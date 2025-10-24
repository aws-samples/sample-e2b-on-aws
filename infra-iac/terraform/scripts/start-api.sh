#!/usr/bin/env bash

# This script is meant to be run in the User Data of each EC2 Instance while it's booting. The script uses the
# run-nomad and run-consul scripts to configure and start Nomad and Consul in client mode. Note that this script
# assumes it's running in an AMI built from the Packer template in examples/nomad-consul-ami/nomad-consul.json.

set -euo pipefail

# Set timestamp format
PS4='[\D{%Y-%m-%d %H:%M:%S}] '
# Enable command tracing
set -x

# Send the log output from this script to user-data.log, syslog, and the console
# Inspired by https://alestic.com/2010/12/ec2-user-data-output/
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

sudo apt-get update
sudo apt-get install -y amazon-ecr-credential-helper

ulimit -n 1048576
export GOMAXPROCS='nproc'

sudo tee -a /etc/sysctl.conf <<EOF
# Increase the maximum number of socket connections
net.core.somaxconn = 65535

# Increase the maximum number of backlogged connections
net.core.netdev_max_backlog = 65535

# Increase maximum number of TCP sockets
net.ipv4.tcp_max_syn_backlog = 65535
EOF
sudo sysctl -p

# These variables are passed in via Terraform template interpolation
aws s3 cp "s3://${SCRIPTS_BUCKET}/run-consul-${RUN_CONSUL_FILE_HASH}.sh" /opt/consul/bin/run-consul.sh
aws s3 cp "s3://${SCRIPTS_BUCKET}/run-api-nomad-${RUN_NOMAD_FILE_HASH}.sh" /opt/nomad/bin/run-nomad.sh
chmod +x /opt/consul/bin/run-consul.sh /opt/nomad/bin/run-nomad.sh

# Create initial Docker configuration
mkdir -p /root/docker
touch /root/docker/config.json

# Initial ECR token setup (without restarting Nomad since it's not running yet)
echo "[$(date)] Setting up initial ECR token..."
new_token=$(aws ecr get-authorization-token --region "${AWS_REGION}" --output text --query 'authorizationData[].authorizationToken' 2>/dev/null)

if [ -n "$new_token" ]; then
    cat <<EOF >/root/docker/config.json
{
    "auths": {
        "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com": {
            "auth": "$new_token"
        }
    }
}
EOF
    echo "[$(date)] Initial ECR token configured successfully"
else
    echo "[$(date)] Warning: Failed to get initial ECR token"
fi

# Create ECR token refresh script
cat <<'REFRESH_SCRIPT' >/usr/local/bin/refresh-ecr-token.sh
#!/bin/bash
# ECR Token Refresh Script for API Node
set -euo pipefail

AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID}"
AWS_REGION="${AWS_REGION}"
CONSUL_TOKEN="${CONSUL_TOKEN}"
LOG_FILE="/var/log/ecr-token-refresh.log"

# Log function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "Starting ECR token refresh..."

# Get new ECR token
new_token=$(aws ecr get-authorization-token --region "$AWS_REGION" --output text --query 'authorizationData[].authorizationToken' 2>/dev/null)

if [ -n "$new_token" ]; then
    # Update Docker config
    cat <<EOF >/root/docker/config.json
{
    "auths": {
        "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com": {
            "auth": "$new_token"
        }
    }
}
EOF
    log "ECR token refreshed successfully"
    
    # Restart Nomad to pick up new token
    if pgrep -f nomad > /dev/null; then
        log "Restarting Nomad service..."
        pkill -f nomad
        sleep 3
        /opt/nomad/bin/run-nomad.sh --consul-token "$CONSUL_TOKEN" &
        log "Nomad restarted successfully"
    else
        log "Nomad not running, skipping restart"
    fi
else
    log "ERROR: Failed to get ECR token"
    exit 1
fi
REFRESH_SCRIPT

# Make refresh script executable
chmod +x /usr/local/bin/refresh-ecr-token.sh

# Add cron job to refresh ECR token every 10 hours
cat <<CRON_JOB >/etc/cron.d/ecr-token-refresh
# Refresh ECR token every 10 hours
0 */10 * * * root /usr/local/bin/refresh-ecr-token.sh >> /var/log/ecr-token-refresh.log 2>&1
CRON_JOB

# Ensure cron service is running
systemctl enable cron
systemctl start cron

mkdir -p /etc/systemd/resolved.conf.d/
touch /etc/systemd/resolved.conf.d/consul.conf
cat <<EOF >/etc/systemd/resolved.conf.d/consul.conf
[Resolve]
DNS=127.0.0.1:8600
DNSSEC=false
Domains=~consul
EOF
systemctl restart systemd-resolved

# These variables are passed in via Terraform template interpolation
/opt/consul/bin/run-consul.sh --client \
    --consul-token "${CONSUL_TOKEN}" \
    --cluster-tag-name "${CLUSTER_TAG_NAME}" \
    --enable-gossip-encryption \
    --gossip-encryption-key "${CONSUL_GOSSIP_ENCRYPTION_KEY}" \
    --dns-request-token "${CONSUL_DNS_REQUEST_TOKEN}" &

/opt/nomad/bin/run-nomad.sh --consul-token "${CONSUL_TOKEN}" &
