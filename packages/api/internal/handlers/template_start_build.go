package handlers

import (
	"context"
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
	template_manager "github.com/e2b-dev/infra/packages/api/internal/template-manager"
	"github.com/e2b-dev/infra/packages/db/queries"
	"github.com/e2b-dev/infra/packages/shared/pkg/models"
	"github.com/e2b-dev/infra/packages/shared/pkg/models/env"
	"github.com/e2b-dev/infra/packages/shared/pkg/models/envbuild"
	"github.com/e2b-dev/infra/packages/shared/pkg/telemetry"
	"github.com/e2b-dev/infra/packages/shared/pkg/utils"
)

// PostTemplatesTemplateIDBuildsBuildID triggers a new build after the user pushes the Docker image to the registry
func (a *APIStore) PostTemplatesTemplateIDBuildsBuildID(c *gin.Context, templateID api.TemplateID, buildID api.BuildID) {
	ctx := c.Request.Context()
	span := trace.SpanFromContext(ctx)
	
	zap.L().Info("开始处理构建请求", 
		zap.String("templateID", templateID), 
		zap.String("buildID", string(buildID)))

	buildUUID, err := uuid.Parse(buildID)
	if err != nil {
		zap.L().Error("解析buildID失败", 
			zap.String("buildID", string(buildID)), 
			zap.Error(err))
		a.sendAPIStoreError(c, http.StatusBadRequest, fmt.Sprintf("Invalid build ID: %s", buildID))

		telemetry.ReportCriticalError(ctx, "invalid build ID", err)

		return
	}
	
	zap.L().Debug("成功解析buildID", 
		zap.String("buildID", string(buildID)), 
		zap.String("buildUUID", buildUUID.String()))

	userID, teams, err := a.GetUserAndTeams(c)
	if err != nil {
		zap.L().Error("获取用户和团队信息失败", zap.Error(err))
		a.sendAPIStoreError(c, http.StatusInternalServerError, fmt.Sprintf("Error when getting default team: %s", err))

		telemetry.ReportCriticalError(ctx, "error when getting default team", err)

		return
	}
	
	zap.L().Info("成功获取用户和团队信息", 
		zap.String("userID", userID.String()), 
		zap.Int("teamsCount", len(teams)))

	telemetry.ReportEvent(ctx, "started environment build")

	// Check if the user has access to the template, load the template with build info
	zap.L().Info("开始查询模板信息", zap.String("templateID", templateID))
	envDB, err := a.db.Client.Env.Query().Where(
		env.ID(templateID),
	).WithBuilds(
		func(query *models.EnvBuildQuery) {
			query.Where(envbuild.ID(buildUUID))
		},
	).Only(ctx)
	if err != nil {
		zap.L().Error("获取模板信息失败", 
			zap.String("templateID", templateID), 
			zap.Error(err))
		a.sendAPIStoreError(c, http.StatusNotFound, fmt.Sprintf("Error when getting template: %s", err))

		telemetry.ReportCriticalError(ctx, "error when getting env", err, telemetry.WithTemplateID(templateID))

		return
	}
	
	zap.L().Info("成功获取模板信息", 
		zap.String("templateID", templateID), 
		zap.String("teamID", envDB.TeamID.String()), 
		zap.Int("buildsCount", len(envDB.Edges.Builds)))

	var team *queries.Team
	// Check if the user has access to the template
	zap.L().Info("开始检查用户访问权限", 
		zap.String("userID", userID.String()), 
		zap.String("templateTeamID", envDB.TeamID.String()))
	for _, t := range teams {
		if t.Team.ID == envDB.TeamID {
			team = &t.Team
			break
		}
	}

	if team == nil {
		zap.L().Warn("用户无权访问模板", 
			zap.String("userID", userID.String()), 
			zap.String("templateID", templateID), 
			zap.String("templateTeamID", envDB.TeamID.String()))
		a.sendAPIStoreError(c, http.StatusForbidden, "User does not have access to the template")

		telemetry.ReportCriticalError(ctx, "user does not have access to the template", err, telemetry.WithTemplateID(templateID))

		return
	}
	
	zap.L().Info("用户有权访问模板", 
		zap.String("userID", userID.String()), 
		zap.String("teamID", team.ID.String()), 
		zap.String("templateID", templateID))

	telemetry.SetAttributes(ctx,
		attribute.String("user.id", userID.String()),
		telemetry.WithTeamID(team.ID.String()),
		telemetry.WithTemplateID(templateID),
	)

	zap.L().Info("开始检查并发运行的构建", zap.String("templateID", templateID))
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
		zap.L().Error("获取并发运行构建失败", 
			zap.String("templateID", templateID), 
			zap.Error(err))
		a.sendAPIStoreError(c, http.StatusInternalServerError, "Error during template build request")
		telemetry.ReportCriticalError(ctx, "Error when getting running builds", err)
		return
	}
	
	zap.L().Info("检查到并发运行的构建", 
		zap.String("templateID", templateID), 
		zap.Int("concurrentBuildsCount", len(concurrentlyRunningBuilds)))

	// make sure there is no other build in progress for the same template
	if len(concurrentlyRunningBuilds) > 0 {
		buildIDs := utils.Map(concurrentlyRunningBuilds, func(b *models.EnvBuild) template_manager.DeleteBuild {
			return template_manager.DeleteBuild{
				TemplateID: envDB.ID,
				BuildID:    b.ID,
			}
		})
		telemetry.ReportEvent(ctx, "canceling running builds", attribute.StringSlice("ids", utils.Map(buildIDs, func(b template_manager.DeleteBuild) string {
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

	startTime := time.Now()
	build := envDB.Edges.Builds[0]
	var startCmd string
	if build.StartCmd != nil {
		startCmd = *build.StartCmd
	}

	var readyCmd string
	if build.ReadyCmd != nil {
		readyCmd = *build.ReadyCmd
	}

	// only waiting builds can be triggered
	if build.Status != envbuild.StatusWaiting {
		a.sendAPIStoreError(c, http.StatusBadRequest, "build is not in waiting state")
		telemetry.ReportCriticalError(ctx, "build is not in waiting state", fmt.Errorf("build is not in waiting state: %s", build.Status), telemetry.WithTemplateID(templateID))
		return
	}

	// team is part of the cluster but template build is not assigned to a cluster node so its invalid stats
	if team.ClusterID != nil && build.ClusterNodeID == nil {
		a.sendAPIStoreError(c, http.StatusInternalServerError, "build is not assigned to a cluster node")
		telemetry.ReportCriticalError(ctx, "build is not assigned to a cluster node", nil, telemetry.WithTemplateID(templateID))
		return
	}

	// Call the Template Manager to build the environment
	zap.L().Info("开始创建模板", 
		zap.String("templateID", templateID), 
		zap.String("buildID", buildUUID.String()), 
		zap.String("kernelVersion", build.KernelVersion), 
		zap.String("firecrackerVersion", build.FirecrackerVersion), 
		zap.Int64("vcpu", build.Vcpu), 
		zap.Int64("ramMB", build.RAMMB))
	buildErr := a.templateManager.CreateTemplate(
		a.Tracer,
		ctx,
		templateID,
		buildUUID,
		build.KernelVersion,
		build.FirecrackerVersion,
		startCmd,
		build.Vcpu,
		build.FreeDiskSizeMB,
		build.RAMMB,
		readyCmd,
		team.ClusterID,
		build.ClusterNodeID,
	)

	if buildErr != nil {
		zap.L().Error("创建模板失败", 
			zap.String("templateID", templateID), 
			zap.String("buildID", buildUUID.String()), 
			zap.Error(buildErr))
		telemetry.ReportCriticalError(ctx, "build failed", buildErr, telemetry.WithTemplateID(templateID))
		err = a.templateManager.SetStatus(
			ctx,
			templateID,
			buildUUID,
			envbuild.StatusFailed,
			fmt.Sprintf("error when building env: %s", buildErr),
		)
		if err != nil {
			zap.L().Error("设置构建状态失败", 
				zap.String("templateID", templateID), 
				zap.String("buildID", buildUUID.String()), 
				zap.Error(err))
			telemetry.ReportCriticalError(ctx, "error when setting build status", err)
		}

		return
	}
	
	zap.L().Info("成功创建模板", 
		zap.String("templateID", templateID), 
		zap.String("buildID", buildUUID.String()))

	// status building must be set after build is triggered because then
	// it's possible build status job will be triggered before build cache on template manager is created and build will fail
	zap.L().Info("开始设置构建状态为building", 
		zap.String("templateID", templateID), 
		zap.String("buildID", buildUUID.String()))
	err = a.templateManager.SetStatus(
		ctx,
		templateID,
		buildUUID,
		envbuild.StatusBuilding,
		"starting build",
	)
	if err != nil {
		zap.L().Error("设置构建状态失败", 
			zap.String("templateID", templateID), 
			zap.String("buildID", buildUUID.String()), 
			zap.Error(err))
		telemetry.ReportCriticalError(ctx, "error when setting build status", err)
		return
	}
	
	zap.L().Info("成功设置构建状态为building", 
		zap.String("templateID", templateID), 
		zap.String("buildID", buildUUID.String()))

	telemetry.ReportEvent(ctx, "created new environment", telemetry.WithTemplateID(templateID))

	// Do not wait for global build sync trigger it immediately
	zap.L().Info("开始触发后台构建同步", 
		zap.String("templateID", templateID), 
		zap.String("buildID", buildUUID.String()))
	go func() {
		buildContext, buildSpan := a.Tracer.Start(
			trace.ContextWithSpanContext(context.Background(), span.SpanContext()),
			"template-background-build-env",
		)
		defer buildSpan.End()

		zap.L().Info("开始后台构建状态同步", 
			zap.String("templateID", templateID), 
			zap.String("buildID", buildUUID.String()))
		err := a.templateManager.BuildStatusSync(buildContext, buildUUID, templateID, team.ClusterID, build.ClusterNodeID)
		if err != nil {
			zap.L().Error("后台构建状态同步失败", 
				zap.String("templateID", templateID), 
				zap.String("buildID", buildUUID.String()), 
				zap.Error(err))
		} else {
			zap.L().Info("后台构建状态同步成功", 
				zap.String("templateID", templateID), 
				zap.String("buildID", buildUUID.String()))
		}

		// Invalidate the cache
		zap.L().Info("开始使模板缓存失效", zap.String("templateID", templateID))
		a.templateCache.Invalidate(templateID)
		zap.L().Info("成功使模板缓存失效", zap.String("templateID", templateID))
	}()

	a.posthog.CreateAnalyticsUserEvent(userID.String(), team.ID.String(), "built environment", posthog.NewProperties().
		Set("user_id", userID).
		Set("environment", templateID).
		Set("build_id", buildID).
		Set("duration", time.Since(startTime).String()).
		Set("success", err != nil),
	)

	zap.L().Info("构建请求处理完成", 
		zap.String("templateID", templateID), 
		zap.String("buildID", string(buildID)), 
		zap.String("duration", time.Since(startTime).String()))
	c.Status(http.StatusAccepted)
}
