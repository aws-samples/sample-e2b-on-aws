#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${ORPHAN_FC_EXPORTER_INSTALL_DIR:-/opt/e2b/bin}"
EXPORTER_PATH="${INSTALL_DIR}/orphan-fc-exporter.py"
GRPCURL_PATH="${INSTALL_DIR}/grpcurl"
SERVICE_PATH="/etc/systemd/system/e2b-orphan-fc-exporter.service"
LISTEN_ADDR="${ORPHAN_FC_EXPORTER_LISTEN:-127.0.0.1}"
PORT="${ORPHAN_FC_EXPORTER_PORT:-9109}"
ORCHESTRATOR_ADDR="${ORPHAN_FC_ORCHESTRATOR_ADDR:-127.0.0.1:5008}"
GRPCURL_VERSION="${GRPCURL_VERSION:-1.9.3}"
GRPCURL_URL="${GRPCURL_URL:-https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION}_linux_x86_64.tar.gz}"
GRPCURL_SHA256="${GRPCURL_SHA256:-}"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

download_file() {
  local src="$1"
  local dst="$2"

  case "$src" in
    s3://*)
      if [[ -n "$AWS_REGION" ]]; then
        aws s3 cp "$src" "$dst" --region "$AWS_REGION"
      else
        aws s3 cp "$src" "$dst"
      fi
      ;;
    http://*|https://*)
      curl -fsSL --max-time 60 -o "$dst" "$src"
      ;;
    file://*)
      cp "${src#file://}" "$dst"
      ;;
    *)
      cp "$src" "$dst"
      ;;
  esac
}

install_grpcurl() {
  if [[ -x "$GRPCURL_PATH" ]] && "$GRPCURL_PATH" --version >/dev/null 2>&1; then
    log "grpcurl already installed at $GRPCURL_PATH"
    return
  fi

  local tmp
  tmp="$(mktemp -d /tmp/e2b-grpcurl-install.XXXXXX)"
  trap 'rm -rf "$tmp"' RETURN

  log "installing grpcurl from $GRPCURL_URL"
  download_file "$GRPCURL_URL" "$tmp/grpcurl.download"

  if [[ -n "$GRPCURL_SHA256" ]]; then
    printf '%s  %s\n' "$GRPCURL_SHA256" "$tmp/grpcurl.download" | sha256sum -c -
  fi

  if tar -tzf "$tmp/grpcurl.download" >/dev/null 2>&1; then
    tar -C "$tmp" -xzf "$tmp/grpcurl.download" grpcurl
    install -m 0755 "$tmp/grpcurl" "$GRPCURL_PATH"
  else
    install -m 0755 "$tmp/grpcurl.download" "$GRPCURL_PATH"
  fi

  "$GRPCURL_PATH" --version 2>&1
}

write_exporter() {
  log "writing $EXPORTER_PATH"
  mkdir -p "$INSTALL_DIR"
  cat >"$EXPORTER_PATH" <<'PY'
#!/usr/bin/env python3
import argparse
import glob
import json
import os
import re
import subprocess
import tempfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROTO = r'''
syntax = "proto3";
import "google/protobuf/empty.proto";
import "google/protobuf/timestamp.proto";
message SandboxConfig {
  string template_id = 1;
  string build_id = 2;
  string kernel_version = 3;
  string firecracker_version = 4;
  bool huge_pages = 5;
  string sandbox_id = 6;
  map<string, string> env_vars = 7;
  map<string, string> metadata = 8;
  optional string alias = 9;
  string envd_version = 10;
  int64 vcpu = 11;
  int64 ram_mb = 12;
  string team_id = 13;
  int64 max_sandbox_length = 14;
  int64 total_disk_size_mb = 15;
  bool snapshot = 16;
  string base_template_id = 17;
  optional bool auto_pause = 18;
  optional string envd_access_token = 19;
  string execution_id = 20;
}
message RunningSandbox {
  SandboxConfig config = 1;
  string client_id = 2;
  google.protobuf.Timestamp start_time = 3;
  google.protobuf.Timestamp end_time = 4;
}
message SandboxListResponse { repeated RunningSandbox sandboxes = 1; }
message SandboxCreateRequest { SandboxConfig sandbox = 1; }
message SandboxCreateResponse { string client_id = 1; }
message SandboxUpdateRequest { string sandbox_id = 1; }
message SandboxDeleteRequest { string sandbox_id = 1; }
message SandboxPauseRequest { string sandbox_id = 1; string template_id = 2; string build_id = 3; }
message CachedBuildInfo { string build_id = 1; google.protobuf.Timestamp expiration_time = 2; }
message SandboxListCachedBuildsResponse { repeated CachedBuildInfo builds = 1; }
service SandboxService {
  rpc Create(SandboxCreateRequest) returns (SandboxCreateResponse);
  rpc Update(SandboxUpdateRequest) returns (google.protobuf.Empty);
  rpc List(google.protobuf.Empty) returns (SandboxListResponse);
  rpc Delete(SandboxDeleteRequest) returns (google.protobuf.Empty);
  rpc Pause(SandboxPauseRequest) returns (google.protobuf.Empty);
  rpc ListCachedBuilds(google.protobuf.Empty) returns (SandboxListCachedBuildsResponse);
}
'''

SOCKET_RE = re.compile(r"/tmp/fc-([A-Za-z0-9_-]+)\.sock")


def normalize(sid):
    return sid.split("-", 1)[0] if sid else sid


def read_text(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()
    except (FileNotFoundError, PermissionError, OSError):
        return ""


def run(args, timeout):
    return subprocess.run(
        args,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=timeout,
        check=False,
    )


def collect_processes():
    proc = run(["ps", "-eo", "pid=,ppid=,stat=,etimes=,pcpu=,pmem=,comm=,args="], 5)
    if proc.returncode != 0:
        raise RuntimeError("ps failed: " + proc.stderr[:200])

    firecrackers = []
    wrappers = []

    for line in proc.stdout.splitlines():
        parts = line.split(None, 7)
        if len(parts) < 8:
            continue
        pid, ppid, stat, etimes, pcpu, pmem, comm, args = parts
        match = SOCKET_RE.search(args)
        if not match:
            continue
        sid = match.group(1)
        row = {
            "sid": sid,
            "base": normalize(sid),
            "pid": pid,
            "ppid": ppid,
            "stat": stat,
            "age": int(float(etimes)),
            "cpu": pcpu,
            "mem": pmem,
        }
        if comm == "firecracker" and "--api-sock" in args:
            firecrackers.append(row)
        elif comm == "unshare" and "--kill-child" in args and "firecracker" in args and "--api-sock" in args:
            wrappers.append(row)

    return firecrackers, wrappers


def collect_control_ids(grpcurl, orchestrator_addr, timeout):
    if not os.path.exists(grpcurl) or not os.access(grpcurl, os.X_OK):
        return set(), False

    with tempfile.TemporaryDirectory(prefix="orphan-fc-proto.") as tmp:
        proto_path = os.path.join(tmp, "orchestrator.proto")
        with open(proto_path, "w", encoding="utf-8") as f:
            f.write(PROTO)
        proc = run(
            [
                grpcurl,
                "-plaintext",
                "-max-time",
                str(timeout),
                "-import-path",
                tmp,
                "-proto",
                proto_path,
                "-d",
                "{}",
                orchestrator_addr,
                "SandboxService/List",
            ],
            timeout + 2,
        )
        if proc.returncode != 0:
            return set(), False

        data = json.loads(proc.stdout or "{}")
        ids = set()
        for sandbox in data.get("sandboxes", []):
            sid = (sandbox.get("config") or {}).get("sandboxId")
            if sid:
                ids.add(normalize(sid))
        return ids, True


def collect_socket_ids():
    ids = set()
    for path in glob.glob("/tmp/fc-*.sock"):
        name = os.path.basename(path)
        if name.startswith("fc-") and name.endswith(".sock"):
            ids.add(name[3:-5])
    return ids


def collect_netns_count():
    try:
        proc = run(["ip", "netns", "list"], 3)
        if proc.returncode == 0:
            return sum(1 for line in proc.stdout.splitlines() if line.strip())
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        pass

    paths = glob.glob("/var/run/netns/*") + glob.glob("/run/netns/*")
    return len({os.path.basename(path) for path in paths})


def collect_netdev_counts():
    counts = {"tap": 0, "veth": 0}
    for path in glob.glob("/sys/class/net/*"):
        name = os.path.basename(path)
        if name.startswith("tap"):
            counts["tap"] += 1
        elif name.startswith("veth"):
            counts["veth"] += 1
    return counts


def collect_nbd_counts():
    counts = {
        "total": 0,
        "active": 0,
        "pid": 0,
        "nonzero_size": 0,
        "no_pid_nonzero_size": 0,
    }
    for path in glob.glob("/sys/block/nbd*"):
        counts["total"] += 1
        size = read_text(os.path.join(path, "size"))
        pid = read_text(os.path.join(path, "pid"))
        has_pid = bool(pid)
        has_nonzero_size = bool(size and size != "0")
        if has_pid:
            counts["pid"] += 1
        if has_nonzero_size:
            counts["nonzero_size"] += 1
        if has_nonzero_size and not has_pid:
            counts["no_pid_nonzero_size"] += 1
        if has_nonzero_size or has_pid:
            counts["active"] += 1
    return counts


def metric(lines, name, value, help_text, metric_type="gauge"):
    if not any(line.startswith(f"# HELP {name} ") for line in lines):
        lines.append(f"# HELP {name} {help_text}")
        lines.append(f"# TYPE {name} {metric_type}")
    if isinstance(value, float):
        rendered = f"{value:.6f}"
    else:
        rendered = str(int(value))
    lines.append(f"{name} {rendered}")


def collect_metrics(args):
    started = time.time()
    audit_success = 1
    control_available = 0
    fc = []
    wrappers = []
    control_ids = set()

    try:
        fc, wrappers = collect_processes()
        control_ids, control_available_bool = collect_control_ids(args.grpcurl, args.orchestrator_addr, args.grpc_timeout)
        control_available = 1 if control_available_bool else 0
        if not control_available_bool:
            audit_success = 0
    except Exception:
        audit_success = 0

    fc_ids = {item["sid"] for item in fc}
    fc_bases = {item["base"] for item in fc}
    socket_ids = collect_socket_ids()
    wrapper_ids = {item["sid"] for item in wrappers}
    nbd_counts = collect_nbd_counts()
    netdev_counts = collect_netdev_counts()

    if control_available:
        orphan_rows = [item for item in fc if item["base"] not in control_ids]
    else:
        orphan_rows = []

    orphan_oldest_age = max((item["age"] for item in orphan_rows), default=0)
    fc_oldest_age = max((item["age"] for item in fc), default=0)

    lines = []
    metric(lines, "e2b_host_firecracker_processes", len(fc_ids), "Host Firecracker process count.")
    metric(lines, "e2b_host_firecracker_orchestrator_tracked_sandboxes", len(control_ids), "Sandboxes tracked by local orchestrator List.")
    metric(lines, "e2b_host_firecracker_orphan_processes", len(orphan_rows), "Host Firecracker processes not tracked by local orchestrator List.")
    metric(lines, "e2b_host_firecracker_orphan_oldest_age_seconds", orphan_oldest_age, "Oldest orphan Firecracker process age.")
    metric(lines, "e2b_host_firecracker_oldest_age_seconds", fc_oldest_age, "Oldest host Firecracker process age.")
    metric(lines, "e2b_host_firecracker_ppid_1_processes", sum(1 for item in fc if item["ppid"] == "1"), "Firecracker processes adopted by init.")
    metric(lines, "e2b_host_firecracker_without_unshare_wrapper", sum(1 for item in fc if item["sid"] not in wrapper_ids), "Firecracker processes without a matching unshare wrapper.")
    metric(lines, "e2b_host_unshare_wrappers_total", len(wrappers), "Firecracker unshare wrapper process count.")
    metric(lines, "e2b_host_firecracker_orphan_d_state_processes", sum(1 for item in orphan_rows if "D" in item["stat"]), "Orphan Firecracker processes in D state.")
    metric(lines, "e2b_host_firecracker_orphan_z_state_processes", sum(1 for item in orphan_rows if "Z" in item["stat"]), "Orphan Firecracker processes in Z state.")
    metric(lines, "e2b_host_nbd_active_devices", nbd_counts["active"], "NBD devices with non-zero size or attached pid.")
    metric(lines, "e2b_host_nbd_total_devices", nbd_counts["total"], "Total NBD block devices visible on the host.")
    metric(lines, "e2b_host_nbd_pid_devices", nbd_counts["pid"], "NBD devices with an attached pid.")
    metric(lines, "e2b_host_nbd_nonzero_size_devices", nbd_counts["nonzero_size"], "NBD devices with non-zero size.")
    metric(lines, "e2b_host_nbd_no_pid_nonzero_size_devices", nbd_counts["no_pid_nonzero_size"], "NBD devices with non-zero size but no attached pid.")
    metric(lines, "e2b_host_tmp_fc_sockets_total", len(socket_ids), "Firecracker API socket count under /tmp.")
    metric(lines, "e2b_host_tmp_fc_sockets_without_fc", len(socket_ids - fc_ids), "Firecracker API sockets without matching Firecracker process.")
    metric(lines, "e2b_host_netns_total", collect_netns_count(), "Network namespace count visible to ip netns.")
    metric(lines, "e2b_host_tap_devices_total", netdev_counts["tap"], "Host network interfaces whose names start with tap.")
    metric(lines, "e2b_host_veth_devices_total", netdev_counts["veth"], "Host network interfaces whose names start with veth.")
    metric(lines, "e2b_host_unshare_wrappers_without_fc", len(wrapper_ids - fc_ids), "Firecracker unshare wrapper processes without matching Firecracker child.")
    metric(lines, "e2b_host_firecracker_d_state_processes", sum(1 for item in fc if "D" in item["stat"]), "Firecracker processes in D state.")
    metric(lines, "e2b_host_firecracker_z_state_processes", sum(1 for item in fc if "Z" in item["stat"]), "Firecracker processes in Z state.")
    metric(lines, "e2b_host_orphan_control_available", control_available, "Whether local orchestrator List was available for orphan diff.")
    metric(lines, "e2b_host_orphan_audit_success", audit_success, "Whether orphan audit completed with authoritative control data.")
    metric(lines, "e2b_host_orphan_audit_duration_seconds", time.time() - started, "Orphan audit scrape duration in seconds.")
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    args = None

    def do_GET(self):
        if self.path not in ("/", "/metrics"):
            self.send_response(404)
            self.end_headers()
            return
        body = collect_metrics(self.args).encode("utf-8")
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
    parser.add_argument("--port", type=int, default=9109)
    parser.add_argument("--grpcurl", default="/opt/e2b/bin/grpcurl")
    parser.add_argument("--orchestrator-addr", default="127.0.0.1:5008")
    parser.add_argument("--grpc-timeout", type=int, default=8)
    args = parser.parse_args()
    Handler.args = args
    ThreadingHTTPServer((args.listen, args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
PY
  chmod 0755 "$EXPORTER_PATH"
}

write_service() {
  log "writing $SERVICE_PATH"
  cat >"$SERVICE_PATH" <<EOF
[Unit]
Description=E2B orphan Firecracker metrics exporter
After=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=3

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${EXPORTER_PATH} --listen ${LISTEN_ADDR} --port ${PORT} --grpcurl ${GRPCURL_PATH} --orchestrator-addr ${ORCHESTRATOR_ADDR}
Restart=always
RestartSec=30
CPUAccounting=true
MemoryAccounting=true
IOAccounting=true
CPUQuota=20%
MemoryMax=128M
TasksMax=32
Nice=10
IOSchedulingClass=idle
NoNewPrivileges=true
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
}

main() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required" >&2
    exit 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required" >&2
    exit 1
  fi

  write_exporter
  install_grpcurl
  write_service

  systemctl daemon-reload
  systemctl enable --now e2b-orphan-fc-exporter.service
  systemctl restart e2b-orphan-fc-exporter.service

  for _ in $(seq 1 10); do
    if curl -fs --max-time 10 "http://${LISTEN_ADDR}:${PORT}/metrics" 2>/dev/null | grep -q '^e2b_host_orphan_audit_success '; then
      log "orphan FC exporter is serving metrics on ${LISTEN_ADDR}:${PORT}"
      exit 0
    fi
    sleep 1
  done

  systemctl status --no-pager e2b-orphan-fc-exporter.service || true
  echo "orphan FC exporter did not serve metrics in time" >&2
  exit 1
}

main "$@"
