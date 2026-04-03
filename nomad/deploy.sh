#!/bin/bash
set -e

cd "$(dirname "$0")"

# Load Nomad env if not already set
if [ -z "$NOMAD_ADDR" ]; then
    if [ -f /tmp/nomad_env.sh ]; then
        source /tmp/nomad_env.sh
    else
        echo "Error: NOMAD_ADDR not set and /tmp/nomad_env.sh not found"
        exit 1
    fi
fi

echo "NOMAD_ADDR=$NOMAD_ADDR"

# Deploy order matters: orchestrator first (system job), then services
JOBS_MINIMAL=(
    "deploy/orchestrator-deploy.hcl"
    "deploy/template-manager-deploy.hcl"
    "deploy/api-deploy.hcl"
    "deploy/edge-deploy.hcl"
    "deploy/docker-reverse-proxy-deploy.hcl"
)

JOBS_MONITORING=(
    "deploy/loki-deploy.hcl"
    "deploy/logs-collector-deploy.hcl"
    "deploy/otel-collector-deploy.hcl"
)

deploy_jobs() {
    local jobs=("$@")
    for job in "${jobs[@]}"; do
        if [ ! -f "$job" ]; then
            echo "Warning: $job not found, skipping"
            continue
        fi
        echo "Deploying $job..."
        nomad job run -detach "$job"
    done
}

case "${1:-}" in
    --all|-a)
        deploy_jobs "${JOBS_MONITORING[@]}"
        sleep 5
        deploy_jobs "${JOBS_MINIMAL[@]}"
        ;;
    --help|-h)
        echo "Usage: $0 [--all|--min|SERVICE_NAME]"
        echo "  --min (default): orchestrator, template-manager, api, client-proxy, docker-reverse-proxy"
        echo "  --all: adds loki, logs-collector, otel-collector"
        ;;
    ""|--min|-m)
        deploy_jobs "${JOBS_MINIMAL[@]}"
        ;;
    *)
        if [ -f "deploy/${1}-deploy.hcl" ]; then
            nomad job run -detach "deploy/${1}-deploy.hcl"
        else
            echo "Error: Unknown service '$1'"
            exit 1
        fi
        ;;
esac

echo ""
echo "Nomad jobs submitted. Checking status in 30s..."
sleep 30
nomad job status
