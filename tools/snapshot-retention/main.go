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
//     referenced by the header of any restorable build, and carry snapshot
//     object metadata, have their {buildID}/ prefix deleted and their
//     env_builds row removed.
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

	"github.com/e2b-dev/infra/packages/db/pkg/pool"
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

	dbURL  string
	bucket string
	region string
}

func parseConfig(args []string, getenv func(string) string) (config, error) {
	fs := flag.NewFlagSet("snapshot-retention", flag.ContinueOnError)

	// The environment is what the Nomad job spec sets; flags override it.
	retentionDefault, err := envInt(getenv, "RETENTION_DAYS", 90)
	if err != nil {
		return config{}, err
	}
	purgeDelayDefault, err := envInt(getenv, "PURGE_DELAY_DAYS", 7)
	if err != nil {
		return config{}, err
	}

	var cfg config
	fs.BoolVar(&cfg.apply, "apply", envBool(getenv("RETENTION_APPLY")), "write to the database and delete objects; without it every action is only logged (env RETENTION_APPLY)")
	retentionDays := fs.Int("retention-days", retentionDefault, "a snapshot whose newest pause is older than this is expired (env RETENTION_DAYS)")
	purgeDelayDays := fs.Int("purge-delay-days", purgeDelayDefault, "days between soft-deleting an expired snapshot and deleting its objects (env PURGE_DELAY_DAYS)")
	fs.DurationVar(&cfg.headerGrace, "header-grace", 48*time.Hour, "a build younger than this may still be uploading; missing headers are not warned about")
	fs.DurationVar(&cfg.maxRuntime, "max-runtime", 2*time.Hour, "abort the run after this long")
	fs.IntVar(&cfg.workers, "workers", 8, "concurrent header downloads; each decodes a whole header in memory")
	fs.BoolVar(&cfg.allowMissingOrigin, "allow-missing-origin", envBool(getenv("RETENTION_ALLOW_MISSING_ORIGIN")), "purge objects that carry no build_origin metadata (written before upstream stamped it) (env RETENTION_ALLOW_MISSING_ORIGIN)")

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
	case *retentionDays < 1:
		// Zero would match every paused sandbox in the deployment.
		return config{}, errors.New("retention must be at least 1 day")
	case *purgeDelayDays < 0:
		return config{}, errors.New("purge delay cannot be negative")
	case cfg.workers < 1:
		return config{}, errors.New("workers must be at least 1")
	}

	return cfg, nil
}

func envBool(v string) bool {
	b, err := strconv.ParseBool(strings.TrimSpace(v))

	return err == nil && b
}

// envInt reads an integer from the environment. Unset or empty means the
// default; anything else has to parse, because a typo here ("30d", "9O")
// silently falling back to 90 days would delete on the wrong schedule.
func envInt(getenv func(string) string, name string, def int) (int, error) {
	v := strings.TrimSpace(getenv(name))
	if v == "" {
		return def, nil
	}

	n, err := strconv.Atoi(v)
	if err != nil {
		return 0, fmt.Errorf("%s: %q is not an integer", name, v)
	}

	return n, nil
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
// aborted or when a build had to be left alone for a reason that indicates
// an inconsistency between the database and the bucket.
func run(ctx context.Context, cfg config, log *slog.Logger) int {
	store, err := newS3Store(ctx, cfg.bucket, cfg.region)
	if err != nil {
		log.Error("create s3 client", "err", err)

		return 1
	}

	// Upstream's client: it pings, and it owns the session-scoped advisory lock.
	client, err := pool.Connect(ctx, cfg.dbURL, "snapshot-retention")
	if err != nil {
		log.Error("connect to postgres", "err", err)

		return 1
	}
	defer client.Close()
	db := &database{pool: client.Pool()}

	// One round at a time. Nomad's prohibit_overlap only serializes scheduled
	// launches; a manual `nomad job periodic force` or a run started by hand
	// would otherwise overlap with the nightly one and duplicate its work and
	// its log lines.
	lock, err := client.TryAcquireAdvisoryLock(ctx, "snapshot-retention")
	if errors.Is(err, pool.ErrAdvisoryLockBusy) {
		log.Error("another snapshot-retention run holds the lock; exiting")

		return 1
	}
	if err != nil {
		log.Error("acquire advisory lock", "err", err)

		return 1
	}
	defer func() { _ = lock.Release(context.WithoutCancel(ctx)) }()

	// The queries were verified against one schema version. A newer database
	// (an upstream sync added migrations) may have changed what they mean
	// without breaking them, so nothing is written until someone has
	// re-verified and bumped verifiedMigration; the dry run still shows what
	// would happen. An older database cannot be reasoned about at all.
	applied, err := db.appliedMigration(ctx)
	if err != nil {
		log.Error("read applied schema version", "err", err)

		return 1
	}
	schemaAhead := false
	switch {
	case applied < verifiedMigration:
		log.Error("database schema is older than the version this tool was verified against; refusing to run", "applied", applied, "verified", verifiedMigration)

		return 1
	case applied > verifiedMigration:
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
		log.Error("read team_limits.max_length_hours", "err", err)

		return 1
	}
	if longest := time.Duration(maxHours) * time.Hour; longest >= cfg.purgeDelay {
		log.Error("purge delay must exceed the longest sandbox lifetime", "purge_delay", cfg.purgeDelay, "max_length_hours", maxHours)

		return 1
	}

	marked, err := runMark(ctx, db, cfg, log)
	if err != nil {
		log.Error("mark phase failed", "err", err)

		return 1
	}

	roots, err := db.protectedRootBuilds(ctx, cfg.purgeDelay)
	if err != nil {
		log.Error("list protected root builds", "err", err)

		return 1
	}
	protected, err := protectedSet(ctx, store, roots, cfg.workers, cfg.headerGrace, time.Now(), log)
	if err != nil {
		// Without a complete picture of what is still referenced nothing may
		// be deleted. The mark phase above stands: it only hid snapshots that
		// were expired anyway.
		log.Error("computing the protected set failed; skipping the purge phase", "err", err)

		return 1
	}
	log.Info("protected set computed", "root_builds", len(roots), "protected_builds", len(protected))

	stats, err := runPurge(ctx, db, store, cfg, protected, log)
	if err != nil {
		log.Error("purge phase aborted", "err", err, "purged_so_far", stats.purged)

		return 1
	}

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
		if err := ctx.Err(); err != nil {
			return marked, fmt.Errorf("run aborted after marking %d envs: %w", marked, err)
		}

		l := log.With("phase", "mark", "env", c.envID, "sandbox", c.sandboxID, "team", c.teamID, "last_pause", c.newestAt.UTC().Format(time.RFC3339), "builds", c.builds)
		if cfg.apply {
			done, err := db.markEnv(ctx, c, cfg.retention)
			if err != nil {
				return marked, fmt.Errorf("mark env %s: %w", c.envID, err)
			}
			if !done {
				// The sandbox was paused again between the select and the update.
				l.Info("MARK skipped: env changed since selection")

				continue
			}
		}
		l.Info("MARK")
		marked++
	}

	return marked, nil
}

type purgeStats struct {
	purged, dbOnly, kept, skipped, errors, objects int
}

func runPurge(ctx context.Context, db *database, store objectStore, cfg config, protected map[uuid.UUID]uuid.UUID, log *slog.Logger) (purgeStats, error) {
	var stats purgeStats

	candidates, err := purgeCandidates(ctx, db.pool, cfg.purgeDelay, cfg.retention, nil)
	if err != nil {
		return stats, fmt.Errorf("list purge candidates: %w", err)
	}

	for _, c := range candidates {
		if err := ctx.Err(); err != nil {
			return stats, err
		}

		l := log.With("phase", "purge", "build", c.buildID, "envs", c.envIDs, "created", c.createdAt.UTC().Format(time.RFC3339))

		// Decided from memory, before any request is spent on the build.
		if referrer, ok := protected[c.buildID]; ok {
			l.Info("KEEP_REFERENCED_BY " + referrer.String())
			stats.kept++

			continue
		}

		paths := storage.Paths{BuildID: c.buildID.String()}
		prefix := paths.StorageDir() + "/"

		keys, err := store.List(ctx, prefix)
		if err != nil {
			l.Error("list objects", "err", err)
			stats.errors++

			continue
		}
		facts, err := objectFactsFor(ctx, store, paths, keys)
		if err != nil {
			l.Error("read object metadata", "err", err)
			stats.errors++

			continue
		}

		l = l.With("objects", len(keys))
		d := decidePurge(c, facts, cfg.allowMissingOrigin)
		switch d.action {
		case actionSkip:
			l.Warn(d.reason)
			stats.skipped++

			continue
		case actionFail:
			l.Error(d.reason)
			stats.errors++

			continue
		}

		if cfg.apply {
			deleteObjects := func(ctx context.Context) error {
				if len(keys) == 0 {
					return nil
				}

				return store.DeletePrefix(ctx, prefix)
			}
			if err := db.purgeBuild(ctx, c, cfg.purgeDelay, cfg.retention, deleteObjects); err != nil {
				if errors.Is(err, errRecheckFailed) {
					l.Info(reasonRecheckFailed)
					stats.kept++
				} else {
					l.Error("purge failed", "err", err)
					stats.errors++
				}

				continue
			}
		}

		l.Info(d.reason)
		if len(keys) == 0 {
			stats.dbOnly++
		} else {
			stats.purged++
			stats.objects += len(keys)
		}
	}

	return stats, nil
}

// objectFactsFor reads the metadata stamped on the build's objects. The rootfs
// header exists for every complete build (memory-only and filesystem-only
// alike); metadata.json is the fallback for one whose header upload failed.
// Only a key the listing reported is HEADed, so a build with neither costs no
// request.
func objectFactsFor(ctx context.Context, store objectStore, paths storage.Paths, keys []string) (objectFacts, error) {
	facts := objectFacts{objectCount: len(keys)}

	present := make(map[string]struct{}, len(keys))
	for _, k := range keys {
		present[k] = struct{}{}
	}

	for _, key := range []string{paths.RootfsHeader(), paths.Metadata()} {
		if _, ok := present[key]; !ok {
			continue
		}

		meta, err := store.Head(ctx, key)
		if errors.Is(err, storage.ErrObjectNotExist) {
			continue
		}
		if err != nil {
			return objectFacts{}, fmt.Errorf("head %s: %w", key, err)
		}

		facts.origin = meta[storage.ObjectMetadataBuildOrigin]
		facts.templateID = meta[storage.ObjectMetadataTemplateID]
		facts.teamID = meta[storage.ObjectMetadataTeamID]

		return facts, nil
	}

	return facts, nil
}
