#!/bin/bash
# ==================================================
# Environment Configuration Section
# ==================================================
setup_environment() {
  # Get CloudFormation stack ID
  STACK_ID=$(grep "^StackName=" /tmp/e2b.log | cut -d'=' -f2)
  
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

  REGION=$(aws configure get region)
  echo "AWSREGION=$REGION" >> /opt/config.properties

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