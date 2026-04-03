#!/bin/bash
set -e

echo "Starting resource upload script..."

# Read configuration file
CONFIG_FILE="/opt/config.properties"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file $CONFIG_FILE does not exist"
    exit 1
fi

BUCKET_E2B=$(grep "BUCKET_E2B" $CONFIG_FILE | cut -d'=' -f2)
ARCHITECTURE=$(grep "^CFNARCHITECTURE=" "$CONFIG_FILE" | cut -d'=' -f2)

if [ -z "$BUCKET_E2B" ]; then
    echo "Error: Could not read BUCKET_E2B from configuration file"
    exit 1
fi

echo "BUCKET_E2B: $BUCKET_E2B"
echo "ARCHITECTURE: $ARCHITECTURE"

# E2B public builds source (custom Firecracker + kernels)
E2B_GCS="https://storage.googleapis.com/e2b-prod-public-builds"

TEMP_DIR=$(mktemp -d)

# ==============================================================
# Kernel and Firecracker versions to download
# All downloaded from e2b's custom builds (NOT official releases)
# ==============================================================

declare -A KERNELS=(
    ["vmlinux-6.1.102"]="${E2B_GCS}/kernels/vmlinux-6.1.102/vmlinux.bin"
    ["vmlinux-6.1.158"]="${E2B_GCS}/kernels/vmlinux-6.1.158/vmlinux.bin"
)

declare -A FIRECRACKERS=(
    ["v1.10.1_1fcdaec"]="${E2B_GCS}/firecrackers/v1.10.1_1fcdaec/firecracker"
    ["v1.12.1_210cbac"]="${E2B_GCS}/firecrackers/v1.12.1_210cbac/firecracker"
)

# ==============================================================
# Download and upload kernels
# ==============================================================
echo "=== Downloading kernels ==="
for folder in "${!KERNELS[@]}"; do
    url="${KERNELS[$folder]}"
    echo "  Downloading $folder..."
    mkdir -p "${TEMP_DIR}/kernels/${folder}"
    curl -sL "$url" -o "${TEMP_DIR}/kernels/${folder}/vmlinux.bin"
    echo "  Downloaded $(du -h ${TEMP_DIR}/kernels/${folder}/vmlinux.bin | cut -f1)"
done

echo "Uploading kernels to S3..."
aws s3 cp --recursive "${TEMP_DIR}/kernels/" "s3://${BUCKET_E2B}/fc-kernels/"
echo "Kernels uploaded"

# ==============================================================
# Download and upload Firecracker versions
# ==============================================================
echo "=== Downloading Firecracker versions ==="
for folder in "${!FIRECRACKERS[@]}"; do
    url="${FIRECRACKERS[$folder]}"
    echo "  Downloading $folder..."
    mkdir -p "${TEMP_DIR}/firecrackers/${folder}"
    curl -sL "$url" -o "${TEMP_DIR}/firecrackers/${folder}/firecracker"
    chmod +x "${TEMP_DIR}/firecrackers/${folder}/firecracker"
    echo "  Downloaded $(du -h ${TEMP_DIR}/firecrackers/${folder}/firecracker | cut -f1)"
done

echo "Uploading Firecracker versions to S3..."
aws s3 cp --recursive "${TEMP_DIR}/firecrackers/" "s3://${BUCKET_E2B}/fc-versions/"
echo "Firecracker versions uploaded"

# ==============================================================
# Cleanup
# ==============================================================
rm -rf "${TEMP_DIR}"
echo "Upload completed!"
