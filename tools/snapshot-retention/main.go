// snapshot-retention removes sandbox pause snapshots that nobody can resume
// any more.
//
// Template builds and pause snapshots share one bucket and one key layout
// ({buildID}/memfile, rootfs.ext4, *.header, snapfile, metadata.json), and a
// snapshot is a diff: its header maps the blocks it did not rewrite to
// ancestor builds - the base template, earlier pauses of the same sandbox, the
// checkpoint a fork was taken from. Those ancestor objects are read lazily
// while a sandbox runs. Deleting objects by age would therefore break every
// newer snapshot still mapping blocks to them, so this tool decides from the
// database and from the headers, and S3 only executes:
//
//  1. mark:  snapshot envs whose newest pause is older than the retention
//     period are soft-deleted, exactly like DELETE /sandboxes/{id}.
//  2. purge: builds that belong only to envs soft-deleted for longer than the
//     purge delay, are themselves older than the retention period, are not
//     referenced by the header of any live build, and carry snapshot object
//     metadata, have their {buildID}/ prefix deleted and their env_builds row
//     removed.
//
// The purge delay is what makes the mark reversible: a wrongly marked sandbox
// is brought back with UPDATE envs SET deleted_at = NULL, and a sandbox that
// happened to be running when it was marked keeps its objects, because its
// next pause adds a build younger than the retention period.
//
// Everything is a dry run unless -apply (or RETENTION_APPLY=true) is set.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/e2b-dev/infra/packages/shared/pkg/storage"
)

type config struct {
	apply              bool
	retention          time.Duration
	purgeDelay         time.Duration
	headerGrace        time.Duration
	maxRuntime         time.Duration
	workers            int
	allowMissingOrigin bool
	force              bool

	dbURL  string
	bucket string
	region string
}

func parseConfig(args []string, getenv func(string) string) (config, error) {
	fs := flag.NewFlagSet("snapshot-retention", flag.ContinueOnError)

	var cfg config
	fs.BoolVar(&cfg.apply, "apply", envBool(getenv("RETENTION_APPLY")), "write to the database and delete objects; without it every action is only logged (env RETENTION_APPLY)")
	retentionDays := fs.Int("retention-days", envInt(getenv("RETENTION_DAYS"), 90), "a snapshot whose newest pause is older than this is expired (env RETENTION_DAYS)")
	purgeDelayDays := fs.Int("purge-delay-days", envInt(getenv("PURGE_DELAY_DAYS"), 7), "days between soft-deleting an expired snapshot and deleting its objects (env PURGE_DELAY_DAYS)")
	fs.DurationVar(&cfg.headerGrace, "header-grace", 48*time.Hour, "a live build younger than this may still be uploading; missing headers are not warned about")
	fs.DurationVar(&cfg.maxRuntime, "max-runtime", 2*time.Hour, "abort the run after this long")
	fs.IntVar(&cfg.workers, "workers", 16, "concurrent header downloads")
	fs.BoolVar(&cfg.allowMissingOrigin, "allow-missing-origin", false, "purge objects that carry no build_origin metadata (written before upstream stamped it)")
	fs.BoolVar(&cfg.force, "force", false, "skip the check that the purge delay exceeds the longest sandbox lifetime (tests only)")

	if err := fs.Parse(args); err != nil {
		return config{}, err
	}

	cfg.retention = time.Duration(*retentionDays) * 24 * time.Hour
	cfg.purgeDelay = time.Duration(*purgeDelayDays) * 24 * time.Hour
	cfg.dbURL = getenv("POSTGRES_CONNECTION_STRING")
	cfg.bucket = getenv("TEMPLATE_BUCKET_NAME")
	cfg.region = getenv("AWS_REGION")

	switch {
	case cfg.dbURL == "":
		return config{}, errors.New("POSTGRES_CONNECTION_STRING is required")
	case cfg.bucket == "":
		return config{}, errors.New("TEMPLATE_BUCKET_NAME is required")
	case *retentionDays < 0 || *purgeDelayDays < 0:
		return config{}, errors.New("retention and purge delay cannot be negative")
	case cfg.workers < 1:
		return config{}, errors.New("workers must be at least 1")
	}

	return cfg, nil
}

func envBool(v string) bool {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "1", "true", "yes", "on":
		return true
	}

	return false
}

func envInt(v string, def int) int {
	n, err := strconv.Atoi(strings.TrimSpace(v))
	if err != nil {
		return def
	}

	return n
}

func main() {
	log := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))

	cfg, err := parseConfig(os.Args[1:], os.Getenv)
	if err != nil {
		log.Error("invalid configuration", "err", err)
		os.Exit(2)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	ctx, cancel := context.WithTimeout(ctx, cfg.maxRuntime)
	defer cancel()

	os.Exit(run(ctx, cfg, log))
}

// run executes one round and returns the process exit code: 0 when every
// decision was carried out (or, in a dry run, logged), 1 when the run was
// aborted or when a build had to be skipped for a reason that indicates an
// inconsistency between the database and the bucket.
func run(ctx context.Context, cfg config, log *slog.Logger) int {
	pool, err := pgxpool.New(ctx, cfg.dbURL)
	if err != nil {
		log.Error("connect to postgres", "err", err)

		return 1
	}
	defer pool.Close()
	db := &database{pool: pool}

	// The queries below were verified against one schema version. A newer
	// database (an upstream sync added migrations) may have changed what they
	// mean without breaking them, so nothing is written until someone has
	// re-verified and bumped verifiedMigration; the dry run still shows what
	// would happen. An older database cannot be reasoned about at all.
	applied, err := db.appliedMigration(ctx)
	if err != nil {
		log.Error("read applied schema version", "err", err)

		return 1
	}
	schemaAhead := false
	switch compareSchema(applied, verifiedMigration) {
	case schemaOlder:
		log.Error("database schema is older than the version this tool was verified against; refusing to run", "applied", applied, "verified", verifiedMigration)

		return 1
	case schemaNewer:
		log.Error("database schema is newer than the version this tool was verified against; forcing a dry run until tools/snapshot-retention is re-verified and verifiedMigration is bumped", "applied", applied, "verified", verifiedMigration)
		cfg.apply = false
		schemaAhead = true
	}

	mode := "apply"
	if !cfg.apply {
		mode = "dry-run"
	}
	log = log.With("mode", mode)
	log.Info("starting", "retention", cfg.retention, "purge_delay", cfg.purgeDelay, "bucket", cfg.bucket, "schema", applied)

	// A sandbox resumed just before its snapshot was marked keeps reading the
	// snapshot's objects until it stops. The purge delay has to outlast the
	// longest lifetime a sandbox can have.
	maxHours, err := db.maxSandboxLengthHours(ctx)
	if err != nil {
		log.Error("read tiers.max_length_hours", "err", err)

		return 1
	}
	if longest := time.Duration(maxHours) * time.Hour; longest >= cfg.purgeDelay {
		if !cfg.force {
			log.Error("purge delay must exceed the longest sandbox lifetime", "purge_delay", cfg.purgeDelay, "max_length_hours", maxHours)

			return 1
		}
		log.Warn("purge delay does not exceed the longest sandbox lifetime; continuing because of -force", "purge_delay", cfg.purgeDelay, "max_length_hours", maxHours)
	}

	store, err := newS3Store(ctx, cfg.bucket, cfg.region)
	if err != nil {
		log.Error("create s3 client", "err", err)

		return 1
	}

	marked, err := runMark(ctx, db, cfg, log)
	if err != nil {
		log.Error("mark phase failed", "err", err)

		return 1
	}

	live, err := db.liveBuilds(ctx)
	if err != nil {
		log.Error("list live builds", "err", err)

		return 1
	}
	protected, err := protectedSet(ctx, store, live, cfg.workers, cfg.headerGrace, time.Now(), log)
	if err != nil {
		// Without a complete picture of what is still referenced nothing may
		// be deleted. The mark phase above stands: it only hid snapshots that
		// were expired anyway.
		log.Error("computing the protected set failed; skipping the purge phase", "err", err)

		return 1
	}
	log.Info("protected set computed", "live_builds", len(live), "protected_builds", len(protected))

	stats := runPurge(ctx, db, store, cfg, protected, log)

	log.Info("finished",
		"marked", marked,
		"purged", stats.purged,
		"purged_db_only", stats.dbOnly,
		"kept", stats.kept,
		"skipped", stats.skipped,
		"errors", stats.errors,
		"objects_deleted", stats.objects,
	)

	if stats.errors > 0 || schemaAhead {
		return 1
	}

	return 0
}

func runMark(ctx context.Context, db *database, cfg config, log *slog.Logger) (int, error) {
	candidates, err := db.markCandidates(ctx, cfg.retention)
	if err != nil {
		return 0, err
	}

	marked := 0
	for _, c := range candidates {
		l := log.With("phase", "mark", "env", c.envID, "sandbox", c.sandboxID, "team", c.teamID, "last_pause", c.newestAt.UTC().Format(time.RFC3339), "builds", c.builds)
		if !cfg.apply {
			l.Info("MARK")
			marked++

			continue
		}

		done, err := db.markEnv(ctx, c, cfg.retention)
		if err != nil {
			return marked, fmt.Errorf("mark env %s: %w", c.envID, err)
		}
		if !done {
			// The sandbox was paused again between the select and the update.
			l.Info("MARK skipped: env changed since selection")

			continue
		}
		l.Info("MARK")
		marked++
	}

	return marked, nil
}

type purgeStats struct {
	purged, dbOnly, kept, skipped, errors, objects int
}

func runPurge(ctx context.Context, db *database, store objectStore, cfg config, protected map[uuid.UUID][]uuid.UUID, log *slog.Logger) purgeStats {
	var stats purgeStats

	candidates, err := db.purgeCandidates(ctx, cfg.purgeDelay, cfg.retention)
	if err != nil {
		log.Error("list purge candidates", "err", err)
		stats.errors++

		return stats
	}

	for _, c := range candidates {
		if ctx.Err() != nil {
			log.Error("run aborted", "err", ctx.Err())
			stats.errors++

			return stats
		}

		l := log.With("phase", "purge", "build", c.buildID, "envs", c.envIDs, "created", c.createdAt.UTC().Format(time.RFC3339))
		paths := storage.Paths{BuildID: c.buildID.String()}
		prefix := paths.StorageDir() + "/"

		keys, err := store.List(ctx, prefix)
		if err != nil {
			l.Error("list objects", "err", err)
			stats.errors++

			continue
		}

		facts, err := objectFactsFor(ctx, store, paths)
		if err != nil {
			l.Error("read object metadata", "err", err)
			stats.errors++

			continue
		}
		facts.objectCount = len(keys)

		d := decidePurge(c, protected, facts, cfg.allowMissingOrigin)
		switch d.action {
		case actionKeep:
			l.Info(d.reason)
			stats.kept++

			continue
		case actionSkip:
			if d.failure {
				l.Error(d.reason)
				stats.errors++
			} else {
				l.Warn(d.reason)
				stats.skipped++
			}

			continue
		}

		l = l.With("objects", len(keys))
		if !cfg.apply {
			l.Info(d.reason)
			if d.dbOnly {
				stats.dbOnly++
			} else {
				stats.purged++
				stats.objects += len(keys)
			}

			continue
		}

		deleted := 0
		deleteObjects := func(ctx context.Context) error {
			// List again under the row lock: the set is immutable for a build
			// this old, but a re-list costs one request and removes any doubt.
			current, err := store.List(ctx, prefix)
			if err != nil {
				return err
			}
			if len(current) == 0 {
				return nil
			}
			if err := store.Delete(ctx, current); err != nil {
				return err
			}
			deleted = len(current)

			return nil
		}

		if err := db.purgeBuild(ctx, c, cfg.purgeDelay, deleteObjects); err != nil {
			if errors.Is(err, errRecheckFailed) {
				l.Info("KEEP_LIVE_ASSIGNMENT: env state changed since selection")
				stats.kept++
			} else {
				l.Error("purge failed", "err", err)
				stats.errors++
			}

			continue
		}

		l.Info(d.reason, "deleted", deleted)
		if d.dbOnly {
			stats.dbOnly++
		} else {
			stats.purged++
			stats.objects += deleted
		}
	}

	return stats
}

// objectFactsFor reads the snapshot's object metadata. The rootfs header is
// present for every real build (memory-only and filesystem-only alike); the
// metadata.json is the fallback for a build whose header upload failed.
func objectFactsFor(ctx context.Context, store objectStore, paths storage.Paths) (objectFacts, error) {
	for _, key := range []string{paths.RootfsHeader(), paths.Metadata()} {
		meta, err := store.Head(ctx, key)
		if errors.Is(err, errNotFound) {
			continue
		}
		if err != nil {
			return objectFacts{}, fmt.Errorf("head %s: %w", key, err)
		}

		return objectFacts{
			origin:     meta[storage.ObjectMetadataBuildOrigin],
			templateID: meta[storage.ObjectMetadataTemplateID],
			teamID:     meta[storage.ObjectMetadataTeamID],
		}, nil
	}

	return objectFacts{missing: true}, nil
}
