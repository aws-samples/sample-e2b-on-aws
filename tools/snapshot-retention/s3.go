package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
	"github.com/aws/smithy-go"
)

// s3Store talks to the template bucket with the raw SDK. The vendored AWS
// storage provider is not used because it exposes neither object metadata
// (it implements no MetadataReader) nor a listing.
type s3Store struct {
	client *s3.Client
	bucket string
}

func newS3Store(ctx context.Context, bucket, region string) (*s3Store, error) {
	var opts []func(*awsconfig.LoadOptions) error
	if region != "" {
		opts = append(opts, awsconfig.WithRegion(region))
	}

	cfg, err := awsconfig.LoadDefaultConfig(ctx, opts...)
	if err != nil {
		return nil, err
	}

	return &s3Store{client: s3.NewFromConfig(cfg), bucket: bucket}, nil
}

func (s *s3Store) Get(ctx context.Context, key string) ([]byte, error) {
	out, err := s.client.GetObject(ctx, &s3.GetObjectInput{Bucket: &s.bucket, Key: &key})
	if err != nil {
		if isNotFound(err) {
			return nil, errNotFound
		}

		return nil, err
	}
	defer out.Body.Close()

	return io.ReadAll(out.Body)
}

// Head returns the object's user metadata with lower-cased keys.
func (s *s3Store) Head(ctx context.Context, key string) (map[string]string, error) {
	out, err := s.client.HeadObject(ctx, &s3.HeadObjectInput{Bucket: &s.bucket, Key: &key})
	if err != nil {
		if isNotFound(err) {
			return nil, errNotFound
		}

		return nil, err
	}

	meta := make(map[string]string, len(out.Metadata))
	for k, v := range out.Metadata {
		meta[strings.ToLower(k)] = v
	}

	return meta, nil
}

func (s *s3Store) List(ctx context.Context, prefix string) ([]string, error) {
	var keys []string

	pager := s3.NewListObjectsV2Paginator(s.client, &s3.ListObjectsV2Input{Bucket: &s.bucket, Prefix: &prefix})
	for pager.HasMorePages() {
		page, err := pager.NextPage(ctx)
		if err != nil {
			return nil, err
		}
		for _, o := range page.Contents {
			keys = append(keys, aws.ToString(o.Key))
		}
	}

	return keys, nil
}

// Delete removes the keys in batches of 1000 (the DeleteObjects limit) and
// fails unless S3 reports every key as deleted.
func (s *s3Store) Delete(ctx context.Context, keys []string) error {
	const batchSize = 1000

	for start := 0; start < len(keys); start += batchSize {
		batch := keys[start:min(start+batchSize, len(keys))]

		ids := make([]types.ObjectIdentifier, len(batch))
		for i, k := range batch {
			ids[i] = types.ObjectIdentifier{Key: aws.String(k)}
		}

		out, err := s.client.DeleteObjects(ctx, &s3.DeleteObjectsInput{
			Bucket: &s.bucket,
			Delete: &types.Delete{Objects: ids, Quiet: aws.Bool(false)},
		})
		if err != nil {
			return err
		}
		if len(out.Errors) > 0 {
			e := out.Errors[0]

			return fmt.Errorf("%d of %d objects failed, first: %s: %s %s", len(out.Errors), len(batch), aws.ToString(e.Key), aws.ToString(e.Code), aws.ToString(e.Message))
		}
		if len(out.Deleted) != len(batch) {
			return fmt.Errorf("s3 reported %d deleted of %d requested", len(out.Deleted), len(batch))
		}
	}

	return nil
}

func isNotFound(err error) bool {
	var noSuchKey *types.NoSuchKey
	if errors.As(err, &noSuchKey) {
		return true
	}
	var notFound *types.NotFound
	if errors.As(err, &notFound) {
		return true
	}

	var apiErr smithy.APIError
	if errors.As(err, &apiErr) {
		switch apiErr.ErrorCode() {
		case "NoSuchKey", "NotFound":
			return true
		}
	}

	return false
}
