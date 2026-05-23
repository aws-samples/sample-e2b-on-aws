package instance

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"time"

	"go.uber.org/zap"

	"github.com/e2b-dev/infra/packages/api/internal/api"
)

// TODO: this should be removed once we have a better way to handle node sync
// Don't remove instances that were started in the grace period on node sync
// This is to prevent remove instances that are still being started
const syncSandboxRemoveGracePeriod = 10 * time.Second

func getMaxAllowedTTL(now time.Time, startTime time.Time, duration, maxInstanceLength time.Duration) time.Duration {
	timeLeft := maxInstanceLength - now.Sub(startTime)
	if timeLeft <= 0 {
		return 0
	}

	return min(timeLeft, duration)
}

// KeepAliveFor the instance's expiration timer.
func (c *InstanceCache) KeepAliveFor(instanceID string, duration time.Duration, allowShorter bool) (*InstanceInfo, *api.APIError) {
	instance, err := c.Get(instanceID)
	if err != nil {
		return nil, &api.APIError{Code: http.StatusNotFound, ClientMsg: fmt.Sprintf("Sandbox '%s' not found", instanceID), Err: err}
	}

	now := time.Now()

	endTime := instance.GetEndTime()
	if !allowShorter && endTime.After(now.Add(duration)) {
		return instance, nil
	}

	if (time.Since(instance.StartTime)) > instance.MaxInstanceLength {
		c.cache.Remove(instanceID)

		msg := fmt.Sprintf("Sandbox '%s' reached maximal allowed uptime", instanceID)
		return nil, &api.APIError{Code: http.StatusForbidden, ClientMsg: msg, Err: errors.New(msg)}
	} else {
		maxAllowedTTL := getMaxAllowedTTL(now, instance.StartTime, duration, instance.MaxInstanceLength)

		newEndTime := now.Add(maxAllowedTTL)
		instance.SetEndTime(newEndTime)
	}

	if c.redisStore != nil {
		if err := c.redisStore.Update(context.Background(), instance); err != nil {
			return nil, &api.APIError{Code: http.StatusInternalServerError, ClientMsg: "Error when updating sandbox timeout", Err: err}
		}
	}

	return instance, nil
}

func (c *InstanceCache) Sync(ctx context.Context, instances []*InstanceInfo, nodeID string) {
	c.Reconcile(ctx, instances, nodeID)
}

func (c *InstanceCache) Reconcile(ctx context.Context, instances []*InstanceInfo, nodeID string) (orphans []*InstanceInfo) {
	if c.redisStore != nil {
		return c.reconcileRedis(ctx, instances, nodeID)
	}

	instanceMap := make(map[string]*InstanceInfo)

	// Use a map for faster lookup
	for _, instance := range instances {
		instanceMap[instance.Instance.SandboxID] = instance
	}

	// Delete instances that are not in Orchestrator anymore
	for _, item := range c.cache.Items() {
		if item.Instance.ClientID != nodeID {
			continue
		}
		if time.Since(item.StartTime) <= syncSandboxRemoveGracePeriod {
			continue
		}
		_, found := instanceMap[item.Instance.SandboxID]
		if !found {
			c.cache.Remove(item.Instance.SandboxID)
		}
	}

	// Add instances that are not in the cache with the default TTL
	for _, instance := range instances {
		if c.Exists(instance.Instance.SandboxID) {
			continue
		}
		err := c.Add(ctx, instance, false)
		if err != nil {
			zap.L().Error("error adding instance to cache", zap.Error(err))
		}
	}

	return nil
}

func (c *InstanceCache) reconcileRedis(ctx context.Context, instances []*InstanceInfo, nodeID string) (orphans []*InstanceInfo) {
	redisItems, err := c.redisStore.AllItems(ctx)
	if err != nil {
		zap.L().Error("error listing redis sandboxes during reconcile", zap.Error(err))
		return nil
	}

	nodeReported := make(map[string]*InstanceInfo, len(instances))
	for _, instance := range instances {
		nodeReported[instance.Instance.SandboxID] = instance
	}

	redisByID := make(map[string]*InstanceInfo, len(redisItems))
	for _, item := range redisItems {
		redisByID[item.Instance.SandboxID] = item
	}

	for _, item := range redisItems {
		if item.Instance.ClientID != nodeID {
			continue
		}
		if time.Since(item.StartTime) <= syncSandboxRemoveGracePeriod {
			continue
		}
		if _, found := nodeReported[item.Instance.SandboxID]; !found {
			if item.TeamID != nil {
				if err := c.redisStore.Remove(ctx, *item.TeamID, item.Instance.SandboxID); err != nil {
					zap.L().Error("error removing missing sandbox from redis", zap.Error(err))
				}
			}
			c.cache.Remove(item.Instance.SandboxID)
		}
	}

	for _, instance := range instances {
		if _, found := redisByID[instance.Instance.SandboxID]; !found {
			orphans = append(orphans, instance)
			continue
		}

		if !c.Exists(instance.Instance.SandboxID) {
			c.Set(instance.Instance.SandboxID, instance, false)
		}
	}

	return orphans
}
