#!/bin/bash
# Run the whole E2B deploy chain on the bastion.
#
# This is the chain CloudFormation runs for you when AutoDeploy=true. With
# AutoDeploy=false the stack only clones this tree and installs the toolchain,
# and this script is how you drive everything that is left:
#
#   sudo bash deploy-all.sh
#
# The UserData calls this same script on the automatic path, so the step order
# and the checkpoint names live in one place instead of being kept in sync by
# hand between the template and the manual instructions.
#
# set -u is deliberately absent: nomad/nomad.sh is sourced into this shell and
# tests NOMAD_TOKEN/CONSUL_HTTP_TOKEN before either is necessarily set.
set -o pipefail

LOG=/tmp/e2b.log
CKPT_DIR=/opt

# Every step, in the order they have to run. terraform needs the config file
# init writes, build needs the ECR repositories terraform creates, and deploy
# needs the images build pushes.
STEPS=(init packer terraform init-db build prepare deploy create-template)

ACTION=""
SKIP_TEMPLATE=false
ONLY_STEP=""
FORCE=false
STACK_NAME_ARG=""

usage() {
  cat <<'EOF'
Usage: sudo bash deploy-all.sh [options]

Runs the E2B deploy chain on the bastion: init, packer, terraform, init-db,
build, prepare, deploy, create-template.

Each step writes /opt/.e2b-step-<name>.done when it succeeds, so re-running the
script after fixing a failure resumes at the step that broke instead of starting
over. All output goes to /tmp/e2b.log as well as to your terminal.

Options:
  --list                 Show the steps and which ones are already done
  --only STEP            Run just STEP, ignoring its checkpoint
  --force                Clear all checkpoints first and run the chain again
  --skip-template        Stop after deploy, without building a test template
  --stack-name NAME      Record NAME as the stack in /tmp/e2b.log. Needed only
                         when the log has no StackName= line, which is the case
                         if this tree was delivered by hand rather than cloned
                         by the stack's UserData - infra-iac/init.sh reads the
                         stack name from that line.
  --help                 Show this message
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --list)          ACTION=list; shift ;;
    --only)          ONLY_STEP="$2"; shift 2 ;;
    --force)         FORCE=true; shift ;;
    --skip-template) SKIP_TEMPLATE=true; shift ;;
    --stack-name)    STACK_NAME_ARG="$2"; shift 2 ;;
    --help|-h)       usage; exit 0 ;;
    *)               echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# Absolute, because the sudo re-exec below would otherwise hand sudo a bare
# "deploy-all.sh" for it to look up on PATH, where it is not.
REPO_DIR=$(cd "$(dirname "$0")" && pwd) || exit 1
SELF=$REPO_DIR/$(basename "$0")

is_done() { [ -f "$CKPT_DIR/.e2b-step-$1.done" ]; }

# Listing only reads the checkpoint files, so it runs before the root check.
if [ "$ACTION" = list ]; then
  echo "Deploy steps (checkpoints in $CKPT_DIR):"
  for step in "${STEPS[@]}"; do
    if is_done "$step"; then echo "  [done] $step"; else echo "  [todo] $step"; fi
  done
  exit 0
fi

# The steps run terraform, docker and the AWS CLI as root and write to /opt, the
# same way the UserData does. Elevate rather than failing halfway through.
if [ "$(id -u)" -ne 0 ]; then
  echo "deploy-all.sh needs root; re-running under sudo."
  exec sudo -- bash "$SELF" "$@"
fi

# The UserData path runs without HOME, and the toolchain the steps drive assumes
# one: go keeps its build cache there (init-db's goose migrations die with
# "GOCACHE is not defined and neither $XDG_CACHE_HOME nor $HOME are defined"),
# and packer and docker keep their plugins, config and registry credentials
# there. Pin it once, to the home of root, who runs every step.
export HOME=/root

# Funnel everything into one log, exactly as the UserData does, and skip it when
# the caller has already set one up - nesting a second tee on the same file would
# write every line twice.
if [ -z "${E2B_LOG_FUNNEL:-}" ]; then
  export E2B_LOG_FUNNEL=1
  exec > >(tee -a "$LOG") 2>&1
fi

cd "$REPO_DIR" || exit 1

# The UserData hands this tree to ubuntu so the login user can drive git, which
# makes it "dubious ownership" for root - and every git call in the chain runs as
# root. The upstream Makefiles take COMMIT_SHA from `git rev-parse`, so without
# this the binaries and images ship with an empty commitSHA and "compare the
# replicas' commit_sha with HEAD" can no longer tell a fresh build from a stale
# one. --global (root's, given the HOME pinned above) so the exception widens
# trust for root alone rather than for every user on the host.
if ! git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$REPO_DIR"; then
  git config --global --add safe.directory "$REPO_DIR" || {
    echo "Error: could not mark $REPO_DIR as a safe git directory for root." >&2
    exit 1
  }
fi

# Each deployment step records a marker on success so a re-run (after fixing
# whatever failed) resumes instead of starting the whole chain over. This is the
# same marker the UserData path uses, so a stack that got half way through
# automatically continues from where it stopped.
run_step() {
  STEP_NAME=$1
  shift
  MARKER=$CKPT_DIR/.e2b-step-$STEP_NAME.done
  echo "========================================"
  if [ -f "$MARKER" ] && [ -z "$ONLY_STEP" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') Step $STEP_NAME already completed, skipping"
    echo "========================================"
    return 0
  fi
  echo "$(date '+%Y-%m-%d %H:%M:%S') Start to execute $STEP_NAME"
  echo "========================================"
  if "$@"; then
    touch "$MARKER"
    echo "$(date '+%Y-%m-%d %H:%M:%S') Step $STEP_NAME OK"
    return 0
  fi
  echo "$(date '+%Y-%m-%d %H:%M:%S') Step $STEP_NAME FAILED, aborting deploy chain"
  return 1
}

NOMAD_ENV_LOADED=false
load_nomad_env() {
  $NOMAD_ENV_LOADED && return 0
  echo "========================================"
  echo "$(date '+%Y-%m-%d %H:%M:%S') Start to execute nomad.sh"
  echo "========================================"
  # Sourced rather than run: it exports NOMAD_ADDR/NOMAD_TOKEN into this shell
  # for the prepare and deploy steps below. It calls exit on failure, which ends
  # this script as well - that is the intended fail-fast, since neither step can
  # reach the cluster without those variables.
  source nomad/nomad.sh || return 1
  NOMAD_ENV_LOADED=true
}

# terraform returns as soon as the ASGs exist, but a fresh instance still has to
# boot, join Consul and start Nomad - about three minutes. nomad/nomad.sh does
# not close that gap: it checks that two servers are in the EC2 running state,
# which says nothing about whether anything is listening on 4646. Without this
# gate the deploy step ran 45 seconds after terraform finished and died on
#   Error submitting job: dial tcp 192.0.2.5:4646: connect: connection refused
#
# Waiting on a leader alone is not enough either. The jobs are placed per pool -
# loki and api on api, orchestrator on the client nodes (default), and
# template-manager on build - and `nomad job run` blocks until the deployment is
# healthy, so a missing pool turns into a stalled step rather than a clear error.
# With build_on_client the build pool is empty by design and is not waited for.
#
# A node is reported ready before Nomad has fingerprinted its Consul agent, and
# until it has, the node fails the "${attr.consul.version} semver >= 1.8.0"
# constraint Nomad adds to every job with a Consul service. A system job such as
# logs-collector then skips that node and `nomad job run` exits non-zero on the
# placement failure. It happened on switching build_on_client back to false: the
# build node terraform had just started was ready but not yet fingerprinted when
# the deploy step ran. So every ready node has to carry consul.version as well.
wait_for_nomad() {
  local deadline=$((SECONDS + 900))
  local leader nodes pools missing pool id name unprinted required="default api build"
  [ "$(config_value build_on_client)" = true ] && required="default api"
  echo "$(date '+%Y-%m-%d %H:%M:%S') Waiting for the Nomad cluster to accept jobs at $NOMAD_ADDR (pools: $required)"
  while [ $SECONDS -lt $deadline ]; do
    leader=$(curl -sf --connect-timeout 5 --max-time 15 -H "X-Nomad-Token: ${NOMAD_TOKEN:-}" "$NOMAD_ADDR/v1/status/leader" | tr -d '"')
    if [ -n "$leader" ]; then
      nodes=$(curl -sf --connect-timeout 5 --max-time 15 -H "X-Nomad-Token: ${NOMAD_TOKEN:-}" "$NOMAD_ADDR/v1/nodes")
      pools=$(jq -r '[.[] | select(.Status == "ready") | .NodePool] | unique | join(",")' <<<"${nodes:-[]}")
      missing=""
      for pool in $required; do
        printf '%s\n' "$pools" | tr ',' '\n' | grep -qx "$pool" || missing="$missing $pool"
      done
      # The node list carries no attributes; each ready node is read on its own.
      unprinted=""
      while read -r id name; do
        [ -n "$id" ] || continue
        curl -sf --connect-timeout 5 --max-time 15 -H "X-Nomad-Token: ${NOMAD_TOKEN:-}" "$NOMAD_ADDR/v1/node/$id" \
          | jq -e '.Attributes["consul.version"] // empty' >/dev/null || unprinted="$unprinted $name"
      done < <(jq -r '.[] | select(.Status == "ready") | "\(.ID) \(.Name)"' <<<"${nodes:-[]}")
      if [ -z "$missing" ] && [ -z "$unprinted" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') Cluster ready: leader $leader, pools ready: $pools"
        return 0
      fi
      echo "  leader $leader, pools ready: ${pools:-none}, still waiting for:${missing:- none}; no Consul fingerprint yet:${unprinted:- none}"
    else
      echo "  no leader yet at $NOMAD_ADDR"
    fi
    sleep 15
  done
  echo "Error: the Nomad cluster was not ready within 15 minutes." >&2
  echo "       Last seen: leader='${leader:-none}' ready pools='${pools:-none}' ready nodes without a Consul fingerprint='${unprinted:-none}'." >&2
  echo "       Check the server and client instances came up and joined:" >&2
  echo "         nomad server members ; nomad node status" >&2
  echo "       and, on a node that never joined, /var/log/cloud-init-output.log." >&2
  return 1
}

# The api job's db-migrator prestart task applies whatever migrations a code-layer
# sync brought in, and upstream migrations rewrite the tiers table more than once.
# init-db's checkpoint keeps it from running again on a redeploy, so reapply this
# deployment's tier limits right after the jobs are up - even when a job after
# api fails, since by then the migrator may already have rewritten the tiers
# under a running API. The step still fails if nomad/deploy.sh did.
#
# Loki goes first because logs-collector ships sandbox logs to it, then the two
# collectors, so the services find something listening on :30006 and :4317 when
# they start. nomad/deploy.sh (the minimal set) runs loki again, which is a
# no-op. A collector failing fails the step but does not stop the services from
# being deployed.
#
# With build_on_client the client orchestrators build templates and nomad/deploy.sh
# skips template-manager; a stack switched over from a build pool still has that
# job registered, so it is stopped before the orchestrator takes over. Before
# anything is touched the rendered orchestrator job has to carry the matching
# ORCHESTRATOR_SERVICES - a deploy without the prepare after the switch would
# otherwise stop the old builder and start an orchestrator that does not build.
# And if the old builder cannot be stopped the step stops there, so it is never
# left taking builds for a CPU the client pool no longer runs.
deploy_jobs() {
  local rc=0 build_on_client services
  build_on_client=$(config_value build_on_client) || return 1
  # Missing is a stack from before the switch existed; present must be true/false.
  if [ -z "$build_on_client" ] && ! grep -q '^[[:blank:]]*build_on_client[[:blank:]]*=' /opt/config.properties; then
    build_on_client=false
  fi
  case "$build_on_client" in
    true)  services="orchestrator,template-manager" ;;
    false) services="orchestrator" ;;
    *) echo "Error: build_on_client in /opt/config.properties must be true or false, got '$build_on_client'." >&2; return 1 ;;
  esac
  if ! grep -qF "ORCHESTRATOR_SERVICES = \"$services\"" nomad/deploy/orchestrator-deploy.hcl; then
    echo "Error: nomad/deploy/orchestrator-deploy.hcl was not rendered for build_on_client=$build_on_client." >&2
    echo "       Run: sudo bash deploy-all.sh --only prepare && sudo bash deploy-all.sh --only deploy" >&2
    return 1
  fi
  bash nomad/deploy.sh loki || rc=$?
  { bash nomad/deploy.sh logs-collector && wait_system_job logs-collector; } || rc=$?
  deploy_otel_collector || rc=$?
  if [ "$build_on_client" = true ]; then
    stop_job_if_active template-manager || return 1
  fi
  bash nomad/deploy.sh || rc=$?
  bash infra-iac/db/apply-tier-limits.sh || return 1
  return $rc
}

# A key of /opt/config.properties read the way nomad/prepare.sh reads it:
# comment lines are skipped, the key is what precedes the first "=" with blanks
# around it dropped (so "otel_customer_endpoint =..." counts too), and the last
# occurrence wins. Only spaces and tabs are trimmed from the value - what xargs
# trims - so a stray carriage return stays in it and is refused as a control
# character instead of silently differing from what prepare renders. Fails when
# the file cannot be read, rather than reporting the key as unset.
config_value() {
  awk -v want="$1" '
    /^[[:space:]]*#/ || index($0, "=") == 0 { next }
    {
      key = substr($0, 1, index($0, "=") - 1)
      gsub(/^[[:blank:]]+|[[:blank:]]+$/, "", key)
      if (key == want) { val = substr($0, index($0, "=") + 1); found = 1 }
    }
    END { if (found) { gsub(/^[[:blank:]]+|[[:blank:]]+$/, "", val); print val } }
  ' /opt/config.properties
}

# GET a Nomad API path. Prints the body, then the HTTP status on a last line
# ("000" when the request itself failed), so callers can tell "no such job"
# from "could not ask".
nomad_get() {
  curl -s --connect-timeout 5 --max-time 15 -H "X-Nomad-Token: ${NOMAD_TOKEN:-}" \
    -w '\n%{http_code}' "$NOMAD_ADDR$1"
}

# ", ', \, $, ` and braces change meaning on the way into the collector: the
# values are substituted verbatim into YAML double-quoted strings inside a Nomad
# template (which parses "{{" even in a branch it does not take), the collector
# expands ${...} itself, and prepare.sh reads them through xargs, which strips
# quotes, squeezes runs of spaces and hands a leading "-n" or "-e" to echo as an
# option. Control characters would break the KEY=VALUE file itself. Refuse all
# of them rather than ship a config that breaks or sends something else.
has_unsafe_chars() {
  [[ "$1" == *[\"\'\\\$\`{}]* || "$1" == *[[:cntrl:]]* || "$1" == *"  "* || "$1" == -* ]]
}

# What prepare rendered otel-collector from, and what it rendered: the settings'
# fingerprint plus the digest of the job file. deploy checks both, so neither a
# key changed after the last prepare nor a job file rendered some other way
# (nomad/prepare.sh run directly) can be validated against one configuration
# and then shipped with another.
OTEL_RENDERED=/opt/.e2b-otel-rendered
OTEL_JOB_FILE=nomad/deploy/otel-collector-deploy.hcl
otel_fingerprint() {
  local endpoint name value
  endpoint=$(config_value otel_customer_endpoint) || return 1
  name=$(config_value otel_customer_header_name) || return 1
  value=$(config_value otel_customer_header_value) || return 1
  printf '%s\n' "$endpoint" "$name" "$value" | sha256sum | cut -d' ' -f1
}

# The fingerprint is taken before prepare reads the file, so it describes what
# was rendered. prepare.sh falls back to the environment for otel_customer_*
# and build_on_client when the file lacks them; unset those so only the file
# decides, as it does for nomad/deploy.sh.
prepare_jobs() {
  local fp job
  fp=$(otel_fingerprint) || return 1
  env -u otel_customer_endpoint -u otel_customer_header_name -u otel_customer_header_value -u build_on_client \
    bash nomad/prepare.sh || return 1
  job=$(sha256sum "$OTEL_JOB_FILE" | cut -d' ' -f1) || return 1
  echo "$fp $job" > "$OTEL_RENDERED"
}

# Stops a job and waits until none of its allocations is still running. Succeeds
# when the job does not exist; fails when Nomad cannot be asked, the stop fails
# or a task is still up two minutes later, so a collector from an earlier
# configuration is never assumed gone.
stop_job_if_active() {
  local res code stopped left deadline=$((SECONDS + 120))
  res=$(nomad_get "/v1/job/$1"); code=${res##*$'\n'}
  case "$code" in
    404) return 0 ;;
    200) ;;
    *) echo "Error: could not look up job $1 (HTTP $code)." >&2; return 1 ;;
  esac
  # Not jq -e: that also fails when the answer is a legitimate "false".
  if ! stopped=$(jq -r '.Stop | if type == "boolean" then . else error("no Stop flag") end' <<<"${res%$'\n'*}" 2>/dev/null); then
    echo "Error: unexpected answer from Nomad for job $1." >&2
    return 1
  fi
  if [ "$stopped" = false ]; then
    echo "$1: stopping the copy left by an earlier configuration"
    nomad job stop -yes "$1" >/dev/null || { echo "Error: nomad job stop $1 failed." >&2; return 1; }
  fi
  while [ $SECONDS -lt $deadline ]; do
    # all=true also lists allocations of an earlier registration of the job.
    res=$(nomad_get "/v1/job/$1/allocations?all=true"); code=${res##*$'\n'}
    left=""
    [ "$code" = 200 ] && left=$(jq '[.[] | select(.ClientStatus == "running" or .ClientStatus == "pending" or .ClientStatus == "unknown")] | length' <<<"${res%$'\n'*}")
    [ "$left" = 0 ] && return 0
    sleep 5
  done
  echo "Error: $1 still has ${left:-unknown} allocation(s) running two minutes after the stop." >&2
  return 1
}

# otel-collector exports to the backend in the otel_customer_* keys, which the
# operator adds to /opt/config.properties once the regular installation is done
# (README, "Deploy with Customer OTel Endpoint"). With no endpoint there is
# nothing to export to, so the job is not deployed - and a copy from an earlier
# configuration is stopped rather than left sending to the old backend with the
# old credential. Stopping does not depend on the rendered job, so it happens
# before the check that prepare has caught up.
deploy_otel_collector() {
  local endpoint header_name header_value rendered expected url_re
  if ! endpoint=$(config_value otel_customer_endpoint) \
      || ! header_name=$(config_value otel_customer_header_name) \
      || ! header_value=$(config_value otel_customer_header_value); then
    echo "Error: could not read /opt/config.properties." >&2
    return 1
  fi

  if [ -z "$endpoint" ]; then
    echo "otel-collector: no otel_customer_endpoint in /opt/config.properties - not deployed"
    stop_job_if_active otel-collector
    return
  fi
  rendered=$(cat "$OTEL_RENDERED" 2>/dev/null)
  expected="$(otel_fingerprint) $(sha256sum "$OTEL_JOB_FILE" 2>/dev/null | cut -d' ' -f1)"
  if ! [[ "$rendered" =~ ^[0-9a-f]{64}\ [0-9a-f]{64}$ ]] || [ "$expected" != "$rendered" ]; then
    echo "Error: $OTEL_JOB_FILE was not rendered by the last prepare from the current otel_customer_* settings." >&2
    echo "       Run: sudo bash deploy-all.sh --only prepare && sudo bash deploy-all.sh --only deploy" >&2
    return 1
  fi
  # The exporter appends /v1/metrics etc. to the endpoint string as it is, so a
  # query or fragment would swallow the signal path; percent-escapes must be
  # well formed, or the collector rejects the URL after the job is submitted.
  url_re='^https?://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?(/([A-Za-z0-9._~!&()*+,;=:@/-]|%[0-9A-Fa-f]{2})*)?$'
  if ! [[ "$endpoint" =~ $url_re ]] || has_unsafe_chars "$endpoint"; then
    echo "Error: otel_customer_endpoint must be http(s)://host[:port][/path] - no query, fragment, spaces, quotes or malformed %-escapes." >&2
    return 1
  fi
  if [ -n "$header_name" ] || [ -n "$header_value" ]; then
    if [ -z "$header_name" ] || [ -z "$header_value" ]; then
      echo "Error: set otel_customer_header_name and otel_customer_header_value together, or neither." >&2
      return 1
    fi
    if ! [[ "$header_name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
      echo "Error: otel_customer_header_name may only contain letters, digits, hyphens and underscores, starting with a letter or digit." >&2
      return 1
    fi
    if [[ "$endpoint" != https://* ]]; then
      echo "Error: refusing to send the $header_name header to a plain http:// endpoint; use https://." >&2
      return 1
    fi
    if has_unsafe_chars "$header_value"; then
      echo "Error: the OTel header value contains a quote, backslash, \$, \`, brace, control character or double space, or starts with -, which the collector config cannot carry." >&2
      return 1
    fi
  fi
  bash nomad/deploy.sh otel-collector && wait_system_job otel-collector
}

# `nomad job run` returns for a system job once its allocations are placed:
# system jobs get no deployment, so nothing waits for them to come up, and a
# collector that rejects its config would crash-loop behind a green step. Wait
# until the job's current version runs on every ready, eligible node (both
# collectors target node pool "all"), and the same allocations of the same
# version are still running 20 seconds later without having restarted in
# between. This proves the collector is up, not that the backend accepts what it
# sends - a rejected credential shows up as "Exporting failed" in its logs.
wait_system_job() {
  local job=$1 deadline=$((SECONDS + 300)) res code version node_ids allocs failed running_nodes missing ids restarts
  local seen="" seen_restarts=0
  while [ $SECONDS -lt $deadline ]; do
    res=$(nomad_get "/v1/job/$job"); code=${res##*$'\n'}
    version=""; [ "$code" = 200 ] && version=$(jq -r '.Version // empty' <<<"${res%$'\n'*}")
    res=$(nomad_get "/v1/nodes"); code=${res##*$'\n'}
    node_ids=""; [ "$code" = 200 ] && node_ids=$(jq -r '.[] | select(.Status == "ready" and .SchedulingEligibility == "eligible") | .ID' <<<"${res%$'\n'*}" | sort)
    res=$(nomad_get "/v1/job/$job/allocations"); code=${res##*$'\n'}
    if [ -z "$version" ] || [ -z "$node_ids" ] || [ "$code" != 200 ]; then
      seen=""; sleep 5; continue
    fi
    # The job's current allocations: this version, wanted running, not replaced.
    allocs=$(jq -c --argjson v "$version" '[.[] | select(.JobVersion == $v and .DesiredStatus == "run" and ((.NextAllocation // "") == ""))]' <<<"${res%$'\n'*}")
    failed=$(jq '[.[] | select(.ClientStatus == "failed" or .ClientStatus == "lost")] | length' <<<"$allocs")
    if [ "$failed" -gt 0 ]; then
      echo "Error: $job has $failed failed allocation(s) of version $version." >&2
      echo "       nomad job status $job lists them; nomad alloc logs -stderr <alloc-id> says why." >&2
      return 1
    fi
    running_nodes=$(jq -r '.[] | select(.ClientStatus == "running") | .NodeID' <<<"$allocs" | sort -u)
    missing=$(comm -23 <(printf '%s\n' "$node_ids") <(printf '%s\n' "$running_nodes") | grep -c .)
    if [ "$missing" -eq 0 ]; then
      ids=$(jq -r '[.[] | select(.ClientStatus == "running") | .ID] | sort | join(",")' <<<"$allocs")
      restarts=$(jq '[.[] | select(.ClientStatus == "running") | (.TaskStates // {})[] | .Restarts] | add // 0' <<<"$allocs")
      if [ "$version|$ids" = "$seen" ]; then
        if [ "$restarts" -gt "$seen_restarts" ]; then
          echo "Error: $job restarted $((restarts - seen_restarts)) time(s) within 20 seconds - it is crash-looping." >&2
          echo "       nomad alloc logs -stderr <alloc-id> says why." >&2
          return 1
        fi
        echo "$job: running version $version on all $(printf '%s\n' "$node_ids" | grep -c .) ready node(s)"
        return 0
      fi
      seen="$version|$ids"; seen_restarts=$restarts
      sleep 20
      continue
    fi
    seen=""
    sleep 5
  done
  echo "Error: $job was not running on every ready node within 5 minutes (${missing:-?} without a running allocation)." >&2
  return 1
}

run_named() {
  case "$1" in
    init)            run_step init bash infra-iac/init.sh ;;
    packer)          run_step packer bash -l infra-iac/packer/packer.sh ;;
    terraform)       run_step terraform bash infra-iac/terraform/start.sh ;;
    init-db)         run_step init-db bash infra-iac/db/init-db.sh ;;
    build)           run_step build bash tools/build-and-upload.sh ;;
    prepare)         load_nomad_env && run_step prepare prepare_jobs ;;
    deploy)          load_nomad_env && wait_for_nomad && run_step deploy deploy_jobs ;;
    create-template) run_step create-template bash tools/legacy/create_template.sh ;;
    *) echo "Unknown step: $1" >&2; return 2 ;;
  esac
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

if [ -n "$STACK_NAME_ARG" ]; then
  echo "StackName=$STACK_NAME_ARG"
fi

# infra-iac/init.sh resolves the stack the same way, off the same line.
STACK_NAME=$(grep '^StackName=' "$LOG" 2>/dev/null | tail -1 | cut -d'=' -f2)

# /tmp/e2b.log is written once by the UserData and then only appended to, so
# systemd-tmpfiles eventually deletes it for being untouched (10 days on Ubuntu),
# taking the stack name with it. /opt/config.properties carries the same value as
# CFNSTACKNAME and lives on a path nothing sweeps, so fall back to it and put the
# line back into the log for infra-iac/init.sh, which only reads the log.
if [ -z "$STACK_NAME" ] && [ -f /opt/config.properties ]; then
  STACK_NAME=$(grep '^CFNSTACKNAME=' /opt/config.properties | tail -1 | cut -d'=' -f2)
  if [ -n "$STACK_NAME" ]; then
    echo "StackName=$STACK_NAME"
    echo "  ($LOG had no StackName=; recovered it from /opt/config.properties)"
  fi
fi

if [ -z "$STACK_NAME" ]; then
  echo "Error: no StackName= line in $LOG and no CFNSTACKNAME in" >&2
  echo "       /opt/config.properties, so the stack cannot be resolved." >&2
  echo "       infra-iac/init.sh reads the stack name from the log. Re-run as" >&2
  echo "       sudo bash deploy-all.sh --stack-name <your-stack>" >&2
  exit 1
fi
echo "Stack: $STACK_NAME"
echo "BUILD=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

# The UserData waits for the stack before starting, because it runs while the
# stack is still coming up. Keep that guard here: terraform reads the stack
# outputs, and a half-created stack has not published them yet.
while true; do
  STACK_STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query "Stacks[0].StackStatus" --output text) || exit 1
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Stack current state: $STACK_STATUS"
  case $STACK_STATUS in
    CREATE_COMPLETE|UPDATE_COMPLETE)
      break
      ;;
    CREATE_FAILED|ROLLBACK_COMPLETE|ROLLBACK_FAILED|UPDATE_ROLLBACK_COMPLETE|UPDATE_ROLLBACK_FAILED|DELETE_FAILED)
      echo "exit with error cloudformation state: $STACK_STATUS" >&2
      exit 1
      ;;
    *)
      sleep 10
      ;;
  esac
done

if $FORCE; then
  echo "--force: clearing checkpoints in $CKPT_DIR"
  rm -f "$CKPT_DIR"/.e2b-step-*.done
fi

# ---------------------------------------------------------------------------
# Chain
# ---------------------------------------------------------------------------

if [ -n "$ONLY_STEP" ]; then
  run_named "$ONLY_STEP" || exit 1
  echo "$(date '+%Y-%m-%d %H:%M:%S') Step $ONLY_STEP finished."
  exit 0
fi

for step in "${STEPS[@]}"; do
  if [ "$step" = create-template ] && $SKIP_TEMPLATE; then
    echo "--skip-template: not building a test template."
    continue
  fi
  run_named "$step" || exit 1
done

echo "========================================"
echo "$(date '+%Y-%m-%d %H:%M:%S') E2B Deploy Done!"
echo "========================================"
