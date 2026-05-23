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

IMAGE_TAG=$(git rev-parse --short HEAD)
export IMAGE_TAG
echo "Using IMAGE_TAG: $IMAGE_TAG"

API_COUNT="${API_COUNT:-2}"
export API_COUNT
echo "Using API_COUNT: $API_COUNT"

CLIENT_PROXY_COUNT="${CLIENT_PROXY_COUNT:-2}"
export CLIENT_PROXY_COUNT
echo "Using CLIENT_PROXY_COUNT: $CLIENT_PROXY_COUNT"

SANDBOX_STORAGE_BACKEND="${SANDBOX_STORAGE_BACKEND:-redis}"
export SANDBOX_STORAGE_BACKEND
echo "Using SANDBOX_STORAGE_BACKEND: $SANDBOX_STORAGE_BACKEND"

JFROG_ARTIFACTORY_URL="${jfrog_artifactory_url:-${JFROGARTIFACTORYURL:-https://artifactory.aic.aws.zoomdev.us/artifactory}}"
JFROG_ARTIFACTORY_URL="${JFROG_ARTIFACTORY_URL%/}"
JFROG_DOCKER_REGISTRY="${JFROG_ARTIFACTORY_URL#https://}"
JFROG_DOCKER_REGISTRY="${JFROG_DOCKER_REGISTRY#http://}"
if [[ "$JFROG_DOCKER_REGISTRY" == */artifactory ]]; then
    JFROG_DOCKER_REGISTRY="${JFROG_DOCKER_REGISTRY%/artifactory}/zoom-docker-virtual"
else
    JFROG_DOCKER_REGISTRY="${JFROG_DOCKER_REGISTRY}/zoom-docker-virtual"
fi
export JFROG_ARTIFACTORY_URL JFROG_DOCKER_REGISTRY
echo "Using JFROG_DOCKER_REGISTRY: $JFROG_DOCKER_REGISTRY"

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
