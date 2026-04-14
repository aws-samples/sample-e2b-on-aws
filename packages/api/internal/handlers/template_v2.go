package handlers

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/posthog/posthog-go"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
	"go.uber.org/zap"

	"github.com/e2b-dev/infra/packages/api/internal/api"
	"github.com/e2b-dev/infra/packages/api/internal/constants"
	template_manager "github.com/e2b-dev/infra/packages/api/internal/template-manager"
	"github.com/e2b-dev/infra/packages/api/internal/utils"
	"github.com/e2b-dev/infra/packages/shared/pkg/db"
	templatemanagergrpc "github.com/e2b-dev/infra/packages/shared/pkg/grpc/template-manager"
	"github.com/e2b-dev/infra/packages/shared/pkg/id"
	"github.com/e2b-dev/infra/packages/shared/pkg/logger"
	"github.com/e2b-dev/infra/packages/shared/pkg/models"
	"github.com/e2b-dev/infra/packages/shared/pkg/models/env"
	"github.com/e2b-dev/infra/packages/shared/pkg/models/envalias"
	"github.com/e2b-dev/infra/packages/shared/pkg/models/envbuild"
	"github.com/e2b-dev/infra/packages/shared/pkg/schema"
	"github.com/e2b-dev/infra/packages/shared/pkg/storage"
	"github.com/e2b-dev/infra/packages/shared/pkg/telemetry"
	sharedutils "github.com/e2b-dev/infra/packages/shared/pkg/utils"
)

// TemplateBuildRequestV2 is the request body for POST /v2/templates
type TemplateBuildRequestV2 struct {
	Alias    string `json:"alias"`
	CpuCount *int32 `json:"cpuCount,omitempty"`
	MemoryMB *int32 `json:"memoryMB,omitempty"`
}

// TemplateBuildStepV2 represents a single build step from the SDK.
type TemplateBuildStepV2 struct {
	Type      string   `json:"type"`
	Args      []string `json:"args,omitempty"`
	FilesHash string   `json:"filesHash,omitempty"`
	Force     bool     `json:"force,omitempty"`
}

// TemplateBuildStartV2 is the request body for POST /v2/templates/:templateID/builds/:buildID
type TemplateBuildStartV2 struct {
	Force     *bool                 `json:"force,omitempty"`
	FromImage *string               `json:"fromImage,omitempty"`
	StartCmd  *string               `json:"startCmd,omitempty"`
	ReadyCmd  *string               `json:"readyCmd,omitempty"`
	Steps     []TemplateBuildStepV2 `json:"steps,omitempty"`
}

// BuildContextFileUploadResponse matches SDK's TemplateBuildFileUpload model.
type BuildContextFileUploadResponse struct {
	Present bool   `json:"present"`
	URL     string `json:"url,omitempty"`
}

// TemplateResponseV2 is the response body for POST /v2/templates,
// matching the fields expected by Python SDK 2.1.0's Template.from_dict.
type TemplateResponseV2 struct {
	TemplateID    string   `json:"templateID"`
	BuildID       string   `json:"buildID"`
	Public        bool     `json:"public"`
	Aliases       []string `json:"aliases"`
	CpuCount      int32    `json:"cpuCount"`
	MemoryMB      int32    `json:"memoryMB"`
	DiskSizeMB    int64    `json:"diskSizeMB"`
	EnvdVersion   string   `json:"envdVersion"`
	BuildCount    int32    `json:"buildCount"`
	SpawnCount    int64    `json:"spawnCount"`
	CreatedBy     *string  `json:"createdBy"`
	LastSpawnedAt *string  `json:"lastSpawnedAt"`
	CreatedAt     string   `json:"createdAt"`
	UpdatedAt     string   `json:"updatedAt"`
}

// getCPUAndRAMV2 validates and returns CPU/RAM values for v2 endpoints.
// Unlike getCPUAndRAM (which uses queries.Tier with MaxVcpu/MaxRamMb),
// this validates basic constraints only since models.Tier does not carry
// per-tier max CPU/RAM limits.
func getCPUAndRAMV2(cpuCount, memoryMB *int32) (int64, int64, *api.APIError) {
	cpu := constants.DefaultTemplateCPU
	ramMB := constants.DefaultTemplateMemory

	if cpuCount != nil {
		cpu = int64(*cpuCount)
		if cpu < constants.MinTemplateCPU {
			return 0, 0, &api.APIError{
				Err:       fmt.Errorf("CPU count must be at least %d", constants.MinTemplateCPU),
				ClientMsg: fmt.Sprintf("CPU count must be at least %d", constants.MinTemplateCPU),
				Code:      http.StatusBadRequest,
			}
		}
	}

	if memoryMB != nil {
		ramMB = int64(*memoryMB)
		if ramMB < constants.MinTemplateMemory {
			return 0, 0, &api.APIError{
				Err:       fmt.Errorf("memory must be at least %d MiB", constants.MinTemplateMemory),
				ClientMsg: fmt.Sprintf("Memory must be at least %d MiB", constants.MinTemplateMemory),
				Code:      http.StatusBadRequest,
			}
		}
		if ramMB%2 != 0 {
			return 0, 0, &api.APIError{
				Err:       fmt.Errorf("user provided memory size isn't divisible by 2"),
				ClientMsg: "Memory must be divisible by 2",
				Code:      http.StatusBadRequest,
			}
		}
	}

	return cpu, ramMB, nil
}

// PostV2Templates handles POST /v2/templates — creates a new template (v2 format).
// Authenticated via X-API-Key header (API Key auth).
func (a *APIStore) PostV2Templates(c *gin.Context) {
	ctx := c.Request.Context()
	envID := id.Generate()

	telemetry.ReportEvent(ctx, "started creating new environment (v2)")

	body, err := utils.ParseBody[TemplateBuildRequestV2](ctx, c)
	if err != nil {
		a.sendAPIStoreError(c, http.StatusBadRequest, fmt.Sprintf("Invalid request body: %s", err))
		telemetry.ReportCriticalError(ctx, "invalid request body", err)
		return
	}

	// alias is required in v2
	if body.Alias == "" {
		a.sendAPIStoreError(c, http.StatusBadRequest, "alias is required")
		telemetry.ReportCriticalError(ctx, "alias is required", fmt.Errorf("alias is required"))
		return
	}

	telemetry.ReportEvent(ctx, "started request for environment build (v2)")

	// Get team info from API Key auth (TeamContextKey)
	authInfo := a.GetTeamInfo(c)
	team := authInfo.Team
	tier := authInfo.Tier

	buildID, err := uuid.NewRandom()
	if err != nil {
		telemetry.ReportCriticalError(ctx, "error when generating build id", err)
		a.sendAPIStoreError(c, http.StatusInternalServerError, "Failed to generate build id")
		return
	}

	telemetry.SetAttributes(ctx,
		attribute.String("env.team.id", team.ID.String()),
		attribute.String("env.team.name", team.Name),
		telemetry.WithTemplateID(envID),
		attribute.String("env.team.tier", team.Tier),
		telemetry.WithBuildID(buildID.String()),
		attribute.String("env.alias", body.Alias),
	)

	if body.CpuCount != nil {
		telemetry.SetAttributes(ctx, attribute.Int("env.cpu", int(*body.CpuCount)))
	}
	if body.MemoryMB != nil {
		telemetry.SetAttributes(ctx, attribute.Int("env.memory_mb", int(*body.MemoryMB)))
	}

	cpuCount, ramMB, apiError := getCPUAndRAMV2(body.CpuCount, body.MemoryMB)
	if apiError != nil {
		telemetry.ReportCriticalError(ctx, "error when getting CPU and RAM", apiError.Err)
		a.sendAPIStoreError(c, apiError.Code, apiError.ClientMsg)
		return
	}

	alias, err := id.CleanEnvID(body.Alias)
	if err != nil {
		a.sendAPIStoreError(c, http.StatusBadRequest, fmt.Sprintf("Invalid alias: %s", body.Alias))
		telemetry.ReportCriticalError(ctx, "invalid alias", err)
		return
	}

	// Start a transaction
	tx, err := a.db.Client.Tx(ctx)
	if err != nil {
		a.sendAPIStoreError(c, http.StatusInternalServerError, fmt.Sprintf("Error when starting transaction: %s", err))
		telemetry.ReportCriticalError(ctx, "error when starting transaction", err)
		return
	}
	defer tx.Rollback()

	// Create the template (no SetCreatedBy — API Key auth does not provide a user ID)
	err = tx.
		Env.
		Create().
		SetID(envID).
		SetTeamID(team.ID).
		SetPublic(false).
		SetNillableClusterID(team.ClusterID).
		OnConflictColumns(env.FieldID).
		UpdateUpdatedAt().
		Exec(ctx)
	if err != nil {
		a.sendAPIStoreError(c, http.StatusInternalServerError, fmt.Sprintf("Error when updating template: %s", err))
		telemetry.ReportCriticalError(ctx, "error when updating env", err)
		return
	}

	// Mark previous not started builds as failed
	err = tx.EnvBuild.Update().Where(
		envbuild.EnvID(envID),
		envbuild.StatusEQ(envbuild.StatusWaiting),
	).SetStatus(envbuild.StatusFailed).SetFinishedAt(time.Now()).Exec(ctx)
	if err != nil {
		a.sendAPIStoreError(c, http.StatusInternalServerError, fmt.Sprintf("Error when updating template: %s", err))
		telemetry.ReportCriticalError(ctx, "error when updating env", err)
		return
	}

	var builderNodeID *string
	if team.ClusterID != nil {
		cluster, found := a.clustersPool.GetClusterById(*team.ClusterID)
		if !found {
			a.sendAPIStoreError(c, http.StatusBadRequest, fmt.Sprintf("Cluster with ID '%s' not found", *team.ClusterID))
			telemetry.ReportCriticalError(ctx, "cluster not found", fmt.Errorf("cluster with ID '%s' not found", *team.ClusterID), telemetry.WithTemplateID(envID))
			return
		}

		clusterNode, err := cluster.GetAvailableTemplateBuilder(ctx)
		if err != nil {
			a.sendAPIStoreError(c, http.StatusInternalServerError, fmt.Sprintf("Error when getting available template builder: %s", err))
			telemetry.ReportCriticalError(ctx, "error when getting available template builder", err, telemetry.WithTemplateID(envID))
			return
		}

		builderNodeID = &clusterNode.NodeID
	}

	// Insert the new build — v2 does NOT set Dockerfile, StartCmd, ReadyCmd
	err = tx.EnvBuild.Create().
		SetID(buildID).
		SetEnvID(envID).
		SetStatus(envbuild.StatusWaiting).
		SetRAMMB(ramMB).
		SetVcpu(cpuCount).
		SetKernelVersion(schema.DefaultKernelVersion).
		SetFirecrackerVersion(schema.DefaultFirecrackerVersion).
		SetFreeDiskSizeMB(tier.DiskMB).
		SetNillableClusterNodeID(builderNodeID).
		Exec(ctx)
	if err != nil {
		a.sendAPIStoreError(c, http.StatusInternalServerError, fmt.Sprintf("Error when inserting build: %s", err))
		telemetry.ReportCriticalError(ctx, "error when inserting build", err)
		return
	}

	// Handle alias
	if alias != "" {
		envs, err := tx.
			Env.
			Query().
			Where(env.ID(alias)).
			All(ctx)
		if err != nil {
			a.sendAPIStoreError(c, http.StatusInternalServerError, fmt.Sprintf("Error when querying alias '%s': %s", alias, err))
			telemetry.ReportCriticalError(ctx, "error when checking alias", err, attribute.String("alias", alias))
			return
		}

		if len(envs) > 0 {
			a.sendAPIStoreError(c, http.StatusConflict, fmt.Sprintf("Alias '%s' is already used", alias))
			telemetry.ReportCriticalError(ctx, "conflict of alias", err, attribute.String("alias", alias))
			return
		}

		aliasDB, err := tx.EnvAlias.Query().Where(envalias.ID(alias)).Only(ctx)
		if err != nil {
			if !models.IsNotFound(err) {
				a.sendAPIStoreError(c, http.StatusInternalServerError, fmt.Sprintf("Error when querying for alias: %s", err))
				telemetry.ReportCriticalError(ctx, "error when checking alias", err, attribute.String("alias", alias))
				return
			}

			count, err := tx.EnvAlias.Delete().Where(envalias.EnvID(envID), envalias.IsRenamable(true)).Exec(ctx)
			if err != nil {
				a.sendAPIStoreError(c, http.StatusInternalServerError, fmt.Sprintf("Error when deleting template alias: %s", err))
				telemetry.ReportCriticalError(ctx, "error when deleting template alias", err, attribute.String("alias", alias))
				return
			}

			if count > 0 {
				telemetry.ReportEvent(ctx, "deleted old aliases", attribute.Int("env.alias.count", count))
			}

			err = tx.
				EnvAlias.
				Create().
				SetEnvID(envID).SetIsRenamable(true).SetID(alias).
				Exec(ctx)
			if err != nil {
				a.sendAPIStoreError(c, http.StatusInternalServerError, fmt.Sprintf("Error when inserting alias '%s': %s", alias, err))
				telemetry.ReportCriticalError(ctx, "error when inserting alias", err, attribute.String("alias", alias))
				return
			}
		} else if aliasDB.EnvID != envID {
			a.sendAPIStoreError(c, http.StatusForbidden, fmt.Sprintf("Alias '%s' already used", alias))
			telemetry.ReportCriticalError(ctx, "alias already used", err, attribute.String("alias", alias))
			return
		}

		telemetry.ReportEvent(ctx, "inserted alias", attribute.String("env.alias", alias))
	}

	// Commit the transaction
	err = tx.Commit()
	if err != nil {
		a.sendAPIStoreError(c, http.StatusInternalServerError, fmt.Sprintf("Error when committing transaction: %s", err))
		telemetry.ReportCriticalError(ctx, "error when committing transaction", err)
		return
	}

	properties := a.posthog.GetPackageToPosthogProperties(&c.Request.Header)
	a.posthog.IdentifyAnalyticsTeam(team.ID.String(), team.Name)
	a.posthog.CreateAnalyticsUserEvent(team.ID.String(), team.ID.String(), "submitted environment build request (v2)", properties.
		Set("environment", envID).
		Set("build_id", buildID).
		Set("alias", alias),
	)

	telemetry.SetAttributes(ctx,
		attribute.String("env.alias", alias),
		attribute.Int64("build.cpu_count", cpuCount),
		attribute.Int64("build.ram_mb", ramMB),
	)
	telemetry.ReportEvent(ctx, "started updating environment (v2)")

	var aliases []string
	if alias != "" {
		aliases = append(aliases, alias)
	}

	zap.L().Info("Built template (v2)", logger.WithTemplateID(envID), logger.WithBuildID(buildID.String()))

	now := time.Now().UTC().Format(time.RFC3339)
	c.JSON(http.StatusAccepted, &TemplateResponseV2{
		TemplateID:    envID,
		BuildID:       buildID.String(),
		Public:        false,
		Aliases:       aliases,
		CpuCount:      int32(cpuCount),
		MemoryMB:      int32(ramMB),
		DiskSizeMB:    tier.DiskMB,
		EnvdVersion:   "",
		BuildCount:    1,
		SpawnCount:    0,
		CreatedBy:     nil,
		LastSpawnedAt: nil,
		CreatedAt:     now,
		UpdatedAt:     now,
	})
}

// PostV2TemplatesTemplateIDBuildsBuildID handles POST /v2/templates/:templateID/builds/:buildID
// Authenticated via X-API-Key header (API Key auth).
// It optionally updates startCmd/readyCmd in the DB, then triggers the build.
func (a *APIStore) PostV2TemplatesTemplateIDBuildsBuildID(c *gin.Context) {
	templateID := c.Param("templateID")
	buildIDStr := c.Param("buildID")

	ctx := c.Request.Context()
	span := trace.SpanFromContext(ctx)

	buildUUID, err := uuid.Parse(buildIDStr)
	if err != nil {
		a.sendAPIStoreError(c, http.StatusBadRequest, fmt.Sprintf("Invalid build ID: %s", buildIDStr))
		telemetry.ReportCriticalError(ctx, "invalid build ID", err)
		return
	}

	// Get team info from API Key auth (TeamContextKey)
	authInfo := a.GetTeamInfo(c)
	team := authInfo.Team

	telemetry.ReportEvent(ctx, "started environment build (v2)")

	// Parse optional v2 body
	var body TemplateBuildStartV2
	if c.Request.ContentLength > 0 {
		if err := c.ShouldBindJSON(&body); err != nil {
			a.sendAPIStoreError(c, http.StatusBadRequest, fmt.Sprintf("Invalid request body: %s", err))
			telemetry.ReportCriticalError(ctx, "invalid v2 build start body", err)
			return
		}
	}

	// If v2 provides startCmd or readyCmd, update the build record before triggering
	if body.StartCmd != nil || body.ReadyCmd != nil {
		update := a.db.Client.EnvBuild.UpdateOneID(buildUUID)
		if body.StartCmd != nil {
			update = update.SetNillableStartCmd(body.StartCmd)
		}
		if body.ReadyCmd != nil {
			update = update.SetNillableReadyCmd(body.ReadyCmd)
		}

		if err := update.Exec(ctx); err != nil {
			a.sendAPIStoreError(c, http.StatusInternalServerError, fmt.Sprintf("Error updating build commands: %s", err))
			telemetry.ReportCriticalError(ctx, "error updating build commands for v2", err)
			return
		}

		zap.L().Info("Updated build commands for v2",
			zap.String("templateID", templateID),
			zap.String("buildID", buildIDStr),
		)
	}

	// Build steps and fromImage are now passed to template-manager via gRPC

	// Query template with the specific build
	envDB, err := a.db.Client.Env.Query().Where(
		env.ID(templateID),
	).WithBuilds(
		func(query *models.EnvBuildQuery) {
			query.Where(envbuild.ID(buildUUID))
		},
	).Only(ctx)
	if err != nil {
		a.sendAPIStoreError(c, http.StatusNotFound, fmt.Sprintf("Error when getting template: %s", err))
		telemetry.ReportCriticalError(ctx, "error when getting env", err, telemetry.WithTemplateID(templateID))
		return
	}

	// Verify team has access to this template
	if envDB.TeamID != team.ID {
		a.sendAPIStoreError(c, http.StatusForbidden, "Team does not have access to the template")
		telemetry.ReportCriticalError(ctx, "team does not have access to the template", fmt.Errorf("team %s tried to access template owned by team %s", team.ID, envDB.TeamID), telemetry.WithTemplateID(templateID))
		return
	}

	telemetry.SetAttributes(ctx,
		telemetry.WithTeamID(team.ID.String()),
		telemetry.WithTemplateID(templateID),
	)

	// Check and cancel concurrent running builds
	concurrentlyRunningBuilds, err := a.db.
		Client.
		EnvBuild.
		Query().
		Where(
			envbuild.EnvID(envDB.ID),
			envbuild.StatusIn(envbuild.StatusWaiting, envbuild.StatusBuilding),
			envbuild.IDNotIn(buildUUID),
		).
		All(ctx)
	if err != nil {
		a.sendAPIStoreError(c, http.StatusInternalServerError, "Error during template build request")
		telemetry.ReportCriticalError(ctx, "Error when getting running builds", err)
		return
	}

	if len(concurrentlyRunningBuilds) > 0 {
		buildIDs := sharedutils.Map(concurrentlyRunningBuilds, func(b *models.EnvBuild) template_manager.DeleteBuild {
			return template_manager.DeleteBuild{
				TemplateID: envDB.ID,
				BuildID:    b.ID,
			}
		})
		telemetry.ReportEvent(ctx, "canceling running builds", attribute.StringSlice("ids", sharedutils.Map(buildIDs, func(b template_manager.DeleteBuild) string {
			return fmt.Sprintf("%s/%s", b.TemplateID, b.BuildID)
		})))
		deleteJobErr := a.templateManager.DeleteBuilds(ctx, buildIDs)
		if deleteJobErr != nil {
			a.sendAPIStoreError(c, http.StatusInternalServerError, "Error during template build cancel request")
			telemetry.ReportCriticalError(ctx, "error when canceling running build", deleteJobErr)
			return
		}
		telemetry.ReportEvent(ctx, "canceled running builds")
	}

	build := envDB.Edges.Builds[0]
	var startCmd string
	if build.StartCmd != nil {
		startCmd = *build.StartCmd
	}

	var readyCmd string
	if build.ReadyCmd != nil {
		readyCmd = *build.ReadyCmd
	}

	// Only waiting builds can be triggered
	if build.Status != envbuild.StatusWaiting {
		a.sendAPIStoreError(c, http.StatusBadRequest, "build is not in waiting state")
		telemetry.ReportCriticalError(ctx, "build is not in waiting state", fmt.Errorf("build is not in waiting state: %s", build.Status), telemetry.WithTemplateID(templateID))
		return
	}

	// Team is part of the cluster but template build is not assigned to a cluster node
	if team.ClusterID != nil && build.ClusterNodeID == nil {
		a.sendAPIStoreError(c, http.StatusInternalServerError, "build is not assigned to a cluster node")
		telemetry.ReportCriticalError(ctx, "build is not assigned to a cluster node", nil, telemetry.WithTemplateID(templateID))
		return
	}

	telemetry.ReportEvent(ctx, "created new environment (v2)", telemetry.WithTemplateID(templateID))

	a.posthog.CreateAnalyticsUserEvent(team.ID.String(), team.ID.String(), "built environment (v2)", posthog.NewProperties().
		Set("environment", templateID).
		Set("build_id", buildIDStr),
	)

	zap.L().Info("Build triggered (v2)",
		zap.String("templateID", templateID),
		zap.String("buildID", buildIDStr))

	// Return HTTP 202 immediately — CopyImage + CreateTemplate run in background
	c.Status(http.StatusAccepted)

	// Background goroutine: CopyImage → CreateTemplate → SetStatus → BuildStatusSync
	go func() {
		// Panic recovery - prevent silent goroutine death
		defer func() {
			if r := recover(); r != nil {
				zap.L().Error("Panic in background build goroutine (v2)",
					zap.String("templateID", templateID),
					zap.String("buildID", buildIDStr),
					zap.Any("panic", r))
				_ = a.templateManager.SetStatus(context.Background(), templateID, buildUUID,
					envbuild.StatusFailed, fmt.Sprintf("internal error: %v", r))
				a.templateCache.Invalidate(templateID)
			}
		}()

		// Overall timeout for the entire background pipeline
		bgCtx, bgCancel := context.WithTimeout(context.Background(), 30*time.Minute)
		defer bgCancel()

		buildContext, buildSpan := a.Tracer.Start(
			trace.ContextWithSpanContext(bgCtx, span.SpanContext()),
			"template-background-build-env-v2",
		)
		defer buildSpan.End()

		zap.L().Info("Background build goroutine started (v2)",
			zap.String("templateID", templateID),
			zap.String("buildID", buildIDStr))

		// Convert steps to proto format for template-manager
		var protoSteps []*templatemanagergrpc.TemplateStep
		for _, s := range body.Steps {
			step := &templatemanagergrpc.TemplateStep{
				Type: s.Type,
				Args: s.Args,
			}
			if s.FilesHash != "" {
				step.FilesHash = &s.FilesHash
			}
			protoSteps = append(protoSteps, step)
		}

		var fromImage string
		if body.FromImage != nil {
			fromImage = *body.FromImage
		}

		// Dispatch build to template-manager via gRPC — steps are executed inside FC VM
		zap.L().Info("Dispatching build to template-manager (v2)",
			zap.String("templateID", templateID),
			zap.String("buildID", buildIDStr),
			zap.String("fromImage", fromImage),
			zap.Int("numSteps", len(protoSteps)))
		buildErr := a.templateManager.CreateTemplate(
			a.Tracer, buildContext, templateID, buildUUID,
			build.KernelVersion, build.FirecrackerVersion,
			startCmd, build.Vcpu, build.FreeDiskSizeMB, build.RAMMB,
			readyCmd, fromImage, protoSteps,
			team.ClusterID, build.ClusterNodeID,
		)
		if buildErr != nil {
			zap.L().Error("Build dispatch failed (v2)",
				zap.String("templateID", templateID),
				zap.String("buildID", buildIDStr),
				zap.Error(buildErr))
			_ = a.templateManager.SetStatus(buildContext, templateID, buildUUID,
				envbuild.StatusFailed, fmt.Sprintf("error when building env: %s", buildErr))
			a.templateCache.Invalidate(templateID)
			return
		}

		// Step 3: Set status to building
		zap.L().Info("Setting build status to building (v2)",
			zap.String("templateID", templateID),
			zap.String("buildID", buildIDStr))
		if statusErr := a.templateManager.SetStatus(buildContext, templateID, buildUUID,
			envbuild.StatusBuilding, "starting build"); statusErr != nil {
			zap.L().Error("Failed to set build status (v2)",
				zap.String("templateID", templateID),
				zap.String("buildID", buildIDStr),
				zap.Error(statusErr))
			a.templateCache.Invalidate(templateID)
			return
		}
		zap.L().Info("Build status set to building (v2)",
			zap.String("templateID", templateID),
			zap.String("buildID", buildIDStr))

		// Step 4: Poll build status until completion
		if syncErr := a.templateManager.BuildStatusSync(buildContext, buildUUID, templateID,
			team.ClusterID, build.ClusterNodeID); syncErr != nil {
			zap.L().Error("Build status sync failed (v2)",
				zap.String("templateID", templateID),
				zap.String("buildID", buildIDStr),
				zap.Error(syncErr))
		}

		a.templateCache.Invalidate(templateID)
	}()
}

// GetV2TemplatesTemplateIDFilesHash handles GET /v2/templates/:templateID/files/:hash
// Returns a presigned S3 upload URL for build context files.
// SDK expects 201 with {present: bool, url: string}.
func (a *APIStore) GetV2TemplatesTemplateIDFilesHash(c *gin.Context) {
	templateID := c.Param("templateID")
	hash := c.Param("hash")

	ctx := c.Request.Context()

	// Get team info from API Key auth
	authInfo := a.GetTeamInfo(c)
	team := authInfo.Team

	// Verify template belongs to this team
	envDB, err := a.db.Client.Env.Query().Where(env.ID(templateID)).Only(ctx)
	if err != nil {
		if models.IsNotFound(err) {
			a.sendAPIStoreError(c, http.StatusNotFound, fmt.Sprintf("Template '%s' not found", templateID))
			return
		}
		a.sendAPIStoreError(c, http.StatusInternalServerError, fmt.Sprintf("Error querying template: %s", err))
		return
	}

	if envDB.TeamID != team.ID {
		a.sendAPIStoreError(c, http.StatusForbidden, "Team does not have access to the template")
		return
	}

	if a.buildContextPresign == nil {
		a.sendAPIStoreError(c, http.StatusServiceUnavailable, "Build context storage is not configured")
		return
	}

	s3Key := storage.BuildContextKey(templateID, hash)

	// Check if object already exists
	exists, err := a.buildContextPresign.ObjectExists(ctx, s3Key)
	if err != nil {
		zap.L().Error("Failed to check build context file existence",
			zap.String("templateID", templateID),
			zap.String("hash", hash),
			zap.Error(err))
		a.sendAPIStoreError(c, http.StatusInternalServerError, "Failed to check file existence")
		return
	}

	if exists {
		c.JSON(http.StatusCreated, BuildContextFileUploadResponse{
			Present: true,
		})
		return
	}

	// Generate presigned PUT URL
	url, err := a.buildContextPresign.GeneratePutURL(ctx, s3Key, 0)
	if err != nil {
		zap.L().Error("Failed to generate presigned URL",
			zap.String("templateID", templateID),
			zap.String("hash", hash),
			zap.Error(err))
		a.sendAPIStoreError(c, http.StatusInternalServerError, "Failed to generate upload URL")
		return
	}

	c.JSON(http.StatusCreated, BuildContextFileUploadResponse{
		Present: false,
		URL:     url,
	})
}

// BuildLogEntryV2 represents a structured log entry for v2 build status responses.
type BuildLogEntryV2 struct {
	Level     string `json:"level"`
	Message   string `json:"message"`
	Timestamp string `json:"timestamp"`
}

// BuildStatusReasonV2 represents a reason for build failure in v2 responses.
type BuildStatusReasonV2 struct {
	Message string `json:"message"`
	Step    string `json:"step,omitempty"`
}

// TemplateBuildV2 is the v2 build status response matching Python SDK 2.1.0 expectations.
type TemplateBuildV2 struct {
	BuildID    string               `json:"buildID"`
	LogEntries []BuildLogEntryV2    `json:"logEntries"`
	Logs       []string             `json:"logs"`
	Status     string               `json:"status"`
	TemplateID string               `json:"templateID"`
	Reason     *BuildStatusReasonV2 `json:"reason,omitempty"`
}

// getV2BuildStatus converts envbuild.Status to the string format expected by Python SDK 2.1.0.
func getV2BuildStatus(s envbuild.Status) string {
	switch s {
	case envbuild.StatusWaiting:
		return "waiting"
	case envbuild.StatusFailed:
		return "error"
	case envbuild.StatusUploaded:
		return "ready"
	default:
		return "building"
	}
}

// GetV2TemplatesTemplateIDBuildsBuildIDStatus handles GET /v2/templates/:templateID/builds/:buildID/status
// Authenticated via X-API-Key header (API Key auth).
// Returns build status in v2 format with logEntries required by Python SDK 2.1.0.
func (a *APIStore) GetV2TemplatesTemplateIDBuildsBuildIDStatus(c *gin.Context) {
	templateID := c.Param("templateID")
	buildIDStr := c.Param("buildID")

	ctx := c.Request.Context()

	buildUUID, err := uuid.Parse(buildIDStr)
	if err != nil {
		telemetry.ReportError(ctx, "error when parsing build id", err)
		a.sendAPIStoreError(c, http.StatusBadRequest, "Invalid build id")
		return
	}

	// Get team info from API Key auth (TeamContextKey)
	authInfo := a.GetTeamInfo(c)
	team := authInfo.Team

	buildInfo, err := a.templateBuildsCache.Get(ctx, buildUUID, templateID)
	if err != nil {
		if errors.Is(err, db.TemplateBuildNotFound{}) {
			a.sendAPIStoreError(c, http.StatusBadRequest, fmt.Sprintf("Build '%s' not found", buildUUID))
			return
		}

		if errors.Is(err, db.TemplateNotFound{}) {
			a.sendAPIStoreError(c, http.StatusBadRequest, fmt.Sprintf("Template '%s' not found", templateID))
			return
		}

		telemetry.ReportError(ctx, "error when getting template", err)
		a.sendAPIStoreError(c, http.StatusInternalServerError, "Error when getting template")
		return
	}

	// Verify team has access to this template
	if buildInfo.TeamID != team.ID {
		telemetry.ReportError(ctx, "team doesn't have access to template", fmt.Errorf("team %s tried to access template owned by team %s", team.ID, buildInfo.TeamID), telemetry.WithTemplateID(templateID))
		a.sendAPIStoreError(c, http.StatusForbidden, fmt.Sprintf("You don't have access to this sandbox template (%s)", templateID))
		return
	}

	status := getV2BuildStatus(buildInfo.BuildStatus)

	// Early return if still waiting for build start — return a hint log instead of empty list
	if buildInfo.BuildStatus == envbuild.StatusWaiting {
		now := time.Now().UTC().Format(time.RFC3339)
		waitingMsg := "Build is initializing, please wait..."
		result := TemplateBuildV2{
			BuildID: buildIDStr,
			LogEntries: []BuildLogEntryV2{{
				Level:     "info",
				Message:   waitingMsg,
				Timestamp: now,
			}},
			Logs:       []string{waitingMsg},
			Status:     status,
			TemplateID: templateID,
		}
		c.JSON(http.StatusOK, result)
		return
	}

	// Parse optional logsOffset query parameter
	var logsOffset *int32
	if offsetStr := c.Query("logsOffset"); offsetStr != "" {
		var offset int32
		if _, err := fmt.Sscanf(offsetStr, "%d", &offset); err == nil {
			logsOffset = &offset
		}
	}

	logs := make([]string, 0)
	l, err := a.templateManager.GetLogs(ctx, buildUUID, templateID, team.ClusterID, buildInfo.ClusterNodeID, logsOffset)
	if err != nil {
		zap.L().Error("Failed to get build logs", zap.Error(err), logger.WithBuildID(buildIDStr), logger.WithTemplateID(templateID))
	} else {
		logs = l
	}

	// Convert []string logs to []BuildLogEntryV2
	now := time.Now().UTC().Format(time.RFC3339)
	logEntries := make([]BuildLogEntryV2, 0, len(logs))
	for _, logLine := range logs {
		logEntries = append(logEntries, BuildLogEntryV2{
			Level:     "info",
			Message:   logLine,
			Timestamp: now,
		})
	}

	result := TemplateBuildV2{
		BuildID:    buildIDStr,
		LogEntries: logEntries,
		Logs:       logs,
		Status:     status,
		TemplateID: templateID,
	}

	// Add reason for error status
	if buildInfo.BuildStatus == envbuild.StatusFailed {
		reason := "Build failed"
		if buildInfo.FailureReason != "" {
			reason = buildInfo.FailureReason
		} else if len(logs) > 0 {
			reason = logs[len(logs)-1]
		}
		result.Reason = &BuildStatusReasonV2{
			Message: reason,
		}
	}

	c.JSON(http.StatusOK, result)
}
