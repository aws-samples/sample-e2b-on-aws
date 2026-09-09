package main

import (
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestDecidePurge(t *testing.T) {
	snapshotEnv := "snap-env"
	templateEnv := "tpl-env"
	team := uuid.New().String()

	cand := purgeCandidate{
		buildID:   uuid.New(),
		createdAt: time.Now().Add(-100 * 24 * time.Hour),
		envIDs:    []string{snapshotEnv, templateEnv},
		teamIDs:   []string{team},
	}
	stamped := func(origin, templateID, teamID string) objectFacts {
		return objectFacts{objectCount: 6, origin: origin, templateID: templateID, teamID: teamID}
	}

	cases := []struct {
		name         string
		facts        objectFacts
		allowMissing bool
		wantAction   action
		wantReason   string
	}{
		{"empty prefix only removes the row", objectFacts{}, false, actionPurge, "PURGE_DB_ONLY"},
		{"no metadata is skipped by default", objectFacts{objectCount: 6}, false, actionSkip, "SKIP_MISSING_METADATA"},
		{"no metadata is purged when allowed", objectFacts{objectCount: 6}, true, actionPurge, "PURGE"},
		{"template build objects are never touched", stamped("template_build", snapshotEnv, team), false, actionFail, "FAIL_ORIGIN_TEMPLATE"},
		{"template layer cache objects are never touched", stamped("template_build_cache", snapshotEnv, team), false, actionFail, "FAIL_ORIGIN_TEMPLATE"},
		{"unknown origin is treated like a template", stamped("something_new", snapshotEnv, team), false, actionFail, "FAIL_ORIGIN_TEMPLATE"},
		{"pause snapshot is purged", stamped("pause", snapshotEnv, team), false, actionPurge, "PURGE"},
		{"checkpoint stamped as snapshot_template is purged", stamped("snapshot_template", templateEnv, team), false, actionPurge, "PURGE"},
		{"template_id pointing at a foreign env is an inconsistency", stamped("pause", "someone-else", team), false, actionFail, "FAIL_METADATA_MISMATCH"},
		{"team_id of another team is an inconsistency", stamped("pause", snapshotEnv, uuid.New().String()), false, actionFail, "FAIL_METADATA_MISMATCH"},
		{"origin alone is enough when the other keys are absent", stamped("pause", "", ""), false, actionPurge, "PURGE"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			d := decidePurge(cand, tc.facts, tc.allowMissing)

			if d.action != tc.wantAction {
				t.Errorf("action = %s, want %s (%s)", d.action, tc.wantAction, d.reason)
			}
			if !strings.HasPrefix(d.reason, tc.wantReason) {
				t.Errorf("reason = %q, want prefix %q", d.reason, tc.wantReason)
			}
		})
	}
}

func TestParseConfig(t *testing.T) {
	base := map[string]string{
		"POSTGRES_CONNECTION_STRING": "postgresql://u:p@h/db",
		"TEMPLATE_BUCKET_NAME":       "bucket",
		"AWS_REGION":                 "us-east-1",
		"RETENTION_APPLY":            "true",
		"RETENTION_DAYS":             "30",
		"PURGE_DELAY_DAYS":           "3",
	}

	cases := []struct {
		name    string
		env     map[string]string // overrides base; "" removes the key
		args    []string
		wantErr bool
		check   func(config) bool
	}{
		{
			name: "environment supplies the defaults",
			check: func(c config) bool {
				return c.apply && c.retention == 30*24*time.Hour && c.purgeDelay == 3*24*time.Hour
			},
		},
		{
			name: "flags override the environment",
			args: []string{"-apply=false", "-retention-days=90"},
			check: func(c config) bool {
				return !c.apply && c.retention == 90*24*time.Hour && c.purgeDelay == 3*24*time.Hour
			},
		},
		{
			name:  "RETENTION_ALLOW_MISSING_ORIGIN enables the flag",
			env:   map[string]string{"RETENTION_ALLOW_MISSING_ORIGIN": "true"},
			check: func(c config) bool { return c.allowMissingOrigin },
		},
		{
			name:    "a zero retention would expire every paused sandbox",
			args:    []string{"-retention-days=0"},
			wantErr: true,
		},
		{
			name:    "a malformed RETENTION_DAYS is rejected, not defaulted",
			env:     map[string]string{"RETENTION_DAYS": "30d"},
			wantErr: true,
		},
		{
			name:    "the bucket is required",
			env:     map[string]string{"TEMPLATE_BUCKET_NAME": ""},
			wantErr: true,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			env := make(map[string]string, len(base)+len(tc.env))
			for k, v := range base {
				env[k] = v
			}
			for k, v := range tc.env {
				env[k] = v
			}

			cfg, err := parseConfig(tc.args, func(k string) string { return env[k] })
			if tc.wantErr {
				if err == nil {
					t.Fatal("expected an error")
				}

				return
			}
			if err != nil {
				t.Fatalf("parseConfig: %v", err)
			}
			if !tc.check(cfg) {
				t.Fatalf("unexpected config: %+v", cfg)
			}
		})
	}
}
