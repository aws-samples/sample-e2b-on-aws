package main

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// database wraps the handful of statements this tool runs. It touches only
// envs, snapshots, env_builds, env_build_assignments and tiers, and it mirrors
// the API's own soft delete (packages/db/queries/templates/delete_template.sql)
// rather than inventing a state of its own.
type database struct {
	pool *pgxpool.Pool
}

var errRecheckFailed = errors.New("env state changed since the build was selected")

// interval renders a duration as a Postgres interval literal for `$n::interval`.
func interval(d time.Duration) string {
	return fmt.Sprintf("%d seconds", int64(d.Seconds()))
}

// tryLock takes a session-level advisory lock so two rounds never overlap. The
// connection stays checked out until release is called.
func (d *database) tryLock(ctx context.Context) (release func(), locked bool, err error) {
	conn, err := d.pool.Acquire(ctx)
	if err != nil {
		return nil, false, err
	}

	if err := conn.QueryRow(ctx, `SELECT pg_try_advisory_lock(hashtext('snapshot-retention'))`).Scan(&locked); err != nil {
		conn.Release()

		return nil, false, err
	}
	if !locked {
		conn.Release()

		return nil, false, nil
	}

	release = func() {
		_, _ = conn.Exec(context.WithoutCancel(ctx), `SELECT pg_advisory_unlock(hashtext('snapshot-retention'))`)
		conn.Release()
	}

	return release, true, nil
}

func (d *database) maxSandboxLengthHours(ctx context.Context) (int64, error) {
	var hours int64
	err := d.pool.QueryRow(ctx, `SELECT COALESCE(MAX(max_length_hours), 0) FROM public.tiers`).Scan(&hours)

	return hours, err
}

type markCandidate struct {
	envID     string
	teamID    string
	sandboxID string
	newestAt  time.Time
	builds    int64
}

// markCandidates lists pause-snapshot envs whose newest build is older than
// the retention period. "Newest pause" is what the API itself reports as the
// pause time (handlers/sandbox_get.go), taken as the later of the build row
// and the assignment row so a re-assigned build never looks older than it is.
func (d *database) markCandidates(ctx context.Context, retention time.Duration) ([]markCandidate, error) {
	rows, err := d.pool.Query(ctx, `
		WITH newest AS (
			SELECT eba.env_id,
			       MAX(GREATEST(eb.created_at, eba.created_at)) AS newest_at,
			       COUNT(*)                                     AS n
			FROM public.env_build_assignments eba
			JOIN public.env_builds eb ON eb.id = eba.build_id
			GROUP BY eba.env_id
		)
		SELECT e.id, e.team_id::text, s.sandbox_id, n.newest_at, n.n
		FROM public.envs e
		JOIN public.snapshots s ON s.env_id = e.id
		JOIN newest n ON n.env_id = e.id
		WHERE e.source = 'snapshot'
		  AND e.deleted_at IS NULL
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

// markEnv soft-deletes a snapshot env the way DELETE /sandboxes/{id} does, and
// only if it still has no build younger than the retention period.
func (d *database) markEnv(ctx context.Context, envID string, retention time.Duration) (bool, error) {
	tag, err := d.pool.Exec(ctx, `
		UPDATE public.envs
		SET deleted_at = now(), updated_at = now()
		WHERE id = $1
		  AND deleted_at IS NULL
		  AND source = 'snapshot'
		  AND NOT EXISTS (
			SELECT 1
			FROM public.env_build_assignments eba
			JOIN public.env_builds eb ON eb.id = eba.build_id
			WHERE eba.env_id = $1
			  AND GREATEST(eb.created_at, eba.created_at) >= now() - $2::interval)`,
		envID, interval(retention))
	if err != nil {
		return false, err
	}

	return tag.RowsAffected() == 1, nil
}

type restoreCandidate struct {
	envID     string
	deletedAt time.Time
}

// restoreCandidates lists soft-deleted snapshot envs that were paused again
// after the soft delete: the sandbox was running when the env was marked. The
// API invalidates its snapshot cache when a user deletes a paused sandbox, so
// a user-deleted env can never be resumed and never gains a newer build; the
// only envs this can match are the ones this tool marked.
func (d *database) restoreCandidates(ctx context.Context) ([]restoreCandidate, error) {
	rows, err := d.pool.Query(ctx, `
		SELECT e.id, e.deleted_at
		FROM public.envs e
		WHERE e.source = 'snapshot'
		  AND e.deleted_at IS NOT NULL
		  AND e.cluster_id IS NULL
		  AND EXISTS (
			SELECT 1
			FROM public.env_build_assignments eba
			JOIN public.env_builds eb ON eb.id = eba.build_id
			WHERE eba.env_id = e.id
			  AND GREATEST(eb.created_at, eba.created_at) > e.deleted_at)`)
	if err != nil {
		return nil, err
	}

	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (restoreCandidate, error) {
		var c restoreCandidate
		err := row.Scan(&c.envID, &c.deletedAt)

		return c, err
	})
}

func (d *database) restoreEnv(ctx context.Context, envID string) (bool, error) {
	tag, err := d.pool.Exec(ctx, `
		UPDATE public.envs
		SET deleted_at = NULL, updated_at = now()
		WHERE id = $1 AND deleted_at IS NOT NULL AND source = 'snapshot'`, envID)
	if err != nil {
		return false, err
	}

	return tag.RowsAffected() == 1, nil
}

type liveBuild struct {
	id        uuid.UUID
	createdAt time.Time
}

// liveBuilds returns every build assigned to an env that is not soft-deleted,
// whatever the env's source. Their headers decide what must not be deleted.
func (d *database) liveBuilds(ctx context.Context) ([]liveBuild, error) {
	rows, err := d.pool.Query(ctx, `
		SELECT DISTINCT eb.id, eb.created_at
		FROM public.env_build_assignments eba
		JOIN public.envs e ON e.id = eba.env_id AND e.deleted_at IS NULL AND e.cluster_id IS NULL
		JOIN public.env_builds eb ON eb.id = eba.build_id`)
	if err != nil {
		return nil, err
	}

	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (liveBuild, error) {
		var b liveBuild
		err := row.Scan(&b.id, &b.createdAt)

		return b, err
	})
}

type purgeCandidate struct {
	buildID       uuid.UUID
	createdAt     time.Time
	envIDs        []string
	teamIDs       []string
	lastDeletedAt time.Time
}

// purgeCandidates lists builds every one of whose envs is soft-deleted (for at
// least the purge delay), at least one of which is a pause snapshot and none of
// which is a template, and none of whose envs was paused within the retention
// period. Template builds are never candidates even when their env is deleted.
func (d *database) purgeCandidates(ctx context.Context, purgeDelay, retention time.Duration) ([]purgeCandidate, error) {
	rows, err := d.pool.Query(ctx, `
		WITH cand AS (
			SELECT eb.id                                AS build_id,
			       eb.created_at,
			       array_agg(DISTINCT e.id)             AS env_ids,
			       array_agg(DISTINCT e.team_id::text)  AS team_ids,
			       max(e.deleted_at)                    AS last_deleted_at
			FROM public.env_builds eb
			JOIN public.env_build_assignments eba ON eba.build_id = eb.id
			JOIN public.envs e ON e.id = eba.env_id
			GROUP BY eb.id
			HAVING bool_and(e.deleted_at IS NOT NULL)
			   AND bool_and(e.cluster_id IS NULL)
			   AND bool_or(e.source = 'snapshot')
			   AND NOT bool_or(e.source = 'template')
			   AND max(e.deleted_at) < now() - $1::interval
		)
		SELECT c.build_id, c.created_at, c.env_ids, c.team_ids, c.last_deleted_at
		FROM cand c
		WHERE NOT EXISTS (
			SELECT 1
			FROM public.env_build_assignments a2
			JOIN public.env_builds b2 ON b2.id = a2.build_id
			WHERE a2.env_id = ANY(c.env_ids)
			  AND GREATEST(b2.created_at, a2.created_at) >= now() - $2::interval)
		ORDER BY c.created_at`, interval(purgeDelay), interval(retention))
	if err != nil {
		return nil, err
	}

	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (purgeCandidate, error) {
		var c purgeCandidate
		err := row.Scan(&c.buildID, &c.createdAt, &c.envIDs, &c.teamIDs, &c.lastDeletedAt)

		return c, err
	})
}

// purgeBuild deletes one build: it locks the build's env rows, re-checks that
// every one of them is still soft-deleted for longer than the purge delay and
// that no live env has picked the build up meanwhile, runs deleteObjects, and
// only then removes the env_builds row (the assignments cascade). Objects go
// first on purpose: a crash in between leaves a row pointing at an empty
// prefix, which the next round finishes; the other order would leave objects
// nothing can find again.
func (d *database) purgeBuild(ctx context.Context, c purgeCandidate, purgeDelay time.Duration, deleteObjects func(context.Context) error) error {
	tx, err := d.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(context.WithoutCancel(ctx)) //nolint:errcheck // no-op after Commit

	rows, err := tx.Query(ctx, `
		SELECT id, deleted_at, now() - $2::interval
		FROM public.envs
		WHERE id = ANY($1)
		FOR UPDATE`, c.envIDs, interval(purgeDelay))
	if err != nil {
		return err
	}
	type envState struct {
		id        string
		deletedAt *time.Time
		cutoff    time.Time
	}
	states, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (envState, error) {
		var s envState
		err := row.Scan(&s.id, &s.deletedAt, &s.cutoff)

		return s, err
	})
	if err != nil {
		return err
	}
	if len(states) != len(c.envIDs) {
		return errRecheckFailed
	}
	for _, s := range states {
		if s.deletedAt == nil || !s.deletedAt.Before(s.cutoff) {
			return errRecheckFailed
		}
	}

	var liveAssignments int
	if err := tx.QueryRow(ctx, `
		SELECT count(*)
		FROM public.env_build_assignments a
		JOIN public.envs e ON e.id = a.env_id
		WHERE a.build_id = $1 AND e.deleted_at IS NULL`, c.buildID).Scan(&liveAssignments); err != nil {
		return err
	}
	if liveAssignments > 0 {
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
