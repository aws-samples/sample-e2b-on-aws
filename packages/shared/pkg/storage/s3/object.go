package s3

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/feature/s3/manager"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

const (
	readTimeout       = 10 * time.Second
	operationTimeout  = 5 * time.Second
	bufferSize        = 2 << 21
	initialBackoff    = 10 * time.Millisecond
	maxBackoff        = 10 * time.Second
	backoffMultiplier = 2
	maxAttempts       = 10
)

type Object struct {
	bucket *BucketHandle
	key    string
	ctx    context.Context
}

func NewObject(ctx context.Context, bucket *BucketHandle, objectPath string) *Object {
	return &Object{
		bucket: bucket,
		key:    objectPath,
		ctx:    ctx,
	}
}

func (o *Object) WriteTo(dst io.Writer) (int64, error) {
	ctx, cancel := context.WithTimeout(o.ctx, readTimeout)
	defer cancel()

	resp, err := o.bucket.Client.GetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(o.bucket.Name),
		Key:    aws.String(o.key),
	})
	if err != nil {
		return 0, fmt.Errorf("failed to download S3 object: %w", err)
	}
	defer resp.Body.Close()

	return io.Copy(dst, resp.Body)
}

func (o *Object) ReadFrom(src io.Reader) (int64, error) {
	uploader := manager.NewUploader(o.bucket.Client)

	_, err := uploader.Upload(o.ctx, &s3.PutObjectInput{
		Bucket: aws.String(o.bucket.Name),
		Key:    aws.String(o.key),
		Body:   src,
	})

	if err != nil {
		return 0, fmt.Errorf("failed to upload to S3: %w", err)
	}

	// S3 API doesn't return bytes written, so we have to return 0 here
	return 0, nil
}

func (o *Object) UploadWithCli(ctx context.Context, path string) error {
	cmd := exec.CommandContext(
		ctx,
		"aws",
		"s3",
		"cp",
		path,
		fmt.Sprintf("s3://%s/%s", o.bucket.Name, o.key),
	)

	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("failed to upload file to S3: %w\n%s", err, string(output))
	}

	return nil
}

func (o *Object) Upload(ctx context.Context, path string) error {
	file, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("failed to open file: %w", err)
	}
	defer file.Close()

	uploader := manager.NewUploader(o.bucket.Client, func(u *manager.Uploader) {
		u.PartSize = 100 * 1024 * 1024 // 64MB per part
	})

	// Perform the upload
	_, err = uploader.Upload(context.TODO(), &s3.PutObjectInput{
		Bucket: aws.String(o.bucket.Name),
		Key:    aws.String(o.key),
		Body:   file,
	})
	if err != nil {
		return fmt.Errorf("Upload failed: %w", err)
	}

	return nil
}

func (o *Object) ReadAt(b []byte, off int64) (n int, err error) {
	ctx, cancel := context.WithTimeout(o.ctx, readTimeout)
	defer cancel()

	resp, err := o.bucket.Client.GetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(o.bucket.Name),
		Key:    aws.String(o.key),
		Range:  aws.String(fmt.Sprintf("bytes=%d-%d", off, off+int64(len(b))-1)),
	})

	if err != nil {
		return 0, fmt.Errorf("failed to create S3 reader: %w", err)
	}

	defer resp.Body.Close()

	for {
		nr, readErr := resp.Body.Read(b[n:])
		n += nr

		if readErr == nil {
			continue
		}

		if errors.Is(readErr, io.EOF) {
			break
		}

		return n, fmt.Errorf("failed to read from S3 object: %w", readErr)
	}

	return n, nil
}

func (o *Object) Size() (int64, error) {
	ctx, cancel := context.WithTimeout(o.ctx, operationTimeout)
	defer cancel()

	resp, err := o.bucket.Client.HeadObject(ctx, &s3.HeadObjectInput{
		Bucket: aws.String(o.bucket.Name),
		Key:    aws.String(o.key),
	})

	if err != nil {
		return 0, fmt.Errorf("failed to get S3 object (%s) attributes: %w", o.key, err)
	}

	return *resp.ContentLength, nil
}

func (o *Object) Delete() error {
	ctx, cancel := context.WithTimeout(o.ctx, operationTimeout)
	defer cancel()

	_, err := o.bucket.Client.DeleteObject(ctx, &s3.DeleteObjectInput{
		Bucket: aws.String(o.bucket.Name),
		Key:    aws.String(o.key),
	})

	if err != nil {
		return fmt.Errorf("failed to delete S3 object: %w", err)
	}

	return nil
}
