package s3

import (
	"context"
	"fmt"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
)

func RemoveDir(ctx context.Context, bucket *BucketHandle, dir string) error {
	paginator := s3.NewListObjectsV2Paginator(bucket.Client, &s3.ListObjectsV2Input{
		Bucket: aws.String(bucket.Name),
		Prefix: aws.String(dir + "/"),
	})

	for paginator.HasMorePages() {
		page, err := paginator.NextPage(ctx)
		if err != nil {
			return fmt.Errorf("error when listing S3 objects: %w", err)
		}

		if len(page.Contents) == 0 {
			break
		}

		objects := make([]types.ObjectIdentifier, len(page.Contents))
		for i, obj := range page.Contents {
			objects[i] = types.ObjectIdentifier{
				Key: obj.Key,
			}
		}

		_, err = bucket.Client.DeleteObjects(ctx, &s3.DeleteObjectsInput{
			Bucket: aws.String(bucket.Name),
			Delete: &types.Delete{
				Objects: objects,
			},
		})

		if err != nil {
			return fmt.Errorf("error when deleting S3 objects: %w", err)
		}
	}

	return nil
}
