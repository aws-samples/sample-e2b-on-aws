package storage

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/feature/s3/manager"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
)

const (
	awsOperationTimeout = 5 * time.Second
	awsWriteTimeout     = 120 * time.Second
	awsReadTimeout      = 15 * time.Second
)

var storageTimingDebug = os.Getenv("E2B_STORAGE_TIMING_DEBUG") == "true" || os.Getenv("E2B_STORAGE_TIMING_DEBUG") == "1"

func logStorageTiming(format string, args ...any) {
	if !storageTimingDebug {
		return
	}

	log.Printf("[e2b-storage-timing] "+format, args...)
}

type AWSBucketStorageProvider struct {
	client     *s3.Client
	bucketName string
}

type AWSBucketStorageObjectProvider struct {
	client     *s3.Client
	path       string
	bucketName string
	ctx        context.Context
}

func NewAWSBucketStorageProvider(ctx context.Context, bucketName string) (*AWSBucketStorageProvider, error) {
	cfg, err := config.LoadDefaultConfig(ctx)
	if err != nil {
		return nil, err
	}

	client := s3.NewFromConfig(cfg)

	return &AWSBucketStorageProvider{
		client:     client,
		bucketName: bucketName,
	}, nil
}

func (a *AWSBucketStorageProvider) DeleteObjectsWithPrefix(ctx context.Context, prefix string) error {
	ctx, cancel := context.WithTimeout(ctx, awsOperationTimeout)
	defer cancel()

	list, err := a.client.ListObjectsV2(ctx, &s3.ListObjectsV2Input{Bucket: &a.bucketName, Prefix: &prefix})
	if err != nil {
		return err
	}

	objects := make([]types.ObjectIdentifier, 0, len(list.Contents))
	for _, obj := range list.Contents {
		objects = append(objects, types.ObjectIdentifier{Key: obj.Key})
	}

	_, err = a.client.DeleteObjects(
		ctx, &s3.DeleteObjectsInput{
			Bucket: &a.bucketName,
			Delete: &types.Delete{Objects: objects},
		},
	)

	return err
}

func (a *AWSBucketStorageProvider) GetDetails() string {
	return fmt.Sprintf("[AWS Storage, bucket set to %s]", a.bucketName)
}

func (a *AWSBucketStorageProvider) OpenObject(ctx context.Context, path string) (StorageObjectProvider, error) {
	return &AWSBucketStorageObjectProvider{
		client:     a.client,
		bucketName: a.bucketName,
		path:       path,
		ctx:        ctx,
	}, nil
}

func (a *AWSBucketStorageObjectProvider) WriteTo(dst io.Writer) (int64, error) {
	ctx, cancel := context.WithTimeout(a.ctx, awsReadTimeout)
	defer cancel()

	resp, err := a.client.GetObject(ctx, &s3.GetObjectInput{Bucket: &a.bucketName, Key: &a.path})
	if err != nil {
		var nsk *types.NoSuchKey
		if errors.As(err, &nsk) {
			return 0, ErrorObjectNotExist
		}

		return 0, err
	}

	defer resp.Body.Close()

	return io.Copy(dst, resp.Body)
}

func (a *AWSBucketStorageObjectProvider) WriteFromFileSystem(path string) error {
	ctx, cancel := context.WithTimeout(a.ctx, awsWriteTimeout)
	defer cancel()

	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()

	uploader := manager.NewUploader(
		a.client,
		func(u *manager.Uploader) {
			u.PartSize = 10 * 1024 * 1024 // 10 MB
			u.Concurrency = 8             // eight parts in flight
		},
	)

	_, err = uploader.Upload(
		ctx,
		&s3.PutObjectInput{
			Bucket: &a.bucketName,
			Key:    &a.path,
			Body:   file,
		},
	)

	return err
}

func (a *AWSBucketStorageObjectProvider) ReadFrom(src io.Reader) (int64, error) {
	ctx, cancel := context.WithTimeout(a.ctx, awsWriteTimeout)
	defer cancel()

	_, err := a.client.PutObject(
		ctx,
		&s3.PutObjectInput{
			Bucket: &a.bucketName,
			Key:    &a.path,
			Body:   src,
		},
	)
	if err != nil {
		return 0, err
	}

	return 0, nil
}

func (a *AWSBucketStorageObjectProvider) ReadAt(buff []byte, off int64) (n int, err error) {
	totalStart := time.Now()
	ctx, cancel := context.WithTimeout(a.ctx, awsReadTimeout)
	defer cancel()

	readRange := aws.String(fmt.Sprintf("bytes=%d-%d", off, off+int64(len(buff))-1))
	getObjectStart := time.Now()
	resp, err := a.client.GetObject(ctx, &s3.GetObjectInput{Bucket: &a.bucketName, Key: &a.path, Range: readRange})
	getObjectDuration := time.Since(getObjectStart)
	if err != nil {
		logStorageTiming(
			"s3_readat bucket=%s key=%s offset=%d length=%d get_object_duration=%s total_duration=%s err=%q",
			a.bucketName,
			a.path,
			off,
			len(buff),
			getObjectDuration,
			time.Since(totalStart),
			err.Error(),
		)

		var nsk *types.NoSuchKey
		if errors.As(err, &nsk) {
			return 0, ErrorObjectNotExist
		}

		return 0, err
	}

	defer resp.Body.Close()

	// When the object is smaller than requested range there will be unexpected EOF,
	// but backend expects to return EOF in this case.
	bodyReadStart := time.Now()
	n, err = io.ReadFull(resp.Body, buff)
	bodyReadDuration := time.Since(bodyReadStart)
	if errors.Is(err, io.ErrUnexpectedEOF) {
		err = io.EOF
	}
	logStorageTiming(
		"s3_readat bucket=%s key=%s offset=%d length=%d bytes=%d get_object_duration=%s body_read_duration=%s total_duration=%s err=%v",
		a.bucketName,
		a.path,
		off,
		len(buff),
		n,
		getObjectDuration,
		bodyReadDuration,
		time.Since(totalStart),
		err,
	)

	return n, err
}

func (a *AWSBucketStorageObjectProvider) Size() (int64, error) {
	ctx, cancel := context.WithTimeout(a.ctx, awsOperationTimeout)
	defer cancel()

	resp, err := a.client.HeadObject(ctx, &s3.HeadObjectInput{Bucket: &a.bucketName, Key: &a.path})
	if err != nil {
		return 0, err
	}

	return *resp.ContentLength, nil
}

func (a *AWSBucketStorageObjectProvider) Delete() error {
	ctx, cancel := context.WithTimeout(a.ctx, awsOperationTimeout)
	defer cancel()

	_, err := a.client.DeleteObject(
		ctx, &s3.DeleteObjectInput{
			Bucket: &a.bucketName,
			Key:    &a.path,
		},
	)

	return err
}
