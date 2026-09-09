package main

import (
	"context"
	"log/slog"
	"os"
	"slices"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/e2b-dev/infra/packages/shared/pkg/storage"
	"github.com/e2b-dev/infra/packages/shared/pkg/storage/header"
)

// serializedHeader builds a header whose block map points at blocks (one page
// each, uuid.Nil = empty region) and serializes it in the requested on-disk
// version, using the same vendored code the orchestrator writes headers with.
func serializedHeader(t *testing.T, version uint64, self, base uuid.UUID, blocks []uuid.UUID) []byte {
	t.Helper()

	meta := header.NewTemplateMetadata(base, header.PageSize, uint64(len(blocks))*header.PageSize)
	meta.Version = version
	meta.BuildId = self

	mapping := make([]header.BuildMap, 0, len(blocks))
	for i, b := range blocks {
		mapping = append(mapping, header.BuildMap{
			Offset:             uint64(i) * header.PageSize,
			Length:             header.PageSize,
			BuildId:            b,
			BuildStorageOffset: uint64(i) * header.PageSize,
		})
	}

	h, err := header.NewHeader(meta, mapping)
	if err != nil {
		t.Fatalf("NewHeader: %v", err)
	}
	if version >= header.MetadataVersionV4 {
		for _, b := range blocks {
			if b != uuid.Nil {
				h.SetBuild(b, header.BuildData{FrameData: storage.UncompressedFrameTable})
			}
		}
		h.SetBuild(self, header.BuildData{FrameData: storage.UncompressedFrameTable})
	}

	data, err := header.SerializeHeader(h)
	if err != nil {
		t.Fatalf("SerializeHeader v%d: %v", version, err)
	}

	return data
}

func sortedIDs(ids ...uuid.UUID) []uuid.UUID {
	out := slices.Clone(ids)
	sort.Slice(out, func(i, j int) bool { return strings.Compare(out[i].String(), out[j].String()) < 0 })

	return out
}

func assertSameIDs(t *testing.T, got, want []uuid.UUID) {
	t.Helper()

	g, w := sortedIDs(got...), sortedIDs(want...)
	if !slices.Equal(g, w) {
		t.Fatalf("refs mismatch\n got: %v\nwant: %v", g, w)
	}
}

func TestRefsFromHeader(t *testing.T) {
	T := uuid.New()  // base template build
	P1 := uuid.New() // first pause of a sandbox
	P2 := uuid.New() // second pause, layered on P1
	K := uuid.New()  // checkpoint taken from another sandbox (fork parent)
	C1 := uuid.New() // first pause of the forked child

	cases := []struct {
		name    string
		version uint64
		self    uuid.UUID
		base    uuid.UUID
		blocks  []uuid.UUID
		want    []uuid.UUID
	}{
		{"template v3 refers only to itself", 3, T, T, []uuid.UUID{T, T, uuid.Nil}, []uuid.UUID{T}},
		{"pause chain v4 keeps template and earlier pause", header.MetadataVersionV4, P2, T, []uuid.UUID{T, P1, P2, uuid.Nil}, []uuid.UUID{T, P1, P2}},
		{"pause chain v5 keeps template and earlier pause", header.MetadataVersionV5, P2, T, []uuid.UUID{T, P1, P2}, []uuid.UUID{T, P1, P2}},
		{"fork child v5 refers to the parent's checkpoint", header.MetadataVersionV5, C1, T, []uuid.UUID{K, C1, T}, []uuid.UUID{K, C1, T}},
		{"base build is protected even when no block maps to it", header.MetadataVersionV4, P2, T, []uuid.UUID{P1, P2}, []uuid.UUID{T, P1, P2}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			data := serializedHeader(t, tc.version, tc.self, tc.base, tc.blocks)

			got, err := refsFromHeader(data)
			if err != nil {
				t.Fatalf("refsFromHeader: %v", err)
			}
			assertSameIDs(t, got, tc.want)
			if slices.Contains(got, uuid.Nil) {
				t.Fatal("uuid.Nil must never be reported as a reference")
			}
		})
	}

	t.Run("garbage is an error", func(t *testing.T) {
		if _, err := refsFromHeader([]byte("not a header")); err == nil {
			t.Fatal("expected an error for garbage input")
		}
	})
}

// fakeStore is an in-memory objectStore: keys to bytes, no metadata.
type fakeStore map[string][]byte

func (f fakeStore) Get(_ context.Context, key string) ([]byte, error) {
	data, ok := f[key]
	if !ok {
		return nil, storage.ErrObjectNotExist
	}

	return data, nil
}

func (f fakeStore) Head(_ context.Context, key string) (map[string]string, error) {
	if _, ok := f[key]; !ok {
		return nil, storage.ErrObjectNotExist
	}

	return map[string]string{}, nil
}

func (f fakeStore) List(_ context.Context, prefix string) ([]string, error) {
	var keys []string
	for k := range f {
		if strings.HasPrefix(k, prefix) {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)

	return keys, nil
}

func (f fakeStore) DeletePrefix(_ context.Context, prefix string) error {
	for k := range f {
		if strings.HasPrefix(k, prefix) {
			delete(f, k)
		}
	}

	return nil
}

func TestProtectedSet(t *testing.T) {
	T := uuid.New()
	K := uuid.New()  // parent's checkpoint, env already soft-deleted
	C1 := uuid.New() // live child snapshot referencing K
	F := uuid.New()  // live filesystem-only snapshot: rootfs header only
	B := uuid.New()  // live build whose upload never happened

	store := fakeStore{
		storage.Paths{BuildID: C1.String()}.MemfileHeader(): serializedHeader(t, header.MetadataVersionV4, C1, T, []uuid.UUID{K, C1, T}),
		storage.Paths{BuildID: C1.String()}.RootfsHeader():  serializedHeader(t, header.MetadataVersionV4, C1, T, []uuid.UUID{T, C1}),
		storage.Paths{BuildID: F.String()}.RootfsHeader():   serializedHeader(t, 3, F, T, []uuid.UUID{T, F}),
	}

	now := time.Now()
	roots := []rootBuild{
		{id: C1, createdAt: now.Add(-100 * 24 * time.Hour)},
		{id: F, createdAt: now.Add(-time.Hour)},
		{id: B, createdAt: now.Add(-10 * 24 * time.Hour)},
	}

	log := slog.New(slog.NewTextHandler(os.Stderr, nil))
	protected, err := protectedSet(context.Background(), store, roots, 4, 48*time.Hour, now, log)
	if err != nil {
		t.Fatalf("protectedSet: %v", err)
	}

	for _, id := range []uuid.UUID{T, K, C1, F, B} {
		if _, ok := protected[id]; !ok {
			t.Errorf("build %s should be protected", id)
		}
	}
	if referrer := protected[K]; referrer != C1 {
		t.Errorf("K should be reported as referenced by C1, got %s", referrer)
	}
	if got := len(protected); got != 5 {
		t.Errorf("expected exactly 5 protected builds, got %d: %v", got, protected)
	}
}
