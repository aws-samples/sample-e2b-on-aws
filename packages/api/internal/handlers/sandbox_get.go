package handlers

import (
	"fmt"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
	"go.uber.org/zap"

	"github.com/e2b-dev/infra/packages/api/internal/api"
	"github.com/e2b-dev/infra/packages/api/internal/auth"
	authcache "github.com/e2b-dev/infra/packages/api/internal/cache/auth"
	"github.com/e2b-dev/infra/packages/db/queries"
	"github.com/e2b-dev/infra/packages/shared/pkg/logger"
	"github.com/e2b-dev/infra/packages/shared/pkg/telemetry"
)

func (a *APIStore) GetSandboxesSandboxID(c *gin.Context, id string) {
	ctx := c.Request.Context()

	teamInfo := c.Value(auth.TeamContextKey).(authcache.AuthTeamInfo)
	team := teamInfo.Team

	telemetry.ReportEvent(ctx, "get sandbox")

	sandboxId := strings.Split(id, "-")[0]

	// Try to get the running sandbox first
	info, err := a.orchestrator.GetInstance(ctx, sandboxId)
	if err == nil {
		// Check if sandbox belongs to the team
		if *info.TeamID != team.ID {
			zap.L().Error("sandbox %s doesn't exist or you don't have access to it", logger.WithSandboxID(id))
			c.JSON(http.StatusNotFound, fmt.Sprintf("sandbox \"%s\" doesn't exist or you don't have access to it", id))
			return
		}

		// Sandbox exists and belongs to the team - return running sandbox info
		sandbox := api.SandboxDetail{
			ClientID:        info.Instance.ClientID,
			TemplateID:      info.Instance.TemplateID,
			Alias:           info.Instance.Alias,
			SandboxID:       info.Instance.SandboxID,
			StartedAt:       info.StartTime,
			CpuCount:        api.CPUCount(info.VCpu),
			MemoryMB:        api.MemoryMB(info.RamMB),
			DiskSizeMB:      info.TotalDiskSizeMB,
			EndAt:           info.GetEndTime(),
			State:           api.Running,
			EnvdVersion:     &info.EnvdVersion,
			EnvdAccessToken: info.EnvdAccessToken,
		}

		if info.Metadata != nil {
			meta := api.SandboxMetadata(info.Metadata)
			sandbox.Metadata = &meta
		}

		c.JSON(http.StatusOK, sandbox)
		return
	}

	// If sandbox not found try to get the latest snapshot
	lastSnapshot, err := a.sqlcDB.GetLastSnapshot(ctx, queries.GetLastSnapshotParams{SandboxID: sandboxId, TeamID: team.ID})
	if err != nil {
		zap.L().Error("error getting last snapshot for sandbox", logger.WithSandboxID(id), zap.Error(err))
		c.JSON(http.StatusNotFound, fmt.Sprintf("sandbox \"%s\" doesn't exist or you don't have access to it", id))
		return
	}

	var sbxAccessToken *string = nil
	if lastSnapshot.Snapshot.EnvSecure {
		key, err := a.envdAccessTokenGenerator.GenerateAccessToken(lastSnapshot.Snapshot.SandboxID)
		if err != nil {
			zap.L().Error("error generating sandbox access token", logger.WithSandboxID(id), zap.Error(err))
			c.JSON(http.StatusInternalServerError, fmt.Sprintf("error generating sandbox access token: %s", err))
			return
		}

		sbxAccessToken = &key
	}

	sandbox := snapshotToSandboxDetail(lastSnapshot, sbxAccessToken)

	c.JSON(http.StatusOK, sandbox)
}

func envBuildDiskSizeMB(build queries.EnvBuild) int64 {
	if build.TotalDiskSizeMb != nil {
		return *build.TotalDiskSizeMb
	}

	return build.FreeDiskSizeMb
}

func snapshotToSandboxDetail(lastSnapshot queries.GetLastSnapshotRow, envdAccessToken *string) api.SandboxDetail {
	snapshot := lastSnapshot.Snapshot
	build := lastSnapshot.EnvBuild

	sandbox := api.SandboxDetail{
		ClientID:        "00000000", // for backwards compatibility we need to return a client id
		TemplateID:      snapshot.EnvID,
		SandboxID:       snapshot.SandboxID,
		StartedAt:       snapshot.SandboxStartedAt.Time,
		CpuCount:        int32(build.Vcpu),
		MemoryMB:        int32(build.RamMb),
		DiskSizeMB:      envBuildDiskSizeMB(build),
		EndAt:           snapshot.CreatedAt.Time,
		State:           api.Paused,
		EnvdVersion:     build.EnvdVersion,
		EnvdAccessToken: envdAccessToken,
	}

	if snapshot.Metadata != nil {
		metadata := api.SandboxMetadata(snapshot.Metadata)
		sandbox.Metadata = &metadata
	}

	return sandbox
}
