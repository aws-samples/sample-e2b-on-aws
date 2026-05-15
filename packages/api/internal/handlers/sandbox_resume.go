package handlers

import (
	"database/sql"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"go.opentelemetry.io/otel/trace"
	"go.uber.org/zap"

	"github.com/e2b-dev/infra/packages/api/internal/api"
	"github.com/e2b-dev/infra/packages/api/internal/auth"
	authcache "github.com/e2b-dev/infra/packages/api/internal/cache/auth"
	"github.com/e2b-dev/infra/packages/api/internal/cache/instance"
	resumetiming "github.com/e2b-dev/infra/packages/api/internal/timing"
	"github.com/e2b-dev/infra/packages/api/internal/utils"
	"github.com/e2b-dev/infra/packages/db/queries"
	"github.com/e2b-dev/infra/packages/shared/pkg/logger"
	sbxlogger "github.com/e2b-dev/infra/packages/shared/pkg/logger/sandbox"
	"github.com/e2b-dev/infra/packages/shared/pkg/telemetry"
)

func getSandboxIDClient(sandboxID string) (string, bool) {
	parts := strings.Split(sandboxID, "-")
	if len(parts) != 2 {
		return "", false
	}

	return parts[1], true
}

func resolveResumeClientID(requestedClientID string, pausedNodeID, snapshotOriginNodeID *string) *string {
	if pausedNodeID != nil && *pausedNodeID != "" {
		return pausedNodeID
	}

	if snapshotOriginNodeID != nil && *snapshotOriginNodeID != "" {
		return snapshotOriginNodeID
	}

	if requestedClientID != "" {
		return &requestedClientID
	}

	return nil
}

func (a *APIStore) PostSandboxesSandboxIDResume(c *gin.Context, sandboxID api.SandboxID) {
	handlerStart := time.Now()
	ctx := c.Request.Context()

	// Get team from context, use TeamContextKey
	teamInfo := c.Value(auth.TeamContextKey).(authcache.AuthTeamInfo)

	span := trace.SpanFromContext(ctx)
	traceID := span.SpanContext().TraceID().String()
	c.Set("traceID", traceID)

	resumetiming.Log("api_resume_request_received",
		logger.WithSandboxID(string(sandboxID)),
		zap.String("trace_id", traceID),
	)

	telemetry.ReportEvent(ctx, "Parsed body")

	parseStart := time.Now()
	body, err := utils.ParseBody[api.PostSandboxesSandboxIDResumeJSONRequestBody](ctx, c)
	resumetiming.Log("api_resume_body_parsed",
		logger.WithSandboxID(string(sandboxID)),
		zap.Duration("duration", time.Since(parseStart)),
		zap.Error(err),
	)
	if err != nil {
		a.sendAPIStoreError(c, http.StatusBadRequest, fmt.Sprintf("Error when parsing request: %s", err))

		telemetry.ReportCriticalError(ctx, "error when parsing request", err)

		return
	}

	timeout := instance.InstanceExpiration
	if body.Timeout != nil {
		timeout = time.Duration(*body.Timeout) * time.Second

		if timeout > time.Duration(teamInfo.Tier.MaxLengthHours)*time.Hour {
			a.sendAPIStoreError(c, http.StatusBadRequest, fmt.Sprintf("Timeout cannot be greater than %d hours", teamInfo.Tier.MaxLengthHours))

			return
		}
	}

	autoPause := instance.InstanceAutoPauseDefault
	if body.AutoPause != nil {
		autoPause = *body.AutoPause
	}

	requestedClientID, _ := getSandboxIDClient(sandboxID)
	sandboxID = utils.ShortID(sandboxID)
	resumetiming.Log("api_resume_short_id_resolved",
		logger.WithSandboxID(sandboxID),
		zap.String("requested_client_id", requestedClientID),
	)

	cacheLookupStart := time.Now()
	sbxCache, err := a.orchestrator.GetSandbox(sandboxID)
	resumetiming.Log("api_resume_running_cache_lookup_done",
		logger.WithSandboxID(sandboxID),
		zap.Duration("duration", time.Since(cacheLookupStart)),
		zap.Error(err),
	)
	if err == nil {
		zap.L().Debug("Sandbox is already running",
			logger.WithSandboxID(sandboxID),
			zap.Time("end_time", sbxCache.GetEndTime()),
			zap.Bool("auto_pause", sbxCache.AutoPause.Load()),
			zap.Time("start_time", sbxCache.StartTime),
			zap.String("node_id", sbxCache.Node.ID),
		)
		a.sendAPIStoreError(c, http.StatusConflict, fmt.Sprintf("Sandbox %s is already running", sandboxID))

		return
	}

	// Wait for any pausing for this sandbox in progress.
	waitPauseStart := time.Now()
	pausedOnNode, err := a.orchestrator.WaitForPause(ctx, sandboxID)
	resumetiming.Log("api_resume_wait_for_pause_done",
		logger.WithSandboxID(sandboxID),
		zap.Duration("duration", time.Since(waitPauseStart)),
		zap.Error(err),
	)
	if err != nil && !errors.Is(err, instance.ErrPausingInstanceNotFound) {
		a.sendAPIStoreError(c, http.StatusInternalServerError, fmt.Sprintf("Error while pausing sandbox %s: %s", sandboxID, err))

		return
	}

	var pausedNodeID *string
	if err == nil {
		// If the pausing was in progress, prefer to restore on the node where the pausing happened.
		pausedNodeID = &pausedOnNode.ID
	}

	lastSnapshotStart := time.Now()
	lastSnapshot, err := a.sqlcDB.GetLastSnapshot(ctx, queries.GetLastSnapshotParams{SandboxID: sandboxID, TeamID: teamInfo.Team.ID})
	resumetiming.Log("api_resume_last_snapshot_lookup_done",
		logger.WithSandboxID(sandboxID),
		zap.Duration("duration", time.Since(lastSnapshotStart)),
		zap.Error(err),
	)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			zap.L().Debug("Snapshot not found", logger.WithSandboxID(sandboxID))
			a.sendAPIStoreError(c, http.StatusNotFound, "Sandbox snapshot not found")
			return
		}

		zap.L().Error("Error getting last snapshot", logger.WithSandboxID(sandboxID), zap.Error(err))
		a.sendAPIStoreError(c, http.StatusInternalServerError, "Error when getting snapshot")
		return
	}

	snap := lastSnapshot.Snapshot
	build := lastSnapshot.EnvBuild

	alias := ""
	if len(lastSnapshot.Aliases) > 0 {
		alias = lastSnapshot.Aliases[0]
	}

	sbxlogger.E(&sbxlogger.SandboxMetadata{
		SandboxID:  sandboxID,
		TemplateID: *build.EnvID,
		TeamID:     teamInfo.Team.ID.String(),
	}).Debug("Started resuming sandbox")

	var envdAccessToken *string = nil
	if snap.EnvSecure {
		tokenStart := time.Now()
		accessToken, tokenErr := a.getEnvdAccessToken(build.EnvdVersion, sandboxID)
		resumetiming.Log("api_resume_envd_token_done",
			logger.WithSandboxID(sandboxID),
			zap.Duration("duration", time.Since(tokenStart)),
			zap.Bool("ok", tokenErr == nil),
		)
		if tokenErr != nil {
			zap.L().Error("Secure envd access token error", zap.Error(tokenErr.Err), logger.WithTemplateID(*build.EnvID), logger.WithBuildID(build.ID.String()))
			a.sendAPIStoreError(c, tokenErr.Code, tokenErr.ClientMsg)
			return
		}

		envdAccessToken = &accessToken
	}

	clientIDPtr := resolveResumeClientID(requestedClientID, pausedNodeID, snap.OriginNodeID)
	resumetiming.Log("api_resume_preferred_node_resolved",
		logger.WithSandboxID(sandboxID),
		zap.String("requested_client_id", requestedClientID),
		zap.Stringp("paused_node_id", pausedNodeID),
		zap.Stringp("snapshot_origin_node_id", snap.OriginNodeID),
		zap.Stringp("preferred_client_id", clientIDPtr),
	)

	startSandboxStart := time.Now()
	sbx, createErr := a.startSandbox(
		ctx,
		snap.SandboxID,
		timeout,
		nil,
		snap.Metadata,
		alias,
		teamInfo,
		build,
		&c.Request.Header,
		true,
		clientIDPtr,
		snap.BaseEnvID,
		autoPause,
		envdAccessToken,
	)
	resumetiming.Log("api_resume_start_sandbox_done",
		logger.WithSandboxID(sandboxID),
		zap.Duration("duration", time.Since(startSandboxStart)),
		zap.Duration("handler_duration", time.Since(handlerStart)),
		zap.Bool("ok", createErr == nil),
	)

	if createErr != nil {
		zap.L().Error("Failed to resume sandbox", zap.Error(createErr.Err))
		a.sendAPIStoreError(c, createErr.Code, createErr.ClientMsg)

		return
	}

	c.JSON(http.StatusCreated, &sbx)
}
