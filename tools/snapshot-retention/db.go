package main

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/e2b-dev/infra/packages/db/pkg/dberrors"
	"github.com/e2b-dev/infra/packages/db/queries"
)

// database wraps the handful of statements this tool runs. It reads envs,
// snapshots, env_builds, env_build_assignments, team_limits and _migrations;
// the one state transition it shares with the API - the soft delete - it
// performs by calling upstream's generated queries rather than copying their
// SQL, so an upstream change there surfaces as a compile error at the next
// sync.
type database struct {
	pool *pgxpool.Pool
}

// querier is what the statements below need from a pool or a transaction.
type querier interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

var errRecheckFailed = errors.New("env state changed since the build was selected")

// The two predicates the whole policy rests on, each written once. Both
// expect the aliases eb (env_builds), eba (env_build_assignments) and e (envs).
const (
	// newestPause is when a build was last made resumable for an env: the
	// later of the build row and the assignment row, so a build re-assigned
	// later (a snapshot template reuses a pause build) never looks older than
	// it is. Its MAX over an env is what the API reports as the pause time
	// (packages/api/internal/handlers/sandbox_get.go).
	newestPause = "GREATEST(eb.created_at, eba.created_at)"

	// restorableEnv holds for an env that can still be brought back: live, or
	// soft-deleted less than the purge delay ago. $1 must be that delay.
	restorableEnv = "(e.deleted_at IS NULL OR e.deleted_at >= now() - $1::interval)"
)

// interval renders a duration as a Postgres interval literal for `$n::interval`.
func interval(d time.Duration) string {
	return fmt.Sprintf("%d seconds", int64(d.Seconds()))
}

// maxSandboxLengthHours is the longest a sandbox may run anywhere in the
// deployment. team_limits is the view the API reads limits through; it folds
// per-team project_limits overrides over the tier defaults.
func (d *database) maxSandboxLengthHours(ctx context.Context) (int64, error) {
	var hours int64
	err := d.pool.QueryRow(ctx, `SELECT COALESCE(MAX(max_length_hours), 0) FROM public.team_limits`).Scan(&hours)

	return hours, err
}

type markCandidate struct {
	envID     string
	teamID    uuid.UUID
	sandboxID string
	newestAt  time.Time
	builds    int64
}

// markCandidates lists pause-snapshot envs whose newest pause is older than
// the retention period. active_envs is upstream's canonical "not soft-deleted"
// projection; the snapshots join both confirms the env is a paused sandbox and
// yields the sandbox id operators recognise.
func (d *database) markCandidates(ctx context.Context, retention time.Duration) ([]markCandidate, error) {
	rows, err := d.pool.Query(ctx, `
		SELECT e.id, e.team_id, s.sandbox_id, n.newest_at, n.n
		FROM public.active_envs e
		JOIN public.snapshots s ON s.env_id = e.id
		JOIN LATERAL (
			SELECT MAX(`+newestPause+`) AS newest_at, COUNT(*) AS n
			FROM public.env_build_assignments eba
			JOIN public.env_builds eb ON eb.id = eba.build_id
			WHERE eba.env_id = e.id
		) n ON n.newest_at IS NOT NULL
		WHERE e.source = 'snapshot'
		  AND e.cluster_id IS NULL
		  AND n.newest_at < now() - $1::interval
		ORDER BY n.newest_at`, interval(retention))
	if err != nil {
		return nil, err
	}

	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (markCandidate, error) {
		var c markCandidate
		err := row.Scan(&c.envID, &c.teamID, &c.sandboxID, &c.newestAt, &c.builds)

		return c, err
	})
}

// markEnv soft-deletes a snapshot env exactly the way DELETE /sandboxes/{id}
// does: the three generated queries the API's softDeleteTemplate runs
// (packages/api/internal/handlers/template_delete.go), in one transaction.
// What cannot be mirrored from outside the API is its cache invalidation; the
// snapshot cache expires on its own within five minutes.
//
// Upstream's UPDATE takes the env row lock; the retention check is repeated
// behind it and rolls the soft delete back if the sandbox was paused again
// between selection and here. Returns false when nothing was changed.
func (d *database) markEnv(ctx context.Context, c markCandidate, retention time.Duration) (bool, error) {
	tx, err := d.pool.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback(context.WithoutCancel(ctx)) //nolint:errcheck // no-op after Commit

	q := queries.New(tx)
	if _, err := q.SoftDeleteTemplate(ctx, queries.SoftDeleteTemplateParams{TemplateID: c.envID, TeamID: c.teamID}); err != nil {
		if dberrors.IsNotFoundError(err) {
			// Already deleted, or the team no longer owns it: same outcome as
			// the API, which treats this as nothing to do.
			return false, nil
		}

		return false, fmt.Errorf("soft delete: %w", err)
	}

	var pausedRecently bool
	if err := tx.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1
			FROM public.env_build_assignments eba
			JOIN public.env_builds eb ON eb.id = eba.build_id
			WHERE eba.env_id = $1
			  AND `+newestPause+` >= now() - $2::interval)`,
		c.envID, interval(retention)).Scan(&pausedRecently); err != nil {
		return false, err
	}
	if pausedRecently {
		return false, nil // the deferred Rollback undoes the soft delete
	}

	if _, err := q.ReleaseTemplateAliases(ctx, c.envID); err != nil {
		return false, fmt.Errorf("release aliases: %w", err)
	}
	if err := q.DeleteActiveTemplateBuilds(ctx, c.envID); err != nil {
		return false, fmt.Errorf("delete active builds: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return false, err
	}

	return true, nil
}

type rootBuild struct {
	id        uuid.UUID
	createdAt time.Time
}

// protectedRootBuilds returns every build whose header has to be read to learn
// what must not be deleted: the builds of every restorable env - live, or
// soft-deleted less than the purge delay ago. The second group is what keeps
// the undo window honest: a sandbox marked yesterday can still be brought
// back, so the builds its snapshots are layered on (a fork's checkpoint in
// another sandbox's env, say) have to survive until it cannot. Neither the
// env's source nor its cluster is filtered; one header too many only
// over-protects.
func (d *database) protectedRootBuilds(ctx context.Context, purgeDelay time.Duration) ([]rootBuild, error) {
	rows, err := d.pool.Query(ctx, `
		SELECT eb.id, eb.created_at
		FROM public.env_builds eb
		WHERE EXISTS (
			SELECT 1
			FROM public.env_build_assignments eba
			JOIN public.envs e ON e.id = eba.env_id
			WHERE eba.build_id = eb.id
			  AND `+restorableEnv+`)`, interval(purgeDelay))
	if err != nil {
		return nil, err
	}

	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (rootBuild, error) {
		var b rootBuild
		err := row.Scan(&b.id, &b.createdAt)

		return b, err
	})
}

type purgeCandidate struct {
	buildID   uuid.UUID
	createdAt time.Time
	envIDs    []string
	teamIDs   []string
}

// purgeCandidates lists builds none of whose envs is restorable any more, at
// least one of which is a pause snapshot and none a template, and none of
// whose envs was paused within the retention period. With only set it answers
// the same question for one build; purgeBuild re-runs it that way under the
// row lock, so eligibility has a single definition.
func purgeCandidates(ctx context.Context, q querier, purgeDelay, retention time.Duration, only *uuid.UUID) ([]purgeCandidate, error) {
	rows, err := q.Query(ctx, `
		WITH cand AS (
			SELECT eb.id                                AS build_id,
			       eb.created_at,
			       array_agg(DISTINCT e.id)             AS env_ids,
			       array_agg(DISTINCT e.team_id::text)  AS team_ids
			FROM public.env_builds eb
			JOIN public.env_build_assignments eba ON eba.build_id = eb.id
			JOIN public.envs e ON e.id = eba.env_id
			WHERE $3::uuid IS NULL OR eb.id = $3
			GROUP BY eb.id
			HAVING NOT bool_or(`+restorableEnv+`)
			   AND bool_and(e.cluster_id IS NULL)
			   AND bool_or(e.source = 'snapshot')
			   AND NOT bool_or(e.source = 'template')
		)
		SELECT c.build_id, c.created_at, c.env_ids, c.team_ids
		FROM cand c
		WHERE NOT EXISTS (
			SELECT 1
			FROM public.env_build_assignments eba
			JOIN public.env_builds eb ON eb.id = eba.build_id
			WHERE eba.env_id = ANY(c.env_ids)
			  AND `+newestPause+` >= now() - $2::interval)
		ORDER BY c.created_at`, interval(purgeDelay), interval(retention), only)
	if err != nil {
		return nil, err
	}

	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (purgeCandidate, error) {
		var c purgeCandidate
		err := row.Scan(&c.buildID, &c.createdAt, &c.envIDs, &c.teamIDs)

		return c, err
	})
}

// purgeBuild deletes one build: it locks the build's env rows, re-runs the
// eligibility query for that build under the lock, runs deleteObjects, and
// only then removes the env_builds row (the assignments cascade). Objects go
// first on purpose: a crash in between leaves a row pointing at an empty
// prefix, which the next round finishes; the other order would leave objects
// nothing can find again.
//
// The rows are locked in id order. The advisory lock already keeps two rounds
// apart, so this only matters if something else ever locks several envs at
// once - it costs nothing and rules the deadlock out.
func (d *database) purgeBuild(ctx context.Context, c purgeCandidate, purgeDelay, retention time.Duration, deleteObjects func(context.Context) error) error {
	tx, err := d.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(context.WithoutCancel(ctx)) //nolint:errcheck // no-op after Commit

	if _, err := tx.Exec(ctx, `SELECT id FROM public.envs WHERE id = ANY($1) ORDER BY id FOR UPDATE`, c.envIDs); err != nil {
		return err
	}

	still, err := purgeCandidates(ctx, tx, purgeDelay, retention, &c.buildID)
	if err != nil {
		return err
	}
	if len(still) != 1 {
		return errRecheckFailed
	}

	if err := deleteObjects(ctx); err != nil {
		return fmt.Errorf("delete objects: %w", err)
	}

	if _, err := tx.Exec(ctx, `DELETE FROM public.env_builds WHERE id = $1`, c.buildID); err != nil {
		return fmt.Errorf("delete env_builds row: %w", err)
	}

	return tx.Commit(ctx)
}
