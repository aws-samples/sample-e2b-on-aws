package uffd

import (
	"github.com/bits-and-blooms/bitset"

	"github.com/e2b-dev/infra/packages/orchestrator/internal/sandbox/lifecycle"
)

type MemoryBackend interface {
	Disable() error
	Dirty() *bitset.BitSet
	Stats() lifecycle.UffdStats

	Start(sandboxId string) error
	Stop() error
	Ready() chan struct{}
	Exit() chan error
}
