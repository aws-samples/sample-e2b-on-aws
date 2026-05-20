package sandbox

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"go.opentelemetry.io/otel/trace"
	"go.uber.org/zap"

	"github.com/e2b-dev/infra/packages/orchestrator/internal/sandbox/lifecycle"
	"github.com/e2b-dev/infra/packages/shared/pkg/consts"
	"github.com/e2b-dev/infra/packages/shared/pkg/logger"
)

const (
	requestTimeout = 50 * time.Millisecond
	loopDelay      = 5 * time.Millisecond
)

// doRequestWithInfiniteRetries does a request with infinite retries until the context is done.
// The parent context should have a deadline or a timeout.
func doRequestWithInfiniteRetries(ctx context.Context, method, address, sandboxID string, requestBody []byte, accessToken *string) (*http.Response, int, error) {
	requestStart := time.Now()
	attempt := 0

	for {
		attempt++
		reqCtx, cancel := context.WithTimeout(ctx, requestTimeout)
		request, err := http.NewRequestWithContext(reqCtx, method, address, bytes.NewReader(requestBody))
		if err != nil {
			cancel()
			return nil, attempt, err
		}

		// make sure request to already authorized envd will not fail
		// this can happen in sandbox resume and in some edge cases when previous request was success, but we continued
		if accessToken != nil {
			request.Header.Set("X-Access-Token", *accessToken)
		}

		attemptStart := time.Now()
		response, err := httpClient.Do(request)
		attemptDuration := time.Since(attemptStart)
		cancel()

		if err == nil {
			logResumeTiming("envd_init_attempt_success",
				logger.WithSandboxID(sandboxID),
				zap.Int("attempt", attempt),
				zap.String("method", method),
				zap.Duration("attempt_duration", attemptDuration),
				zap.Duration("total_duration", time.Since(requestStart)),
				zap.Int("status_code", response.StatusCode),
			)

			return response, attempt, nil
		}

		if resumeTimingDebug && (attempt == 1 || attempt%20 == 0 || attemptDuration >= requestTimeout) {
			logResumeTiming("envd_init_attempt_failed",
				logger.WithSandboxID(sandboxID),
				zap.Int("attempt", attempt),
				zap.String("method", method),
				zap.Duration("attempt_duration", attemptDuration),
				zap.Duration("total_duration", time.Since(requestStart)),
				zap.Error(err),
			)
		}

		select {
		case <-ctx.Done():
			logResumeTiming("envd_init_attempts_context_done",
				logger.WithSandboxID(sandboxID),
				zap.Int("attempts", attempt),
				zap.Duration("total_duration", time.Since(requestStart)),
				zap.Error(err),
				zap.Error(context.Cause(ctx)),
			)

			return nil, attempt, fmt.Errorf("%w with cause: %w", ctx.Err(), context.Cause(ctx))
		case <-time.After(loopDelay):
		}
	}
}

type PostInitJSONBody struct {
	EnvVars     *map[string]string `json:"envVars"`
	AccessToken *string            `json:"accessToken,omitempty"`
}

type envdInitStats struct {
	Attempts            int
	Duration            time.Duration
	BodyDiscardDuration time.Duration
	StatusCode          int
}

func (s *Sandbox) initEnvd(ctx context.Context, tracer trace.Tracer, envVars map[string]string, accessToken *string) (*envdInitStats, error) {
	childCtx, childSpan := tracer.Start(ctx, "envd-init")
	defer childSpan.End()

	initStart := time.Now()
	stats := &envdInitStats{}
	address := fmt.Sprintf("http://%s:%d/init", s.Slot.HostIPString(), consts.DefaultEnvdServerPort)
	jsonBody := &PostInitJSONBody{
		EnvVars:     &envVars,
		AccessToken: accessToken,
	}

	logResumeTiming("envd_init_start",
		logger.WithSandboxID(s.Metadata.Config.SandboxId),
		zap.String("address", address),
		zap.Int("env_count", len(envVars)),
		zap.Bool("has_access_token", accessToken != nil),
	)

	body, err := json.Marshal(jsonBody)
	if err != nil {
		stats.Duration = time.Since(initStart)
		return stats, err
	}

	response, attempts, err := doRequestWithInfiniteRetries(childCtx, "POST", address, s.Metadata.Config.SandboxId, body, accessToken)
	stats.Attempts = attempts
	stats.Duration = time.Since(initStart)
	if err != nil {
		logResumeTiming("envd_init_failed",
			logger.WithSandboxID(s.Metadata.Config.SandboxId),
			zap.Int("attempts", attempts),
			zap.Duration("duration", time.Since(initStart)),
			zap.Error(err),
		)

		return stats, fmt.Errorf("failed to init envd: %w", err)
	}

	defer response.Body.Close()
	stats.StatusCode = response.StatusCode
	if response.StatusCode != http.StatusNoContent {
		logResumeTiming("envd_init_unexpected_status",
			logger.WithSandboxID(s.Metadata.Config.SandboxId),
			zap.Int("attempts", attempts),
			zap.Int("status_code", response.StatusCode),
			zap.Duration("duration", time.Since(initStart)),
		)

		stats.Duration = time.Since(initStart)
		return stats, fmt.Errorf("unexpected status code: %d", response.StatusCode)
	}

	bodyDiscardStart := time.Now()
	_, err = io.Copy(io.Discard, response.Body)
	stats.BodyDiscardDuration = time.Since(bodyDiscardStart)
	stats.Duration = time.Since(initStart)
	if err != nil {
		return stats, err
	}

	logResumeTiming("envd_init_done",
		logger.WithSandboxID(s.Metadata.Config.SandboxId),
		zap.Int("attempts", attempts),
		zap.Duration("body_discard_duration", stats.BodyDiscardDuration),
		zap.Duration("duration", stats.Duration),
	)

	return stats, nil
}

func (s *Sandbox) recordEnvdInit(ctx context.Context, operation string, stats *envdInitStats, err error) {
	if stats == nil {
		stats = &envdInitStats{}
	}

	lifecycle.RecordEnvdInit(ctx, operation, stats.Attempts, stats.Duration, err)
	zap.L().Info("envd init summary",
		logger.WithSandboxID(s.Metadata.Config.SandboxId),
		zap.String("operation", operation),
		zap.Int("attempts", stats.Attempts),
		zap.Int("status_code", stats.StatusCode),
		zap.Duration("duration", stats.Duration),
		zap.Duration("body_discard_duration", stats.BodyDiscardDuration),
		zap.Error(err),
	)
}
