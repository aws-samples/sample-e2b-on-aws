package server

import (
	"context"
	"errors"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/ecr"
	"github.com/e2b-dev/infra/packages/shared/pkg/consts"
	"go.opentelemetry.io/otel/trace"
	"go.uber.org/zap"

	"github.com/e2b-dev/infra/packages/orchestrator/internal/grpcserver"
	"github.com/e2b-dev/infra/packages/orchestrator/internal/proxy"
	"github.com/e2b-dev/infra/packages/orchestrator/internal/sandbox"
	"github.com/e2b-dev/infra/packages/orchestrator/internal/sandbox/nbd"
	"github.com/e2b-dev/infra/packages/orchestrator/internal/sandbox/network"
	"github.com/e2b-dev/infra/packages/orchestrator/internal/template/build"
	"github.com/e2b-dev/infra/packages/orchestrator/internal/template/cache"
	"github.com/e2b-dev/infra/packages/orchestrator/internal/template/constants"
	"github.com/e2b-dev/infra/packages/orchestrator/internal/template/template"
	"github.com/e2b-dev/infra/packages/shared/pkg/env"
	templatemanager "github.com/e2b-dev/infra/packages/shared/pkg/grpc/template-manager"
	"github.com/e2b-dev/infra/packages/shared/pkg/smap"
	"github.com/e2b-dev/infra/packages/shared/pkg/storage"
)

type ServerStore struct {
	templatemanager.UnimplementedTemplateServiceServer
	tracer          trace.Tracer
	logger          *zap.Logger
	builder         *build.TemplateBuilder
	buildCache      *cache.BuildCache
	buildLogger     *zap.Logger
	templateStorage *template.Storage
	ecrClient       *ecr.Client
	healthStatus    templatemanager.HealthState
	wg              *sync.WaitGroup // wait group for running builds
}

func New(ctx context.Context,
	tracer trace.Tracer,
	logger *zap.Logger,
	buildLogger *zap.Logger,
	grpc *grpcserver.GRPCServer,
	networkPool *network.Pool,
	devicePool *nbd.DevicePool,
	proxy *proxy.SandboxProxy,
	sandboxes *smap.Map[*sandbox.Sandbox],
) (*ServerStore, error) {
	// Template Manager Initialization
	if err := constants.CheckRequired(); err != nil {
		log.Fatalf("Validation for environment variables failed: %v", err)
	}

	logger.Info("Initializing template manager")

	// Create AWS session and ECR client
	cfg, err := config.LoadDefaultConfig(ctx,
		config.WithRegion(consts.AWSRegion),
	)

	if err != nil {
		return nil, fmt.Errorf("error creating artifact registry client: %v", err)
	}
	ecrClient := ecr.NewFromConfig(cfg)
	persistence, err := storage.GetTemplateStorageProvider(ctx)
	if err != nil {
		return nil, fmt.Errorf("error getting template storage provider: %v", err)
	}

	templateStorage := template.NewStorage(persistence)
	buildCache := cache.NewBuildCache()
	builder := build.NewBuilder(
		logger,
		buildLogger,
		tracer,
		templateStorage,
		buildCache,
		persistence,
		devicePool,
		networkPool,
		proxy,
		sandboxes,
	)
	store := &ServerStore{
		tracer:          tracer,
		logger:          logger,
		builder:         builder,
		buildCache:      buildCache,
		buildLogger:     buildLogger,
		ecrClient:       ecrClient,
		templateStorage: templateStorage,
		healthStatus:    templatemanager.HealthState_Healthy,
		wg:              &sync.WaitGroup{},
	}

	templatemanager.RegisterTemplateServiceServer(grpc.GRPCServer(), store)

	return store, nil
}

func (s *ServerStore) Close(ctx context.Context) error {
	select {
	case <-ctx.Done():
		return errors.New("context canceled during server graceful shutdown")
	default:
		// no new jobs should be started
		s.logger.Info("marking service as draining")
		s.healthStatus = templatemanager.HealthState_Draining
		// wait for registering the node as draining
		if !env.IsLocal() {
			time.Sleep(5 * time.Second)
		}

		// wait for all builds to finish
		s.logger.Info("waiting for all jobs to finish")
		s.wg.Wait()

		if !env.IsLocal() {
			// give some time so all connected services can check build status
			s.logger.Info("waiting before shutting down server")
			time.Sleep(15 * time.Second)
		}
		return nil
	}
}
