#!/usr/bin/env bash
set -Eeuo pipefail

# Replace E2B client nodes from the setup/bastion host.
#
# Intended operator flow:
#   sudo -i
#   cd /opt/infra/sample-e2b-on-aws
#   bash artifacts/replace_client_node.sh
#
# Expected host:
#   The setup/bastion host with /opt/config.properties, AWS CLI, Nomad CLI,
#   jq, curl, and network access to private Nomad/client-proxy endpoints.
#
# Default mode is for a confirmed no-customer window:
#   start replacement client nodes first, wait for EC2/Nomad/orchestrator
#   health, then terminate the old client nodes and return ASG desired capacity
#   to its original value. Edge drain and old-node SSM diagnostics are skipped
#   by default for environments where those private paths are unavailable.
#
# Set BATCH_REPLACE_ALL_CLIENT_NODES=0 for a single-node replacement.
# Set BATCH_REPLACE_ALL_CLIENT_NODES=0 FAST_NO_CUSTOMER_REPLACEMENT=0
# DRAIN_OLD_NODE=1 COLLECT_OLD_NODE_OS_STATE=1 for the conservative staged
# flow that scales out first, drains the old node, then terminates it.
#
# Important knobs:
#   CONFIG_FILE=/opt/config.properties
#   REPO_DIR=/opt/infra/sample-e2b-on-aws
#   CLIENT_ASG_NAME=<stack>-client-asg
#   TARGET_INSTANCE_ID=<old client instance id>  # required when ASG has >1 node
#   ALLOW_INCREASE_ASG_MAX=1                    # allow max-size bump for scale-out
#   ALLOW_TERMINATE_CLIENT_NODE=0               # dry-run guardrail
#   ALLOW_TERMINATE_WITH_RUNNING_SANDBOXES=1    # maintenance-window override
#   FAST_NO_CUSTOMER_REPLACEMENT=0              # strict drain when BATCH=0
#   BATCH_REPLACE_ALL_CLIENT_NODES=0            # single-node replace
#   COLLECT_OLD_NODE_OS_STATE=1                 # collect SSM diagnostics
#   DRAIN_OLD_NODE=1                            # require edge drain
#   EDGE_API_BASE=http://<client-proxy-node-ip>:3001
#   EDGE_SECRET=<admin_token>                   # optional; auto-loaded from secret
#   NOMAD_CLI_EXTRA="-tls-skip-verify"

CONFIG_FILE="${CONFIG_FILE:-/opt/config.properties}"
REPO_DIR="${REPO_DIR:-/opt/infra/sample-e2b-on-aws}"
CLIENT_ASG_NAME="${CLIENT_ASG_NAME:-}"
TARGET_INSTANCE_ID="${TARGET_INSTANCE_ID:-}"

ALLOW_SCALE_OUT_CLIENT_NODE="${ALLOW_SCALE_OUT_CLIENT_NODE:-1}"
ALLOW_INCREASE_ASG_MAX="${ALLOW_INCREASE_ASG_MAX:-0}"
ALLOW_TERMINATE_CLIENT_NODE="${ALLOW_TERMINATE_CLIENT_NODE:-1}"
ALLOW_TERMINATE_WITH_RUNNING_SANDBOXES="${ALLOW_TERMINATE_WITH_RUNNING_SANDBOXES:-0}"
FAST_NO_CUSTOMER_REPLACEMENT="${FAST_NO_CUSTOMER_REPLACEMENT:-1}"
BATCH_REPLACE_ALL_CLIENT_NODES="${BATCH_REPLACE_ALL_CLIENT_NODES:-1}"
COLLECT_OLD_NODE_OS_STATE="${COLLECT_OLD_NODE_OS_STATE:-0}"
DRAIN_OLD_NODE="${DRAIN_OLD_NODE:-0}"

EDGE_API_BASE="${EDGE_API_BASE:-}"
EDGE_SECRET="${EDGE_SECRET:-}"
EDGE_PORT="${EDGE_PORT:-3001}"
ORCHESTRATOR_PORT="${ORCHESTRATOR_PORT:-5008}"

WAIT_NEW_TIMEOUT_SECONDS="${WAIT_NEW_TIMEOUT_SECONDS:-1800}"
WAIT_DRAIN_TIMEOUT_SECONDS="${WAIT_DRAIN_TIMEOUT_SECONDS:-900}"
WAIT_POLL_SECONDS="${WAIT_POLL_SECONDS:-15}"
SSM_TIMEOUT_SECONDS="${SSM_TIMEOUT_SECONDS:-180}"

ORIGINAL_ASG_DESIRED=""
ORIGINAL_ASG_MAX=""
TARGET_DESIRED=""
OLD_INSTANCE_ID=""
OLD_PRIVATE_IP=""
OLD_NOMAD_NODE_ID=""
NEW_INSTANCE_ID=""
NEW_PRIVATE_IP=""
NEW_NOMAD_NODE_ID=""
OLD_ORCHESTRATOR_SERVICE_ID=""

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

preflight() {
  log "Preflight"
  need_cmd aws
  need_cmd nomad
  need_cmd jq
  need_cmd curl
  need_cmd mktemp

  load_config
  setup_nomad_env

  aws_region sts get-caller-identity >/dev/null
  nomad_cmd node status -json >/dev/null

  echo "config_file=$CONFIG_FILE"
  echo "repo_dir=$REPO_DIR"
  echo "aws_region=$AWSREGION"
  echo "client_asg_name=$CLIENT_ASG_NAME"
  echo "target_instance_id=${TARGET_INSTANCE_ID:-auto}"
  echo "allow_scale_out_client_node=$ALLOW_SCALE_OUT_CLIENT_NODE"
  echo "allow_increase_asg_max=$ALLOW_INCREASE_ASG_MAX"
  echo "allow_terminate_client_node=$ALLOW_TERMINATE_CLIENT_NODE"
  echo "allow_terminate_with_running_sandboxes=$ALLOW_TERMINATE_WITH_RUNNING_SANDBOXES"
  echo "fast_no_customer_replacement=$FAST_NO_CUSTOMER_REPLACEMENT"
  echo "batch_replace_all_client_nodes=$BATCH_REPLACE_ALL_CLIENT_NODES"
  echo "collect_old_node_os_state=$COLLECT_OLD_NODE_OS_STATE"
  echo "drain_old_node=$DRAIN_OLD_NODE"
  echo "edge_api_base=${EDGE_API_BASE:-auto}"
}

describe_asg_json() {
  aws_region autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$CLIENT_ASG_NAME" \
    --output json
}

instance_in_list() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

choose_old_instance() {
  log "Discovering current client ASG instances"
  local asg_json
  asg_json="$(describe_asg_json)"

  local asg_count
  asg_count="$(jq '.AutoScalingGroups | length' <<<"$asg_json")"
  [[ "$asg_count" == "1" ]] || die "ASG not found or ambiguous: $CLIENT_ASG_NAME"

  ORIGINAL_ASG_DESIRED="$(jq -r '.AutoScalingGroups[0].DesiredCapacity' <<<"$asg_json")"
  ORIGINAL_ASG_MAX="$(jq -r '.AutoScalingGroups[0].MaxSize' <<<"$asg_json")"
  TARGET_DESIRED="$((ORIGINAL_ASG_DESIRED + 1))"

  mapfile -t healthy_instances < <(
    jq -r '
      .AutoScalingGroups[0].Instances[]
      | select(.LifecycleState == "InService" and .HealthStatus == "Healthy")
      | .InstanceId
    ' <<<"$asg_json"
  )

  if [[ -n "$TARGET_INSTANCE_ID" ]]; then
    instance_in_list "$TARGET_INSTANCE_ID" "${healthy_instances[@]}" \
      || die "TARGET_INSTANCE_ID=$TARGET_INSTANCE_ID is not a healthy InService member of $CLIENT_ASG_NAME"
    OLD_INSTANCE_ID="$TARGET_INSTANCE_ID"
  elif ((${#healthy_instances[@]} == 1)); then
    OLD_INSTANCE_ID="${healthy_instances[0]}"
  else
    printf 'Healthy client instances in %s:\n' "$CLIENT_ASG_NAME" >&2
    printf '  %s\n' "${healthy_instances[@]}" >&2
    die "set TARGET_INSTANCE_ID when the client ASG has more than one healthy instance"
  fi

  OLD_PRIVATE_IP="$(get_instance_private_ip "$OLD_INSTANCE_ID")"
  [[ -n "$OLD_PRIVATE_IP" && "$OLD_PRIVATE_IP" != "None" ]] || die "failed to resolve private IP for $OLD_INSTANCE_ID"

  echo "original_asg_desired=$ORIGINAL_ASG_DESIRED"
  echo "original_asg_max=$ORIGINAL_ASG_MAX"
  echo "target_desired_after_scale_out=$TARGET_DESIRED"
  echo "old_instance_id=$OLD_INSTANCE_ID"
  echo "old_private_ip=$OLD_PRIVATE_IP"
}

get_instance_private_ip() {
  local instance_id="$1"
  aws_region ec2 describe-instances \
    --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' \
    --output text
}

get_asg_instance_ids() {
  describe_asg_json | jq -r '.AutoScalingGroups[0].Instances[].InstanceId'
}

get_asg_instance_state() {
  local instance_id="$1"
  describe_asg_json | jq -r --arg id "$instance_id" '
    .AutoScalingGroups[0].Instances[]
    | select(.InstanceId == $id)
    | [.LifecycleState, .HealthStatus] | @tsv
  '
}

scale_out_client_asg() {
  log "Scaling out client ASG by one node"
  if [[ "$ALLOW_SCALE_OUT_CLIENT_NODE" != "1" ]]; then
    die "ALLOW_SCALE_OUT_CLIENT_NODE is not 1; refusing to change ASG desired capacity"
  fi

  if ((TARGET_DESIRED > ORIGINAL_ASG_MAX)); then
    if [[ "$ALLOW_INCREASE_ASG_MAX" != "1" ]]; then
      die "target desired $TARGET_DESIRED is greater than ASG max $ORIGINAL_ASG_MAX; set ALLOW_INCREASE_ASG_MAX=1 to bump max"
    fi

    log "Increasing client ASG max size from $ORIGINAL_ASG_MAX to $TARGET_DESIRED"
    aws_region autoscaling update-auto-scaling-group \
      --auto-scaling-group-name "$CLIENT_ASG_NAME" \
      --max-size "$TARGET_DESIRED"
  fi

  aws_region autoscaling update-auto-scaling-group \
    --auto-scaling-group-name "$CLIENT_ASG_NAME" \
    --desired-capacity "$TARGET_DESIRED"
}

wait_for_new_instance() {
  log "Waiting for new client EC2 instance to become InService and healthy"
  local start now asg_json lifecycle health
  start="$(date +%s)"

  local before_instances=("$@")
  if ((${#before_instances[@]} == 0)); then
    mapfile -t before_instances < <(get_asg_instance_ids)
  fi

  while true; do
    now="$(date +%s)"
    if ((now - start > WAIT_NEW_TIMEOUT_SECONDS)); then
      die "timed out waiting for a new client instance in $CLIENT_ASG_NAME"
    fi

    asg_json="$(describe_asg_json)"
    mapfile -t current_instances < <(jq -r '.AutoScalingGroups[0].Instances[].InstanceId' <<<"$asg_json")

    local instance
    for instance in "${current_instances[@]}"; do
      if ! instance_in_list "$instance" "${before_instances[@]}"; then
        NEW_INSTANCE_ID="$instance"
        read -r lifecycle health < <(
          jq -r --arg id "$instance" '
            .AutoScalingGroups[0].Instances[]
            | select(.InstanceId == $id)
            | [.LifecycleState, .HealthStatus] | @tsv
          ' <<<"$asg_json"
        )

        echo "new_instance_candidate=$NEW_INSTANCE_ID lifecycle=$lifecycle health=$health"
        if [[ "$lifecycle" == "InService" && "$health" == "Healthy" ]]; then
          NEW_PRIVATE_IP="$(get_instance_private_ip "$NEW_INSTANCE_ID")"
          [[ -n "$NEW_PRIVATE_IP" && "$NEW_PRIVATE_IP" != "None" ]] || die "failed to resolve private IP for $NEW_INSTANCE_ID"
          echo "new_instance_id=$NEW_INSTANCE_ID"
          echo "new_private_ip=$NEW_PRIVATE_IP"
          break 2
        fi
      fi
    done

    sleep "$WAIT_POLL_SECONDS"
  done

  log "Waiting for EC2 status checks on $NEW_INSTANCE_ID"
  aws_region ec2 wait instance-status-ok --instance-ids "$NEW_INSTANCE_ID"
}

nomad_node_row_by_ip() {
  local ip="$1"
  nomad_cmd node status -json | jq -r --arg ip "$ip" '
    .[]
    | select(.Address == $ip)
    | [.ID, .Status, .SchedulingEligibility, (.NodePool // ""), (.Datacenter // ""), (.Name // "")]
    | @tsv
  ' | head -n 1
}

wait_for_nomad_node_ready() {
  local ip="$1"
  local out_var="$2"
  local label="$3"
  local start now row node_id status scheduling node_pool datacenter name

  log "Waiting for $label Nomad node to be ready ($ip)"
  start="$(date +%s)"

  while true; do
    now="$(date +%s)"
    if ((now - start > WAIT_NEW_TIMEOUT_SECONDS)); then
      die "timed out waiting for $label Nomad node for IP $ip"
    fi

    row="$(nomad_node_row_by_ip "$ip" || true)"
    if [[ -n "$row" ]]; then
      IFS=$'\t' read -r node_id status scheduling node_pool datacenter name <<<"$row"
      echo "${label}_nomad_node_id=$node_id status=$status scheduling=$scheduling node_pool=$node_pool datacenter=$datacenter name=$name"
      if [[ "$status" == "ready" && "$scheduling" == "eligible" ]]; then
        printf -v "$out_var" '%s' "$node_id"
        return
      fi
    fi

    sleep "$WAIT_POLL_SECONDS"
  done
}

resolve_nomad_node_by_ip() {
  local ip="$1"
  local out_var="$2"
  local label="$3"
  local row node_id status scheduling node_pool datacenter name

  row="$(nomad_node_row_by_ip "$ip" || true)"
  [[ -n "$row" ]] || die "Nomad node for $label IP $ip was not found"

  IFS=$'\t' read -r node_id status scheduling node_pool datacenter name <<<"$row"
  echo "${label}_nomad_node_id=$node_id status=$status scheduling=$scheduling node_pool=$node_pool datacenter=$datacenter name=$name"
  printf -v "$out_var" '%s' "$node_id"
}

wait_for_orchestrator_alloc() {
  local node_id="$1"
  local label="$2"
  local start now alloc_id status

  log "Waiting for orchestrator system alloc on $label node $node_id"
  start="$(date +%s)"

  while true; do
    now="$(date +%s)"
    if ((now - start > WAIT_NEW_TIMEOUT_SECONDS)); then
      die "timed out waiting for orchestrator alloc on node $node_id"
    fi

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

  log "Waiting for client-proxy to discover $label orchestrator"
  start="$(date +%s)"

  while true; do
    now="$(date +%s)"
    if ((now - start > WAIT_NEW_TIMEOUT_SECONDS)); then
      die "timed out waiting for client-proxy to discover $label orchestrator"
    fi

    row="$(find_orchestrator_row "$nomad_node_id" "$private_ip" || true)"
    if [[ -n "$row" ]]; then
      IFS=$'\t' read -r service_id node_id host status running <<<"$row"
      echo "${label}_orchestrator_service_id=$service_id node_id=$node_id host=$host status=$status running_sandboxes=$running"
      if [[ "$status" == "healthy" || "$status" == "draining" ]]; then
        if [[ "$label" == "old" ]]; then
          OLD_ORCHESTRATOR_SERVICE_ID="$service_id"
        fi
        return
      fi
    fi

    sleep "$WAIT_POLL_SECONDS"
  done
}

drain_old_orchestrator() {
  if [[ "$DRAIN_OLD_NODE" != "1" ]]; then
    warn "DRAIN_OLD_NODE is not 1; old orchestrator will not be marked draining"
    return
  fi

  [[ -n "$OLD_ORCHESTRATOR_SERVICE_ID" ]] || die "old orchestrator service id is empty"

  log "Marking old orchestrator as draining through client-proxy edge API"
  curl -fsS \
    --max-time 10 \
    -X POST \
    -H "X-API-Key: ${EDGE_SECRET}" \
    "${EDGE_API_BASE}/v1/service-discovery/nodes/${OLD_ORCHESTRATOR_SERVICE_ID}/drain" \
    >/dev/null
}

wait_for_old_orchestrator_drained() {
  local start now row service_id node_id host status running
  log "Waiting for old orchestrator to drain"
  start="$(date +%s)"

  while true; do
    now="$(date +%s)"
    if ((now - start > WAIT_DRAIN_TIMEOUT_SECONDS)); then
      if [[ "$ALLOW_TERMINATE_WITH_RUNNING_SANDBOXES" == "1" ]]; then
        warn "Drain wait timed out, but ALLOW_TERMINATE_WITH_RUNNING_SANDBOXES=1"
        return
      fi
      die "timed out waiting for old orchestrator running sandbox count to reach 0"
    fi

    row="$(find_orchestrator_row "$OLD_NOMAD_NODE_ID" "$OLD_PRIVATE_IP" || true)"
    if [[ -z "$row" ]]; then
      warn "old orchestrator disappeared from edge discovery; treating it as drained"
      return
    fi

    IFS=$'\t' read -r service_id node_id host status running <<<"$row"
    echo "old_orchestrator status=$status running_sandboxes=$running service_id=$service_id host=$host"

    if [[ "$status" == "draining" && "$running" == "0" ]]; then
      return
    fi

    if [[ "$ALLOW_TERMINATE_WITH_RUNNING_SANDBOXES" == "1" && "$status" == "draining" ]]; then
      warn "old orchestrator still reports running_sandboxes=$running, but maintenance override is enabled"
      return
    fi

    sleep "$WAIT_POLL_SECONDS"
  done
}

run_ssm_shell() {
  local instance_id="$1"
  local command_text="$2"
  local input_file command_id start now status

  input_file="$(mktemp)"
  jq -n --arg id "$instance_id" --arg cmd "$command_text" '{
    DocumentName: "AWS-RunShellScript",
    InstanceIds: [$id],
    Parameters: {commands: [$cmd]}
  }' > "$input_file"

  command_id="$(
    aws_region ssm send-command \
      --cli-input-json "file://${input_file}" \
      --query 'Command.CommandId' \
      --output text
  )"
  rm -f "$input_file"

  start="$(date +%s)"
  while true; do
    now="$(date +%s)"
    if ((now - start > SSM_TIMEOUT_SECONDS)); then
      die "timed out waiting for SSM command $command_id on $instance_id"
    fi

    status="$(aws_region ssm get-command-invocation \
      --command-id "$command_id" \
      --instance-id "$instance_id" \
      --query 'Status' \
      --output text 2>/dev/null || true)"

    case "$status" in
      Success)
        aws_region ssm get-command-invocation \
          --command-id "$command_id" \
          --instance-id "$instance_id" \
          --query 'StandardOutputContent' \
          --output text
        return
        ;;
      Failed|Cancelled|TimedOut|Cancelling)
        aws_region ssm get-command-invocation \
          --command-id "$command_id" \
          --instance-id "$instance_id" \
          --query 'StandardErrorContent' \
          --output text >&2 || true
        die "SSM command $command_id on $instance_id finished with status $status"
        ;;
      *)
        sleep 5
        ;;
    esac
  done
}

print_old_node_os_state() {
  log "Collecting old node OS state through SSM"
  local remote_cmd output
  remote_cmd="$(cat <<'REMOTE'
set -euo pipefail
echo "now_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "hostname=$(hostname)"
echo "loadavg=$(cat /proc/loadavg)"
awk "/HugePages_Total|HugePages_Free|HugePages_Rsvd|Hugetlb/ {print}" /proc/meminfo
echo "unshare_fc=$(pgrep -fc "unshare -pfm --kill-child" || true)"
echo "firecracker=$(pgrep -fc "firecracker" || true)"
echo "current_orchestrator_pid=$(pgrep -fo "orchestrator --port|local/orchestrator" || true)"
echo "firecracker_parent_counts_begin"
ps -eo ppid=,comm= | awk '$2 == "firecracker" {count[$1]++} END {for (p in count) print p, count[p]}' | sort -k2,2nr | head -n 20 || true
echo "firecracker_parent_counts_end"
REMOTE
)"

  output="$(run_ssm_shell "$OLD_INSTANCE_ID" "$remote_cmd")"
  printf '%s\n' "$output"

  local fc_count huge_free
  fc_count="$(awk -F= '/^firecracker=/{print $2}' <<<"$output" | tail -n 1)"
  huge_free="$(awk '/^HugePages_Free:/{print $2}' <<<"$output" | tail -n 1)"
  echo "old_node_firecracker_processes=${fc_count:-unknown}"
  echo "old_node_hugepages_free=${huge_free:-unknown}"
}

collect_old_node_os_state() {
  if [[ "$COLLECT_OLD_NODE_OS_STATE" != "1" ]]; then
    warn "COLLECT_OLD_NODE_OS_STATE is not 1; skipping old node SSM diagnostics"
    return
  fi

  if [[ "$FAST_NO_CUSTOMER_REPLACEMENT" == "1" ]]; then
    (print_old_node_os_state) || warn "failed to collect old node OS state; continuing because FAST_NO_CUSTOMER_REPLACEMENT=1"
    return
  fi

  print_old_node_os_state
}

terminate_old_instance_if_allowed() {
  if [[ "$ALLOW_TERMINATE_CLIENT_NODE" != "1" ]]; then
    warn "ALLOW_TERMINATE_CLIENT_NODE is not 1; leaving old instance $OLD_INSTANCE_ID running"
    warn "To finish replacement after review: ALLOW_TERMINATE_CLIENT_NODE=1 TARGET_INSTANCE_ID=$OLD_INSTANCE_ID bash $0"
    return
  fi

  log "Terminating old client instance $OLD_INSTANCE_ID and decrementing ASG desired capacity"
  aws_region autoscaling terminate-instance-in-auto-scaling-group \
    --instance-id "$OLD_INSTANCE_ID" \
    --should-decrement-desired-capacity \
    >/dev/null

  log "Waiting for old instance $OLD_INSTANCE_ID to terminate"
  aws_region ec2 wait instance-terminated --instance-ids "$OLD_INSTANCE_ID"

  if ((TARGET_DESIRED > ORIGINAL_ASG_MAX)); then
    log "Restoring ASG max size to $ORIGINAL_ASG_MAX"
    aws_region autoscaling update-auto-scaling-group \
      --auto-scaling-group-name "$CLIENT_ASG_NAME" \
      --max-size "$ORIGINAL_ASG_MAX"
  fi
}

discover_batch_old_instances() {
  log "Discovering current client ASG instances for batch replacement"
  local asg_json asg_count
  asg_json="$(describe_asg_json)"

  asg_count="$(jq '.AutoScalingGroups | length' <<<"$asg_json")"
  [[ "$asg_count" == "1" ]] || die "ASG not found or ambiguous: $CLIENT_ASG_NAME"

  ORIGINAL_ASG_DESIRED="$(jq -r '.AutoScalingGroups[0].DesiredCapacity' <<<"$asg_json")"
  ORIGINAL_ASG_MAX="$(jq -r '.AutoScalingGroups[0].MaxSize' <<<"$asg_json")"

  mapfile -t BATCH_OLD_INSTANCE_IDS < <(
    jq -r '
      .AutoScalingGroups[0].Instances[]
      | select(.LifecycleState == "InService")
      | .InstanceId
    ' <<<"$asg_json"
  )

  ((${#BATCH_OLD_INSTANCE_IDS[@]} > 0)) || die "no InService client instances found in $CLIENT_ASG_NAME"
  TARGET_DESIRED="$((ORIGINAL_ASG_DESIRED + ${#BATCH_OLD_INSTANCE_IDS[@]}))"

  echo "original_asg_desired=$ORIGINAL_ASG_DESIRED"
  echo "original_asg_max=$ORIGINAL_ASG_MAX"
  echo "target_desired_after_scale_out=$TARGET_DESIRED"
  echo "batch_old_instance_count=${#BATCH_OLD_INSTANCE_IDS[@]}"
  printf 'batch_old_instance_ids=%s\n' "${BATCH_OLD_INSTANCE_IDS[*]}"
}

batch_scale_out_client_asg() {
  log "Scaling out client ASG from $ORIGINAL_ASG_DESIRED to $TARGET_DESIRED before replacing old nodes"
  if [[ "$ALLOW_SCALE_OUT_CLIENT_NODE" != "1" ]]; then
    die "ALLOW_SCALE_OUT_CLIENT_NODE is not 1; refusing to change ASG desired capacity"
  fi

  if ((TARGET_DESIRED > ORIGINAL_ASG_MAX)); then
    if [[ "$ALLOW_INCREASE_ASG_MAX" != "1" ]]; then
      die "target desired $TARGET_DESIRED is greater than ASG max $ORIGINAL_ASG_MAX; set ALLOW_INCREASE_ASG_MAX=1 to bump max"
    fi

    log "Increasing client ASG max size from $ORIGINAL_ASG_MAX to $TARGET_DESIRED"
    aws_region autoscaling update-auto-scaling-group \
      --auto-scaling-group-name "$CLIENT_ASG_NAME" \
      --max-size "$TARGET_DESIRED"
  fi

  aws_region autoscaling update-auto-scaling-group \
    --auto-scaling-group-name "$CLIENT_ASG_NAME" \
    --desired-capacity "$TARGET_DESIRED"
}

batch_drain_old_orchestrators() {
  if [[ "$DRAIN_OLD_NODE" != "1" ]]; then
    warn "DRAIN_OLD_NODE is not 1; batch replacement will not mark old orchestrators draining"
    return
  fi

  discover_edge_api_base
  resolve_edge_secret

  local instance_id private_ip nomad_node_id row service_id node_id host status running
  for instance_id in "${BATCH_OLD_INSTANCE_IDS[@]}"; do
    private_ip="$(get_instance_private_ip "$instance_id")"
    if [[ -z "$private_ip" || "$private_ip" == "None" ]]; then
      warn "failed to resolve private IP for $instance_id; skip edge drain for this instance"
      continue
    fi

    row="$(nomad_node_row_by_ip "$private_ip" || true)"
    if [[ -z "$row" ]]; then
      warn "Nomad node for $instance_id ($private_ip) was not found; skip edge drain for this instance"
      continue
    fi

    IFS=$'\t' read -r nomad_node_id _ _ _ _ _ <<<"$row"
    row="$(find_orchestrator_row "$nomad_node_id" "$private_ip" || true)"
    if [[ -z "$row" ]]; then
      warn "orchestrator for $instance_id ($private_ip) is not visible from edge discovery; skip drain"
      continue
    fi

    IFS=$'\t' read -r service_id node_id host status running <<<"$row"
    echo "batch_old_orchestrator instance_id=$instance_id service_id=$service_id node_id=$node_id host=$host status=$status running_sandboxes=$running"

    OLD_ORCHESTRATOR_SERVICE_ID="$service_id"
    drain_old_orchestrator || warn "failed to mark old orchestrator draining for $instance_id"
  done
}

batch_collect_old_node_os_state() {
  if [[ "$COLLECT_OLD_NODE_OS_STATE" != "1" ]]; then
    warn "COLLECT_OLD_NODE_OS_STATE is not 1; skipping old node SSM diagnostics"
    return
  fi

  local instance_id
  for instance_id in "${BATCH_OLD_INSTANCE_IDS[@]}"; do
    OLD_INSTANCE_ID="$instance_id"
    (print_old_node_os_state) || warn "failed to collect old node OS state for $instance_id; continuing batch replacement"
  done
}

batch_terminate_old_instances_decrement_desired() {
  [[ "$ALLOW_TERMINATE_CLIENT_NODE" == "1" ]] || die "batch replacement requires ALLOW_TERMINATE_CLIENT_NODE=1"

  local instance_id
  log "Terminating ${#BATCH_OLD_INSTANCE_IDS[@]} old client instances and decrementing ASG desired capacity"
  for instance_id in "${BATCH_OLD_INSTANCE_IDS[@]}"; do
    echo "terminating_old_instance=$instance_id"
    aws_region autoscaling terminate-instance-in-auto-scaling-group \
      --instance-id "$instance_id" \
      --should-decrement-desired-capacity \
      >/dev/null
  done

  log "Waiting for old client instances to terminate"
  aws_region ec2 wait instance-terminated --instance-ids "${BATCH_OLD_INSTANCE_IDS[@]}"

  if ((TARGET_DESIRED > ORIGINAL_ASG_MAX)); then
    log "Restoring ASG max size to $ORIGINAL_ASG_MAX"
    aws_region autoscaling update-auto-scaling-group \
      --auto-scaling-group-name "$CLIENT_ASG_NAME" \
      --max-size "$ORIGINAL_ASG_MAX"
  fi
}

wait_for_batch_new_instances() {
  local expected_count="$1"
  shift
  local old_instances=("$@")
  local start now asg_json candidate_count instance

  log "Waiting for $expected_count replacement client instances to become InService and healthy"
  start="$(date +%s)"

  while true; do
    now="$(date +%s)"
    if ((now - start > WAIT_NEW_TIMEOUT_SECONDS)); then
      die "timed out waiting for $expected_count replacement client instances in $CLIENT_ASG_NAME"
    fi

    asg_json="$(describe_asg_json)"
    mapfile -t BATCH_NEW_INSTANCE_IDS < <(
      jq -r '
        .AutoScalingGroups[0].Instances[]
        | select(.LifecycleState == "InService" and .HealthStatus == "Healthy")
        | .InstanceId
      ' <<<"$asg_json" \
        | while IFS= read -r instance; do
            if ! instance_in_list "$instance" "${old_instances[@]}"; then
              printf '%s\n' "$instance"
            fi
          done
    )

    candidate_count="${#BATCH_NEW_INSTANCE_IDS[@]}"
    echo "batch_new_healthy_candidate_count=$candidate_count expected=$expected_count"
    if ((candidate_count >= expected_count)); then
      BATCH_NEW_INSTANCE_IDS=("${BATCH_NEW_INSTANCE_IDS[@]:0:$expected_count}")
      printf 'batch_new_instance_ids=%s\n' "${BATCH_NEW_INSTANCE_IDS[*]}"
      break
    fi

    sleep "$WAIT_POLL_SECONDS"
  done

  log "Waiting for EC2 status checks on replacement instances"
  aws_region ec2 wait instance-status-ok --instance-ids "${BATCH_NEW_INSTANCE_IDS[@]}"

  BATCH_NEW_PRIVATE_IPS=()
  for instance in "${BATCH_NEW_INSTANCE_IDS[@]}"; do
    BATCH_NEW_PRIVATE_IPS+=("$(get_instance_private_ip "$instance")")
  done
  printf 'batch_new_private_ips=%s\n' "${BATCH_NEW_PRIVATE_IPS[*]}"
}

batch_wait_new_nodes_healthy() {
  BATCH_NEW_NOMAD_NODE_IDS=()

  local private_ip resolved_node_id
  for private_ip in "${BATCH_NEW_PRIVATE_IPS[@]}"; do
    resolved_node_id=""
    wait_for_nomad_node_ready "$private_ip" resolved_node_id "new"
    BATCH_NEW_NOMAD_NODE_IDS+=("$resolved_node_id")
    wait_for_orchestrator_alloc "$resolved_node_id" "new"
  done

  if [[ -n "${EDGE_API_BASE:-}" && -n "${EDGE_SECRET:-}" ]]; then
    local i
    for i in "${!BATCH_NEW_PRIVATE_IPS[@]}"; do
      wait_for_edge_orchestrator_visible "${BATCH_NEW_NOMAD_NODE_IDS[$i]}" "${BATCH_NEW_PRIVATE_IPS[$i]}" "new"
    done
  fi
}

batch_post_checks() {
  log "Batch post checks"
  local asg_json desired in_service
  asg_json="$(describe_asg_json)"
  desired="$(jq -r '.AutoScalingGroups[0].DesiredCapacity' <<<"$asg_json")"
  in_service="$(jq -r '[.AutoScalingGroups[0].Instances[] | select(.LifecycleState == "InService")] | length' <<<"$asg_json")"
  echo "asg_desired=$desired"
  echo "asg_in_service=$in_service"
  echo "batch_new_instance_count=${#BATCH_NEW_INSTANCE_IDS[@]}"
  echo "batch_new_nomad_node_count=${#BATCH_NEW_NOMAD_NODE_IDS[@]}"
  log "Batch client node replacement checks passed"
}

post_checks() {
  log "Post checks"
  local asg_json desired in_service
  asg_json="$(describe_asg_json)"
  desired="$(jq -r '.AutoScalingGroups[0].DesiredCapacity' <<<"$asg_json")"
  in_service="$(jq -r '[.AutoScalingGroups[0].Instances[] | select(.LifecycleState == "InService")] | length' <<<"$asg_json")"
  echo "asg_desired=$desired"
  echo "asg_in_service=$in_service"

  wait_for_nomad_node_ready "$NEW_PRIVATE_IP" NEW_NOMAD_NODE_ID "new"
  wait_for_orchestrator_alloc "$NEW_NOMAD_NODE_ID" "new"

  if [[ -n "${EDGE_API_BASE:-}" && -n "${EDGE_SECRET:-}" ]]; then
    wait_for_edge_orchestrator_visible "$NEW_NOMAD_NODE_ID" "$NEW_PRIVATE_IP" "new"
  fi

  log "Client node replacement checks passed"
}

fast_no_customer_replacement() {
  log "Single-node scale-out-first replacement mode"
  [[ "$ALLOW_TERMINATE_CLIENT_NODE" == "1" ]] || die "FAST_NO_CUSTOMER_REPLACEMENT=1 requires ALLOW_TERMINATE_CLIENT_NODE=1"

  local old_asg_instances=("$@")

  scale_out_client_asg
  wait_for_new_instance "${old_asg_instances[@]}"
  wait_for_nomad_node_ready "$NEW_PRIVATE_IP" NEW_NOMAD_NODE_ID "new"
  wait_for_orchestrator_alloc "$NEW_NOMAD_NODE_ID" "new"

  resolve_nomad_node_by_ip "$OLD_PRIVATE_IP" OLD_NOMAD_NODE_ID "old"

  if [[ "$DRAIN_OLD_NODE" == "1" ]]; then
    if ! fast_drain_old_orchestrator_best_effort; then
      warn "failed to drain old orchestrator; continuing because FAST_NO_CUSTOMER_REPLACEMENT=1"
    fi
  else
    warn "DRAIN_OLD_NODE is not 1; continuing because FAST_NO_CUSTOMER_REPLACEMENT=1"
  fi

  collect_old_node_os_state
  terminate_old_instance_if_allowed

  if [[ -n "${EDGE_API_BASE:-}" && -n "${EDGE_SECRET:-}" ]]; then
    wait_for_edge_orchestrator_visible "$NEW_NOMAD_NODE_ID" "$NEW_PRIVATE_IP" "new"
  fi

  post_checks
}

fast_drain_old_orchestrator_best_effort() {
    discover_edge_api_base
    resolve_edge_secret

    local row service_id node_id host status running
    row="$(find_orchestrator_row "$OLD_NOMAD_NODE_ID" "$OLD_PRIVATE_IP" || true)"
    if [[ -n "$row" ]]; then
      IFS=$'\t' read -r service_id node_id host status running <<<"$row"
      OLD_ORCHESTRATOR_SERVICE_ID="$service_id"
      echo "old_orchestrator_service_id=$service_id node_id=$node_id host=$host status=$status running_sandboxes=$running"
      drain_old_orchestrator || warn "failed to mark old orchestrator draining; continuing because FAST_NO_CUSTOMER_REPLACEMENT=1"
    else
      warn "old orchestrator is not visible from client-proxy edge discovery; continuing because FAST_NO_CUSTOMER_REPLACEMENT=1"
    fi
}

batch_fast_replacement() {
  log "Batch scale-out-first replacement mode"
  [[ "$ALLOW_TERMINATE_CLIENT_NODE" == "1" ]] || die "BATCH_REPLACE_ALL_CLIENT_NODES=1 requires ALLOW_TERMINATE_CLIENT_NODE=1"

  discover_batch_old_instances
  batch_scale_out_client_asg
  wait_for_batch_new_instances "${#BATCH_OLD_INSTANCE_IDS[@]}" "${BATCH_OLD_INSTANCE_IDS[@]}"
  batch_wait_new_nodes_healthy
  if ! batch_drain_old_orchestrators; then
    warn "failed to drain one or more old orchestrators; continuing because BATCH_REPLACE_ALL_CLIENT_NODES=1"
  fi
  batch_collect_old_node_os_state
  batch_terminate_old_instances_decrement_desired
  batch_post_checks
}

main() {
  preflight

  if [[ "$BATCH_REPLACE_ALL_CLIENT_NODES" == "1" ]]; then
    batch_fast_replacement
    return
  fi

  choose_old_instance

  mapfile -t old_asg_instances < <(get_asg_instance_ids)

  if [[ "$FAST_NO_CUSTOMER_REPLACEMENT" == "1" ]]; then
    fast_no_customer_replacement "${old_asg_instances[@]}"
    return
  fi

  scale_out_client_asg
  wait_for_new_instance "${old_asg_instances[@]}"

  wait_for_nomad_node_ready "$NEW_PRIVATE_IP" NEW_NOMAD_NODE_ID "new"
  wait_for_orchestrator_alloc "$NEW_NOMAD_NODE_ID" "new"

  resolve_nomad_node_by_ip "$OLD_PRIVATE_IP" OLD_NOMAD_NODE_ID "old"

  if [[ "$DRAIN_OLD_NODE" == "1" ]]; then
    discover_edge_api_base
    resolve_edge_secret
    wait_for_edge_orchestrator_visible "$NEW_NOMAD_NODE_ID" "$NEW_PRIVATE_IP" "new"
    wait_for_edge_orchestrator_visible "$OLD_NOMAD_NODE_ID" "$OLD_PRIVATE_IP" "old"
    drain_old_orchestrator
    wait_for_old_orchestrator_drained
  else
    warn "Skipping edge drain and running-sandbox verification because DRAIN_OLD_NODE=$DRAIN_OLD_NODE"
    if [[ "$ALLOW_TERMINATE_CLIENT_NODE" == "1" && "$ALLOW_TERMINATE_WITH_RUNNING_SANDBOXES" != "1" ]]; then
      die "refusing to terminate without drain verification; set DRAIN_OLD_NODE=1 or ALLOW_TERMINATE_WITH_RUNNING_SANDBOXES=1"
    fi
  fi

  collect_old_node_os_state
  terminate_old_instance_if_allowed
  post_checks
}

main "$@"
