#!/bin/bash
# verify-migrations.sh - Rehearse the schema upgrade on a throwaway clone.
#
# This is the gate for the upstream code sync: it proves the 85 migrations added
# since 20250624001049 apply cleanly on top of a database that was created by the
# old flattened .migration.sql, and that the row-level security this deployment
# enables on 10 tables does not block them.
#
# It creates real AWS resources (a snapshot and a restored Aurora cluster) and so
# costs money. Nothing touches the live cluster: the snapshot is read-only and all
# migrations run against the clone.
#
# Usage:
#   ./verify-migrations.sh <source-cluster-id> [clone-suffix]
#
# Example:
#   ./verify-migrations.sh e2b-aurora-db presync
#
# Clean up when finished:
#   aws rds delete-db-cluster --db-cluster-identifier <clone-id> --skip-final-snapshot
#   aws rds delete-db-instance --db-instance-identifier <clone-id>-instance --skip-final-snapshot
set -euo pipefail

cd "$(dirname "$0")"
REPO_ROOT=$(cd ../.. && pwd)
MIGRATIONS_DIR="$REPO_ROOT/packages/db/migrations"
BASELINE="${BASELINE:-20250624001049}"

SRC_CLUSTER="${1:?Usage: verify-migrations.sh <source-cluster-id> [clone-suffix]}"
SUFFIX="${2:-presync}"
SNAPSHOT_ID="${SRC_CLUSTER}-${SUFFIX}-snap"
CLONE_ID="${SRC_CLUSTER}-${SUFFIX}-clone"

total=$(ls "$MIGRATIONS_DIR" | grep -cE '^[0-9]+_.*\.sql$')
pending=$(ls "$MIGRATIONS_DIR" | grep -E '^[0-9]+_.*\.sql$' | sed 's/_.*//' | sort -u | awk -v b="$BASELINE" '$1 > b' | wc -l | tr -d ' ')

cat <<EOF
=== Migration upgrade rehearsal ===
  source cluster : $SRC_CLUSTER
  snapshot       : $SNAPSHOT_ID
  clone          : $CLONE_ID
  baseline       : $BASELINE
  migrations     : $total total, $pending to apply

This creates billable AWS resources. Ctrl-C now to abort.
EOF
sleep 10

echo "--- 1/5 snapshotting source cluster ---"
aws rds create-db-cluster-snapshot \
    --db-cluster-identifier "$SRC_CLUSTER" \
    --db-cluster-snapshot-identifier "$SNAPSHOT_ID" >/dev/null
aws rds wait db-cluster-snapshot-available --db-cluster-snapshot-identifier "$SNAPSHOT_ID"

echo "--- 2/5 restoring clone ---"
SRC_JSON=$(aws rds describe-db-clusters --db-cluster-identifier "$SRC_CLUSTER")
ENGINE=$(echo "$SRC_JSON" | jq -r '.DBClusters[0].Engine')
SUBNET_GROUP=$(echo "$SRC_JSON" | jq -r '.DBClusters[0].DBSubnetGroup')
SEC_GROUPS=$(echo "$SRC_JSON" | jq -r '.DBClusters[0].VpcSecurityGroups[].VpcSecurityGroupId' | tr '\n' ' ')

aws rds restore-db-cluster-from-snapshot \
    --db-cluster-identifier "$CLONE_ID" \
    --snapshot-identifier "$SNAPSHOT_ID" \
    --engine "$ENGINE" \
    --db-subnet-group-name "$SUBNET_GROUP" \
    --vpc-security-group-ids $SEC_GROUPS \
    --serverless-v2-scaling-configuration MinCapacity=0.5,MaxCapacity=16 >/dev/null

aws rds create-db-instance \
    --db-instance-identifier "${CLONE_ID}-instance" \
    --db-cluster-identifier "$CLONE_ID" \
    --db-instance-class db.serverless \
    --engine "$ENGINE" >/dev/null
aws rds wait db-instance-available --db-instance-identifier "${CLONE_ID}-instance"

CLONE_HOST=$(aws rds describe-db-clusters --db-cluster-identifier "$CLONE_ID" \
    --query 'DBClusters[0].Endpoint' --output text)
echo "clone endpoint: $CLONE_HOST"

# Credentials are inherited from the snapshot, so reuse the live cluster's secret.
CONFIG_FILE=/opt/config.properties
DB_CREDENTIAL_SECRET=$(grep "^CFNDBCredentialSecretName=" "$CONFIG_FILE" | cut -d'=' -f2)
DB_SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$DB_CREDENTIAL_SECRET" --query SecretString --output text)
DB_PORT=$(echo "$DB_SECRET_JSON" | jq -r '.port')
DB_NAME=$(echo "$DB_SECRET_JSON" | jq -r '.dbname')
DB_USER=$(echo "$DB_SECRET_JSON" | jq -r '.username')
DB_PASSWORD=$(echo "$DB_SECRET_JSON" | jq -r '.password')

clone_psql() {
    PGPASSWORD="$DB_PASSWORD" psql -h "$CLONE_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 "$@"
}

echo "--- 3/5 stamping baseline on the clone ---"
versions=$(ls "$MIGRATIONS_DIR" | grep -E '^[0-9]+_.*\.sql$' | sed 's/_.*//' | sort -u | awk -v b="$BASELINE" '$1 <= b')
clone_psql <<'SQL'
CREATE TABLE IF NOT EXISTS public._migrations (
    id          serial PRIMARY KEY,
    version_id  bigint  NOT NULL,
    is_applied  boolean NOT NULL,
    tstamp      timestamp NULL DEFAULT now()
);
SQL
clone_psql -c "INSERT INTO public._migrations (version_id, is_applied)
               SELECT 0, true WHERE NOT EXISTS (SELECT 1 FROM public._migrations WHERE version_id = 0);"
for v in $versions; do
    clone_psql -qc "INSERT INTO public._migrations (version_id, is_applied)
                    SELECT ${v}, true
                    WHERE NOT EXISTS (SELECT 1 FROM public._migrations WHERE version_id = ${v});"
done
echo "stamped version: $(clone_psql -tAc 'SELECT max(version_id) FROM public._migrations;')"

echo "--- 4/5 applying the remaining migrations ---"
POSTGRES_CONNECTION_STRING="postgresql://${DB_USER}:${DB_PASSWORD}@${CLONE_HOST}:${DB_PORT}/${DB_NAME}" \
    make -C "$REPO_ROOT/packages/db" migrate

echo "--- 5/5 post-migration checks ---"
echo "final version: $(clone_psql -tAc 'SELECT max(version_id) FROM public._migrations;')"
echo
echo "tables with row-level security still enabled:"
clone_psql -c "SELECT relname FROM pg_class c
               JOIN pg_namespace n ON n.oid = c.relnamespace
               WHERE n.nspname = 'public' AND c.relrowsecurity
               ORDER BY relname;"
echo "row counts on the core tables (must be non-zero where they were before):"
clone_psql -c "SELECT 'teams' AS t, count(*) FROM teams
               UNION ALL SELECT 'envs', count(*) FROM envs
               UNION ALL SELECT 'env_builds', count(*) FROM env_builds
               UNION ALL SELECT 'team_api_keys', count(*) FROM team_api_keys;"

cat <<EOF

=== Rehearsal complete ===
Delete the clone and snapshot when you are done:
  aws rds delete-db-instance --db-instance-identifier ${CLONE_ID}-instance --skip-final-snapshot
  aws rds delete-db-cluster  --db-cluster-identifier ${CLONE_ID} --skip-final-snapshot
  aws rds delete-db-cluster-snapshot --db-cluster-snapshot-identifier ${SNAPSHOT_ID}
EOF
