#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_REPO_DIR="${SOURCE_REPO_DIR:-/opt/infra/sample-e2b-on-aws}"
CONFIG_FILE="${CONFIG_FILE:-/opt/config.properties}"
REMOTE="${REMOTE:-origin}"
BRANCH="${BRANCH:-0303}"
LOG_DIR="${LOG_DIR:-/opt/infra/e2b-dev-api-deploy-$(date -u +%Y%m%dT%H%M%SZ)}"
WORK_DIR="$LOG_DIR/source"
REPO_DIR="$WORK_DIR"

mkdir -p "$LOG_DIR"

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

config_get() {
  local key="$1"
  awk -F= -v k="$key" '$1 == k {print substr($0, length($1) + 2)}' "$CONFIG_FILE" | tail -n 1
}

config_has() {
  local key="$1"
  grep -q "^${key}=" "$CONFIG_FILE"
}

append_config_if_missing() {
  local key="$1"
  local value="$2"
  if [[ -n "$value" ]] && ! config_has "$key"; then
    log "adding missing config key $key to $CONFIG_FILE"
    printf '%s=%s\n' "$key" "$value" >>"$CONFIG_FILE"
  fi
}

source_config() {
  set +u
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  set +a
  set -u
}

secret_json() {
  local secret_name="$1"
  aws secretsmanager get-secret-value \
    --secret-id "$secret_name" \
    --region "$AWS_REGION" \
    --query SecretString \
    --output text
}

secret_field() {
  local secret_name="$1"
  local field="$2"
  secret_json "$secret_name" | jq -r --arg field "$field" '.[$field] // empty'
}

private_nomad_ip() {
  aws ec2 describe-instances \
    --filters \
      "Name=tag:aws:autoscaling:groupName,Values=${CFNSTACKNAME}-server-asg" \
      "Name=instance-state-name,Values=running" \
    --region "$AWS_REGION" \
    --query 'Reservations[].Instances[].PrivateIpAddress' \
    --output text 2>/dev/null | tr '\t' '\n' | awk 'NF {print; exit}'
}

configure_go_env() {
  export GOPATH="${GOPATH:-/root/go}"
  export GOMODCACHE="${GOMODCACHE:-${GOPATH}/pkg/mod}"
  export GOCACHE="${GOCACHE:-/root/.cache/go-build}"
  export GOTMPDIR="${GOTMPDIR:-${LOG_DIR}/go-tmp}"
  export GOTOOLCHAIN=auto
  mkdir -p "$GOMODCACHE" "$GOCACHE" "$GOTMPDIR"
}

nomad_group_count() {
  local job="$1"
  local group="$2"
  local fallback="$3"
  local count
  count="$(nomad job inspect -json "$job" 2>/dev/null | jq -r --arg group "$group" '.TaskGroups[]? | select(.Name == $group) | .Count' | head -n 1 || true)"
  if [[ -z "$count" || "$count" == "null" ]]; then
    printf '%s' "$fallback"
  else
    printf '%s' "$count"
  fi
}

run_nomad_job() {
  local hcl="$1"
  local job="$2"
  log "nomad job run $job"
  nomad job run "$hcl" | tee "$LOG_DIR/nomad-run-${job}.log"
  nomad job status "$job" | tee "$LOG_DIR/nomad-status-${job}.log" || true
}

ecr_image_exists() {
  local repository="$1"
  aws ecr describe-images \
    --repository-name "$repository" \
    --image-ids "imageTag=${RELEASE_IMAGE_TAG}" \
    --region "$AWS_REGION" \
    >/dev/null 2>&1
}

preflight() {
  need_cmd git
  need_cmd aws
  need_cmd jq
  need_cmd curl
  need_cmd docker
  need_cmd nomad
  need_cmd make
  need_cmd go

  [[ -d "$SOURCE_REPO_DIR/.git" ]] || die "repo not found at $SOURCE_REPO_DIR"
  [[ -f "$CONFIG_FILE" ]] || die "config file not found: $CONFIG_FILE"
}

update_repo() {
  local remote_url

  log "preparing clean checkout from $SOURCE_REPO_DIR branch $BRANCH"
  remote_url="$(git -C "$SOURCE_REPO_DIR" remote get-url "$REMOTE")"
  git clone --no-tags --branch "$BRANCH" "$remote_url" "$WORK_DIR"
  cd "$REPO_DIR"
  git fetch "$REMOTE" "$BRANCH"
  git checkout -B "$BRANCH" "$REMOTE/$BRANCH"
  RELEASE_COMMIT_FULL="$(git rev-parse HEAD)"
  RELEASE_IMAGE_TAG="$(git rev-parse --short HEAD)"
  export RELEASE_COMMIT_FULL RELEASE_IMAGE_TAG
  log "release commit: $RELEASE_COMMIT_FULL"
  log "image tag: $RELEASE_IMAGE_TAG"
}

normalize_config() {
  log "normalizing $CONFIG_FILE"

  local jfrog_lower account az1 az2 infra_secret redis_endpoint redis_name
  jfrog_lower="$(config_get jfrog_artifactory_url || true)"
  append_config_if_missing "JFROGARTIFACTORYURL" "$jfrog_lower"

  account="$(config_get account_id || true)"
  if [[ -z "$account" ]]; then
    account="$(aws sts get-caller-identity --query Account --output text)"
  fi
  append_config_if_missing "account_id" "$account"

  az1="$(config_get aws_az1 || true)"
  if [[ -z "$az1" ]]; then
    az1="$(config_get CFNAZ1 || true)"
  fi
  append_config_if_missing "aws_az1" "$az1"

  az2="$(config_get aws_az2 || true)"
  if [[ -z "$az2" ]]; then
    az2="$(config_get CFNAZ2 || true)"
  fi
  append_config_if_missing "aws_az2" "$az2"

  redis_endpoint="$(config_get REDIS_ENDPOINT || true)"
  if [[ -z "$redis_endpoint" ]]; then
    redis_name="$(config_get CFNREDISNAME || true)"
    if [[ -z "$redis_name" ]]; then
      redis_name="$(config_get REDISNAME || true)"
    fi
    if [[ -n "$redis_name" ]]; then
      redis_endpoint="$(aws elasticache describe-serverless-caches \
        --serverless-cache-name "$redis_name" \
        --region "$(config_get AWSREGION)" \
        --query 'ServerlessCaches[0].Endpoint.Address' \
        --output text 2>/dev/null || true)"
      [[ "$redis_endpoint" == "None" ]] && redis_endpoint=""
    fi
  fi
  append_config_if_missing "REDIS_ENDPOINT" "$redis_endpoint"

  infra_secret="$(config_get infra_tokens_secret_name || true)"
  if [[ -z "$infra_secret" ]]; then
    local stack_name
    stack_name="$(config_get CFNSTACKNAME || true)"
    [[ -n "$stack_name" ]] && infra_secret="${stack_name}-infra-tokens"
  fi
  append_config_if_missing "infra_tokens_secret_name" "$infra_secret"

  source_config

  AWS_REGION="${AWSREGION:-}"
  AWS_ACCOUNT_ID="${account_id:-}"
  INFRA_TOKENS_SECRET_NAME="${infra_tokens_secret_name:-}"
  export AWS_REGION AWS_ACCOUNT_ID INFRA_TOKENS_SECRET_NAME

  [[ -n "$AWS_REGION" ]] || die "AWSREGION is missing from $CONFIG_FILE"
  [[ -n "$AWS_ACCOUNT_ID" ]] || die "account_id is missing from $CONFIG_FILE"
  [[ -n "$INFRA_TOKENS_SECRET_NAME" ]] || die "infra_tokens_secret_name is missing from $CONFIG_FILE"
  [[ -n "${CFNSTACKNAME:-}" ]] || die "CFNSTACKNAME is missing from $CONFIG_FILE"
  [[ -n "${CFNDOMAIN:-}" ]] || die "CFNDOMAIN is missing from $CONFIG_FILE"

  printf '%s\n' "${CFNENVIRONMENT:-dev}" >"$REPO_DIR/.last_used_env"
}

configure_nomad_env() {
  if [[ -z "${NOMAD_TOKEN:-}" ]]; then
    if [[ -r /opt/e2b/secrets/nomad_acl_token ]]; then
      export NOMAD_TOKEN
      NOMAD_TOKEN="$(cat /opt/e2b/secrets/nomad_acl_token)"
    else
      export NOMAD_TOKEN
      NOMAD_TOKEN="$(secret_field "$INFRA_TOKENS_SECRET_NAME" nomad_acl_token)"
    fi
  fi

  [[ -n "${NOMAD_TOKEN:-}" ]] || die "NOMAD_TOKEN could not be resolved"

  if [[ -z "${CONSUL_HTTP_TOKEN:-}" ]]; then
    if [[ -r /opt/e2b/secrets/consul_http_token ]]; then
      export CONSUL_HTTP_TOKEN
      CONSUL_HTTP_TOKEN="$(cat /opt/e2b/secrets/consul_http_token)"
    else
      export CONSUL_HTTP_TOKEN
      CONSUL_HTTP_TOKEN="$(secret_field "$INFRA_TOKENS_SECRET_NAME" consul_http_token)"
    fi
  fi

  [[ -n "${CONSUL_HTTP_TOKEN:-}" ]] || die "CONSUL_HTTP_TOKEN could not be resolved"

  if [[ -r /opt/nomad/tls/ca.pem && -r /opt/nomad/tls/cert.pem && -r /opt/nomad/tls/key.pem ]]; then
    export NOMAD_CACERT="${NOMAD_CACERT:-/opt/nomad/tls/ca.pem}"
    export NOMAD_CLIENT_CERT="${NOMAD_CLIENT_CERT:-/opt/nomad/tls/cert.pem}"
    export NOMAD_CLIENT_KEY="${NOMAD_CLIENT_KEY:-/opt/nomad/tls/key.pem}"
    export NOMAD_TLS_SERVER_NAME="${NOMAD_TLS_SERVER_NAME:-server.${AWS_REGION}.nomad}"
  fi

  if [[ -z "${NOMAD_ADDR:-}" ]]; then
    local nomad_ip
    nomad_ip="$(private_nomad_ip || true)"
    if [[ -n "$nomad_ip" && "$nomad_ip" != "None" ]]; then
      export NOMAD_ADDR="https://${nomad_ip}:4646"
    else
      export NOMAD_ADDR="https://nomad.${CFNDOMAIN}"
    fi
  fi

  log "using NOMAD_ADDR=$NOMAD_ADDR"
}

load_admin_token() {
  if [[ -z "${ADMIN_TOKEN:-}" ]]; then
    if [[ -r /opt/e2b/secrets/admin_token ]]; then
      export ADMIN_TOKEN
      ADMIN_TOKEN="$(cat /opt/e2b/secrets/admin_token)"
    else
      export ADMIN_TOKEN
      ADMIN_TOKEN="$(secret_field "$INFRA_TOKENS_SECRET_NAME" admin_token)"
    fi
  fi

  [[ -n "${ADMIN_TOKEN:-}" ]] || die "ADMIN_TOKEN could not be resolved"
}

build_and_upload_api() {
  log "building and uploading api artifact"
  cd "$REPO_DIR"
  export COMMIT_SHA="$RELEASE_IMAGE_TAG"
  configure_go_env

  if ecr_image_exists "e2b-orchestration/api"; then
    log "api image tag ${RELEASE_IMAGE_TAG} already exists; skipping build/push"
  else
    make -C packages/api build-and-upload-aws | tee "$LOG_DIR/build-api.log"
  fi

  local api_image
  api_image="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/e2b-orchestration/api:${RELEASE_IMAGE_TAG}"
  docker image rm "$api_image" >/dev/null 2>&1 || true
}

deploy_api_job() {
  log "deploying api nomad job"
  configure_nomad_env

  cd "$REPO_DIR/nomad"
  local api_count
  api_count="$(nomad_group_count api api-service 2)"
  log "preserving api-service count: $api_count"

  COMMIT_SHA="$RELEASE_IMAGE_TAG" API_COUNT="$api_count" bash ./prepare.sh | tee "$LOG_DIR/nomad-prepare.log"
  run_nomad_job "deploy/api-deploy.hcl" api
}

verify_api() {
  log "verifying api health and commit visibility"

  local api_base ok=false
  api_base="https://api.${CFNDOMAIN}"

  for attempt in {1..40}; do
    if curl -fsS --connect-timeout 5 --max-time 20 "$api_base/health" | tee "$LOG_DIR/api-health.log"; then
      ok=true
      break
    fi
    log "api health not ready yet, retrying in 15s ($attempt/40)"
    sleep 15
  done
  [[ "$ok" == "true" ]] || die "api health did not become ready"

  local expected_image actual_image current_job_version api_count
  api_count="$(nomad_group_count api api-service 2)"
  expected_image="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/e2b-orchestration/api:${RELEASE_IMAGE_TAG}"
  actual_image="$(nomad job inspect -json api | jq -r '.TaskGroups[] | select(.Name == "api-service") | .Tasks[] | select(.Name == "start") | .Config.image' | head -n 1)"
  printf '%s\n' "$actual_image" | tee "$LOG_DIR/api-job-image.txt" >/dev/null
  [[ "$actual_image" == "$expected_image" ]] || die "api job image mismatch: expected $expected_image, got ${actual_image:-<empty>}"

  nomad job inspect -json api | tee "$LOG_DIR/nomad-job-api.raw.json" >/dev/null
  current_job_version="$(jq -r '.Version' "$LOG_DIR/nomad-job-api.raw.json")"
  [[ "$current_job_version" =~ ^[0-9]+$ ]] || die "failed to resolve current api job version"

  ok=false
  for attempt in {1..20}; do
    if nomad job allocs -json api | tee "$LOG_DIR/nomad-api-allocations.raw.json" | \
      jq --argjson version "$current_job_version" '
        map({
          id: .ID,
          jobVersion: .JobVersion,
          clientStatus: .ClientStatus,
          desiredStatus: .DesiredStatus,
          taskState: (.TaskStates.start.State // ""),
          nodeID: .NodeID
        }) as $allocs
        | {
            allocations: $allocs,
            running_current_version: (
              $allocs
              | map(select(.jobVersion == $version and .clientStatus == "running" and .desiredStatus == "run" and .taskState == "running"))
            )
          }
      ' >"$LOG_DIR/nomad-api-allocations.json"; then
      if jq -e --argjson expected "$api_count" '.running_current_version | length >= $expected' "$LOG_DIR/nomad-api-allocations.json" >/dev/null; then
        ok=true
        break
      fi
    fi
    log "api allocations not fully rolled yet, retrying in 15s ($attempt/20)"
    sleep 15
  done
  [[ "$ok" == "true" ]] || die "api allocations did not converge to job version $current_job_version; inspect $LOG_DIR/nomad-api-allocations.json"

  log "api deploy verified with image $RELEASE_IMAGE_TAG and job version $current_job_version"
}

main() {
  preflight
  update_repo
  normalize_config
  build_and_upload_api
  deploy_api_job
  verify_api

  log "dev api deploy completed"
  log "logs: $LOG_DIR"
}

main "$@"
