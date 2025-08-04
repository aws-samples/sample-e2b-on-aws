package orchestrator

import (
	"context"
	_ "embed"
	"errors"
	"fmt"
	"log"
	"net/http"
	"time"

	"go.opentelemetry.io/otel/attribute"
	"go.uber.org/zap"
	"google.golang.org/protobuf/types/known/timestamppb"

	"github.com/e2b-dev/infra/packages/api/internal/api"
	authcache "github.com/e2b-dev/infra/packages/api/internal/cache/auth"
	"github.com/e2b-dev/infra/packages/api/internal/cache/instance"
	"github.com/e2b-dev/infra/packages/api/internal/sandbox"
	"github.com/e2b-dev/infra/packages/api/internal/utils"
	"github.com/e2b-dev/infra/packages/db/queries"
	"github.com/e2b-dev/infra/packages/shared/pkg/grpc/orchestrator"
	"github.com/e2b-dev/infra/packages/shared/pkg/logger"
	"github.com/e2b-dev/infra/packages/shared/pkg/telemetry"
)
	"github.com/e2b-dev/infra/packages/db/queries"
	"github.com/e2b-dev/infra/packages/shared/pkg/grpc/orchestrator"
	"github.com/e2b-dev/infra/packages/shared/pkg/logger"
	"github.com/e2b-dev/infra/packages/shared/pkg/telemetry"
)

const (
	maxNodeRetries       = 3
	leastBusyNodeTimeout = 60 * time.Second

	maxStartingInstancesPerNode = 3
)

var errSandboxCreateFailed = fmt.Errorf("failed to create a new sandbox, if the problem persists, contact us")

func (o *Orchestrator) CreateSandbox(
	ctx context.Context,
	sandboxID,
	executionID,
	alias string,
	team authcache.AuthTeamInfo,
	build queries.EnvBuild,
	metadata map[string]string,
	envVars map[string]string,
	startTime time.Time,
	endTime time.Time,
	timeout time.Duration,
	isResume bool,
	clientID *string,
	baseTemplateID string,
	autoPause bool,
	envdAuthToken *string,
) (*api.Sandbox, *api.APIError) {
	childCtx, childSpan := o.tracer.Start(ctx, "create-sandbox")
	defer childSpan.End()

	zap.L().Info("Starting sandbox creation process",
		logger.WithSandboxID(sandboxID),
		zap.String("execution_id", executionID),
		zap.String("team_id", team.Team.ID.String()),
		zap.String("template_id", *build.EnvID),
		zap.String("alias", alias),
		zap.Bool("is_resume", isResume),
		zap.Bool("auto_pause", autoPause),
		zap.Any("metadata", metadata),
	)

	// Check if team has reached max instances
	zap.L().Debug("Checking team sandbox reservation limits",
		logger.WithSandboxID(sandboxID),
		zap.String("team_id", team.Team.ID.String()),
		zap.Int64("max_concurrent_instances", team.Tier.ConcurrentInstances),
	)
	
	releaseTeamSandboxReservation, err := o.instanceCache.Reserve(sandboxID, team.Team.ID, team.Tier.ConcurrentInstances)
	if err != nil {
		var limitErr *instance.ErrSandboxLimitExceeded
		var alreadyErr *instance.ErrAlreadyBeingStarted

		telemetry.ReportCriticalError(ctx, "failed to reserve sandbox for team", err)

		switch {
		case errors.As(err, &limitErr):
			return nil, &api.APIError{
				Code: http.StatusTooManyRequests,
				ClientMsg: fmt.Sprintf(
					"you have reached the maximum number of concurrent E2B sandboxes (%d). If you need more, "+
						"please contact us at 'https://e2b.dev/docs/getting-help'", team.Tier.ConcurrentInstances),
				Err: fmt.Errorf("team '%s' has reached the maximum number of instances (%d)", team.Team.ID, team.Tier.ConcurrentInstances),
			}
		case errors.As(err, &alreadyErr):
			zap.L().Warn("sandbox already being started", logger.WithSandboxID(sandboxID), zap.Error(err))
			return nil, &api.APIError{
				Code:      http.StatusConflict,
				ClientMsg: fmt.Sprintf("Sandbox %s is already being started", sandboxID),
				Err:       err,
			}
		default:
			zap.L().Error("failed to reserve sandbox for team", logger.WithSandboxID(sandboxID), zap.Error(err))
			return nil, &api.APIError{
				Code:      http.StatusInternalServerError,
				ClientMsg: fmt.Sprintf("Failed to create sandbox: %s", err),
				Err:       err,
			}
		}
	}

	zap.L().Info("Team sandbox reservation successful",
		logger.WithSandboxID(sandboxID),
		zap.String("team_id", team.Team.ID.String()),
	)

	telemetry.ReportEvent(childCtx, "Reserved sandbox for team")
	defer releaseTeamSandboxReservation()

	zap.L().Debug("Getting firecracker version features",
		logger.WithSandboxID(sandboxID),
		zap.String("firecracker_version", build.FirecrackerVersion),
	)

	features, err := sandbox.NewVersionInfo(build.FirecrackerVersion)
	if err != nil {
		errMsg := fmt.Errorf("failed to get features for firecracker version '%s': %w", build.FirecrackerVersion, err)

		return nil, &api.APIError{
			Code:      http.StatusInternalServerError,
			ClientMsg: "Failed to get build information for the template",
			Err:       errMsg,
		}
	}

	zap.L().Debug("Firecracker version features retrieved successfully",
		logger.WithSandboxID(sandboxID),
		zap.String("firecracker_version", build.FirecrackerVersion),
		zap.Bool("has_huge_pages", features.HasHugePages()),
	)

	telemetry.ReportEvent(childCtx, "Got FC version info")

	zap.L().Debug("Creating sandbox request configuration",
		logger.WithSandboxID(sandboxID),
		zap.String("execution_id", executionID),
		zap.String("template_id", *build.EnvID),
		zap.String("base_template_id", baseTemplateID),
		zap.Int64("vcpu", build.Vcpu),
		zap.Int64("ram_mb", build.RamMb),
		zap.Int64("max_sandbox_length_hours", team.Tier.MaxLengthHours),
	)

	sbxRequest := &orchestrator.SandboxCreateRequest{
		Sandbox: &orchestrator.SandboxConfig{
			BaseTemplateId:     baseTemplateID,
			TemplateId:         *build.EnvID,
			Alias:              &alias,
			TeamId:             team.Team.ID.String(),
			BuildId:            build.ID.String(),
			SandboxId:          sandboxID,
			ExecutionId:        executionID,
			KernelVersion:      build.KernelVersion,
			FirecrackerVersion: build.FirecrackerVersion,
			EnvdVersion:        *build.EnvdVersion,
			Metadata:           metadata,
			EnvVars:            envVars,
			EnvdAccessToken:    envdAuthToken,
			MaxSandboxLength:   team.Tier.MaxLengthHours,
			HugePages:          features.HasHugePages(),
			RamMb:              build.RamMb,
			Vcpu:               build.Vcpu,
			Snapshot:           isResume,
			AutoPause:          &autoPause,
		},
		StartTime: timestamppb.New(startTime),
		EndTime:   timestamppb.New(endTime),
	}

	var node *Node

	if isResume && clientID != nil {
		zap.L().Info("Attempting to place sandbox on specific node for resume",
			logger.WithSandboxID(sandboxID),
			zap.String("target_client_id", *clientID),
		)
		
		telemetry.ReportEvent(childCtx, "Placing sandbox on the node where the snapshot was taken")

		node, _ = o.nodes.Get(*clientID)
		if node != nil && node.Status() != api.NodeStatusReady {
			zap.L().Warn("Target node for resume is not ready, will select different node",
				logger.WithSandboxID(sandboxID),
				zap.String("target_client_id", *clientID),
				zap.String("node_status", string(node.Status())),
			)
			node = nil
		} else if node != nil {
			zap.L().Info("Successfully selected target node for resume",
				logger.WithSandboxID(sandboxID),
				zap.String("selected_node_id", node.Info.ID),
			)
		} else {
			zap.L().Warn("Target node for resume not found, will select different node",
				logger.WithSandboxID(sandboxID),
				zap.String("target_client_id", *clientID),
			)
		}
	}

	zap.L().Debug("Starting node selection and sandbox creation loop",
		logger.WithSandboxID(sandboxID),
		zap.Int("max_retries", maxNodeRetries),
	)

	attempt := 1
	nodesExcluded := make(map[string]*Node)
	for {
		zap.L().Debug("Starting sandbox creation attempt",
			logger.WithSandboxID(sandboxID),
			zap.Int("attempt", attempt),
			zap.Int("max_attempts", maxNodeRetries),
		)

		select {
		case <-childCtx.Done():
			zap.L().Error("Sandbox creation timed out",
				logger.WithSandboxID(sandboxID),
				zap.Int("attempt", attempt),
				zap.Error(childCtx.Err()),
			)
			return nil, &api.APIError{
				Code:      http.StatusRequestTimeout,
				ClientMsg: "Failed to create sandbox",
				Err:       fmt.Errorf("timeout while creating sandbox, attempt #%d", attempt),
			}
		default:
			// Continue
		}

		if attempt > maxNodeRetries {
			zap.L().Error("Exceeded maximum retry attempts for sandbox creation",
				logger.WithSandboxID(sandboxID),
				zap.Int("max_attempts", maxNodeRetries),
			)
			return nil, &api.APIError{
				Code:      http.StatusInternalServerError,
				ClientMsg: "Failed to create sandbox",
				Err:       errSandboxCreateFailed,
			}
		}

		if node == nil {
			zap.L().Debug("Selecting least busy node for sandbox creation",
				logger.WithSandboxID(sandboxID),
				zap.Int("excluded_nodes_count", len(nodesExcluded)),
			)
			
			node, err = o.getLeastBusyNode(childCtx, nodesExcluded)
			if err != nil {
				zap.L().Error("Failed to get least busy node",
					logger.WithSandboxID(sandboxID),
					zap.Error(err),
				)
				telemetry.ReportError(childCtx, "failed to get least busy node", err)

				return nil, &api.APIError{
					Code:      http.StatusInternalServerError,
					ClientMsg: "Failed to get node to place sandbox on.",
					Err:       fmt.Errorf("failed to get least busy node: %w", err),
				}
			}
			
			zap.L().Info("Selected node for sandbox creation",
				logger.WithSandboxID(sandboxID),
				zap.String("selected_node_id", node.Info.ID),
				zap.String("node_ip", node.Info.IPAddress),
				zap.Int64("node_cpu_usage", node.CPUUsage.Load()),
				zap.Int64("node_ram_usage", node.RamUsage.Load()),
			)
		}

		// To creating a lot of sandboxes at once on the same node
		zap.L().Debug("Marking sandbox as in progress on node",
			logger.WithSandboxID(sandboxID),
			zap.String("node_id", node.Info.ID),
			zap.Int64("sandbox_ram_mb", build.RamMb),
			zap.Int64("sandbox_vcpu", build.Vcpu),
		)
		
		node.sbxsInProgress.Insert(sandboxID, &sbxInProgress{
			MiBMemory: build.RamMb,
			CPUs:      build.Vcpu,
		})

		zap.L().Info("Sending sandbox creation request to orchestrator node",
			logger.WithSandboxID(sandboxID),
			zap.String("node_id", node.Info.ID),
			zap.String("execution_id", executionID),
			zap.Int("attempt", attempt),
		)

		_, err = node.Client.Sandbox.Create(childCtx, sbxRequest)
		// The request is done, we will either add it to the cache or remove it from the node
		if err == nil {
			zap.L().Info("Sandbox creation successful on orchestrator node",
				logger.WithSandboxID(sandboxID),
				zap.String("node_id", node.Info.ID),
				zap.Int("attempt", attempt),
			)
			// The sandbox was created successfully
			break
		}

		zap.L().Warn("Sandbox creation failed on node, will retry on different node",
			logger.WithSandboxID(sandboxID),
			zap.String("failed_node_id", node.Info.ID),
			zap.Int("attempt", attempt),
			zap.Error(utils.UnwrapGRPCError(err)),
		)

		node.sbxsInProgress.Remove(sandboxID)

		log.Printf("failed to create sandbox '%s' on node '%s', attempt #%d: %v", sandboxID, node.Info.ID, attempt, utils.UnwrapGRPCError(err))

		// The node is not available, try again with another node
		node.createFails.Add(1)
		nodesExcluded[node.Info.ID] = node
		node = nil
		attempt += 1
	}

	// The build should be cached on the node now
	node.InsertBuild(build.ID.String())

	// The sandbox was created successfully, the resources will be counted in cache
	defer node.sbxsInProgress.Remove(sandboxID)

	zap.L().Info("Sandbox successfully created on orchestrator node",
		logger.WithSandboxID(sandboxID),
		zap.String("node_id", node.Info.ID),
		zap.String("execution_id", executionID),
	)

	telemetry.SetAttributes(childCtx, attribute.String("node.id", node.Info.ID))
	telemetry.ReportEvent(childCtx, "Created sandbox")

	zap.L().Debug("Creating sandbox API object",
		logger.WithSandboxID(sandboxID),
		zap.String("client_id", node.Info.ID),
		zap.String("template_id", *build.EnvID),
		zap.String("envd_version", *build.EnvdVersion),
	)

	sbx := api.Sandbox{
		ClientID:        node.Info.ID,
		SandboxID:       sandboxID,
		TemplateID:      *build.EnvID,
		Alias:           &alias,
		EnvdVersion:     *build.EnvdVersion,
		EnvdAccessToken: envdAuthToken,
	}

	// This is to compensate for the time it takes to start the instance
	// Otherwise it could cause the instance to expire before user has a chance to use it
	startTime = time.Now()
	endTime = startTime.Add(timeout)

	zap.L().Debug("Creating instance info for cache",
		logger.WithSandboxID(sandboxID),
		zap.String("execution_id", executionID),
		zap.String("team_id", team.Team.ID.String()),
		zap.String("build_id", build.ID.String()),
		zap.Time("start_time", startTime),
		zap.Time("end_time", endTime),
		zap.Duration("timeout", timeout),
		zap.Int64("vcpu", build.Vcpu),
		zap.Int64("ram_mb", build.RamMb),
		zap.Int64("total_disk_mb", *build.TotalDiskSizeMb),
		zap.Bool("auto_pause", autoPause),
	)

	instanceInfo := instance.NewInstanceInfo(
		&sbx,
		executionID,
		&team.Team.ID,
		&build.ID,
		metadata,
		time.Duration(team.Tier.MaxLengthHours)*time.Hour,
		startTime,
		endTime,
		build.Vcpu,
		*build.TotalDiskSizeMb,
		build.RamMb,
		build.KernelVersion,
		build.FirecrackerVersion,
		*build.EnvdVersion,
		node.Info,
		autoPause,
		envdAuthToken,
		baseTemplateID,
	)

	zap.L().Info("Adding sandbox to instance cache - this will trigger Redis catalog creation",
		logger.WithSandboxID(sandboxID),
		zap.String("execution_id", executionID),
		zap.String("node_id", node.Info.ID),
		zap.String("team_id", team.Team.ID.String()),
	)

	cacheErr := o.instanceCache.Add(childCtx, instanceInfo, true)
	if cacheErr != nil {
		zap.L().Error("Failed to add sandbox to instance cache",
			logger.WithSandboxID(sandboxID),
			zap.String("execution_id", executionID),
			zap.Error(cacheErr),
		)
		
		telemetry.ReportError(ctx, "error when adding instance to cache", cacheErr)

		zap.L().Warn("Attempting to delete sandbox due to cache error",
			logger.WithSandboxID(sandboxID),
		)

		deleted := o.DeleteInstance(childCtx, sbx.SandboxID, false)
		if !deleted {
			zap.L().Error("Failed to delete sandbox after cache error - sandbox may be orphaned",
				logger.WithSandboxID(sandboxID),
			)
			telemetry.ReportEvent(ctx, "instance wasn't found in cache when deleting")
		} else {
			zap.L().Info("Successfully deleted sandbox after cache error",
				logger.WithSandboxID(sandboxID),
			)
		}

		return nil, &api.APIError{
			Code:      http.StatusInternalServerError,
			ClientMsg: "Failed to create sandbox",
			Err:       fmt.Errorf("error when adding instance to cache: %w", cacheErr),
		}
	}

	zap.L().Info("Sandbox creation process completed successfully",
		logger.WithSandboxID(sandboxID),
		zap.String("execution_id", executionID),
		zap.String("client_id", sbx.ClientID),
		zap.String("template_id", sbx.TemplateID),
		zap.Time("start_time", startTime),
		zap.Time("end_time", endTime),
	)

	return &sbx, nil
}

// getLeastBusyNode returns the least busy node, if there are no eligible nodes, it tries until one is available or the context timeouts
func (o *Orchestrator) getLeastBusyNode(parentCtx context.Context, nodesExcluded map[string]*Node) (leastBusyNode *Node, err error) {
	ctx, cancel := context.WithTimeout(parentCtx, leastBusyNodeTimeout)
	defer cancel()

	childCtx, childSpan := o.tracer.Start(ctx, "get-least-busy-node")
	defer childSpan.End()

	// Try to find a node without waiting
	leastBusyNode, err = o.findLeastBusyNode(nodesExcluded)
	if err == nil {
		return leastBusyNode, nil
	}

	// If no node is available, wait for a bit and try again
	ticker := time.NewTicker(10 * time.Millisecond)
	for {
		select {
		case <-childCtx.Done():
			return nil, childCtx.Err()
		case <-ticker.C:
			// If no node is available, wait for a bit and try again
			leastBusyNode, err = o.findLeastBusyNode(nodesExcluded)
			if err == nil {
				return leastBusyNode, nil
			}
		}
	}
}

// findLeastBusyNode finds the least busy node that is ready and not in the excluded list
// if no node is available, returns an error
func (o *Orchestrator) findLeastBusyNode(nodesExcluded map[string]*Node) (leastBusyNode *Node, err error) {
	for _, node := range o.nodes.Items() {
		// The node might be nil if it was removed from the list while iterating
		if node == nil {
			continue
		}

		// If the node is not ready, skip it
		if node.Status() != api.NodeStatusReady {
			continue
		}

		// Skip already tried nodes
		if nodesExcluded[node.Info.ID] != nil {
			continue
		}

		// To prevent overloading the node
		if node.sbxsInProgress.Count() > maxStartingInstancesPerNode {
			continue
		}

		cpuUsage := int64(0)
		for _, sbx := range node.sbxsInProgress.Items() {
			cpuUsage += sbx.CPUs
		}

		if leastBusyNode == nil || (node.CPUUsage.Load()+cpuUsage) < leastBusyNode.CPUUsage.Load() {
			leastBusyNode = node
		}
	}

	if leastBusyNode != nil {
		return leastBusyNode, nil
	}

	return nil, fmt.Errorf("no node available")
}
