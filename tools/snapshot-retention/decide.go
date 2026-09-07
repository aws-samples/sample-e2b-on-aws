package main

import (
	"fmt"
	"slices"
	"strings"

	"github.com/google/uuid"

	"github.com/e2b-dev/infra/packages/shared/pkg/storage/storageopts"
)

type action string

const (
	actionPurge action = "PURGE"
	actionKeep  action = "KEEP"
	actionSkip  action = "SKIP"
)

type decision struct {
	action action
	// reason is the log line: a stable code followed by detail.
	reason string
	// dbOnly is set when the prefix holds no objects and only the row is left.
	dbOnly bool
	// failure marks a skip that points at an inconsistency between the
	// database and the bucket and should fail the run.
	failure bool
}

// objectFacts is what the bucket says about a build: the metadata stamped on
// its objects at upload time and how many objects sit under its prefix.
type objectFacts struct {
	missing     bool // no rootfs header and no metadata.json
	objectCount int
	origin      string
	templateID  string
	teamID      string
}

// decidePurge is the last word on a build the database already found
// eligible: every env it is assigned to is soft-deleted for longer than the
// purge delay, none of them is a template, none was paused within the
// retention period. It only ever narrows that down.
func decidePurge(c purgeCandidate, protected map[uuid.UUID][]uuid.UUID, facts objectFacts, allowMissingOrigin bool) decision {
	if referrers, ok := protected[c.buildID]; ok {
		return decision{action: actionKeep, reason: "KEEP_REFERENCED_BY " + joinIDs(referrers, 3)}
	}

	if facts.objectCount == 0 {
		// A previous round deleted the objects and lost the race to the row,
		// or the upload never happened. Either way only the row is left.
		return decision{action: actionPurge, dbOnly: true, reason: "PURGE_DB_ONLY: no objects under the prefix"}
	}

	if facts.missing || facts.origin == "" {
		if !allowMissingOrigin {
			return decision{action: actionSkip, reason: "SKIP_MISSING_METADATA: objects carry no build_origin; pass -allow-missing-origin to purge on database evidence alone"}
		}

		return decision{action: actionPurge, reason: "PURGE: metadata absent, allowed by -allow-missing-origin"}
	}

	switch storageopts.ObjectOrigin(facts.origin) {
	case storageopts.ObjectOriginPause, storageopts.ObjectOriginSnapshotTemplate:
		// pause: a paused sandbox. snapshot_template: a checkpoint (fork) or a
		// snapshot template build; both live in the sandbox's snapshot env.
	default:
		return decision{action: actionSkip, failure: true, reason: fmt.Sprintf("SKIP_ORIGIN_TEMPLATE: objects are stamped build_origin=%q under a snapshot-only build", facts.origin)}
	}

	if facts.templateID != "" && !slices.Contains(c.envIDs, facts.templateID) {
		return decision{action: actionSkip, failure: true, reason: fmt.Sprintf("SKIP_METADATA_MISMATCH: object template_id=%s is not one of the build's envs", facts.templateID)}
	}
	if facts.teamID != "" && !slices.Contains(c.teamIDs, facts.teamID) {
		return decision{action: actionSkip, failure: true, reason: fmt.Sprintf("SKIP_METADATA_MISMATCH: object team_id=%s is not the env's team", facts.teamID)}
	}

	return decision{action: actionPurge, reason: "PURGE"}
}

func joinIDs(ids []uuid.UUID, limit int) string {
	parts := make([]string, 0, min(len(ids), limit))
	for _, id := range ids[:min(len(ids), limit)] {
		parts = append(parts, id.String())
	}
	if len(ids) > limit {
		parts = append(parts, fmt.Sprintf("(+%d more)", len(ids)-limit))
	}

	return strings.Join(parts, ",")
}
