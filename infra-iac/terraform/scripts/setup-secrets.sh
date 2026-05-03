#!/bin/bash
set -euo pipefail

SECRETS_DIR="/opt/e2b/secrets"
AWS_REGION="$1"
DB_CREDENTIAL_SECRET_NAME="$2"
INFRA_TOKENS_SECRET_NAME="$3"

mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

DB_SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$DB_CREDENTIAL_SECRET_NAME" --region "$AWS_REGION" --query SecretString --output text)
DB_HOST=$(echo "$DB_SECRET_JSON" | jq -r '.host')
DB_USER=$(echo "$DB_SECRET_JSON" | jq -r '.username')
DB_PASS=$(echo "$DB_SECRET_JSON" | jq -r '.password')
DB_NAME=$(echo "$DB_SECRET_JSON" | jq -r '.dbname')
printf '%s' "postgresql://${DB_USER}:${DB_PASS}@${DB_HOST}/${DB_NAME}" > "$SECRETS_DIR/postgres_connection_string"
printf '%s' "$DB_HOST" > "$SECRETS_DIR/postgres_host"
printf '%s' "$DB_USER" > "$SECRETS_DIR/postgres_user"
printf '%s' "$DB_PASS" > "$SECRETS_DIR/postgres_password"

INFRA_JSON=$(aws secretsmanager get-secret-value --secret-id "$INFRA_TOKENS_SECRET_NAME" --region "$AWS_REGION" --query SecretString --output text)
printf '%s' "$(echo "$INFRA_JSON" | jq -r '.nomad_acl_token')" > "$SECRETS_DIR/nomad_acl_token"
printf '%s' "$(echo "$INFRA_JSON" | jq -r '.consul_http_token')" > "$SECRETS_DIR/consul_http_token"
printf '%s' "$(echo "$INFRA_JSON" | jq -r '.admin_token')" > "$SECRETS_DIR/admin_token"
SEED=$(echo "$INFRA_JSON" | jq -r '.sandbox_access_token_hash_seed // empty')
[ -z "$SEED" ] && SEED=$(echo "$INFRA_JSON" | jq -r '.admin_token')
printf '%s' "$SEED" > "$SECRETS_DIR/sandbox_access_token_hash_seed"

chmod 600 "$SECRETS_DIR"/*
