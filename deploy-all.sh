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

# Funnel everything into one log, exactly as the UserData does, and skip it when
# the caller has already set one up - nesting a second tee on the same file would
# write every line twice.
if [ -z "${E2B_LOG_FUNNEL:-}" ]; then
  export E2B_LOG_FUNNEL=1
  exec > >(tee -a "$LOG") 2>&1
fi

cd "$REPO_DIR" || exit 1

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
#   Error submitting job: dial tcp 10.0.55.63:4646: connect: connection refused
#
# Waiting on a leader alone is not enough either. The jobs are placed per pool -
# loki and api on api, orchestrator on the client nodes (default), and
# template-manager on build - and `nomad job run` blocks until the deployment is
# healthy, so a missing pool turns into a stalled step rather than a clear error.
wait_for_nomad() {
  local deadline=$((SECONDS + 900))
  local leader pools missing pool
  echo "$(date '+%Y-%m-%d %H:%M:%S') Waiting for the Nomad cluster to accept jobs at $NOMAD_ADDR"
  while [ $SECONDS -lt $deadline ]; do
    leader=$(curl -sf -H "X-Nomad-Token: ${NOMAD_TOKEN:-}" "$NOMAD_ADDR/v1/status/leader" | tr -d '"')
    if [ -n "$leader" ]; then
      pools=$(curl -sf -H "X-Nomad-Token: ${NOMAD_TOKEN:-}" "$NOMAD_ADDR/v1/nodes" \
        | jq -r '[.[] | select(.Status == "ready") | .NodePool] | unique | join(",")')
      missing=""
      for pool in default api build; do
        printf '%s\n' "$pools" | tr ',' '\n' | grep -qx "$pool" || missing="$missing $pool"
      done
      if [ -z "$missing" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') Cluster ready: leader $leader, pools ready: $pools"
        return 0
      fi
      echo "  leader $leader, pools ready: ${pools:-none}, still waiting for:$missing"
    else
      echo "  no leader yet at $NOMAD_ADDR"
    fi
    sleep 15
  done
  echo "Error: the Nomad cluster was not ready within 15 minutes." >&2
  echo "       Last seen: leader='${leader:-none}' ready pools='${pools:-none}'." >&2
  echo "       Check the server and client instances came up and joined:" >&2
  echo "         nomad server members ; nomad node status" >&2
  echo "       and, on a node that never joined, /var/log/cloud-init-output.log." >&2
  return 1
}

run_named() {
  case "$1" in
    init)            run_step init bash infra-iac/init.sh ;;
    packer)          run_step packer env HOME=/root bash -l infra-iac/packer/packer.sh ;;
    terraform)       run_step terraform bash infra-iac/terraform/start.sh ;;
    init-db)         run_step init-db bash infra-iac/db/init-db.sh ;;
    build)           run_step build env HOME=/root bash tools/build-and-upload.sh ;;
    prepare)         load_nomad_env && run_step prepare bash nomad/prepare.sh ;;
    deploy)          load_nomad_env && wait_for_nomad && run_step deploy bash nomad/deploy.sh ;;
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
