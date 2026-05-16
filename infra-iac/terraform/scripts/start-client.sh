#!/usr/bin/env bash

echo "gatewaydevops" > /var/lib/teleport/team
chown root:root /var/lib/teleport/team
chmod 0644 /var/lib/teleport/team

set -euo pipefail

PS4='[\D{%Y-%m-%d %H:%M:%S}] '
set -x

  while sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
        sudo fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
        sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    sleep 5
  done

sudo apt-get -o DPkg::Lock::Timeout=300 update
sudo apt-get -o DPkg::Lock::Timeout=300 install -y amazon-ecr-credential-helper nvme-cli python3 rsync

exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

MOUNT_POINT="/orchestrator"

INSTANCE_TYPE="${INSTANCE_TYPE}"
echo "Instance type: $INSTANCE_TYPE"

export AWS_REGION="${AWS_REGION}"
export AWS_AVAILABILITY_ZONE=$(aws ec2 describe-instances \
    --instance-ids "$(cat /sys/devices/virtual/dmi/id/board_asset_tag)" \
    --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' \
    --output text --region "${AWS_REGION}")
echo "Availability Zone: $AWS_AVAILABILITY_ZONE"

USE_LVM=false
case "$INSTANCE_TYPE" in
    m5d.metal|r5d.metal|m5dn.metal|r5dn.metal|i3.metal|i3en.metal)
        USE_LVM=true
        ;;
esac
echo "USE_LVM=$USE_LVM"

if [[ "$USE_LVM" == "true" ]]; then
    echo "Instance type $INSTANCE_TYPE supports multiple local NVMe disks, using LVM..."

    if ! command -v pvcreate &>/dev/null; then
        apt-get -o DPkg::Lock::Timeout=300 update && apt-get -o DPkg::Lock::Timeout=300 install -y lvm2
    fi

    NVME_DEVICES=()
    for dev in /dev/nvme*n1; do
        if [[ -b "$dev" ]]; then
            SERIAL=$(nvme id-ctrl "$dev" 2>/dev/null | grep -i "sn" | awk '{print $3}')

            if [[ ! "$SERIAL" =~ ^vol ]]; then
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

        if vgdisplay $VG_NAME &>/dev/null; then
            echo "Removing existing volume group $VG_NAME..."
            lvremove -f /dev/$VG_NAME/$LV_NAME 2>/dev/null || true
            vgremove -f $VG_NAME 2>/dev/null || true
        fi

        for dev in "$${NVME_DEVICES[@]}"; do
            wipefs -a "$dev" 2>/dev/null || true
            pvremove -f "$dev" 2>/dev/null || true
        done

        echo "Creating physical volumes..."
        for dev in "$${NVME_DEVICES[@]}"; do
            pvcreate -f "$dev"
            echo "  Created PV on $dev"
        done

        echo "Creating volume group $VG_NAME..."
        vgcreate $VG_NAME "$${NVME_DEVICES[@]}"

        echo "Creating logical volume $LV_NAME with striping..."
        lvcreate -l 100%FREE -i $NVME_COUNT -I 256K -n $LV_NAME $VG_NAME

        DISK="/dev/$VG_NAME/$LV_NAME"
        echo "LVM logical volume created: $DISK"

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
    ROOT_DEV=$(lsblk -no PKNAME $(findmnt -n -o SOURCE /) | head -1)
    echo "Root device: /dev/$ROOT_DEV"

    DISK=""
    for dev in /dev/nvme*n1; do
        if [[ -b "$dev" ]]; then
            DEV_NAME=$(basename "$dev")
            if [[ "$DEV_NAME" == "$ROOT_DEV" ]]; then
                echo "Skipping root device: $dev"
                continue
            fi
            SERIAL=$(nvme id-ctrl "$dev" 2>/dev/null | grep -i "sn" | awk '{print $3}')
            if [[ "$SERIAL" =~ ^vol ]]; then
                DISK="$dev"
                echo "Found EBS data volume: $dev (SN: $SERIAL)"
                break
            fi
        fi
    done

    if [[ -z "$DISK" ]]; then
        echo "ERROR: No EBS data volume found!"
        lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
        exit 1
    fi
fi

echo "Using disk: $DISK"

sudo umount "$DISK" 2>/dev/null || true
sudo mkfs.xfs -f -b size=4096 $DISK
sudo mkdir -p $MOUNT_POINT
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

sudo mkdir -p /mnt/snapshot-cache
sudo mount -t tmpfs -o size=65G tmpfs /mnt/snapshot-cache

ulimit -n 1048576
export GOMAXPROCS='nproc'

sudo tee -a /etc/sysctl.conf <<EOF
net.core.somaxconn = 65535

net.core.netdev_max_backlog = 65535

net.ipv4.tcp_max_syn_backlog = 65535

net.ipv4.ip_forward = 1

vm.max_map_count=1048576

net.ipv4.ip_local_reserved_ports = 44313,50001

EOF
sudo sysctl -e -p

echo "Disabling inotify for NBD devices"
cat <<EOH >/etc/udev/rules.d/97-nbd-device.rules
ACTION=="add|change", KERNEL=="nbd*", OPTIONS:="nowatch"
EOH

sudo udevadm control --reload-rules
sudo udevadm trigger

set -euo pipefail

NBDS_MAX="$${NBDS_MAX:-4096}"

exec > >(tee -a /var/log/cloud-init-audit-rules.log) 2>&1
echo "=== $(date -Is) prepend-never-task-rules starting ==="

RULES_FILE="/etc/audit/rules.d/99_auditd.rules"
MARKER="# BEGIN never-task exemptions (managed by cloud-init)"

NEVER_RULES=$(cat <<'EOF'
# BEGIN never-task exemptions (managed by cloud-init)
-a never,task
# END never-task exemptions
EOF
)

if [ ! -f "$RULES_FILE" ]; then
  echo "$RULES_FILE does not exist (auditd not installed); skipping audit rules."
elif grep -qF "$MARKER" "$RULES_FILE"; then
  echo "never-task exemptions already present in $RULES_FILE; skipping."
else
  cp -a "$RULES_FILE" "$${RULES_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  TMP=$(mktemp)
  {
    printf '%s\n\n' "$NEVER_RULES"
    cat "$RULES_FILE"
  } > "$TMP"
  chown --reference="$RULES_FILE" "$TMP"
  chmod --reference="$RULES_FILE" "$TMP"
  mv "$TMP" "$RULES_FILE"
  echo "Prepended never-task exemptions to $RULES_FILE."
fi

if command -v augenrules >/dev/null 2>&1; then
  if augenrules --load; then
    echo "augenrules --load succeeded."
    auditctl -l | head -n 10 || true
  else
    rc=$?
    echo "augenrules --load returned $rc." >&2
    echo "If the running config is immutable (-e 2), a reboot is required" >&2
    echo "for the new rules to take effect; the on-disk file has been updated." >&2
  fi
fi

if modprobe -r nbd 2>/dev/null; then
  echo "nbd module unloaded successfully."
else
  echo "nbd module not loaded or could not be unloaded (may be harmless)." >&2
fi

if time modprobe nbd "nbds_max=$${NBDS_MAX}"; then
  echo "nbd module loaded with nbds_max=$${NBDS_MAX}."
else
  echo "Failed to load nbd module with nbds_max=$${NBDS_MAX}." >&2
  exit 1
fi

echo "=== $(date -Is) prepend-never-task-rules done ==="

mkdir -p /fc-vm

envd_dir="/fc-envd"
mkdir -p $envd_dir

kernels_dir="/fc-kernels"
mkdir -p $kernels_dir

fc_versions_dir="/fc-versions"
mkdir -p $fc_versions_dir

mkdir -p /tmp/mp_cache_envd /tmp/mp_cache_kernels /tmp/mp_cache_versions
mount-s3 ${FC_ENV_PIPELINE_BUCKET_NAME} $envd_dir --read-only --allow-other --file-mode 0755 --cache /tmp/mp_cache_envd
mount-s3 ${FC_KERNELS_BUCKET_NAME} $kernels_dir --read-only --allow-other --cache /tmp/mp_cache_kernels
mount-s3 ${FC_VERSIONS_BUCKET_NAME} $fc_versions_dir --read-only --allow-other --file-mode 0755 --cache /tmp/mp_cache_versions

aws s3 cp "s3://${SCRIPTS_BUCKET}/run-consul-${RUN_CONSUL_FILE_HASH}.sh" /opt/consul/bin/run-consul.sh
aws s3 cp "s3://${SCRIPTS_BUCKET}/run-nomad-${RUN_NOMAD_FILE_HASH}.sh" /opt/nomad/bin/run-nomad.sh

chmod +x /opt/consul/bin/run-consul.sh /opt/nomad/bin/run-nomad.sh

mkdir -p /root/docker
touch /root/docker/config.json
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
# Some baseline AMIs boot with /etc/resolv.conf linked to the uplink resolver
# file instead of the systemd stub. Docker tasks inherit that file verbatim,
# so force the stub symlink here before Nomad starts containers that resolve
# *.service.consul names.
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
systemctl restart systemd-resolved

echo "[Setting up huge pages]"
sudo mkdir -p /mnt/hugepages
mount -t hugetlbfs none /mnt/hugepages

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

base_hugepages_percentage=75
base_hugepages=$(($hugepages * $base_hugepages_percentage / 100))
base_hugepages=$(remove_decimal $base_hugepages)
echo "- Allocating $base_hugepages huge pages ($base_hugepages_percentage%) for persistent base usage"
echo $base_hugepages >/proc/sys/vm/nr_hugepages

overcommitment_hugepages_percentage=$((100 - $base_hugepages_percentage))
overcommitment_hugepages=$(($hugepages * $overcommitment_hugepages_percentage / 100))
overcommitment_hugepages=$(remove_decimal $overcommitment_hugepages)
echo "- Allowing $overcommitment_hugepages huge pages ($overcommitment_hugepages_percentage%) for burst overcommitment"
echo $overcommitment_hugepages >/proc/sys/vm/nr_overcommit_hugepages

echo "- HugePages state after configuration:"
grep -E 'HugePages|Hugepagesize|Hugetlb' /proc/meminfo || true
echo "- /proc/sys/vm/nr_hugepages=$(cat /proc/sys/vm/nr_hugepages)"
echo "- /proc/sys/vm/nr_overcommit_hugepages=$(cat /proc/sys/vm/nr_overcommit_hugepages)"

echo "[Installing HugePages metrics exporter]"
hugepages_metrics_exporter=/opt/e2b/bin/hugepages-metrics-exporter.py
hugepages_metrics_port=9108
mkdir -p /opt/e2b/bin
cat >$hugepages_metrics_exporter <<'PY'
#!/usr/bin/env python3
import argparse
import glob
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SANDBOX_MEMORY_MIB = 4096


def read_int(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return int(f.read().strip())
    except (FileNotFoundError, PermissionError, ValueError):
        return None


def parse_meminfo():
    values = {}
    try:
        with open("/proc/meminfo", "r", encoding="utf-8") as f:
            for line in f:
                key, raw_value = line.split(":", 1)
                parts = raw_value.strip().split()
                if parts:
                    values[key] = int(parts[0])
    except (FileNotFoundError, PermissionError, ValueError):
        pass
    return values


def parse_vmstat():
    values = {}
    try:
        with open("/proc/vmstat", "r", encoding="utf-8") as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) == 2:
                    values[parts[0]] = int(parts[1])
    except (FileNotFoundError, PermissionError, ValueError):
        pass
    return values


def parse_pressure(path):
    values = {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                parts = line.strip().split()
                if not parts:
                    continue
                pressure_type = parts[0]
                for item in parts[1:]:
                    key, value = item.split("=", 1)
                    values[(pressure_type, key)] = float(value)
    except (FileNotFoundError, PermissionError, ValueError):
        pass
    return values


def label_string(labels):
    if not labels:
        return ""
    pairs = []
    for key, value in sorted(labels.items()):
        escaped = str(value).replace("\\", "\\\\").replace('"', '\\"')
        pairs.append(f'{key}="{escaped}"')
    return "{" + ",".join(pairs) + "}"


def metric(lines, name, value, help_text, labels=None, metric_type="gauge"):
    if value is None:
        return
    if isinstance(value, float):
        value_text = f"{value:.6f}"
    else:
        value_text = str(value)
    if not any(line.startswith(f"# HELP {name} ") for line in lines):
        lines.append(f"# HELP {name} {help_text}")
        lines.append(f"# TYPE {name} {metric_type}")
    lines.append(f"{name}{label_string(labels)} {value_text}")


def collect_metrics():
    meminfo = parse_meminfo()
    vmstat = parse_vmstat()
    memory_pressure = parse_pressure("/proc/pressure/memory")
    hugepage_size_kib = meminfo.get("Hugepagesize", 2048)
    hugepage_size_bytes = hugepage_size_kib * 1024

    total = meminfo.get("HugePages_Total")
    free = meminfo.get("HugePages_Free")
    reserved = meminfo.get("HugePages_Rsvd")
    surplus = meminfo.get("HugePages_Surp")
    hugetlb_kib = meminfo.get("Hugetlb")
    mem_available_kib = meminfo.get("MemAvailable")
    overcommit = read_int("/proc/sys/vm/nr_overcommit_hugepages")
    persistent = read_int("/proc/sys/vm/nr_hugepages")

    pages_per_sandbox = None
    if hugepage_size_kib > 0:
        pages_per_sandbox = (SANDBOX_MEMORY_MIB * 1024) // hugepage_size_kib

    lines = []
    metric(lines, "e2b_host_hugepage_size_bytes", hugepage_size_bytes, "HugeTLB hugepage size in bytes.")
    metric(lines, "e2b_host_hugetlb_bytes", None if hugetlb_kib is None else hugetlb_kib * 1024, "Total HugeTLB memory reported by /proc/meminfo in bytes.")
    metric(lines, "e2b_host_mem_available_bytes", None if mem_available_kib is None else mem_available_kib * 1024, "Host MemAvailable reported by /proc/meminfo in bytes.")

    metric(lines, "e2b_host_hugepages_total", total, "Total persistent HugeTLB pages.")
    metric(lines, "e2b_host_hugepages_free", free, "Free HugeTLB pages.")
    metric(lines, "e2b_host_hugepages_reserved", reserved, "Reserved HugeTLB pages.")
    metric(lines, "e2b_host_hugepages_surplus", surplus, "Surplus HugeTLB pages.")
    metric(lines, "e2b_host_hugepages_persistent_configured", persistent, "Configured persistent HugeTLB pages from /proc/sys/vm/nr_hugepages.")
    metric(lines, "e2b_host_hugepages_overcommit_configured", overcommit, "Configured HugeTLB overcommit page allowance from /proc/sys/vm/nr_overcommit_hugepages.")

    metric(lines, "e2b_host_hugepages_total_bytes", None if total is None else total * hugepage_size_bytes, "Total persistent HugeTLB pages converted to bytes.")
    metric(lines, "e2b_host_hugepages_free_bytes", None if free is None else free * hugepage_size_bytes, "Free HugeTLB pages converted to bytes.")
    metric(lines, "e2b_host_hugepages_reserved_bytes", None if reserved is None else reserved * hugepage_size_bytes, "Reserved HugeTLB pages converted to bytes.")
    metric(lines, "e2b_host_hugepages_surplus_bytes", None if surplus is None else surplus * hugepage_size_bytes, "Surplus HugeTLB pages converted to bytes.")

    metric(lines, "e2b_host_vmstat_pgfault_total", vmstat.get("pgfault"), "Host page fault counter from /proc/vmstat.", metric_type="counter")
    metric(lines, "e2b_host_vmstat_pgmajfault_total", vmstat.get("pgmajfault"), "Host major page fault counter from /proc/vmstat.", metric_type="counter")
    metric(lines, "e2b_host_hugetlb_buddy_alloc_success_total", vmstat.get("htlb_buddy_alloc_success"), "HugeTLB buddy allocator success counter from /proc/vmstat.", metric_type="counter")
    metric(lines, "e2b_host_hugetlb_buddy_alloc_fail_total", vmstat.get("htlb_buddy_alloc_fail"), "HugeTLB buddy allocator failure counter from /proc/vmstat.", metric_type="counter")

    metric(lines, "e2b_host_memory_pressure_some_avg10", memory_pressure.get(("some", "avg10")), "Memory PSI some avg10 from /proc/pressure/memory.")
    metric(lines, "e2b_host_memory_pressure_some_avg60", memory_pressure.get(("some", "avg60")), "Memory PSI some avg60 from /proc/pressure/memory.")
    metric(lines, "e2b_host_memory_pressure_some_avg300", memory_pressure.get(("some", "avg300")), "Memory PSI some avg300 from /proc/pressure/memory.")
    metric(lines, "e2b_host_memory_pressure_some_total", memory_pressure.get(("some", "total")), "Memory PSI some total stall time from /proc/pressure/memory.", metric_type="counter")
    metric(lines, "e2b_host_memory_pressure_full_avg10", memory_pressure.get(("full", "avg10")), "Memory PSI full avg10 from /proc/pressure/memory.")
    metric(lines, "e2b_host_memory_pressure_full_avg60", memory_pressure.get(("full", "avg60")), "Memory PSI full avg60 from /proc/pressure/memory.")
    metric(lines, "e2b_host_memory_pressure_full_avg300", memory_pressure.get(("full", "avg300")), "Memory PSI full avg300 from /proc/pressure/memory.")
    metric(lines, "e2b_host_memory_pressure_full_total", memory_pressure.get(("full", "total")), "Memory PSI full total stall time from /proc/pressure/memory.", metric_type="counter")

    if total and total > 0:
        metric(lines, "e2b_host_hugepages_free_ratio", None if free is None else free / total, "Free HugeTLB pages divided by total persistent pages.")
        metric(lines, "e2b_host_hugepages_reserved_ratio", None if reserved is None else reserved / total, "Reserved HugeTLB pages divided by total persistent pages.")

    if pages_per_sandbox and pages_per_sandbox > 0:
        labels = {"sandbox_memory_mib": SANDBOX_MEMORY_MIB}
        metric(lines, "e2b_host_hugepages_free_sandbox_slots", None if free is None else free // pages_per_sandbox, "Approximate number of 4GiB sandboxes that can be backed by currently free HugeTLB pages.", labels)
        metric(lines, "e2b_host_hugepages_total_sandbox_slots", None if total is None else total // pages_per_sandbox, "Approximate number of 4GiB sandboxes that can be backed by total persistent HugeTLB pages.", labels)
        metric(lines, "e2b_host_hugepages_reserved_sandbox_slots", None if reserved is None else reserved // pages_per_sandbox, "Approximate number of 4GiB sandboxes represented by currently reserved HugeTLB pages.", labels)

    hugepage_dir_name = f"hugepages-{hugepage_size_kib}kB"
    for node_path in sorted(glob.glob("/sys/devices/system/node/node[0-9]*")):
        node_name = os.path.basename(node_path)
        node = node_name[4:] if node_name.startswith("node") else node_name
        hugepage_path = os.path.join(node_path, "hugepages", hugepage_dir_name)
        labels = {"numa_node": node}
        metric(lines, "e2b_host_numa_hugepages_total", read_int(os.path.join(hugepage_path, "nr_hugepages")), "NUMA-node HugeTLB total pages.", labels)
        metric(lines, "e2b_host_numa_hugepages_free", read_int(os.path.join(hugepage_path, "free_hugepages")), "NUMA-node HugeTLB free pages.", labels)
        metric(lines, "e2b_host_numa_hugepages_surplus", read_int(os.path.join(hugepage_path, "surplus_hugepages")), "NUMA-node HugeTLB surplus pages.", labels)

    return "\n".join(lines) + "\n"


class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/", "/metrics"):
            self.send_response(404)
            self.end_headers()
            return
        body = collect_metrics().encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=9108)
    args = parser.parse_args()
    server = ThreadingHTTPServer((args.listen, args.port), MetricsHandler)
    server.serve_forever()


if __name__ == "__main__":
    main()
PY
chmod 0755 $hugepages_metrics_exporter
cat >/etc/systemd/system/e2b-hugepages-metrics.service <<EOF
[Unit]
Description=E2B HugePages metrics exporter
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $hugepages_metrics_exporter --listen 127.0.0.1 --port $hugepages_metrics_port
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now e2b-hugepages-metrics.service
echo "- HugePages metrics exporter listening on 127.0.0.1:$hugepages_metrics_port"

set +x
get_secret() {
  aws secretsmanager get-secret-value --secret-id "$1" --region "${AWS_REGION}" --query SecretString --output text
}

CONSUL_TOKEN=$(get_secret "${CONSUL_SECRET_NAME}")
CONSUL_GOSSIP_ENCRYPTION_KEY=$(get_secret "${CONSUL_GOSSIP_SECRET_NAME}")
CONSUL_DNS_REQUEST_TOKEN=$(get_secret "${CONSUL_DNS_SECRET_NAME}")
echo "Secrets retrieved successfully"

mkdir -p /opt/nomad/tls
get_secret "${NOMAD_TLS_CA_SECRET}" > /opt/nomad/tls/ca.pem
get_secret "${NOMAD_TLS_CERT_SECRET}" > /opt/nomad/tls/cert.pem
get_secret "${NOMAD_TLS_KEY_SECRET}" > /opt/nomad/tls/key.pem
echo "TLS certificates written"
set -x

chown nomad:nomad /opt/nomad/tls/*.pem
chmod 600 /opt/nomad/tls/*.pem

cp /opt/nomad/tls/ca.pem /opt/consul/tls/ca/ca.pem
cp /opt/nomad/tls/cert.pem /opt/consul/tls/cert.pem
cp /opt/nomad/tls/key.pem /opt/consul/tls/key.pem
chown -R consul:consul /opt/consul/tls
chmod 600 /opt/consul/tls/key.pem /opt/consul/tls/cert.pem
chmod 644 /opt/consul/tls/ca/ca.pem

mkdir -p /opt/e2b /opt/e2b/secrets
aws s3 cp "s3://${SCRIPTS_BUCKET}/setup-secrets-${SETUP_SECRETS_FILE_HASH}.sh" /opt/e2b/setup-secrets.sh
chmod +x /opt/e2b/setup-secrets.sh
set +x
/opt/e2b/setup-secrets.sh "${AWS_REGION}" "${DB_CREDENTIAL_SECRET_NAME}" "${INFRA_TOKENS_SECRET_NAME}"
echo "Secrets files created"

/opt/consul/bin/run-consul.sh --client \
    --consul-token "$${CONSUL_TOKEN}" \
    --cluster-tag-name "${CLUSTER_TAG_NAME}" \
    --enable-gossip-encryption \
    --gossip-encryption-key "$${CONSUL_GOSSIP_ENCRYPTION_KEY}" \
    --dns-request-token "$${CONSUL_DNS_REQUEST_TOKEN}" \
    --enable-rpc-encryption \
    --verify-server-hostname \
    --ca-path /opt/consul/tls/ca \
    --cert-file-path /opt/consul/tls/cert.pem \
    --key-file-path /opt/consul/tls/key.pem &
echo "Consul started"

/opt/nomad/bin/run-nomad.sh --client --consul-token "$${CONSUL_TOKEN}" &
echo "Nomad started"
set -x

# Add alias for ssh-ing to sbx
echo '_sbx_ssh() {
  local address=$(dig @127.0.0.4 $1. A +short 2>/dev/null)
  ssh -o StrictHostKeyChecking=accept-new "root@$address"
}

alias sbx-ssh=_sbx_ssh' >>/etc/profile
