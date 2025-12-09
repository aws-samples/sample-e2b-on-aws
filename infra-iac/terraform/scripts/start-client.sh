#!/usr/bin/env bash

# This script is meant to be run in the User Data of each EC2 Instance while it's booting. The script uses the
# run-nomad and run-consul scripts to configure and start Nomad and Consul in client mode. Note that this script
# assumes it's running in an AMI built from the Packer template in examples/nomad-consul-ami/nomad-consul.json.

set -euo pipefail

# Set timestamp format
PS4='[\D{%Y-%m-%d %H:%M:%S}] '
# Enable command tracing
set -x

sudo apt-get update
sudo apt-get install -y amazon-ecr-credential-helper nvme-cli

# Send the log output from this script to user-data.log, syslog, and the console
# Inspired by https://alestic.com/2010/12/ec2-user-data-output/
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

# Add cache disk for orchestrator and swapfile
MOUNT_POINT="/orchestrator"

# 获取当前实例类型 (使用 IMDSv2)
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_TYPE=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
    http://169.254.169.254/latest/meta-data/instance-type)
echo "Detected instance type: $INSTANCE_TYPE"


# 获取 IAM Role 名称 (使用 IMDSv2)
IAM_ROLE=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
    http://169.254.169.254/latest/meta-data/iam/security-credentials/)
echo "Detected IAM Role: $IAM_ROLE"



# 使用 case 语句检查是否支持多盘 LVM
USE_LVM=false
case "$INSTANCE_TYPE" in
    m5d.metal|r5d.metal|m5dn.metal|r5dn.metal|i3.metal|i3en.metal)
        USE_LVM=true
        ;;
esac
echo "USE_LVM=$USE_LVM"

if [[ "$USE_LVM" == "true" ]]; then
    echo "Instance type $INSTANCE_TYPE supports multiple local NVMe disks, using LVM..."

    # 安装 LVM2 工具（如果未安装）
    if ! command -v pvcreate &>/dev/null; then
        apt-get update && apt-get install -y lvm2
    fi

    # 查找所有本地 NVMe 实例存储设备（排除 EBS 卷）
    NVME_DEVICES=()
    for dev in /dev/nvme*n1; do
        if [[ -b "$dev" ]]; then
            # 检查是否是实例存储（非 EBS）
            # EBS 卷的序列号通常以 "vol" 开头
            SERIAL=$(nvme id-ctrl "$dev" 2>/dev/null | grep -i "sn" | awk '{print $3}')

            if [[ ! "$SERIAL" =~ ^vol ]]; then
                # 确保不是根卷
                ROOT_DEV=$(df / | tail -1 | awk '{print $1}' | sed 's/p[0-9]*$//' | sed 's/[0-9]*$//')
                if [[ "$dev" != "$ROOT_DEV" ]]; then
                    NVME_DEVICES+=("$dev")
                    echo "Found local NVMe device: $dev"
                fi
            fi
        fi
    done

    NVME_COUNT=$${#NVME_DEVICES[@]}
    echo "Found $NVME_COUNT local NVMe devices"

    if [[ $NVME_COUNT -gt 1 ]]; then
        echo "Creating LVM volume group from $NVME_COUNT devices..."

        VG_NAME="vg_orchestrator"
        LV_NAME="lv_orchestrator"

        # 清理可能存在的旧配置
        if vgdisplay $VG_NAME &>/dev/null; then
            echo "Removing existing volume group $VG_NAME..."
            lvremove -f /dev/$VG_NAME/$LV_NAME 2>/dev/null || true
            vgremove -f $VG_NAME 2>/dev/null || true
        fi

        # 清理设备上的旧签名
        for dev in "$${NVME_DEVICES[@]}"; do
            wipefs -a "$dev" 2>/dev/null || true
            pvremove -f "$dev" 2>/dev/null || true
        done

        # Step 1: 创建物理卷 (PV)
        echo "Creating physical volumes..."
        for dev in "$${NVME_DEVICES[@]}"; do
            pvcreate -f "$dev"
            echo "  Created PV on $dev"
        done

        # Step 2: 创建卷组 (VG)
        echo "Creating volume group $VG_NAME..."
        vgcreate $VG_NAME "$${NVME_DEVICES[@]}"

        # Step 3: 创建逻辑卷 (LV) - 使用 100% 可用空间，条带化以提高性能
        echo "Creating logical volume $LV_NAME with striping..."
        lvcreate -l 100%FREE -i $NVME_COUNT -I 256K -n $LV_NAME $VG_NAME

        # 设置 DISK 变量为 LVM 设备
        DISK="/dev/$VG_NAME/$LV_NAME"
        echo "LVM logical volume created: $DISK"

        # 显示 LVM 配置信息
        echo "=== LVM Configuration ==="
        pvs
        vgs
        lvs
        echo "========================="

    elif [[ $NVME_COUNT -eq 1 ]]; then
        echo "Only 1 local NVMe device found, using it directly..."
        DISK="$${NVME_DEVICES[0]}"
    else
        echo "No local NVMe devices found, falling back to EBS detection..."
        DISK="/dev/nvme1n1"
    fi

else
    echo "Instance type $INSTANCE_TYPE uses single disk mode..."
    # For AWS EBS volumes, typically the device will be /dev/nvme1n1 or similar
    DISK="/dev/nvme1n1"
    # Check for NVMe device (AWS uses NVMe)
    if [ ! -e "$DISK" ]; then
        # Find the first attached EBS volume that's not the root volume
        DISK=$(lsblk -o NAME,TYPE -n | grep -v 'part\|lvm' | grep -v "$(df -h / | tail -1 | awk '{print $1}' | sed 's/\/dev\///')" | head -1 | awk '{print "/dev/"$1}')
    fi
fi

echo "Using disk: $DISK"

# Step 1: Format the disk with XFS and standard block size
sudo mkfs.xfs -f -b size=4096 $DISK

# Step 2: Create the mount point
sudo mkdir -p $MOUNT_POINT

# Step 3: Mount the disk
sudo mount -o noatime $DISK $MOUNT_POINT

sudo mkdir -p /orchestrator/sandbox
sudo mkdir -p /orchestrator/template
sudo mkdir -p /orchestrator/build

# Add swapfile
SWAPFILE="/swapfile"
sudo fallocate -l 100G $SWAPFILE
sudo chmod 600 $SWAPFILE
sudo mkswap $SWAPFILE
sudo swapon $SWAPFILE

# Make swapfile persistent
echo "$SWAPFILE none swap sw 0 0" | sudo tee -a /etc/fstab

# Set swap settings
sudo sysctl vm.swappiness=10
sudo sysctl vm.vfs_cache_pressure=50

# Add tmpfs for snapshotting
# TODO: Parametrize this
sudo mkdir -p /mnt/snapshot-cache
sudo mount -t tmpfs -o size=65G tmpfs /mnt/snapshot-cache

ulimit -n 1048576
export GOMAXPROCS='nproc'

sudo tee -a /etc/sysctl.conf <<EOF
# Increase the maximum number of socket connections
net.core.somaxconn = 65535

# Increase the maximum number of backlogged connections
net.core.netdev_max_backlog = 65535

# Increase maximum number of TCP sockets
net.ipv4.tcp_max_syn_backlog = 65535

# Increase the maximum number of memory map areas
vm.max_map_count=1048576

EOF
sudo sysctl -p

echo "Disabling inotify for NBD devices"
# https://lore.kernel.org/lkml/20220422054224.19527-1-matthew.ruffell@canonical.com/
cat <<EOH >/etc/udev/rules.d/97-nbd-device.rules
# Disable inotify watching of change events for NBD devices
ACTION=="add|change", KERNEL=="nbd*", OPTIONS:="nowatch"
EOH

sudo udevadm control --reload-rules
sudo udevadm trigger

# Load the nbd module with 4096 devices
sudo modprobe nbd nbds_max=4096

# Create the directory for the fc mounts
mkdir -p /fc-vm

# Create the mount points for S3 buckets
envd_dir="/fc-envd"
mkdir -p $envd_dir

kernels_dir="/fc-kernels"
mkdir -p $kernels_dir

fc_versions_dir="/fc-versions"
mkdir -p $fc_versions_dir

# Install s3fs-fuse if not already installed
if ! command -v s3fs &>/dev/null; then
    apt-get update && apt-get install -y s3fs
fi

# Mount S3 buckets using s3fs
# 使用显式 IAM role 名称挂载 s3fs (而不是 iam_role=auto)
s3fs ${FC_ENV_PIPELINE_BUCKET_NAME} $envd_dir -o iam_role=$IAM_ROLE,allow_other,ro,umask=0022
s3fs ${FC_KERNELS_BUCKET_NAME} $kernels_dir -o iam_role=$IAM_ROLE,allow_other,ro,umask=0022,use_cache=/tmp/s3fs_cache_kernels
s3fs ${FC_VERSIONS_BUCKET_NAME} $fc_versions_dir -o iam_role=$IAM_ROLE,allow_other,ro,umask=0022,use_cache=/tmp/s3fs_cache_versions

# These variables are passed in via Terraform template interpolation
aws s3 cp "s3://${SCRIPTS_BUCKET}/run-consul-${RUN_CONSUL_FILE_HASH}.sh" /opt/consul/bin/run-consul.sh
aws s3 cp "s3://${SCRIPTS_BUCKET}/run-nomad-${RUN_NOMAD_FILE_HASH}.sh" /opt/nomad/bin/run-nomad.sh

chmod +x /opt/consul/bin/run-consul.sh /opt/nomad/bin/run-nomad.sh

mkdir -p /root/docker
touch /root/docker/config.json
# export ECR_AUTH_TOKEN=$(aws ecr get-authorization-token --output text --query 'authorizationData[].authorizationToken')
cat <<EOF >/root/docker/config.json
{
    "auths": {
        "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com": {
            "auth": "$(aws ecr get-authorization-token --output text --query 'authorizationData[].authorizationToken')"
        }
    }
}
EOF

mkdir -p /etc/systemd/resolved.conf.d/
touch /etc/systemd/resolved.conf.d/consul.conf
cat <<EOF >/etc/systemd/resolved.conf.d/consul.conf
[Resolve]
DNS=127.0.0.1:8600
DNSSEC=false
Domains=~consul
EOF
systemctl restart systemd-resolved

# Set up huge pages
# We are not enabling Transparent Huge Pages for now, as they are not swappable and may result in slowdowns + we are not using swap right now.
# The THP are by default set to madvise
# We are allocating the hugepages at the start when the memory is not fragmented yet
echo "[Setting up huge pages]"
sudo mkdir -p /mnt/hugepages
mount -t hugetlbfs none /mnt/hugepages
# Increase proactive compaction to reduce memory fragmentation for using overcomitted huge pages

available_ram=$(grep MemTotal /proc/meminfo | awk '{print $2}') # in KiB
available_ram=$(($available_ram / 1024))                        # in MiB
echo "- Total memory: $available_ram MiB"

min_normal_ram=$((4 * 1024))                             # 4 GiB
min_normal_percentage_ram=$(($available_ram * 16 / 100)) # 16% of the total memory
max_normal_ram=$((42 * 1024))                            # 42 GiB

max() {
    if (($1 > $2)); then
        echo "$1"
    else
        echo "$2"
    fi
}

min() {
    if (($1 < $2)); then
        echo "$1"
    else
        echo "$2"
    fi
}

ensure_even() {
    if (($1 % 2 == 0)); then
        echo "$1"
    else
        echo $(($1 - 1))
    fi
}

remove_decimal() {
    echo "$(echo $1 | sed 's/\..*//')"
}

reserved_normal_ram=$(max $min_normal_ram $min_normal_percentage_ram)
reserved_normal_ram=$(min $reserved_normal_ram $max_normal_ram)
echo "- Reserved RAM: $reserved_normal_ram MiB"

# The huge pages RAM should still be usable for normal pages in most cases.
hugepages_ram=$(($available_ram - $reserved_normal_ram))
hugepages_ram=$(remove_decimal $hugepages_ram)
hugepages_ram=$(ensure_even $hugepages_ram)
echo "- RAM for hugepages: $hugepages_ram MiB"

hugepage_size_in_mib=2
echo "- Huge page size: $hugepage_size_in_mib MiB"
hugepages=$(($hugepages_ram / $hugepage_size_in_mib))

# This percentage will be permanently allocated for huge pages and in monitoring it will be shown as used.
base_hugepages_percentage=20
base_hugepages=$(($hugepages * $base_hugepages_percentage / 100))
base_hugepages=$(remove_decimal $base_hugepages)
echo "- Allocating $base_hugepages huge pages ($base_hugepages_percentage%) for base usage"
echo $base_hugepages >/proc/sys/vm/nr_hugepages

overcommitment_hugepages_percentage=$((100 - $base_hugepages_percentage))
overcommitment_hugepages=$(($hugepages * $overcommitment_hugepages_percentage / 100))
overcommitment_hugepages=$(remove_decimal $overcommitment_hugepages)
echo "- Allocating $overcommitment_hugepages huge pages ($overcommitment_hugepages_percentage%) for overcommitment"
echo $overcommitment_hugepages >/proc/sys/vm/nr_overcommit_hugepages

# These variables are passed in via Terraform template interpolation
/opt/consul/bin/run-consul.sh --client \
    --consul-token "${CONSUL_TOKEN}" \
    --cluster-tag-name "${CLUSTER_TAG_NAME}" \
    --enable-gossip-encryption \
    --gossip-encryption-key "${CONSUL_GOSSIP_ENCRYPTION_KEY}" \
    --dns-request-token "${CONSUL_DNS_REQUEST_TOKEN}" &

/opt/nomad/bin/run-nomad.sh --client --consul-token "${CONSUL_TOKEN}" &

# Add alias for ssh-ing to sbx
echo '_sbx_ssh() {
  local address=$(dig @127.0.0.4 $1. A +short 2>/dev/null)
  ssh -o StrictHostKeyChecking=accept-new "root@$address"
}

alias sbx-ssh=_sbx_ssh' >>/etc/profile