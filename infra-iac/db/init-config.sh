#!/bin/bash

# Set LC_ALL=C to avoid character encoding issues
export LC_ALL=C

# Generate UUID format teamId
generate_uuid() {
    if command -v uuidgen &> /dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        # Use a more reliable method to generate UUID
        printf '%04x%04x-%04x-%04x-%04x-%04x%04x%04x\n' \
            $((RANDOM%65536)) $((RANDOM%65536)) \
            $((RANDOM%65536)) \
            $(((RANDOM%16384)+16384)) \
            $(((RANDOM%16384)+32768)) \
            $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536))
    fi
}

# Generate random accessToken (format: sk_e2b_ followed by 32 random chars)
generate_access_token() {
    local chars="abcdefghijklmnopqrstuvwxyz0123456789"
    local token="sk_e2b_"

    for i in {1..32}; do
        token="${token}${chars:$(( RANDOM % ${#chars} )):1}"
    done

    echo "$token"
}

# Generate random teamApiKey (format: e2b_ followed by 32 random chars)
generate_team_api_key() {
    local chars="abcdefghijklmnopqrstuvwxyz0123456789"
    local key="e2b_"

    for i in {1..32}; do
        key="${key}${chars:$(( RANDOM % ${#chars} )):1}"
    done

    echo "$key"
}

AWSREGION=$(grep "^AWSREGION=" /opt/config.properties | cut -d'=' -f2)
E2B_CONFIG_SECRET=$(grep "^e2b_config_secret_name=" /opt/config.properties | cut -d'=' -f2)

if [ -z "$E2B_CONFIG_SECRET" ]; then
    echo "Error: e2b_config_secret_name not found in config.properties"
    exit 1
fi

# Idempotency check: skip if SM already has a value
EXISTING=$(aws secretsmanager get-secret-value --secret-id "$E2B_CONFIG_SECRET" \
    --region "$AWSREGION" --query SecretString --output text 2>/dev/null)
if [ -n "$EXISTING" ] && [ "$EXISTING" != "null" ]; then
    echo "E2B config already exists in Secrets Manager, skipping generation"
    exit 0
fi

# Generate random values
TEAM_ID=$(generate_uuid)
ACCESS_TOKEN=$(generate_access_token)
TEAM_API_KEY=$(generate_team_api_key)

CONFIG_JSON=$(cat <<EOF
{
    "email": "e2b@example.com",
    "teamId": "$TEAM_ID",
    "accessToken": "$ACCESS_TOKEN",
    "teamApiKey": "$TEAM_API_KEY",
    "cloud": "aws",
    "region": "$AWSREGION"
}
EOF
)

aws secretsmanager put-secret-value \
    --secret-id "$E2B_CONFIG_SECRET" \
    --secret-string "$CONFIG_JSON" \
    --region "$AWSREGION"

if [ $? -eq 0 ]; then
    echo "E2B config written to Secrets Manager successfully"
else
    echo "Error: Failed to write E2B config to Secrets Manager"
    exit 1
fi
