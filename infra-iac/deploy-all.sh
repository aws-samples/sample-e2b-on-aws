#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

STACK_NAME="${1:?Usage: $0 <CloudFormation-StackName>}"
touch /tmp/e2b.log
echo "StackName=$STACK_NAME" > /tmp/e2b.log
BUILD=$(git rev-parse --short HEAD)
echo "BUILD=$BUILD" >> /tmp/e2b.log

echo "=== Step 0: Install Prerequisites ==="

# Architecture detection
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  BUILDX_ARCH="amd64"; AWS_ARCH="x86_64"; HC_ARCH="amd64" ;;
  aarch64) BUILDX_ARCH="arm64"; AWS_ARCH="aarch64"; HC_ARCH="arm64" ;;
  *) echo "Error: Unsupported architecture $ARCH"; exit 1 ;;
esac

# Wait for apt locks (reused from packer/main.pkr.hcl)
wait_apt_lock() {
  for i in $(seq 1 60); do
    if sudo fuser /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; then
      echo "Apt lock held, waiting... ($i/60)"; sleep 5
    else
      break
    fi
  done
}

# apt packages
wait_apt_lock
sudo apt-get update -y
sudo apt-get install -y unzip docker.io make jq git postgresql-client-common postgresql-client

# Go via snap
command -v go &>/dev/null || sudo snap install go --classic

# Docker service + user group
sudo systemctl start docker
sudo usermod -aG docker $USER || true

# Docker Buildx v0.21.1
if ! docker buildx version &>/dev/null; then
  mkdir -p ~/.docker/cli-plugins
  wget -q "https://github.com/docker/buildx/releases/download/v0.21.1/buildx-v0.21.1.linux-${BUILDX_ARCH}" \
    -O ~/.docker/cli-plugins/docker-buildx
  chmod +x ~/.docker/cli-plugins/docker-buildx
fi

# AWS CLI v2
if ! command -v aws &>/dev/null; then
  curl -s "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp && sudo /tmp/aws/install && rm -rf /tmp/aws /tmp/awscliv2.zip
fi

# Packer 1.12.0
if ! command -v packer &>/dev/null; then
  wget -q "https://releases.hashicorp.com/packer/1.12.0/packer_1.12.0_linux_${HC_ARCH}.zip" -O /tmp/packer.zip
  unzip -q /tmp/packer.zip -d /tmp && sudo mv /tmp/packer /usr/local/bin/ && rm /tmp/packer.zip
fi

# Terraform 1.5.7
if ! command -v terraform &>/dev/null; then
  wget -q "https://releases.hashicorp.com/terraform/1.5.7/terraform_1.5.7_linux_${HC_ARCH}.zip" -O /tmp/terraform.zip
  unzip -q /tmp/terraform.zip -d /tmp && sudo mv /tmp/terraform /usr/local/bin/ && rm /tmp/terraform.zip
fi

# Nomad 1.6.2
if ! command -v nomad &>/dev/null; then
  wget -q "https://releases.hashicorp.com/nomad/1.6.2/nomad_1.6.2_linux_${HC_ARCH}.zip" -O /tmp/nomad.zip
  unzip -q /tmp/nomad.zip -d /tmp && sudo mv /tmp/nomad /usr/local/bin/ && rm /tmp/nomad.zip
fi

# Configure AWS CLI default region
REGION=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --query "Stacks[0].StackId" --output text 2>/dev/null | cut -d: -f4)
if [ -n "$REGION" ]; then
  aws configure set region "$REGION"
fi

# Verify all required commands
for cmd in aws terraform packer nomad go docker make jq git; do
  command -v $cmd &>/dev/null || { echo "Error: $cmd not found after installation"; exit 1; }
done

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
