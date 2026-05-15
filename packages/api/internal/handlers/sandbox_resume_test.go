package handlers

import "testing"

func TestResolveResumeClientID(t *testing.T) {
	tests := []struct {
		name                 string
		requestedClientID    string
		pausedNodeID         *string
		snapshotOriginNodeID *string
		want                 *string
	}{
		{
			name:                 "uses paused node first",
			requestedClientID:    "requested-node",
			pausedNodeID:         stringPtr("paused-node"),
			snapshotOriginNodeID: stringPtr("snapshot-node"),
			want:                 stringPtr("paused-node"),
		},
		{
			name:                 "uses snapshot origin before requested suffix",
			requestedClientID:    "requested-node",
			snapshotOriginNodeID: stringPtr("snapshot-node"),
			want:                 stringPtr("snapshot-node"),
		},
		{
			name:              "falls back to requested suffix",
			requestedClientID: "requested-node",
			want:              stringPtr("requested-node"),
		},
		{
			name: "returns nil when there is no preferred node",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := resolveResumeClientID(tt.requestedClientID, tt.pausedNodeID, tt.snapshotOriginNodeID)
			if !stringPtrEqual(got, tt.want) {
				t.Fatalf("resolveResumeClientID() = %v, want %v", got, tt.want)
			}
		})
	}
}

func stringPtr(value string) *string {
	return &value
}

func stringPtrEqual(a, b *string) bool {
	if a == nil || b == nil {
		return a == b
	}

	return *a == *b
}
