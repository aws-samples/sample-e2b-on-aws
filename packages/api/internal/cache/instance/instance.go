package instance

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"
	"go.opentelemetry.io/otel/metric"
	"go.uber.org/zap"

	"github.com/e2b-dev/infra/packages/api/internal/api"
	"github.com/e2b-dev/infra/packages/api/internal/node"
	sbxlogger "github.com/e2b-dev/infra/packages/shared/pkg/logger/sandbox"
	"github.com/e2b-dev/infra/packages/shared/pkg/smap"
	"github.com/e2b-dev/infra/packages/shared/pkg/telemetry"
	"github.com/e2b-dev/infra/packages/shared/pkg/utils"
)

const (
	InstanceExpiration = time.Second * 15
	// Should we auto pause the instance by default instead of killing it,
	InstanceAutoPauseDefault = false
)

var ErrPausingInstanceNotFound = errors.New("pausing instance not found")

func NewInstanceInfo(
	Instance *api.Sandbox,
	ExecutionID string,
	TeamID *uuid.UUID,
	BuildID *uuid.UUID,
	Metadata map[string]string,
	MaxInstanceLength time.Duration,
	StartTime time.Time,
	endTime time.Time,
	VCpu int64,
	TotalDiskSizeMB int64,
	RamMB int64,
	KernelVersion string,
	FirecrackerVersion string,
	EnvdVersion string,
	Node *node.NodeInfo,
	AutoPause bool,
	EnvdAccessToken *string,
	BaseTemplateID string,
) *InstanceInfo {
	instance := &InstanceInfo{
		Instance:           Instance,
		ExecutionID:        ExecutionID,
		TeamID:             TeamID,
		BuildID:            BuildID,
		Metadata:           Metadata,
		MaxInstanceLength:  MaxInstanceLength,
		StartTime:          StartTime,
		endTime:            endTime,
		VCpu:               VCpu,
		TotalDiskSizeMB:    TotalDiskSizeMB,
		RamMB:              RamMB,
		KernelVersion:      KernelVersion,
		FirecrackerVersion: FirecrackerVersion,
		EnvdVersion:        EnvdVersion,
		EnvdAccessToken:    EnvdAccessToken,
		Node:               Node,
		AutoPause:          atomic.Bool{},
		Pausing:            utils.NewSetOnce[*node.NodeInfo](),
		BaseTemplateID:     BaseTemplateID,
		mu:                 sync.RWMutex{},
	}

	instance.AutoPause.Store(AutoPause)

	return instance
}

type InstanceInfo struct {
	Instance           *api.Sandbox
	ExecutionID        string
	TeamID             *uuid.UUID
	BuildID            *uuid.UUID
	BaseTemplateID     string
	Metadata           map[string]string
	MaxInstanceLength  time.Duration
	StartTime          time.Time
	endTime            time.Time
	VCpu               int64
	TotalDiskSizeMB    int64
	RamMB              int64
	KernelVersion      string
	FirecrackerVersion string
	EnvdVersion        string
	EnvdAccessToken    *string
	Node               *node.NodeInfo
	AutoPause          atomic.Bool
	Pausing            *utils.SetOnce[*node.NodeInfo]
	mu                 sync.RWMutex
}

func (i *InstanceInfo) LoggerMetadata() sbxlogger.SandboxMetadata {
	return sbxlogger.SandboxMetadata{
		SandboxID:  i.Instance.SandboxID,
		TemplateID: i.Instance.TemplateID,
		TeamID:     i.TeamID.String(),
	}
}

func (i *InstanceInfo) IsExpired() bool {
	i.mu.RLock()
	defer i.mu.RUnlock()

	return time.Now().After(i.endTime)
}

func (i *InstanceInfo) GetEndTime() time.Time {
	i.mu.RLock()
	defer i.mu.RUnlock()

	return i.endTime
}

func (i *InstanceInfo) SetEndTime(endTime time.Time) {
	i.mu.Lock()
	defer i.mu.Unlock()

	i.endTime = endTime
}

func (i *InstanceInfo) SetExpired() {
	i.SetEndTime(time.Now())
}

type InstanceCache struct {
	reservations *ReservationCache
	pausing      *smap.Map[*InstanceInfo]

	cache          *lifecycleCache[*InstanceInfo]
	insertInstance func(data *InstanceInfo, created bool) error
	deleteInstance func(data *InstanceInfo) error
	redisStore     *redisInstanceStore

	sandboxCounter metric.Int64UpDownCounter
	createdCounter metric.Int64Counter

	mu sync.Mutex
}

func NewCache(
	ctx context.Context,
	meterProvider metric.MeterProvider,
	insertInstance func(data *InstanceInfo, created bool) error,
	deleteInstance func(data *InstanceInfo) error,
	redisClient ...redis.UniversalClient,
) *InstanceCache {
	// We will need to either use Redis or Consul's KV for storing active sandboxes to keep everything in sync,
	// right now we load them from Orchestrator
	cache := newLifecycleCache[*InstanceInfo]()

	meter := meterProvider.Meter("api.cache.sandbox")
	sandboxCounter, err := telemetry.GetUpDownCounter(meter, telemetry.SandboxCountMeterName)
	if err != nil {
		zap.L().Error("error getting counter", zap.Error(err))
	}

	createdCounter, err := telemetry.GetCounter(meter, telemetry.SandboxCreateMeterName)
	if err != nil {
		zap.L().Error("error getting counter", zap.Error(err))
	}

	var remoteStore *redisInstanceStore
	if len(redisClient) > 0 && redisClient[0] != nil {
		remoteStore = newRedisInstanceStore(redisClient[0])
	}

	instanceCache := &InstanceCache{
		cache:          cache,
		insertInstance: insertInstance,
		deleteInstance: deleteInstance,
		sandboxCounter: sandboxCounter,
		createdCounter: createdCounter,
		reservations:   NewReservationCache(),
		pausing:        smap.New[*InstanceInfo](),
		redisStore:     remoteStore,
	}

	cache.OnEviction(func(ctx context.Context, instanceInfo *InstanceInfo) {
		if instanceCache.redisStore != nil {
			redisItem, err := instanceCache.redisStore.Get(ctx, *instanceInfo.TeamID, instanceInfo.Instance.SandboxID)
			if err == nil {
				if redisItem.ExecutionID != instanceInfo.ExecutionID || redisItem.GetEndTime().After(time.Now()) {
					instanceCache.cache.Set(instanceInfo.Instance.SandboxID, redisItem)
					zap.L().Debug("skipping stale local sandbox eviction",
						zap.String("sandbox_id", instanceInfo.Instance.SandboxID),
						zap.String("local_execution_id", instanceInfo.ExecutionID),
						zap.String("redis_execution_id", redisItem.ExecutionID),
						zap.Time("redis_end_time", redisItem.GetEndTime()),
					)
					return
				}
			} else if !errors.Is(err, ErrRedisSandboxNotFound) {
				zap.L().Error("Error reading instance from redis store before eviction", zap.Error(err))
				return
			}

			if err := instanceCache.redisStore.Remove(ctx, *instanceInfo.TeamID, instanceInfo.Instance.SandboxID); err != nil {
				if !errors.Is(err, ErrRedisSandboxNotFound) {
					zap.L().Error("Error removing instance from redis store", zap.Error(err))
					return
				}
			}
		}

		err := deleteInstance(instanceInfo)
		if err != nil {
			zap.L().Error("Error deleting instance", zap.Error(err))
		}

		instanceCache.UpdateCounters(ctx, instanceInfo, -1, false)
	})

	go cache.Start(ctx)

	return instanceCache
}

func (c *InstanceCache) Len() int {
	return c.cache.Len()
}

func (c *InstanceCache) Set(key string, value *InstanceInfo, created bool) {
	_ = c.set(key, value, created, false)
}

func (c *InstanceCache) set(key string, value *InstanceInfo, created bool, waitForInsert bool) error {
	inserted := c.cache.SetIfAbsent(key, value)
	if inserted {
		if c.insertInstance == nil {
			return nil
		}

		insert := func() error {
			if err := c.insertInstance(value, created); err != nil {
				zap.L().Error("error inserting instance", zap.Error(err))
				return err
			}

			return nil
		}

		if waitForInsert {
			return insert()
		}

		go func() {
			_ = insert()
		}()
	}

	return nil
}

func (c *InstanceCache) MarkAsPausing(instanceInfo *InstanceInfo) {
	if instanceInfo.AutoPause.Load() {
		c.pausing.InsertIfAbsent(instanceInfo.Instance.SandboxID, instanceInfo)
	}
}

func (c *InstanceCache) UnmarkAsPausing(instanceInfo *InstanceInfo) {
	c.pausing.RemoveCb(instanceInfo.Instance.SandboxID, func(key string, v *InstanceInfo, exists bool) bool {
		if !exists {
			return false
		}

		// Make sure it's the same instance and not a sandbox which has been already resumed
		return v.ExecutionID == instanceInfo.ExecutionID
	})
}

func (c *InstanceCache) WaitForPause(ctx context.Context, sandboxID string) (*node.NodeInfo, error) {
	instanceInfo, ok := c.pausing.Get(sandboxID)
	if !ok {
		return nil, ErrPausingInstanceNotFound
	}

	value, err := instanceInfo.Pausing.WaitWithContext(ctx)
	if err != nil {
		return nil, fmt.Errorf("pause waiting was canceled: %w", err)
	}

	return value, nil
}

func (i *InstanceInfo) PauseDone(err error) {
	if err == nil {
		err := i.Pausing.SetValue(i.Node)
		if err != nil {
			zap.L().Error("error setting PauseDone value", zap.Error(err))

			return
		}
	} else {
		err := i.Pausing.SetError(err)
		if err != nil {
			zap.L().Error("error setting PauseDone error", zap.Error(err))

			return
		}
	}
}
