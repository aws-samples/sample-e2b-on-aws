//go:build linux
// +build linux

package uffd

import (
	"errors"
	"fmt"
	"os"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"

	"github.com/loopholelabs/userfaultfd-go/pkg/constants"
	"go.uber.org/zap"
	"golang.org/x/sync/errgroup"
	"golang.org/x/sys/unix"

	"github.com/e2b-dev/infra/packages/orchestrator/internal/sandbox/block"
	"github.com/e2b-dev/infra/packages/orchestrator/internal/sandbox/lifecycle"
	"github.com/e2b-dev/infra/packages/shared/pkg/logger"
)

var ErrUnexpectedEventType = errors.New("unexpected event type")

var uffdTimingDebug = os.Getenv("E2B_UFFD_TIMING_DEBUG") == "true" || os.Getenv("E2B_UFFD_TIMING_DEBUG") == "1"

const uffdSlowFaultThreshold = 100 * time.Millisecond

type uffdTimingStats struct {
	faults     atomic.Uint64
	slowFaults atomic.Uint64

	sliceNanos atomic.Uint64
	copyNanos  atomic.Uint64
	totalNanos atomic.Uint64

	maxSliceNanos atomic.Uint64
	maxCopyNanos  atomic.Uint64
	maxTotalNanos atomic.Uint64
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

func (s *uffdTimingStats) nextFault() uint64 {
	return s.faults.Add(1)
}

func (s *uffdTimingStats) record(sliceDuration, copyDuration, totalDuration time.Duration) {
	s.sliceNanos.Add(uint64(sliceDuration.Nanoseconds()))
	s.copyNanos.Add(uint64(copyDuration.Nanoseconds()))
	s.totalNanos.Add(uint64(totalDuration.Nanoseconds()))

	setMaxDurationNanos(&s.maxSliceNanos, sliceDuration)
	setMaxDurationNanos(&s.maxCopyNanos, copyDuration)
	setMaxDurationNanos(&s.maxTotalNanos, totalDuration)

	if sliceDuration >= uffdSlowFaultThreshold || totalDuration >= uffdSlowFaultThreshold {
		s.slowFaults.Add(1)
	}
}

func (s *uffdTimingStats) logSummary(sandboxID string) {
	faults := s.faults.Load()
	if faults == 0 {
		zap.L().Info("uffd timing summary",
			logger.WithSandboxID(sandboxID),
			zap.Uint64("fault_count", faults),
		)

		return
	}

	zap.L().Info("uffd timing summary",
		logger.WithSandboxID(sandboxID),
		zap.Uint64("fault_count", faults),
		zap.Uint64("slow_fault_count", s.slowFaults.Load()),
		zap.Duration("slice_total", time.Duration(s.sliceNanos.Load())),
		zap.Duration("copy_total", time.Duration(s.copyNanos.Load())),
		zap.Duration("fault_total", time.Duration(s.totalNanos.Load())),
		zap.Duration("slice_avg", time.Duration(s.sliceNanos.Load()/faults)),
		zap.Duration("copy_avg", time.Duration(s.copyNanos.Load()/faults)),
		zap.Duration("fault_avg", time.Duration(s.totalNanos.Load()/faults)),
		zap.Duration("slice_max", time.Duration(s.maxSliceNanos.Load())),
		zap.Duration("copy_max", time.Duration(s.maxCopyNanos.Load())),
		zap.Duration("fault_max", time.Duration(s.maxTotalNanos.Load())),
	)
}

func (s *uffdTimingStats) snapshot() lifecycle.UffdStats {
	if s == nil {
		return lifecycle.UffdStats{}
	}

	return lifecycle.UffdStats{
		Faults:        s.faults.Load(),
		SlowFaults:    s.slowFaults.Load(),
		SliceNanos:    s.sliceNanos.Load(),
		CopyNanos:     s.copyNanos.Load(),
		FaultNanos:    s.totalNanos.Load(),
		MaxSliceNanos: s.maxSliceNanos.Load(),
		MaxCopyNanos:  s.maxCopyNanos.Load(),
		MaxFaultNanos: s.maxTotalNanos.Load(),
	}
}

type GuestRegionUffdMapping struct {
	BaseHostVirtAddr uintptr `json:"base_host_virt_addr"`
	Size             uintptr `json:"size"`
	Offset           uintptr `json:"offset"`
	PageSize         uintptr `json:"page_size_kib"`
}

func getMapping(addr uintptr, mappings []GuestRegionUffdMapping) (*GuestRegionUffdMapping, error) {
	for _, m := range mappings {
		if addr < m.BaseHostVirtAddr || m.BaseHostVirtAddr+m.Size <= addr {
			// Outside the mapping
			continue
		}

		return &m, nil
	}

	return nil, fmt.Errorf("address %d not found in any mapping", addr)
}

func Serve(
	uffd int,
	mappings []GuestRegionUffdMapping,
	src *block.TrackedSliceDevice,
	fd uintptr,
	stop func() error,
	sandboxId string,
	timingStats *uffdTimingStats,
) error {
	pollFds := []unix.PollFd{
		{Fd: int32(uffd), Events: unix.POLLIN},
		{Fd: int32(fd), Events: unix.POLLIN},
	}

	var eg errgroup.Group
	if timingStats == nil {
		timingStats = &uffdTimingStats{}
	}
	if uffdTimingDebug {
		defer timingStats.logSummary(sandboxId)
	}

outerLoop:
	for {
		if _, err := unix.Poll(
			pollFds,
			-1,
		); err != nil {
			if err == unix.EINTR {
				zap.L().Debug("uffd: interrupted polling, going back to polling", logger.WithSandboxID(sandboxId))

				continue
			}

			if err == unix.EAGAIN {
				zap.L().Debug("uffd: eagain during polling, going back to polling", logger.WithSandboxID(sandboxId))

				continue
			}

			zap.L().Error("UFFD serve polling error", logger.WithSandboxID(sandboxId), zap.Error(err))

			return fmt.Errorf("failed polling: %w", err)
		}

		exitFd := pollFds[1]
		if exitFd.Revents&unix.POLLIN != 0 {
			errMsg := eg.Wait()
			if errMsg != nil {
				zap.L().Warn("UFFD fd exit error while waiting for goroutines to finish", logger.WithSandboxID(sandboxId), zap.Error(errMsg))

				return fmt.Errorf("failed to handle uffd: %w", errMsg)
			}

			return nil
		}

		uffdFd := pollFds[0]
		if uffdFd.Revents&unix.POLLIN == 0 {
			// Uffd is not ready for reading as there is nothing to read on the fd.
			// https://github.com/firecracker-microvm/firecracker/issues/5056
			// https://elixir.bootlin.com/linux/v6.8.12/source/fs/userfaultfd.c#L1149
			// TODO: Check for all the errors
			// - https://docs.kernel.org/admin-guide/mm/userfaultfd.html
			// - https://elixir.bootlin.com/linux/v6.8.12/source/fs/userfaultfd.c
			// - https://man7.org/linux/man-pages/man2/userfaultfd.2.html
			// It might be possible to just check for data != 0 in the syscall.Read loop
			// but I don't feel confident about doing that.
			zap.L().Debug("uffd: no data in fd, going back to polling", logger.WithSandboxID(sandboxId))

			continue
		}

		buf := make([]byte, unsafe.Sizeof(constants.UffdMsg{}))

		for {
			n, err := syscall.Read(uffd, buf)
			if err == syscall.EINTR {
				zap.L().Debug("uffd: interrupted read, reading again", logger.WithSandboxID(sandboxId))

				continue
			}

			if err == nil {
				// There is no error so we can proceed.
				break
			}

			if err == syscall.EAGAIN {
				zap.L().Debug("uffd: eagain error, going back to polling", logger.WithSandboxID(sandboxId), zap.Error(err), zap.Int("read_bytes", n))

				// Continue polling the fd.
				continue outerLoop
			}

			zap.L().Error("uffd: read error", logger.WithSandboxID(sandboxId), zap.Error(err))

			return fmt.Errorf("failed to read: %w", err)
		}

		msg := (*(*constants.UffdMsg)(unsafe.Pointer(&buf[0])))
		if constants.GetMsgEvent(&msg) != constants.UFFD_EVENT_PAGEFAULT {
			zap.L().Error("UFFD serve unexpected event type", logger.WithSandboxID(sandboxId), zap.Any("event_type", constants.GetMsgEvent(&msg)))

			return ErrUnexpectedEventType
		}

		arg := constants.GetMsgArg(&msg)
		pagefault := (*(*constants.UffdPagefault)(unsafe.Pointer(&arg[0])))

		addr := constants.GetPagefaultAddress(&pagefault)

		mapping, err := getMapping(uintptr(addr), mappings)
		if err != nil {
			zap.L().Error("UFFD serve get mapping error", logger.WithSandboxID(sandboxId), zap.Error(err))

			return fmt.Errorf("failed to map: %w", err)
		}

		offset := int64(mapping.Offset + uintptr(addr) - mapping.BaseHostVirtAddr)
		pagesize := int64(mapping.PageSize)
		faultNumber := timingStats.nextFault()

		eg.Go(func() error {
			defer func() {
				if r := recover(); r != nil {
					zap.L().Error("UFFD serve panic", logger.WithSandboxID(sandboxId), zap.Any("offset", offset), zap.Any("pagesize", pagesize), zap.Any("panic", r))
					fmt.Printf("[sandbox %s]: recovered from panic in uffd serve (offset: %d, pagesize: %d): %v\n", sandboxId, offset, pagesize, r)
				}
			}()

			faultStart := time.Now()
			sliceStart := faultStart
			b, err := src.Slice(offset, pagesize)
			sliceDuration := time.Since(sliceStart)
			if err != nil {

				stop()

				zap.L().Error("UFFD serve slice error", logger.WithSandboxID(sandboxId), zap.Error(err))

				return fmt.Errorf("failed to read from source: %w", err)
			}

			cpy := constants.NewUffdioCopy(
				b,
				addr&^constants.CULong(pagesize-1),
				constants.CULong(pagesize),
				0,
				0,
			)

			copyStart := time.Now()
			if _, _, errno := syscall.Syscall(
				syscall.SYS_IOCTL,
				uintptr(uffd),
				constants.UFFDIO_COPY,
				uintptr(unsafe.Pointer(&cpy)),
			); errno != 0 {
				if errno == unix.EEXIST {
					zap.L().Debug("UFFD serve page already mapped", logger.WithSandboxID(sandboxId), zap.Any("offset", offset), zap.Any("pagesize", pagesize))

					// Page is already mapped
					return nil
				}

				stop()

				zap.L().Error("UFFD serve uffdio copy error", logger.WithSandboxID(sandboxId), zap.Error(err))

				return fmt.Errorf("failed uffdio copy %w", errno)
			}
			copyDuration := time.Since(copyStart)
			faultDuration := time.Since(faultStart)
			timingStats.record(sliceDuration, copyDuration, faultDuration)

			if uffdTimingDebug {
				if sliceDuration >= uffdSlowFaultThreshold || faultDuration >= uffdSlowFaultThreshold || faultNumber%100 == 0 {
					zap.L().Info("uffd timing page fault",
						logger.WithSandboxID(sandboxId),
						zap.Uint64("fault_number", faultNumber),
						zap.Int64("offset", offset),
						zap.Int64("page_size", pagesize),
						zap.Duration("slice_duration", sliceDuration),
						zap.Duration("copy_duration", copyDuration),
						zap.Duration("fault_duration", faultDuration),
					)
				}
			}

			return nil
		})
	}
}
