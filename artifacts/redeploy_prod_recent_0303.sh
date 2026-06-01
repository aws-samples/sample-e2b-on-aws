#!/usr/bin/env bash
set -Eeuo pipefail

# Redeploy recent 0303 changes to an existing production E2B-on-AWS cluster.
#
# Intended operator flow:
#   sudo -i
#   bash redeploy_prod_recent_0303.sh
#
# Expected host:
#   The production setup/bastion host with /opt/config.properties, Docker,
#   AWS CLI, Nomad CLI, and access to ECR/S3/Nomad.
#
# Components redeployed by default:
#   - api: Docker image + Nomad job, API_COUNT defaults to 2
#   - client-proxy: Docker image + Nomad job, CLIENT_PROXY_COUNT defaults to 2
#   - orchestrator: S3 binary artifact is built/uploaded, but the Nomad
#     orchestrator job is not restarted by default. Restarting it in place can
#     orphan live Firecracker processes; use a drained/replaced client node or
#     an explicit maintenance-window override.
#   - template-manager: same S3 binary artifact + Nomad job restart
#   - envd: S3 binary artifact for new template/sandbox usage
#   - otel-collector: Nomad metrics/OTLP collector job
#   - otel-hugepages-collector: default-node hugepages metrics collector
#   - nomad-event-collector: Nomad deployment/eval/alloc/job/node event logs
#
# Optional knobs:
#   REPO_DIR=/opt/infra/sample-e2b-on-aws
#   DEPLOY_COMMIT=e7e1db6be5a9b5a139d9a0da370d3c08606c0765
#   IMAGE_TAG=7056a3c
#   DEPLOY_ENVD=1
#   SKIP_OBSERVABILITY=0
#   SKIP_ORCHESTRATOR=1
#   SKIP_ORCHESTRATOR=0   # only after client nodes are drained/replaced
#   CHECK_ORCHESTRATOR_HEALTH=1
#   SKIP_TEMPLATE_MANAGER=0
#   RUN_SDK_LIFECYCLE_CHECK=auto
#   SDK_VERSION=2.1.0
#   APPLY_DB_TIER_UPDATE=1
#   BASE_TIER_DISK_MB=10240
#   NOMAD_CLI_EXTRA="-tls-skip-verify"

REPO_DIR="${REPO_DIR:-/opt/infra/sample-e2b-on-aws}"
CONFIG_FILE="${CONFIG_FILE:-/opt/config.properties}"
DEPLOY_COMMIT="${DEPLOY_COMMIT:-e7e1db6be5a9b5a139d9a0da370d3c08606c0765}"
EXPECTED_BRANCH_HEAD="${EXPECTED_BRANCH_HEAD:-$DEPLOY_COMMIT}"
IMAGE_TAG="${IMAGE_TAG:-${DEPLOY_COMMIT:0:7}}"
COMMIT_SHA="${COMMIT_SHA:-$IMAGE_TAG}"
API_COUNT="${API_COUNT:-2}"
CLIENT_PROXY_COUNT="${CLIENT_PROXY_COUNT:-2}"
SANDBOX_STORAGE_BACKEND="${SANDBOX_STORAGE_BACKEND:-redis}"
DEPLOY_ENVD="${DEPLOY_ENVD:-1}"
SKIP_OBSERVABILITY="${SKIP_OBSERVABILITY:-0}"
SKIP_ORCHESTRATOR="${SKIP_ORCHESTRATOR:-1}"
CHECK_ORCHESTRATOR_HEALTH="${CHECK_ORCHESTRATOR_HEALTH:-1}"
SKIP_TEMPLATE_MANAGER="${SKIP_TEMPLATE_MANAGER:-0}"
RUN_SDK_LIFECYCLE_CHECK="${RUN_SDK_LIFECYCLE_CHECK:-auto}"
SDK_VERSION="${SDK_VERSION:-2.1.0}"
APPLY_DB_TIER_UPDATE="${APPLY_DB_TIER_UPDATE:-1}"
BASE_TIER_ID="${BASE_TIER_ID:-base_v1}"
BASE_TIER_DISK_MB="${BASE_TIER_DISK_MB:-10240}"

TMP_DIR=""
LOCK_CLEANUP_JOB="cleanup-orchestrator-lock-$(date -u +%Y%m%d%H%M%S)"
LOCK_CLEANUP_SUBMITTED=0
LOCK_CLEANUP_HCL=""

log() {
  printf '\n[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

cleanup() {
  if [[ "$LOCK_CLEANUP_SUBMITTED" == "1" ]]; then
    nomad_cmd job stop -purge -yes "$LOCK_CLEANUP_JOB" >/dev/null 2>&1 || true
  fi
  if [[ -n "$LOCK_CLEANUP_HCL" ]]; then
    rm -f "$LOCK_CLEANUP_HCL"
  fi
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

nomad_cmd() {
  local args=("$@")
  local extra=()

  if [[ -n "${NOMAD_CLI_EXTRA:-}" ]]; then
    # shellcheck disable=SC2206
    extra=(${NOMAD_CLI_EXTRA})
  fi

  if ((${#extra[@]} == 0)); then
    nomad "$@"
    return
  fi

  case "${args[0]:-}" in
    job|node|alloc|operator)
      if ((${#args[@]} >= 2)); then
        nomad "${args[0]}" "${args[1]}" "${extra[@]}" "${args[@]:2}"
      else
        nomad "${args[0]}" "${extra[@]}"
      fi
      ;;
    *)
      nomad "${args[0]}" "${extra[@]}" "${args[@]:1}"
      ;;
  esac
}

load_config() {
  [[ -f "$CONFIG_FILE" ]] || die "missing config file: $CONFIG_FILE"

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# || "$line" != *=* ]] && continue
    local key value
    key="${line%%=*}"
    value="${line#*=}"
    key="$(echo "$key" | xargs)"
    value="$(echo "$value" | xargs)"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    export "$key=$value"
  done < "$CONFIG_FILE"

  JFROG_ARTIFACTORY_URL="${jfrog_artifactory_url:-${JFROGARTIFACTORYURL:-https://artifactory.aic.aws.zoomdev.us/artifactory}}"
  JFROG_ARTIFACTORY_URL="${JFROG_ARTIFACTORY_URL%/}"
  JFROG_GENERIC_URL="${JFROG_ARTIFACTORY_URL}/zoom-generic-virtual"

  [[ -n "${AWSREGION:-}" ]] || die "AWSREGION is missing from $CONFIG_FILE"
  export AWS_REGION="$AWSREGION"
  export AWS_DEFAULT_REGION="$AWSREGION"
  export JFROG_ARTIFACTORY_URL JFROG_GENERIC_URL
}

setup_go_env() {
  export HOME="${HOME:-/root}"
  export GOPATH="${GOPATH:-$HOME/go}"
  export GOMODCACHE="${GOMODCACHE:-$GOPATH/pkg/mod}"
  export GOCACHE="${GOCACHE:-$HOME/.cache/go-build}"
  mkdir -p "$GOMODCACHE" "$GOCACHE" "$GOPATH/bin"
}

setup_nomad_env() {
  if [[ -n "${NOMAD_ADDR:-}" ]]; then
    return 0
  fi

  [[ -f "$REPO_DIR/nomad/nomad.sh" ]] || die "NOMAD_ADDR is empty and $REPO_DIR/nomad/nomad.sh is missing"
  log "Loading Nomad CLI environment from $REPO_DIR/nomad/nomad.sh"
  set +u
  # shellcheck source=/dev/null
  source "$REPO_DIR/nomad/nomad.sh"
  set -u
}

download_source_archive() {
  local archive_url archive_file extracted
  archive_url="${JFROG_GENERIC_URL}/aws-samples/sample-e2b-on-aws/archive/${DEPLOY_COMMIT}.zip"
  TMP_DIR="$(mktemp -d)"
  archive_file="$TMP_DIR/sample-e2b-on-aws.zip"

  log "Downloading source archive for $DEPLOY_COMMIT"
  if command -v curl >/dev/null 2>&1; then
    curl -fL "$archive_url" -o "$archive_file"
  else
    wget -O "$archive_file" "$archive_url"
  fi

  unzip -q "$archive_file" -d "$TMP_DIR"
  extracted="$TMP_DIR/sample-e2b-on-aws-$DEPLOY_COMMIT"
  [[ -d "$extracted" ]] || die "archive did not contain expected directory: $extracted"

  log "Installing source into $REPO_DIR"
  mkdir -p "$(dirname "$REPO_DIR")"
  if [[ -e "$REPO_DIR" ]]; then
    mv "$REPO_DIR" "${REPO_DIR}.bak.$(date -u +%Y%m%d%H%M%S)"
  fi
  mv "$extracted" "$REPO_DIR"
}

preflight() {
  log "Preflight"
  [[ "$(id -u)" -eq 0 ]] || die "run as root, for example: sudo -i && bash $0"

  need_cmd aws
  need_cmd docker
  need_cmd make
  need_cmd nomad
  need_cmd unzip
  need_cmd jq
  need_cmd python3
  need_cmd curl
  need_cmd psql

  load_config
  setup_go_env

  docker info >/dev/null
  aws sts get-caller-identity >/dev/null

  echo "expected_branch_head=$EXPECTED_BRANCH_HEAD"
  echo "deploy_commit=$DEPLOY_COMMIT"
  echo "image_tag=$IMAGE_TAG"
  echo "api_count=$API_COUNT"
  echo "client_proxy_count=$CLIENT_PROXY_COUNT"
  echo "sandbox_storage_backend=$SANDBOX_STORAGE_BACKEND"
  echo "check_orchestrator_health=$CHECK_ORCHESTRATOR_HEALTH"
  echo "run_sdk_lifecycle_check=$RUN_SDK_LIFECYCLE_CHECK"
  echo "sdk_version=$SDK_VERSION"
  echo "apply_db_tier_update=$APPLY_DB_TIER_UPDATE"
  echo "base_tier_id=$BASE_TIER_ID"
  echo "base_tier_disk_mb=$BASE_TIER_DISK_MB"
  echo "aws_region=$AWSREGION"
  echo "stack_name=${CFNSTACKNAME:-${AWSSTACKNAME:-}}"
  echo "domain=${CFNDOMAIN:-}"
}

db_query() {
  local sql="$1"
  local db_secret_json db_host db_port db_name db_user db_password

  [[ -n "${CFNDBCredentialSecretName:-}" ]] || die "CFNDBCredentialSecretName is missing from $CONFIG_FILE"

  db_secret_json="$(aws secretsmanager get-secret-value \
    --secret-id "$CFNDBCredentialSecretName" \
    --query SecretString \
    --output text)"

  db_host="$(jq -r '.host' <<< "$db_secret_json")"
  db_port="$(jq -r '.port // 5432' <<< "$db_secret_json")"
  db_name="$(jq -r '.dbname' <<< "$db_secret_json")"
  db_user="$(jq -r '.username' <<< "$db_secret_json")"
  db_password="$(jq -r '.password' <<< "$db_secret_json")"

  [[ -n "$db_host" && "$db_host" != "null" ]] || die "database host is missing in $CFNDBCredentialSecretName"
  [[ -n "$db_port" && "$db_port" != "null" ]] || die "database port is missing in $CFNDBCredentialSecretName"
  [[ -n "$db_name" && "$db_name" != "null" ]] || die "database name is missing in $CFNDBCredentialSecretName"
  [[ -n "$db_user" && "$db_user" != "null" ]] || die "database username is missing in $CFNDBCredentialSecretName"
  [[ -n "$db_password" && "$db_password" != "null" ]] || die "database password is missing in $CFNDBCredentialSecretName"

  PGPASSWORD="$db_password" psql \
    -h "$db_host" \
    -p "$db_port" \
    -U "$db_user" \
    -d "$db_name" \
    -v ON_ERROR_STOP=1 \
    -At \
    -c "$sql"
}

assert_base_tier_disk_config() {
  local current_disk

  [[ "$BASE_TIER_ID" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "BASE_TIER_ID has unsupported characters: $BASE_TIER_ID"
  [[ "$BASE_TIER_DISK_MB" =~ ^[0-9]+$ ]] || die "BASE_TIER_DISK_MB must be an integer: $BASE_TIER_DISK_MB"

  current_disk="$(db_query "SELECT disk_mb FROM public.tiers WHERE id = '$BASE_TIER_ID';" | tail -1 | xargs)"
  [[ -n "$current_disk" ]] || die "tier $BASE_TIER_ID was not found in public.tiers"
  [[ "$current_disk" == "$BASE_TIER_DISK_MB" ]] || die "tier $BASE_TIER_ID disk_mb=$current_disk, expected $BASE_TIER_DISK_MB"

  log "Verified $BASE_TIER_ID disk_mb=$current_disk"
}

apply_base_tier_disk_config() {
  if [[ "$APPLY_DB_TIER_UPDATE" != "1" ]]; then
    log "Skipping DB tier update because APPLY_DB_TIER_UPDATE=$APPLY_DB_TIER_UPDATE"
    return 0
  fi

  [[ "$BASE_TIER_ID" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "BASE_TIER_ID has unsupported characters: $BASE_TIER_ID"
  [[ "$BASE_TIER_DISK_MB" =~ ^[0-9]+$ ]] || die "BASE_TIER_DISK_MB must be an integer: $BASE_TIER_DISK_MB"

  log "Apply base tier disk config: $BASE_TIER_ID disk_mb=$BASE_TIER_DISK_MB"
  db_query "UPDATE public.tiers SET disk_mb = $BASE_TIER_DISK_MB WHERE id = '$BASE_TIER_ID';" >/dev/null
  assert_base_tier_disk_config
}

build_and_upload() {
  export IMAGE_TAG COMMIT_SHA API_COUNT CLIENT_PROXY_COUNT SANDBOX_STORAGE_BACKEND

  log "Build and push API image"
  cd "$REPO_DIR/packages/api"
  GOTOOLCHAIN=auto make build-and-upload-aws COMMIT_SHA="$COMMIT_SHA"

  log "Build and push client-proxy image"
  cd "$REPO_DIR/packages/client-proxy"
  GOTOOLCHAIN=auto make build-and-upload-aws COMMIT_SHA="$COMMIT_SHA"

  log "Build and upload orchestrator/template-manager artifact"
  cd "$REPO_DIR/packages/orchestrator"
  GOTOOLCHAIN=auto make build-and-upload COMMIT_SHA="$COMMIT_SHA"

  if [[ "$DEPLOY_ENVD" == "1" ]]; then
    log "Build and upload envd artifact"
    cd "$REPO_DIR/packages/envd"
    GOTOOLCHAIN=auto make build-and-upload COMMIT_SHA="$COMMIT_SHA"
  else
    log "Skipping envd upload because DEPLOY_ENVD=$DEPLOY_ENVD"
  fi
}

render_nomad_jobs() {
  export IMAGE_TAG COMMIT_SHA API_COUNT CLIENT_PROXY_COUNT SANDBOX_STORAGE_BACKEND

  log "Render Nomad jobs"
  cd "$REPO_DIR/nomad"
  bash prepare.sh

  grep -q "count = $API_COUNT" deploy/api-deploy.hcl || die "api count was not rendered as $API_COUNT"
  grep -q "count = $CLIENT_PROXY_COUNT" deploy/edge-deploy.hcl || die "client-proxy count was not rendered as $CLIENT_PROXY_COUNT"
  grep -q "SANDBOX_STORAGE_BACKEND.*\"$SANDBOX_STORAGE_BACKEND\"" deploy/api-deploy.hcl || die "SANDBOX_STORAGE_BACKEND was not rendered as $SANDBOX_STORAGE_BACKEND"
  grep -q "e2b-orchestration/api:$IMAGE_TAG" deploy/api-deploy.hcl || die "api image tag was not rendered as $IMAGE_TAG"
  grep -q "e2b-orchestration/client-proxy:$IMAGE_TAG" deploy/edge-deploy.hcl || die "client-proxy image tag was not rendered as $IMAGE_TAG"
  grep -q "USE_CATALOG_RESOLUTION = \"true\"" deploy/edge-deploy.hcl || die "client-proxy catalog resolution is not enabled"
  [[ -f deploy/otel-collector-deploy.hcl ]] || die "missing otel-collector deploy HCL"
  [[ -f deploy/otel-hugepages-collector-deploy.hcl ]] || die "missing otel-hugepages-collector deploy HCL"
  [[ -f deploy/nomad-event-collector-deploy.hcl ]] || die "missing nomad-event-collector deploy HCL"
}

nomad_plan() {
  local file="$1"
  log "Nomad plan $file"
  set +e
  nomad_cmd job plan "$file"
  local rc=$?
  set -e
  if (( rc > 1 )); then
    die "nomad job plan failed for $file with exit code $rc"
  fi
}

running_alloc_count() {
  local job="$1"
  local group="$2"
  nomad_cmd job status "$job" \
    | awk -v group="$group" '$3 == group && $5 == "run" && $6 == "running" {count++} END {print count + 0}'
}

wait_running_allocs() {
  local job="$1"
  local group="$2"
  local min_count="$3"
  local timeout_seconds="${4:-360}"
  local start now count
  start="$(date +%s)"

  while true; do
    count="$(running_alloc_count "$job" "$group")"
    echo "$job/$group running=$count expected>=$min_count"
    if (( count >= min_count )); then
      return 0
    fi

    now="$(date +%s)"
    if (( now - start > timeout_seconds )); then
      nomad_cmd job status "$job" || true
      die "timed out waiting for $job/$group running allocations"
    fi

    sleep 10
  done
}

wait_no_running_allocs() {
  local job="$1"
  local group="$2"
  local timeout_seconds="${3:-240}"
  local start now count
  start="$(date +%s)"

  while true; do
    count="$(running_alloc_count "$job" "$group")"
    echo "$job/$group running=$count expected=0"
    if (( count == 0 )); then
      return 0
    fi

    now="$(date +%s)"
    if (( now - start > timeout_seconds )); then
      nomad_cmd job status "$job" || true
      die "timed out waiting for $job/$group running allocations to stop"
    fi

    sleep 10
  done
}

assert_job_healthy() {
  local job="$1"
  local group="$2"
  local expected_count="$3"
  local status_output running_count bad_allocs

  log "Check Nomad job health: $job/$group"
  status_output="$(nomad_cmd job status "$job")"
  printf '%s\n' "$status_output"

  running_count="$(awk -v group="$group" '$3 == group && $5 == "run" && $6 == "running" {count++} END {print count + 0}' <<< "$status_output")"
  bad_allocs="$(awk -v group="$group" '$3 == group && $5 == "run" && $6 != "running" {print "  " $1 " desired=" $5 " status=" $6}' <<< "$status_output")"

  if (( running_count < expected_count )); then
    die "$job/$group has $running_count running allocations, expected at least $expected_count"
  fi

  if [[ -n "$bad_allocs" ]]; then
    printf '%s\n' "$bad_allocs" >&2
    die "$job/$group has non-running desired allocations"
  fi
}

job_datacenters() {
  local job="$1"
  local job_json
  job_json="$TMP_DIR/${job}-dcs.json"

  nomad_cmd job inspect -json "$job" > "$job_json"
  python3 - "$job_json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    job = json.load(fh)
print(",".join(job.get("Datacenters") or []))
PY
}

default_ready_node_count_for_job() {
  local job="$1"
  local job_json node_json
  job_json="$TMP_DIR/${job}-job.json"
  node_json="$TMP_DIR/${job}-nodes.json"

  nomad_cmd job inspect -json "$job" > "$job_json"
  nomad_cmd node status -json > "$node_json"

  python3 - "$job_json" "$node_json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    job = json.load(fh)
with open(sys.argv[2], encoding="utf-8") as fh:
    nodes = json.load(fh)

dcs = set(job.get("Datacenters") or [])
node_pool = job.get("NodePool") or "default"
count = 0
for node in nodes:
    if dcs and node.get("Datacenter") not in dcs:
        continue
    if node.get("Status") != "ready":
        continue
    if node.get("SchedulingEligibility") != "eligible":
        continue
    if node_pool not in ("", "all") and (node.get("NodePool") or "default") != node_pool:
        continue
    count += 1
print(count)
PY
}

wait_lock_cleanup_job() {
  local expected_count="$1"
  local timeout_seconds="${2:-120}"
  local start now status_output running_count
  start="$(date +%s)"

  while true; do
    status_output="$(nomad_cmd job status "$LOCK_CLEANUP_JOB" || true)"
    printf '%s\n' "$status_output"

    if awk '$3 == "cleanup" && ($6 == "failed" || $6 == "lost") {found=1} END {exit found ? 0 : 1}' <<< "$status_output"; then
      die "$LOCK_CLEANUP_JOB has failed or lost allocations"
    fi

    running_count="$(awk '$3 == "cleanup" && $5 == "run" && $6 == "running" {count++} END {print count + 0}' <<< "$status_output")"
    if (( running_count >= expected_count )); then
      return 0
    fi

    now="$(date +%s)"
    if (( now - start > timeout_seconds )); then
      die "timed out waiting for $LOCK_CLEANUP_JOB to run"
    fi

    sleep 5
  done
}

cleanup_orchestrator_lock() {
  local dcs expected_nodes dc_hcl dc
  dcs="$(job_datacenters orchestrator)"
  [[ -n "$dcs" ]] || die "cannot resolve orchestrator datacenters"

  expected_nodes="$(ready_node_count_for_pool default)"
  [[ "$expected_nodes" =~ ^[0-9]+$ ]] || die "cannot resolve default node count for orchestrator lock cleanup"
  (( expected_nodes > 0 )) || die "no ready eligible default nodes for orchestrator lock cleanup"

  dc_hcl=""
  IFS=',' read -r -a dc_arr <<< "$dcs"
  for dc in "${dc_arr[@]}"; do
    [[ -n "$dc_hcl" ]] && dc_hcl+=", "
    dc_hcl+="\"$dc\""
  done

  LOCK_CLEANUP_HCL="/tmp/${LOCK_CLEANUP_JOB}.hcl"
  cat > "$LOCK_CLEANUP_HCL" <<EOF
job "$LOCK_CLEANUP_JOB" {
  type        = "system"
  datacenters = [$dc_hcl]
  node_pool   = "default"
  priority    = 100

  group "cleanup" {
    restart {
      attempts = 0
      mode     = "fail"
    }

    task "rm-lock" {
      driver = "raw_exec"
      config {
        command = "/bin/bash"
        args    = ["-lc", "set -euxo pipefail; pgrep -af 'local/orchestrator|/orchestrator --port' || true; rm -f /orchestrator.lock; test ! -e /orchestrator.lock; echo removed /orchestrator.lock on \$(hostname); sleep 60"]
      }
      resources {
        cpu    = 100
        memory = 128
      }
    }
  }
}
EOF

  log "Cleanup stale /orchestrator.lock on default nodes"
  nomad_cmd job run -detach "$LOCK_CLEANUP_HCL"
  LOCK_CLEANUP_SUBMITTED=1
  wait_lock_cleanup_job "$expected_nodes" 120
  nomad_cmd job stop -purge -yes "$LOCK_CLEANUP_JOB" || true
  LOCK_CLEANUP_SUBMITTED=0
  rm -f "$LOCK_CLEANUP_HCL"
  LOCK_CLEANUP_HCL=""
}

ready_node_count_for_pool() {
  local node_pool="$1"
  local node_json
  node_json="$TMP_DIR/nodes-${node_pool}.json"
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
    if node_pool not in ("", "all") and (node.get("NodePool") or "default") != node_pool:
        continue
    count += 1
print(count)
PY
}

deploy_observability_jobs() {
  cd "$REPO_DIR/nomad"

  if [[ "$SKIP_OBSERVABILITY" == "1" ]]; then
    log "Skipping observability jobs because SKIP_OBSERVABILITY=$SKIP_OBSERVABILITY"
    return 0
  fi

  local expected_otel expected_hugepages
  expected_otel="$(default_ready_node_count_for_job otel-collector)"
  [[ "$expected_otel" =~ ^[0-9]+$ ]] || die "cannot resolve otel-collector expected allocation count"
  (( expected_otel > 0 )) || die "no ready eligible nodes for otel-collector"

  expected_hugepages="$(ready_node_count_for_pool default)"
  [[ "$expected_hugepages" =~ ^[0-9]+$ ]] || die "cannot resolve default node count for otel-hugepages-collector"
  (( expected_hugepages > 0 )) || die "no ready eligible default nodes for otel-hugepages-collector"

  nomad_plan deploy/otel-collector-deploy.hcl
  log "Deploy otel-collector"
  nomad_cmd job run deploy/otel-collector-deploy.hcl
  wait_running_allocs otel-collector otel-collector "$expected_otel" 480

  nomad_plan deploy/otel-hugepages-collector-deploy.hcl
  log "Deploy otel-hugepages-collector"
  nomad_cmd job run deploy/otel-hugepages-collector-deploy.hcl
  wait_running_allocs otel-hugepages-collector otel-hugepages-collector "$expected_hugepages" 480

  nomad_plan deploy/nomad-event-collector-deploy.hcl
  log "Deploy nomad-event-collector"
  nomad_cmd job run deploy/nomad-event-collector-deploy.hcl
  wait_running_allocs nomad-event-collector nomad-event-collector 1 300
}

deploy_docker_jobs() {
  cd "$REPO_DIR/nomad"

  local ready_api_nodes
  ready_api_nodes="$(ready_node_count_for_pool api)"
  [[ "$ready_api_nodes" =~ ^[0-9]+$ ]] || die "cannot resolve api node count"
  if (( ready_api_nodes < API_COUNT || ready_api_nodes < CLIENT_PROXY_COUNT )); then
    die "api node_pool has $ready_api_nodes ready eligible nodes; need >= API_COUNT=$API_COUNT and >= CLIENT_PROXY_COUNT=$CLIENT_PROXY_COUNT because both jobs use distinct_hosts. Scale the API ASG first or lower the counts intentionally."
  fi

  nomad_plan deploy/api-deploy.hcl
  log "Deploy api"
  nomad_cmd job run deploy/api-deploy.hcl
  wait_running_allocs api api-service "$API_COUNT" 480

  nomad_plan deploy/edge-deploy.hcl
  log "Deploy client-proxy"
  nomad_cmd job run deploy/edge-deploy.hcl
  wait_running_allocs client-proxy client-proxy "$CLIENT_PROXY_COUNT" 480
}

restart_raw_exec_jobs() {
  cd "$REPO_DIR/nomad"

  if [[ "$SKIP_TEMPLATE_MANAGER" != "1" ]]; then
    nomad_plan deploy/template-manager-deploy.hcl
    log "Refresh template-manager jobspec and restart allocation"
    nomad_cmd job run deploy/template-manager-deploy.hcl
    nomad_cmd job restart -reschedule -yes -batch-size=100% -on-error=fail template-manager
    wait_running_allocs template-manager template-manager 1 300
  else
    log "Skipping template-manager because SKIP_TEMPLATE_MANAGER=$SKIP_TEMPLATE_MANAGER"
  fi

  if [[ "$SKIP_ORCHESTRATOR" != "1" ]]; then
    local expected_orchestrators
    log "WARNING: restarting the orchestrator job in place can orphan live Firecracker processes. Continue only for a drained/replaced client node or an approved maintenance window."
    expected_orchestrators="$(default_ready_node_count_for_job orchestrator)"
    [[ "$expected_orchestrators" =~ ^[0-9]+$ ]] || die "cannot resolve orchestrator expected allocation count"
    (( expected_orchestrators > 0 )) || die "no ready eligible nodes for orchestrator"

    nomad_plan deploy/orchestrator-deploy.hcl
    log "Stop orchestrator before lock cleanup"
    nomad_cmd job stop -yes orchestrator
    wait_no_running_allocs orchestrator client-orchestrator 240
    cleanup_orchestrator_lock

    log "Start orchestrator from rendered HCL"
    nomad_cmd job run deploy/orchestrator-deploy.hcl
    wait_running_allocs orchestrator client-orchestrator "$expected_orchestrators" 600
  else
    log "Skipping orchestrator Nomad restart because SKIP_ORCHESTRATOR=$SKIP_ORCHESTRATOR; orchestrator/template-manager artifact was still built and uploaded."
  fi
}

stack_prefix() {
  printf '%s' "${CFNSTACKNAME:-${AWSSTACKNAME:-${StackName:-}}}"
}

check_target_group_health() {
  local target_group_name="$1"
  local expected_healthy="$2"
  local arn states healthy_count bad_states

  log "Check ALB target group health: $target_group_name"
  arn="$(aws elbv2 describe-target-groups \
    --names "$target_group_name" \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text 2>/dev/null || true)"

  if [[ -z "$arn" || "$arn" == "None" ]]; then
    die "target group not found: $target_group_name"
  fi

  states="$(aws elbv2 describe-target-health \
    --target-group-arn "$arn" \
    --query 'TargetHealthDescriptions[].TargetHealth.State' \
    --output text)"
  printf '%s states: %s\n' "$target_group_name" "$states"

  healthy_count="$(tr '\t ' '\n' <<< "$states" | grep -cx 'healthy' || true)"
  bad_states="$(tr '\t ' '\n' <<< "$states" | grep -Ev '^(healthy)?$' || true)"

  if (( healthy_count < expected_healthy )); then
    die "$target_group_name has $healthy_count healthy targets, expected at least $expected_healthy"
  fi

  if [[ -n "$bad_states" ]]; then
    printf '%s\n' "$bad_states" >&2
    die "$target_group_name has non-healthy targets"
  fi
}

check_http_health() {
  local name="$1"
  local url="$2"

  log "Check HTTP health: $name"
  curl -fsS --max-time 10 "$url" >/tmp/e2b-health-response.txt
  printf '%s %s -> %s\n' "$name" "$url" "$(cat /tmp/e2b-health-response.txt)"
}

run_sdk_lifecycle_check() {
  case "$RUN_SDK_LIFECYCLE_CHECK" in
    0|false|False|FALSE|no|No|NO)
      log "Skipping SDK lifecycle check because RUN_SDK_LIFECYCLE_CHECK=$RUN_SDK_LIFECYCLE_CHECK"
      return 0
      ;;
    1|true|True|TRUE|yes|Yes|YES|auto)
      ;;
    *)
      die "RUN_SDK_LIFECYCLE_CHECK must be 0, 1, or auto; got $RUN_SDK_LIFECYCLE_CHECK"
      ;;
  esac

  if [[ "$RUN_SDK_LIFECYCLE_CHECK" == "auto" && -z "${E2B_API_KEY:-${E2B_TEAM_API_KEY:-}}" ]]; then
    log "Skipping SDK lifecycle check because RUN_SDK_LIFECYCLE_CHECK=auto and E2B_API_KEY/E2B_TEAM_API_KEY is not set"
    return 0
  fi

  if [[ "$RUN_SDK_LIFECYCLE_CHECK" == "auto" && -z "${E2B_DOMAIN:-${CFNDOMAIN:-}}" ]]; then
    log "Skipping SDK lifecycle check because RUN_SDK_LIFECYCLE_CHECK=auto and E2B_DOMAIN/CFNDOMAIN is not set"
    return 0
  fi

  [[ -f "$REPO_DIR/test_use_case/sdk_lifecycle_execute_report.py" ]] || die "missing SDK lifecycle script"
  [[ -n "${E2B_API_KEY:-${E2B_TEAM_API_KEY:-}}" ]] || die "E2B_API_KEY/E2B_TEAM_API_KEY is required for SDK lifecycle check"
  [[ -n "${E2B_DOMAIN:-${CFNDOMAIN:-}}" ]] || die "E2B_DOMAIN/CFNDOMAIN is required for SDK lifecycle check"

  log "Run SDK lifecycle check with e2b==$SDK_VERSION"
  cd "$REPO_DIR"
  python3 -m venv "$TMP_DIR/e2b-sdk-check"
  "$TMP_DIR/e2b-sdk-check/bin/python" -m pip install --upgrade pip >/dev/null
  "$TMP_DIR/e2b-sdk-check/bin/python" -m pip install "e2b==$SDK_VERSION" >/dev/null

  E2B_DOMAIN="${E2B_DOMAIN:-${CFNDOMAIN:-}}" \
    E2B_API_KEY="${E2B_API_KEY:-${E2B_TEAM_API_KEY:-}}" \
    "$TMP_DIR/e2b-sdk-check/bin/python" test_use_case/sdk_lifecycle_execute_report.py
}

post_checks() {
  local prefix api_health_url

  log "Component health checks"
  assert_job_healthy api api-service "$API_COUNT"
  assert_job_healthy client-proxy client-proxy "$CLIENT_PROXY_COUNT"

  if [[ "$SKIP_OBSERVABILITY" != "1" ]]; then
    assert_job_healthy otel-collector otel-collector "$(default_ready_node_count_for_job otel-collector)"
    assert_job_healthy otel-hugepages-collector otel-hugepages-collector "$(ready_node_count_for_pool default)"
    assert_job_healthy nomad-event-collector nomad-event-collector 1
  fi
  [[ "$SKIP_TEMPLATE_MANAGER" == "1" ]] || assert_job_healthy template-manager template-manager 1
  if [[ "$CHECK_ORCHESTRATOR_HEALTH" == "1" ]]; then
    assert_job_healthy orchestrator client-orchestrator "$(default_ready_node_count_for_job orchestrator)"
  else
    log "Skipping orchestrator health check because CHECK_ORCHESTRATOR_HEALTH=$CHECK_ORCHESTRATOR_HEALTH"
  fi

  prefix="$(stack_prefix)"
  if [[ -n "$prefix" ]]; then
    check_target_group_health "${prefix}-e2b-api" "$API_COUNT"
    check_target_group_health "${prefix}-client-proxy" "$CLIENT_PROXY_COUNT"
  else
    log "CFNSTACKNAME/AWSSTACKNAME not found in config; skip ALB target group health checks"
  fi

  if [[ -n "${E2B_API_BASE:-}" ]]; then
    api_health_url="${E2B_API_BASE%/}/health"
  elif [[ -n "${CFNDOMAIN:-}" ]]; then
    api_health_url="https://api.${CFNDOMAIN}/health"
  else
    log "CFNDOMAIN not found in config; skip public API health check"
    api_health_url=""
  fi

  if [[ -n "$api_health_url" ]]; then
    check_http_health api "$api_health_url"
  fi

  if [[ "$APPLY_DB_TIER_UPDATE" == "1" ]]; then
    assert_base_tier_disk_config
  fi

  run_sdk_lifecycle_check
  log "Post-deploy health checks passed"
}

main() {
  preflight
  download_source_archive
  setup_nomad_env
  nomad_cmd job status >/dev/null
  apply_base_tier_disk_config
  build_and_upload
  render_nomad_jobs
  deploy_observability_jobs
  deploy_docker_jobs
  restart_raw_exec_jobs
  post_checks

  log "Redeploy completed"
}

main "$@"
