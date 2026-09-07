package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"slices"
	"sync"
	"time"

	"github.com/google/uuid"
	"golang.org/x/sync/errgroup"

	"github.com/e2b-dev/infra/packages/shared/pkg/storage"
	"github.com/e2b-dev/infra/packages/shared/pkg/storage/header"
)

var errNotFound = errors.New("object not found")

// objectStore is the slice of S3 this tool needs; s3Store implements it and
// the tests use an in-memory map.
type objectStore interface {
	Get(ctx context.Context, key string) ([]byte, error)
	Head(ctx context.Context, key string) (map[string]string, error)
	List(ctx context.Context, prefix string) ([]string, error)
	Delete(ctx context.Context, keys []string) error
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

	seen := make(map[uuid.UUID]struct{})
	add := func(id uuid.UUID) {
		if id != uuid.Nil {
			seen[id] = struct{}{}
		}
	}
	for _, id := range h.Mapping.Builds() {
		add(id)
	}
	if h.Metadata != nil {
		add(h.Metadata.BuildId)
		add(h.Metadata.BaseBuildId)
	}

	refs := make([]uuid.UUID, 0, len(seen))
	for id := range seen {
		refs = append(refs, id)
	}
	slices.SortFunc(refs, func(a, b uuid.UUID) int { return bytes.Compare(a[:], b[:]) })

	return refs, nil
}

// protectedSet downloads both headers of every live build and returns, for
// each build referenced by any of them (including the live builds themselves),
// the live builds that reference it. A build in this map must not be deleted.
//
// A missing header is not an error: filesystem-only snapshots have no memfile
// header, and a build whose upload failed has none at all; neither can point
// at anything. Every other failure aborts, because an incomplete set would let
// the purge phase delete something that is still in use.
func protectedSet(ctx context.Context, store objectStore, live []liveBuild, workers int, grace time.Duration, now time.Time, log *slog.Logger) (map[uuid.UUID][]uuid.UUID, error) {
	protected := make(map[uuid.UUID][]uuid.UUID)
	var mu sync.Mutex

	g, ctx := errgroup.WithContext(ctx)
	g.SetLimit(workers)

	for _, b := range live {
		g.Go(func() error {
			paths := storage.Paths{BuildID: b.id.String()}
			refs := map[uuid.UUID]struct{}{b.id: {}}

			missing := 0
			for _, key := range []string{paths.MemfileHeader(), paths.RootfsHeader()} {
				data, err := store.Get(ctx, key)
				if errors.Is(err, errNotFound) {
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
				for _, id := range ids {
					refs[id] = struct{}{}
				}
			}

			if missing == 2 && now.Sub(b.createdAt) > grace {
				log.Warn("live build has no headers in the bucket; it cannot be resumed", "build", b.id, "created", b.createdAt.UTC().Format(time.RFC3339))
			}

			mu.Lock()
			for id := range refs {
				protected[id] = append(protected[id], b.id)
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
