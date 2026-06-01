//go:build linux
// +build linux

package sandbox

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/google/uuid"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
	"go.uber.org/zap"

	"github.com/e2b-dev/infra/packages/orchestrator/internal/sandbox/block"
	"github.com/e2b-dev/infra/packages/orchestrator/internal/sandbox/build"
	"github.com/e2b-dev/infra/packages/orchestrator/internal/sandbox/fc"
	"github.com/e2b-dev/infra/packages/orchestrator/internal/sandbox/lifecycle"
	"github.com/e2b-dev/infra/packages/orchestrator/internal/sandbox/nbd"
	"github.com/e2b-dev/infra/packages/orchestrator/internal/sandbox/network"
	"github.com/e2b-dev/infra/packages/orchestrator/internal/sandbox/rootfs"
	"github.com/e2b-dev/infra/packages/orchestrator/internal/sandbox/template"
	"github.com/e2b-dev/infra/packages/orchestrator/internal/sandbox/uffd"
	"github.com/e2b-dev/infra/packages/shared/pkg/env"
	"github.com/e2b-dev/infra/packages/shared/pkg/grpc/orchestrator"
	"github.com/e2b-dev/infra/packages/shared/pkg/logger"
	sbxlogger "github.com/e2b-dev/infra/packages/shared/pkg/logger/sandbox"
	"github.com/e2b-dev/infra/packages/shared/pkg/storage"
	"github.com/e2b-dev/infra/packages/shared/pkg/storage/header"
	"github.com/e2b-dev/infra/packages/shared/pkg/telemetry"
	"github.com/e2b-dev/infra/packages/shared/pkg/utils"
)

var defaultEnvdTimeout = utils.Must(time.ParseDuration(env.GetEnv("ENVD_TIMEOUT", "30s")))

var httpClient = http.Client{
	Timeout: 10 * time.Second,
}

type Resources struct {
	Slot     *network.Slot
	rootfs   rootfs.Provider
	memory   uffd.MemoryBackend
	uffdExit chan error
}

type Metadata struct {
	Config    *orchestrator.SandboxConfig
	StartedAt time.Time
	EndAt     time.Time
}

type Sandbox struct {
	*Resources
	*Metadata

	files   *storage.SandboxFiles
	cleanup *Cleanup

	process *fc.Process

	template template.Template

	Checks *Checks
}

type fetchStatsProvider interface {
	FetchStats() lifecycle.StorageStats
}

func fetchStats(device block.ReadonlyDevice) lifecycle.StorageStats {
	provider, ok := device.(fetchStatsProvider)
	if !ok {
		return lifecycle.StorageStats{}
	}

	return provider.FetchStats()
}

func logStorageDownloadSummary(ctx context.Context, operation, phase, dataKind, sandboxID string, stats lifecycle.StorageStats) {
	lifecycle.RecordStorageDownload(ctx, operation, phase, dataKind, stats)
	if stats.DownloadChunks == 0 && stats.DownloadBytes == 0 && stats.CacheMisses == 0 {
		return
	}

	zap.L().Info("storage download summary",
		logger.WithSandboxID(sandboxID),
		zap.String("operation", operation),
		zap.String("phase", phase),
		zap.String("data_kind", dataKind),
		zap.String("storage_provider", stats.SourceKind),
		zap.Uint64("cache_hit_count", stats.CacheHits),
		zap.Uint64("cache_miss_count", stats.CacheMisses),
		zap.Uint64("s3_download_chunks", stats.DownloadChunks),
		zap.Uint64("s3_download_bytes", stats.DownloadBytes),
		zap.Uint64("s3_download_pages_equivalent", stats.DownloadPages),
		zap.Duration("s3_download_total", stats.FetchDuration()),
		zap.Duration("s3_get_object_total", stats.BaseReadDuration()),
		zap.Duration("cache_write_total", stats.CacheWriteDuration()),
		zap.Duration("s3_download_max", time.Duration(stats.MaxFetchNanos)),
		zap.Duration("s3_get_object_max", time.Duration(stats.MaxBaseReadNanos)),
		zap.Duration("cache_write_max", time.Duration(stats.MaxCacheWriteNanos)),
	)
}

func (m *Metadata) LoggerMetadata() sbxlogger.SandboxMetadata {
	return sbxlogger.SandboxMetadata{
		SandboxID:  m.Config.SandboxId,
		TemplateID: m.Config.TemplateId,
		TeamID:     m.Config.TeamId,
	}
}

type networkSlotRes struct {
	slot *network.Slot
	err  error
}

func CreateSandbox(
	ctx context.Context,
	tracer trace.Tracer,
	networkPool *network.Pool,
	_ *nbd.DevicePool,
	config *orchestrator.SandboxConfig,
	template template.Template,
	sandboxTimeout time.Duration,
	rootfsCachePath string,
	processOptions fc.ProcessOptions,
	allowInternet bool,
) (*Sandbox, *Cleanup, error) {
	childCtx, childSpan := tracer.Start(ctx, "new-sandbox")
	defer childSpan.End()

	cleanup := NewCleanup()

	ipsCh := getNetworkSlotAsync(childCtx, tracer, networkPool, cleanup, allowInternet)
	defer func() {
		// Ensure the slot is received from chan so the slot is cleaned up properly in cleanup
		<-ipsCh
	}()

	sandboxFiles := template.Files().NewSandboxFiles(config.SandboxId)
	cleanup.Add(func(ctx context.Context) error {
		filesErr := cleanupFiles(sandboxFiles)
		if filesErr != nil {
			return fmt.Errorf("failed to cleanup files: %w", filesErr)
		}

		return nil
	})

	rootFS, err := template.Rootfs()
	if err != nil {
		return nil, cleanup, fmt.Errorf("failed to get rootfs: %w", err)
	}

	rootfsProvider, err := rootfs.NewDirectProvider(
		tracer,
		rootFS,
		// Populate direct cache directly from the source file
		// This is needed for marking all blocks as dirty and being able to read them directly
		rootfsCachePath,
	)
	if err != nil {
		return nil, cleanup, fmt.Errorf("failed to create rootfs overlay: %w", err)
	}
	cleanup.Add(func(ctx context.Context) error {
		return rootfsProvider.Close(ctx)
	})
	go func() {
		runErr := rootfsProvider.Start(childCtx)
		if runErr != nil {
			zap.L().Error("rootfs overlay error", zap.Error(runErr))
		}
	}()

	memfile, err := template.Memfile()
	if err != nil {
		return nil, cleanup, fmt.Errorf("failed to get memfile: %w", err)
	}

	memfileSize, err := memfile.Size()
	if err != nil {
		return nil, cleanup, fmt.Errorf("failed to get memfile size: %w", err)
	}

	// / ==== END of resources initialization ====
	rootfsPath, err := rootfsProvider.Path()
	if err != nil {
		return nil, cleanup, fmt.Errorf("failed to get rootfs path: %w", err)
	}
	ips := <-ipsCh
	if ips.err != nil {
		return nil, cleanup, fmt.Errorf("failed to get network slot: %w", err)
	}
	fcHandle, err := fc.NewProcess(
		childCtx,
		tracer,
		ips.slot,
		sandboxFiles,
		rootfsPath,
		config.BaseTemplateId,
		config.BuildId,
	)
	if err != nil {
		return nil, cleanup, fmt.Errorf("failed to init FC: %w", err)
	}

	telemetry.ReportEvent(childCtx, "created fc client")

	err = fcHandle.Create(
		childCtx,
		tracer,
		config.SandboxId,
		config.TemplateId,
		config.TeamId,
		config.Vcpu,
		config.RamMb,
		config.HugePages,
		processOptions,
	)
	if err != nil {
		return nil, cleanup, fmt.Errorf("failed to create FC: %w", err)
	}
	telemetry.ReportEvent(childCtx, "created fc process")

	resources := &Resources{
		Slot:     ips.slot,
		rootfs:   rootfsProvider,
		memory:   uffd.NewNoopMemory(memfileSize, memfile.BlockSize()),
		uffdExit: make(chan error, 1),
	}

	metadata := &Metadata{
		Config: config,

		StartedAt: time.Now(),
		EndAt:     time.Now().Add(sandboxTimeout),
	}

	sbx := &Sandbox{
		Resources: resources,
		Metadata:  metadata,

		template: template,
		files:    sandboxFiles,
		process:  fcHandle,

		cleanup: cleanup,
	}

	checks, err := NewChecks(ctx, tracer, sbx, false)
	if err != nil {
		return nil, cleanup, fmt.Errorf("failed to create health check: %w", err)
	}
	sbx.Checks = checks

	cleanup.AddPriority(func(ctx context.Context) error {
		return sbx.Close(ctx, tracer)
	})

	return sbx, cleanup, nil
}

// ResumeSandbox resumes the sandbox from already saved template or snapshot.
// IMPORTANT: You have to run cleanup functions for the already initialized resources even if there is any error,
// or after you are done with the started sandbox.
func ResumeSandbox(
	ctx context.Context,
	tracer trace.Tracer,
	networkPool *network.Pool,
	templateCache *template.Cache,
	config *orchestrator.SandboxConfig,
	traceID string,
	startedAt time.Time,
	endAt time.Time,
	baseTemplateID string,
	devicePool *nbd.DevicePool,
	allowInternet,
	useClickhouseMetrics bool,
) (sbx *Sandbox, cleanup *Cleanup, e error) {
	resumeStart := time.Now()
	operation := lifecycle.Operation(config.Snapshot)
	stageTimings := lifecycle.NewStageTimings()

	childCtx, childSpan := tracer.Start(ctx, "new-sandbox")
	defer childSpan.End()
	defer func() {
		totalDuration := time.Since(resumeStart)
		lifecycle.RecordLifecycle(childCtx, operation, totalDuration, e)

		result := lifecycle.ResultOK
		if e != nil {
			result = lifecycle.ResultError
		}

		fields := []zap.Field{
			logger.WithSandboxID(config.SandboxId),
			zap.String("operation", operation),
			zap.String("result", result),
			zap.String("template_id", config.TemplateId),
			zap.String("base_template_id", baseTemplateID),
			zap.String("build_id", config.BuildId),
			zap.String("trace_id", traceID),
			zap.Bool("snapshot", config.Snapshot),
			zap.Duration("total_duration", totalDuration),
			zap.Error(e),
		}
		fields = append(fields, stageTimings.ZapFields()...)
		zap.L().Info("sandbox lifecycle summary", fields...)
	}()

	logResumeTiming("sandbox_resume_start",
		logger.WithSandboxID(config.SandboxId),
		zap.String("operation", operation),
		zap.String("template_id", config.TemplateId),
		zap.String("base_template_id", baseTemplateID),
		zap.String("build_id", config.BuildId),
		zap.String("trace_id", traceID),
	)

	cleanup = NewCleanup()

	templateStart := time.Now()
	t, err := templateCache.GetTemplate(
		config.TemplateId,
		config.BuildId,
		config.KernelVersion,
		config.FirecrackerVersion,
	)
	templateDuration := stageTimings.Record(childCtx, operation, "template_get", templateStart, err)
	logResumeTiming("sandbox_resume_template_get_done",
		logger.WithSandboxID(config.SandboxId),
		zap.Duration("duration", templateDuration),
		zap.Error(err),
	)
	if err != nil {
		return nil, cleanup, fmt.Errorf("failed to get template snapshot data: %w", err)
	}

	ipsCh := getNetworkSlotAsync(childCtx, tracer, networkPool, cleanup, allowInternet)
	defer func() {
		// Ensure the slot is received from chan so the slot is cleaned up properly in cleanup
		<-ipsCh
	}()

	sandboxFiles := t.Files().NewSandboxFiles(config.SandboxId)
	cleanup.Add(func(ctx context.Context) error {
		filesErr := cleanupFiles(sandboxFiles)
		if filesErr != nil {
			return fmt.Errorf("failed to cleanup files: %w", filesErr)
		}

		return nil
	})

	rootfsStart := time.Now()
	readonlyRootfs, err := t.Rootfs()
	rootfsDuration := stageTimings.Record(childCtx, operation, "rootfs_open", rootfsStart, err)
	logResumeTiming("sandbox_resume_rootfs_open_done",
		logger.WithSandboxID(config.SandboxId),
		zap.Duration("duration", rootfsDuration),
		zap.Error(err),
	)
	if err != nil {
		return nil, cleanup, fmt.Errorf("failed to get rootfs: %w", err)
	}

	rootfsOverlayStart := time.Now()
	rootfsOverlay, err := createRootfsOverlay(
		childCtx,
		tracer,
		devicePool,
		cleanup,
		readonlyRootfs,
		sandboxFiles.SandboxCacheRootfsPath(),
	)
	rootfsOverlayDuration := stageTimings.Record(childCtx, operation, "rootfs_overlay", rootfsOverlayStart, err)
	logResumeTiming("sandbox_resume_rootfs_overlay_done",
		logger.WithSandboxID(config.SandboxId),
		zap.Duration("duration", rootfsOverlayDuration),
		zap.Error(err),
	)
	if err != nil {
		return nil, cleanup, fmt.Errorf("failed to create rootfs overlay: %w", err)
	}

	go func() {
		runErr := rootfsOverlay.Start(childCtx)
		if runErr != nil {
			zap.L().Error("rootfs overlay error", zap.Error(runErr))
		}
	}()

	memfileStart := time.Now()
	memfile, err := t.Memfile()
	memfileDuration := stageTimings.Record(childCtx, operation, "memfile_open", memfileStart, err)
	logResumeTiming("sandbox_resume_memfile_open_done",
		logger.WithSandboxID(config.SandboxId),
		zap.Duration("duration", memfileDuration),
		zap.Error(err),
	)
	if err != nil {
		return nil, cleanup, fmt.Errorf("failed to get memfile: %w", err)
	}

	fcUffdPath := sandboxFiles.SandboxUffdSocketPath()

	serveMemoryStart := time.Now()
	fcUffd, err := serveMemory(
		childCtx,
		tracer,
		cleanup,
		memfile,
		fcUffdPath,
		config.SandboxId,
	)
	serveMemoryDuration := stageTimings.Record(childCtx, operation, "serve_memory", serveMemoryStart, err)
	logResumeTiming("sandbox_resume_serve_memory_done",
		logger.WithSandboxID(config.SandboxId),
		zap.String("uffd_socket_path", fcUffdPath),
		zap.Duration("duration", serveMemoryDuration),
		zap.Error(err),
	)
	if err != nil {
		return nil, cleanup, fmt.Errorf("failed to serve memory: %w", err)
	}

	uffdStartCtx, cancelUffdStartCtx := context.WithCancelCause(ctx)
	defer cancelUffdStartCtx(fmt.Errorf("uffd finished starting"))

	uffdExit := make(chan error, 1)
	go func() {
		uffdWaitErr := <-fcUffd.Exit()
		uffdExit <- uffdWaitErr

		cancelUffdStartCtx(fmt.Errorf("uffd process exited: %w", errors.Join(uffdWaitErr, context.Cause(uffdStartCtx))))
	}()

	// / ==== END of resources initialization ====
	rootfsPathStart := time.Now()
	rootfsPath, err := rootfsOverlay.Path()
	rootfsPathDuration := stageTimings.Record(childCtx, operation, "rootfs_path", rootfsPathStart, err)
	logResumeTiming("sandbox_resume_rootfs_path_done",
		logger.WithSandboxID(config.SandboxId),
		zap.Duration("duration", rootfsPathDuration),
		zap.Error(err),
	)
	if err != nil {
		return nil, cleanup, fmt.Errorf("failed to get rootfs path: %w", err)
	}
	networkSlotStart := time.Now()
	ips := <-ipsCh
	networkSlotDuration := stageTimings.Record(childCtx, operation, "network_slot", networkSlotStart, ips.err)
	logResumeTiming("sandbox_resume_network_slot_done",
		logger.WithSandboxID(config.SandboxId),
		zap.Duration("duration", networkSlotDuration),
		zap.Error(ips.err),
	)
	if ips.err != nil {
		return nil, cleanup, fmt.Errorf("failed to get network slot: %w", err)
	}
	fcNewStart := time.Now()
	fcHandle, fcErr := fc.NewProcess(
		uffdStartCtx,
		tracer,
		ips.slot,
		sandboxFiles,
		rootfsPath,
		baseTemplateID,
		readonlyRootfs.Header().Metadata.BaseBuildId.String(),
	)
	fcNewDuration := stageTimings.Record(childCtx, operation, "fc_new_process", fcNewStart, fcErr)
	logResumeTiming("sandbox_resume_fc_new_process_done",
		logger.WithSandboxID(config.SandboxId),
		zap.Duration("duration", fcNewDuration),
		zap.Error(fcErr),
	)
	if fcErr != nil {
		return nil, cleanup, fmt.Errorf("failed to create FC: %w", fcErr)
	}

	// todo: check if kernel, firecracker, and envd versions exist
	snapfileStart := time.Now()
	snapfile, err := t.Snapfile()
	snapfileDuration := stageTimings.Record(childCtx, operation, "snapfile_open", snapfileStart, err)
	logResumeTiming("sandbox_resume_snapfile_open_done",
		logger.WithSandboxID(config.SandboxId),
		zap.Duration("duration", snapfileDuration),
		zap.Error(err),
	)
	if err != nil {
		return nil, cleanup, fmt.Errorf("failed to get snapfile: %w", err)
	}
	fcResumeStart := time.Now()
	fcStartErr := fcHandle.Resume(
		uffdStartCtx,
		tracer,
		&fc.MmdsMetadata{
			SandboxId:            config.SandboxId,
			TemplateId:           config.TemplateId,
			LogsCollectorAddress: os.Getenv("LOGS_COLLECTOR_PUBLIC_IP"),
			TraceId:              traceID,
			TeamId:               config.TeamId,
		},
		fcUffdPath,
		snapfile,
		fcUffd.Ready(),
	)
	fcResumeDuration := stageTimings.Record(childCtx, operation, "fc_resume", fcResumeStart, fcStartErr)
	logResumeTiming("sandbox_resume_fc_resume_done",
		logger.WithSandboxID(config.SandboxId),
		zap.Duration("duration", fcResumeDuration),
		zap.Error(fcStartErr),
	)
	if fcStartErr != nil {
		return nil, cleanup, fmt.Errorf("failed to start FC: %w", fcStartErr)
	}

	telemetry.ReportEvent(childCtx, "initialized FC")

	resources := &Resources{
		Slot:     ips.slot,
		rootfs:   rootfsOverlay,
		memory:   fcUffd,
		uffdExit: uffdExit,
	}

	metadata := &Metadata{
		Config: config,

		StartedAt: startedAt,
		EndAt:     endAt,
	}

	sbx = &Sandbox{
		Resources: resources,
		Metadata:  metadata,

		template: t,
		files:    sandboxFiles,
		process:  fcHandle,

		cleanup: cleanup,
	}

	// Part of the sandbox as we need to stop Checks before pausing the sandbox
	// This is to prevent race condition of reporting unhealthy sandbox
	checksStart := time.Now()
	checks, err := NewChecks(ctx, tracer, sbx, useClickhouseMetrics)
	checksDuration := stageTimings.Record(childCtx, operation, "checks_new", checksStart, err)
	logResumeTiming("sandbox_resume_checks_new_done",
		logger.WithSandboxID(config.SandboxId),
		zap.Duration("duration", checksDuration),
		zap.Error(err),
	)
	if err != nil {
		return nil, cleanup, fmt.Errorf("failed to create health check: %w", err)
	}

	sbx.Checks = checks

	sandboxToClose := sbx
	cleanup.AddPriority(func(ctx context.Context) error {
		return sandboxToClose.Close(ctx, tracer)
	})

	waitEnvdStart := time.Now()
	memfileStatsBefore := fetchStats(memfile)
	rootfsStatsBefore := fetchStats(readonlyRootfs)
	uffdStatsBefore := fcUffd.Stats()
	err = sbx.WaitForEnvd(
		ctx,
		tracer,
		defaultEnvdTimeout,
	)
	waitEnvdDuration := stageTimings.Record(childCtx, operation, "wait_envd", waitEnvdStart, err)

	uffdStats := fcUffd.Stats().Sub(uffdStatsBefore)
	lifecycle.RecordUffd(childCtx, operation, "wait_envd", uffdStats)
	zap.L().Info("uffd lifecycle summary",
		logger.WithSandboxID(config.SandboxId),
		zap.String("operation", operation),
		zap.String("phase", "wait_envd"),
		zap.Uint64("fault_count", uffdStats.Faults),
		zap.Uint64("slow_fault_count", uffdStats.SlowFaults),
		zap.Duration("slice_total", uffdStats.SliceDuration()),
		zap.Duration("copy_total", uffdStats.CopyDuration()),
		zap.Duration("fault_total", uffdStats.FaultDuration()),
		zap.Duration("slice_max", time.Duration(uffdStats.MaxSliceNanos)),
		zap.Duration("copy_max", time.Duration(uffdStats.MaxCopyNanos)),
		zap.Duration("fault_max", time.Duration(uffdStats.MaxFaultNanos)),
	)

	logStorageDownloadSummary(childCtx, operation, "wait_envd", "memfile", config.SandboxId, fetchStats(memfile).Sub(memfileStatsBefore))
	logStorageDownloadSummary(childCtx, operation, "wait_envd", "rootfs", config.SandboxId, fetchStats(readonlyRootfs).Sub(rootfsStatsBefore))

	if err != nil {
		return nil, cleanup, fmt.Errorf("failed to wait for sandbox start: %w", err)
	}
	logResumeTiming("sandbox_resume_done",
		logger.WithSandboxID(config.SandboxId),
		zap.Duration("duration", time.Since(resumeStart)),
		zap.Duration("wait_envd_duration", waitEnvdDuration),
	)

	go sbx.Checks.Start()

	return sbx, cleanup, nil
}

func (s *Sandbox) Wait(ctx context.Context) error {
	select {
	case fcErr := <-s.process.Exit:
		stopErr := s.Stop(ctx)
		uffdErr := <-s.uffdExit

		return errors.Join(fcErr, stopErr, uffdErr)
	case uffdErr := <-s.uffdExit:
		stopErr := s.Stop(ctx)
		fcErr := <-s.process.Exit

		return errors.Join(uffdErr, stopErr, fcErr)
	}
}

// Stop starts the cleanup process for the sandbox.
func (s *Sandbox) Stop(ctx context.Context) error {
	err := s.cleanup.Run(ctx)
	if err != nil {
		return fmt.Errorf("failed to stop sandbox: %w", err)
	}

	return nil
}

// Close cleans up the sandbox and stops all resources.
func (s *Sandbox) Close(ctx context.Context, tracer trace.Tracer) error {
	_, span := tracer.Start(ctx, "sandbox-close")
	defer span.End()

	var errs []error

	// Stop the health checks before stopping the sandbox
	s.Checks.Stop()

	fcStopErr := s.process.Stop()
	if fcStopErr != nil {
		errs = append(errs, fmt.Errorf("failed to stop FC: %w", fcStopErr))
	}

	// Wait for FC process to fully exit before cleaning up NBD and COW files.
	// SIGTERM→10s→SIGKILL in Stop() guarantees the process will exit.
	<-s.process.Exited()

	uffdStopErr := s.Resources.memory.Stop()
	if uffdStopErr != nil {
		errs = append(errs, fmt.Errorf("failed to stop uffd: %w", uffdStopErr))
	}

	return errors.Join(errs...)
}

func (s *Sandbox) Pause(
	ctx context.Context,
	tracer trace.Tracer,
	snapshotTemplateFiles *storage.TemplateCacheFiles,
) (*Snapshot, error) {
	childCtx, childSpan := tracer.Start(ctx, "sandbox-snapshot")
	defer childSpan.End()

	buildID, err := uuid.Parse(snapshotTemplateFiles.BuildId)
	if err != nil {
		return nil, fmt.Errorf("failed to parse build id: %w", err)
	}

	// Stop the health check before pausing the VM
	s.Checks.Stop()

	if err := s.process.Pause(childCtx, tracer); err != nil {
		return nil, fmt.Errorf("failed to pause VM: %w", err)
	}

	if err := s.memory.Disable(); err != nil {
		return nil, fmt.Errorf("failed to disable uffd: %w", err)
	}

	// Snapfile is not closed as it's returned and cached for later use (like resume)
	snapfile := template.NewLocalFileLink(snapshotTemplateFiles.CacheSnapfilePath())
	// Memfile is also closed on diff creation processing
	/* The process of snapshotting memory is as follows:
	1. Pause FC via API
	2. Snapshot FC via API—memory dump to “file on disk” that is actually tmpfs, because it is too slow
	3. Create the diff - copy the diff pages from tmpfs to normal disk file
	4. Delete tmpfs file
	5. Unlock so another snapshot can use tmpfs space
	*/
	memfile, err := storage.AcquireTmpMemfile(childCtx, buildID.String())
	if err != nil {
		return nil, fmt.Errorf("failed to acquire memfile snapshot: %w", err)
	}
	// Close the file even if an error occurs
	defer memfile.Close()

	err = s.process.CreateSnapshot(
		childCtx,
		tracer,
		snapfile.Path(),
		memfile.Path(),
	)
	if err != nil {
		return nil, fmt.Errorf("error creating snapshot: %w", err)
	}

	// Gather data for postprocessing
	originalMemfile, err := s.template.Memfile()
	if err != nil {
		return nil, fmt.Errorf("failed to get original memfile: %w", err)
	}
	originalRootfs, err := s.template.Rootfs()
	if err != nil {
		return nil, fmt.Errorf("failed to get original rootfs: %w", err)
	}

	// Start POSTPROCESSING
	memfileDiff, memfileDiffHeader, err := pauseProcessMemory(
		childCtx,
		tracer,
		buildID,
		originalMemfile.Header(),
		&MemoryDiffCreator{
			tracer:     tracer,
			memfile:    memfile,
			dirtyPages: s.memory.Dirty(),
			blockSize:  originalMemfile.BlockSize(),
			doneHook: func(ctx context.Context) error {
				return memfile.Close()
			},
		},
	)
	if err != nil {
		return nil, fmt.Errorf("error while post processing: %w", err)
	}

	rootfsDiff, rootfsDiffHeader, err := pauseProcessRootfs(
		childCtx,
		tracer,
		buildID,
		originalRootfs.Header(),
		&RootfsDiffCreator{
			rootfs:   s.rootfs,
			stopHook: s.Stop,
		},
	)
	if err != nil {
		return nil, fmt.Errorf("error while post processing: %w", err)
	}

	return &Snapshot{
		Snapfile:          snapfile,
		MemfileDiff:       memfileDiff,
		MemfileDiffHeader: memfileDiffHeader,
		RootfsDiff:        rootfsDiff,
		RootfsDiffHeader:  rootfsDiffHeader,
	}, nil
}

type Snapshot struct {
	MemfileDiff       build.Diff
	MemfileDiffHeader *header.Header
	RootfsDiff        build.Diff
	RootfsDiffHeader  *header.Header
	Snapfile          *template.LocalFileLink
}

func (s *Snapshot) Close(_ context.Context) error {
	var errs []error

	if err := s.MemfileDiff.Close(); err != nil {
		errs = append(errs, fmt.Errorf("failed to close memfile diff: %w", err))
	}

	if err := s.RootfsDiff.Close(); err != nil {
		errs = append(errs, fmt.Errorf("failed to close rootfs diff: %w", err))
	}

	if err := s.Snapfile.Close(); err != nil {
		errs = append(errs, fmt.Errorf("failed to close snapfile: %w", err))
	}

	return errors.Join(errs...)
}

func pauseProcessMemory(
	ctx context.Context,
	tracer trace.Tracer,
	buildId uuid.UUID,
	originalHeader *header.Header,
	diffCreator DiffCreator,
) (build.Diff, *header.Header, error) {
	ctx, childSpan := tracer.Start(ctx, "process-memory")
	defer childSpan.End()

	memfileDiffFile, err := build.NewLocalDiffFile(
		build.DefaultCachePath,
		buildId.String(),
		build.Memfile,
	)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to create memfile diff file: %w", err)
	}

	m, err := diffCreator.process(ctx, memfileDiffFile)
	if err != nil {
		return nil, nil, fmt.Errorf("error creating diff: %w", err)
	}
	telemetry.ReportEvent(ctx, "created diff")

	memfileMapping, err := m.CreateMapping(ctx, buildId)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to create memfile mapping: %w", err)
	}

	memfileMappings := header.MergeMappings(
		originalHeader.Mapping,
		memfileMapping,
	)
	// TODO: We can run normalization only when empty mappings are not empty for this snapshot
	memfileMappings = header.NormalizeMappings(memfileMappings)
	telemetry.ReportEvent(ctx, "merged memfile mappings")

	memfileDiff, err := memfileDiffFile.CloseToDiff(int64(originalHeader.Metadata.BlockSize))
	if err != nil {
		return nil, nil, fmt.Errorf("failed to convert memfile diff file to local diff: %w", err)
	}

	telemetry.ReportEvent(ctx, "converted memfile diff file to local diff")

	memfileMetadata := originalHeader.Metadata.NextGeneration(buildId)

	telemetry.SetAttributes(ctx,
		attribute.Int64("snapshot.memfile.header.mappings.length", int64(len(memfileMappings))),
		attribute.Int64("snapshot.memfile.diff.size", int64(m.Dirty.Count()*uint(originalHeader.Metadata.BlockSize))),
		attribute.Int64("snapshot.memfile.mapped_size", int64(memfileMetadata.Size)),
		attribute.Int64("snapshot.memfile.block_size", int64(memfileMetadata.BlockSize)),
		attribute.Int64("snapshot.metadata.version", int64(memfileMetadata.Version)),
		attribute.Int64("snapshot.metadata.generation", int64(memfileMetadata.Generation)),
		attribute.String("snapshot.metadata.build_id", memfileMetadata.BuildId.String()),
		attribute.String("snapshot.metadata.base_build_id", memfileMetadata.BaseBuildId.String()),
	)

	return memfileDiff, header.NewHeader(memfileMetadata, memfileMappings), nil
}

func pauseProcessRootfs(
	ctx context.Context,
	tracer trace.Tracer,
	buildId uuid.UUID,
	originalHeader *header.Header,
	diffCreator DiffCreator,
) (build.Diff, *header.Header, error) {
	ctx, childSpan := tracer.Start(ctx, "process-rootfs")
	defer childSpan.End()

	rootfsDiffFile, err := build.NewLocalDiffFile(build.DefaultCachePath, buildId.String(), build.Rootfs)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to create rootfs diff: %w", err)
	}

	rootfsDiffMetadata, err := diffCreator.process(ctx, rootfsDiffFile)
	if err != nil {
		return nil, nil, fmt.Errorf("error creating diff: %w", err)
	}

	telemetry.ReportEvent(ctx, "exported rootfs")
	rootfsMapping, err := rootfsDiffMetadata.CreateMapping(ctx, buildId)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to create rootfs diff: %w", err)
	}

	rootfsMappings := header.MergeMappings(
		originalHeader.Mapping,
		rootfsMapping,
	)
	// TODO: We can run normalization only when empty mappings are not empty for this snapshot
	rootfsMappings = header.NormalizeMappings(rootfsMappings)
	telemetry.ReportEvent(ctx, "merged rootfs mappings")

	rootfsDiff, err := rootfsDiffFile.CloseToDiff(int64(originalHeader.Metadata.BlockSize))
	if err != nil {
		return nil, nil, fmt.Errorf("failed to convert rootfs diff file to local diff: %w", err)
	}
	telemetry.ReportEvent(ctx, "converted rootfs diff file to local diff")

	rootfsMetadata := originalHeader.Metadata.NextGeneration(buildId)

	telemetry.SetAttributes(ctx,
		attribute.Int64("snapshot.rootfs.header.mappings.length", int64(len(rootfsMappings))),
		attribute.Int64("snapshot.rootfs.diff.size", int64(rootfsDiffMetadata.Dirty.Count()*uint(originalHeader.Metadata.BlockSize))),
		attribute.Int64("snapshot.rootfs.mapped_size", int64(rootfsMetadata.Size)),
		attribute.Int64("snapshot.rootfs.block_size", int64(rootfsMetadata.BlockSize)),
	)

	return rootfsDiff, header.NewHeader(rootfsMetadata, rootfsMappings), nil
}

func getNetworkSlotAsync(
	ctx context.Context,
	tracer trace.Tracer,
	networkPool *network.Pool,
	cleanup *Cleanup,
	allowInternet bool,
) chan networkSlotRes {
	networkCtx, networkSpan := tracer.Start(ctx, "get-network-slot")
	defer networkSpan.End()

	r := make(chan networkSlotRes, 1)

	go func() {
		defer close(r)

		ips, err := networkPool.Get(networkCtx, tracer, allowInternet)
		if err != nil {
			r <- networkSlotRes{nil, fmt.Errorf("failed to get network slot: %w", err)}
			return
		}

		cleanup.Add(func(ctx context.Context) error {
			_, span := tracer.Start(ctx, "network-slot-clean")
			defer span.End()

			// We can run this cleanup asynchronously, as it is not important for the sandbox lifecycle
			go func() {
				returnErr := networkPool.Return(context.Background(), tracer, ips)
				if returnErr != nil {
					zap.L().Error("failed to return network slot", zap.Error(returnErr))
				}
			}()

			return nil
		})

		r <- networkSlotRes{ips, nil}
	}()

	return r
}

func createRootfsOverlay(
	ctx context.Context,
	tracer trace.Tracer,
	devicePool *nbd.DevicePool,
	cleanup *Cleanup,
	readonlyRootfs block.ReadonlyDevice,
	targetCachePath string,
) (rootfs.Provider, error) {
	_, overlaySpan := tracer.Start(ctx, "create-rootfs-overlay")
	defer overlaySpan.End()

	rootfsOverlay, err := rootfs.NewNBDProvider(
		tracer,
		readonlyRootfs,
		targetCachePath,
		devicePool,
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create overlay file: %w", err)
	}

	cleanup.Add(func(ctx context.Context) error {
		childCtx, span := tracer.Start(ctx, "rootfs-overlay-close")
		defer span.End()

		if rootfsOverlayErr := rootfsOverlay.Close(childCtx); rootfsOverlayErr != nil {
			return fmt.Errorf("failed to close overlay file: %w", rootfsOverlayErr)
		}

		return nil
	})

	return rootfsOverlay, nil
}

func serveMemory(
	ctx context.Context,
	tracer trace.Tracer,
	cleanup *Cleanup,
	memfile block.ReadonlyDevice,
	socketPath string,
	sandboxID string,
) (uffd.MemoryBackend, error) {
	fcUffd, uffdErr := uffd.New(memfile, socketPath, memfile.BlockSize())
	if uffdErr != nil {
		return nil, fmt.Errorf("failed to create uffd: %w", uffdErr)
	}

	uffdStartErr := fcUffd.Start(sandboxID)
	if uffdStartErr != nil {
		return nil, fmt.Errorf("failed to start uffd: %w", uffdStartErr)
	}

	cleanup.Add(func(ctx context.Context) error {
		_, span := tracer.Start(ctx, "uffd-stop")
		defer span.End()

		stopErr := fcUffd.Stop()
		if stopErr != nil {
			return fmt.Errorf("failed to stop uffd: %w", stopErr)
		}

		return nil
	})

	return fcUffd, nil
}

func (s *Sandbox) WaitForExit(
	ctx context.Context,
	tracer trace.Tracer,
) error {
	ctx, childSpan := tracer.Start(ctx, "sandbox-wait-for-exit")
	defer childSpan.End()

	timeout := time.Until(s.EndAt)

	select {
	case <-time.After(timeout):
		return fmt.Errorf("waiting for exit took too long")
	case <-ctx.Done():
		return nil
	case err := <-s.process.Exit:
		if err == nil {
			return nil
		}
		return fmt.Errorf("fc process exited prematurely: %w", err)
	}
}

func (s *Sandbox) WaitForEnvd(
	ctx context.Context,
	tracer trace.Tracer,
	timeout time.Duration,
) (e error) {
	ctx, childSpan := tracer.Start(ctx, "sandbox-wait-for-start")
	defer childSpan.End()

	waitStart := time.Now()
	logResumeTiming("wait_envd_start",
		logger.WithSandboxID(s.Metadata.Config.SandboxId),
		zap.Duration("timeout", timeout),
		zap.String("slot_host_ip", s.Slot.HostIPString()),
	)

	defer func() {
		logResumeTiming("wait_envd_done",
			logger.WithSandboxID(s.Metadata.Config.SandboxId),
			zap.Duration("duration", time.Since(waitStart)),
			zap.Error(e),
		)

		if e != nil {
			return
		}
		// Update the sandbox as started now
		s.Metadata.StartedAt = time.Now()
	}()
	syncCtx, syncCancel := context.WithCancelCause(ctx)
	defer syncCancel(nil)

	go func() {
		select {
		// Ensure the syncing takes at most timeout seconds.
		case <-time.After(timeout):
			syncCancel(fmt.Errorf("syncing took too long"))
		case <-syncCtx.Done():
			return
		case err := <-s.process.Exit:
			syncCancel(fmt.Errorf("fc process exited prematurely: %w", err))
		}
	}()

	operation := lifecycle.Operation(s.Metadata.Config.Snapshot)
	initStats, initErr := s.initEnvd(syncCtx, tracer, s.Metadata.Config.EnvVars, s.Metadata.Config.EnvdAccessToken)
	s.recordEnvdInit(syncCtx, operation, initStats, initErr)
	if initErr != nil {
		return fmt.Errorf("failed to init new envd: %w", initErr)
	} else {
		telemetry.ReportEvent(syncCtx, fmt.Sprintf("[sandbox %s]: initialized new envd", s.Metadata.Config.SandboxId))
	}

	return nil
}
