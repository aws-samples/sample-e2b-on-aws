package handlers

import "strings"

func redactSecret(secret string) string {
	if secret == "" {
		return ""
	}

	return "***"
}

func redactAuthorizationHeader(header string) string {
	header = strings.TrimSpace(header)
	if header == "" {
		return ""
	}

	parts := strings.Fields(header)
	if len(parts) == 0 {
		return "***"
	}

	scheme := parts[0]
	if strings.EqualFold(scheme, "Basic") || strings.EqualFold(scheme, "Bearer") {
		return scheme + " ***"
	}

	return "***"
}
