package cache

import (
	"strings"
	"testing"
)

func TestGetMissDoesNotExposeToken(t *testing.T) {
	c := New()
	secret := "e2b_token_that_must_not_be_logged"

	_, err := c.Get(secret)
	if err == nil {
		t.Fatal("expected cache miss error")
	}

	if strings.Contains(err.Error(), secret) {
		t.Fatalf("cache miss error exposed token: %q", err.Error())
	}
}
