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

  while sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
        sudo fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
        sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    sleep 5
  done

sudo apt-get -o DPkg::Lock::Timeout=300 update
sudo apt-get -o DPkg::Lock::Timeout=300 install -y amazon-ecr-credential-helper

ulimit -n 1048576
export GOMAXPROCS='nproc'

sudo tee -a /etc/sysctl.conf <<EOF
# Increase the maximum number of socket connections
net.core.somaxconn = 65535

# Increase the maximum number of backlogged connections
net.core.netdev_max_backlog = 65535

# Increase maximum number of TCP sockets
net.ipv4.tcp_max_syn_backlog = 65535

# Reserve static service ports from being used as ephemeral ports
net.ipv4.ip_local_reserved_ports = 50001
EOF
sudo sysctl -p

# These variables are passed in via Terraform template interpolation
aws s3 cp "s3://${SCRIPTS_BUCKET}/run-consul-${RUN_CONSUL_FILE_HASH}.sh" /opt/consul/bin/run-consul.sh
aws s3 cp "s3://${SCRIPTS_BUCKET}/run-api-nomad-${RUN_NOMAD_FILE_HASH}.sh" /opt/nomad/bin/run-nomad.sh
chmod +x /opt/consul/bin/run-consul.sh /opt/nomad/bin/run-nomad.sh

mkdir -p /root/docker
touch /root/docker/config.json
# export ECR_AUTH_TOKEN=$(aws ecr get-authorization-token --output text --query 'authorizationData[].authorizationToken')
cat <<EOF >/root/docker/config.json
{
    "auths": {
        "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com": {
            "auth": "$(aws ecr get-authorization-token --output text --query 'authorizationData[].authorizationToken')"
        }
    }
}
EOF

mkdir -p /etc/systemd/resolved.conf.d/
touch /etc/systemd/resolved.conf.d/consul.conf
cat <<EOF >/etc/systemd/resolved.conf.d/consul.conf
[Resolve]
DNS=127.0.0.1:8600
DNSSEC=false
Domains=~consul
EOF
systemctl restart systemd-resolved

# Retrieve secrets at runtime from AWS Secrets Manager
get_secret() {
  aws secretsmanager get-secret-value --secret-id "$1" --region "${AWS_REGION}" --query SecretString --output text
}

CONSUL_TOKEN=$(get_secret "${CONSUL_SECRET_NAME}")
CONSUL_GOSSIP_ENCRYPTION_KEY=$(get_secret "${CONSUL_GOSSIP_SECRET_NAME}")
CONSUL_DNS_REQUEST_TOKEN=$(get_secret "${CONSUL_DNS_SECRET_NAME}")

# Retrieve Nomad TLS certificates and write to disk
mkdir -p /opt/nomad/tls
get_secret "${NOMAD_TLS_CA_SECRET}" > /opt/nomad/tls/ca.pem
get_secret "${NOMAD_TLS_CERT_SECRET}" > /opt/nomad/tls/cert.pem
get_secret "${NOMAD_TLS_KEY_SECRET}" > /opt/nomad/tls/key.pem
chown nomad:nomad /opt/nomad/tls/*.pem
chmod 600 /opt/nomad/tls/*.pem

cp /opt/nomad/tls/ca.pem /opt/consul/tls/ca/ca.pem
cp /opt/nomad/tls/cert.pem /opt/consul/tls/cert.pem
cp /opt/nomad/tls/key.pem /opt/consul/tls/key.pem
chown -R consul:consul /opt/consul/tls
chmod 600 /opt/consul/tls/key.pem /opt/consul/tls/cert.pem
chmod 644 /opt/consul/tls/ca/ca.pem

# Write secrets to /opt/e2b/secrets/ for Nomad template {{ file }} access
SECRETS_DIR="/opt/e2b/secrets"
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

DB_SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "${DB_CREDENTIAL_SECRET_NAME}" --region "${AWS_REGION}" --query SecretString --output text)
DB_HOST=$(echo "$DB_SECRET_JSON" | jq -r '.host')
DB_USER=$(echo "$DB_SECRET_JSON" | jq -r '.username')
DB_PASS=$(echo "$DB_SECRET_JSON" | jq -r '.password')
DB_NAME=$(echo "$DB_SECRET_JSON" | jq -r '.dbname')
printf '%s' "postgresql://$${DB_USER}:$${DB_PASS}@$${DB_HOST}/$${DB_NAME}" > "$SECRETS_DIR/postgres_connection_string"
printf '%s' "$DB_HOST" > "$SECRETS_DIR/postgres_host"
printf '%s' "$DB_USER" > "$SECRETS_DIR/postgres_user"
printf '%s' "$DB_PASS" > "$SECRETS_DIR/postgres_password"

INFRA_JSON=$(aws secretsmanager get-secret-value --secret-id "${INFRA_TOKENS_SECRET_NAME}" --region "${AWS_REGION}" --query SecretString --output text)
printf '%s' "$(echo "$INFRA_JSON" | jq -r '.nomad_acl_token')" > "$SECRETS_DIR/nomad_acl_token"
printf '%s' "$(echo "$INFRA_JSON" | jq -r '.consul_http_token')" > "$SECRETS_DIR/consul_http_token"
printf '%s' "$(echo "$INFRA_JSON" | jq -r '.admin_token')" > "$SECRETS_DIR/admin_token"
SEED=$(echo "$INFRA_JSON" | jq -r '.sandbox_access_token_hash_seed // empty')
[ -z "$SEED" ] && SEED=$(echo "$INFRA_JSON" | jq -r '.admin_token')
printf '%s' "$SEED" > "$SECRETS_DIR/sandbox_access_token_hash_seed"

chmod 600 "$SECRETS_DIR"/*

/opt/consul/bin/run-consul.sh --client \
    --consul-token "$${CONSUL_TOKEN}" \
    --cluster-tag-name "${CLUSTER_TAG_NAME}" \
    --enable-gossip-encryption \
    --gossip-encryption-key "$${CONSUL_GOSSIP_ENCRYPTION_KEY}" \
    --dns-request-token "$${CONSUL_DNS_REQUEST_TOKEN}" \
    --enable-rpc-encryption \
    --verify-server-hostname \
    --ca-path /opt/consul/tls/ca \
    --cert-file-path /opt/consul/tls/cert.pem \
    --key-file-path /opt/consul/tls/key.pem &

/opt/nomad/bin/run-nomad.sh --consul-token "$${CONSUL_TOKEN}" &
