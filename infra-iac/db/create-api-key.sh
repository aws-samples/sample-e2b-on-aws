#!/bin/bash
# create-api-key.sh - Generate a new Team API Key for an existing team
set -e

cd "$(dirname "$0")"
CONFIG_FILE="/opt/config.properties"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: $CONFIG_FILE not found"
    exit 1
fi

source "$CONFIG_FILE" 2>/dev/null || true

# Read DB credentials
DB_SECRET=$(aws secretsmanager get-secret-value --secret-id "$CFNDBCredentialSecretName" --region "$AWSREGION" --query SecretString --output text)
DB_HOST=$(echo "$DB_SECRET" | jq -r '.host')
DB_PORT=$(echo "$DB_SECRET" | jq -r '.port')
DB_USER=$(echo "$DB_SECRET" | jq -r '.username')
DB_PASS=$(echo "$DB_SECRET" | jq -r '.password')

# Get team ID (use argument or default from config)
TEAM_ID="${1:-$(grep '^teamId=' $CONFIG_FILE | cut -d= -f2)}"
KEY_NAME="${2:-CLI API Key}"

if [ -z "$TEAM_ID" ]; then
    echo "Usage: $0 [team_id] [key_name]"
    echo ""
    echo "Available teams:"
    PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d e2b \
        -c "SELECT id, name, email FROM teams;" 2>/dev/null
    exit 1
fi

# Generate key: e2b_ + 40 hex chars
AK_HEX=$(openssl rand -hex 20)
API_KEY="e2b_${AK_HEX}"

# Compute SHA-256 hash (matching Go's base64.RawStdEncoding)
API_KEY_HASH=$(echo -n "$AK_HEX" | xxd -r -p | openssl dgst -sha256 -binary | openssl base64 -A | sed 's/=*$//')
API_KEY_HASH="\$sha256\$$API_KEY_HASH"

# Mask values
MASK_PREFIX="${AK_HEX:0:2}"
MASK_SUFFIX="${AK_HEX: -4}"

# Insert into DB
PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d e2b << SQL
INSERT INTO team_api_keys (id, team_id, api_key_hash, api_key_prefix, api_key_length, api_key_mask_prefix, api_key_mask_suffix, name, created_at)
VALUES (gen_random_uuid(), '${TEAM_ID}'::uuid, '${API_KEY_HASH}', 'e2b_', 40, '${MASK_PREFIX}', '${MASK_SUFFIX}', '${KEY_NAME}', CURRENT_TIMESTAMP);
SQL

if [ $? -eq 0 ]; then
    echo ""
    echo "=== API Key Created ==="
    echo "Team ID:  $TEAM_ID"
    echo "Key Name: $KEY_NAME"
    echo "API Key:  $API_KEY"
    echo ""
    echo "Usage:"
    echo "  export E2B_API_KEY=\"$API_KEY\""
    echo "  export E2B_DOMAIN=\"$CFNDOMAIN\""
    echo ""
    echo "NOTE: Save this key now. It cannot be retrieved later (only hash is stored)."
else
    echo "Error: Failed to create API key"
    exit 1
fi
