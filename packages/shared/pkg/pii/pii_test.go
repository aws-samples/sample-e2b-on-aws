package pii

import "testing"

func TestTag(t *testing.T) {
	t.Parallel()

	got := Tag("user-123")
	want := "{E}user-123{/E}"
	if got != want {
		t.Fatalf("Tag() = %q, want %q", got, want)
	}
}

func TestTagEmpty(t *testing.T) {
	t.Parallel()

	if got := Tag(""); got != "" {
		t.Fatalf("Tag(\"\") = %q, want empty string", got)
	}
}
