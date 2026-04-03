package artifacts_registry

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/ecr"
	"github.com/aws/aws-sdk-go-v2/service/ecr/types"
	"github.com/google/go-containerregistry/pkg/authn"
	"github.com/google/go-containerregistry/pkg/name"
	containerregistry "github.com/google/go-containerregistry/pkg/v1"
	"github.com/google/go-containerregistry/pkg/v1/remote"
)

type AWSArtifactsRegistry struct {
	repositoryName string
	client         *ecr.Client
}

var (
	AwsRepositoryNameEnvVar = "AWS_DOCKER_REPOSITORY_NAME"
	AwsRepositoryName       = os.Getenv(AwsRepositoryNameEnvVar)
)

func NewAWSArtifactsRegistry(ctx context.Context) (*AWSArtifactsRegistry, error) {
	cfg, err := config.LoadDefaultConfig(ctx)
	if err != nil {
		return nil, err
	}

	if AwsRepositoryName == "" {
		return nil, fmt.Errorf("%s environment variable is not set", AwsRepositoryNameEnvVar)
	}

	client := ecr.NewFromConfig(cfg)

	return &AWSArtifactsRegistry{
		repositoryName: AwsRepositoryName,
		client:         client,
	}, nil
}

// templateRepoName returns the per-template ECR repository name: e2bdev/base/<templateId>
func (g *AWSArtifactsRegistry) templateRepoName(templateId string) string {
	return fmt.Sprintf("%s/%s", g.repositoryName, templateId)
}

// ensureRepository creates the per-template ECR repository if it does not exist.
func (g *AWSArtifactsRegistry) ensureRepository(ctx context.Context, repoName string) error {
	_, err := g.client.DescribeRepositories(ctx, &ecr.DescribeRepositoriesInput{RepositoryNames: []string{repoName}})
	if err != nil {
		var notFound *types.RepositoryNotFoundException
		if errors.As(err, &notFound) {
			_, createErr := g.client.CreateRepository(ctx, &ecr.CreateRepositoryInput{RepositoryName: &repoName})
			if createErr != nil {
				return fmt.Errorf("failed to create ecr repository %s: %w", repoName, createErr)
			}
			return nil
		}
		return fmt.Errorf("failed to describe ecr repository %s: %w", repoName, err)
	}
	return nil
}

func (g *AWSArtifactsRegistry) Delete(ctx context.Context, templateId string, buildId string) error {
	imageIds := []types.ImageIdentifier{
		{ImageTag: &buildId},
	}

	repoName := g.templateRepoName(templateId)
	res, err := g.client.BatchDeleteImage(ctx, &ecr.BatchDeleteImageInput{RepositoryName: &repoName, ImageIds: imageIds})
	if err != nil {
		return fmt.Errorf("failed to delete image from aws ecr: %w", err)
	}

	if len(res.Failures) > 0 {
		if res.Failures[0].FailureCode == types.ImageFailureCodeImageNotFound {
			return ErrImageNotExists
		}

		return errors.New("failed to delete image from aws ecr")
	}

	return nil
}

func (g *AWSArtifactsRegistry) GetTag(ctx context.Context, templateId string, buildId string) (string, error) {
	repoName := g.templateRepoName(templateId)

	if err := g.ensureRepository(ctx, repoName); err != nil {
		return "", err
	}

	res, err := g.client.DescribeRepositories(ctx, &ecr.DescribeRepositoriesInput{RepositoryNames: []string{repoName}})
	if err != nil {
		return "", fmt.Errorf("failed to describe aws ecr repository: %w", err)
	}

	if len(res.Repositories) == 0 {
		return "", fmt.Errorf("repository %s not found", repoName)
	}

	return fmt.Sprintf("%s:%s", *res.Repositories[0].RepositoryUri, buildId), nil
}

func (g *AWSArtifactsRegistry) GetImage(ctx context.Context, templateId string, buildId string, platform containerregistry.Platform) (containerregistry.Image, error) {
	imageUrl, err := g.GetTag(ctx, templateId, buildId)
	if err != nil {
		return nil, fmt.Errorf("failed to get image URL: %w", err)
	}

	ref, err := name.ParseReference(imageUrl)
	if err != nil {
		return nil, fmt.Errorf("invalid image reference: %w", err)
	}

	auth, err := g.getAuthToken(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to get auth: %w", err)
	}

	img, err := remote.Image(ref, remote.WithAuth(auth), remote.WithPlatform(platform), remote.WithContext(ctx))
	if err != nil {
		return nil, fmt.Errorf("error pulling image: %w", err)
	}

	return img, nil
}

func (g *AWSArtifactsRegistry) getAuthToken(ctx context.Context) (*authn.Basic, error) {
	res, err := g.client.GetAuthorizationToken(ctx, &ecr.GetAuthorizationTokenInput{})
	if err != nil {
		return nil, fmt.Errorf("failed to get aws ecr auth token: %w", err)
	}

	if len(res.AuthorizationData) == 0 {
		return nil, fmt.Errorf("no aws ecr auth token found")
	}

	authData := res.AuthorizationData[0]
	decodedToken, err := base64.StdEncoding.DecodeString(*authData.AuthorizationToken)
	if err != nil {
		return nil, fmt.Errorf("failed to decode aws ecr auth token: %w", err)
	}

	// split into username and password
	parts := strings.SplitN(string(decodedToken), ":", 2)
	if len(parts) != 2 {
		return nil, fmt.Errorf("invalid aws ecr auth token")
	}

	username := parts[0]
	password := parts[1]

	return &authn.Basic{
		Username: username,
		Password: password,
	}, nil
}
