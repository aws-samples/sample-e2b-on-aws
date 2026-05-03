#!/bin/bash
# This script is meant to be run in the User Data of each EC2 Instance while it's booting. The script uses the
# run-nomad and run-consul scripts to configure and start Consul and Nomad in server mode. Note that this script
# assumes it's running in an AWS AMI built from the Packer template.

set -e

# Send the log output from this script to user-data.log, syslog, and the console
# Inspired by https://alestic.com/2010/12/ec2-user-data-output/
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

ulimit -n 65536
export GOMAXPROCS='nproc'

  while sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
        sudo fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
        sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    sleep 5
  done

sudo apt-get -o DPkg::Lock::Timeout=300 update
sudo apt-get -o DPkg::Lock::Timeout=300 install -y amazon-ecr-credential-helper

aws s3 cp "s3://${SCRIPTS_BUCKET}/run-consul-${RUN_CONSUL_FILE_HASH}.sh" /opt/consul/bin/run-consul.sh
aws s3 cp "s3://${SCRIPTS_BUCKET}/run-nomad-${RUN_NOMAD_FILE_HASH}.sh" /opt/nomad/bin/run-nomad.sh

chmod +x /opt/consul/bin/run-consul.sh /opt/nomad/bin/run-nomad.sh

# Retrieve secrets at runtime from AWS Secrets Manager
get_secret() {
  aws secretsmanager get-secret-value --secret-id "$1" --region "${AWS_REGION}" --query SecretString --output text
}

CONSUL_TOKEN=$(get_secret "${CONSUL_SECRET_NAME}")
NOMAD_TOKEN=$(get_secret "${NOMAD_SECRET_NAME}")
CONSUL_GOSSIP_ENCRYPTION_KEY=$(get_secret "${CONSUL_GOSSIP_SECRET_NAME}")

# Retrieve Nomad TLS certificates and write to disk
mkdir -p /opt/nomad/tls
get_secret "${NOMAD_TLS_CA_SECRET}" > /opt/nomad/tls/ca.pem
get_secret "${NOMAD_TLS_CERT_SECRET}" > /opt/nomad/tls/cert.pem
get_secret "${NOMAD_TLS_KEY_SECRET}" > /opt/nomad/tls/key.pem
chmod 600 /opt/nomad/tls/*.pem

cp /opt/nomad/tls/ca.pem /opt/consul/tls/ca/ca.pem
cp /opt/nomad/tls/cert.pem /opt/consul/tls/cert.pem
cp /opt/nomad/tls/key.pem /opt/consul/tls/key.pem
chown -R consul:consul /opt/consul/tls
chmod 600 /opt/consul/tls/key.pem /opt/consul/tls/cert.pem
chmod 644 /opt/consul/tls/ca/ca.pem

/opt/consul/bin/run-consul.sh --server \
    --cluster-tag-name "${CLUSTER_TAG_NAME}" \
    --consul-token "$${CONSUL_TOKEN}" \
    --enable-gossip-encryption \
    --gossip-encryption-key "$${CONSUL_GOSSIP_ENCRYPTION_KEY}" \
    --enable-rpc-encryption \
    --verify-server-hostname \
    --ca-path /opt/consul/tls/ca \
    --cert-file-path /opt/consul/tls/cert.pem \
    --key-file-path /opt/consul/tls/key.pem
/opt/nomad/bin/run-nomad.sh --server --num-servers "${NUM_SERVERS}" --consul-token "$${CONSUL_TOKEN}" --nomad-token "$${NOMAD_TOKEN}"
