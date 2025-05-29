package s3

import (
	"context"
	"os"
	"testing"

	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/stretchr/testify/assert"
)

var BUCKET_NAME = os.Getenv("TEMPLATE_BUCKET_NAME")
var AWS_REGION = os.Getenv("AWS_REGION")
var LARGE_FILE_PATH = os.Getenv("LARGE_FILE_PATH")

func TestObject_WithRealS3Client(t *testing.T) {
	// Skip if not set
	var region = "us-east-1"
	var file = "object.go"

	if BUCKET_NAME == "" {
		t.Fatal("TEMPLATE_BUCKET_NAME is not set")
		return
	}
	if LARGE_FILE_PATH != "" {
		file = LARGE_FILE_PATH
	}
	if AWS_REGION != "" {
		region = AWS_REGION
	}

	t.Logf("BUCKET_NAME: %s", BUCKET_NAME)
	t.Logf("AWS_REGION: %s", AWS_REGION)
	t.Logf("LARGE_FILE_PATH: %s", LARGE_FILE_PATH)

	// Create real S3 client (uses default AWS credentials)
	cfg, err := config.LoadDefaultConfig(context.Background(),
		config.WithRegion(region))
	if err != nil {
		t.Fatal("unable to load SDK config:", err)
	}
	client := s3.NewFromConfig(cfg)

	bucket := &BucketHandle{
		Name:   BUCKET_NAME,
		Client: client,
	}

	ctx := context.Background()
	obj := NewObject(ctx, bucket, file)

	// Test reading data
	err = obj.Upload(ctx, file)
	assert.NoError(t, err)
	t.Logf("Uploaded object %s successfully", file)

	//Test deletion

	err = obj.Delete()
	assert.NoError(t, err)
	t.Logf("Deleted object %s successfully", file)
}
