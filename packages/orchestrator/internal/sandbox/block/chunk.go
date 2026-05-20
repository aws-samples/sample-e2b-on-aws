package block

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"time"

	"go.uber.org/zap"
	"golang.org/x/sync/errgroup"

	"github.com/e2b-dev/infra/packages/orchestrator/internal/sandbox/lifecycle"
	"github.com/e2b-dev/infra/packages/shared/pkg/storage/header"
	"github.com/e2b-dev/infra/packages/shared/pkg/utils"
)

const (
	// Chunks must always be bigger or equal to the block size.
	ChunkSize = 4 * 1024 * 1024 // 4 MB
)

var chunkerTimingDebug = os.Getenv("E2B_UFFD_TIMING_DEBUG") == "true" || os.Getenv("E2B_UFFD_TIMING_DEBUG") == "1"

type Chunker struct {
	ctx context.Context

	base  io.ReaderAt
	cache *Cache

	size      int64
	blockSize int64
	stats     *FetchStats

	// TODO: Optimize this so we don't need to keep the fetchers in memory.
	fetchers *utils.WaitMap
}

func NewChunker(
	ctx context.Context,
	size,
	blockSize int64,
	base io.ReaderAt,
	cachePath string,
) (*Chunker, error) {
	cache, err := NewCache(size, blockSize, cachePath, false)
	if err != nil {
		return nil, fmt.Errorf("failed to create file cache: %w", err)
	}

	chunker := &Chunker{
		ctx:       ctx,
		size:      size,
		blockSize: blockSize,
		base:      base,
		cache:     cache,
		fetchers:  utils.NewWaitMap(),
		stats:     &FetchStats{},
	}

	return chunker, nil
}

func (c *Chunker) ReadAt(b []byte, off int64) (int, error) {
	slice, err := c.Slice(off, int64(len(b)))
	if err != nil {
		return 0, fmt.Errorf("failed to slice cache at %d-%d: %w", off, off+int64(len(b)), err)
	}

	return copy(b, slice), nil
}

func (c *Chunker) WriteTo(w io.Writer) (int64, error) {
	for i := int64(0); i < c.size; i += ChunkSize {
		chunk := make([]byte, ChunkSize)

		n, err := c.ReadAt(chunk, i)
		if err != nil {
			return 0, fmt.Errorf("failed to slice cache at %d-%d: %w", i, i+ChunkSize, err)
		}

		_, err = w.Write(chunk[:n])
		if err != nil {
			return 0, fmt.Errorf("failed to write chunk %d to writer: %w", i, err)
		}
	}

	return c.size, nil
}

func (c *Chunker) Slice(off, length int64) ([]byte, error) {
	b, err := c.cache.Slice(off, length)
	if err == nil {
		c.stats.RecordCacheHit()
		return b, nil
	}

	if !errors.As(err, &ErrBytesNotAvailable{}) {
		return nil, fmt.Errorf("failed read from cache at offset %d: %w", off, err)
	}

	c.stats.RecordCacheMiss()
	missStart := time.Now()
	chunkErr := c.fetchToCache(off, length)
	if chunkErr != nil {
		return nil, fmt.Errorf("failed to ensure data at %d-%d: %w", off, off+length, chunkErr)
	}

	b, cacheErr := c.cache.Slice(off, length)
	if cacheErr != nil {
		return nil, fmt.Errorf("failed to read from cache after ensuring data at %d-%d: %w", off, off+length, cacheErr)
	}

	if chunkerTimingDebug {
		zap.L().Info("uffd timing chunker cache miss",
			zap.Int64("offset", off),
			zap.Int64("length", length),
			zap.Duration("miss_duration", time.Since(missStart)),
		)
	}

	return b, nil
}

// fetchToCache ensures that the data at the given offset and length is available in the cache.
func (c *Chunker) fetchToCache(off, length int64) error {
	var eg errgroup.Group

	chunks := header.BlocksOffsets(length, ChunkSize)

	startingChunk := header.BlockIdx(off, ChunkSize)
	startingChunkOffset := header.BlockOffset(startingChunk, ChunkSize)

	for _, chunkOff := range chunks {
		// Ensure the closure captures the correct block offset.
		fetchOff := startingChunkOffset + chunkOff

		eg.Go(func() (err error) {
			defer func() {
				if r := recover(); r != nil {
					zap.L().Error("recovered from panic in the fetch handler", zap.Any("error", r))
					err = fmt.Errorf("recovered from panic in the fetch handler: %v", r)
				}
			}()

			err = c.fetchers.Wait(fetchOff, func() error {
				select {
				case <-c.ctx.Done():
					return fmt.Errorf("error fetching range %d-%d: %w", fetchOff, fetchOff+ChunkSize, c.ctx.Err())
				default:
				}

				fetchStart := time.Now()
				b := make([]byte, ChunkSize)

				readStart := time.Now()
				n, err := c.base.ReadAt(b, fetchOff)
				readDuration := time.Since(readStart)
				if err != nil && !errors.Is(err, io.EOF) {
					return fmt.Errorf("failed to read chunk from base %d: %w", fetchOff, err)
				}

				writeStart := time.Now()
				_, cacheErr := c.cache.WriteAtWithoutLock(b, fetchOff)
				writeDuration := time.Since(writeStart)
				if cacheErr != nil {
					return fmt.Errorf("failed to write chunk %d to cache: %w", fetchOff, cacheErr)
				}
				c.stats.RecordFetch(n, time.Since(fetchStart), readDuration, writeDuration)

				if chunkerTimingDebug {
					zap.L().Info("uffd timing chunker fetch",
						zap.Int64("fetch_offset", fetchOff),
						zap.Int64("chunk_size", ChunkSize),
						zap.Int("read_bytes", n),
						zap.Bool("read_eof", errors.Is(err, io.EOF)),
						zap.Duration("base_read_duration", readDuration),
						zap.Duration("cache_write_duration", writeDuration),
						zap.Duration("fetch_duration", time.Since(fetchStart)),
					)
				}

				return nil
			})

			return err
		})
	}

	err := eg.Wait()
	if err != nil {
		return fmt.Errorf("failed to ensure data at %d-%d: %w", off, off+length, err)
	}

	return nil
}

func (c *Chunker) FetchStats(sourceKind string) lifecycle.StorageStats {
	return c.stats.Snapshot(c.blockSize, sourceKind)
}

func (c *Chunker) Close() error {
	return c.cache.Close()
}

func (c *Chunker) FileSize() (int64, error) {
	return c.cache.FileSize()
}
