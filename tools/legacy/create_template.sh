#!/bin/bash

# Default Dockerfile
DOCKERFILE="FROM e2bdev/code-interpreter:latest"
DOCKER_IMAGE="e2bdev/code-interpreter:latest"
CREATE_TYPE="default"
ECR_IMAGE=""
START_COMMAND="sudo /root/.jupyter/start-up.sh"
READY_COMMAND=""

# Parse command line arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --docker-file)
            if [ -f "$2" ]; then
                START_COMMAND=""
                DOCKERFILE=$(cat "$2")
                CREATE_TYPE="dockerfile"
                echo "Will use below Dockerfile to create template: $DOCKERFILE"
                shift 2
            else
                echo "Error: Dockerfile $2 not found"
                exit 1
            fi
            ;;
        --ecr-image)
            START_COMMAND=""
            ECR_IMAGE="$2"
            DOCKERFILE="FROM $2"
            CREATE_TYPE="ecr_image"
            echo "Will use below ECR Image to create template: $ECR_IMAGE"
            shift 2
            ;;
        *)
            echo "Unknown parameter: $1"
            echo "Usage: $0 [--docker-file <dockerfile-path>] [--ecr-image <ecr-image-uri>]"
            exit 1
            ;;
    esac
done

# Change to the directory of the script
cd "$(dirname "$0")"

# This script lives in tools/legacy, so the repository root is two levels up.
REPO_ROOT=$(cd ../.. && pwd)

# Read parameters from /opt/config.properties
if [ -f /opt/config.properties ]; then
    # Use grep to extract variables
    AWSREGION=$(grep -E "^AWSREGION=" /opt/config.properties | cut -d'=' -f2)
    CFNDOMAIN=$(grep -E "^CFNDOMAIN=" /opt/config.properties | cut -d'=' -f2)
    
    echo "Found AWSREGION: $AWSREGION"
    echo "Found CFNDOMAIN: $CFNDOMAIN"
else
    echo "Error: Configuration file /opt/config.properties not found"
    exit 1
fi

# Credentials written by infra-iac/db/init-db.sh after it seeds the database.
# Resolved from the repository root: the script cds into tools/legacy above, so
# the old "./../infra-iac/db/config.json" was one level short and never resolved
# from any working directory.
#
# The team API key, not a user access token: upstream migration 20260823120000
# dropped the access_tokens table, and the v1 POST /templates that took those
# tokens now only accepts an auth-provider bearer token (an external IdP this
# deployment does not run). The /v2 template endpoints below accept
# X-API-Key, which is what makes a self-hosted build work without an IdP.
CONFIG_FILE="$REPO_ROOT/infra-iac/db/config.json"
if [ -f "$CONFIG_FILE" ]; then
    # Check if jq is installed
    if command -v jq &> /dev/null; then
        TEAM_API_KEY=$(jq -r '.teamApiKey' "$CONFIG_FILE")
    else
        # Fallback to grep and sed if jq is not available
        TEAM_API_KEY=$(grep -o '"teamApiKey": *"[^"]*"' "$CONFIG_FILE" | sed 's/"teamApiKey": *"\([^"]*\)"/\1/')
    fi

    if [ -z "$TEAM_API_KEY" ] || [ "$TEAM_API_KEY" = "null" ]; then
        echo "Error: no teamApiKey in $CONFIG_FILE; re-run infra-iac/db/init-db.sh" >&2
        exit 1
    fi
    echo "Found teamApiKey: $TEAM_API_KEY"
else
    echo "Error: Configuration file $CONFIG_FILE not found"
    exit 1
fi

# Wait for the API to answer through the ALB before asking it for anything.
# Running this straight after nomad/deploy.sh is a race: the job is healthy in
# Nomad well before the ALB has finished registering the target and passing its
# own health check, and until then this host gets a connection failure rather
# than an HTTP error. That used to surface five minutes later as
# "invalid reference format" on a docker tag built from an empty build ID.
echo "Waiting for https://api.$CFNDOMAIN/health ..."
API_READY=false
for attempt in $(seq 1 60); do
    if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://api.$CFNDOMAIN/health")" = "200" ]; then
        API_READY=true
        echo "API is reachable after ${attempt} attempt(s)."
        break
    fi
    sleep 5
done
if ! $API_READY; then
    echo "Error: https://api.$CFNDOMAIN/health did not return 200 within 5 minutes." >&2
    echo "       Check the ALB target health for the api target group and that" >&2
    echo "       api.$CFNDOMAIN resolves to the current load balancer." >&2
    exit 1
fi

# Register the template.
#
# /v2/templates rather than /templates: the v1 route is restricted to
# auth-provider bearer tokens, while v2 accepts the team API key. The v2 body
# carries only the shape (alias, cpuCount, memoryMB) - startCmd, readyCmd and
# the base image belong to the build request further down.
echo "Making POST request to https://api.$CFNDOMAIN/v2/templates"

RESPONSE=$(curl -s -X POST \
 "https://api.$CFNDOMAIN/v2/templates" \
 -H "X-API-Key: $TEAM_API_KEY" \
 -H 'Content-Type: application/json' \
 -d "{
 \"alias\": \"test-$(date +%s)\",
 \"memoryMB\": 4096,
 \"cpuCount\": 4
 }")

 echo "Response: $RESPONSE"

# Extract buildID and templateID from response
if command -v jq &> /dev/null; then
    BUILD_ID=$(echo "$RESPONSE" | jq -r '.buildID')
    TEMPLATE_ID=$(echo "$RESPONSE" | jq -r '.templateID')
else
    # Fallback to grep and sed if jq is not available
    BUILD_ID=$(echo "$RESPONSE" | grep -o '"buildID": *"[^"]*"' | sed 's/"buildID": *"\([^"]*\)"/\1/')
    TEMPLATE_ID=$(echo "$RESPONSE" | grep -o '"templateID": *"[^"]*"' | sed 's/"templateID": *"\([^"]*\)"/\1/')
fi

# Stop here rather than carrying an empty ID into the ECR work below, where the
# failure shows up as an unrelated-looking invalid docker reference.
if [ -z "$BUILD_ID" ] || [ "$BUILD_ID" = "null" ] || [ -z "$TEMPLATE_ID" ] || [ "$TEMPLATE_ID" = "null" ]; then
    echo "Error: POST /templates did not return a build and template ID." >&2
    echo "       Response was: ${RESPONSE:-<empty>}" >&2
    exit 1
fi

echo "Response received:"
echo "$RESPONSE"
echo ""
echo "Template creating information:"
echo "buildID: $BUILD_ID"
echo "templateID: $TEMPLATE_ID"

# Get AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if [ $? -ne 0 ]; then
    echo "Error: Failed to get AWS account ID"
    exit 1
fi
echo "AWS Account ID: $AWS_ACCOUNT_ID"

# Execute ECR login command
echo "Logging in to ECR..."
ECR_DOMAIN="$AWS_ACCOUNT_ID.dkr.ecr.$AWSREGION.amazonaws.com"
aws ecr get-login-password --region $AWSREGION | docker login --username AWS --password-stdin $ECR_DOMAIN
if [ $? -ne 0 ]; then
    echo "Error: Failed to login to ECR"
    exit 1
fi

# The template-manager resolves the base image through
# shared/pkg/artifacts-registry/registry_aws.go, which describes exactly one
# repository - AWS_DOCKER_REPOSITORY_NAME, as set in nomad/origin/*.hcl - and
# uses the build ID as the image tag ("for AWS implementation we are using only
# build id as image tag"; GetTag ignores the template ID entirely).
#
# Pushing to a per-template repository instead made every build fail with
# RepositoryNotFoundException on 'e2bdev/base'. Keep this name in sync with
# AWS_DOCKER_REPOSITORY_NAME in the job files.
ECR_REPOSITORY_NAME="e2bdev/base"

echo "Creating ECR repository $ECR_REPOSITORY_NAME..."
aws ecr create-repository --repository-name "$ECR_REPOSITORY_NAME" --region $AWSREGION >/dev/null 2>&1 \
    || echo "Note: repository $ECR_REPOSITORY_NAME already exists"

# Handle different create types
case "$CREATE_TYPE" in
    "dockerfile")
        # Create a temporary directory for Docker build
        TEMP_DIR=$(mktemp -d)
        echo "$DOCKERFILE" > "$TEMP_DIR/Dockerfile"
        
        echo "Building Docker image from Dockerfile..."
        docker build -t temp_image "$TEMP_DIR"
        if [ $? -ne 0 ]; then
            echo "Error: Failed to build Docker image from Dockerfile"
            rm -rf "$TEMP_DIR"
            exit 1
        fi
        rm -rf "$TEMP_DIR"
        BASE_IMAGE="temp_image"
        ;;
        
    "ecr_image")
        echo "Pulling ECR image $ECR_IMAGE..."
        docker pull $ECR_IMAGE
        if [ $? -ne 0 ]; then
            echo "Error: Failed to pull ECR image $ECR_IMAGE"
            exit 1
        fi
        BASE_IMAGE=$ECR_IMAGE
        ;;
        
    "default")
        echo "Pulling default Docker image $DOCKER_IMAGE..."
        docker pull $DOCKER_IMAGE
        if [ $? -ne 0 ]; then
            echo "Error: Failed to pull $DOCKER_IMAGE Docker image"
            exit 1
        fi
        BASE_IMAGE=$DOCKER_IMAGE
        ;;
        
    *)
        echo "Error: Unknown CREATE_TYPE: $CREATE_TYPE"
        exit 1
        ;;
esac

# Tag and push the base image
BASE_ECR_REPOSITORY="$ECR_DOMAIN/$ECR_REPOSITORY_NAME:$BUILD_ID"
echo "Tagging base Docker image as $BASE_ECR_REPOSITORY..."
docker tag $BASE_IMAGE $BASE_ECR_REPOSITORY
if [ $? -ne 0 ]; then
    echo "Error: Failed to tag base Docker image"
    exit 1
fi

echo "Pushing base Docker image to ECR..."
docker push $BASE_ECR_REPOSITORY
if [ $? -ne 0 ]; then
    echo "Error: Failed to push base Docker image to ECR"
    exit 1
fi

echo "Docker images successfully pushed to ECR:"
echo "Base image: $BASE_ECR_REPOSITORY"

# Start the build now that the base image is in ECR.
#
# fromImage is sent as an empty string, which is neither an oversight nor a
# placeholder: it is how a v1 build is requested.
#
#   - api/internal/template-manager/create_template.go treats the field as
#     present when the pointer is non-nil ("hasImage can be empty for v1
#     template builds"), so omitting it entirely fails the request with
#     "must specify either fromImage or fromTemplate".
#   - orchestrator/pkg/template/server/create_template.go then sees an empty
#     FromImage and builds a TemplateV1Version, which resolves the base image
#     through the AWS artifacts registry - AWS_DOCKER_REPOSITORY_NAME tagged
#     with the build ID, exactly what was pushed above.
#
# Passing a real image reference instead would switch the build to the V2 beta
# path, which pulls the image itself and makes that push pointless.
echo "Starting the build..."
BUILD_COMPLETE_RESPONSE=$(curl -s -X POST \
  "https://api.$CFNDOMAIN/v2/templates/$TEMPLATE_ID/builds/$BUILD_ID" \
  -H "X-API-Key: $TEAM_API_KEY" \
  -H 'Content-Type: application/json' \
  -d "{
 \"fromImage\": \"\",
 \"startCmd\": \"$START_COMMAND\",
 \"readyCmd\": \"$READY_COMMAND\"
 }")

echo "Build completion notification response:"
echo "$BUILD_COMPLETE_RESPONSE"

# Poll build status every 10 seconds until it's no longer "building"
echo "Polling build status every 10 seconds until completion..."
while true; do
    FINAL_BUILD_STATUS_RESPONSE=$(curl -s \
      "https://api.$CFNDOMAIN/templates/$TEMPLATE_ID/builds/$BUILD_ID/status" \
      -H "X-API-Key: $TEAM_API_KEY")
    
    # Extract status value
    if command -v jq &> /dev/null; then
        STATUS=$(echo "$FINAL_BUILD_STATUS_RESPONSE" | jq -r '.status')
    else
        # Fallback to grep and sed if jq is not available
        STATUS=$(echo "$FINAL_BUILD_STATUS_RESPONSE" | grep -o '"status": *"[^"]*"' | sed 's/"status": *"\([^"]*\)"/\1/')
    fi
    
    echo "Current building status: $STATUS"

    if [ "$STATUS" != "building" ]; then
        echo "Build is no longer in 'building' state. Final status: $STATUS"
        break
    fi

    sleep 10
done

# Check final build status
if [ "$STATUS" = "error" ] || [ "$STATUS" = "failed" ]; then
    echo "Building failed with status: $STATUS"
    exit 1
elif [ "$STATUS" = "ready" ] || [ "$STATUS" = "success" ]; then
    echo "Building completed successfully!"
else
    echo "Building finished with unknown status: $STATUS"
    exit 1
fi