package build

import (
	"strings"

	"github.com/e2b-dev/infra/packages/orchestrator/internal/sandbox/lifecycle"
	"github.com/e2b-dev/infra/packages/shared/pkg/storage"
)

type fetchStatsProvider interface {
	FetchStats() lifecycle.StorageStats
}

func storageSourceKind(provider storage.StorageProvider) string {
	details := provider.GetDetails()
	switch {
	case strings.Contains(details, "AWS Storage"):
		return "aws_s3"
	case strings.Contains(details, "GCP Storage"):
		return "gcs"
	case strings.Contains(details, "Local file storage"):
		return "local"
	default:
		return "unknown"
	}
}
