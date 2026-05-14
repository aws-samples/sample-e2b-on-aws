package handlers

import (
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/e2b-dev/infra/packages/api/internal/api"
	"github.com/e2b-dev/infra/packages/api/internal/cache/instance"
	"github.com/e2b-dev/infra/packages/db/queries"
)

func TestInstanceInfoToPaginatedSandboxesIncludesDiskSize(t *testing.T) {
	startedAt := time.Date(2026, 5, 14, 10, 0, 0, 0, time.UTC)
	endAt := startedAt.Add(time.Hour)
	teamID := uuid.New()
	buildID := uuid.New()

	sandbox := instance.NewInstanceInfo(
		&api.Sandbox{
			SandboxID:  "sandbox-running",
			TemplateID: "template-running",
			ClientID:   "client-1",
		},
		"execution-1",
		&teamID,
		&buildID,
		nil,
		time.Hour,
		startedAt,
		endAt,
		2,
		4096,
		1024,
		"kernel",
		"firecracker",
		"envd",
		nil,
		false,
		nil,
		"base-template",
	)

	got := instanceInfoToPaginatedSandboxes([]*instance.InstanceInfo{sandbox})

	if got[0].DiskSizeMB != 4096 {
		t.Fatalf("DiskSizeMB = %d, want 4096", got[0].DiskSizeMB)
	}
}

func TestSnapshotsToPaginatedSandboxesIncludesDiskSize(t *testing.T) {
	startedAt := time.Date(2026, 5, 14, 10, 0, 0, 0, time.UTC)
	createdAt := startedAt.Add(30 * time.Minute)
	totalDiskSizeMB := int64(8192)

	got := snapshotsToPaginatedSandboxes([]queries.GetSnapshotsWithCursorRow{
		{
			Snapshot: queries.Snapshot{
				CreatedAt:        pgtype.Timestamptz{Time: createdAt, Valid: true},
				EnvID:            "template-paused-total",
				SandboxID:        "sandbox-paused-total",
				BaseEnvID:        "base-template-total",
				SandboxStartedAt: pgtype.Timestamptz{Time: startedAt, Valid: true},
			},
			EnvBuild: queries.EnvBuild{
				Vcpu:            2,
				RamMb:           1024,
				FreeDiskSizeMb:  2048,
				TotalDiskSizeMb: &totalDiskSizeMB,
			},
		},
		{
			Snapshot: queries.Snapshot{
				CreatedAt:        pgtype.Timestamptz{Time: createdAt, Valid: true},
				EnvID:            "template-paused-free",
				SandboxID:        "sandbox-paused-free",
				BaseEnvID:        "base-template-free",
				SandboxStartedAt: pgtype.Timestamptz{Time: startedAt, Valid: true},
			},
			EnvBuild: queries.EnvBuild{
				Vcpu:           2,
				RamMb:          1024,
				FreeDiskSizeMb: 2048,
			},
		},
	})

	if got[0].DiskSizeMB != 8192 {
		t.Fatalf("total-backed DiskSizeMB = %d, want 8192", got[0].DiskSizeMB)
	}
	if got[1].DiskSizeMB != 2048 {
		t.Fatalf("free fallback DiskSizeMB = %d, want 2048", got[1].DiskSizeMB)
	}
}

func TestSnapshotToSandboxDetailUsesSnapshotCreatedAtForEndAt(t *testing.T) {
	startedAt := time.Date(2026, 5, 14, 10, 0, 0, 0, time.UTC)
	createdAt := startedAt.Add(30 * time.Minute)
	totalDiskSizeMB := int64(8192)

	got := snapshotToSandboxDetail(queries.GetLastSnapshotRow{
		Snapshot: queries.Snapshot{
			CreatedAt:        pgtype.Timestamptz{Time: createdAt, Valid: true},
			EnvID:            "template-paused",
			SandboxID:        "sandbox-paused",
			SandboxStartedAt: pgtype.Timestamptz{Time: startedAt, Valid: true},
		},
		EnvBuild: queries.EnvBuild{
			Vcpu:            2,
			RamMb:           1024,
			FreeDiskSizeMb:  2048,
			TotalDiskSizeMb: &totalDiskSizeMB,
		},
	}, nil)

	if !got.EndAt.Equal(createdAt) {
		t.Fatalf("EndAt = %s, want snapshot createdAt %s", got.EndAt, createdAt)
	}
	if got.DiskSizeMB != 8192 {
		t.Fatalf("DiskSizeMB = %d, want 8192", got.DiskSizeMB)
	}
}
