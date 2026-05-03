#!/bin/bash

# Navigate to the directory containing the script
cd "$(dirname "$0")"

# Create deploy directory if it doesn't exist
mkdir -p deploy

# Source the configuration properties file to make variables available
if [[ -f /opt/config.properties ]]; then
    # Use a loop to read each line and export variables
    while read -r line || [[ -n "$line" ]]; do
        if [[ ! "$line" =~ ^[[:space:]]*# && -n "$line" && "$line" == *=* ]]; then
            key="${line%%=*}"
            value="${line#*=}"
            # Remove any leading/trailing whitespace
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            # Export the variable
            export "$key"="$value"
        fi
    done < /opt/config.properties
    echo "Loaded configuration from /opt/config.properties"
else
    echo "Error: Configuration file /opt/config.properties not found"
    exit 1
fi

# Write secrets to files instead of exporting as env vars.
# This prevents secrets from being baked into HCL by envsubst and
# subsequently stored in plaintext in Nomad state (visible via nomad job inspect).
SECRETS_DIR="/opt/e2b/secrets"
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

# Read DB credentials from Secrets Manager -> write to individual files
DB_CREDENTIAL_SECRET=$(grep "^CFNDBCredentialSecretName=" /opt/config.properties | cut -d'=' -f2)
if [ -n "$DB_CREDENTIAL_SECRET" ]; then
    DB_SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$DB_CREDENTIAL_SECRET" --query SecretString --output text)
    DB_HOST=$(echo "$DB_SECRET_JSON" | jq -r '.host')
    DB_PORT=$(echo "$DB_SECRET_JSON" | jq -r '.port')
    DB_NAME=$(echo "$DB_SECRET_JSON" | jq -r '.dbname')
    DB_USER=$(echo "$DB_SECRET_JSON" | jq -r '.username')
    DB_PASS=$(echo "$DB_SECRET_JSON" | jq -r '.password')

    printf '%s' "postgresql://${DB_USER}:${DB_PASS}@${DB_HOST}/${DB_NAME}" > "$SECRETS_DIR/postgres_connection_string"
    printf '%s' "$DB_HOST" > "$SECRETS_DIR/postgres_host"
    printf '%s' "$DB_USER" > "$SECRETS_DIR/postgres_user"
    printf '%s' "$DB_PASS" > "$SECRETS_DIR/postgres_password"
fi

# Read infra tokens from Secrets Manager -> write to individual files
AWSREGION=$(grep "^AWSREGION=" /opt/config.properties | cut -d'=' -f2)
INFRA_TOKENS_SECRET=$(grep "^infra_tokens_secret_name=" /opt/config.properties | cut -d'=' -f2)
if [ -n "$INFRA_TOKENS_SECRET" ]; then
    INFRA_TOKENS_JSON=$(aws secretsmanager get-secret-value --secret-id "$INFRA_TOKENS_SECRET" --region "$AWSREGION" --query SecretString --output text)
    printf '%s' "$(echo "$INFRA_TOKENS_JSON" | jq -r '.nomad_acl_token')" > "$SECRETS_DIR/nomad_acl_token"
    printf '%s' "$(echo "$INFRA_TOKENS_JSON" | jq -r '.consul_http_token')" > "$SECRETS_DIR/consul_http_token"
    printf '%s' "$(echo "$INFRA_TOKENS_JSON" | jq -r '.admin_token')" > "$SECRETS_DIR/admin_token"
    SEED=$(echo "$INFRA_TOKENS_JSON" | jq -r '.sandbox_access_token_hash_seed // empty')
    if [ -z "$SEED" ]; then
        SEED=$(echo "$INFRA_TOKENS_JSON" | jq -r '.admin_token')
    fi
    printf '%s' "$SEED" > "$SECRETS_DIR/sandbox_access_token_hash_seed"
fi

chmod 600 "$SECRETS_DIR"/*

IMAGE_TAG=$(git rev-parse --short HEAD)
export IMAGE_TAG
echo "Using IMAGE_TAG: $IMAGE_TAG"

# Process each HCL file in the origin directory
for file in origin/*.hcl; do
    if [[ -f "$file" && "$file" != *"-deploy.hcl" ]]; then
        filename=$(basename "$file")
        output_file="deploy/${filename%.*}-deploy.hcl"
        
        # Special handling for session-proxy.hcl
        if [[ "$filename" == "session-proxy.hcl" ]]; then
            # Create a temporary file with only aws_az1 and aws_az2 variables
            temp_env_file=$(mktemp)
            echo "aws_az1=$aws_az1" > "$temp_env_file"
            echo "aws_az2=$aws_az2" >> "$temp_env_file"
            
            # Use env command with the temporary environment file
            env -i $(cat "$temp_env_file") envsubst '${aws_az1} ${aws_az2}' < "$file" > "$output_file"
            
            # Remove the temporary file
            rm "$temp_env_file"
            
            echo "Generated $output_file with limited variable substitution (aws_az1, aws_az2 only)"
        else
            # For all other files, use regular envsubst with all variables
            envsubst < "$file" > "$output_file"
            echo "Generated $output_file with full variable substitution"
        fi
    fi
done

chmod 600 deploy/*.hcl
echo "Deployment files generation completed"
