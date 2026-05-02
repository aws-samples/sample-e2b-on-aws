package handlers

import "testing"

func TestRedactAuthorizationHeader(t *testing.T) {
	tests := []struct {
		name   string
		header string
		want   string
	}{
		{
			name:   "bearer token",
			header: "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9",
			want:   "Bearer ***",
		},
		{
			name:   "basic token",
			header: "Basic X2UyYl9hY2Nlc3NfdG9rZW46c2tfZTJiX3NlY3JldA==",
			want:   "Basic ***",
		},
		{
			name:   "unknown scheme",
			header: "sk_e2b_secret",
			want:   "***",
		},
		{
			name:   "empty",
			header: "",
			want:   "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := redactAuthorizationHeader(tt.header)
			if got != tt.want {
				t.Fatalf("redactAuthorizationHeader(%q) = %q, want %q", tt.header, got, tt.want)
			}
		})
	}
}

func TestRedactSecret(t *testing.T) {
	secret := "sk_e2b_this_should_not_appear_in_logs"
	if got := redactSecret(secret); got != "***" {
		t.Fatalf("redactSecret(%q) = %q, want redacted marker", secret, got)
	}
}
