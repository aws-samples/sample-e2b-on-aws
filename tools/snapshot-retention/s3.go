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

	"github.com/e2b-dev/infra/packages/shared/pkg/storage"
)

// s3Store reads the template bucket with the raw SDK - upstream's AWS provider
// exposes neither object metadata nor a listing - and deletes through the
// provider, so a build's prefix goes away by the same code the orchestrator
// uses to delete its own builds.
type s3Store struct {
	client   *s3.Client
	bucket   string
	provider storage.StorageProvider
}

func newS3Store(ctx context.Context, bucket, region string) (*s3Store, error) {
	provider, err := storage.NewProvider(ctx, storage.Spec{Provider: storage.AWSStorageProvider, Bucket: bucket, Region: region})
	if err != nil {
		return nil, fmt.Errorf("storage provider: %w", err)
	}

	var opts []func(*awsconfig.LoadOptions) error
	if region != "" {
		opts = append(opts, awsconfig.WithRegion(region))
	}
	cfg, err := awsconfig.LoadDefaultConfig(ctx, opts...)
	if err != nil {
		return nil, err
	}

	return &s3Store{client: s3.NewFromConfig(cfg), bucket: bucket, provider: provider}, nil
}

func (s *s3Store) Get(ctx context.Context, key string) ([]byte, error) {
	out, err := s.client.GetObject(ctx, &s3.GetObjectInput{Bucket: &s.bucket, Key: &key})
	if err != nil {
		return nil, mapNotFound(err)
	}
	defer out.Body.Close()

	if size := aws.ToInt64(out.ContentLength); size > 0 {
		buf := make([]byte, size)
		if _, err := io.ReadFull(out.Body, buf); err != nil {
			return nil, err
		}

		return buf, nil
	}

	return io.ReadAll(out.Body)
}

// Head returns the object's user metadata with lower-cased keys.
func (s *s3Store) Head(ctx context.Context, key string) (map[string]string, error) {
	out, err := s.client.HeadObject(ctx, &s3.HeadObjectInput{Bucket: &s.bucket, Key: &key})
	if err != nil {
		return nil, mapNotFound(err)
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

// DeletePrefix removes every object under prefix with upstream's
// DeleteObjectsWithPrefix: paged listing, batches of 1000, and a refusal to
// run on an empty prefix.
func (s *s3Store) DeletePrefix(ctx context.Context, prefix string) error {
	return s.provider.DeleteObjectsWithPrefix(ctx, prefix)
}

// mapNotFound turns the SDK's spellings of "no such object" into upstream's
// sentinel and passes every other error through.
func mapNotFound(err error) error {
	var noSuchKey *types.NoSuchKey
	var notFound *types.NotFound
	var apiErr smithy.APIError

	switch {
	case errors.As(err, &noSuchKey), errors.As(err, &notFound):
		return storage.ErrObjectNotExist
	case errors.As(err, &apiErr) && (apiErr.ErrorCode() == "NoSuchKey" || apiErr.ErrorCode() == "NotFound"):
		return storage.ErrObjectNotExist
	}

	return err
}
