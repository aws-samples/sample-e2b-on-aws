package logger

import (
	"github.com/google/uuid"
	"go.uber.org/zap"

	"github.com/e2b-dev/infra/packages/shared/pkg/pii"
)

func WithSandboxID(sandboxID string) zap.Field {
	return zap.String("sandbox.id", sandboxID)
}

func WithTemplateID(templateID string) zap.Field {
	return zap.String("template.id", templateID)
}

func WithBuildID(buildID string) zap.Field {
	return zap.String("build.id", buildID)
}

func WithTeamID(teamID string) zap.Field {
	return zap.String("team.id", pii.Tag(teamID))
}

func WithClusterID(clusterId uuid.UUID) zap.Field {
	return zap.String("cluster.id", clusterId.String())
}

func WithClusterNodeID(nodeId string) zap.Field {
	return zap.String("cluster.node.id", nodeId)
}
