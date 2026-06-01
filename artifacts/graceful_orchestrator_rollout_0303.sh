#!/usr/bin/env bash
set -Eeuo pipefail

# Gracefully roll out a new orchestrator artifact from the setup/bastion host.
#
# Flow per original client node:
#   1. Mark one old orchestrator as draining through client-proxy.
#   2. Wait DRAIN_HOLD_SECONDS, default 300 seconds.
#   3. Optionally require that the old orchestrator reports zero running sandboxes.
#   4. Scale the client ASG out by one node.
#   5. Wait for the new EC2/Nomad/orchestrator node to become healthy.
#   6. Terminate the old client instance with desired-capacity decrement.
#
# Intended operator flow:
#   sudo -i
#   cd /opt/infra/sample-e2b-on-aws
#   bash artifacts/graceful_orchestrator_rollout_0303.sh
#
# Useful knobs:
#   DEPLOY_COMMIT=<full source commit>        # defaults to the script pin below or current git HEAD
#   BUILD_AND_UPLOAD_ORCHESTRATOR=1           # build/upload S3 orchestrator artifact first
#   DOWNLOAD_SOURCE_ARCHIVE=auto              # download exact DEPLOY_COMMIT archive for build
#   ROLL_TARGET_INSTANCE_IDS="i-... i-..."    # default: initial healthy InService client ASG nodes
#   DRAIN_HOLD_SECONDS=300
#   REQUIRE_ZERO_RUNNING_SANDBOXES=1
#   WAIT_DRAIN_TIMEOUT_SECONDS=1800
#   WAIT_NEW_TIMEOUT_SECONDS=1800
#   ALLOW_INCREASE_ASG_MAX=1
#   ALLOW_TERMINATE_CLIENT_NODE=1
#   ALLOW_TERMINATE_WITH_RUNNING_SANDBOXES=0
#   EDGE_API_BASE=http://<client-proxy-ip>:3001
#   EDGE_SECRET=<admin_token>                 # auto-loaded from infra_tokens_secret_name
#   NOMAD_CLI_EXTRA="-tls-skip-verify"

CONFIG_FILE="${CONFIG_FILE:-/opt/config.properties}"
REPO_DIR="${REPO_DIR:-/opt/infra/sample-e2b-on-aws}"
CLIENT_ASG_NAME="${CLIENT_ASG_NAME:-}"

DEPLOY_COMMIT="${DEPLOY_COMMIT:-}"
IMAGE_TAG="${IMAGE_TAG:-}"
COMMIT_SHA="${COMMIT_SHA:-}"
BUILD_AND_UPLOAD_ORCHESTRATOR="${BUILD_AND_UPLOAD_ORCHESTRATOR:-1}"
DOWNLOAD_SOURCE_ARCHIVE="${DOWNLOAD_SOURCE_ARCHIVE:-auto}"

ROLL_TARGET_INSTANCE_IDS="${ROLL_TARGET_INSTANCE_IDS:-}"
DRAIN_HOLD_SECONDS="${DRAIN_HOLD_SECONDS:-300}"
REQUIRE_ZERO_RUNNING_SANDBOXES="${REQUIRE_ZERO_RUNNING_SANDBOXES:-1}"
WAIT_DRAIN_TIMEOUT_SECONDS="${WAIT_DRAIN_TIMEOUT_SECONDS:-1800}"
WAIT_NEW_TIMEOUT_SECONDS="${WAIT_NEW_TIMEOUT_SECONDS:-1800}"
WAIT_POLL_SECONDS="${WAIT_POLL_SECONDS:-15}"

ALLOW_SCALE_OUT_CLIENT_NODE="${ALLOW_SCALE_OUT_CLIENT_NODE:-1}"
ALLOW_INCREASE_ASG_MAX="${ALLOW_INCREASE_ASG_MAX:-1}"
ALLOW_TERMINATE_CLIENT_NODE="${ALLOW_TERMINATE_CLIENT_NODE:-1}"
ALLOW_TERMINATE_WITH_RUNNING_SANDBOXES="${ALLOW_TERMINATE_WITH_RUNNING_SANDBOXES:-0}"

EDGE_API_BASE="${EDGE_API_BASE:-}"
EDGE_SECRET="${EDGE_SECRET:-}"
EDGE_PORT="${EDGE_PORT:-3001}"
ORCHESTRATOR_PORT="${ORCHESTRATOR_PORT:-5008}"

TMP_DIR=""
BUILD_REPO_DIR=""

log() {
  printf '\n[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

warn() {
  printf '\n[%s] WARNING: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

aws_region() {
  aws --region "$AWSREGION" "$@"
}

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

normalize_jfrog_artifactory_url() {
  local value="$1"
  value="${value%/}"

  if [[ "$value" != http://* && "$value" != https://* ]]; then
    value="https://${value}"
  fi
  if [[ "$value" != */artifactory ]]; then
    value="${value}/artifactory"
  fi

  printf '%s' "$value"
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

  [[ -n "${AWSREGION:-}" ]] || die "AWSREGION is missing from $CONFIG_FILE"
  [[ -n "${CFNSTACKNAME:-}" ]] || die "CFNSTACKNAME is missing from $CONFIG_FILE"

  export AWS_REGION="$AWSREGION"
  export AWS_DEFAULT_REGION="$AWSREGION"

  CLIENT_ASG_NAME="${CLIENT_ASG_NAME:-${CFNSTACKNAME}-client-asg}"
  JFROG_ARTIFACTORY_URL="${JFROG_ARTIFACTORY_URL:-${jfrog_artifactory_url:-${JFROGARTIFACTORYURL:-https://artifactory.aic.aws.zoomdev.us/artifactory}}}"
  JFROG_ARTIFACTORY_URL="$(normalize_jfrog_artifactory_url "$JFROG_ARTIFACTORY_URL")"
  JFROG_GENERIC_URL="${JFROG_ARTIFACTORY_URL}/zoom-generic-virtual"
  export JFROG_ARTIFACTORY_URL JFROG_GENERIC_URL
}

setup_nomad_env() {
  if [[ -n "${NOMAD_ADDR:-}" ]]; then
    return
  fi

  [[ -f "$REPO_DIR/nomad/nomad.sh" ]] || die "NOMAD_ADDR is empty and $REPO_DIR/nomad/nomad.sh is missing"
  log "Loading Nomad CLI environment from $REPO_DIR/nomad/nomad.sh"
  set +u
  # shellcheck source=/dev/null
  source "$REPO_DIR/nomad/nomad.sh"
  set -u
}

resolve_deploy_commit() {
  if [[ -z "$DEPLOY_COMMIT" && -d "$REPO_DIR/.git" ]]; then
    DEPLOY_COMMIT="$(git -C "$REPO_DIR" rev-parse HEAD)"
  fi

  if [[ "$BUILD_AND_UPLOAD_ORCHESTRATOR" == "1" && -z "$DEPLOY_COMMIT" ]]; then
    die "DEPLOY_COMMIT is required when BUILD_AND_UPLOAD_ORCHESTRATOR=1 and $REPO_DIR has no .git metadata"
  fi

  if [[ -z "$IMAGE_TAG" && -n "$DEPLOY_COMMIT" ]]; then
    IMAGE_TAG="${DEPLOY_COMMIT:0:7}"
  fi
  COMMIT_SHA="${COMMIT_SHA:-$IMAGE_TAG}"
}

preflight() {
  log "Preflight"
  [[ "$(id -u)" -eq 0 ]] || die "run as root, for example: sudo -i && bash $0"

  need_cmd aws
  need_cmd jq
  need_cmd nomad
  need_cmd curl
  need_cmd make
  need_cmd bash

  load_config
  setup_nomad_env
  resolve_deploy_commit

  if [[ "$BUILD_AND_UPLOAD_ORCHESTRATOR" == "1" ]]; then
    need_cmd docker
    need_cmd unzip
    docker info >/dev/null
  fi

  aws_region sts get-caller-identity >/dev/null
  nomad_cmd node status -json >/dev/null
  nomad_cmd job inspect -json orchestrator >/dev/null

  echo "config_file=$CONFIG_FILE"
  echo "repo_dir=$REPO_DIR"
  echo "deploy_commit=${DEPLOY_COMMIT:-none}"
  echo "image_tag=${IMAGE_TAG:-none}"
  echo "commit_sha=${COMMIT_SHA:-none}"
  echo "client_asg_name=$CLIENT_ASG_NAME"
  echo "drain_hold_seconds=$DRAIN_HOLD_SECONDS"
  echo "require_zero_running_sandboxes=$REQUIRE_ZERO_RUNNING_SANDBOXES"
  echo "allow_terminate_client_node=$ALLOW_TERMINATE_CLIENT_NODE"
  echo "aws_region=$AWSREGION"
}

prepare_build_source() {
  BUILD_REPO_DIR="$REPO_DIR"
  [[ "$BUILD_AND_UPLOAD_ORCHESTRATOR" == "1" ]] || return

  local should_download archive_url archive_file extracted
  should_download="$DOWNLOAD_SOURCE_ARCHIVE"
  if [[ "$should_download" == "auto" ]]; then
    if [[ -n "$DEPLOY_COMMIT" ]]; then
      should_download="1"
    else
      should_download="0"
    fi
  fi

  if [[ "$should_download" != "1" ]]; then
    return
  fi

  TMP_DIR="$(mktemp -d)"
  archive_file="$TMP_DIR/sample-e2b-on-aws.zip"
  archive_url="${JFROG_GENERIC_URL}/aws-samples/sample-e2b-on-aws/archive/${DEPLOY_COMMIT}.zip"

  log "Downloading source archive for $DEPLOY_COMMIT"
  curl -fL "$archive_url" -o "$archive_file"
  unzip -q "$archive_file" -d "$TMP_DIR"

  extracted="$TMP_DIR/sample-e2b-on-aws-$DEPLOY_COMMIT"
  [[ -d "$extracted" ]] || die "archive did not contain expected directory: $extracted"
  BUILD_REPO_DIR="$extracted"
}

build_and_upload_orchestrator() {
  [[ "$BUILD_AND_UPLOAD_ORCHESTRATOR" == "1" ]] || {
    log "Skipping orchestrator build/upload because BUILD_AND_UPLOAD_ORCHESTRATOR=$BUILD_AND_UPLOAD_ORCHESTRATOR"
    return
  }

  prepare_build_source
  log "Build and upload orchestrator/template-manager artifact from $BUILD_REPO_DIR"
  cd "$BUILD_REPO_DIR/packages/orchestrator"
  GOTOOLCHAIN=auto make build-and-upload COMMIT_SHA="$COMMIT_SHA"
}

describe_asg_json() {
  aws_region autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$CLIENT_ASG_NAME" \
    --output json
}

get_instance_private_ip() {
  local instance_id="$1"
  aws_region ec2 describe-instances \
    --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' \
    --output text
}

get_initial_rollout_instances() {
  if [[ -n "$ROLL_TARGET_INSTANCE_IDS" ]]; then
    # shellcheck disable=SC2206
    ROLLOUT_INSTANCE_IDS=(${ROLL_TARGET_INSTANCE_IDS})
    return
  fi

  local asg_json
  asg_json="$(describe_asg_json)"
  mapfile -t ROLLOUT_INSTANCE_IDS < <(
    jq -r '
      .AutoScalingGroups[0].Instances[]
      | select(.LifecycleState == "InService" and .HealthStatus == "Healthy")
      | .InstanceId
    ' <<<"$asg_json"
  )

  ((${#ROLLOUT_INSTANCE_IDS[@]} > 0)) || die "no healthy InService client instances found in $CLIENT_ASG_NAME"
}

get_asg_instance_ids() {
  describe_asg_json | jq -r '.AutoScalingGroups[0].Instances[].InstanceId'
}

asg_contains_instance() {
  local instance_id="$1"
  get_asg_instance_ids | grep -qx "$instance_id"
}

nomad_node_row_by_ip() {
  local ip="$1"
  nomad_cmd node status -json | jq -r --arg ip "$ip" '
    .[]
    | select(.Address == $ip)
    | [
        .ID,
        .Status,
        .SchedulingEligibility,
        (.NodePool // "default"),
        .Datacenter,
        .Name
      ]
    | @tsv
  ' | head -n 1
}

resolve_nomad_node_by_ip() {
  local ip="$1"
  local label="$2"
  local row node_id status scheduling node_pool datacenter name

  row="$(nomad_node_row_by_ip "$ip" || true)"
  [[ -n "$row" ]] || die "Nomad node for $label IP $ip was not found"

  IFS=$'\t' read -r node_id status scheduling node_pool datacenter name <<<"$row"
  echo "${label}_nomad_node_id=$node_id status=$status scheduling=$scheduling node_pool=$node_pool datacenter=$datacenter name=$name"
  RESOLVED_NOMAD_NODE_ID="$node_id"
}

wait_nomad_node_ready_by_ip() {
  local ip="$1"
  local label="$2"
  local start now row node_id status scheduling node_pool datacenter name
  start="$(date +%s)"

  while true; do
    row="$(nomad_node_row_by_ip "$ip" || true)"
    if [[ -n "$row" ]]; then
      IFS=$'\t' read -r node_id status scheduling node_pool datacenter name <<<"$row"
      echo "${label}_nomad_node_id=$node_id status=$status scheduling=$scheduling node_pool=$node_pool datacenter=$datacenter name=$name"
      if [[ "$status" == "ready" && "$scheduling" == "eligible" ]]; then
        RESOLVED_NOMAD_NODE_ID="$node_id"
        return
      fi
    fi

    now="$(date +%s)"
    if ((now - start > WAIT_NEW_TIMEOUT_SECONDS)); then
      die "timed out waiting for $label Nomad node for IP $ip"
    fi
    sleep "$WAIT_POLL_SECONDS"
  done
}

wait_for_orchestrator_alloc() {
  local node_id="$1"
  local label="$2"
  local start now alloc_id status
  start="$(date +%s)"

  log "Waiting for orchestrator system alloc on $label node $node_id"
  while true; do
    alloc_id="$(
      nomad_cmd job allocs -json orchestrator \
        | jq -r --arg node "$node_id" '
          .[]?
          | select(.NodeID == $node and .DesiredStatus == "run" and .ClientStatus == "running")
          | .ID
        ' \
        | head -n 1
    )"

    if [[ -n "$alloc_id" ]]; then
      status="$(nomad_cmd alloc status -json "$alloc_id" | jq -r '.ClientStatus')"
      echo "${label}_orchestrator_alloc=$alloc_id status=$status"
      [[ "$status" == "running" ]] && return
    fi

    now="$(date +%s)"
    if ((now - start > WAIT_NEW_TIMEOUT_SECONDS)); then
      die "timed out waiting for orchestrator alloc on node $node_id"
    fi
    sleep "$WAIT_POLL_SECONDS"
  done
}

discover_edge_api_base() {
  if [[ -n "$EDGE_API_BASE" ]]; then
    EDGE_API_BASE="${EDGE_API_BASE%/}"
    log "Using EDGE_API_BASE=$EDGE_API_BASE"
    return
  fi

  log "Discovering a healthy client-proxy edge API endpoint from Nomad"
  mapfile -t edge_node_ids < <(
    nomad_cmd job allocs -json client-proxy \
      | jq -r '
        .[]?
        | select(.DesiredStatus == "run" and .ClientStatus == "running")
        | .NodeID
      '
  )

  ((${#edge_node_ids[@]} > 0)) || die "no running client-proxy allocations found"

  local nodes_json node_id ip candidate
  nodes_json="$(nomad_cmd node status -json)"

  for node_id in "${edge_node_ids[@]}"; do
    ip="$(jq -r --arg node "$node_id" '.[] | select(.ID == $node) | .Address' <<<"$nodes_json" | head -n 1)"
    [[ -n "$ip" && "$ip" != "null" ]] || continue
    candidate="http://${ip}:${EDGE_PORT}"

    if curl -fsS --max-time 3 "${candidate}/health" >/dev/null; then
      EDGE_API_BASE="$candidate"
      echo "edge_api_base=$EDGE_API_BASE"
      return
    fi
  done

  die "failed to discover a reachable client-proxy edge API endpoint; set EDGE_API_BASE=http://<ip>:${EDGE_PORT}"
}

resolve_edge_secret() {
  if [[ -n "$EDGE_SECRET" ]]; then
    return
  fi

  local secret_name
  secret_name="${infra_tokens_secret_name:-${INFRA_TOKENS_SECRET_NAME:-}}"
  [[ -n "$secret_name" ]] || die "infra_tokens_secret_name is missing from $CONFIG_FILE; set EDGE_SECRET manually"

  log "Loading edge admin token from Secrets Manager secret $secret_name"
  EDGE_SECRET="$(
    aws_region secretsmanager get-secret-value \
      --secret-id "$secret_name" \
      --query SecretString \
      --output text \
      | jq -r '.admin_token // empty'
  )"
  [[ -n "$EDGE_SECRET" && "$EDGE_SECRET" != "null" ]] || die "admin_token is missing from $secret_name"
}

edge_get_orchestrators() {
  curl -fsS \
    --max-time 10 \
    -H "X-API-Key: ${EDGE_SECRET}" \
    "${EDGE_API_BASE}/v1/service-discovery/nodes/orchestrators"
}

find_orchestrator_row() {
  local nomad_node_id="$1"
  local private_ip="$2"
  local expected_host="${private_ip}:${ORCHESTRATOR_PORT}"

  edge_get_orchestrators | jq -r --arg node "$nomad_node_id" --arg host "$expected_host" '
    .[]
    | select(.nodeID == $node or .serviceHost == $host)
    | [
        .serviceInstanceID,
        .nodeID,
        .serviceHost,
        .serviceStatus,
        (.metricSandboxesRunning // 0)
      ]
    | @tsv
  ' | head -n 1
}

wait_for_edge_orchestrator_visible() {
  local nomad_node_id="$1"
  local private_ip="$2"
  local label="$3"
  local start now row service_id node_id host status running
  start="$(date +%s)"

  log "Waiting for client-proxy to discover $label orchestrator"
  while true; do
    row="$(find_orchestrator_row "$nomad_node_id" "$private_ip" || true)"
    if [[ -n "$row" ]]; then
      IFS=$'\t' read -r service_id node_id host status running <<<"$row"
      echo "${label}_orchestrator_service_id=$service_id node_id=$node_id host=$host status=$status running_sandboxes=$running"
      if [[ "$status" == "healthy" || "$status" == "draining" ]]; then
        EDGE_ORCHESTRATOR_SERVICE_ID="$service_id"
        EDGE_ORCHESTRATOR_RUNNING="$running"
        return
      fi
    fi

    now="$(date +%s)"
    if ((now - start > WAIT_NEW_TIMEOUT_SECONDS)); then
      die "timed out waiting for client-proxy to discover $label orchestrator"
    fi
    sleep "$WAIT_POLL_SECONDS"
  done
}

mark_orchestrator_draining() {
  local service_id="$1"
  log "Marking orchestrator $service_id draining through client-proxy"
  curl -fsS \
    --max-time 10 \
    -X POST \
    -H "X-API-Key: ${EDGE_SECRET}" \
    "${EDGE_API_BASE}/v1/service-discovery/nodes/${service_id}/drain" \
    >/dev/null
}

wait_for_old_sandboxes_to_drain() {
  local nomad_node_id="$1"
  local private_ip="$2"
  local start now row service_id node_id host status running

  if [[ "$REQUIRE_ZERO_RUNNING_SANDBOXES" != "1" ]]; then
    warn "REQUIRE_ZERO_RUNNING_SANDBOXES=$REQUIRE_ZERO_RUNNING_SANDBOXES; not waiting for running_sandboxes=0"
    return
  fi

  log "Waiting for old orchestrator running sandbox count to reach zero"
  start="$(date +%s)"

  while true; do
    row="$(find_orchestrator_row "$nomad_node_id" "$private_ip" || true)"
    if [[ -z "$row" ]]; then
      warn "old orchestrator disappeared from edge discovery; treating it as drained"
      return
    fi

    IFS=$'\t' read -r service_id node_id host status running <<<"$row"
    echo "old_orchestrator service_id=$service_id host=$host status=$status running_sandboxes=$running"

    if [[ "$status" == "draining" && "$running" == "0" ]]; then
      return
    fi

    if [[ "$ALLOW_TERMINATE_WITH_RUNNING_SANDBOXES" == "1" && "$status" == "draining" ]]; then
      warn "old orchestrator still reports running_sandboxes=$running, but maintenance override is enabled"
      return
    fi

    now="$(date +%s)"
    if ((now - start > WAIT_DRAIN_TIMEOUT_SECONDS)); then
      die "timed out waiting for old orchestrator running sandbox count to reach 0"
    fi
    sleep "$WAIT_POLL_SECONDS"
  done
}

scale_out_one_client_node() {
  local asg_json desired max target
  asg_json="$(describe_asg_json)"
  desired="$(jq -r '.AutoScalingGroups[0].DesiredCapacity' <<<"$asg_json")"
  max="$(jq -r '.AutoScalingGroups[0].MaxSize' <<<"$asg_json")"
  target="$((desired + 1))"

  [[ "$ALLOW_SCALE_OUT_CLIENT_NODE" == "1" ]] || die "ALLOW_SCALE_OUT_CLIENT_NODE is not 1; refusing to scale ASG"

  if ((target > max)); then
    [[ "$ALLOW_INCREASE_ASG_MAX" == "1" ]] || die "target desired $target is greater than ASG max $max; set ALLOW_INCREASE_ASG_MAX=1"
    log "Increasing client ASG max size from $max to $target"
    aws_region autoscaling update-auto-scaling-group \
      --auto-scaling-group-name "$CLIENT_ASG_NAME" \
      --max-size "$target"
  fi

  log "Scaling client ASG from desired=$desired to desired=$target"
  aws_region autoscaling update-auto-scaling-group \
    --auto-scaling-group-name "$CLIENT_ASG_NAME" \
    --desired-capacity "$target"

  SCALE_PREVIOUS_DESIRED="$desired"
  SCALE_PREVIOUS_MAX="$max"
  SCALE_TARGET_DESIRED="$target"
}

wait_for_new_instance() {
  local before_file="$1"
  local start now candidate_ids id state health lifecycle private_ip
  start="$(date +%s)"

  log "Waiting for one new client instance to join $CLIENT_ASG_NAME"
  while true; do
    mapfile -t candidate_ids < <(
      get_asg_instance_ids | while read -r id; do
        grep -qx "$id" "$before_file" || printf '%s\n' "$id"
      done
    )

    for id in "${candidate_ids[@]}"; do
      read -r state health lifecycle private_ip < <(
        aws_region autoscaling describe-auto-scaling-groups \
          --auto-scaling-group-names "$CLIENT_ASG_NAME" \
          --query "AutoScalingGroups[0].Instances[?InstanceId=='${id}'].[LifecycleState,HealthStatus]" \
          --output text \
          | awk '{print $1, $2}'
      )
      private_ip="$(get_instance_private_ip "$id")"
      echo "new_candidate=$id lifecycle=$state health=$health private_ip=$private_ip"
      if [[ "$state" == "InService" && "$health" == "Healthy" && -n "$private_ip" && "$private_ip" != "None" ]]; then
        NEW_INSTANCE_ID="$id"
        NEW_PRIVATE_IP="$private_ip"
        return
      fi
    done

    now="$(date +%s)"
    if ((now - start > WAIT_NEW_TIMEOUT_SECONDS)); then
      die "timed out waiting for a new client instance in $CLIENT_ASG_NAME"
    fi
    sleep "$WAIT_POLL_SECONDS"
  done
}

wait_ec2_status_ok() {
  local instance_id="$1"
  log "Waiting for EC2 status checks on $instance_id"
  aws_region ec2 wait instance-status-ok --instance-ids "$instance_id"
}

terminate_old_instance() {
  local old_instance_id="$1"

  if [[ "$ALLOW_TERMINATE_CLIENT_NODE" != "1" ]]; then
    warn "ALLOW_TERMINATE_CLIENT_NODE is not 1; leaving old instance $old_instance_id running"
    warn "After review, terminate it with desired decrement or rerun with ALLOW_TERMINATE_CLIENT_NODE=1"
    return
  fi

  log "Terminating old client instance $old_instance_id and decrementing desired capacity"
  aws_region autoscaling terminate-instance-in-auto-scaling-group \
    --instance-id "$old_instance_id" \
    --should-decrement-desired-capacity \
    >/dev/null

  aws_region ec2 wait instance-terminated --instance-ids "$old_instance_id"

  if ((SCALE_TARGET_DESIRED > SCALE_PREVIOUS_MAX)); then
    log "Restoring client ASG max size to $SCALE_PREVIOUS_MAX"
    aws_region autoscaling update-auto-scaling-group \
      --auto-scaling-group-name "$CLIENT_ASG_NAME" \
      --max-size "$SCALE_PREVIOUS_MAX"
  fi
}

roll_one_instance() {
  local old_instance_id="$1"
  local old_private_ip old_nomad_node_id service_id before_file

  if ! asg_contains_instance "$old_instance_id"; then
    warn "Skipping $old_instance_id because it is no longer in $CLIENT_ASG_NAME"
    return
  fi

  log "Rolling client instance $old_instance_id"
  old_private_ip="$(get_instance_private_ip "$old_instance_id")"
  [[ -n "$old_private_ip" && "$old_private_ip" != "None" ]] || die "failed to resolve private IP for $old_instance_id"

  resolve_nomad_node_by_ip "$old_private_ip" "old"
  old_nomad_node_id="$RESOLVED_NOMAD_NODE_ID"

  wait_for_edge_orchestrator_visible "$old_nomad_node_id" "$old_private_ip" "old"
  service_id="$EDGE_ORCHESTRATOR_SERVICE_ID"
  mark_orchestrator_draining "$service_id"

  log "Drain hold for $DRAIN_HOLD_SECONDS seconds before scaling out replacement"
  sleep "$DRAIN_HOLD_SECONDS"
  wait_for_old_sandboxes_to_drain "$old_nomad_node_id" "$old_private_ip"

  before_file="$(mktemp)"
  get_asg_instance_ids > "$before_file"
  scale_out_one_client_node
  wait_for_new_instance "$before_file"
  rm -f "$before_file"

  wait_ec2_status_ok "$NEW_INSTANCE_ID"
  wait_nomad_node_ready_by_ip "$NEW_PRIVATE_IP" "new"
  wait_for_orchestrator_alloc "$RESOLVED_NOMAD_NODE_ID" "new"
  wait_for_edge_orchestrator_visible "$RESOLVED_NOMAD_NODE_ID" "$NEW_PRIVATE_IP" "new"

  terminate_old_instance "$old_instance_id"
  log "Finished rolling $old_instance_id -> $NEW_INSTANCE_ID"
}

post_checks() {
  log "Final orchestrator status"
  nomad_cmd job status orchestrator

  log "Final client ASG instances"
  aws_region autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$CLIENT_ASG_NAME" \
    --query 'AutoScalingGroups[0].Instances[].{InstanceId:InstanceId,LifecycleState:LifecycleState,HealthStatus:HealthStatus}' \
    --output table
}

main() {
  preflight
  build_and_upload_orchestrator
  discover_edge_api_base
  resolve_edge_secret
  get_initial_rollout_instances

  printf 'rollout_instance_ids=%s\n' "${ROLLOUT_INSTANCE_IDS[*]}"
  for instance_id in "${ROLLOUT_INSTANCE_IDS[@]}"; do
    roll_one_instance "$instance_id"
  done

  post_checks
}

main "$@"
