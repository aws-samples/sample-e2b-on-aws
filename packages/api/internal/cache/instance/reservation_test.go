package instance

import (
	"context"
	"testing"
	"time"

	"github.com/google/uuid"
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

func TestRedisRecordRoundTrip(t *testing.T) {
	buildID := uuid.New()
	start := time.Now().UTC().Truncate(time.Second)
	end := start.Add(time.Minute)
	alias := "base"
	token := "envd-token"

	info := NewInstanceInfo(
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

	got := recordFromInstance(info).toInstanceInfo()

	require.Equal(t, sandboxID, got.Instance.SandboxID)
	require.Equal(t, teamID, *got.TeamID)
	require.Equal(t, buildID, *got.BuildID)
	require.Equal(t, "node-a", got.Node.ID)
	require.Equal(t, end, got.GetEndTime())
	require.Equal(t, true, got.AutoPause.Load())
	require.Equal(t, "base-template", got.BaseTemplateID)
	require.Equal(t, "v", got.Metadata["k"])
}
