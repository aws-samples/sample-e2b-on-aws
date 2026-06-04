package sandbox

import (
	"context"
	"errors"
	"fmt"
	"os"
	"sync"
	"sync/atomic"

	"go.uber.org/zap"

	"github.com/e2b-dev/infra/packages/shared/pkg/storage"
)

type Cleanup struct {
	cleanup         []func(ctx context.Context) error
	priorityCleanup []func(ctx context.Context) error
	error           error
	once            sync.Once

	hasRun atomic.Bool
	mu     sync.Mutex
}

func NewCleanup() *Cleanup {
	return &Cleanup{}
}

func (c *Cleanup) Add(f func(ctx context.Context) error) {
	if c.hasRun.Load() {
		err := runCleanupFunc(context.Background(), f)
		if err != nil {
			zap.L().Error("failed to run function after cleanup has run", zap.Error(err))
		}
		return
	}

	c.mu.Lock()
	defer c.mu.Unlock()

	c.cleanup = append(c.cleanup, f)
}

func (c *Cleanup) AddPriority(f func(ctx context.Context) error) {
	if c.hasRun.Load() {
		err := runCleanupFunc(context.Background(), f)
		if err != nil {
			zap.L().Error("failed to run priority function after cleanup has run", zap.Error(err))
		}
		return
	}

	c.mu.Lock()
	defer c.mu.Unlock()

	c.priorityCleanup = append(c.priorityCleanup, f)
}

func (c *Cleanup) Run(ctx context.Context) error {
	c.once.Do(func() {
		c.run(context.WithoutCancel(ctx))
	})
	return c.error
}

func (c *Cleanup) run(ctx context.Context) {
	c.hasRun.Store(true)

	c.mu.Lock()
	defer c.mu.Unlock()

	var errs []error

	for i := len(c.priorityCleanup) - 1; i >= 0; i-- {
		err := runCleanupFunc(ctx, c.priorityCleanup[i])
		if err != nil {
			errs = append(errs, err)
		}
	}

	for i := len(c.cleanup) - 1; i >= 0; i-- {
		err := runCleanupFunc(ctx, c.cleanup[i])
		if err != nil {
			errs = append(errs, err)
		}
	}

	c.error = errors.Join(errs...)
}

func runCleanupFunc(ctx context.Context, f func(ctx context.Context) error) (err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("cleanup function panicked: %v", r)
		}
	}()

	return f(ctx)
}

func cleanupFiles(files *storage.SandboxFiles) error {
	var errs []error

	for _, p := range []string{
		files.SandboxFirecrackerSocketPath(),
		files.SandboxUffdSocketPath(),
		files.SandboxCacheRootfsLinkPath(),
	} {
		err := os.RemoveAll(p)
		if err != nil {
			errs = append(errs, fmt.Errorf("failed to delete '%s': %w", p, err))
		}
	}

	return errors.Join(errs...)
}
