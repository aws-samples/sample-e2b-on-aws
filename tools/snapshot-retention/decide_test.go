package main

import (
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestDecidePurge(t *testing.T) {
	build := uuid.New()
	live := uuid.New()
	snapshotEnv := "snap-env"
	templateEnv := "tpl-env"
	team := uuid.New().String()

	cand := purgeCandidate{
		buildID:   build,
		createdAt: time.Now().Add(-100 * 24 * time.Hour),
		envIDs:    []string{snapshotEnv, templateEnv},
		teamIDs:   []string{team},
	}
	stamped := func(origin, templateID, teamID string) objectFacts {
		return objectFacts{objectCount: 6, origin: origin, templateID: templateID, teamID: teamID}
	}

	cases := []struct {
		name         string
		protected    map[uuid.UUID][]uuid.UUID
		facts        objectFacts
		allowMissing bool
		wantAction   action
		wantReason   string
		wantDBOnly   bool
		wantFailure  bool
	}{
		{
			name:       "referenced by a live build is kept",
			protected:  map[uuid.UUID][]uuid.UUID{build: {live}},
			facts:      stamped("pause", snapshotEnv, team),
			wantAction: actionKeep, wantReason: "KEEP_REFERENCED_BY " + live.String(),
		},
		{
			name:       "empty prefix only removes the row",
			facts:      objectFacts{objectCount: 0, missing: true},
			wantAction: actionPurge, wantReason: "PURGE_DB_ONLY", wantDBOnly: true,
		},
		{
			name:       "no metadata is skipped by default",
			facts:      objectFacts{objectCount: 6, missing: true},
			wantAction: actionSkip, wantReason: "SKIP_MISSING_METADATA",
		},
		{
			name:       "empty build_origin counts as no metadata",
			facts:      stamped("", "", ""),
			wantAction: actionSkip, wantReason: "SKIP_MISSING_METADATA",
		},
		{
			name:         "no metadata is purged when allowed",
			facts:        objectFacts{objectCount: 6, missing: true},
			allowMissing: true,
			wantAction:   actionPurge, wantReason: "PURGE",
		},
		{
			name:       "template build objects are never touched",
			facts:      stamped("template_build", snapshotEnv, team),
			wantAction: actionSkip, wantReason: "SKIP_ORIGIN_TEMPLATE", wantFailure: true,
		},
		{
			name:       "template layer cache objects are never touched",
			facts:      stamped("template_build_cache", snapshotEnv, team),
			wantAction: actionSkip, wantReason: "SKIP_ORIGIN_TEMPLATE", wantFailure: true,
		},
		{
			name:       "unknown origin is treated like a template",
			facts:      stamped("something_new", snapshotEnv, team),
			wantAction: actionSkip, wantReason: "SKIP_ORIGIN_TEMPLATE", wantFailure: true,
		},
		{
			name:       "pause snapshot is purged",
			facts:      stamped("pause", snapshotEnv, team),
			wantAction: actionPurge, wantReason: "PURGE",
		},
		{
			name:       "checkpoint stamped as snapshot_template is purged",
			facts:      stamped("snapshot_template", templateEnv, team),
			wantAction: actionPurge, wantReason: "PURGE",
		},
		{
			name:       "template_id pointing at a foreign env is an inconsistency",
			facts:      stamped("pause", "someone-else", team),
			wantAction: actionSkip, wantReason: "SKIP_METADATA_MISMATCH", wantFailure: true,
		},
		{
			name:       "team_id of another team is an inconsistency",
			facts:      stamped("pause", snapshotEnv, uuid.New().String()),
			wantAction: actionSkip, wantReason: "SKIP_METADATA_MISMATCH", wantFailure: true,
		},
		{
			name:       "origin alone is enough when the other keys are absent",
			facts:      stamped("pause", "", ""),
			wantAction: actionPurge, wantReason: "PURGE",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			d := decidePurge(cand, tc.protected, tc.facts, tc.allowMissing)

			if d.action != tc.wantAction {
				t.Errorf("action = %s, want %s (%s)", d.action, tc.wantAction, d.reason)
			}
			if !strings.HasPrefix(d.reason, tc.wantReason) {
				t.Errorf("reason = %q, want prefix %q", d.reason, tc.wantReason)
			}
			if d.dbOnly != tc.wantDBOnly {
				t.Errorf("dbOnly = %v, want %v", d.dbOnly, tc.wantDBOnly)
			}
			if d.failure != tc.wantFailure {
				t.Errorf("failure = %v, want %v", d.failure, tc.wantFailure)
			}
		})
	}
}

func TestParseConfig(t *testing.T) {
	env := map[string]string{
		"POSTGRES_CONNECTION_STRING": "postgresql://u:p@h/db",
		"TEMPLATE_BUCKET_NAME":       "bucket",
		"AWS_REGION":                 "us-east-1",
		"RETENTION_APPLY":            "true",
		"RETENTION_DAYS":             "30",
		"PURGE_DELAY_DAYS":           "3",
	}
	getenv := func(k string) string { return env[k] }

	cfg, err := parseConfig(nil, getenv)
	if err != nil {
		t.Fatalf("parseConfig: %v", err)
	}
	if !cfg.apply || cfg.retention != 30*24*time.Hour || cfg.purgeDelay != 3*24*time.Hour {
		t.Fatalf("env defaults not applied: %+v", cfg)
	}

	cfg, err = parseConfig([]string{"-apply=false", "-retention-days=90"}, getenv)
	if err != nil {
		t.Fatalf("parseConfig with flags: %v", err)
	}
	if cfg.apply || cfg.retention != 90*24*time.Hour || cfg.purgeDelay != 3*24*time.Hour {
		t.Fatalf("flags must override env: %+v", cfg)
	}

	if _, err := parseConfig([]string{"-retention-days=0"}, getenv); err == nil {
		t.Fatal("a zero retention would expire every paused sandbox and must be rejected")
	}

	env["RETENTION_ALLOW_MISSING_ORIGIN"] = "true"
	cfg, err = parseConfig(nil, getenv)
	if err != nil {
		t.Fatalf("parseConfig: %v", err)
	}
	if !cfg.allowMissingOrigin {
		t.Fatal("RETENTION_ALLOW_MISSING_ORIGIN=true must enable -allow-missing-origin")
	}

	env["RETENTION_DAYS"] = "30d"
	if _, err := parseConfig(nil, getenv); err == nil {
		t.Fatal("a malformed RETENTION_DAYS must be rejected, not defaulted")
	}
	env["RETENTION_DAYS"] = "30"

	delete(env, "TEMPLATE_BUCKET_NAME")
	if _, err := parseConfig(nil, getenv); err == nil {
		t.Fatal("missing bucket must be rejected")
	}
}
