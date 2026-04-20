package artifacts_registry

import (
	"archive/tar"
	"bufio"
	"compress/gzip"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"

	"github.com/google/go-containerregistry/pkg/authn"
	"github.com/google/go-containerregistry/pkg/name"
	"go.uber.org/zap"

	"github.com/e2b-dev/infra/packages/shared/pkg/storage"
)

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

	// Download and extract COPY step files from S3 in parallel
	var wg sync.WaitGroup
	var mu sync.Mutex
	var firstErr error

	for _, step := range steps {
		if strings.ToUpper(step.Type) != "COPY" || step.FilesHash == "" {
			continue
		}
		wg.Add(1)
		go func(s TemplateBuildStep) {
			defer wg.Done()

			s3Key := storage.BuildContextKey(templateID, s.FilesHash)
			tarPath := filepath.Join(contextDir, fmt.Sprintf("%s.tar.gz", s.FilesHash))

			zap.L().Info("Downloading build context file from S3",
				zap.String("templateID", templateID),
				zap.String("hash", s.FilesHash),
				zap.String("s3Key", s3Key))

			if err := presignSvc.DownloadToFile(ctx, s3Key, tarPath); err != nil {
				mu.Lock()
				if firstErr == nil {
					firstErr = fmt.Errorf("failed to download build context file '%s': %w", s3Key, err)
				}
				mu.Unlock()
				return
			}

			// Extract tar.gz into context directory
			if err := extractTarGz(tarPath, contextDir); err != nil {
				mu.Lock()
				if firstErr == nil {
					firstErr = fmt.Errorf("failed to extract build context file '%s': %w", tarPath, err)
				}
				mu.Unlock()
				return
			}

			// Remove the tar.gz after extraction
			os.Remove(tarPath)
		}(step)
	}

	wg.Wait()
	if firstErr != nil {
		cleanup()
		return "", nil, firstErr
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

	// 3. Try to pull previous build image for cache
	cacheFrom := g.pullCacheImage(ctx, templateID)

	// 4. Build using Docker daemon with cache-from + streaming output
	buildArgs := []string{"build"}
	if cacheFrom != "" {
		buildArgs = append(buildArgs, "--cache-from", cacheFrom)
	}
	buildArgs = append(buildArgs, "-t", localTag, contextDir)

	cmd := exec.CommandContext(ctx, "docker", buildArgs...)
	// Explicitly disable BuildKit — the API container only has docker-cli without buildx
	cmd.Env = append(os.Environ(), "DOCKER_BUILDKIT=0")

	if err := runCmdWithStreamingLogs(cmd, templateID, "docker build"); err != nil {
		return fmt.Errorf("docker build failed: %w", err)
	}

	zap.L().Info("Docker build completed", zap.String("localTag", localTag))

	// 5. Tag and push to ECR using docker CLI
	if err := g.tagAndPush(ctx, localTag, targetTag, templateID); err != nil {
		return err
	}

	// 6. Clean up old local images for this template, keep the latest
	cleanupOldImages(templateID, localTag)

	zap.L().Info("Successfully built and pushed Docker image",
		zap.String("templateID", templateID),
		zap.String("buildID", buildID),
		zap.String("targetTag", targetTag))

	return nil
}

// pullCacheImage attempts to pull the latest image for a template from ECR
// to use as Docker build cache. Returns the image tag on success, empty string on failure.
func (g *AWSArtifactsRegistry) pullCacheImage(ctx context.Context, templateID string) string {
	latestTag, err := g.getLatestImageTag(ctx, templateID)
	if err != nil || latestTag == "" {
		zap.L().Debug("No previous image found for cache",
			zap.String("templateID", templateID), zap.Error(err))
		return ""
	}

	// Check if the image already exists locally
	checkCmd := exec.CommandContext(ctx, "docker", "image", "inspect", latestTag)
	if checkCmd.Run() == nil {
		zap.L().Info("Cache image already exists locally", zap.String("tag", latestTag))
		return latestTag
	}

	// Write temporary Docker config with ECR credentials for pull
	auth, err := g.getAuthToken(ctx)
	if err != nil {
		zap.L().Warn("Failed to get ECR auth for cache pull", zap.Error(err))
		return ""
	}

	configDir, err := writeTempDockerConfig(templateID, auth, latestTag)
	if err != nil {
		zap.L().Warn("Failed to write temp docker config", zap.Error(err))
		return ""
	}
	defer os.RemoveAll(configDir)

	zap.L().Info("Pulling cache image from ECR", zap.String("tag", latestTag))
	pullCmd := exec.CommandContext(ctx, "docker", "--config", configDir, "pull", latestTag)
	if output, pullErr := pullCmd.CombinedOutput(); pullErr != nil {
		zap.L().Warn("Failed to pull cache image, building without cache",
			zap.String("tag", latestTag),
			zap.Error(pullErr),
			zap.String("output", string(output)))
		return ""
	}

	zap.L().Info("Pulled cache image successfully", zap.String("tag", latestTag))
	return latestTag
}

// writeTempDockerConfig creates a temporary Docker config directory with ECR credentials.
// Returns the config directory path. Caller must clean up.
func writeTempDockerConfig(templateID string, auth *authn.Basic, imageRef string) (string, error) {
	configDir, err := os.MkdirTemp("", fmt.Sprintf("docker-cfg-%s-*", templateID))
	if err != nil {
		return "", err
	}

	// Extract registry host from image reference
	ref, err := name.ParseReference(imageRef)
	if err != nil {
		os.RemoveAll(configDir)
		return "", err
	}
	registryHost := ref.Context().RegistryStr()

	configData := map[string]interface{}{
		"auths": map[string]interface{}{
			registryHost: map[string]string{
				"username": auth.Username,
				"password": auth.Password,
			},
		},
	}

	data, err := json.Marshal(configData)
	if err != nil {
		os.RemoveAll(configDir)
		return "", err
	}

	if err := os.WriteFile(filepath.Join(configDir, "config.json"), data, 0600); err != nil {
		os.RemoveAll(configDir)
		return "", err
	}

	return configDir, nil
}

// tagAndPush tags the local image and pushes it to ECR using docker CLI.
func (g *AWSArtifactsRegistry) tagAndPush(ctx context.Context, localTag, targetTag, templateID string) error {
	// Tag
	tagCmd := exec.CommandContext(ctx, "docker", "tag", localTag, targetTag)
	if output, err := tagCmd.CombinedOutput(); err != nil {
		return fmt.Errorf("docker tag failed: %w\noutput: %s", err, string(output))
	}

	// Login to ECR
	auth, err := g.getAuthToken(ctx)
	if err != nil {
		return fmt.Errorf("failed to get ECR auth token for push: %w", err)
	}

	ref, err := name.ParseReference(targetTag)
	if err != nil {
		return fmt.Errorf("failed to parse target reference '%s': %w", targetTag, err)
	}
	registryHost := ref.Context().RegistryStr()

	loginCmd := exec.CommandContext(ctx, "docker", "login",
		"--username", auth.Username, "--password-stdin", registryHost)
	loginCmd.Stdin = strings.NewReader(auth.Password)
	if output, err := loginCmd.CombinedOutput(); err != nil {
		return fmt.Errorf("docker login failed: %w\noutput: %s", err, string(output))
	}

	// Push with streaming logs
	zap.L().Info("Pushing image to ECR", zap.String("targetTag", targetTag))
	pushCmd := exec.CommandContext(ctx, "docker", "push", targetTag)
	if err := runCmdWithStreamingLogs(pushCmd, templateID, "docker push"); err != nil {
		return fmt.Errorf("docker push failed: %w", err)
	}

	zap.L().Info("Image pushed to ECR successfully", zap.String("targetTag", targetTag))
	return nil
}

// runCmdWithStreamingLogs runs a command and streams its stdout/stderr to zap logger.
// On failure, the error includes the last lines of output for diagnostics.
func runCmdWithStreamingLogs(cmd *exec.Cmd, templateID, cmdName string) error {
	// Use io.Pipe to merge stdout and stderr into a single reader
	pr, pw := io.Pipe()
	cmd.Stdout = pw
	cmd.Stderr = pw

	if err := cmd.Start(); err != nil {
		pw.Close()
		return fmt.Errorf("%s start failed: %w", cmdName, err)
	}

	// Keep last N lines for error reporting
	const tailSize = 30
	tailLines := make([]string, 0, tailSize)

	scanner := bufio.NewScanner(pr)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	// Read output in a goroutine since we need to close the writer after Wait()
	scanDone := make(chan struct{})
	go func() {
		defer close(scanDone)
		for scanner.Scan() {
			line := scanner.Text()
			zap.L().Info(cmdName,
				zap.String("templateID", templateID),
				zap.String("output", line))
			if len(tailLines) >= tailSize {
				tailLines = tailLines[1:]
			}
			tailLines = append(tailLines, line)
		}
	}()

	err := cmd.Wait()
	pw.Close() // signal EOF to scanner
	<-scanDone // wait for scanner to finish

	if err != nil {
		tail := strings.Join(tailLines, "\n")
		return fmt.Errorf("%s: %w\noutput (last %d lines):\n%s", cmdName, err, len(tailLines), tail)
	}

	return nil
}

// cleanupOldImages removes old Docker images for a template, keeping the latest one.
func cleanupOldImages(templateID, keepTag string) {
	repoFilter := fmt.Sprintf("e2b-build/%s", templateID)
	cmd := exec.Command("docker", "images", "--format", "{{.Repository}}:{{.Tag}}", repoFilter)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return
	}

	for _, tag := range strings.Split(strings.TrimSpace(string(output)), "\n") {
		if tag != "" && tag != keepTag {
			rmiCmd := exec.Command("docker", "rmi", tag)
			if rmiOut, rmiErr := rmiCmd.CombinedOutput(); rmiErr != nil {
				zap.L().Warn("Failed to remove old Docker image",
					zap.String("tag", tag),
					zap.Error(rmiErr),
					zap.String("output", string(rmiOut)))
			}
		}
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
