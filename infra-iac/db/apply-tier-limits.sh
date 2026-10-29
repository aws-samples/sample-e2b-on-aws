#!/bin/bash
# apply-tier-limits.sh - Put the base_v1 tier back on this deployment's limits.
#
# Upstream's migrations seed base_v1 with E2B Cloud's free-tier values - 1-hour
# sandboxes, 20 concurrent, 8 vCPU / 8 GiB, 512 MB disk - while this deployment
# has run with the values below since 2025-07 (they used to be written by the
# flattened .migration.sql the goose chain replaced). The migrations are vendored
# and overwritten on every sync, and several of them UPDATE tiers outright, so
# this runs after every place migrations can run:
#
#   - init-db.sh, right after its goose migrate
#   - deploy-all.sh's deploy step, after the api job's db-migrator prestart task
#     has applied whatever a code-layer sync brought in
#
# disk_mb is what the API hands a template build as its free disk
# (packages/api/internal/template/register_build.go). default_free_disk_size_mb
# is not read by the current code, but upstream initialised it from disk_mb when
# it added the column, so it moves with disk_mb to stay what an old database
# upgraded through the same migrations would hold. max_disk_size_mb keeps
# upstream's 25600 - that upgrade path ends there too.
#
# The tier's longest sandbox lifetime bounds snapshot-retention's
# PURGE_DELAY_DAYS (7 days, so 24 hours is fine) and the drain window in
# docs/design/client-node-graceful-scale-in.md.
set -e

CONFIG_FILE="/opt/config.properties"

DB_CREDENTIAL_SECRET=$(grep "^CFNDBCredentialSecretName=" "$CONFIG_FILE" | cut -d'=' -f2)
if [ -z "$DB_CREDENTIAL_SECRET" ]; then
    echo "Error: CFNDBCredentialSecretName is missing from $CONFIG_FILE" >&2
    exit 1
fi
DB_SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$DB_CREDENTIAL_SECRET" --query SecretString --output text)
DB_HOST=$(echo "$DB_SECRET_JSON" | jq -r '.host')
DB_PORT=$(echo "$DB_SECRET_JSON" | jq -r '.port')
DB_NAME=$(echo "$DB_SECRET_JSON" | jq -r '.dbname')
DB_USER=$(echo "$DB_SECRET_JSON" | jq -r '.username')
DB_PASSWORD=$(echo "$DB_SECRET_JSON" | jq -r '.password')

echo "Applying this deployment's base_v1 tier limits on $DB_HOST/$DB_NAME..."
PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
    -v ON_ERROR_STOP=1 -q <<'SQL'
DO $$
BEGIN
    UPDATE public.tiers
    SET max_length_hours          = 24,
        concurrent_instances      = 1000000,
        max_vcpu                  = 32,
        max_ram_mb                = 32768,
        disk_mb                   = 8192,
        default_free_disk_size_mb = 8192
    WHERE id = 'base_v1';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'tier base_v1 not found - the upstream migrations no longer create it';
    END IF;
END
$$;
SQL
echo "Tier limits applied."
