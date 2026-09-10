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
BUCKET_E2B=$(grep "BUCKET_E2B" $CONFIG_FILE | cut -d'=' -f2)

if [ -z "$BUCKET_E2B" ]; then
    echo "Error: Could not read BUCKET_E2B from configuration file"
    exit 1
fi

echo "Bucket information read from configuration file:"
echo "BUCKET_E2B: $BUCKET_E2B"

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo "Installing AWS CLI..."
    sudo apt-get install -y awscli
    echo "AWS CLI installation completed"
else
    echo "AWS CLI is already installed"
fi

# Kernel and Firecracker versions the code asks for by default. Keep these in
# sync with packages/shared/pkg/featureflags/flags.go:
#   DefaultKernelVersion      = "vmlinux-6.1.158"
#   DefaultFirecrackerVersion = DefaultFirecrackerV1_14_0Version = "v1.14-0.2.0"
# A build that requests a version which is not present here fails with
# "error stating firecracker binary: ... no such file or directory".
#
# The Firecracker directory naming changed with the d73e2b1 sync: E2B moved from
# an upstream-version-plus-build-hash name (v1.14.1_431f1fc) to their own release
# line (formatE2B, "vX.Y-<e2b-semver>"), and 0.2.0 is what carries the in-place
# checkpoint support the orchestrator now expects. Overriding
# DEFAULT_FIRECRACKER_VERSION back to the old directory would keep this upload
# valid and lose that.
KERNEL_FOLDER="vmlinux-6.1.158"
FC_FOLDER="v1.14-0.2.0"

# Both artifacts come from E2B's own public build bucket, not from upstream
# vendor releases: the Firecracker directory names carry E2B's build hash
# (431f1fc) and the binaries are their patched builds, so a vanilla
# firecracker-v1.14.1 release renamed into that directory would be the wrong
# binary. The same bucket also holds the matching kernels.
E2B_BUILDS="https://storage.googleapis.com/e2b-prod-public-builds"

# Must match BUSYBOX_VERSION in packages/orchestrator/pkg/cfg/model.go. The
# orchestrator resolves the binary as
#   $HOST_BUSYBOX_DIR/<version>/<goarch>/busybox
# (see cmd/create-build/main.go), so the object layout below has to match.
BUSYBOX_VERSION="1.36.1"

ARCHITECTURE=$(grep "^CFNARCHITECTURE=" "$CONFIG_FILE" | cut -d'=' -f2)
if [ "$ARCHITECTURE" = "arm64" ]; then
    GOARCH="arm64"
else
    GOARCH="amd64"
fi

# orchestrator/pkg/sandbox/fc/config.go resolves both artifacts as
# <dir>/<version>/<arch>/<file> and falls back to the flat <dir>/<version>/<file>
# for nodes that predate the arch-prefixed layout. Publish both so either lookup
# succeeds.
mkdir -p "${TEMP_DIR}/kernels/${KERNEL_FOLDER}/${GOARCH}"
mkdir -p "${TEMP_DIR}/firecrackers/${FC_FOLDER}/${GOARCH}"

echo "Downloading kernel ${KERNEL_FOLDER} (${GOARCH})..."
curl -sfL -o "${TEMP_DIR}/kernels/${KERNEL_FOLDER}/${GOARCH}/vmlinux.bin" \
    "${E2B_BUILDS}/kernels/${KERNEL_FOLDER}/${GOARCH}/vmlinux.bin"
cp "${TEMP_DIR}/kernels/${KERNEL_FOLDER}/${GOARCH}/vmlinux.bin" \
   "${TEMP_DIR}/kernels/${KERNEL_FOLDER}/vmlinux.bin"

echo "Downloading firecracker ${FC_FOLDER} (${GOARCH})..."
curl -sfL -o "${TEMP_DIR}/firecrackers/${FC_FOLDER}/${GOARCH}/firecracker" \
    "${E2B_BUILDS}/firecrackers/${FC_FOLDER}/${GOARCH}/firecracker"
chmod +x "${TEMP_DIR}/firecrackers/${FC_FOLDER}/${GOARCH}/firecracker"
cp "${TEMP_DIR}/firecrackers/${FC_FOLDER}/${GOARCH}/firecracker" \
   "${TEMP_DIR}/firecrackers/${FC_FOLDER}/firecracker"

# Busybox, mirrored from the same public bucket and with the same checksum
# verification as packages/orchestrator/scripts/fetch-busybox.sh.
BUSYBOX_DIR="${TEMP_DIR}/busybox/${BUSYBOX_VERSION}/${GOARCH}"
mkdir -p "${BUSYBOX_DIR}"
BUSYBOX_SRC="https://storage.googleapis.com/e2b-artifact-binaries/busybox/${BUSYBOX_VERSION}/${GOARCH}"
echo "Downloading busybox v${BUSYBOX_VERSION} (${GOARCH})..."
curl -sfL -o "${BUSYBOX_DIR}/busybox" "${BUSYBOX_SRC}/busybox"
curl -sfL -o "${BUSYBOX_DIR}/busybox.sha256" "${BUSYBOX_SRC}/busybox.sha256"
(cd "${BUSYBOX_DIR}" && sha256sum -c busybox.sha256)
rm -f "${BUSYBOX_DIR}/busybox.sha256"
chmod +x "${BUSYBOX_DIR}/busybox"

# Upload to S3
echo "Starting file upload to S3..."
aws s3 cp --recursive "${TEMP_DIR}/kernels/" "s3://${BUCKET_E2B}/fc-kernels/"
aws s3 cp --recursive "${TEMP_DIR}/firecrackers/" "s3://${BUCKET_E2B}/fc-versions/"
aws s3 cp --recursive "${TEMP_DIR}/busybox/" "s3://${BUCKET_E2B}/fc-busybox/"
echo "File upload to S3 completed"

# Clean up temporary directory
echo "Cleaning up temporary files..."
rm -rf "${TEMP_DIR}"
echo "Temporary files cleaned up"
echo "Migration completed!"