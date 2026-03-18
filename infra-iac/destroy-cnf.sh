#!/bin/bash

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo "AWS CLI is not installed. Please install it first." >&2
    exit 1
fi

# Check if the file exists
if [ ! -f "/opt/config.properties" ]; then
    echo "File /opt/config.properties does not exist" >&2
    exit 1
fi

# Extract the AWS region from the config file
REGION=$(grep "^AWSREGION=" /opt/config.properties | cut -d= -f2)

if [ -z "$REGION" ]; then
    echo "Could not determine AWS region from config file. Using default." >&2
    REGION="us-west-2"  # Default region if not found in config
fi

# Extract the stack name from the config file
STACK_NAME=$(grep "^CFNSTACKNAME=" /opt/config.properties | cut -d= -f2)

if [ -z "$STACK_NAME" ]; then
    echo "Could not determine CloudFormation stack name from config file." >&2
    exit 1
fi

echo "Using stack name: $STACK_NAME"
echo "Using AWS region: $REGION"

# External resources (S3 buckets, RDS, Redis) are not managed by this stack - skipping cleanup

# Delete the CloudFormation stack
echo "Deleting CloudFormation stack: $STACK_NAME"
aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"

echo "CloudFormation stack deletion initiated for: $STACK_NAME"
echo "Note: Stack deletion may take some time to complete. You can check the status in the AWS CloudFormation console."
