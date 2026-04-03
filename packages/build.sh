#!/bin/bash
set -e

cd "$(dirname "$0")"
PROJECT_ROOT=$(pwd)

# Read config
source /opt/config.properties 2>/dev/null || true
AWS_ACCOUNT_ID=${account_id}
AWS_REGION=${AWSREGION}
BUCKET_E2B=${BUCKET_E2B}

if [ -z "$AWS_ACCOUNT_ID" ] || [ -z "$AWS_REGION" ]; then
    echo "Error: account_id or AWSREGION not found in /opt/config.properties"
    exit 1
fi

ECR_DOMAIN="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# ECR login
echo "=== ECR Login ==="
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_DOMAIN"

# Ensure ECR repos exist
for repo in e2b-orchestration/api e2b-orchestration/client-proxy docker-reverse-proxy; do
    aws ecr describe-repositories --repository-names "$repo" --region "$AWS_REGION" 2>/dev/null || \
    aws ecr create-repository --repository-name "$repo" --region "$AWS_REGION" 2>/dev/null || true
done

# ============================================================
# Docker images (build context = packages/ root for all)
# ============================================================
echo ""
echo "=== Building API ==="
docker build --platform linux/amd64 \
    -t "${ECR_DOMAIN}/e2b-orchestration/api:latest" \
    -f api/Dockerfile .
docker push "${ECR_DOMAIN}/e2b-orchestration/api:latest"
echo "API done"

echo ""
echo "=== Building client-proxy ==="
docker build --platform linux/amd64 \
    -t "${ECR_DOMAIN}/e2b-orchestration/client-proxy:latest" \
    -f client-proxy/Dockerfile .
docker push "${ECR_DOMAIN}/e2b-orchestration/client-proxy:latest"
echo "client-proxy done"

echo ""
echo "=== Building docker-reverse-proxy ==="
docker build --platform linux/amd64 \
    -t "${ECR_DOMAIN}/docker-reverse-proxy:latest" \
    -f docker-reverse-proxy/Dockerfile .
docker push "${ECR_DOMAIN}/docker-reverse-proxy:latest"
echo "docker-reverse-proxy done"

# ============================================================
# Native binaries → S3
# ============================================================
echo ""
echo "=== Building orchestrator ==="
cd "$PROJECT_ROOT/orchestrator"
make build
aws s3 cp bin/orchestrator "s3://${BUCKET_E2B}/software/orchestrator"
aws s3 cp bin/orchestrator "s3://${BUCKET_E2B}/software/template-manager"
echo "orchestrator done"

echo ""
echo "=== Building envd ==="
cd "$PROJECT_ROOT/envd"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -a -o bin/envd .
aws s3 cp bin/envd "s3://${BUCKET_E2B}/fc-env-pipeline/envd"
echo "envd done"

# ============================================================
# Kernels + Firecracker (from e2b public builds)
# ============================================================
echo ""
echo "=== Uploading kernels & firecracker ==="
cd "$PROJECT_ROOT"
bash ./upload.sh

echo ""
echo "=== All builds and uploads completed ==="
