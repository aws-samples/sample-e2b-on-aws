package lifecycle

import (
	"context"
	"sync"
	"time"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"
	noopmetric "go.opentelemetry.io/otel/metric/noop"
	"go.uber.org/zap"
)

const (
	OperationCreate = "create"
	OperationResume = "resume"

	ResultOK    = "ok"
	ResultError = "error"
)

var global = newRecorder(noopmetric.NewMeterProvider())

func Operation(snapshot bool) string {
	if snapshot {
		return OperationResume
	}

	return OperationCreate
}

func Init(meterProvider metric.MeterProvider) {
	global = newRecorder(meterProvider)
}

type Recorder struct {
	lifecycleDuration metric.Int64Histogram
	stageDuration     metric.Int64Histogram
	envdAttempts      metric.Int64Histogram

	uffdFaults     metric.Int64Counter
	uffdSlowFaults metric.Int64Counter
	uffdSlice      metric.Int64Histogram
	uffdCopy       metric.Int64Histogram
	uffdFault      metric.Int64Histogram

	storageDownloadBytes      metric.Int64Counter
	storageDownloadPages      metric.Int64Counter
	storageDownloadChunks     metric.Int64Counter
	storageDownloadDuration   metric.Int64Histogram
	storageBaseReadDuration   metric.Int64Histogram
	storageCacheWriteDuration metric.Int64Histogram
}

func newRecorder(meterProvider metric.MeterProvider) *Recorder {
	meter := meterProvider.Meter("orchestrator.sandbox.lifecycle")

	r := &Recorder{}
	var err error
	r.lifecycleDuration, err = meter.Int64Histogram(
		"orchestrator.sandbox.lifecycle.duration_ms",
		metric.WithUnit("ms"),
		metric.WithDescription("End-to-end sandbox create/resume duration."),
	)
	logMetricError("lifecycle duration", err)

	r.stageDuration, err = meter.Int64Histogram(
		"orchestrator.sandbox.lifecycle.stage.duration_ms",
		metric.WithUnit("ms"),
		metric.WithDescription("Sandbox create/resume stage duration."),
	)
	logMetricError("stage duration", err)

	r.envdAttempts, err = meter.Int64Histogram(
		"orchestrator.sandbox.envd.init.attempts",
		metric.WithUnit("{attempt}"),
		metric.WithDescription("Number of /init attempts before envd becomes ready."),
	)
	logMetricError("envd attempts", err)

	r.uffdFaults, err = meter.Int64Counter(
		"orchestrator.sandbox.uffd.faults",
		metric.WithUnit("{fault}"),
		metric.WithDescription("Number of UFFD page faults."),
	)
	logMetricError("uffd faults", err)

	r.uffdSlowFaults, err = meter.Int64Counter(
		"orchestrator.sandbox.uffd.slow_faults",
		metric.WithUnit("{fault}"),
		metric.WithDescription("Number of slow UFFD page faults."),
	)
	logMetricError("uffd slow faults", err)

	r.uffdSlice, err = meter.Int64Histogram(
		"orchestrator.sandbox.uffd.slice.duration_ms",
		metric.WithUnit("ms"),
		metric.WithDescription("Total source slice duration for UFFD page faults."),
	)
	logMetricError("uffd slice", err)

	r.uffdCopy, err = meter.Int64Histogram(
		"orchestrator.sandbox.uffd.copy.duration_ms",
		metric.WithUnit("ms"),
		metric.WithDescription("Total UFFDIO_COPY duration for UFFD page faults."),
	)
	logMetricError("uffd copy", err)

	r.uffdFault, err = meter.Int64Histogram(
		"orchestrator.sandbox.uffd.fault.duration_ms",
		metric.WithUnit("ms"),
		metric.WithDescription("Total UFFD page fault service duration."),
	)
	logMetricError("uffd fault", err)

	r.storageDownloadBytes, err = meter.Int64Counter(
		"orchestrator.sandbox.storage.s3.download.bytes",
		metric.WithUnit("By"),
		metric.WithDescription("Bytes downloaded from S3-backed template storage."),
	)
	logMetricError("storage download bytes", err)

	r.storageDownloadPages, err = meter.Int64Counter(
		"orchestrator.sandbox.storage.s3.download.pages",
		metric.WithUnit("{page}"),
		metric.WithDescription("Block/page equivalent downloaded from S3-backed template storage."),
	)
	logMetricError("storage download pages", err)

	r.storageDownloadChunks, err = meter.Int64Counter(
		"orchestrator.sandbox.storage.s3.download.chunks",
		metric.WithUnit("{chunk}"),
		metric.WithDescription("Chunks downloaded from S3-backed template storage."),
	)
	logMetricError("storage download chunks", err)

	r.storageDownloadDuration, err = meter.Int64Histogram(
		"orchestrator.sandbox.storage.s3.download.duration_ms",
		metric.WithUnit("ms"),
		metric.WithDescription("Total chunk fetch duration for S3-backed template storage."),
	)
	logMetricError("storage download duration", err)

	r.storageBaseReadDuration, err = meter.Int64Histogram(
		"orchestrator.sandbox.storage.s3.get_object.duration_ms",
		metric.WithUnit("ms"),
		metric.WithDescription("Total base object read duration for S3-backed template storage."),
	)
	logMetricError("storage base read duration", err)

	r.storageCacheWriteDuration, err = meter.Int64Histogram(
		"orchestrator.sandbox.storage.cache_write.duration_ms",
		metric.WithUnit("ms"),
		metric.WithDescription("Total local cache write duration after template storage download."),
	)
	logMetricError("storage cache write duration", err)

	return r
}

func logMetricError(name string, err error) {
	if err != nil {
		zap.L().Error("failed to create sandbox lifecycle metric", zap.String("metric", name), zap.Error(err))
	}
}

func result(err error) string {
	if err != nil {
		return ResultError
	}

	return ResultOK
}

func RecordLifecycle(ctx context.Context, operation string, duration time.Duration, err error) {
	global.lifecycleDuration.Record(ctx, millis(duration),
		metric.WithAttributes(
			attribute.String("operation", operation),
			attribute.String("result", result(err)),
		),
	)
}

func RecordStage(ctx context.Context, operation, stage string, duration time.Duration, err error) {
	global.stageDuration.Record(ctx, millis(duration),
		metric.WithAttributes(
			attribute.String("operation", operation),
			attribute.String("stage", stage),
			attribute.String("result", result(err)),
		),
	)
}

func RecordEnvdInit(ctx context.Context, operation string, attempts int, duration time.Duration, err error) {
	attrs := metric.WithAttributes(
		attribute.String("operation", operation),
		attribute.String("result", result(err)),
	)
	global.envdAttempts.Record(ctx, int64(attempts), attrs)
	global.stageDuration.Record(ctx, millis(duration),
		metric.WithAttributes(
			attribute.String("operation", operation),
			attribute.String("stage", "envd_init"),
			attribute.String("result", result(err)),
		),
	)
}

func RecordUffd(ctx context.Context, operation, phase string, stats UffdStats) {
	if stats.Faults == 0 {
		return
	}

	attrs := metric.WithAttributes(
		attribute.String("operation", operation),
		attribute.String("phase", phase),
	)

	global.uffdFaults.Add(ctx, int64(stats.Faults), attrs)
	if stats.SlowFaults > 0 {
		global.uffdSlowFaults.Add(ctx, int64(stats.SlowFaults), attrs)
	}
	global.uffdSlice.Record(ctx, millis(stats.SliceDuration()), attrs)
	global.uffdCopy.Record(ctx, millis(stats.CopyDuration()), attrs)
	global.uffdFault.Record(ctx, millis(stats.FaultDuration()), attrs)
}

func RecordStorageDownload(ctx context.Context, operation, phase, dataKind string, stats StorageStats) {
	if stats.DownloadChunks == 0 && stats.DownloadBytes == 0 {
		return
	}
	if stats.SourceKind != "aws_s3" {
		return
	}

	attrs := metric.WithAttributes(
		attribute.String("operation", operation),
		attribute.String("phase", phase),
		attribute.String("data_kind", dataKind),
		attribute.String("storage_provider", stats.SourceKind),
	)

	if stats.DownloadBytes > 0 {
		global.storageDownloadBytes.Add(ctx, int64(stats.DownloadBytes), attrs)
	}
	if stats.DownloadPages > 0 {
		global.storageDownloadPages.Add(ctx, int64(stats.DownloadPages), attrs)
	}
	if stats.DownloadChunks > 0 {
		global.storageDownloadChunks.Add(ctx, int64(stats.DownloadChunks), attrs)
	}
	global.storageDownloadDuration.Record(ctx, millis(stats.FetchDuration()), attrs)
	global.storageBaseReadDuration.Record(ctx, millis(stats.BaseReadDuration()), attrs)
	global.storageCacheWriteDuration.Record(ctx, millis(stats.CacheWriteDuration()), attrs)
}

func millis(d time.Duration) int64 {
	return d.Milliseconds()
}

type UffdStats struct {
	Faults     uint64
	SlowFaults uint64

	SliceNanos uint64
	CopyNanos  uint64
	FaultNanos uint64

	MaxSliceNanos uint64
	MaxCopyNanos  uint64
	MaxFaultNanos uint64
}

func (s UffdStats) Sub(before UffdStats) UffdStats {
	return UffdStats{
		Faults:        subUint64(s.Faults, before.Faults),
		SlowFaults:    subUint64(s.SlowFaults, before.SlowFaults),
		SliceNanos:    subUint64(s.SliceNanos, before.SliceNanos),
		CopyNanos:     subUint64(s.CopyNanos, before.CopyNanos),
		FaultNanos:    subUint64(s.FaultNanos, before.FaultNanos),
		MaxSliceNanos: s.MaxSliceNanos,
		MaxCopyNanos:  s.MaxCopyNanos,
		MaxFaultNanos: s.MaxFaultNanos,
	}
}

func (s UffdStats) SliceDuration() time.Duration {
	return time.Duration(s.SliceNanos)
}

func (s UffdStats) CopyDuration() time.Duration {
	return time.Duration(s.CopyNanos)
}

func (s UffdStats) FaultDuration() time.Duration {
	return time.Duration(s.FaultNanos)
}

type StorageStats struct {
	SourceKind string

	CacheHits      uint64
	CacheMisses    uint64
	DownloadChunks uint64
	DownloadBytes  uint64
	DownloadPages  uint64

	FetchNanos      uint64
	BaseReadNanos   uint64
	CacheWriteNanos uint64

	MaxFetchNanos      uint64
	MaxBaseReadNanos   uint64
	MaxCacheWriteNanos uint64
}

func (s StorageStats) Add(other StorageStats) StorageStats {
	sourceKind := s.SourceKind
	if sourceKind == "" {
		sourceKind = other.SourceKind
	}

	return StorageStats{
		SourceKind:         sourceKind,
		CacheHits:          s.CacheHits + other.CacheHits,
		CacheMisses:        s.CacheMisses + other.CacheMisses,
		DownloadChunks:     s.DownloadChunks + other.DownloadChunks,
		DownloadBytes:      s.DownloadBytes + other.DownloadBytes,
		DownloadPages:      s.DownloadPages + other.DownloadPages,
		FetchNanos:         s.FetchNanos + other.FetchNanos,
		BaseReadNanos:      s.BaseReadNanos + other.BaseReadNanos,
		CacheWriteNanos:    s.CacheWriteNanos + other.CacheWriteNanos,
		MaxFetchNanos:      maxUint64(s.MaxFetchNanos, other.MaxFetchNanos),
		MaxBaseReadNanos:   maxUint64(s.MaxBaseReadNanos, other.MaxBaseReadNanos),
		MaxCacheWriteNanos: maxUint64(s.MaxCacheWriteNanos, other.MaxCacheWriteNanos),
	}
}

func (s StorageStats) Sub(before StorageStats) StorageStats {
	return StorageStats{
		SourceKind:         s.SourceKind,
		CacheHits:          subUint64(s.CacheHits, before.CacheHits),
		CacheMisses:        subUint64(s.CacheMisses, before.CacheMisses),
		DownloadChunks:     subUint64(s.DownloadChunks, before.DownloadChunks),
		DownloadBytes:      subUint64(s.DownloadBytes, before.DownloadBytes),
		DownloadPages:      subUint64(s.DownloadPages, before.DownloadPages),
		FetchNanos:         subUint64(s.FetchNanos, before.FetchNanos),
		BaseReadNanos:      subUint64(s.BaseReadNanos, before.BaseReadNanos),
		CacheWriteNanos:    subUint64(s.CacheWriteNanos, before.CacheWriteNanos),
		MaxFetchNanos:      s.MaxFetchNanos,
		MaxBaseReadNanos:   s.MaxBaseReadNanos,
		MaxCacheWriteNanos: s.MaxCacheWriteNanos,
	}
}

func (s StorageStats) FetchDuration() time.Duration {
	return time.Duration(s.FetchNanos)
}

func (s StorageStats) BaseReadDuration() time.Duration {
	return time.Duration(s.BaseReadNanos)
}

func (s StorageStats) CacheWriteDuration() time.Duration {
	return time.Duration(s.CacheWriteNanos)
}

func subUint64(after, before uint64) uint64 {
	if after < before {
		return 0
	}

	return after - before
}

func maxUint64(a, b uint64) uint64 {
	if a > b {
		return a
	}

	return b
}

type StageTimings struct {
	mu        sync.Mutex
	durations map[string]time.Duration
}

func NewStageTimings() *StageTimings {
	return &StageTimings{
		durations: make(map[string]time.Duration),
	}
}

func (s *StageTimings) Record(ctx context.Context, operation, stage string, start time.Time, err error) time.Duration {
	duration := time.Since(start)
	RecordStage(ctx, operation, stage, duration, err)

	s.mu.Lock()
	s.durations[stage] = duration
	s.mu.Unlock()

	return duration
}

func (s *StageTimings) ZapFields() []zap.Field {
	s.mu.Lock()
	defer s.mu.Unlock()

	fields := make([]zap.Field, 0, len(s.durations))
	for stage, duration := range s.durations {
		fields = append(fields, zap.Int64(stage+"_ms", duration.Milliseconds()))
	}

	return fields
}
