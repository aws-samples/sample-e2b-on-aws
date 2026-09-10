package main

import (
	"fmt"
	"slices"

	"github.com/e2b-dev/infra/packages/shared/pkg/storage/storageopts"
)

type action string

const (
	actionPurge action = "PURGE" // delete the objects, if any, and the build row
	actionSkip  action = "SKIP"  // policy says leave it; not an error
	actionFail  action = "FAIL"  // the bucket disagrees with the database; leave it and fail the run
)

type decision struct {
	action action
	// reason is the log line: a stable code followed by detail.
	reason string
}

// reasonRecheckFailed is logged when the eligibility rule no longer holds
// under the row lock: the env changed between selection and deletion.
const reasonRecheckFailed = "KEEP_CHANGED_SINCE_SELECTION"

// objectFacts is what the bucket says about a build: how many objects sit
// under its prefix and the metadata stamped on them at upload time (empty
// when the objects predate upstream stamping it).
type objectFacts struct {
	objectCount int
	origin      string
	templateID  string
	teamID      string
}

// decidePurge is the last word on a build the database already found
// eligible (every env it is assigned to is soft-deleted for longer than the
// purge delay, none of them is a template, none was paused within the
// retention period) and that no root build references. It only ever narrows
// that down.
func decidePurge(c purgeCandidate, facts objectFacts, allowMissingOrigin bool) decision {
	// With no objects there is nothing the metadata could vouch for; only the
	// row is left, from a previous round that deleted the objects and lost the
	// race to the row, or from an upload that never happened.
	if facts.objectCount == 0 {
		return decision{action: actionPurge, reason: "PURGE_DB_ONLY: no objects under the prefix"}
	}

	if facts.origin == "" {
		if !allowMissingOrigin {
			return decision{action: actionSkip, reason: "SKIP_MISSING_METADATA: objects carry no build_origin; set RETENTION_ALLOW_MISSING_ORIGIN=true to purge on database evidence alone"}
		}

		return decision{action: actionPurge, reason: "PURGE: metadata absent, allowed by RETENTION_ALLOW_MISSING_ORIGIN"}
	}

	switch storageopts.ObjectOrigin(facts.origin) {
	case storageopts.ObjectOriginPause, storageopts.ObjectOriginSnapshotTemplate:
		// pause: a paused sandbox. snapshot_template: a checkpoint (fork) or a
		// snapshot template build; both live in the sandbox's snapshot env.
	default:
		return decision{action: actionFail, reason: fmt.Sprintf("FAIL_ORIGIN_TEMPLATE: objects are stamped build_origin=%q under a snapshot-only build", facts.origin)}
	}

	if facts.templateID != "" && !slices.Contains(c.envIDs, facts.templateID) {
		return decision{action: actionFail, reason: fmt.Sprintf("FAIL_METADATA_MISMATCH: object template_id=%s is not one of the build's envs", facts.templateID)}
	}
	if facts.teamID != "" && !slices.Contains(c.teamIDs, facts.teamID) {
		return decision{action: actionFail, reason: fmt.Sprintf("FAIL_METADATA_MISMATCH: object team_id=%s is not the env's team", facts.teamID)}
	}

	return decision{action: actionPurge, reason: "PURGE"}
}
