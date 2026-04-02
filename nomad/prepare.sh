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
            echo "aws_az3=$aws_az3" >> "$temp_env_file"
            echo "aws_az4=$aws_az4" >> "$temp_env_file"
            
            # Use env command with the temporary environment file
            env -i $(cat "$temp_env_file") envsubst '${aws_az1} ${aws_az2} ${aws_az3} ${aws_az4}' < "$file" > "$output_file"
            
            # Remove the temporary file
            rm "$temp_env_file"
            
            echo "Generated $output_file with limited variable substitution (aws_az1, aws_az2, aws_az3, aws_az4 only)"
        else
            # For all other files, use regular envsubst with all variables
            envsubst < "$file" > "$output_file"
            echo "Generated $output_file with full variable substitution"
        fi
    fi
done

echo "Deployment files generation completed"
