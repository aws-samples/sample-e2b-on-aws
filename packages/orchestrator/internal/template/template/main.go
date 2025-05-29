package template

import (
	"context"
	"fmt"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ecr/types"

	"log"

	"github.com/aws/aws-sdk-go-v2/service/ecr"

	"github.com/e2b-dev/infra/packages/shared/pkg/consts"
	"github.com/e2b-dev/infra/packages/shared/pkg/telemetry"
	"go.opentelemetry.io/otel/trace"
)

func GetDockerImageURL(templateID string) string {
	// DockerImagesURL is the URL to the docker images in the artifact registry
	return fmt.Sprintf("%s.dkr.ecr.%s.amazonaws.com/%s/%s:%s", consts.AWSAccountID, consts.AWSRegion, consts.ECRRepository, templateID)
}
func GetDockerImageTag(templateID string) string {
	// Return the ECR image tag
	return templateID
}

func GetDockerImageRepository(templateID string) string {
	// Return the ECR repository URI
	return fmt.Sprintf("%s.dkr.ecr.%s.amazonaws.com/%s/%s", consts.AWSAccountID, consts.AWSRegion, consts.ECRRepository, templateID)
	//return fmt.Sprintf("%s.dkr.ecr.%s.amazonaws.com/%s:", consts.AWSAccountID, consts.AWSRegion, consts.ECRRepository)
}

// GetDockerRepositoryName 返回完整的 ECR 仓库名称
func GetDockerRepositoryName(templateID string) string {
	// 根据截图和您提供的信息，正确的格式是 "e2b-custom-environments/templateID"
	return fmt.Sprintf("%s/%s", consts.ECRRepository, templateID)
}
func Delete(
	ctx context.Context,
	tracer trace.Tracer,
	ecrClient *ecr.Client,
	templateStorage *Storage,
	buildId string,
	templateID string,
) error {
	childCtx, childSpan := tracer.Start(ctx, "delete-template")
	defer childSpan.End()

	err := templateStorage.Remove(ctx, buildId)
	if err != nil {
		return fmt.Errorf("error when deleting template objects: %w", err)
	}
	// 获取完整的仓库名称
	repositoryName := GetDockerRepositoryName(templateID)

	// 打印调试信息
	log.Printf("Attempting to delete image with tag '%s' from repository '%s'", buildId, repositoryName)

	imageToDelete := ecr.BatchDeleteImageInput{
		RepositoryName: aws.String(repositoryName),
		ImageIds: []types.ImageIdentifier{
			{
				ImageTag: aws.String(buildId),
			},
		},
	}
	_, ecrDeleteErr := ecrClient.BatchDeleteImage(ctx, &imageToDelete)

	if ecrDeleteErr != nil {
		errMsg := fmt.Errorf("error when deleting template image from registry: %w", ecrDeleteErr)
		telemetry.ReportCriticalError(childCtx, errMsg)
		log.Printf("error deleting template image from ECR: %v", ecrDeleteErr)
	} else {
		telemetry.ReportEvent(childCtx, "deleted template image from registry")
		log.Printf("successfully deleted template image %s from ECR", buildId)
	}

	return nil
}
