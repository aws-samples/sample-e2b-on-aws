package storage

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
)

const (
	defaultPresignExpiry = 15 * time.Minute
)

// S3PresignService provides presigned URL generation, object existence checks,
// and file download/delete operations for S3 build context files.
type S3PresignService struct {
	client        *s3.Client
	presignClient *s3.PresignClient
	bucketName    string
	keyPrefix     string
}

// NewS3PresignService creates a new S3PresignService using the default AWS config.
func NewS3PresignService(ctx context.Context, bucketName string, keyPrefix string) (*S3PresignService, error) {
	cfg, err := config.LoadDefaultConfig(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to load AWS config: %w", err)
	}

	client := s3.NewFromConfig(cfg)
	presignClient := s3.NewPresignClient(client)

	return &S3PresignService{
		client:        client,
		presignClient: presignClient,
		bucketName:    bucketName,
		keyPrefix:     keyPrefix,
	}, nil
}

// GeneratePutURL generates a presigned PUT URL for uploading an object to S3.
func (s *S3PresignService) GeneratePutURL(ctx context.Context, key string, expiry time.Duration) (string, error) {
	if expiry == 0 {
		expiry = defaultPresignExpiry
	}

	fullKey := s.keyPrefix + key
	req, err := s.presignClient.PresignPutObject(ctx, &s3.PutObjectInput{
		Bucket: &s.bucketName,
		Key:    &fullKey,
	}, s3.WithPresignExpires(expiry))
	if err != nil {
		return "", fmt.Errorf("failed to generate presigned PUT URL for key '%s': %w", key, err)
	}

	return req.URL, nil
}

// ObjectExists checks whether an object exists in S3 at the given key.
func (s *S3PresignService) ObjectExists(ctx context.Context, key string) (bool, error) {
	fullKey := s.keyPrefix + key
	_, err := s.client.HeadObject(ctx, &s3.HeadObjectInput{
		Bucket: &s.bucketName,
		Key:    &fullKey,
	})
	if err != nil {
		var notFound *types.NotFound
		if errors.As(err, &notFound) {
			return false, nil
		}
		// HeadObject can also return NoSuchKey-style errors as generic API errors
		var noSuchKey *types.NoSuchKey
		if errors.As(err, &noSuchKey) {
			return false, nil
		}
		return false, fmt.Errorf("failed to check object existence for key '%s': %w", key, err)
	}

	return true, nil
}

// DownloadToFile downloads an object from S3 to a local file path.
func (s *S3PresignService) DownloadToFile(ctx context.Context, key string, destPath string) error {
	fullKey := s.keyPrefix + key
	resp, err := s.client.GetObject(ctx, &s3.GetObjectInput{
		Bucket: &s.bucketName,
		Key:    &fullKey,
	})
	if err != nil {
		return fmt.Errorf("failed to download object '%s': %w", key, err)
	}
	defer resp.Body.Close()

	file, err := os.Create(destPath)
	if err != nil {
		return fmt.Errorf("failed to create destination file '%s': %w", destPath, err)
	}
	defer file.Close()

	if _, err := io.Copy(file, resp.Body); err != nil {
		return fmt.Errorf("failed to write object '%s' to file '%s': %w", key, destPath, err)
	}

	return nil
}

// DeleteObject deletes an object from S3.
func (s *S3PresignService) DeleteObject(ctx context.Context, key string) error {
	fullKey := s.keyPrefix + key
	_, err := s.client.DeleteObject(ctx, &s3.DeleteObjectInput{
		Bucket: &s.bucketName,
		Key:    &fullKey,
	})
	if err != nil {
		return fmt.Errorf("failed to delete object '%s': %w", key, err)
	}

	return nil
}

// BuildContextKey returns the S3 key for a build context file.
func BuildContextKey(templateID, hash string) string {
	return fmt.Sprintf("build-files/%s/%s.tar.gz", templateID, hash)
}
