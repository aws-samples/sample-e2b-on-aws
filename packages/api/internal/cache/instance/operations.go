package instance

import (
	"context"
	"fmt"

	"github.com/google/uuid"
	"go.uber.org/zap"

	sbxlogger "github.com/e2b-dev/infra/packages/shared/pkg/logger/sandbox"
)

func (c *InstanceCache) Count() int {
	return c.cache.Len()
}

func (c *InstanceCache) CountForTeam(teamID uuid.UUID) (count uint) {
	for _, item := range c.cache.Items() {
		currentTeamID := item.TeamID

		if currentTeamID == nil {
			continue
		}

		if *currentTeamID == teamID {
			count++
		}
	}

	return count
}

// Exists Check if the instance exists in the cache or is being evicted.
func (c *InstanceCache) Exists(instanceID string) bool {
	return c.cache.Has(instanceID, true)
}

// Get the item from the cache.
func (c *InstanceCache) Get(instanceID string) (*InstanceInfo, error) {
	item, ok := c.cache.Get(instanceID)
	if !ok {
		return nil, fmt.Errorf("instance \"%s\" doesn't exist", instanceID)
	}

	return item, nil
}

func (c *InstanceCache) GetInstances(teamID *uuid.UUID) (instances []*InstanceInfo) {
	for _, item := range c.cache.Items() {
		currentTeamID := item.TeamID

		if teamID == nil || *currentTeamID == *teamID {
			instances = append(instances, item)
		}
	}

	return instances
}

// Add the instance to the cache and start expiration timer.
// If the instance already exists we do nothing - it was loaded from Orchestrator.
// TODO: Any error here should delete the sandbox
func (c *InstanceCache) Add(ctx context.Context, instance *InstanceInfo, newlyCreated bool) error {
	zap.L().Info("Starting to add sandbox to instance cache",
		sbxlogger.WithSandboxID(instance.Instance.SandboxID),
		zap.String("execution_id", instance.ExecutionID),
		zap.String("team_id", instance.TeamID.String()),
		zap.Bool("newly_created", newlyCreated),
		zap.Time("start_time", instance.StartTime),
		zap.Time("end_time", instance.GetEndTime()),
	)

	sbxlogger.I(instance).Debug("Adding sandbox to cache",
		zap.Bool("newly_created", newlyCreated),
		zap.Time("start_time", instance.StartTime),
		zap.Time("end_time", instance.GetEndTime()),
	)

	// Validation checks
	zap.L().Debug("Validating instance data before adding to cache",
		sbxlogger.WithSandboxID(instance.Instance.SandboxID),
	)

	if instance.Instance == nil {
		zap.L().Error("Instance validation failed: instance is nil",
			sbxlogger.WithSandboxID(instance.Instance.SandboxID),
		)
		return fmt.Errorf("instance doesn't contain info about inself")
	}

	if instance.Instance.SandboxID == "" {
		zap.L().Error("Instance validation failed: missing sandbox ID")
		return fmt.Errorf("instance is missing sandbox ID")
	}

	if instance.TeamID == nil {
		zap.L().Error("Instance validation failed: missing team ID",
			sbxlogger.WithSandboxID(instance.Instance.SandboxID),
		)
		return fmt.Errorf("instance %s is missing team ID", instance.Instance.SandboxID)
	}

	if instance.Instance.ClientID == "" {
		zap.L().Error("Instance validation failed: missing client ID",
			sbxlogger.WithSandboxID(instance.Instance.SandboxID),
		)
		return fmt.Errorf("instance %s is missing client ID", instance.Instance.ClientID)
	}

	if instance.Instance.TemplateID == "" {
		zap.L().Error("Instance validation failed: missing template ID",
			sbxlogger.WithSandboxID(instance.Instance.SandboxID),
		)
		return fmt.Errorf("instance %s is missing env ID", instance.Instance.TemplateID)
	}

	zap.L().Debug("Instance validation passed",
		sbxlogger.WithSandboxID(instance.Instance.SandboxID),
		zap.String("client_id", instance.Instance.ClientID),
		zap.String("template_id", instance.Instance.TemplateID),
		zap.String("team_id", instance.TeamID.String()),
	)

	endTime := instance.GetEndTime()

	zap.L().Debug("Validating instance time settings",
		sbxlogger.WithSandboxID(instance.Instance.SandboxID),
		zap.Time("start_time", instance.StartTime),
		zap.Time("end_time", endTime),
		zap.Duration("max_instance_length", instance.MaxInstanceLength),
	)

	if instance.StartTime.IsZero() || endTime.IsZero() || instance.StartTime.After(endTime) {
		zap.L().Error("Instance time validation failed",
			sbxlogger.WithSandboxID(instance.Instance.SandboxID),
			zap.Time("start_time", instance.StartTime),
			zap.Time("end_time", endTime),
			zap.Bool("start_time_zero", instance.StartTime.IsZero()),
			zap.Bool("end_time_zero", endTime.IsZero()),
			zap.Bool("start_after_end", instance.StartTime.After(endTime)),
		)
		return fmt.Errorf("instance %s has invalid start(%s)/end(%s) times", instance.Instance.SandboxID, instance.StartTime, endTime)
	}

	if endTime.Sub(instance.StartTime) > instance.MaxInstanceLength {
		newEndTime := instance.StartTime.Add(instance.MaxInstanceLength)
		zap.L().Info("Adjusting instance end time to respect max length limit",
			sbxlogger.WithSandboxID(instance.Instance.SandboxID),
			zap.Time("original_end_time", endTime),
			zap.Time("adjusted_end_time", newEndTime),
			zap.Duration("max_instance_length", instance.MaxInstanceLength),
		)
		instance.SetEndTime(newEndTime)
	}

	zap.L().Info("Adding instance to lifecycle cache - this will trigger Redis operations",
		sbxlogger.WithSandboxID(instance.Instance.SandboxID),
		zap.String("execution_id", instance.ExecutionID),
		zap.Bool("newly_created", newlyCreated),
	)

	c.Set(instance.Instance.SandboxID, instance, newlyCreated)
	
	zap.L().Debug("Updating instance counters",
		sbxlogger.WithSandboxID(instance.Instance.SandboxID),
	)
	
	c.UpdateCounters(ctx, instance, 1, newlyCreated)

	zap.L().Debug("Releasing sandbox reservation",
		sbxlogger.WithSandboxID(instance.Instance.SandboxID),
	)

	// Release the reservation if it exists
	c.reservations.release(instance.Instance.SandboxID)

	zap.L().Info("Successfully added sandbox to instance cache",
		sbxlogger.WithSandboxID(instance.Instance.SandboxID),
		zap.String("execution_id", instance.ExecutionID),
		zap.Bool("newly_created", newlyCreated),
	)

	return nil
}

// Delete the instance and remove it from the cache.
func (c *InstanceCache) Delete(instanceID string, pause bool) bool {
	value, found := c.cache.GetAndRemove(instanceID)
	if found {
		value.AutoPause.Store(pause)

		if pause {
			c.MarkAsPausing(value)
		}
	}

	return found
}

func (c *InstanceCache) Items() []*InstanceInfo {
	return c.cache.Items()
}
