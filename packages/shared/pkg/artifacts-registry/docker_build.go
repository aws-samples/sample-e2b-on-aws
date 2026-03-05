package artifacts_registry

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/google/go-containerregistry/pkg/name"
	containerregistry "github.com/google/go-containerregistry/pkg/v1"
	"github.com/google/go-containerregistry/pkg/v1/daemon"
	"github.com/google/go-containerregistry/pkg/v1/remote"
	"github.com/google/go-containerregistry/pkg/v1/tarball"
	"go.uber.org/zap"

	"github.com/e2b-dev/infra/packages/shared/pkg/storage"
)

// IsDockerfilePath checks if the string looks like a Dockerfile filename/path
// rather than Docker image reference or Dockerfile content.
func IsDockerfilePath(s string) bool {
	s = strings.TrimSpace(s)
	base := filepath.Base(s)
	lower := strings.ToLower(base)
	return lower == "dockerfile" || strings.HasPrefix(lower, "dockerfile.") ||
		strings.HasSuffix(lower, ".dockerfile")
}

// IsDockerfileContent checks if the given string looks like Dockerfile content
// rather than a Docker image reference. It returns true if the string starts
// with a FROM instruction (after stripping leading blank lines and comments).
func IsDockerfileContent(s string) bool {
	for _, line := range strings.Split(s, "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		return strings.HasPrefix(strings.ToUpper(trimmed), "FROM ")
	}
	return false
}

// WriteDockerfileToDir writes Dockerfile content to a temporary directory
// and returns the directory path and a cleanup function.
func WriteDockerfileToDir(content string, templateID string) (string, func(), error) {
	contextDir, err := os.MkdirTemp("", fmt.Sprintf("dockerfile-ctx-%s-*", templateID))
	if err != nil {
		return "", nil, fmt.Errorf("failed to create temp directory: %w", err)
	}

	cleanup := func() {
		os.RemoveAll(contextDir)
	}

	dockerfilePath := filepath.Join(contextDir, "Dockerfile")
	if err := os.WriteFile(dockerfilePath, []byte(content), 0644); err != nil {
		cleanup()
		return "", nil, fmt.Errorf("failed to write Dockerfile: %w", err)
	}

	return contextDir, cleanup, nil
}

// TemplateBuildStep represents a single build step from the SDK.
type TemplateBuildStep struct {
	Type      string   `json:"type"`
	Args      []string `json:"args,omitempty"`
	FilesHash string   `json:"filesHash,omitempty"`
	Force     bool     `json:"force,omitempty"`
}

// GenerateDockerfile generates a Dockerfile from a base image and build steps.
func GenerateDockerfile(baseImage string, steps []TemplateBuildStep) string {
	var sb strings.Builder
	sb.WriteString(fmt.Sprintf("FROM %s\n", baseImage))

	for _, step := range steps {
		switch strings.ToUpper(step.Type) {
		case "RUN":
			if len(step.Args) > 0 {
				sb.WriteString(fmt.Sprintf("RUN %s\n", step.Args[0]))
			}
		case "COPY":
			// SDK sends COPY args as [src, dst, chown, chmod]
			if len(step.Args) >= 2 {
				src := step.Args[0]
				dst := step.Args[1]
				var options []string
				if len(step.Args) > 2 && step.Args[2] != "" {
					options = append(options, fmt.Sprintf("--chown=%s", step.Args[2]))
				}
				if len(step.Args) > 3 && step.Args[3] != "" {
					options = append(options, fmt.Sprintf("--chmod=%s", step.Args[3]))
				}
				if len(options) > 0 {
					sb.WriteString(fmt.Sprintf("COPY %s %s %s\n", strings.Join(options, " "), src, dst))
				} else {
					sb.WriteString(fmt.Sprintf("COPY %s %s\n", src, dst))
				}
			}
		case "ENV":
			if len(step.Args) >= 2 {
				sb.WriteString(fmt.Sprintf("ENV %s=%s\n", step.Args[0], step.Args[1]))
			}
		case "WORKDIR":
			if len(step.Args) > 0 {
				sb.WriteString(fmt.Sprintf("WORKDIR %s\n", step.Args[0]))
			}
		case "USER":
			if len(step.Args) > 0 {
				sb.WriteString(fmt.Sprintf("USER %s\n", step.Args[0]))
			}
		case "EXPOSE":
			if len(step.Args) > 0 {
				sb.WriteString(fmt.Sprintf("EXPOSE %s\n", step.Args[0]))
			}
		case "CMD":
			if len(step.Args) > 0 {
				sb.WriteString(fmt.Sprintf("CMD %s\n", step.Args[0]))
			}
		case "ENTRYPOINT":
			if len(step.Args) > 0 {
				sb.WriteString(fmt.Sprintf("ENTRYPOINT %s\n", step.Args[0]))
			}
		default:
			zap.L().Warn("Unknown build step type, skipping", zap.String("type", step.Type))
		}
	}

	return sb.String()
}

// PrepareBuildContext downloads uploaded files from S3 and generates a Dockerfile
// in a temporary directory. Returns the context directory path and a cleanup function.
func PrepareBuildContext(
	ctx context.Context,
	presignSvc *storage.S3PresignService,
	templateID string,
	baseImage string,
	steps []TemplateBuildStep,
) (string, func(), error) {
	contextDir, err := os.MkdirTemp("", fmt.Sprintf("build-ctx-%s-*", templateID))
	if err != nil {
		return "", nil, fmt.Errorf("failed to create temp directory: %w", err)
	}

	cleanup := func() {
		os.RemoveAll(contextDir)
	}

	// Download and extract COPY step files from S3
	for _, step := range steps {
		if strings.ToUpper(step.Type) != "COPY" || step.FilesHash == "" {
			continue
		}

		s3Key := storage.BuildContextKey(templateID, step.FilesHash)
		tarPath := filepath.Join(contextDir, fmt.Sprintf("%s.tar.gz", step.FilesHash))

		zap.L().Info("Downloading build context file from S3",
			zap.String("templateID", templateID),
			zap.String("hash", step.FilesHash),
			zap.String("s3Key", s3Key))

		if err := presignSvc.DownloadToFile(ctx, s3Key, tarPath); err != nil {
			cleanup()
			return "", nil, fmt.Errorf("failed to download build context file '%s': %w", s3Key, err)
		}

		// Extract tar.gz into context directory
		if err := extractTarGz(tarPath, contextDir); err != nil {
			cleanup()
			return "", nil, fmt.Errorf("failed to extract build context file '%s': %w", tarPath, err)
		}

		// Remove the tar.gz after extraction
		os.Remove(tarPath)
	}

	// Generate Dockerfile
	dockerfile := GenerateDockerfile(baseImage, steps)
	dockerfilePath := filepath.Join(contextDir, "Dockerfile")
	if err := os.WriteFile(dockerfilePath, []byte(dockerfile), 0644); err != nil {
		cleanup()
		return "", nil, fmt.Errorf("failed to write Dockerfile: %w", err)
	}

	zap.L().Info("Prepared build context",
		zap.String("templateID", templateID),
		zap.String("contextDir", contextDir),
		zap.String("dockerfile", dockerfile))

	return contextDir, cleanup, nil
}

// BuildAndPushImage builds a Docker image from the context directory and pushes it to ECR.
func (g *AWSArtifactsRegistry) BuildAndPushImage(
	ctx context.Context,
	contextDir string,
	templateID string,
	buildID string,
) error {
	// 1. Ensure target ECR repository exists
	targetRepoName := fmt.Sprintf("%s/%s", g.repositoryName, templateID)
	if err := g.ensureRepository(ctx, targetRepoName); err != nil {
		return fmt.Errorf("failed to ensure target repository: %w", err)
	}

	// 2. Get target tag
	targetTag, err := g.GetTag(ctx, templateID, buildID)
	if err != nil {
		return fmt.Errorf("failed to get target tag: %w", err)
	}

	localTag := fmt.Sprintf("e2b-build/%s:%s", templateID, buildID)

	zap.L().Info("Building Docker image",
		zap.String("templateID", templateID),
		zap.String("buildID", buildID),
		zap.String("contextDir", contextDir),
		zap.String("targetTag", targetTag))

	// 3. Build using Docker daemon
	cmd := exec.CommandContext(ctx, "docker", "build", "-t", localTag, contextDir)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("docker build failed: %w\noutput: %s", err, string(output))
	}

	zap.L().Info("Docker build completed", zap.String("localTag", localTag))

	// 4. Load built image from daemon
	img, err := loadImageFromDaemon(ctx, localTag)
	if err != nil {
		return fmt.Errorf("failed to load built image from daemon: %w", err)
	}

	// 5. Push to ECR
	auth, err := g.getAuthToken(ctx)
	if err != nil {
		return fmt.Errorf("failed to get ECR auth token: %w", err)
	}

	dst, err := name.ParseReference(targetTag)
	if err != nil {
		return fmt.Errorf("failed to parse target reference '%s': %w", targetTag, err)
	}

	if err := remote.Write(dst, img, remote.WithAuth(auth)); err != nil {
		return fmt.Errorf("failed to push image to '%s': %w", targetTag, err)
	}

	// 6. Clean up local image
	cleanupLocalImage(localTag)

	zap.L().Info("Successfully built and pushed Docker image",
		zap.String("templateID", templateID),
		zap.String("buildID", buildID),
		zap.String("targetTag", targetTag))

	return nil
}

// loadImageFromDaemon loads an image from the Docker daemon.
// It first tries the daemon package, then falls back to saving and loading via tarball.
func loadImageFromDaemon(ctx context.Context, tag string) (containerregistry.Image, error) {
	ref, err := name.NewTag(tag)
	if err != nil {
		return nil, fmt.Errorf("failed to parse image tag '%s': %w", tag, err)
	}

	img, err := daemon.Image(ref)
	if err == nil {
		return img, nil
	}

	zap.L().Warn("Failed to load image from daemon directly, falling back to tarball",
		zap.String("tag", tag), zap.Error(err))

	// Fallback: save to tarball and load
	tmpFile, err := os.CreateTemp("", "docker-image-*.tar")
	if err != nil {
		return nil, fmt.Errorf("failed to create temp file for image export: %w", err)
	}
	defer os.Remove(tmpFile.Name())
	tmpFile.Close()

	cmd := exec.CommandContext(ctx, "docker", "save", "-o", tmpFile.Name(), tag)
	if output, err := cmd.CombinedOutput(); err != nil {
		return nil, fmt.Errorf("docker save failed: %w\noutput: %s", err, string(output))
	}

	img, err = tarball.ImageFromPath(tmpFile.Name(), &ref)
	if err != nil {
		return nil, fmt.Errorf("failed to load image from tarball: %w", err)
	}

	return img, nil
}

// cleanupLocalImage removes a local Docker image.
func cleanupLocalImage(tag string) {
	cmd := exec.Command("docker", "rmi", tag)
	if output, err := cmd.CombinedOutput(); err != nil {
		zap.L().Warn("Failed to remove local Docker image",
			zap.String("tag", tag),
			zap.Error(err),
			zap.String("output", string(output)))
	}
}

// extractTarGz extracts a .tar.gz file into the destination directory.
func extractTarGz(tarGzPath string, destDir string) error {
	file, err := os.Open(tarGzPath)
	if err != nil {
		return fmt.Errorf("failed to open tar.gz file: %w", err)
	}
	defer file.Close()

	gzReader, err := gzip.NewReader(file)
	if err != nil {
		return fmt.Errorf("failed to create gzip reader: %w", err)
	}
	defer gzReader.Close()

	tarReader := tar.NewReader(gzReader)

	for {
		header, err := tarReader.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return fmt.Errorf("error reading tar: %w", err)
		}

		// Prevent path traversal attacks
		targetPath := filepath.Join(destDir, header.Name)
		relPath, relErr := filepath.Rel(destDir, targetPath)
		if relErr != nil || strings.HasPrefix(relPath, "..") || filepath.IsAbs(relPath) {
			return fmt.Errorf("invalid file path in archive: %s", header.Name)
		}

		switch header.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(targetPath, 0755); err != nil {
				return fmt.Errorf("failed to create directory '%s': %w", targetPath, err)
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(targetPath), 0755); err != nil {
				return fmt.Errorf("failed to create parent directory for '%s': %w", targetPath, err)
			}
			if err := extractFile(targetPath, tarReader); err != nil {
				return err
			}
		}
	}

	return nil
}

// extractFile extracts a single file from a tar reader to the given path.
func extractFile(targetPath string, r io.Reader) error {
	outFile, err := os.Create(targetPath)
	if err != nil {
		return fmt.Errorf("failed to create file '%s': %w", targetPath, err)
	}
	defer outFile.Close()

	// Limit copy size to prevent decompression bombs (1GB max per file)
	if _, err := io.Copy(outFile, io.LimitReader(r, 1<<30)); err != nil {
		return fmt.Errorf("failed to extract file '%s': %w", targetPath, err)
	}

	return nil
}
