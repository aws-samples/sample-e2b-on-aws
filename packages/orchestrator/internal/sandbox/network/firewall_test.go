package network

import "testing"

func TestLogsCollectorAllowedCIDR(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		want    string
		wantErr bool
	}{
		{
			name:  "http URL with port",
			input: "http://10.50.121.182:30006",
			want:  "10.50.121.182/32",
		},
		{
			name:  "http URL without port",
			input: "http://127.0.0.1",
			want:  "127.0.0.1/32",
		},
		{
			name:  "bare host port",
			input: "10.50.121.182:30006",
			want:  "10.50.121.182/32",
		},
		{
			name: "empty",
		},
		{
			name:    "non IP host",
			input:   "http://logs-collector:30006",
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := logsCollectorAllowedCIDR(tt.input)
			if tt.wantErr {
				if err == nil {
					t.Fatalf("expected error, got nil")
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tt.want {
				t.Fatalf("got %q, want %q", got, tt.want)
			}
		})
	}
}
