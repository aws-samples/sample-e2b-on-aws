#!/bin/bash
set -e

echo "Starting migration script..."

# Create temporary directory
TEMP_DIR=$(mktemp -d)
echo "Created temporary directory: ${TEMP_DIR}"

# Read configuration file
CONFIG_FILE="/opt/config.properties"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file $CONFIG_FILE does not exist"
    exit 1
fi

# Read bucket information from configuration file
BUCKET_FC_ENV_PIPELINE=$(grep "BUCKET_FC_ENV_PIPELINE" $CONFIG_FILE | cut -d'=' -f2)
BUCKET_FC_KERNELS=$(grep "BUCKET_FC_KERNELS" $CONFIG_FILE | cut -d'=' -f2)
BUCKET_FC_VERSIONS=$(grep "BUCKET_FC_VERSIONS" $CONFIG_FILE | cut -d'=' -f2)

if [ -z "$BUCKET_FC_ENV_PIPELINE" ] || [ -z "$BUCKET_FC_KERNELS" ] || [ -z "$BUCKET_FC_VERSIONS" ]; then
    echo "Error: Could not read all required bucket information from configuration file"
    echo "BUCKET_FC_ENV_PIPELINE: $BUCKET_FC_ENV_PIPELINE"
    echo "BUCKET_FC_KERNELS: $BUCKET_FC_KERNELS"
    echo "BUCKET_FC_VERSIONS: $BUCKET_FC_VERSIONS"
    exit 1
fi

echo "Bucket information read from configuration file:"
echo "BUCKET_FC_ENV_PIPELINE: $BUCKET_FC_ENV_PIPELINE"
echo "BUCKET_FC_KERNELS: $BUCKET_FC_KERNELS"
echo "BUCKET_FC_VERSIONS: $BUCKET_FC_VERSIONS"

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo "Installing AWS CLI..."
    sudo apt-get install -y awscli
    echo "AWS CLI installation completed"
else
    echo "AWS CLI is already installed"
fi

CI_VERSION="v1.10"
KERNEL_VERSION="6.1.102"
KERNEL_FOLDER="vmlinux-${KERNEL_VERSION}"
FC_VERSION="v1.10.1"
FC_FOLDER="v1.10.1_1fcdaec"

# Create subdirectories
mkdir -p "${TEMP_DIR}/kernels/${KERNEL_FOLDER}"
mkdir -p "${TEMP_DIR}/firecrackers/${FC_FOLDER}"

fc_url="https://github.com/firecracker-microvm/firecracker/releases"

ARCHITECTURE=$(grep "^CFNARCHITECTURE=" "$CONFIG_FILE" | cut -d'=' -f2)

# Download kernel and fc
if [ "$ARCHITECTURE" = "arm64" ]; then
    # Download kernel
	curl -L https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/$CI_VERSION/aarch64/vmlinux-$KERNEL_VERSION -o ${TEMP_DIR}/kernels/${KERNEL_FOLDER}/vmlinux.bin
	# Download firecracker
	curl -L ${fc_url}/download/${FC_VERSION}/firecracker-${FC_VERSION}-aarch64.tgz | tar -xz
    mv release-${FC_VERSION}-aarch64/firecracker-${FC_VERSION}-aarch64 \
       ${TEMP_DIR}/firecrackers/${FC_FOLDER}/firecracker
    rm -rf release-${latest_version}-aarch64
else
    # Download kernel
	curl -L https://storage.googleapis.com/e2b-prod-public-builds/kernels/vmlinux-6.1.102/vmlinux.bin -o ${TEMP_DIR}/kernels/${KERNEL_FOLDER}/vmlinux.bin
	# Download firecracker
	curl -L ${fc_url}/download/${FC_VERSION}/firecracker-${FC_VERSION}-x86_64.tgz | tar -xz
    mv release-${FC_VERSION}-x86_64/firecracker-${FC_VERSION}-x86_64 \
       ${TEMP_DIR}/firecrackers/${FC_FOLDER}/firecracker
    rm -rf release-${latest_version}-x86_64
fi

# Upload to S3
echo "Starting file upload to S3..."
aws s3 cp --recursive "${TEMP_DIR}/kernels/" "s3://${BUCKET_FC_KERNELS}/"
aws s3 cp --recursive "${TEMP_DIR}/firecrackers/" "s3://${BUCKET_FC_VERSIONS}/"
echo "File upload to S3 completed"

# Clean up temporary directory
echo "Cleaning up temporary files..."
rm -rf "${TEMP_DIR}"
echo "Temporary files cleaned up"
echo "Migration completed!"