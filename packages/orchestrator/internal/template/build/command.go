package build

import (
	"context"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"connectrpc.com/connect"
	"go.uber.org/zap"

	"github.com/e2b-dev/infra/packages/orchestrator/internal/template/build/writer"
	"github.com/e2b-dev/infra/packages/shared/pkg/grpc"
	"github.com/e2b-dev/infra/packages/shared/pkg/grpc/envd/process"
	"github.com/e2b-dev/infra/packages/shared/pkg/grpc/envd/process/processconnect"
	templatemanager "github.com/e2b-dev/infra/packages/shared/pkg/grpc/template-manager"
	"github.com/e2b-dev/infra/packages/shared/pkg/storage"
)

const httpTimeout = 600 * time.Second

func (b *TemplateBuilder) runCommand(
	ctx context.Context,
	postProcessor *writer.PostProcessor,
	id string,
	sandboxID string,
	command string,
	runAsUser string,
	cwd *string,
	envVars map[string]string,
) error {
	return b.runCommandWithConfirmation(
		ctx,
		postProcessor,
		id,
		sandboxID,
		command,
		runAsUser,
		cwd,
		envVars,
		// No confirmation needed for this command
		make(chan struct{}),
	)
}

func (b *TemplateBuilder) runCommandWithConfirmation(
	ctx context.Context,
	postProcessor *writer.PostProcessor,
	id string,
	sandboxID string,
	command string,
	runAsUser string,
	cwd *string,
	envVars map[string]string,
	confirmCh chan<- struct{},
) error {
	runCmdReq := connect.NewRequest(&process.StartRequest{
		Process: &process.ProcessConfig{
			Cmd: "/bin/bash",
			Cwd: cwd,
			Args: []string{
				"-l", "-c", command,
			},
			Envs: envVars,
		},
	})

	hc := http.Client{
		Timeout: httpTimeout,
	}
	proxyHost := fmt.Sprintf("http://localhost%s", b.proxy.GetAddr())
	processC := processconnect.NewProcessClient(&hc, proxyHost)
	err := grpc.SetSandboxHeader(runCmdReq.Header(), proxyHost, sandboxID)
	if err != nil {
		return fmt.Errorf("failed to set sandbox header: %w", err)
	}
	grpc.SetUserHeader(runCmdReq.Header(), runAsUser)

	processCtx, processCancel := context.WithCancel(ctx)
	defer processCancel()
	commandStream, err := processC.Start(processCtx, runCmdReq)
	// Confirm the command has executed before proceeding
	close(confirmCh)
	if err != nil {
		return fmt.Errorf("error starting process: %w", err)
	}
	defer func() {
		processCancel()
		commandStream.Close()
	}()

	msgCh, msgErrCh := grpc.StreamToChannel(ctx, commandStream)

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case err := <-msgErrCh:
			return err
		case msg, ok := <-msgCh:
			if !ok {
				return nil
			}
			e := msg.Event
			if e == nil {
				zap.L().Error("received nil command event")
				return nil
			}

			switch {
			case e.GetData() != nil:
				data := e.GetData()
				b.logStream(postProcessor, id, "stdout", string(data.GetStdout()))
				b.logStream(postProcessor, id, "stderr", string(data.GetStderr()))

			case e.GetEnd() != nil:
				end := e.GetEnd()
				name := fmt.Sprintf("exit %d", end.GetExitCode())
				b.logStream(postProcessor, id, name, end.GetStatus())

				if end.GetExitCode() != 0 {
					return fmt.Errorf("command failed: %s", end.GetStatus())
				}
			}
		}
	}
}

// copyFilesToSandbox downloads build-context files from S3 and copies them into the sandbox via envd.
// The files are identified by step.FilesHash which corresponds to a tar archive in the build-context bucket.
func (b *TemplateBuilder) copyFilesToSandbox(ctx context.Context, postProcessor *writer.PostProcessor, sandboxID string, templateID string, step *templatemanager.TemplateStep, cwd *string) error {
	if step.FilesHash == nil || step.GetFilesHash() == "" {
		return fmt.Errorf("COPY/ADD requires filesHash to be set")
	}

	if len(step.Args) < 2 {
		return fmt.Errorf("COPY/ADD requires source and destination arguments")
	}

	targetPath := step.Args[1]
	if !strings.HasPrefix(targetPath, "/") && cwd != nil {
		targetPath = *cwd + "/" + targetPath
	}

	// Download the tar archive from the dedicated build-context bucket (API presign upload target).
	// Key format must match the upload side (packages/shared/pkg/storage/presign.go:BuildContextKey).
	if b.buildContextStorage == nil {
		return fmt.Errorf("build-context storage is not configured (BUILD_CONTEXT_BUCKET_NAME unset)")
	}
	filesKey := storage.BuildContextKey(templateID, step.GetFilesHash())
	obj, err := b.buildContextStorage.OpenObject(ctx, filesKey)
	if err != nil {
		return fmt.Errorf("failed to open build-context files from storage (key=%s): %w", filesKey, err)
	}

	tmpFile, err := os.CreateTemp("", "layer-file-*.tar.gz")
	if err != nil {
		return fmt.Errorf("failed to create temp file for layer tar: %w", err)
	}
	defer os.Remove(tmpFile.Name())
	defer tmpFile.Close()

	if _, err := obj.WriteTo(tmpFile); err != nil {
		return fmt.Errorf("failed to download build-context files: %w", err)
	}
	// Seek back to beginning for upload
	tmpFile.Seek(0, 0)

	// Upload to sandbox /tmp and extract
	sbxTarPath := fmt.Sprintf("/tmp/%s.tar.gz", step.GetFilesHash())
	sbxUnpackPath := fmt.Sprintf("/tmp/%s/unpack", step.GetFilesHash())

	// Use envd file upload to copy tar into sandbox. The /files endpoint requires
	// multipart/form-data, so stream the tar as a multipart body via io.Pipe.
	proxyHost := fmt.Sprintf("http://localhost%s", b.proxy.GetAddr())
	uploadURL := fmt.Sprintf("%s/files?path=%s&username=root", proxyHost, sbxTarPath)

	pr, pw := io.Pipe()
	mw := multipart.NewWriter(pw)
	uploadErrCh := make(chan error, 1)
	go func() {
		var writeErr error
		defer func() {
			if closeErr := mw.Close(); closeErr != nil && writeErr == nil {
				writeErr = closeErr
			}
			pw.CloseWithError(writeErr)
			uploadErrCh <- writeErr
		}()

		formFile, err := mw.CreateFormFile("file", filepath.Base(sbxTarPath))
		if err != nil {
			writeErr = fmt.Errorf("create multipart form file: %w", err)
			return
		}
		if _, err := io.Copy(formFile, tmpFile); err != nil {
			writeErr = fmt.Errorf("copy tar into multipart body: %w", err)
			return
		}
	}()

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, uploadURL, pr)
	if err != nil {
		return fmt.Errorf("failed to create upload request: %w", err)
	}
	req.Header.Set("Content-Type", mw.FormDataContentType())
	if err := grpc.SetSandboxHeader(req.Header, proxyHost, sandboxID); err != nil {
		return fmt.Errorf("failed to set sandbox header: %w", err)
	}
	req.Host = req.Header.Get("Host")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("failed to upload file to sandbox: %w", err)
	}
	defer resp.Body.Close()

	if writeErr := <-uploadErrCh; writeErr != nil {
		return fmt.Errorf("failed to build multipart upload body: %w", writeErr)
	}

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("failed to upload file to sandbox (status %d)", resp.StatusCode)
	}

	// Extract and move files inside sandbox following Docker COPY semantics:
	// 1. Find the "content root" by drilling through single-entry parent directories
	//    (strips tar packaging directories like shims/ when COPY shims/file.py ...)
	// 2. Single file + target not ending with / → copy as file
	// 3. Otherwise → copy directory contents into target directory
	extractCmd := fmt.Sprintf(
		`mkdir -p "%s" && tar -xzf "%s" -C "%s" && `+
			`CONTENT_ROOT="%s" && `+
			`while [ $(ls -1 "$CONTENT_ROOT" | wc -l) -eq 1 ] && [ -d "$CONTENT_ROOT/$(ls -1 "$CONTENT_ROOT")" ]; do `+
			`CONTENT_ROOT="$CONTENT_ROOT/$(ls -1 "$CONTENT_ROOT")"; `+
			`done && `+
			`FILE_COUNT=$(find "$CONTENT_ROOT" -maxdepth 1 -type f | wc -l) && `+
			`DIR_COUNT=$(find "$CONTENT_ROOT" -maxdepth 1 -type d -not -path "$CONTENT_ROOT" | wc -l) && `+
			`if [ "$FILE_COUNT" -eq 1 ] && [ "$DIR_COUNT" -eq 0 ] && echo "%s" | grep -qv '/$'; then `+
			`SRC_FILE=$(find "$CONTENT_ROOT" -maxdepth 1 -type f) && mkdir -p "$(dirname "%s")" && cp "$SRC_FILE" "%s"; `+
			`else `+
			`mkdir -p "%s" && cp -r "$CONTENT_ROOT"/* "%s"/ 2>/dev/null || cp -r "$CONTENT_ROOT"/* "%s" 2>/dev/null; `+
			`fi; rm -rf "/tmp/%s"`,
		sbxUnpackPath, sbxTarPath, sbxUnpackPath,
		sbxUnpackPath,
		targetPath,
		targetPath, targetPath,
		targetPath, targetPath, targetPath,
		step.GetFilesHash())

	return b.runCommand(ctx, postProcessor, "copy", sandboxID, extractCmd, "root", nil, map[string]string{})
}

func (b *TemplateBuilder) logStream(postProcessor *writer.PostProcessor, id string, name string, content string) {
	if content == "" {
		return
	}
	for _, line := range strings.Split(content, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		msg := fmt.Sprintf("[%s] [%s]: %s", id, name, line)
		postProcessor.WriteMsg(msg)
		b.buildLogger.Info(msg)
	}
}
