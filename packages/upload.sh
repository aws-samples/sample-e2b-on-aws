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

# Check if gsutil is installed
if ! command -v gsutil &> /dev/null; then
    echo "Installing gsutil..."

    # Create keyring directory if it doesn't exist
    sudo mkdir -p /usr/share/keyrings

    # Add Google Cloud SDK distribution URI as a package source
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee -a /etc/apt/sources.list.d/google-cloud-sdk.list

    # Import Google Cloud public key
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key --keyring /usr/share/keyrings/cloud.google.gpg add -

    # Update package list
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update -y

    # Install Google Cloud SDK (automatically accept all prompts)
    sudo apt-get install -y google-cloud-sdk

    echo "gsutil installation completed"
else
    echo "gsutil is already installed"
fi

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo "Installing AWS CLI..."
    sudo apt-get install -y awscli
    echo "AWS CLI installation completed"
else
    echo "AWS CLI is already installed"
fi

# Create subdirectories
mkdir -p "${TEMP_DIR}/kernels"
mkdir -p "${TEMP_DIR}/firecrackers"

if [ "$ARCHITECTURE" = "x86_64" ]; then
    ARCH_SUFFIX="x86_64"
    # Download files from Google Cloud Storage
    echo "Downloading files from Google Cloud Storage..."
    # gsutil cp -r gs://e2b-prod-public-builds/envd-v0.0.1 "${TEMP_DIR}/envd-v0.0.1"
    # gsutil cp -r gs://e2b-prod-public-builds/envd "${TEMP_DIR}/envd"
    gsutil cp -r gs://e2b-prod-public-builds/kernels/* "${TEMP_DIR}/kernels/"
    gsutil cp -r gs://e2b-prod-public-builds/firecrackers/* "${TEMP_DIR}/firecrackers/"
    echo "File download completed"

else ## ARM64 architecture
    ARCH_SUFFIX="arm64"
    # Download kernels
	CI_VERSION="v1.10"
	KERNEL_VERSION="6.1.102"
	FOLDER="vmlinux-${KERNEL_VERSION}"
	mkdir -p "${TEMP_DIR}/kernels/${FOLDER}"
	curl -L https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/$CI_VERSION/aarch64/vmlinux-$KERNEL_VERSION -o ${TEMP_DIR}/kernels/${FOLDER}/vmlinux.bin
	# Download firecracker
	FC_VERSION="v1.10.1"
	FOLDER="v1.10.1_1fcdaec"
	mkdir -p "${TEMP_DIR}/firecrackers/${FOLDER}"
	release_url="https://github.com/firecracker-microvm/firecracker/releases"
	curl -L ${release_url}/download/${FC_VERSION}/firecracker-${FC_VERSION}-aarch64.tgz | tar -xz
    mv release-${FC_VERSION}-aarch64/firecracker-${FC_VERSION}-aarch64 \
       ${TEMP_DIR}/firecrackers/${FOLDER}/firecracker
    rm -rf release-${latest_version}-aarch64
fi

# Upload to S3
echo "Starting file upload to S3..."
# Copy envd binary to S3 bucket
# aws s3 cp "${TEMP_DIR}/envd-v0.0.1" "s3://${BUCKET_FC_ENV_PIPELINE}/envd-v0.0.1"
# # aws s3 cp ./envd/bin/envd "s3://${BUCKET_FC_ENV_PIPELINE}/envd"
# aws s3 cp "${TEMP_DIR}/envd" "s3://${BUCKET_FC_ENV_PIPELINE}/envd"
aws s3 cp --recursive "${TEMP_DIR}/kernels/" "s3://${BUCKET_FC_KERNELS}/"
aws s3 cp --recursive "${TEMP_DIR}/firecrackers/" "s3://${BUCKET_FC_VERSIONS}/"
echo "File upload to S3 completed"

# Clean up temporary directory
echo "Cleaning up temporary files..."
rm -rf "${TEMP_DIR}"
echo "Temporary files cleaned up"

echo "Migration completed!"