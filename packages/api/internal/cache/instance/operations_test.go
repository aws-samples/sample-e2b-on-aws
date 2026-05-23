package instance

import (
	"context"
	"testing"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	"go.opentelemetry.io/otel/metric/noop"
)

func TestAddWaitsForInsertHook(t *testing.T) {
	ctx := context.Background()
	insertStarted := make(chan struct{})
	releaseInsert := make(chan struct{})

	cache := NewCache(ctx, noop.MeterProvider{}, func(data *InstanceInfo, created bool) error {
		require.True(t, created)
		close(insertStarted)
		<-releaseInsert
		return nil
	}, nil)

	done := make(chan error, 1)
	go func() {
		done <- cache.Add(ctx, newTestInstanceInfo("test-add-sync", uuid.New()), true)
	}()

	select {
	case <-insertStarted:
	case err := <-done:
		require.Failf(t, "Add returned before insert hook started", "err=%v", err)
	}

	select {
	case err := <-done:
		require.Failf(t, "Add returned before insert hook completed", "err=%v", err)
	default:
	}

	close(releaseInsert)
	require.NoError(t, <-done)
}
