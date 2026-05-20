package block

import (
	"sync/atomic"
	"time"

	"github.com/e2b-dev/infra/packages/orchestrator/internal/sandbox/lifecycle"
)

type FetchStats struct {
	cacheHits   atomic.Uint64
	cacheMisses atomic.Uint64

	chunks atomic.Uint64
	bytes  atomic.Uint64

	fetchNanos      atomic.Uint64
	baseReadNanos   atomic.Uint64
	cacheWriteNanos atomic.Uint64

	maxFetchNanos      atomic.Uint64
	maxBaseReadNanos   atomic.Uint64
	maxCacheWriteNanos atomic.Uint64
}

func (s *FetchStats) RecordCacheHit() {
	s.cacheHits.Add(1)
}

func (s *FetchStats) RecordCacheMiss() {
	s.cacheMisses.Add(1)
}

func (s *FetchStats) RecordFetch(bytes int, fetchDuration, baseReadDuration, cacheWriteDuration time.Duration) {
	s.chunks.Add(1)
	if bytes > 0 {
		s.bytes.Add(uint64(bytes))
	}

	s.fetchNanos.Add(uint64(fetchDuration.Nanoseconds()))
	s.baseReadNanos.Add(uint64(baseReadDuration.Nanoseconds()))
	s.cacheWriteNanos.Add(uint64(cacheWriteDuration.Nanoseconds()))

	setMaxDurationNanos(&s.maxFetchNanos, fetchDuration)
	setMaxDurationNanos(&s.maxBaseReadNanos, baseReadDuration)
	setMaxDurationNanos(&s.maxCacheWriteNanos, cacheWriteDuration)
}

func (s *FetchStats) Snapshot(blockSize int64, sourceKind string) lifecycle.StorageStats {
	bytes := s.bytes.Load()
	pages := uint64(0)
	if blockSize > 0 && bytes > 0 {
		pages = (bytes + uint64(blockSize) - 1) / uint64(blockSize)
	}

	return lifecycle.StorageStats{
		SourceKind:         sourceKind,
		CacheHits:          s.cacheHits.Load(),
		CacheMisses:        s.cacheMisses.Load(),
		DownloadChunks:     s.chunks.Load(),
		DownloadBytes:      bytes,
		DownloadPages:      pages,
		FetchNanos:         s.fetchNanos.Load(),
		BaseReadNanos:      s.baseReadNanos.Load(),
		CacheWriteNanos:    s.cacheWriteNanos.Load(),
		MaxFetchNanos:      s.maxFetchNanos.Load(),
		MaxBaseReadNanos:   s.maxBaseReadNanos.Load(),
		MaxCacheWriteNanos: s.maxCacheWriteNanos.Load(),
	}
}

func setMaxDurationNanos(value *atomic.Uint64, candidate time.Duration) {
	nanos := uint64(candidate.Nanoseconds())
	for {
		current := value.Load()
		if nanos <= current || value.CompareAndSwap(current, nanos) {
			return
		}
	}
}
