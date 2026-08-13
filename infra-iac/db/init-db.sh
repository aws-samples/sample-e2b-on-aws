#!/bin/bash
# init-db.sh - One-click database initialization (schema migration + seed data)
#
# Schema is owned by goose (packages/db/migrations, tracking table _migrations),
# not by the flattened .migration.sql that used to live here. That file stopped
# at 20250624001049 and, more importantly, never wrote a row into _migrations, so
# goose would see version 0 and try to replay every migration against tables that
# already exist. See ./stamp-baseline.sh for upgrading a database that was
# created the old way.

set -e

# Change to the directory of the script
cd "$(dirname "$0")"

REPO_ROOT=$(cd ../.. && pwd)
CONFIG_PATH="./config.json"
CONFIG_FILE="/opt/config.properties"


# First, execute init-config.sh to generate configuration
echo "Generating configuration file..."
if [ -f "./init-config.sh" ]; then
    bash ./init-config.sh
    if [ $? -ne 0 ]; then
        echo "Error: Failed to generate configuration"
        exit 1
    fi
    echo "Configuration generated successfully!"
else
    echo "Error: init-config.sh not found"
    exit 1
fi
# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file $CONFIG_FILE does not exist"
    exit 1
fi

# Read all database connection information from Secrets Manager
DB_CREDENTIAL_SECRET=$(grep "^CFNDBCredentialSecretName=" "$CONFIG_FILE" | cut -d'=' -f2)
DB_SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$DB_CREDENTIAL_SECRET" --query SecretString --output text)
DB_HOST=$(echo "$DB_SECRET_JSON" | jq -r '.host')
DB_PORT=$(echo "$DB_SECRET_JSON" | jq -r '.port')
DB_NAME=$(echo "$DB_SECRET_JSON" | jq -r '.dbname')
DB_USER=$(echo "$DB_SECRET_JSON" | jq -r '.username')
DB_PASSWORD=$(echo "$DB_SECRET_JSON" | jq -r '.password')

# Check if all database variables are set
for VAR_NAME in DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD; do
    VAR_VALUE=${!VAR_NAME}
    if [ -z "$VAR_VALUE" ]; then
        echo "Error: $VAR_NAME variable is missing in the configuration file"
        exit 1
    fi
    echo "Using $VAR_NAME = $VAR_VALUE"
done

# Read configuration file
echo "Reading information from configuration file..."
if command -v jq &> /dev/null; then
    email=$(jq -r '.email' "$CONFIG_PATH")
else
    echo "Warning: jq tool not found"
    exit 1
fi

# Check database connection
if ! PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -c '\q' &>/dev/null; then
    echo "Error: Cannot connect to PostgreSQL database server. Please check connection parameters."
    exit 1
fi

# Step 1: Apply schema migrations with goose.
#
# A database created by the old flattened .migration.sql has the tables but an
# empty/absent _migrations table, so goose would replay everything and fail on
# the first CREATE TABLE. Refuse to guess: tell the operator to stamp first.
export POSTGRES_CONNECTION_STRING="postgresql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}"

TABLE_EXISTS=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc \
    "SELECT to_regclass('public.teams') IS NOT NULL")
MIGRATIONS_TRACKED=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc \
    "SELECT to_regclass('public._migrations') IS NOT NULL")

if [ "$TABLE_EXISTS" = "t" ] && [ "$MIGRATIONS_TRACKED" != "t" ]; then
    echo "Error: this database already has E2B tables but no _migrations tracking table."
    echo "       It was created by the pre-sync flattened .migration.sql."
    echo "       Run ./stamp-baseline.sh once to record the migrations it already"
    echo "       contains, then re-run this script."
    exit 1
fi

# Provision the one role the upstream migrations reference but never create.
#
# Upstream runs against a Supabase-provisioned database, where a "postgres" role
# already exists. On a fresh Aurora cluster the master user is whatever
# DBUsername the stack was created with, so that role is absent and the very
# first migration (20000101000000_auth.sql) dies on
#   GRANT EXECUTE ON FUNCTION auth.uid() TO postgres
# with 'role "postgres" does not exist'.
#
# trigger_user is deliberately NOT created here: 20231220094836 creates it
# itself with CREATE USER, and pre-creating it makes that migration fail with
# 'role "trigger_user" already exists'.
#
# This belongs here rather than in packages/db/migrations: that tree is a
# byte-for-byte copy of upstream and gets overwritten on the next code sync.
echo "Ensuring upstream-assumed database roles exist..."
PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
    -v ON_ERROR_STOP=1 -q <<SQL
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'postgres') THEN
        CREATE ROLE postgres NOLOGIN;
    END IF;
END
\$\$;
SQL
echo "Roles ready."

echo "Applying schema migrations with goose..."
make -C "$REPO_ROOT/packages/db" migrate
echo "Schema migrations applied successfully!"

# Step 2: Seed the initial user, team, access token and team API key.
#
# This delegates to upstream's own seeder instead of the flattened
# .seed-db.sql we used to run. Two reasons:
#
#   1. The plaintext columns it wrote are gone. access_tokens and
#      team_api_keys now store only access_token_hash / api_key_hash plus
#      prefix, length and mask columns, all NOT NULL. The hash is computed by
#      packages/shared/pkg/keys, so reproducing it in SQL would mean
#      re-implementing (and then re-verifying on every sync) key derivation
#      that upstream already owns.
#   2. The old "seed only when teams is empty" guard can never fire: the
#      migrations themselves now provision a system@e2b.dev team, so a freshly
#      migrated database always has exactly one team.
#
# The seeder is idempotent - it deletes everything belonging to the email
# before re-inserting - so it runs unconditionally. It prompts for the email on
# stdin and generates the team id and both keys itself, printing them; the
# values are parsed back out and written to config.json, which
# tools/legacy/create_template.sh reads.
echo "Seeding initial user and team via upstream seeder..."
SEED_OUTPUT=$(echo "$email" | make -s -C "$REPO_ROOT/packages/db" seed-db 2>&1)
SEED_RC=$?
echo "$SEED_OUTPUT"
if [ $SEED_RC -ne 0 ]; then
    echo "Error: Data population failed"
    exit 1
fi

# The seeder deletes the previous team's envs, but env_builds has no foreign key
# to envs, so re-seeding a populated database leaves one unreachable env_builds
# row per template that ever existed. Harmless but it accumulates on every
# re-seed and makes the counts misleading when debugging. Only rows whose env is
# already gone are touched.
ORPHANS=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc \
    "DELETE FROM env_builds b WHERE NOT EXISTS (SELECT 1 FROM envs e WHERE e.id = b.env_id) RETURNING 1" 2>/dev/null | wc -l)
if [ "${ORPHANS:-0}" -gt 0 ]; then
    echo "Removed $ORPHANS orphaned env_builds row(s) left behind by the reseed."
fi

teamId=$(echo "$SEED_OUTPUT" | grep -oP 'Team ID:\s*\K[0-9a-f-]+' | head -1)
accessToken=$(echo "$SEED_OUTPUT" | grep -oP 'Access Token:\s*\K\S+' | head -1)
teamApiKey=$(echo "$SEED_OUTPUT" | grep -oP 'Team API Key:\s*\K\S+' | head -1)

for VAR_NAME in teamId accessToken teamApiKey; do
    if [ -z "${!VAR_NAME}" ]; then
        echo "Error: could not parse $VAR_NAME out of the seeder output"
        exit 1
    fi
done

# Write the real credentials back into config.json.
jq --arg teamId "$teamId" \
   --arg accessToken "$accessToken" \
   --arg teamApiKey "$teamApiKey" \
   '. + {teamId: $teamId, accessToken: $accessToken, teamApiKey: $teamApiKey}' \
   "$CONFIG_PATH" > "$CONFIG_PATH.tmp" && mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"

# Refresh the credential block in the shared config file. Rewritten rather than
# appended so re-running this script does not stack up stale copies.
sed -i '/^# E2B配置$/,$d' "$CONFIG_FILE"
cat << EOF >> "$CONFIG_FILE"
# E2B配置
teamId=$teamId
accessToken=$accessToken
teamApiKey=$teamApiKey
EOF

echo "Database initialization completed!"

echo "==================="
echo "User: $email"
echo "Team ID: $teamId"
echo "Access Token: $accessToken"
echo "Team API Key: $teamApiKey"
echo "export E2B_API_KEY=$teamApiKey"
echo "export E2B_ACCESS_TOKEN=$accessToken"
