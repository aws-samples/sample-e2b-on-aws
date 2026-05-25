package instance

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"

	"github.com/e2b-dev/infra/packages/api/internal/api"
	"github.com/e2b-dev/infra/packages/api/internal/node"
)

const (
	redisKeySeparator    = ":"
	redisSandboxKeyBase  = "sandbox:storage"
	redisSandboxesKey    = "sandboxes"
	redisIndexKey        = "index"
	redisGlobalTeamsKey  = "global:teams"
	redisReservationsKey = "reservations"
	redisPendingKey      = "pending"
	redisResultKey       = "result"

	redisStaleTeamCutoff = 5 * time.Minute
)

type redisInstanceStore struct {
	client redis.UniversalClient
}

var ErrRedisSandboxNotFound = errors.New("sandbox not found in redis store")

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

func redisCreateKey(parts ...string) string {
	return strings.Join(parts, redisKeySeparator)
}

func redisSameSlot(key string) string {
	return fmt.Sprintf("{%s}", key)
}

func redisTeamPrefix(teamID uuid.UUID) string {
	return redisCreateKey(redisSandboxKeyBase, redisSameSlot(teamID.String()))
}

func sandboxKey(teamID uuid.UUID, sandboxID string) string {
	return redisCreateKey(redisTeamPrefix(teamID), redisSandboxesKey, sandboxID)
}

func teamIndexKey(teamID uuid.UUID) string {
	return redisCreateKey(redisTeamPrefix(teamID), redisIndexKey)
}

func globalTeamsKey() string {
	return redisCreateKey(redisSandboxKeyBase, redisGlobalTeamsKey)
}

func reservationPrefix(teamID uuid.UUID) string {
	return redisCreateKey(redisTeamPrefix(teamID), redisReservationsKey)
}

func reservationKey(teamID uuid.UUID) string {
	return redisCreateKey(reservationPrefix(teamID), redisPendingKey)
}

func reservationResultKey(teamID uuid.UUID, sandboxID string) string {
	return redisCreateKey(reservationPrefix(teamID), sandboxID, redisResultKey)
}

var addSandboxScript = redis.NewScript(`
redis.call('SET', KEYS[1], ARGV[1])
redis.call('SADD', KEYS[2], ARGV[2])
return 1
`)

var removeSandboxScript = redis.NewScript(`
if redis.call('EXISTS', KEYS[1]) == 0 then
	return 0
end
redis.call('DEL', KEYS[1])
redis.call('SREM', KEYS[2], ARGV[1])
return 1
`)

func (s *redisInstanceStore) Add(ctx context.Context, info *InstanceInfo) error {
	data, err := json.Marshal(recordFromInstance(info))
	if err != nil {
		return fmt.Errorf("marshal sandbox: %w", err)
	}

	key := sandboxKey(*info.TeamID, info.Instance.SandboxID)
	index := teamIndexKey(*info.TeamID)
	if err := s.client.ZAdd(ctx, globalTeamsKey(), redis.Z{
		Score:  float64(time.Now().Unix()),
		Member: info.TeamID.String(),
	}).Err(); err != nil {
		return fmt.Errorf("add team to redis global sandbox index: %w", err)
	}

	err = addSandboxScript.Run(ctx, s.client, []string{key, index}, data, info.Instance.SandboxID).Err()
	if err != nil {
		return fmt.Errorf("store sandbox in redis: %w", err)
	}

	return nil
}

func (s *redisInstanceStore) Get(ctx context.Context, teamID uuid.UUID, sandboxID string) (*InstanceInfo, error) {
	data, err := s.client.Get(ctx, sandboxKey(teamID, sandboxID)).Bytes()
	if errors.Is(err, redis.Nil) {
		return nil, fmt.Errorf("instance %q doesn't exist: %w", sandboxID, ErrRedisSandboxNotFound)
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

	return nil, fmt.Errorf("instance %q doesn't exist: %w", sandboxID, ErrRedisSandboxNotFound)
}

func (s *redisInstanceStore) TeamItems(ctx context.Context, teamID uuid.UUID) ([]*InstanceInfo, error) {
	ids, err := s.client.SMembers(ctx, teamIndexKey(teamID)).Result()
	if err != nil {
		return nil, fmt.Errorf("list team sandbox ids from redis: %w", err)
	}
	if len(ids) == 0 {
		return []*InstanceInfo{}, nil
	}

	keys := make([]string, 0, len(ids))
	for _, id := range ids {
		keys = append(keys, sandboxKey(teamID, id))
	}

	results, err := s.client.MGet(ctx, keys...).Result()
	if err != nil {
		return nil, fmt.Errorf("get team sandboxes from redis: %w", err)
	}

	items := make([]*InstanceInfo, 0, len(ids))
	for _, raw := range results {
		if raw == nil {
			continue
		}

		var data []byte
		switch value := raw.(type) {
		case string:
			data = []byte(value)
		case []byte:
			data = value
		default:
			return nil, fmt.Errorf("unexpected redis sandbox payload type %T", raw)
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

func (s *redisInstanceStore) AllItems(ctx context.Context) ([]*InstanceInfo, error) {
	teams, err := s.client.ZRangeWithScores(ctx, globalTeamsKey(), 0, -1).Result()
	if err != nil {
		return nil, fmt.Errorf("list redis sandboxes: %w", err)
	}

	items := make([]*InstanceInfo, 0, len(teams))
	var staleTeams []interface{}
	for _, team := range teams {
		teamIDRaw, ok := team.Member.(string)
		if !ok {
			continue
		}
		teamID, err := uuid.Parse(teamIDRaw)
		if err != nil {
			staleTeams = append(staleTeams, team.Member)
			continue
		}

		teamItems, err := s.TeamItems(ctx, teamID)
		if err != nil {
			return nil, err
		}
		if len(teamItems) == 0 && int64(team.Score) < time.Now().Add(-redisStaleTeamCutoff).Unix() {
			staleTeams = append(staleTeams, team.Member)
		}
		items = append(items, teamItems...)
	}

	if len(staleTeams) > 0 {
		_ = s.client.ZRem(ctx, globalTeamsKey(), staleTeams...).Err()
	}

	return items, nil
}

func (s *redisInstanceStore) Update(ctx context.Context, info *InstanceInfo) error {
	return s.Add(ctx, info)
}

func (s *redisInstanceStore) Remove(ctx context.Context, teamID uuid.UUID, sandboxID string) error {
	result, err := removeSandboxScript.Run(ctx, s.client, []string{sandboxKey(teamID, sandboxID), teamIndexKey(teamID)}, sandboxID).Int()
	if err != nil {
		return fmt.Errorf("remove sandbox from redis: %w", err)
	}
	if result == 0 {
		return ErrRedisSandboxNotFound
	}

	return nil
}

const (
	reserveResultReserved         = 0
	reserveResultAlreadyInStorage = 1
	reserveResultAlreadyPending   = 2
	reserveResultLimitExceeded    = 3
)

var reserveScript = redis.NewScript(fmt.Sprintf(`
redis.call('ZREMRANGEBYSCORE', KEYS[2], '-inf', ARGV[4])
if redis.call('SISMEMBER', KEYS[1], ARGV[1]) == 1 then
	return %d
end
if redis.call('ZSCORE', KEYS[2], ARGV[1]) then
	return %d
end
local limit = tonumber(ARGV[2])
if limit >= 0 then
	local storageCount = redis.call('SCARD', KEYS[1])
	local pendingCount = redis.call('ZCARD', KEYS[2])
	if storageCount + pendingCount >= limit then
		return %d
	end
end
redis.call('DEL', KEYS[3])
redis.call('ZADD', KEYS[2], ARGV[3], ARGV[1])
return %d
`, reserveResultAlreadyInStorage, reserveResultAlreadyPending, reserveResultLimitExceeded, reserveResultReserved))

var releaseReservationScript = redis.NewScript(`
redis.call('ZREM', KEYS[1], ARGV[1])
redis.call('DEL', KEYS[2])
return 1
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
	case reserveResultReserved:
		return nil
	case reserveResultAlreadyInStorage, reserveResultAlreadyPending:
		return &ErrAlreadyBeingStarted{sandboxID: sandboxID}
	case reserveResultLimitExceeded:
		return &ErrSandboxLimitExceeded{teamID: teamID.String()}
	default:
		return fmt.Errorf("unexpected redis reservation result: %d", result)
	}
}

func (s *redisInstanceStore) ReleaseReservation(ctx context.Context, teamID uuid.UUID, sandboxID string) {
	_ = releaseReservationScript.Run(ctx, s.client, []string{reservationKey(teamID), reservationResultKey(teamID, sandboxID)}, sandboxID).Err()
}
