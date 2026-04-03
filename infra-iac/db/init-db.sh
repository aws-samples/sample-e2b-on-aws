#!/bin/bash
# init-db.sh - Database initialization: migration + seed
set -e

cd "$(dirname "$0")"

MIGRATION_SQL="./.migration.sql"
SEED_SQL="./.seed-db.sql"
CONFIG_PATH="./config.json"
CONFIG_FILE="/opt/config.properties"

# ============================================================
# Step 1: Generate credentials
# ============================================================
echo "=== Generating credentials ==="
if [ -f "./init-config.sh" ]; then
    bash ./init-config.sh
else
    echo "Error: init-config.sh not found"
    exit 1
fi

# ============================================================
# Step 2: Read DB connection from Secrets Manager
# ============================================================
echo "=== Reading DB credentials ==="
DB_CREDENTIAL_SECRET=$(grep "^CFNDBCredentialSecretName=" "$CONFIG_FILE" | cut -d'=' -f2)
DB_SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$DB_CREDENTIAL_SECRET" --query SecretString --output text)
DB_HOST=$(echo "$DB_SECRET_JSON" | jq -r '.host')
DB_PORT=$(echo "$DB_SECRET_JSON" | jq -r '.port')
DB_NAME=$(echo "$DB_SECRET_JSON" | jq -r '.dbname')
DB_USER=$(echo "$DB_SECRET_JSON" | jq -r '.username')
DB_PASSWORD=$(echo "$DB_SECRET_JSON" | jq -r '.password')

for VAR_NAME in DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD; do
    if [ -z "${!VAR_NAME}" ]; then
        echo "Error: $VAR_NAME is empty"
        exit 1
    fi
done
echo "  DB_HOST=$DB_HOST DB_NAME=$DB_NAME"

PSQL="PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME"

# Test connection
if ! PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c '\q' &>/dev/null; then
    echo "Error: Cannot connect to database"
    exit 1
fi
echo "  DB connection OK"

# ============================================================
# Step 3: Run migration
# ============================================================
echo "=== Running migration ==="
PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -f "$MIGRATION_SQL"
echo "  Migration complete"

# ============================================================
# Step 4: Seed (only if no access tokens exist)
#
# Why check access_tokens instead of teams?
# The migration creates triggers that auto-insert teams when
# auth.users rows exist. So teams may already have rows even
# on a fresh DB. access_tokens is only populated by seed.
# ============================================================
echo "=== Checking if seed is needed ==="
TOKEN_COUNT=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
    -t -c "SELECT COUNT(*) FROM access_tokens;" 2>/dev/null | tr -d ' ')

if [ "$TOKEN_COUNT" = "" ] || [ "$TOKEN_COUNT" = "0" ]; then
    echo "  No tokens found, running seed..."

    # Clean any trigger-created data to avoid conflicts
    PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "
        DELETE FROM users_teams;
        DELETE FROM team_api_keys;
        DELETE FROM access_tokens;
        DELETE FROM envs WHERE id = 'rki5dems9wqfm4r03t7g';
        DELETE FROM teams;
        DELETE FROM users;
    " 2>/dev/null || true

    # Read generated values
    email=$(jq -r '.email' "$CONFIG_PATH")
    teamId=$(jq -r '.teamId' "$CONFIG_PATH")
    accessTokenHash=$(grep "^accessTokenHash=" "$CONFIG_FILE" | cut -d'=' -f2)
    apiKeyHash=$(grep "^apiKeyHash=" "$CONFIG_FILE" | cut -d'=' -f2)
    atMaskPrefix=$(grep "^atMaskPrefix=" "$CONFIG_FILE" | cut -d'=' -f2)
    atMaskSuffix=$(grep "^atMaskSuffix=" "$CONFIG_FILE" | cut -d'=' -f2)
    akMaskPrefix=$(grep "^akMaskPrefix=" "$CONFIG_FILE" | cut -d'=' -f2)
    akMaskSuffix=$(grep "^akMaskSuffix=" "$CONFIG_FILE" | cut -d'=' -f2)

    PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
        -v email="$email" \
        -v teamID="$teamId" \
        -v accessTokenHash="$accessTokenHash" \
        -v apiKeyHash="$apiKeyHash" \
        -v atMaskPrefix="$atMaskPrefix" \
        -v atMaskSuffix="$atMaskSuffix" \
        -v akMaskPrefix="$akMaskPrefix" \
        -v akMaskSuffix="$akMaskSuffix" \
        -f "$SEED_SQL"

    if [ $? -ne 0 ]; then
        echo "Error: Seed failed"
        exit 1
    fi
    echo "  Seed complete"
else
    echo "  Database already seeded ($TOKEN_COUNT tokens found). Skipping."
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "==================="
echo "Database initialization complete!"
echo "==================="
echo "User:         $(jq -r '.email' $CONFIG_PATH)"
echo "Team ID:      $(jq -r '.teamId' $CONFIG_PATH)"
echo "Access Token: $(jq -r '.accessToken' $CONFIG_PATH)"
echo "API Key:      $(jq -r '.teamApiKey' $CONFIG_PATH)"
echo "==================="
