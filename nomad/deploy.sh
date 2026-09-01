#!/bin/bash
set -e

# Navigate to the directory containing the script
cd "$(dirname "$0")"

# docker-reverse-proxy is gone: upstream deprecated and deleted the component,
# and its ALB target group / listener rule were removed with it.
# session-proxy never had a job file in origin/ - it was a dead reference.
declare -A jobs_minimal=(
    ["loki"]="deploy/loki-deploy.hcl"
    ["api"]="deploy/api-deploy.hcl"
    ["orchestrator"]="deploy/orchestrator-deploy.hcl"
    ["client-proxy"]="deploy/edge-deploy.hcl"
    ["template-manager"]="deploy/template-manager-deploy.hcl"
)

declare -A jobs_all=(
    ["loki"]="deploy/loki-deploy.hcl"
    ["logs-collector"]="deploy/logs-collector-deploy.hcl"
    ["otel-collector"]="deploy/otel-collector-deploy.hcl"
    ["api"]="deploy/api-deploy.hcl"
    ["orchestrator"]="deploy/orchestrator-deploy.hcl"
    ["client-proxy"]="deploy/edge-deploy.hcl"
    ["template-manager"]="deploy/template-manager-deploy.hcl"
)

# Deployment order. Iterating an associative array walks it in hash order, which
# is not stable; schema migrations now run as a prestart task inside the api job,
# so the sequence has to be explicit.
#
# orchestrator goes before api. `nomad job run` blocks until the deployment is
# healthy, and the api only reports healthy once it has discovered at least one
# orchestrator node (packages/api/internal/handlers/store.go: "Wait till there's
# at least one, otherwise we can't create sandboxes yet"). With api first, the
# two wait on each other until the api's progress_deadline expires ~10 minutes
# later. Nothing in the orchestrator depends on the api or on the database, so
# starting it first is safe.
order_minimal=(loki orchestrator api client-proxy template-manager)
order_all=(loki logs-collector otel-collector orchestrator api client-proxy template-manager)

# Set default jobs array to jobs_all for help and listing functions
declare -A jobs
for key in "${!jobs_all[@]}"; do
    jobs["$key"]="${jobs_all[$key]}"
done

function show_help() {
    echo "Usage: $0 [OPTION] [SERVICE]"
    echo "Deploy Nomad jobs"
    echo ""
    echo "Options:"
    echo "  --help       Show this help message"
    echo "  --list       List all available services"
    echo "  --all        Deploy all services, with monitoring and logging"
    echo "  --min        Deploy minimal services, without monitoring and logging, this is the default"
    echo ""
    echo "Available services:"
    for service in "${!jobs[@]}"; do
        echo "  $service"
    done
    exit 0
}

function list_services() {
    echo "Available services:"
    for service in "${!jobs[@]}"; do
        echo "  $service"
    done
    exit 0
}

# Nomad ignores every task's memory_max unless memory oversubscription is
# enabled on the cluster, and it only says so as a job-submission warning:
#   "Memory oversubscription is not enabled; Task ... memory_max value will be
#    ignored. Update the Scheduler Configuration to allow oversubscription."
# The template-manager reserves 1024 MiB and relies on memory_max = -1 to burst
# past it while building; without this the build is hard-capped at 1 GiB and gets
# OOM-killed. The setting lives in cluster state, so a rebuilt cluster silently
# reverts to the default and has to be set again on every deploy.
function ensure_memory_oversubscription() {
    local current
    current=$(nomad operator scheduler get-config 2>/dev/null | awk '/Memory Oversubscription/ {print $NF}')
    case "$current" in
        true)
            echo "Memory oversubscription already enabled."
            ;;
        false)
            echo "Enabling memory oversubscription (required for memory_max)..."
            nomad operator scheduler set-config -memory-oversubscription=true \
                || echo "WARNING: could not enable it; template builds will be capped at their memory reservation." >&2
            ;;
        *)
            echo "WARNING: could not read the Nomad scheduler config; skipping the" >&2
            echo "         memory oversubscription check. Is NOMAD_ADDR/NOMAD_TOKEN set?" >&2
            ;;
    esac
}

case "${1:-}" in
    --help|-h|--list|-l) ;;
    *) ensure_memory_oversubscription ;;
esac

# Handle options
case "$1" in
    --help|-h)
        show_help
        ;;
    --list|-l)
        list_services
        ;;
    --all|-a)
        # Deploy all services if --all|-a provided
        for name in "${order_all[@]}"; do
            echo "deploying ${jobs_all[$name]}..."
            nomad job run "${jobs_all[$name]}"
        done
        ;;
    --min|-m)
        # Deploy minimal services if --min|-m provided
        for name in "${order_minimal[@]}"; do
            echo "deploying ${jobs_minimal[$name]}..."
            nomad job run "${jobs_minimal[$name]}"
        done
        ;;
    "")
        # Deploy minimal services if no argument provided
        for name in "${order_minimal[@]}"; do
            echo "deploying ${jobs_minimal[$name]}..."
            nomad job run "${jobs_minimal[$name]}"
        done
        ;;
    *)
        # Deploy specific service
        service=$1
        if [[ -n "${jobs[$service]}" ]]; then
            echo "deploying ${jobs[$service]}..."
            nomad job run "${jobs[$service]}"
        else
            echo "Error: Unknown service '$service'"
            list_services
            exit 1
        fi
        ;;
esac

echo "Nomad jobs deployment completed!"

