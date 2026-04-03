#!/bin/bash
# nomad.sh - Discover Nomad server and write env to /tmp/nomad_env.sh

ENV_FILE="/tmp/nomad_env.sh"
> "$ENV_FILE"

if [ ! -f /opt/config.properties ]; then
    echo "Error: /opt/config.properties not found"
    echo 'export NOMAD_SETUP_ERROR="config not found"' >> "$ENV_FILE"
    exit 1
fi

CFNSTACKNAME=$(grep "^CFNSTACKNAME=" /opt/config.properties | cut -d'=' -f2)
AWSREGION=$(grep "^AWSREGION=" /opt/config.properties | cut -d'=' -f2)
nomad_acl_token=$(grep "^nomad_acl_token=" /opt/config.properties | cut -d'=' -f2)
consul_http_token=$(grep "^consul_http_token=" /opt/config.properties | cut -d'=' -f2)

INSTANCE_NAME="${CFNSTACKNAME}-server"
echo "Looking for EC2 instances: $INSTANCE_NAME"

# Wait up to 5 minutes for at least 1 server instance
NOMAD_IP=""
for i in $(seq 1 30); do
    NOMAD_IP=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=running" \
        --query "Reservations[0].Instances[0].PrivateIpAddress" \
        --output text --region "$AWSREGION" 2>/dev/null)

    if [ -n "$NOMAD_IP" ] && [ "$NOMAD_IP" != "None" ]; then
        break
    fi
    NOMAD_IP=""
    echo "  Waiting for server instances... (${i}/30)"
    sleep 10
done

if [ -z "$NOMAD_IP" ]; then
    echo "Error: No server instances found after 5 minutes"
    echo 'export NOMAD_SETUP_ERROR="No instances"' >> "$ENV_FILE"
    exit 1
fi
echo "Found ${#IP_ARRAY[@]} server(s), using: $NOMAD_IP"

# Wait for Nomad API to be reachable
echo "Waiting for Nomad API..."
for i in $(seq 1 30); do
    if curl -sf -o /dev/null "http://${NOMAD_IP}:4646/v1/agent/health" -H "X-Nomad-Token: ${nomad_acl_token}" 2>/dev/null; then
        echo "  Nomad API ready"
        break
    fi
    [ $i -eq 30 ] && echo "Warning: Nomad API not responding after 5 min, continuing anyway"
    sleep 10
done

cat > "$ENV_FILE" << EOF
export NOMAD_ADDR="http://${NOMAD_IP}:4646"
export NOMAD_TOKEN="${nomad_acl_token}"
export CONSUL_HTTP_TOKEN="${consul_http_token}"
export NOMAD_SETUP_SUCCESS=true
EOF

echo "Nomad env written to $ENV_FILE"
echo "  NOMAD_ADDR=http://${NOMAD_IP}:4646"

# Auto-load if sourced
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    source "$ENV_FILE"
fi
