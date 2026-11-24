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
    ["snapshot-retention"]="deploy/snapshot-retention-deploy.hcl"
)

declare -A jobs_all=(
    ["loki"]="deploy/loki-deploy.hcl"
    ["logs-collector"]="deploy/logs-collector-deploy.hcl"
    ["otel-collector"]="deploy/otel-collector-deploy.hcl"
    ["api"]="deploy/api-deploy.hcl"
    ["orchestrator"]="deploy/orchestrator-deploy.hcl"
    ["client-proxy"]="deploy/edge-deploy.hcl"
    ["template-manager"]="deploy/template-manager-deploy.hcl"
    ["snapshot-retention"]="deploy/snapshot-retention-deploy.hcl"
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
#
# snapshot-retention is a periodic batch job: `nomad job run` only registers
# it and returns, so it goes last and never holds up the services.
order_minimal=(loki orchestrator api client-proxy template-manager snapshot-retention)
order_all=(loki logs-collector otel-collector orchestrator api client-proxy template-manager snapshot-retention)

# With build_on_client (infra-iac/terraform/main.tf) the client orchestrators
# build templates in-process and the build pool is empty, so a template-manager
# job would only sit pending - and on a client node it would fight the
# orchestrator over network slots. Leave it out of both sets.
# Read the way nomad/prepare.sh reads it: a missing key (or no config file) is a
# stack from before the switch, anything present must be true or false.
BUILD_ON_CLIENT=false
if [[ -r /opt/config.properties ]] && grep -q '^build_on_client=' /opt/config.properties; then
    # Everything after the first "=", so "true=x" is rejected below, not read as true.
    BUILD_ON_CLIENT=$(awk 'index($0, "build_on_client=") == 1 {v = substr($0, 17)} END {print v}' /opt/config.properties)
fi
if [[ "$BUILD_ON_CLIENT" != "true" && "$BUILD_ON_CLIENT" != "false" ]]; then
    echo "Error: build_on_client in /opt/config.properties must be true or false, got '$BUILD_ON_CLIENT'" >&2
    exit 1
fi

# The rendered orchestrator job has to match that setting: one rendered before a
# switch would be submitted without (or with) the template-manager service while
# the template-manager job is skipped (or deployed), leaving no builder.
check_orchestrator_render() {
    local want="orchestrator"
    [[ "$BUILD_ON_CLIENT" == "true" ]] && want="orchestrator,template-manager"
    if ! grep -qF "ORCHESTRATOR_SERVICES = \"$want\"" deploy/orchestrator-deploy.hcl; then
        echo "Error: deploy/orchestrator-deploy.hcl was not rendered for build_on_client=$BUILD_ON_CLIENT; run nomad/prepare.sh first" >&2
        exit 1
    fi
}
if [[ "$BUILD_ON_CLIENT" == "true" ]]; then
    unset 'jobs_minimal[template-manager]' 'jobs_all[template-manager]'
    without_template_manager() {
        local name
        for name in "$@"; do
            [[ "$name" == "template-manager" ]] || printf '%s\n' "$name"
        done
    }
    mapfile -t order_minimal < <(without_template_manager "${order_minimal[@]}")
    mapfile -t order_all < <(without_template_manager "${order_all[@]}")
fi

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
        check_orchestrator_render
        for name in "${order_all[@]}"; do
            echo "deploying ${jobs_all[$name]}..."
            nomad job run "${jobs_all[$name]}"
        done
        ;;
    --min|-m)
        # Deploy minimal services if --min|-m provided
        check_orchestrator_render
        for name in "${order_minimal[@]}"; do
            echo "deploying ${jobs_minimal[$name]}..."
            nomad job run "${jobs_minimal[$name]}"
        done
        ;;
    "")
        # Deploy minimal services if no argument provided
        check_orchestrator_render
        for name in "${order_minimal[@]}"; do
            echo "deploying ${jobs_minimal[$name]}..."
            nomad job run "${jobs_minimal[$name]}"
        done
        ;;
    *)
        # Deploy specific service
        service=$1
        if [[ "$service" == "template-manager" && "$BUILD_ON_CLIENT" == "true" ]]; then
            echo "Error: build_on_client is set, the client orchestrators build templates; not deploying template-manager" >&2
            exit 1
        fi
        [[ "$service" == "orchestrator" ]] && check_orchestrator_render
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

