#!/bin/bash
# This script is used to configure and run Nomad on an AWS EC2 Instance.

set -e

readonly NOMAD_CONFIG_FILE="default.hcl"
readonly SUPERVISOR_CONFIG_PATH="/etc/supervisor/conf.d/run-nomad.conf"

readonly EC2_METADATA_URL="http://169.254.169.254/latest"

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "$0")"

function log {
  local readonly level="$1"
  local readonly message="$2"
  local readonly timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo >&2 -e "${timestamp} [${level}] [$SCRIPT_NAME] ${message}"
}

function log_info {
  local readonly message="$1"
  log "INFO" "$message"
}

function log_warn {
  local readonly message="$1"
  log "WARN" "$message"
}

function log_error {
  local readonly message="$1"
  log "ERROR" "$message"
}

# Based on code from: http://stackoverflow.com/a/16623897/483528
function strip_prefix {
  local readonly str="$1"
  local readonly prefix="$2"
  echo "${str#$prefix}"
}

function assert_not_empty {
  local readonly arg_name="$1"
  local readonly arg_value="$2"

  if [[ -z "$arg_value" ]]; then
    log_error "The value for '$arg_name' cannot be empty"
    print_usage
    exit 1
  fi
}

# Get the value at a specific EC2 Instance Metadata path
function get_instance_metadata_value {
  local readonly path="$1"

  # AWS IMDSv2 requires a token first for security
  TOKEN=$(curl -X PUT --silent --show-error "$EC2_METADATA_URL/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")

  log_info "Looking up Metadata value at $EC2_METADATA_URL/$path"
  curl --silent --show-error --location -H "X-aws-ec2-metadata-token: $TOKEN" "$EC2_METADATA_URL/$path"
}

# Get the value of a tag from EC2 Instance Tags
function get_instance_tag_value {
  local readonly key="$1"

  log_info "Looking up Instance Tag value for key \"$key\""
  # This requires instance profile with permission to describe tags
  # Using the instance-id from metadata to find the tags
  aws ec2 describe-tags --filters "Name=resource-id,Values=$(get_instance_id)" "Name=key,Values=$key" --query "Tags[0].Value" --output text
}

# Get the AWS account ID
function get_aws_account_id {
  log_info "Looking up AWS Account ID"
  aws sts get-caller-identity --query "Account" --output text
}

# Get the AWS Zone (availability zone) in which this EC2 Instance currently resides
function get_instance_zone {
  log_info "Looking up Availability Zone of the current EC2 Instance"
  get_instance_metadata_value "meta-data/placement/availability-zone"
}

function get_instance_region {
  # Remove the last character from the availability zone to get the region
  # e.g., us-east-1a -> us-east-1
  get_instance_zone | sed 's/[a-z]$//'
}

# Get the ID of the current EC2 Instance
function get_instance_name {
  log_info "Looking up current EC2 Instance ID"
  get_instance_metadata_value "meta-data/instance-id"
}

# Get the ID of the current EC2 Instance (alternative name)
function get_instance_id {
  get_instance_metadata_value "meta-data/instance-id"
}

# Get the IP Address of the current EC2 Instance
function get_instance_ip_address {
  log_info "Looking up EC2 Instance IP Address"
  get_instance_metadata_value "meta-data/local-ipv4"
}

function assert_is_installed {
  local readonly name="$1"

  if [[ ! $(command -v ${name}) ]]; then
    log_error "The binary '$name' is required by this script but is not installed or in the system's PATH."
    exit 1
  fi
}

function generate_nomad_config {
  local readonly server="$1"
  local readonly client="$2"
  local readonly num_servers="$3"
  local readonly config_dir="$4"
  local readonly user="$5"
  local readonly consul_token="$6"
  local readonly config_path="$config_dir/$NOMAD_CONFIG_FILE"

  local instance_name=""
  local instance_ip_address=""
  local instance_region=""
  local instance_zone=""

  instance_name=$(get_instance_name)
  instance_ip_address=$(get_instance_ip_address)
  instance_region=$(get_instance_region)
  zone=$(get_instance_zone)

  log_info "Creating default Nomad config file in $config_path"
  cat >"$config_path" <<EOF
datacenter = "$zone"
name       = "$instance_name"
region     = "$instance_region"
bind_addr  = "0.0.0.0"

advertise {
  http = "$instance_ip_address"
  rpc  = "$instance_ip_address"
  serf = "$instance_ip_address"
}

leave_on_interrupt = true
leave_on_terminate = true

client {
  enabled = true
  node_pool = "build"
  meta {
    "node_pool" = "build"
  }
  max_kill_timeout = "24h"
}

plugin_dir = "/opt/nomad/plugins"

plugin "docker" {
  config {
    volumes {
      enabled = true
    }
    auth {
      config = "/root/docker/config.json"
    }
  }
}


plugin "raw_exec" {
  config {
    enabled = true
    no_cgroups = true
  }
}

log_level = "DEBUG"
log_json = true

telemetry {
  collection_interval = "5s"
  disable_hostname = true
  prometheus_metrics = true
  publish_allocation_metrics = true
  publish_node_metrics = true
}

acl {
  enabled = true
}

limits {
  http_max_conns_per_client = 80
  rpc_max_conns_per_client = 80
}

consul {
  address = "127.0.0.1:8500"
  allow_unauthenticated = false
  token = "$consul_token"
}
EOF
  chown "$user:$user" "$config_path"
}

function generate_supervisor_config {
  local readonly supervisor_config_path="$1"
  local readonly nomad_config_dir="$2"
  local readonly nomad_data_dir="$3"
  local readonly nomad_bin_dir="$4"
  local readonly nomad_log_dir="$5"
  local readonly nomad_user="$6"
  local readonly use_sudo="$7"

  if [[ "$use_sudo" == "true" ]]; then
    log_info "The --use-sudo flag is set, so running Nomad as the root user"
    nomad_user="root"
  fi

  log_info "Creating Supervisor config file to run Nomad in $supervisor_config_path"
  cat >"$supervisor_config_path" <<EOF
[program:nomad]
command=$nomad_bin_dir/nomad agent -config $nomad_config_dir -data-dir $nomad_data_dir
stdout_logfile=$nomad_log_dir/nomad-stdout.log
stderr_logfile=$nomad_log_dir/nomad-error.log
numprocs=1
autostart=true
autorestart=true
stopsignal=INT
minfds=65536
user=$nomad_user
EOF
}

function start_nomad {
  log_info "Reloading Supervisor config and starting Nomad"
  supervisorctl reread
  supervisorctl update
}

function bootstrap {
  log_info "Waiting for Nomad to start"
  while test -z "$(curl -s http://127.0.0.1:4646/v1/agent/health)"; do
    log_info "Nomad not yet started. Waiting for 1 second."
    sleep 1
  done
  log_info "Nomad server started."

  local readonly nomad_token="$1"
  log_info "Bootstrapping Nomad"
  echo "$nomad_token" >"/tmp/nomad.token"
  nomad acl bootstrap /tmp/nomad.token
  rm "/tmp/nomad.token"
}

# Based on: http://unix.stackexchange.com/a/7732/215969
function get_owner_of_path {
  local readonly path="$1"
  ls -ld "$path" | awk '{print $3}'
}

function run {
  local nodepool="default"
  local all_args=()

  while [[ $# > 0 ]]; do
    local key="$1"

    case "$key" in
    --consul-token)
      assert_not_empty "$key" "$2"
      consul_token="$2"
      shift
      ;;
    *)
      log_error "Unrecognized argument: $key"
      print_usage
      exit 1
      ;;
    esac

    shift
  done

  use_sudo="true"

  assert_is_installed "supervisorctl"
  assert_is_installed "curl"

  config_dir=$(cd "$SCRIPT_DIR/../config" && pwd)

  data_dir=$(cd "$SCRIPT_DIR/../data" && pwd)

  bin_dir=$(cd "$SCRIPT_DIR/../bin" && pwd)

  log_dir=$(cd "$SCRIPT_DIR/../log" && pwd)

  user=$(get_owner_of_path "$config_dir")

  generate_nomad_config "$server" "$client" "$num_servers" "$config_dir" "$user" "$consul_token"
  generate_supervisor_config "$SUPERVISOR_CONFIG_PATH" "$config_dir" "$data_dir" "$bin_dir" "$log_dir" "$user" "$use_sudo"
  start_nomad
}

run "$@"
