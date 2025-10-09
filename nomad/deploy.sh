#!/bin/bash
set -e

# Navigate to the directory containing the script
cd "$(dirname "$0")"

declare -A jobs_minimal=(
    # ["redis"]="deploy/redis-deploy.hcl"
    ["api"]="deploy/api-deploy.hcl"
    ["orchestrator"]="deploy/orchestrator-deploy.hcl"
    ["client-proxy"]="deploy/edge-deploy.hcl"
    ["template-manager"]="deploy/template-manager-deploy.hcl"
    # ["docker-reverse-proxy"]="deploy/docker-reverse-proxy-deploy.hcl"
)

declare -A jobs_all=(
    ["loki"]="deploy/loki-deploy.hcl"
    ["logs-collector"]="deploy/logs-collector-deploy.hcl"
    ["otel-collector"]="deploy/otel-collector-deploy.hcl"
    # ["redis"]="deploy/redis-deploy.hcl"
    ["api"]="deploy/api-deploy.hcl"
    ["orchestrator"]="deploy/orchestrator-deploy.hcl"
    ["client-proxy"]="deploy/edge-deploy.hcl"
    ["session-proxy"]="deploy/session-proxy-deploy.hcl"
    ["template-manager"]="deploy/template-manager-deploy.hcl"
    # ["docker-reverse-proxy"]="deploy/docker-reverse-proxy-deploy.hcl"
)

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
        for job in "${jobs_all[@]}"; do
            echo "deploying $job..."
            nomad job run "$job"
        done
        ;;
    --min|-m)
        # Deploy minimal services if --min|-m provided
        for job in "${jobs_minimal[@]}"; do
            echo "deploying $job..."
            nomad job run "$job"
        done
        ;;        
    "")
        # Deploy minimal services if no argument provided
        for job in "${jobs_minimal[@]}"; do
            echo "deploying $job..."
            nomad job run "$job"
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

