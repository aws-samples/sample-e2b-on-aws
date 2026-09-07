#!/bin/bash
# Build every E2B artifact and publish it where the Nomad jobs expect to find it.
#
# This drives the upstream per-package Makefiles rather than reimplementing the
# builds, so the api/db-migrator pair keeps being produced by the same
# docker-bake definition (which bakes in EXPECTED_MIGRATION_TIMESTAMP - the api
# refuses to start against an older schema, so a hand-rolled build would drift).
#
# Two variables redirect upstream's publish paths onto this deployment's layout:
#
#   AWS_BUCKET_PREFIX  Upstream appends "fc-env-pipeline/<binary>" to it. Setting
#                      it to "<unified bucket>/" lands the binaries at
#                      s3://<bucket>/fc-env-pipeline/... which is exactly the
#                      prefix start-client.sh mounts at /fc-envd.
#   PREFIX             Upstream appends "core" to it for the container registry,
#                      giving <acct>.dkr.ecr.<region>.amazonaws.com/e2b-core/...
#                      That matches the e2b-* ECR patterns in the instance IAM
#                      policy and the image references in nomad/origin/*.hcl.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT=$(pwd)

CONFIG_FILE=/opt/config.properties
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: $CONFIG_FILE not found; run infra-iac/init.sh first."
    exit 1
fi

cfg() { grep "^$1=" "$CONFIG_FILE" | head -1 | cut -d'=' -f2-; }

AWS_ACCOUNT_ID=$(cfg account_id)
AWS_REGION=$(cfg AWSREGION)
BUCKET_E2B=$(cfg BUCKET_E2B)

for name in AWS_ACCOUNT_ID AWS_REGION BUCKET_E2B; do
    if [ -z "${!name}" ]; then
        echo "Error: $name missing from $CONFIG_FILE"
        exit 1
    fi
done

# The bastion authenticates through its instance profile. The upstream upload
# targets pass --profile unconditionally, so the value has to name a real
# profile; the CloudFormation user data creates "default" via `aws configure`.
export AWS_PROFILE=${AWS_PROFILE:-default}
export AWS_ACCOUNT_ID AWS_REGION
export PROVIDER=aws
export PREFIX=e2b-
export AWS_BUCKET_PREFIX="${BUCKET_E2B}/"

ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "=== Build configuration ==="
echo "  registry     : ${ECR_REGISTRY}/${PREFIX}core"
echo "  binary target: s3://${AWS_BUCKET_PREFIX}fc-env-pipeline/"

# ECR repositories are not managed by Terraform here, so create them on demand.
for repo in "${PREFIX}core/api" "${PREFIX}core/db-migrator" "${PREFIX}core/client-proxy"; do
    if ! aws ecr describe-repositories --repository-names "$repo" --region "$AWS_REGION" >/dev/null 2>&1; then
        echo "Creating ECR repository $repo"
        aws ecr create-repository --repository-name "$repo" --region "$AWS_REGION" >/dev/null
    fi
done

echo "=== Logging in to ECR ==="
aws ecr get-login-password --region "$AWS_REGION" \
    | docker login --username AWS --password-stdin "$ECR_REGISTRY"

docker buildx install || true

# api and db-migrator are baked together from packages/api/docker-bake.hcl.
echo "=== api + db-migrator ==="
make -C "$REPO_ROOT/packages/api" build-and-upload

echo "=== client-proxy ==="
make -C "$REPO_ROOT/packages/client-proxy" build-and-upload

# orchestrator and template-manager are the same binary published under two
# names; envd is baked into sandbox templates.
echo "=== orchestrator ==="
make -C "$REPO_ROOT/packages/orchestrator" build-and-upload/orchestrator

echo "=== template-manager ==="
make -C "$REPO_ROOT/packages/orchestrator" build-and-upload/template-manager

# snapshot-retention is this deployment's own tool (tools/, not vendored). It is
# published next to the upstream binaries, where
# nomad/origin/snapshot-retention.hcl fetches it from.
echo "=== snapshot-retention ==="
make -C "$REPO_ROOT/tools/snapshot-retention" build-and-upload

echo "=== envd ==="
make -C "$REPO_ROOT/packages/envd" build-and-upload

echo "=== Publishing kernel, Firecracker and busybox artifacts ==="
bash "$REPO_ROOT/tools/legacy/upload.sh"

echo "=== All builds and uploads completed successfully ==="
