#!/bin/bash

# Default Dockerfile
DOCKERFILE="FROM e2bdev/code-interpreter:latest"
DOCKER_IMAGE="e2bdev/code-interpreter:latest"
CREATE_TYPE="default"
ECR_IMAGE=""
START_COMMAND="/root/.jupyter/start-up.sh"
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

# Read JSON configuration from ./../infra-iac/initdb/config.json
CONFIG_FILE="./../infra-iac/db/config.json"
if [ -f "$CONFIG_FILE" ]; then
    # Check if jq is installed
    if command -v jq &> /dev/null; then
        ACCESS_TOKEN=$(jq -r '.accessToken' "$CONFIG_FILE")
    else
        # Fallback to grep and sed if jq is not available
        ACCESS_TOKEN=$(grep -o '"accessToken": *"[^"]*"' "$CONFIG_FILE" | sed 's/"accessToken": *"\([^"]*\)"/\1/')
    fi
    
    echo "Found accessToken: $ACCESS_TOKEN"
else
    echo "Error: Configuration file $CONFIG_FILE not found"
    exit 1
fi

# Make the POST request
echo "Making POST request to https://api.$CFNDOMAIN/templates with token $ACCESS_TOKEN"

RESPONSE=$(curl -s -X POST \
 "https://api.$CFNDOMAIN/templates" \
 -H "Authorization: $ACCESS_TOKEN" \
 -H 'Content-Type: application/json' \
 -d "{
 \"readyCmd\": \"$READY_COMMAND\",
 \"startCmd\": \"$START_COMMAND\",
 \"dockerfile\": \"$DOCKERFILE\",
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

# Create base ECR repository
echo "Creating ECR repository e2bdev/base/$TEMPLATE_ID..."
aws ecr create-repository --repository-name e2bdev/base/$TEMPLATE_ID --region $AWSREGION || true
if [ $? -ne 0 ]; then
    echo "Note: Repository may already exist or there was an error"
fi

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
BASE_ECR_REPOSITORY="$ECR_DOMAIN/e2bdev/base/$TEMPLATE_ID:$BUILD_ID"
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

# Notify the API that the build is complete
echo "Notifying API that the build is complete..."
BUILD_COMPLETE_RESPONSE=$(curl -s -X POST \
  "https://api.$CFNDOMAIN/templates/$TEMPLATE_ID/builds/$BUILD_ID" \
  -H "Authorization: $ACCESS_TOKEN" \
  -H 'Content-Type: application/json')

echo "Build completion notification response:"
echo "$BUILD_COMPLETE_RESPONSE"

# Poll build status every 10 seconds until it's no longer "building"
echo "Polling build status every 10 seconds until completion..."
while true; do
    FINAL_BUILD_STATUS_RESPONSE=$(curl -s \
      "https://api.$CFNDOMAIN/templates/$TEMPLATE_ID/builds/$BUILD_ID/status" \
      -H "Authorization: $ACCESS_TOKEN")
    
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
        echo "Done!"
        break
    fi

    sleep 10
done

echo "Building completed successfully!"