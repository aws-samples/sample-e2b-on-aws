#!/bin/bash
# Set error handling - script will exit if any command fails
set -e

# Navigate to the directory containing the script
cd "$(dirname "$0")"

# Define project root directory (adjust according to actual situation)
PROJECT_ROOT=$(pwd)
echo "Project root directory: $PROJECT_ROOT"

CONFIG_FILE="/opt/config.properties"
if [ -f "$CONFIG_FILE" ]; then
  JFROG_ARTIFACTORY_URL=$(grep -E "^(jfrog_artifactory_url|JFROGARTIFACTORYURL)=" "$CONFIG_FILE" | tail -n 1 | cut -d= -f2-)
  JFROG_ARTIFACTORY_URL="${JFROG_ARTIFACTORY_URL:-https://artifactory.aic.aws.zoomdev.us/artifactory}"
  JFROG_ARTIFACTORY_URL="${JFROG_ARTIFACTORY_URL%/}"
  export JFROG_ARTIFACTORY_URL
  export GOPROXY="${JFROG_ARTIFACTORY_URL}/api/go/zoom-go-virtual"
  echo "Using GOPROXY: $GOPROXY"
fi

# Build and upload API module
echo "=== Building and uploading API module ==="
cd "$PROJECT_ROOT/api" || { echo "API directory not found"; exit 1; }
echo "Current directory: $(pwd)"
make build-and-upload-aws
echo "API module build and upload completed successfully"

# Build and upload client-proxy module
echo "=== Building and uploading client-proxy module ==="
cd "$PROJECT_ROOT/client-proxy" || { echo "client-proxy directory not found"; exit 1; }
echo "Current directory: $(pwd)"
make build-and-upload-aws
echo "client-proxy module build and upload completed successfully"

# Build and upload docker-reverse-proxy module
echo "=== Building and uploading docker-reverse-proxy module ==="
cd "$PROJECT_ROOT/docker-reverse-proxy" || { echo "docker-reverse-proxy directory not found"; exit 1; }
echo "Current directory: $(pwd)"
make build-and-upload-aws
echo "docker-reverse-proxy module build and upload completed successfully"

# Build and upload orchestrator module
echo "=== Building and uploading orchestrator module ==="
cd "$PROJECT_ROOT/orchestrator" || { echo "orchestrator directory not found"; exit 1; }
echo "Current directory: $(pwd)"
make build-and-upload
echo "orchestrator module build and upload completed successfully"

# Build and upload envd module
echo "=== Building envd module ==="
cd "$PROJECT_ROOT/envd" || { echo "envd directory not found"; exit 1; }
echo "Current directory: $(pwd)"
make build-and-upload
echo "envd module build-and-upload completed successfully"

# Upload other required files
echo "=== Uploading required files ==="
cd "$PROJECT_ROOT" || { echo "Cannot return to project root"; exit 1; }
echo "Current directory: $(pwd)"
bash ./upload.sh
echo "envd upload completed successfully"

echo "=== All builds and uploads completed successfully ==="
