package oci

import (
	"context"
	"encoding/base64"
	"fmt"
	"os"
	"strings"

	"github.com/Microsoft/hcsshim/ext4/tar2ext4"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/ecr"
	"github.com/google/go-containerregistry/pkg/authn"
	"github.com/google/go-containerregistry/pkg/name"
	v1 "github.com/google/go-containerregistry/pkg/v1"
	"github.com/google/go-containerregistry/pkg/v1/mutate"
	"github.com/google/go-containerregistry/pkg/v1/remote"
	"go.opentelemetry.io/otel/trace"

	"github.com/e2b-dev/infra/packages/shared/pkg/consts"
	"github.com/e2b-dev/infra/packages/shared/pkg/telemetry"
)

const ToMBShift = 20

func getECRAuth(ctx context.Context) (authn.Authenticator, error) {
	cfg, err := config.LoadDefaultConfig(ctx,
		config.WithRegion(consts.AWSRegion),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to load AWS config: %w", err)
	}

	// 创建 ECR 客户端
	ecrClient := ecr.NewFromConfig(cfg)

	// 获取授权令牌
	input := &ecr.GetAuthorizationTokenInput{}
	result, err := ecrClient.GetAuthorizationToken(ctx, input)
	if err != nil {
		return nil, fmt.Errorf("error getting ECR auth token: %w", err)
	}

	// 处理授权数据
	if len(result.AuthorizationData) == 0 {
		return nil, fmt.Errorf("no authorization data returned")
	}

	authData := result.AuthorizationData[0]
	token := *authData.AuthorizationToken

	// 解码 Base64 令牌
	decodedToken, err := base64.StdEncoding.DecodeString(token)
	if err != nil {
		return nil, fmt.Errorf("error decoding auth token: %w", err)
	}

	// 分割用户名和密码
	parts := strings.SplitN(string(decodedToken), ":", 2)
	if len(parts) != 2 {
		return nil, fmt.Errorf("invalid auth token format")
	}

	return &authn.Basic{
		Username: parts[0],
		Password: parts[1],
	}, nil
}

func GetImage(ctx context.Context, tracer trace.Tracer, dockerTag string) (v1.Image, error) {
	childCtx, childSpan := tracer.Start(ctx, "pull-docker-image")
	defer childSpan.End()

	auth, err := getECRAuth(childCtx)
	if err != nil {
		return nil, fmt.Errorf("failed to get ECR auth: %w", err)
	}

	ref, err := name.ParseReference(dockerTag)
	if err != nil {
		return nil, fmt.Errorf("invalid image reference: %w", err)
	}

	platform := v1.Platform{
		OS:           "linux",
		Architecture: "amd64",
	}
	img, err := remote.Image(ref, remote.WithAuth(auth), remote.WithPlatform(platform))
	if err != nil {
		return nil, fmt.Errorf("error pulling image: %w", err)
	}

	telemetry.ReportEvent(childCtx, "pulled image")
	return img, nil
}

func GetImageSize(img v1.Image) (int64, error) {
	imageSize := int64(0)

	layers, err := img.Layers()
	if err != nil {
		return 0, fmt.Errorf("error getting image layers: %w", err)
	}

	for index, layer := range layers {
		layerSize, err := layer.Size()
		if err != nil {
			return 0, fmt.Errorf("error getting layer (%d) size: %w", index, err)
		}
		imageSize += layerSize
	}

	return imageSize, nil
}

func ToExt4(ctx context.Context, img v1.Image, rootfsPath string, sizeLimit int64) error {
	r := mutate.Extract(img)
	defer r.Close()

	rootfsFile, err := os.Create(rootfsPath)
	if err != nil {
		return fmt.Errorf("error creating rootfs file: %w", err)
	}
	defer func() {
		rootfsErr := rootfsFile.Close()
		if rootfsErr != nil {
			telemetry.ReportError(ctx, fmt.Errorf("error closing rootfs file: %w", rootfsErr))
		} else {
			telemetry.ReportEvent(ctx, "closed rootfs file")
		}
	}()

	// Convert tar to ext4 image
	if err := tar2ext4.Convert(r, rootfsFile, tar2ext4.ConvertWhiteout, tar2ext4.MaximumDiskSize(sizeLimit)); err != nil {
		if strings.Contains(err.Error(), "disk exceeded maximum size") {
			return fmt.Errorf("build failed - exceeded maximum size %v MB", sizeLimit>>ToMBShift)
		}
		return fmt.Errorf("error converting tar to ext4: %w", err)
	}

	return nil
}
