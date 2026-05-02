package auth

import (
	"encoding/base64"
	"strings"
	"testing"
)

func TestExtractAccessTokenErrorsDoNotExposeCredentials(t *testing.T) {
	plain := "_e2b_access_token:sk_e2b_secret:extra"
	encoded := base64.StdEncoding.EncodeToString([]byte(plain))

	_, err := ExtractAccessToken("Basic "+encoded, "Basic ")
	if err == nil {
		t.Fatal("expected malformed credentials error")
	}

	if strings.Contains(err.Error(), plain) || strings.Contains(err.Error(), encoded) || strings.Contains(err.Error(), "sk_e2b_secret") {
		t.Fatalf("error exposed credentials: %q", err.Error())
	}
}
