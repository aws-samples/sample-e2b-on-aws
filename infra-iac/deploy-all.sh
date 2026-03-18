#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

# Pre-flight checks
for cmd in aws terraform packer nomad go docker make jq; do
  command -v $cmd &>/dev/null || { echo "Error: $cmd not found"; exit 1; }
done

# StackName is required (used by init.sh to fetch CloudFormation outputs)
STACK_NAME="${1:?Usage: $0 <CloudFormation-StackName>}"
touch /tmp/e2b.log
echo "StackName=$STACK_NAME" >> /tmp/e2b.log

echo "=== Step 1: init.sh ==="
bash infra-iac/init.sh

echo "=== Step 2: packer.sh ==="
HOME=/root bash -l infra-iac/packer/packer.sh

echo "=== Step 3: terraform ==="
bash infra-iac/terraform/start.sh

echo "=== Step 4: init-db.sh ==="
bash infra-iac/db/init-db.sh

echo "=== Step 5: build.sh ==="
HOME=/root bash packages/build.sh

echo "=== Step 6: nomad.sh ==="
source nomad/nomad.sh

echo "=== Step 7: prepare.sh ==="
bash nomad/prepare.sh

echo "=== Step 8: deploy.sh ==="
bash nomad/deploy.sh

echo "=== Step 9: create_template.sh ==="
bash packages/create_template.sh

echo "=== E2B Deploy Done! ==="
