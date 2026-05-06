#!/bin/bash
set -e

echo "=== Starting cleanup of all created resources ==="

# Stop and remove Docker containers and volumes
echo "Stopping and removing Docker containers and volumes..."
docker-compose down -v || echo "Docker containers may already be stopped or do not exist"

# Remove Docker images (optional, uncomment to remove)
# echo "Removing PostgreSQL Docker image..."
# docker rmi postgres:15 || echo "PostgreSQL image may not exist or is in use"

# Remove created script files
echo "Removing created script files..."
rm -f run-all-migrations.sh check-tables.sh migrate-and-verify.sh

# Remove init-scripts directory
echo "Removing init-scripts directory..."
rm -rf init-scripts

# Remove this cleanup script (executed last)
echo "=== Cleanup complete ==="
echo "Note: this script (cleanup.sh) will self-delete after execution"
echo "Run 'rm -f cleanup.sh' to delete this script"
