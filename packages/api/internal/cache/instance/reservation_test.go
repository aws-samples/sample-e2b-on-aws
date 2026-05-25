package instance

import (
	"context"
	"strings"
	"testing"
	"time"

	miniredis "github.com/alicebob/miniredis/v2"
	"github.com/google/uuid"
	goredis "github.com/redis/go-redis/v9"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.opentelemetry.io/otel/metric/noop"

	"github.com/e2b-dev/infra/packages/api/internal/api"
	"github.com/e2b-dev/infra/packages/api/internal/node"
)

const (
	sandboxID = "test-sandbox-id"
)

var teamID = uuid.New()

func newInstanceCache() (*InstanceCache, context.CancelFunc) {
	ctx, cancel := context.WithCancel(context.Background())
	cache := NewCache(ctx, noop.MeterProvider{}, nil, nil)
	return cache, cancel
}

func TestReservation(t *testing.T) {
	cache, cancel := newInstanceCache()
	defer cancel()

	_, err := cache.Reserve(sandboxID, teamID, 1)
	assert.NoError(t, err)
}

func TestReservation_Exceeded(t *testing.T) {
	cache, cancel := newInstanceCache()
	defer cancel()

	_, err := cache.Reserve(sandboxID, teamID, 0)
	assert.Error(t, err)
	assert.IsType(t, &ErrSandboxLimitExceeded{}, err)
}

func TestReservation_SameSandbox(t *testing.T) {
	cache, cancel := newInstanceCache()
	defer cancel()

	_, err := cache.Reserve(sandboxID, teamID, 10)
	assert.NoError(t, err)

	_, err = cache.Reserve(sandboxID, teamID, 10)
	require.Error(t, err)
	assert.IsType(t, &ErrAlreadyBeingStarted{}, err)
}

func TestReservation_Release(t *testing.T) {
	cache, cancel := newInstanceCache()
	defer cancel()

	release, err := cache.Reserve(sandboxID, teamID, 1)
	assert.NoError(t, err)
	release()

	_, err = cache.Reserve(sandboxID, teamID, 1)
	assert.NoError(t, err)
}

func TestRedisKeysFollowOfficialSameSlotPattern(t *testing.T) {
	tag := redisSameSlot(teamID.String())

	keys := []string{
		redisTeamPrefix(teamID),
		teamIndexKey(teamID),
		reservationKey(teamID),
		reservationResultKey(teamID, sandboxID),
		sandboxKey(teamID, sandboxID),
	}

	for _, key := range keys {
		require.Contains(t, key, tag)
		require.Equal(t, 1, strings.Count(key, tag))
	}

	require.Equal(t, "sandbox:storage:"+tag, redisTeamPrefix(teamID))
	require.Equal(t, "sandbox:storage:"+tag+":index", teamIndexKey(teamID))
	require.Equal(t, "sandbox:storage:"+tag+":sandboxes:"+sandboxID, sandboxKey(teamID, sandboxID))
	require.Equal(t, "sandbox:storage:"+tag+":reservations:pending", reservationKey(teamID))
	require.Equal(t, "sandbox:storage:"+tag+":reservations:"+sandboxID+":result", reservationResultKey(teamID, sandboxID))
	require.Equal(t, "sandbox:storage:global:teams", globalTeamsKey())
}

func newRedisInstanceStoreForTest(t *testing.T) (*redisInstanceStore, func()) {
	t.Helper()

	server, err := miniredis.Run()
	require.NoError(t, err)

	client := goredis.NewClient(&goredis.Options{Addr: server.Addr()})
	cleanup := func() {
		require.NoError(t, client.Close())
		server.Close()
	}

	return newRedisInstanceStore(client), cleanup
}

func newTestInstanceInfo(sandboxID string, teamID uuid.UUID) *InstanceInfo {
	buildID := uuid.New()
	start := time.Now().UTC().Truncate(time.Second)
	end := start.Add(time.Hour)
	alias := "base"
	token := "envd-token"

	return NewInstanceInfo(
		&api.Sandbox{
			SandboxID:       sandboxID,
			TemplateID:      "tpl",
			ClientID:        "node-a",
			Alias:           &alias,
			EnvdVersion:     "0.0.1",
			EnvdAccessToken: &token,
		},
		"execution-id",
		&teamID,
		&buildID,
		map[string]string{"k": "v"},
		time.Hour,
		start,
		end,
		2,
		4096,
		1024,
		"kernel",
		"fc",
		"0.0.1",
		&node.NodeInfo{
			ID:                  "node-a",
			OrchestratorAddress: "10.0.0.1:5008",
			IPAddress:           "10.0.0.1",
		},
		true,
		&token,
		"base-template",
	)
}

func TestRedisStoreAddListReserveAndRemove(t *testing.T) {
	store, cleanup := newRedisInstanceStoreForTest(t)
	defer cleanup()

	ctx := context.Background()
	info := newTestInstanceInfo(sandboxID, teamID)

	require.NoError(t, store.Add(ctx, info))

	got, err := store.Get(ctx, teamID, sandboxID)
	require.NoError(t, err)
	require.Equal(t, sandboxID, got.Instance.SandboxID)

	teamItems, err := store.TeamItems(ctx, teamID)
	require.NoError(t, err)
	require.Len(t, teamItems, 1)

	allItems, err := store.AllItems(ctx)
	require.NoError(t, err)
	require.Len(t, allItems, 1)

	err = store.Reserve(ctx, teamID, "another-sandbox", 1)
	require.ErrorAs(t, err, new(*ErrSandboxLimitExceeded))

	err = store.Reserve(ctx, teamID, sandboxID, 10)
	require.ErrorAs(t, err, new(*ErrAlreadyBeingStarted))

	require.NoError(t, store.Remove(ctx, teamID, sandboxID))
	require.ErrorIs(t, store.Remove(ctx, teamID, sandboxID), ErrRedisSandboxNotFound)

	teamItems, err = store.TeamItems(ctx, teamID)
	require.NoError(t, err)
	require.Empty(t, teamItems)

	allItems, err = store.AllItems(ctx)
	require.NoError(t, err)
	require.Empty(t, allItems)
}

func TestRedisReservationReserveRelease(t *testing.T) {
	store, cleanup := newRedisInstanceStoreForTest(t)
	defer cleanup()

	ctx := context.Background()

	require.NoError(t, store.Reserve(ctx, teamID, sandboxID, 1))

	err := store.Reserve(ctx, teamID, "second-sandbox", 1)
	require.ErrorAs(t, err, new(*ErrSandboxLimitExceeded))

	err = store.Reserve(ctx, teamID, sandboxID, 1)
	require.ErrorAs(t, err, new(*ErrAlreadyBeingStarted))

	store.ReleaseReservation(ctx, teamID, sandboxID)
	require.NoError(t, store.Reserve(ctx, teamID, "second-sandbox", 1))
}

func TestRedisRecordRoundTrip(t *testing.T) {
	info := newTestInstanceInfo(sandboxID, teamID)

	got := recordFromInstance(info).toInstanceInfo()

	require.Equal(t, sandboxID, got.Instance.SandboxID)
	require.Equal(t, teamID, *got.TeamID)
	require.Equal(t, *info.BuildID, *got.BuildID)
	require.Equal(t, "node-a", got.Node.ID)
	require.Equal(t, info.GetEndTime(), got.GetEndTime())
	require.Equal(t, true, got.AutoPause.Load())
	require.Equal(t, "base-template", got.BaseTemplateID)
	require.Equal(t, "v", got.Metadata["k"])
}

func TestRedisStoreMissingLookupsReturnNotFound(t *testing.T) {
	store, cleanup := newRedisInstanceStoreForTest(t)
	defer cleanup()

	ctx := context.Background()

	_, err := store.Get(ctx, teamID, sandboxID)
	require.ErrorIs(t, err, ErrRedisSandboxNotFound)

	_, err = store.GetByID(ctx, sandboxID)
	require.ErrorIs(t, err, ErrRedisSandboxNotFound)
}

func TestDeleteLocalRedisBackedInstanceCallsDeleteHook(t *testing.T) {
	server, err := miniredis.Run()
	require.NoError(t, err)
	defer server.Close()

	client := goredis.NewClient(&goredis.Options{Addr: server.Addr()})
	defer func() { require.NoError(t, client.Close()) }()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	deleted := make(chan string, 1)
	cache := NewCache(
		ctx,
		noop.MeterProvider{},
		nil,
		func(info *InstanceInfo) error {
			deleted <- info.Instance.SandboxID
			return nil
		},
		client,
	)

	info := newTestInstanceInfo(sandboxID, teamID)
	require.NoError(t, cache.Add(ctx, info, true))

	require.True(t, cache.Delete(sandboxID, false))

	select {
	case got := <-deleted:
		require.Equal(t, sandboxID, got)
	case <-time.After(time.Second):
		t.Fatal("delete hook was not called")
	}
}

func TestRedisBackedGetDoesNotReturnLocalWhenRedisMissing(t *testing.T) {
	server, err := miniredis.Run()
	require.NoError(t, err)
	defer server.Close()

	client := goredis.NewClient(&goredis.Options{Addr: server.Addr()})
	defer func() { require.NoError(t, client.Close()) }()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	deleted := make(chan string, 1)
	cache := NewCache(
		ctx,
		noop.MeterProvider{},
		nil,
		func(info *InstanceInfo) error {
			deleted <- info.Instance.SandboxID
			return nil
		},
		client,
	)

	info := newTestInstanceInfo(sandboxID, teamID)
	require.NoError(t, cache.Add(ctx, info, true))
	require.NoError(t, cache.redisStore.Remove(ctx, teamID, sandboxID))

	_, err = cache.Get(sandboxID)
	require.ErrorIs(t, err, ErrRedisSandboxNotFound)
	require.False(t, cache.Exists(sandboxID))

	select {
	case got := <-deleted:
		t.Fatalf("stale local cache removal called delete hook for %s", got)
	default:
	}
}

func TestRedisBackedEvictionKeepsNewerRedisExecution(t *testing.T) {
	server, err := miniredis.Run()
	require.NoError(t, err)
	defer server.Close()

	client := goredis.NewClient(&goredis.Options{Addr: server.Addr()})
	defer func() { require.NoError(t, client.Close()) }()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	deleted := make(chan string, 1)
	cache := NewCache(
		ctx,
		noop.MeterProvider{},
		nil,
		func(info *InstanceInfo) error {
			deleted <- info.ExecutionID
			return nil
		},
		client,
	)

	oldInfo := newTestInstanceInfo(sandboxID, teamID)
	require.NoError(t, cache.Add(ctx, oldInfo, true))

	newInfo := newTestInstanceInfo(sandboxID, teamID)
	newInfo.ExecutionID = "new-execution-id"
	newInfo.SetEndTime(time.Now().Add(time.Hour))
	require.NoError(t, cache.redisStore.Add(ctx, newInfo))

	oldInfo.SetExpired()

	require.Eventually(t, func() bool {
		got, err := cache.Get(sandboxID)
		return err == nil && got.ExecutionID == newInfo.ExecutionID
	}, time.Second, 10*time.Millisecond)

	select {
	case got := <-deleted:
		t.Fatalf("stale local eviction called delete hook for execution %s", got)
	default:
	}
}
