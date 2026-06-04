package sandbox

import (
	"context"
	"strings"
	"testing"
)

func TestCleanupRunContinuesAfterPriorityPanic(t *testing.T) {
	cleanup := NewCleanup()

	var calls []string
	cleanup.Add(func(context.Context) error {
		calls = append(calls, "regular")
		return nil
	})
	cleanup.AddPriority(func(context.Context) error {
		calls = append(calls, "priority-panic")
		panic("boom")
	})

	err := cleanup.Run(context.Background())
	if err == nil {
		t.Fatal("expected cleanup panic to be returned as an error")
	}
	if !strings.Contains(err.Error(), "cleanup function panicked: boom") {
		t.Fatalf("expected panic error, got %v", err)
	}

	want := []string{"priority-panic", "regular"}
	if len(calls) != len(want) {
		t.Fatalf("expected calls %v, got %v", want, calls)
	}
	for i := range want {
		if calls[i] != want[i] {
			t.Fatalf("expected calls %v, got %v", want, calls)
		}
	}
}
