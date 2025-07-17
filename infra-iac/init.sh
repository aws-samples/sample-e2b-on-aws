#!/bin/bash
# ==================================================
# AWS Metadata Operations
# ==================================================
get_metadata_token() {
  curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"
}

get_instance_metadata() {
  local metadata_path=$1
  curl -H "X-aws-ec2-metadata-token: $TOKEN" -s "http://169.254.169.254/latest/meta-data/${metadata_path}"
}

# ==================================================
# Environment Configuration Section
# ==================================================
setup_environment() {
  # Get basic metadata
  export TOKEN=$(get_metadata_token)
  export REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)
  export INSTANCE_ID=$(get_instance_metadata "instance-id")
  echo 

  # Configure AWS region
  aws configure set region "$REGION"

  # Get CloudFormation stack ID
  export STACK_ID=$(aws ec2 describe-tags \
    --filters "Name=resource-id,Values=$INSTANCE_ID" \
    "Name=key,Values=aws:cloudformation:stack-id" \
    --query "Tags[0].Value" \
    --output text)

  # Validate stack existence
  [[ -z "$STACK_ID" ]] && { echo "Error: Failed to get CloudFormation Stack ID"; exit 1; }

  # Dynamic export of CFN outputs
  declare -A CFN_OUTPUTS
  while IFS=$'\t' read -r key value; do
    CFN_OUTPUTS["$key"]="$value"
    done < <(
    aws cloudformation describe-stacks \
        --stack-name "$STACK_ID" \
        --query "Stacks[0].Outputs[?ExportName != null && starts_with(ExportName || '', 'CFN')].[ExportName,OutputValue]" \
        --output text
    )

  # Create/clear the config file first
  echo "# Configuration generated on $(date)" > /opt/config.properties

  # Export variables and handle special cases
  for key in "${!CFN_OUTPUTS[@]}"; do
    export "$key"="${CFN_OUTPUTS[$key]}"

    # Also append to the config file
    echo "$key=${CFN_OUTPUTS[$key]}" >> /opt/config.properties
  done

  echo "AWSREGION=$REGION" >> /opt/config.properties

  export ARCHITECTURE=amd64
  ARCH=$(arch)
  if [ "$ARCH" = "aarch64" ]; then
    echo "CFNARCHITECTURE=arm64" >> /opt/config.properties
    export ARCHITECTURE=$ARCH
  fi

  # Verification output
  echo "=== Exported Variables ==="
  cat /opt/config.properties
}

# ==================================================
# Main Execution Flow
# ==================================================

main() {
  echo "setup_environment..."
  setup_environment
}

main "$@"