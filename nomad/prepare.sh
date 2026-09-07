#!/bin/bash

# Navigate to the directory containing the script
cd "$(dirname "$0")"

# Create deploy directory if it doesn't exist
mkdir -p deploy

# Source the configuration properties file to make variables available
# Names of every variable envsubst is allowed to replace. Anything not in this
# list is left untouched in the output, which is what keeps Nomad's own
# interpolations intact.
SUBST_KEYS=()

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
            SUBST_KEYS+=("$key")
        fi
    done < /opt/config.properties
    echo "Loaded configuration from /opt/config.properties"
else
    echo "Error: Configuration file /opt/config.properties not found"
    exit 1
fi

# Read all database credentials from Secrets Manager (only in memory, not written to config file)
DB_CREDENTIAL_SECRET=$(grep "^CFNDBCredentialSecretName=" /opt/config.properties | cut -d'=' -f2)
if [ -n "$DB_CREDENTIAL_SECRET" ]; then
    DB_SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$DB_CREDENTIAL_SECRET" --query SecretString --output text)
    DB_HOST=$(echo "$DB_SECRET_JSON" | jq -r '.host')
    DB_PORT=$(echo "$DB_SECRET_JSON" | jq -r '.port')
    DB_NAME=$(echo "$DB_SECRET_JSON" | jq -r '.dbname')
    DB_USER=$(echo "$DB_SECRET_JSON" | jq -r '.username')
    DB_PASS=$(echo "$DB_SECRET_JSON" | jq -r '.password')
    export postgres_password="$DB_PASS"
    export postgres_host="$DB_HOST"
    export postgres_user="$DB_USER"
    export CFNDBURL="postgresql://${DB_USER}:${DB_PASS}@${DB_HOST}/${DB_NAME}"
fi

# ElastiCache Serverless only accepts TLS connections, and the shared Redis
# client (packages/shared/pkg/factories/redis.go) pins the server certificate
# against this CA bundle instead of the system trust store. Without it the
# client falls back to a plaintext dial and every Redis call fails.
REDIS_CA_B64=$(curl -fsSL https://www.amazontrust.com/repository/AmazonRootCA1.pem | base64 | tr -d '\n')
if [ -z "$REDIS_CA_B64" ]; then
    echo "Error: failed to download the Amazon Root CA needed for Redis TLS"
    exit 1
fi
export REDIS_CA_B64

# The API expects VOLUME_TOKEN_SIGNING_KEY as "HMAC:<base64 key>".
VOLUME_TOKEN_KEY=$(grep "^volume_token_key=" /opt/config.properties | cut -d'=' -f2-)
if [ -z "$VOLUME_TOKEN_KEY" ]; then
    echo "Error: volume_token_key missing from /opt/config.properties"
    exit 1
fi
export VOLUME_TOKEN_KEY_B64=$(printf '%s' "$VOLUME_TOKEN_KEY" | base64 | tr -d '\n')

# Customer OTel forwarding. All three are optional and defaulted to empty here
# rather than required in the config file, because an absent key is worse than an
# empty one: envsubst only substitutes keys it was given, so a missing
# otel_customer_header_name would survive into the rendered HCL as the literal
# string "${otel_customer_header_name}", and the Go template condition in
# otel-collector.hcl would read that as a set header and emit a headers block
# keyed by the placeholder. Empty means the block is skipped.
#
# An empty endpoint still fails the collector on purpose - forwarding nowhere is
# a misconfiguration, not a default - which is why it is not given a fallback
# value here either.
export otel_customer_endpoint="${otel_customer_endpoint:-}"
export otel_customer_header_name="${otel_customer_header_name:-}"
export otel_customer_header_value="${otel_customer_header_value:-}"

# The snapshot retention job ships as a dry run: it logs what it would delete
# and touches nothing. Add RETENTION_APPLY=true to /opt/config.properties, then
# re-run prepare and `nomad/deploy.sh snapshot-retention`, to let it delete.
export RETENTION_APPLY="${RETENTION_APPLY:-false}"

# Derived above rather than read from the config file.
SUBST_KEYS+=(postgres_password postgres_host postgres_user CFNDBURL REDIS_CA_B64 VOLUME_TOKEN_KEY_B64)
SUBST_KEYS+=(otel_customer_endpoint otel_customer_header_name otel_customer_header_value)
SUBST_KEYS+=(RETENTION_APPLY)

# Process each HCL file in the origin directory.
#
# envsubst is given an explicit shell-format list so it only ever touches the
# variables above. Everything else - including Nomad's own interpolations, both
# the dotted ones (${node.unique.id}) and the plain identifiers
# (${NOMAD_PORT_health}) - passes through untouched for Nomad to resolve at
# scheduling time.
#
# Do NOT write those as $${...}: GNU envsubst has no $$ escape. With an
# unrestricted envsubst it reads the first $ as a literal and then substitutes
# ${NOMAD_PORT_health}, which is unset here, so the whole token collapses to a
# bare "$" - and it does so silently, because the result no longer contains
# "${" for a grep to find.
SHELL_FORMAT=$(printf '${%s}' "${SUBST_KEYS[@]}")

for file in origin/*.hcl; do
    if [[ -f "$file" && "$file" != *"-deploy.hcl" ]]; then
        filename=$(basename "$file")
        output_file="deploy/${filename%.*}-deploy.hcl"

        envsubst "$SHELL_FORMAT" < "$file" > "$output_file"
        echo "Generated $output_file"
    fi
done

# Guard against the collapse described above, plus any leftover $$ from the old
# convention. Both are silent at render time and only surface as a service
# crash-looping on an unparsable config.
if grep -Hn -E '=[[:space:]]*"\$"' deploy/*.hcl; then
    echo "Error: the tokens above rendered to a bare \"\$\". Write Nomad" >&2
    echo "       interpolations as \${NAME}, not \$\${NAME}." >&2
    exit 1
fi

if grep -Hn '\$\$' deploy/*.hcl; then
    echo "Error: leftover \$\$ in the rendered output; see the comment in this" >&2
    echo "       script about envsubst not having a \$\$ escape." >&2
    exit 1
fi

echo "Deployment files generation completed"
