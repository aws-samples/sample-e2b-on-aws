package instance

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"

	"github.com/e2b-dev/infra/packages/api/internal/api"
	"github.com/e2b-dev/infra/packages/api/internal/node"
)

const (
	redisSandboxKeyPrefix     = "api:sandbox"
	redisReservationKeyPrefix = "api:sandbox-reservation"
)

type redisInstanceStore struct {
	client redis.UniversalClient
}

func newRedisInstanceStore(client redis.UniversalClient) *redisInstanceStore {
	return &redisInstanceStore{client: client}
}

type redisInstanceRecord struct {
	Instance           api.Sandbox       `json:"instance"`
	ExecutionID        string            `json:"executionID"`
	TeamID             uuid.UUID         `json:"teamID"`
	BuildID            uuid.UUID         `json:"buildID"`
	BaseTemplateID     string            `json:"baseTemplateID"`
	Metadata           map[string]string `json:"metadata"`
	MaxInstanceLength  time.Duration     `json:"maxInstanceLength"`
	StartTime          time.Time         `json:"startTime"`
	EndTime            time.Time         `json:"endTime"`
	VCpu               int64             `json:"vCpu"`
	TotalDiskSizeMB    int64             `json:"totalDiskSizeMB"`
	RamMB              int64             `json:"ramMB"`
	KernelVersion      string            `json:"kernelVersion"`
	FirecrackerVersion string            `json:"firecrackerVersion"`
	EnvdVersion        string            `json:"envdVersion"`
	EnvdAccessToken    *string           `json:"envdAccessToken,omitempty"`
	Node               node.NodeInfo     `json:"node"`
	AutoPause          bool              `json:"autoPause"`
}

func recordFromInstance(info *InstanceInfo) redisInstanceRecord {
	var buildID uuid.UUID
	if info.BuildID != nil {
		buildID = *info.BuildID
	}

	var teamID uuid.UUID
	if info.TeamID != nil {
		teamID = *info.TeamID
	}

	var n node.NodeInfo
	if info.Node != nil {
		n = *info.Node
	}

	return redisInstanceRecord{
		Instance:           *info.Instance,
		ExecutionID:        info.ExecutionID,
		TeamID:             teamID,
		BuildID:            buildID,
		BaseTemplateID:     info.BaseTemplateID,
		Metadata:           info.Metadata,
		MaxInstanceLength:  info.MaxInstanceLength,
		StartTime:          info.StartTime,
		EndTime:            info.GetEndTime(),
		VCpu:               info.VCpu,
		TotalDiskSizeMB:    info.TotalDiskSizeMB,
		RamMB:              info.RamMB,
		KernelVersion:      info.KernelVersion,
		FirecrackerVersion: info.FirecrackerVersion,
		EnvdVersion:        info.EnvdVersion,
		EnvdAccessToken:    info.EnvdAccessToken,
		Node:               n,
		AutoPause:          info.AutoPause.Load(),
	}
}

func (r redisInstanceRecord) toInstanceInfo() *InstanceInfo {
	instance := r.Instance
	teamID := r.TeamID
	buildID := r.BuildID
	nodeInfo := r.Node

	return NewInstanceInfo(
		&instance,
		r.ExecutionID,
		&teamID,
		&buildID,
		r.Metadata,
		r.MaxInstanceLength,
		r.StartTime,
		r.EndTime,
		r.VCpu,
		r.TotalDiskSizeMB,
		r.RamMB,
		r.KernelVersion,
		r.FirecrackerVersion,
		r.EnvdVersion,
		&nodeInfo,
		r.AutoPause,
		r.EnvdAccessToken,
		r.BaseTemplateID,
	)
}

func sandboxKey(teamID uuid.UUID, sandboxID string) string {
	return fmt.Sprintf("%s:item:%s:%s", redisSandboxKeyPrefix, teamID.String(), sandboxID)
}

func teamIndexKey(teamID uuid.UUID) string {
	return fmt.Sprintf("%s:index:%s", redisSandboxKeyPrefix, teamID.String())
}

func allIndexKey() string {
	return redisSandboxKeyPrefix + ":index:all"
}

func reservationKey(teamID uuid.UUID) string {
	return fmt.Sprintf("%s:%s:pending", redisReservationKeyPrefix, teamID.String())
}

func reservationResultKey(teamID uuid.UUID, sandboxID string) string {
	return fmt.Sprintf("%s:%s:%s:result", redisReservationKeyPrefix, teamID.String(), sandboxID)
}

func (s *redisInstanceStore) Add(ctx context.Context, info *InstanceInfo) error {
	data, err := json.Marshal(recordFromInstance(info))
	if err != nil {
		return fmt.Errorf("marshal sandbox: %w", err)
	}

	key := sandboxKey(*info.TeamID, info.Instance.SandboxID)
	index := teamIndexKey(*info.TeamID)
	pipe := s.client.TxPipeline()
	pipe.Set(ctx, key, data, 0)
	pipe.SAdd(ctx, index, info.Instance.SandboxID)
	pipe.SAdd(ctx, allIndexKey(), key)
	pipe.ZAdd(ctx, index+":exp", redis.Z{Score: float64(info.GetEndTime().Unix()), Member: info.Instance.SandboxID})
	_, err = pipe.Exec(ctx)
	if err != nil {
		return fmt.Errorf("store sandbox in redis: %w", err)
	}

	return nil
}

func (s *redisInstanceStore) Get(ctx context.Context, teamID uuid.UUID, sandboxID string) (*InstanceInfo, error) {
	data, err := s.client.Get(ctx, sandboxKey(teamID, sandboxID)).Bytes()
	if errors.Is(err, redis.Nil) {
		return nil, fmt.Errorf("instance %q doesn't exist", sandboxID)
	}
	if err != nil {
		return nil, fmt.Errorf("get sandbox from redis: %w", err)
	}

	var record redisInstanceRecord
	if err := json.Unmarshal(data, &record); err != nil {
		return nil, fmt.Errorf("unmarshal sandbox: %w", err)
	}

	return record.toInstanceInfo(), nil
}

func (s *redisInstanceStore) GetByID(ctx context.Context, sandboxID string) (*InstanceInfo, error) {
	items, err := s.AllItems(ctx)
	if err != nil {
		return nil, err
	}

	for _, item := range items {
		if item.Instance.SandboxID == sandboxID {
			return item, nil
		}
	}

	return nil, fmt.Errorf("instance %q doesn't exist", sandboxID)
}

func (s *redisInstanceStore) TeamItems(ctx context.Context, teamID uuid.UUID) ([]*InstanceInfo, error) {
	ids, err := s.client.SMembers(ctx, teamIndexKey(teamID)).Result()
	if err != nil {
		return nil, fmt.Errorf("list team sandbox ids from redis: %w", err)
	}

	items := make([]*InstanceInfo, 0, len(ids))
	for _, id := range ids {
		item, err := s.Get(ctx, teamID, id)
		if errors.Is(err, redis.Nil) {
			continue
		}
		if err != nil {
			return nil, err
		}
		if item.IsExpired() {
			continue
		}
		items = append(items, item)
	}

	return items, nil
}

func (s *redisInstanceStore) AllItems(ctx context.Context) ([]*InstanceInfo, error) {
	keys, err := s.client.SMembers(ctx, allIndexKey()).Result()
	if err != nil {
		return nil, fmt.Errorf("list redis sandboxes: %w", err)
	}

	items := make([]*InstanceInfo, 0, len(keys))
	for _, key := range keys {
		data, err := s.client.Get(ctx, key).Bytes()
		if errors.Is(err, redis.Nil) {
			continue
		}
		if err != nil {
			return nil, fmt.Errorf("get sandbox from redis: %w", err)
		}
		var record redisInstanceRecord
		if err := json.Unmarshal(data, &record); err != nil {
			return nil, fmt.Errorf("unmarshal sandbox: %w", err)
		}
		item := record.toInstanceInfo()
		if item.IsExpired() {
			continue
		}
		items = append(items, item)
	}

	return items, nil
}

func (s *redisInstanceStore) Update(ctx context.Context, info *InstanceInfo) error {
	return s.Add(ctx, info)
}

func (s *redisInstanceStore) Remove(ctx context.Context, teamID uuid.UUID, sandboxID string) error {
	pipe := s.client.TxPipeline()
	pipe.Del(ctx, sandboxKey(teamID, sandboxID))
	pipe.SRem(ctx, teamIndexKey(teamID), sandboxID)
	pipe.SRem(ctx, allIndexKey(), sandboxKey(teamID, sandboxID))
	pipe.ZRem(ctx, teamIndexKey(teamID)+":exp", sandboxID)
	_, err := pipe.Exec(ctx)
	if err != nil {
		return fmt.Errorf("remove sandbox from redis: %w", err)
	}

	return nil
}

var reserveScript = redis.NewScript(`
redis.call('ZREMRANGEBYSCORE', KEYS[2], '-inf', ARGV[4])
if redis.call('SISMEMBER', KEYS[1], ARGV[1]) == 1 then
	return 1
end
if redis.call('ZSCORE', KEYS[2], ARGV[1]) then
	return 2
end
local limit = tonumber(ARGV[2])
if limit >= 0 then
	local storageCount = redis.call('SCARD', KEYS[1])
	local pendingCount = redis.call('ZCARD', KEYS[2])
	if storageCount + pendingCount >= limit then
		return 3
	end
end
redis.call('DEL', KEYS[3])
redis.call('ZADD', KEYS[2], ARGV[3], ARGV[1])
return 0
`)

func (s *redisInstanceStore) Reserve(ctx context.Context, teamID uuid.UUID, sandboxID string, limit int64) error {
	now := time.Now()
	result, err := reserveScript.Run(ctx, s.client,
		[]string{teamIndexKey(teamID), reservationKey(teamID), reservationResultKey(teamID, sandboxID)},
		sandboxID,
		limit,
		float64(now.Unix()),
		float64(now.Add(-90*time.Second).Unix()),
	).Int()
	if err != nil {
		return fmt.Errorf("reserve sandbox in redis: %w", err)
	}

	switch result {
	case 0:
		return nil
	case 1, 2:
		return &ErrAlreadyBeingStarted{sandboxID: sandboxID}
	case 3:
		return &ErrSandboxLimitExceeded{teamID: teamID.String()}
	default:
		return fmt.Errorf("unexpected redis reservation result: %d", result)
	}
}

func (s *redisInstanceStore) ReleaseReservation(ctx context.Context, teamID uuid.UUID, sandboxID string) {
	s.client.ZRem(ctx, reservationKey(teamID), sandboxID)
	s.client.Del(ctx, reservationResultKey(teamID, sandboxID))
}
