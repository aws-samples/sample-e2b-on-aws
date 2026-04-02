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
    # Ensure all keys have CFN prefix for consistency
    if [[ "$key" != CFN* ]]; then
      key="CFN${key}"
    fi
    CFN_OUTPUTS["$key"]="$value"
    done < <(
    aws cloudformation describe-stacks \
        --stack-name "$STACK_ID" \
        --query "Stacks[0].Outputs[].[OutputKey,OutputValue]" \
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


  SUBNET1=$(grep "^CFNPRIVATESUBNET1=" /opt/config.properties | cut -d= -f2)
  SUBNET2=$(grep "^CFNPRIVATESUBNET2=" /opt/config.properties | cut -d= -f2)
  AZ1=$(aws ec2 describe-subnets --subnet-ids $SUBNET1 --query 'Subnets[*].[AvailabilityZone]' --output text)
  AZ2=$(aws ec2 describe-subnets --subnet-ids $SUBNET2 --query 'Subnets[*].[AvailabilityZone]' --output text)
  echo "CFNAZ1=$AZ1" >> /opt/config.properties
  echo "CFNAZ2=$AZ2" >> /opt/config.properties

  # Extract AZ3 from PrivateSubnet3
  PRIVATE_SUBNET3="${CFN_OUTPUTS[CFNPRIVATESUBNET3]:-}"
  if [ -n "$PRIVATE_SUBNET3" ]; then
    CFNAZ3=$(aws ec2 describe-subnets --subnet-ids "$PRIVATE_SUBNET3" --query 'Subnets[0].AvailabilityZone' --output text)
    echo "CFNAZ3=$CFNAZ3" >> /opt/config.properties
  fi

  # Extract AZ4 from PrivateSubnet4
  PRIVATE_SUBNET4="${CFN_OUTPUTS[CFNPRIVATESUBNET4]:-}"
  if [ -n "$PRIVATE_SUBNET4" ]; then
    CFNAZ4=$(aws ec2 describe-subnets --subnet-ids "$PRIVATE_SUBNET4" --query 'Subnets[0].AvailabilityZone' --output text)
    echo "CFNAZ4=$CFNAZ4" >> /opt/config.properties
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