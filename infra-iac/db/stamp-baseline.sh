#!/bin/bash
# stamp-baseline.sh - Record the migrations an existing database already contains.
#
# Why this exists
# ---------------
# Before the upstream code sync, the schema was created by applying the flattened
# infra-iac/db/.migration.sql in one shot. That file covered migrations up to and
# including 20250624001049_cluster_for_builds, but it never created goose's
# _migrations tracking table. Upstream now owns the schema through goose (and the
# API refuses to start against a database older than the migration its binary was
# built from), so pointing goose at such a database makes it report version 0 and
# try to replay every migration against tables that already exist.
#
# This script creates the tracking table and marks every migration up to the
# baseline as applied, so a subsequent `goose up` only runs what is genuinely
# missing. It is idempotent and only ever inserts rows for migrations that are
# not already recorded.
#
# Usage:
#   ./stamp-baseline.sh                 # read credentials from /opt/config.properties
#   ./stamp-baseline.sh --dry-run       # show what would be stamped
#   BASELINE=20250624001049 ./stamp-baseline.sh
set -euo pipefail

cd "$(dirname "$0")"
REPO_ROOT=$(cd ../.. && pwd)
MIGRATIONS_DIR="$REPO_ROOT/packages/db/migrations"
CONFIG_FILE="/opt/config.properties"

# Last migration represented in the flattened .migration.sql.
BASELINE="${BASELINE:-20250624001049}"

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

if [ ! -d "$MIGRATIONS_DIR" ]; then
    echo "Error: migrations directory not found: $MIGRATIONS_DIR"
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: $CONFIG_FILE not found"
    exit 1
fi

DB_CREDENTIAL_SECRET=$(grep "^CFNDBCredentialSecretName=" "$CONFIG_FILE" | cut -d'=' -f2)
if [ -z "$DB_CREDENTIAL_SECRET" ]; then
    echo "Error: CFNDBCredentialSecretName missing from $CONFIG_FILE"
    exit 1
fi

DB_SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$DB_CREDENTIAL_SECRET" --query SecretString --output text)
DB_HOST=$(echo "$DB_SECRET_JSON" | jq -r '.host')
DB_PORT=$(echo "$DB_SECRET_JSON" | jq -r '.port')
DB_NAME=$(echo "$DB_SECRET_JSON" | jq -r '.dbname')
DB_USER=$(echo "$DB_SECRET_JSON" | jq -r '.username')
DB_PASSWORD=$(echo "$DB_SECRET_JSON" | jq -r '.password')

psql_do() {
    PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 "$@"
}

# Versions at or below the baseline, taken from the filenames so the list cannot
# drift from what is actually on disk.
versions=$(ls "$MIGRATIONS_DIR" | grep -E '^[0-9]+_.*\.sql$' | sed 's/_.*//' | sort -u | awk -v b="$BASELINE" '$1 <= b')

if [ -z "$versions" ]; then
    echo "Error: no migrations found at or below baseline $BASELINE"
    exit 1
fi

count=$(echo "$versions" | wc -l | tr -d ' ')
echo "Baseline           : $BASELINE"
echo "Migrations to stamp: $count"
echo "Database           : $DB_NAME on $DB_HOST"

if [ "$DRY_RUN" = true ]; then
    echo "--- dry run, nothing written ---"
    echo "$versions"
    exit 0
fi

# goose's postgres tracking table layout. Creating it here rather than letting
# goose do it keeps this script usable against a role without DDL-on-demand.
psql_do <<'SQL'
CREATE TABLE IF NOT EXISTS public._migrations (
    id          serial PRIMARY KEY,
    version_id  bigint  NOT NULL,
    is_applied  boolean NOT NULL,
    tstamp      timestamp NULL DEFAULT now()
);
SQL

# goose treats version 0 as the initial row.
psql_do -c "INSERT INTO public._migrations (version_id, is_applied)
            SELECT 0, true
            WHERE NOT EXISTS (SELECT 1 FROM public._migrations WHERE version_id = 0);"

stamped=0
for v in $versions; do
    inserted=$(psql_do -tAc "INSERT INTO public._migrations (version_id, is_applied)
                             SELECT ${v}, true
                             WHERE NOT EXISTS (SELECT 1 FROM public._migrations WHERE version_id = ${v})
                             RETURNING 1;")
    [ -n "$inserted" ] && stamped=$((stamped + 1))
done

echo "Newly stamped      : $stamped"
echo "Current version    : $(psql_do -tAc 'SELECT max(version_id) FROM public._migrations;')"
echo
echo "Baseline recorded. Run infra-iac/db/init-db.sh (or make -C packages/db migrate)"
echo "to apply the remaining migrations."
