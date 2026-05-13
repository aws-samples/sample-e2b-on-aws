package network

import "testing"

func TestLogsCollectorFirewallCIDR(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		want    string
		wantErr bool
	}{
		{
			name:  "pure IPv4",
			input: "10.50.121.182",
			want:  "10.50.121.182/32",
		},
		{
			name:  "trims whitespace",
			input: " 10.50.121.182 ",
			want:  "10.50.121.182/32",
		},
		{
			name: "empty",
		},
		{
			name:    "public URL is not accepted by firewall variable",
			input:   "http://10.50.121.182:30006",
			wantErr: true,
		},
		{
			name:    "host port is not accepted by firewall variable",
			input:   "10.50.121.182:30006",
			wantErr: true,
		},
		{
			name:    "non IP host",
			input:   "logs-collector",
			wantErr: true,
		},
		{
			name:    "IPv6 is not accepted",
			input:   "2001:db8::1",
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := logsCollectorFirewallCIDR(tt.input)
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
