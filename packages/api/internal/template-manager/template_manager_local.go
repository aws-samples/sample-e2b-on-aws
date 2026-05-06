package template_manager

import (
	"context"
	"time"

	"go.uber.org/zap"
	"google.golang.org/protobuf/types/known/emptypb"

	"github.com/e2b-dev/infra/packages/api/internal/utils"
	orchestratorinfo "github.com/e2b-dev/infra/packages/shared/pkg/grpc/orchestrator-info"
)

var (
	healthCheckInterval = 5 * time.Second
	healthCheckTimeout  = 5 * time.Second
)

func (tm *TemplateManager) localClientPeriodicHealthSync(ctx context.Context) {
	// Initial health check to set the initial status
	tm.localClientHealthSync(ctx)

	ticker := time.NewTicker(healthCheckInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			tm.localClientHealthSync(ctx)
		}
	}
}

func (tm *TemplateManager) localClientHealthSync(ctx context.Context) {
	zap.L().Debug("starting to check template manager health status",
		zap.String("templateManagerHost", templateManagerHost))
	
	reqCtx, reqCtxCancel := context.WithTimeout(ctx, healthCheckTimeout)
	res, err := tm.localClient.Info.ServiceInfo(reqCtx, &emptypb.Empty{})
	reqCtxCancel()

	err = utils.UnwrapGRPCError(err)
	if err != nil {
		zap.L().Error("failed to get template manager health status",
			zap.String("templateManagerHost", templateManagerHost), 
			zap.Error(err))
		tm.setLocalClientStatus(orchestratorinfo.ServiceInfoStatus_OrchestratorUnhealthy)
		return
	}

	zap.L().Debug("successfully got template manager health status",
		zap.String("templateManagerHost", templateManagerHost), 
		zap.String("status", res.ServiceStatus.String()))
	tm.setLocalClientStatus(res.ServiceStatus)
}

func (tm *TemplateManager) setLocalClientStatus(s orchestratorinfo.ServiceInfoStatus) {
	tm.localClientMutex.Lock()
	defer tm.localClientMutex.Unlock()
	
	oldStatus := tm.localClientStatus
	tm.localClientStatus = s
	
	if oldStatus != s {
		zap.L().Info("template manager health status changed",
			zap.String("oldStatus", oldStatus.String()), 
			zap.String("newStatus", s.String()))
	}
}

func (tm *TemplateManager) GetLocalClientStatus() orchestratorinfo.ServiceInfoStatus {
	tm.localClientMutex.RLock() // Use read lock
    defer tm.localClientMutex.RUnlock()
    return tm.localClientStatus
}
