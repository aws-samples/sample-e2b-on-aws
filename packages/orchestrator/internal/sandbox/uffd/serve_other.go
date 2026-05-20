//go:build !linux
// +build !linux

package uffd

import (
	"errors"

	"github.com/e2b-dev/infra/packages/orchestrator/internal/sandbox/block"
	"github.com/e2b-dev/infra/packages/orchestrator/internal/sandbox/lifecycle"
)

var ErrUnexpectedEventType = errors.New("unexpected event type")

type GuestRegionUffdMapping struct {
	BaseHostVirtAddr uintptr `json:"base_host_virt_addr"`
	Size             uintptr `json:"size"`
	Offset           uintptr `json:"offset"`
	PageSize         uintptr `json:"page_size_kib"`
}

type uffdTimingStats struct{}

func (s *uffdTimingStats) snapshot() lifecycle.UffdStats {
	return lifecycle.UffdStats{}
}

func Serve(uffd int, mappings []GuestRegionUffdMapping, src *block.TrackedSliceDevice, fd uintptr, stop func() error, sandboxId string, timingStats *uffdTimingStats) error {
	return errors.New("platform does not support UFFD")
}
