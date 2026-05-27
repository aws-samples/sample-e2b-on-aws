package orchestrator

import (
	"context"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"go.opentelemetry.io/otel/metric/noop"

	"github.com/e2b-dev/infra/packages/api/internal/api"
	"github.com/e2b-dev/infra/packages/api/internal/cache/instance"
	"github.com/e2b-dev/infra/packages/api/internal/dns"
	"github.com/e2b-dev/infra/packages/shared/pkg/smap"
)

func TestInsertInstanceDoesNotMarkAutoPauseAsPausing(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	cache := instance.NewCache(ctx, noop.MeterProvider{}, nil, nil)
	o := &Orchestrator{
		instanceCache: cache,
		nodes:         smap.New[*Node](),
		dns:           dns.New(ctx, nil),
	}

	teamID := uuid.New()
	buildID := uuid.New()
	info := instance.NewInstanceInfo(
		&api.Sandbox{
			SandboxID:  "sandbox-id",
			ClientID:   "missing-node",
			TemplateID: "template-id",
		},
		uuid.NewString(),
		&teamID,
		&buildID,
		nil,
		time.Hour,
		time.Now(),
		time.Now().Add(time.Minute),
		2,
		1024,
		512,
		"kernel",
		"firecracker",
		"envd",
		nil,
		true,
		nil,
		"template-id",
	)

	insert := o.getInsertInstanceFunction(ctx, time.Second)
	require.NoError(t, insert(info, false))

	_, err := cache.WaitForPause(ctx, info.Instance.SandboxID)
	require.ErrorIs(t, err, instance.ErrPausingInstanceNotFound)
}
