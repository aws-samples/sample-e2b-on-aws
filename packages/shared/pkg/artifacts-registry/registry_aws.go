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

func (g *AWSArtifactsRegistry) Delete(ctx context.Context, templateId string, buildId string) error {
	imageIds := []types.ImageIdentifier{
		{ImageTag: &buildId},
	}

	// for AWS implementation we are using only build id as image tag
	res, err := g.client.BatchDeleteImage(ctx, &ecr.BatchDeleteImageInput{RepositoryName: &g.repositoryName, ImageIds: imageIds})
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
	repositoryNameWithTemplate := fmt.Sprintf("%s/%s", g.repositoryName, templateId)
	res, err := g.client.DescribeRepositories(ctx, &ecr.DescribeRepositoriesInput{RepositoryNames: []string{repositoryNameWithTemplate}})
	if err != nil {
		return "", fmt.Errorf("failed to describe aws ecr repository: %w", err)
	}

	if len(res.Repositories) == 0 {
		return "", fmt.Errorf("repository %s not found", g.repositoryName)
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

	img, err := remote.Image(ref, remote.WithAuth(auth), remote.WithPlatform(platform))
	if err != nil {
		return nil, fmt.Errorf("error pulling image: %w", err)
	}

	return img, nil
}

// CopyImage copies an image from sourceRef (full ECR URI) to the standard
// build location {baseRepo}/{templateId}:{buildId}.
// This enables v2 SDK builds where the user pre-pushes images to ECR.
func (g *AWSArtifactsRegistry) CopyImage(ctx context.Context, sourceRef string, templateId string, buildId string) error {
	// Resolve short image names (e.g. "e2bdev/desktop") to full ECR URI
	sourceRef, err := g.resolveSourceRef(ctx, sourceRef)
	if err != nil {
		return fmt.Errorf("failed to resolve source reference: %w", err)
	}

	// 1. Parse source reference
	src, err := name.ParseReference(sourceRef)
	if err != nil {
		return fmt.Errorf("failed to parse source image reference '%s': %w", sourceRef, err)
	}

	// 2. Fetch source image — use auth only for private ECR, anonymous for public sources
	var img containerregistry.Image
	if isPrivateECR(sourceRef) {
		auth, err := g.getAuthToken(ctx)
		if err != nil {
			return fmt.Errorf("failed to get ECR auth token: %w", err)
		}
		img, err = remote.Image(src, remote.WithAuth(auth))
		if err != nil {
			return fmt.Errorf("failed to fetch source image '%s': %w", sourceRef, err)
		}
	} else {
		// Public images (Docker Hub, public.ecr.aws, etc.) — anonymous pull
		var fetchErr error
		img, fetchErr = remote.Image(src)
		if fetchErr != nil {
			return fmt.Errorf("failed to fetch source image '%s': %w", sourceRef, fetchErr)
		}
	}

	// 3. Ensure target ECR repository exists
	targetRepoName := fmt.Sprintf("%s/%s", g.repositoryName, templateId)
	if err := g.ensureRepository(ctx, targetRepoName); err != nil {
		return fmt.Errorf("failed to ensure target repository: %w", err)
	}

	// 5. Get target reference using existing GetTag logic
	targetTag, err := g.GetTag(ctx, templateId, buildId)
	if err != nil {
		return fmt.Errorf("failed to get target tag: %w", err)
	}

	dst, err := name.ParseReference(targetTag)
	if err != nil {
		return fmt.Errorf("failed to parse target reference '%s': %w", targetTag, err)
	}

	// 6. Write image to target (always use ECR auth for the destination)
	pushAuth, err := g.getAuthToken(ctx)
	if err != nil {
		return fmt.Errorf("failed to get ECR auth token for push: %w", err)
	}
	if err := remote.Write(dst, img, remote.WithAuth(pushAuth)); err != nil {
		return fmt.Errorf("failed to write image to '%s': %w", targetTag, err)
	}

	return nil
}

// ensureRepository creates the ECR repository if it doesn't exist.
func (g *AWSArtifactsRegistry) ensureRepository(ctx context.Context, repoName string) error {
	_, err := g.client.DescribeRepositories(ctx, &ecr.DescribeRepositoriesInput{
		RepositoryNames: []string{repoName},
	})
	if err != nil {
		// Repository not found → create it
		mutability := types.ImageTagMutabilityMutable
		_, err = g.client.CreateRepository(ctx, &ecr.CreateRepositoryInput{
			RepositoryName:     &repoName,
			ImageTagMutability: mutability,
		})
		if err != nil {
			return fmt.Errorf("failed to create ECR repository %s: %w", repoName, err)
		}
	}
	return nil
}

// resolveSourceRef resolves image references. If the reference already contains a
// registry domain (detected by a "." in the first path component), it is returned as-is.
// Short names without a domain are treated as Docker Hub images.
func (g *AWSArtifactsRegistry) resolveSourceRef(ctx context.Context, sourceRef string) (string, error) {
	parts := strings.SplitN(sourceRef, "/", 2)
	// Strip tag/digest before checking for domain dots
	host := strings.SplitN(parts[0], ":", 2)[0]
	if strings.Contains(host, ".") {
		// Already has a registry domain (e.g. public.ecr.aws/..., 918xxx.dkr.ecr.../...)
		return sourceRef, nil
	}

	// No domain → Docker Hub image
	if len(parts) == 1 {
		// Official image like "ubuntu:22.04" → "docker.io/library/ubuntu:22.04"
		nameAndTag := strings.SplitN(sourceRef, ":", 2)
		if len(nameAndTag) == 2 {
			return fmt.Sprintf("docker.io/library/%s:%s", nameAndTag[0], nameAndTag[1]), nil
		}
		return fmt.Sprintf("docker.io/library/%s:latest", sourceRef), nil
	}
	// User image like "myuser/myrepo:tag" → "docker.io/myuser/myrepo:tag"
	return fmt.Sprintf("docker.io/%s", sourceRef), nil
}

// isPrivateECR checks if the image reference points to a private ECR registry.
func isPrivateECR(ref string) bool {
	return strings.Contains(ref, ".dkr.ecr.") && strings.Contains(ref, ".amazonaws.com")
}

// getLatestImageTag returns the most recently pushed image tag for a template.
// Returns empty string if no images exist.
func (g *AWSArtifactsRegistry) getLatestImageTag(ctx context.Context, templateID string) (string, error) {
	repoName := fmt.Sprintf("%s/%s", g.repositoryName, templateID)

	res, err := g.client.DescribeImages(ctx, &ecr.DescribeImagesInput{
		RepositoryName: &repoName,
		Filter: &types.DescribeImagesFilter{
			TagStatus: types.TagStatusTagged,
		},
	})
	if err != nil {
		return "", fmt.Errorf("failed to describe images for %s: %w", repoName, err)
	}

	if len(res.ImageDetails) == 0 {
		return "", nil
	}

	// Find the most recently pushed image
	var latest *types.ImageDetail
	for i := range res.ImageDetails {
		img := &res.ImageDetails[i]
		if img.ImagePushedAt == nil || len(img.ImageTags) == 0 {
			continue
		}
		if latest == nil || img.ImagePushedAt.After(*latest.ImagePushedAt) {
			latest = img
		}
	}

	if latest == nil {
		return "", nil
	}

	// Get the repository URI
	repoRes, err := g.client.DescribeRepositories(ctx, &ecr.DescribeRepositoriesInput{
		RepositoryNames: []string{repoName},
	})
	if err != nil || len(repoRes.Repositories) == 0 {
		return "", fmt.Errorf("failed to get repository URI for %s: %w", repoName, err)
	}

	return fmt.Sprintf("%s:%s", *repoRes.Repositories[0].RepositoryUri, latest.ImageTags[0]), nil
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
