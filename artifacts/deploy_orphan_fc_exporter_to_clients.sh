#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK_NAME="${STACK_NAME:-}"
AWS_REGION_OPT="${AWS_REGION:-}"
DEPLOY_BRANCH="0303"
GIT_REMOTE_URL="https://github.com/aws-samples/sample-e2b-on-aws.git"
SYNC_ENV_VAR="ORPHAN_FC_EXPORTER_SCRIPT_SYNCED"
INSTALLER_PATH="$REPO_DIR/infra-iac/terraform/scripts/install-orphan-fc-exporter.sh"
CLIENT_ASG=""
SERVER_ASG=""
ARTIFACT_BUCKET=""
S3_PREFIX="e2b-orphan-fc-exporter"
GRPCURL_VERSION="1.9.3"
GRPCURL_URL="https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION}_linux_x86_64.tar.gz"
GRPCURL_SHA256=""
EXPORTER_PORT="9109"
TERRAFORM_DIR="$REPO_DIR/infra-iac/terraform"
TERRAFORM_CONFIG_FILE="/opt/config.properties"
TERRAFORM_PLAN_FILE="tfplan-orphan-fc-exporter"
NOMAD_WAIT_TIMEOUT="480"
ROLLOUT_JOB="e2b-orphan-fc-exporter-rollout-$(date -u +%Y%m%d%H%M%S)"
ROLLOUT_HCL=""
ROLLOUT_SUBMITTED=0

usage() {
  cat <<'EOF'
Usage:
  artifacts/deploy_orphan_fc_exporter_to_clients.sh

What it does:
  1. Runs a targeted Terraform apply so future client nodes install the exporter
     during boot.
  2. Uploads infra-iac/terraform/scripts/install-orphan-fc-exporter.sh to the
     cluster software bucket for the current-node rollout.
  3. Uses a temporary Nomad raw_exec system job to install/restart
     e2b-orphan-fc-exporter on current default/client nodes.
  4. Verifies http://127.0.0.1:9109/metrics on every targeted node.
  5. Patches and redeploys the otel-hugepages-collector Nomad job so the new
     orphan Firecracker metrics are scraped by the observability pipeline.

Notes:
  - Run this on the deployment/bastion host for the target cluster.
  - The script reads CFNSTACKNAME and AWSREGION from /opt/config.properties.
  - AWS/Nomad CLI credentials come from the host environment or instance role.
  - The script is idempotent and safe to rerun.
  - Future client nodes are covered after the Terraform/start-client.sh change
    in this repo is applied, because new nodes download the same installer from
    the setup/software bucket during boot.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

nomad_cmd() {
  # shellcheck disable=SC2086
  nomad ${NOMAD_CLI_EXTRA:-} "$@"
}

cleanup_on_exit() {
  if [[ "$ROLLOUT_SUBMITTED" == "1" ]]; then
    nomad_cmd job stop -purge -yes "$ROLLOUT_JOB" >/dev/null 2>&1 || true
  fi

  if [[ -n "$ROLLOUT_HCL" && -f "$ROLLOUT_HCL" ]]; then
    rm -f "$ROLLOUT_HCL"
  fi
}

trap cleanup_on_exit EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage; exit 0 ;;
    *)
      die "this one-time OP script takes no arguments; run with --help for details" ;;
  esac
done

sync_repo_once() {
  if [[ "${!SYNC_ENV_VAR:-0}" == "1" ]]; then
    return
  fi

  command -v git >/dev/null 2>&1 || die "git is required for syncing $REPO_DIR"

  local before after script_path
  script_path="$REPO_DIR/artifacts/deploy_orphan_fc_exporter_to_clients.sh"
  before="not-a-git-checkout"

  if [[ -d "$REPO_DIR/.git" ]]; then
    before="$(cd "$REPO_DIR" && git rev-parse HEAD)"

    log "syncing $REPO_DIR from origin/$DEPLOY_BRANCH"
    (
      cd "$REPO_DIR"
      git fetch origin "$DEPLOY_BRANCH"
      git checkout "$DEPLOY_BRANCH"
      git pull --ff-only origin "$DEPLOY_BRANCH"
    )
  else
    local backup_dir
    backup_dir="${REPO_DIR}.bak.$(date -u +%Y%m%d%H%M%S)"
    log "$REPO_DIR is not a git checkout; backing it up to $backup_dir"
    [[ -e "$backup_dir" ]] && die "backup path already exists: $backup_dir"
    mv "$REPO_DIR" "$backup_dir"
    git clone --branch "$DEPLOY_BRANCH" --single-branch "$GIT_REMOTE_URL" "$REPO_DIR"
  fi

  after="$(cd "$REPO_DIR" && git rev-parse HEAD)"
  echo "repo_commit_before=$before"
  echo "repo_commit_after=$after"

  export "${SYNC_ENV_VAR}=1"
  log "re-executing synced script from $script_path"
  exec "$script_path" "$@"
}

sync_repo_once "$@"

[[ -f "$INSTALLER_PATH" ]] || die "installer not found: $INSTALLER_PATH"
[[ -f "$TERRAFORM_CONFIG_FILE" ]] || die "cluster config not found: $TERRAFORM_CONFIG_FILE"
command -v aws >/dev/null 2>&1 || die "aws CLI is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

config_value() {
  local key="$1"
  grep -E "^${key}=" "$TERRAFORM_CONFIG_FILE" | tail -1 | cut -d= -f2- || true
}

if [[ -z "$STACK_NAME" ]]; then
  STACK_NAME="$(config_value CFNSTACKNAME)"
fi
if [[ -z "$AWS_REGION_OPT" ]]; then
  AWS_REGION_OPT="$(config_value AWSREGION)"
fi
[[ -n "$STACK_NAME" ]] || die "CFNSTACKNAME is required in $TERRAFORM_CONFIG_FILE"
[[ -n "$AWS_REGION_OPT" ]] || die "AWSREGION is required in $TERRAFORM_CONFIG_FILE"
AWS_ARGS=()
AWS_ARGS+=(--region "$AWS_REGION_OPT")

aws_cmd() {
  aws "${AWS_ARGS[@]}" "$@"
}

hash5() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print substr($1, 1, 5)}'
  else
    shasum -a 256 "$1" | awk '{print substr($1, 1, 5)}'
  fi
}

resolve_client_asg() {
  [[ -n "$STACK_NAME" ]] || die "--stack-name is required"
  CLIENT_ASG="${STACK_NAME}-client-asg"
}

resolve_server_asg() {
  [[ -n "$STACK_NAME" ]] || die "--stack-name is required"
  SERVER_ASG="${STACK_NAME}-server-asg"
}

resolve_artifact_bucket() {
  [[ -n "$STACK_NAME" ]] || die "--stack-name is required"

  local bucket
  bucket="$(aws_cmd cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='CFNSOFTWAREBUCKET'].OutputValue | [0]" \
    --output text 2>/dev/null || true)"

  if [[ -n "$bucket" && "$bucket" != "None" ]]; then
    ARTIFACT_BUCKET="$bucket"
    return
  fi

  local account fallback
  account="$(aws_cmd sts get-caller-identity --query Account --output text)"
  fallback="software-${STACK_NAME}-${AWS_REGION_OPT}-${account}"
  if aws_cmd s3api head-bucket --bucket "$fallback" >/dev/null 2>&1; then
    ARTIFACT_BUCKET="$fallback"
    return
  fi

  die "could not resolve artifact bucket from CloudFormation output or fallback name"
}

list_asg_instances() {
  aws_cmd autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$CLIENT_ASG" \
    --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService` || LifecycleState==`Pending`].InstanceId' \
    --output text
}

list_server_instances() {
  resolve_server_asg
  aws_cmd autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$SERVER_ASG" \
    --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService` || LifecycleState==`Pending`].InstanceId' \
    --output text
}

resolve_terraform_vars() {
  local environment custom_ami_id
  environment="${TERRAFORM_ENVIRONMENT:-}"
  custom_ami_id="${CUSTOM_AMI_ID:-}"

  if [[ -z "$environment" && -f "$TERRAFORM_CONFIG_FILE" ]]; then
    environment="$(grep -E '^CFNENVIRONMENT=' "$TERRAFORM_CONFIG_FILE" | tail -1 | cut -d= -f2- || true)"
  fi
  if [[ -z "$custom_ami_id" && -f "$TERRAFORM_CONFIG_FILE" ]]; then
    custom_ami_id="$(grep -E '^CFNCUSTOMAMI=' "$TERRAFORM_CONFIG_FILE" | tail -1 | cut -d= -f2- || true)"
  fi

  [[ -n "$environment" ]] || die "Terraform environment is required; set TERRAFORM_ENVIRONMENT or CFNENVIRONMENT in $TERRAFORM_CONFIG_FILE"
  [[ -n "$custom_ami_id" ]] || die "CUSTOM_AMI_ID is required; set CUSTOM_AMI_ID or CFNCUSTOMAMI in $TERRAFORM_CONFIG_FILE"

  TERRAFORM_ENV_RESOLVED="$environment"
  CUSTOM_AMI_ID_RESOLVED="$custom_ami_id"
}

run_terraform_apply() {
  command -v terraform >/dev/null 2>&1 || die "terraform CLI is required"
  [[ -d "$TERRAFORM_DIR" ]] || die "Terraform dir not found: $TERRAFORM_DIR"
  [[ -f "$TERRAFORM_CONFIG_FILE" ]] || die "Terraform config file not found: $TERRAFORM_CONFIG_FILE"
  [[ -f "$TERRAFORM_DIR/prepare.sh" ]] || die "Terraform prepare.sh not found in $TERRAFORM_DIR"

  log "preparing Terraform files"
  (cd "$TERRAFORM_DIR" && bash prepare.sh)

  local -a plan_args
  resolve_terraform_vars
  plan_args=(
    "-var=environment=${TERRAFORM_ENV_RESOLVED}"
    "-var=custom_ami_id=${CUSTOM_AMI_ID_RESOLVED}"
    "-out=${TERRAFORM_PLAN_FILE}"
    '-target=aws_s3_object.setup_config_objects["scripts/install-orphan-fc-exporter.sh"]'
    '-target=aws_launch_template.client'
    '-target=null_resource.client_nested_virtualization'
  )

  log "terraform plan (targeted)"
  (cd "$TERRAFORM_DIR" && terraform plan "${plan_args[@]}")

  log "terraform apply $TERRAFORM_PLAN_FILE"
  (cd "$TERRAFORM_DIR" && terraform apply "$TERRAFORM_PLAN_FILE")
}

setup_nomad_env() {
  need_cmd nomad
  need_cmd python3

  if [[ -n "${NOMAD_ADDR:-}" ]]; then
    log "using existing NOMAD_ADDR=$NOMAD_ADDR"
    nomad_cmd node status -json >/dev/null
    return
  fi

  if [[ -f "$REPO_DIR/nomad/nomad.sh" ]]; then
    log "loading Nomad CLI environment from $REPO_DIR/nomad/nomad.sh"
    if bash "$REPO_DIR/nomad/nomad.sh" >/tmp/e2b-nomad-setup.log 2>&1 && [[ -f /tmp/nomad_env.sh ]]; then
      # shellcheck source=/dev/null
      source /tmp/nomad_env.sh
    else
      log "nomad/nomad.sh did not produce a usable environment; trying direct fallback"
      tail -50 /tmp/e2b-nomad-setup.log || true
    fi
  fi

  if [[ -z "${NOMAD_ADDR:-}" || -z "${NOMAD_TOKEN:-}" ]]; then
    local server_instances server_instance server_ip infra_tokens_secret infra_tokens
    local ca_secret cert_secret key_secret

    server_instances="$(list_server_instances)"
    [[ -n "$server_instances" ]] || die "no instances found in ASG $SERVER_ASG"
    server_instance="$(awk '{print $1}' <<<"$server_instances")"
    server_ip="$(aws_cmd ec2 describe-instances \
      --instance-ids "$server_instance" \
      --query 'Reservations[0].Instances[0].PrivateIpAddress' \
      --output text)"
    [[ -n "$server_ip" && "$server_ip" != "None" ]] || die "could not resolve private IP for server instance $server_instance"

    infra_tokens_secret="$(config_value infra_tokens_secret_name)"
    [[ -n "$infra_tokens_secret" ]] || infra_tokens_secret="${STACK_NAME}-infra-tokens"
    infra_tokens="$(aws_cmd secretsmanager get-secret-value \
      --secret-id "$infra_tokens_secret" \
      --query SecretString \
      --output text)"

    export NOMAD_ADDR="https://${server_ip}:4646"
    export NOMAD_TLS_SERVER_NAME="server.${AWS_REGION_OPT}.nomad"
    export NOMAD_TOKEN
    export CONSUL_HTTP_TOKEN
    NOMAD_TOKEN="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["nomad_acl_token"])' <<<"$infra_tokens")"
    CONSUL_HTTP_TOKEN="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["consul_http_token"])' <<<"$infra_tokens")"

    ca_secret="$(config_value NOMAD_TLS_CA_SECRET)"
    cert_secret="$(config_value NOMAD_TLS_CERT_SECRET)"
    key_secret="$(config_value NOMAD_TLS_KEY_SECRET)"
    [[ -n "$ca_secret" ]] || ca_secret="${STACK_NAME}-nomad-tls-ca-cert"
    [[ -n "$cert_secret" ]] || cert_secret="${STACK_NAME}-nomad-tls-client-cert"
    [[ -n "$key_secret" ]] || key_secret="${STACK_NAME}-nomad-tls-client-key"

    mkdir -p /opt/nomad/tls
    aws_cmd secretsmanager get-secret-value --secret-id "$ca_secret" --query SecretString --output text > /opt/nomad/tls/ca.pem
    aws_cmd secretsmanager get-secret-value --secret-id "$cert_secret" --query SecretString --output text > /opt/nomad/tls/cert.pem
    aws_cmd secretsmanager get-secret-value --secret-id "$key_secret" --query SecretString --output text > /opt/nomad/tls/key.pem
    chmod 600 /opt/nomad/tls/*.pem

    export NOMAD_CACERT="/opt/nomad/tls/ca.pem"
    export NOMAD_CLIENT_CERT="/opt/nomad/tls/cert.pem"
    export NOMAD_CLIENT_KEY="/opt/nomad/tls/key.pem"
  fi

  log "checking Nomad CLI access at $NOMAD_ADDR"
  nomad_cmd node status -json >/dev/null
}

ready_node_count_for_pool() {
  local node_pool="$1"
  local node_json
  node_json="$(mktemp /tmp/e2b-nomad-nodes.XXXXXX.json)"
  nomad_cmd node status -json > "$node_json"

  python3 - "$node_json" "$node_pool" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    nodes = json.load(fh)
node_pool = sys.argv[2]

count = 0
for node in nodes:
    if node.get("Status") != "ready":
        continue
    if node.get("SchedulingEligibility") != "eligible":
        continue
    if (node.get("NodePool") or "default") != node_pool:
        continue
    count += 1
print(count)
PY
  rm -f "$node_json"
}

datacenters_for_pool_hcl() {
  local node_pool="$1"
  local node_json
  node_json="$(mktemp /tmp/e2b-nomad-nodes.XXXXXX.json)"
  nomad_cmd node status -json > "$node_json"

  python3 - "$node_json" "$node_pool" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    nodes = json.load(fh)
node_pool = sys.argv[2]

dcs = []
for node in nodes:
    if node.get("Status") != "ready":
        continue
    if node.get("SchedulingEligibility") != "eligible":
        continue
    if (node.get("NodePool") or "default") != node_pool:
        continue
    dc = node.get("Datacenter")
    if dc and dc not in dcs:
        dcs.append(dc)

if not dcs:
    raise SystemExit(f"no ready eligible nodes found for node pool {node_pool}")

print(", ".join(json.dumps(dc) for dc in dcs))
PY
  rm -f "$node_json"
}

running_allocs_for_group() {
  local job="$1"
  local group="$2"
  nomad_cmd job status "$job" \
    | awk -v group="$group" '$3 == group && $5 == "run" && $6 == "running" {print $1}'
}

print_rollout_debug() {
  local alloc
  nomad_cmd job status "$ROLLOUT_JOB" || true
  while IFS= read -r alloc; do
    [[ -z "$alloc" ]] && continue
    echo
    echo "== alloc $alloc status =="
    nomad_cmd alloc status "$alloc" || true
    echo
    echo "== alloc $alloc logs =="
    nomad_cmd alloc logs "$alloc" install | tail -120 || true
    nomad_cmd alloc logs -stderr "$alloc" install | tail -120 || true
  done < <(running_allocs_for_group "$ROLLOUT_JOB" install || true)
}

wait_rollout_job() {
  local expected="$1"
  local start now allocs alloc running success
  start="$(date +%s)"

  while true; do
    allocs="$(running_allocs_for_group "$ROLLOUT_JOB" install || true)"
    running="$(wc -l <<<"$allocs" | tr -d ' ')"
    if [[ -z "$allocs" ]]; then
      running=0
    fi

    success=0
    while IFS= read -r alloc; do
      [[ -z "$alloc" ]] && continue
      if nomad_cmd alloc logs "$alloc" install 2>/dev/null | grep -q "orphan_fc_rollout_success"; then
        success=$((success + 1))
      fi
    done <<<"$allocs"

    log "$ROLLOUT_JOB/install running=$running success=$success expected=$expected"
    if (( success >= expected )); then
      return
    fi

    now="$(date +%s)"
    if (( now - start > NOMAD_WAIT_TIMEOUT )); then
      print_rollout_debug
      die "timed out waiting for $ROLLOUT_JOB to install exporters on current client nodes"
    fi
    sleep 10
  done
}

rollout_current_clients_with_nomad() {
  local s3_uri="$1"
  local expected_nodes dc_hcl

  setup_nomad_env

  expected_nodes="$(ready_node_count_for_pool default)"
  [[ "$expected_nodes" =~ ^[0-9]+$ ]] || die "cannot resolve ready default node count: $expected_nodes"
  (( expected_nodes > 0 )) || die "no ready eligible default nodes found for current client rollout"
  dc_hcl="$(datacenters_for_pool_hcl default)"

  ROLLOUT_HCL="$(mktemp "/tmp/${ROLLOUT_JOB}.XXXXXX.hcl")"
  cat > "$ROLLOUT_HCL" <<EOF
job "$ROLLOUT_JOB" {
  type        = "system"
  datacenters = [$dc_hcl]
  node_pool   = "default"
  priority    = 100

  group "install" {
    restart {
      attempts = 0
      mode     = "fail"
    }

    task "install" {
      driver = "raw_exec"

      config {
        command = "/bin/bash"
        args = ["-lc", <<SCRIPT
set -euo pipefail
tmp=/tmp/e2b-install-orphan-fc-exporter.sh
aws s3 cp "$s3_uri" "\$tmp" --region "$AWS_REGION_OPT"
chmod 0755 "\$tmp"
export AWS_REGION="$AWS_REGION_OPT"
export GRPCURL_URL="$GRPCURL_URL"
export GRPCURL_SHA256="$GRPCURL_SHA256"
export ORPHAN_FC_EXPORTER_PORT="$EXPORTER_PORT"
/bin/bash "\$tmp"
mkdir -p /etc/systemd/system/e2b-hugepages-metrics.service.d
cat >/etc/systemd/system/e2b-hugepages-metrics.service.d/resource-limits.conf <<'UNIT'
[Unit]
StartLimitIntervalSec=300
StartLimitBurst=3

[Service]
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
UNIT
systemctl daemon-reload
systemctl restart e2b-hugepages-metrics.service
systemctl is-active e2b-orphan-fc-exporter.service
systemctl is-active e2b-hugepages-metrics.service
curl -fsS --max-time 5 "http://127.0.0.1:${EXPORTER_PORT}/metrics" | grep -E '^(e2b_host_orphan_audit_success|e2b_host_firecracker_orphan_processes|e2b_host_firecracker_ppid_1_processes|e2b_host_nbd_active_devices|e2b_host_nbd_no_pid_nonzero_size_devices|e2b_host_netns_total) '
curl -fsS --max-time 5 "http://127.0.0.1:9108/metrics" | grep -E '^(e2b_host_hugepages_free|e2b_host_hugepages_total|e2b_host_hugepages_free_sandbox_slots) '
systemctl show e2b-orphan-fc-exporter.service e2b-hugepages-metrics.service -p CPUQuotaPerSecUSec -p MemoryMax -p TasksMax -p Nice -p IOSchedulingClass -p NoNewPrivileges -p ProtectHome
echo "orphan_fc_rollout_success node=\$(hostname)"
sleep 120
SCRIPT
        ]
      }

      resources {
        cpu    = 100
        memory = 128
      }
    }
  }
}
EOF

  log "running temporary Nomad rollout job $ROLLOUT_JOB for $expected_nodes default nodes"
  nomad_cmd job run -detach "$ROLLOUT_HCL"
  ROLLOUT_SUBMITTED=1
  wait_rollout_job "$expected_nodes"
  print_rollout_debug
  nomad_cmd job stop -purge -yes "$ROLLOUT_JOB" || true
  ROLLOUT_SUBMITTED=0
  rm -f "$ROLLOUT_HCL"
  ROLLOUT_HCL=""
}

redeploy_otel_hugepages_collector() {
  setup_nomad_env

  local workdir expected running start now plan_rc
  workdir="$(mktemp -d /tmp/e2b-otel-hugepages.XXXXXX)"

  log "patching live otel-hugepages-collector Nomad job"
  nomad_cmd job inspect -json otel-hugepages-collector > "$workdir/current.json"

  python3 - "$workdir/current.json" "$workdir/patched.json" <<'PY'
import json
import sys

current_path, patched_path = sys.argv[1], sys.argv[2]

scrape_block = """        - job_name: e2b-orphan-fc
          scrape_interval: 15s
          scrape_timeout: 5s
          metrics_path: /metrics
          static_configs:
            - targets: ['127.0.0.1:9109']
              labels:
                node_pool: default
"""

metric_names = [
    "e2b_host_firecracker_processes",
    "e2b_host_firecracker_orchestrator_tracked_sandboxes",
    "e2b_host_firecracker_orphan_processes",
    "e2b_host_firecracker_orphan_oldest_age_seconds",
    "e2b_host_firecracker_oldest_age_seconds",
    "e2b_host_firecracker_ppid_1_processes",
    "e2b_host_firecracker_without_unshare_wrapper",
    "e2b_host_unshare_wrappers_total",
    "e2b_host_firecracker_orphan_d_state_processes",
    "e2b_host_firecracker_orphan_z_state_processes",
    "e2b_host_nbd_active_devices",
    "e2b_host_nbd_total_devices",
    "e2b_host_nbd_pid_devices",
    "e2b_host_nbd_nonzero_size_devices",
    "e2b_host_nbd_no_pid_nonzero_size_devices",
    "e2b_host_tmp_fc_sockets_total",
    "e2b_host_tmp_fc_sockets_without_fc",
    "e2b_host_netns_total",
    "e2b_host_tap_devices_total",
    "e2b_host_veth_devices_total",
    "e2b_host_unshare_wrappers_without_fc",
    "e2b_host_firecracker_d_state_processes",
    "e2b_host_firecracker_z_state_processes",
    "e2b_host_orphan_control_available",
    "e2b_host_orphan_audit_success",
    "e2b_host_orphan_audit_duration_seconds",
]

with open(current_path, encoding="utf-8") as fh:
    job = json.load(fh)

changed = False
patched_template = False

for group in job.get("TaskGroups") or []:
    if group.get("Name") != "otel-hugepages-collector":
        continue
    for task in group.get("Tasks") or []:
        if task.get("Name") != "start-collector":
            continue
        for tmpl in task.get("Templates") or []:
            data = tmpl.get("EmbeddedTmpl") or ""
            if "job_name: e2b-hugepages" not in data:
                continue

            if "job_name: e2b-orphan-fc" not in data:
                marker = "\nprocessors:"
                if marker not in data:
                    raise SystemExit("cannot patch scrape config: processors marker not found")
                data = data.replace(marker, "\n" + scrape_block + marker, 1)
                changed = True

            missing = [name for name in metric_names if f'"{name}"' not in data]
            if missing:
                marker = "\n  resourcedetection:"
                if marker not in data:
                    raise SystemExit("cannot patch metric allow-list: resourcedetection marker not found")
                metrics = "\n".join(f'          - "{name}"' for name in missing)
                data = data.replace(marker, "\n" + metrics + marker, 1)
                changed = True

            tmpl["EmbeddedTmpl"] = data
            patched_template = True

if not patched_template:
    raise SystemExit("otel-hugepages-collector template was not found in current Nomad job")

with open(patched_path, "w", encoding="utf-8") as fh:
    json.dump({"Job": job}, fh)

print("patched_current_job=true")
print(f"changed={str(changed).lower()}")
PY

  grep -q 'e2b-orphan-fc' "$workdir/patched.json"
  grep -q 'e2b_host_firecracker_orphan_processes' "$workdir/patched.json"

  set +e
  nomad_cmd job plan -json "$workdir/patched.json" > "$workdir/plan.out" 2>&1
  plan_rc=$?
  set -e
  if (( plan_rc > 1 )); then
    tail -80 "$workdir/plan.out" >&2 || true
    die "nomad job plan failed with exit code $plan_rc"
  fi
  echo "nomad_plan_exit=$plan_rc"

  nomad_cmd job run -json "$workdir/patched.json"

  expected="$(ready_node_count_for_pool default)"
  [[ "$expected" =~ ^[0-9]+$ ]] || die "cannot resolve ready default node count: $expected"
  (( expected > 0 )) || die "no ready eligible default nodes found for otel-hugepages-collector"

  start="$(date +%s)"
  while true; do
    running="$(nomad_cmd job status otel-hugepages-collector | awk '$3 == "otel-hugepages-collector" && $5 == "run" && $6 == "running" {count++} END {print count + 0}')"
    echo "otel-hugepages-collector/otel-hugepages-collector running=$running expected>=$expected"
    if (( running >= expected )); then
      break
    fi

    now="$(date +%s)"
    if (( now - start > NOMAD_WAIT_TIMEOUT )); then
      nomad_cmd job status otel-hugepages-collector || true
      die "timed out waiting for otel-hugepages-collector"
    fi
    sleep 10
  done

  nomad_cmd job status otel-hugepages-collector | sed -n '1,35p'
  rm -rf "$workdir"
}

main() {
  resolve_client_asg
  resolve_artifact_bucket

  local instances installer_hash s3_key s3_uri
  instances="$(list_asg_instances)"
  [[ -n "$instances" ]] || die "no instances found in ASG $CLIENT_ASG"

  installer_hash="$(hash5 "$INSTALLER_PATH")"
  s3_key="${S3_PREFIX}/install-orphan-fc-exporter-${installer_hash}.sh"
  s3_uri="s3://${ARTIFACT_BUCKET}/${s3_key}"

  echo "cluster_stack=${STACK_NAME:-unknown}"
  echo "client_asg=$CLIENT_ASG"
  echo "region=$AWS_REGION_OPT"
  echo "artifact_bucket=$ARTIFACT_BUCKET"
  echo "installer=$INSTALLER_PATH"
  echo "installer_s3_uri=$s3_uri"
  echo "grpcurl_url=$GRPCURL_URL"
  echo "exporter_port=$EXPORTER_PORT"
  echo "terraform_mode=targeted"
  echo "terraform_dir=$TERRAFORM_DIR"
  echo "terraform_config_file=$TERRAFORM_CONFIG_FILE"
  echo "server_asg=${SERVER_ASG:-${STACK_NAME}-server-asg}"
  echo "current_node_rollout=nomad_raw_exec_system_job"
  echo "rollout_job=$ROLLOUT_JOB"
  echo "instances=$(tr '\t' ' ' <<<"$instances")"

  run_terraform_apply

  log "uploading installer to $s3_uri"
  aws_cmd s3 cp "$INSTALLER_PATH" "$s3_uri"

  rollout_current_clients_with_nomad "$s3_uri"
  redeploy_otel_hugepages_collector

  log "orphan FC exporter deployment completed"
}

main "$@"
