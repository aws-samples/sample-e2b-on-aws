package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/google/uuid"
	"golang.org/x/sync/errgroup"

	"github.com/e2b-dev/infra/packages/shared/pkg/storage"
	"github.com/e2b-dev/infra/packages/shared/pkg/storage/header"
)

// objectStore is the slice of the bucket this tool needs. s3Store implements
// it; the tests use an in-memory map. A missing object is reported as
// upstream's storage.ErrObjectNotExist.
type objectStore interface {
	Get(ctx context.Context, key string) ([]byte, error)
	Head(ctx context.Context, key string) (map[string]string, error)
	List(ctx context.Context, prefix string) ([]string, error)
	DeletePrefix(ctx context.Context, prefix string) error
}

// refsFromHeader returns every build a serialized memfile or rootfs header
// refers to: the builds its block mapping points at plus its own build and
// base build. It uses the vendored header package, so it reads exactly what
// the orchestrator reads, for every header version.
//
// Mapping.Builds() is the source of truth; Header.Builds is nil for V3 headers
// and only carries frame tables for V4+, so it is deliberately not consulted.
func refsFromHeader(data []byte) ([]uuid.UUID, error) {
	h, err := header.DeserializeBytes(data)
	if err != nil {
		return nil, err
	}

	mapped := h.Mapping.Builds()
	refs := make([]uuid.UUID, 0, len(mapped)+2)
	seen := make(map[uuid.UUID]struct{}, len(mapped)+2)
	add := func(id uuid.UUID) {
		if _, dup := seen[id]; id == uuid.Nil || dup {
			return
		}
		seen[id] = struct{}{}
		refs = append(refs, id)
	}

	for _, id := range mapped {
		add(id)
	}
	if h.Metadata != nil {
		add(h.Metadata.BuildId)
		add(h.Metadata.BaseBuildId)
	}

	return refs, nil
}

// protectedSet downloads both headers of every root build (the builds of live
// envs, and of envs still inside the undo window) and returns every build any
// of them refers to - the roots included - mapped to one root that refers to
// it, for the log. A build in this map must not be deleted.
//
// A missing header is not an error: filesystem-only snapshots have no memfile
// header, and a build whose upload failed has none at all; neither can point
// at anything. Every other failure aborts, because an incomplete set would let
// the purge phase delete something that is still in use.
func protectedSet(ctx context.Context, store objectStore, roots []rootBuild, workers int, grace time.Duration, now time.Time, log *slog.Logger) (map[uuid.UUID]uuid.UUID, error) {
	protected := make(map[uuid.UUID]uuid.UUID)
	var mu sync.Mutex

	g, ctx := errgroup.WithContext(ctx)
	g.SetLimit(workers)

	for _, b := range roots {
		g.Go(func() error {
			paths := storage.Paths{BuildID: b.id.String()}
			refs := []uuid.UUID{b.id}

			missing := 0
			for _, key := range []string{paths.MemfileHeader(), paths.RootfsHeader()} {
				data, err := store.Get(ctx, key)
				if errors.Is(err, storage.ErrObjectNotExist) {
					missing++

					continue
				}
				if err != nil {
					return fmt.Errorf("get %s: %w", key, err)
				}

				ids, err := refsFromHeader(data)
				if err != nil {
					return fmt.Errorf("parse %s: %w", key, err)
				}
				refs = append(refs, ids...)
			}

			if missing == 2 && now.Sub(b.createdAt) > grace {
				log.Warn("build has no headers in the bucket; it cannot be resumed", "build", b.id, "created", b.createdAt.UTC().Format(time.RFC3339))
			}

			mu.Lock()
			for _, id := range refs {
				if _, ok := protected[id]; !ok {
					protected[id] = b.id
				}
			}
			mu.Unlock()

			return nil
		})
	}

	if err := g.Wait(); err != nil {
		return nil, err
	}

	return protected, nil
}
