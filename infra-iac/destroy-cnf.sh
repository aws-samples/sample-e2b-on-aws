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

# List of bucket variables to process
BUCKET_VARS_CNF=(
    "CFNTERRAFORMBUCKET"
    "CFNSOFTWAREBUCKET"
)

echo "Starting to empty CNF S3 buckets..."

# Process each bucket
for BUCKET_VAR in "${BUCKET_VARS_CNF[@]}"; do
    # Extract the bucket name from the config file
    BUCKET_NAME=$(grep "^$BUCKET_VAR=" /opt/config.properties | cut -d= -f2)

    if [ -n "$BUCKET_NAME" ]; then
        echo "Emptying bucket: $BUCKET_NAME"

        # Check if the bucket exists
        if aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$REGION" >/dev/null 2>&1; then
            # Empty the bucket
            aws s3 rm "s3://$BUCKET_NAME" --recursive --region "$REGION" >/dev/null 2>&1
            echo "Successfully emptied bucket: $BUCKET_NAME"
        else
            echo "Bucket $BUCKET_NAME does not exist or you don't have access to it. Skipping."
        fi
    else
        echo "Could not find bucket name for variable $BUCKET_VAR. Skipping."
    fi
done

echo "Starting to delete CNF S3 buckets..."

# Delete each bucket after emptying
for BUCKET_VAR in "${BUCKET_VARS_CNF[@]}"; do
    # Extract the bucket name from the config file
    BUCKET_NAME=$(grep "^$BUCKET_VAR=" /opt/config.properties | cut -d= -f2)

    if [ -n "$BUCKET_NAME" ]; then
        echo "Deleting bucket: $BUCKET_NAME"

        # Check if the bucket exists
        if aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$REGION" >/dev/null 2>&1; then
            # Delete the bucket
            aws s3api delete-bucket --bucket "$BUCKET_NAME" --region "$REGION" >/dev/null 2>&1
            if [ $? -eq 0 ]; then
                echo "Successfully deleted bucket: $BUCKET_NAME"
            else
                echo "Failed to delete bucket: $BUCKET_NAME. It may still contain objects or have other dependencies."
            fi
        else
            echo "Bucket $BUCKET_NAME does not exist or you don't have access to it. Skipping deletion."
        fi
    else
        echo "Could not find bucket name for variable $BUCKET_VAR. Skipping deletion."
    fi
done

TERRAFORM_BUCKET=$(grep "^CFNTERRAFORMBUCKET=" /opt/config.properties | cut -d= -f2)

# Check if bucket exists
if aws s3api head-bucket --bucket "$TERRAFORM_BUCKET" 2>/dev/null; then
    # Check if versioning is enabled
    VERSIONING_STATUS=$(aws s3api get-bucket-versioning --bucket "$TERRAFORM_BUCKET" --query "Status" --output text 2>/dev/null)

    if [ "$VERSIONING_STATUS" = "Enabled" ] || [ "$VERSIONING_STATUS" = "Suspended" ]; then
        echo "Bucket has versioning. Removing all versions and delete markers..."

        # Delete all versions (including delete markers)
        VERSIONS=$(aws s3api list-object-versions --bucket "$TERRAFORM_BUCKET" --output json)

        # Delete non-current versions
        echo "$VERSIONS" | jq -r '.Versions[]? | "\(.Key) \(.VersionId)"' 2>/dev/null | while read KEY VERSION_ID; do
            if [ ! -z "$KEY" ] && [ ! -z "$VERSION_ID" ]; then
                echo "Deleting object: $KEY (version $VERSION_ID)"
                aws s3api delete-object --bucket "$TERRAFORM_BUCKET" --key "$KEY" --version-id "$VERSION_ID" > /dev/null 2>&1
            fi
        done

        # Delete delete markers
        echo "$VERSIONS" | jq -r '.DeleteMarkers[]? | "\(.Key) \(.VersionId)"' 2>/dev/null | while read KEY VERSION_ID; do
            if [ ! -z "$KEY" ] && [ ! -z "$VERSION_ID" ]; then
                echo "Removing delete marker: $KEY (version $VERSION_ID)"
                aws s3api delete-object --bucket "$TERRAFORM_BUCKET" --key "$KEY" --version-id "$VERSION_ID" > /dev/null 2>&1
            fi
        done
    fi

    # Delete all objects (current versions or non-versioned)
    echo "Removing all current objects..."
    aws s3 rm "s3://$TERRAFORM_BUCKET" --recursive > /dev/null 2>&1

    # Disable bucket policy if exists
    echo "Removing bucket policy..."
    aws s3api delete-bucket-policy --bucket "$TERRAFORM_BUCKET" > /dev/null 2>&1

    # Disable bucket encryption if exists
    echo "Removing bucket encryption..."
    aws s3api delete-bucket-encryption --bucket "$TERRAFORM_BUCKET" > /dev/null 2>&1

    # Remove public access block
    echo "Removing public access block..."
    aws s3api delete-public-access-block --bucket "$TERRAFORM_BUCKET" > /dev/null 2>&1
fi

echo "Completed emptying CNF S3 buckets and modifying ELB deletion protection."

# Disable deletion protection for RDS instances matching the stack name
echo "Looking for RDS instances associated with stack name: $STACK_NAME"

# Get all RDS instances
RDS_INSTANCES=$(aws rds describe-db-instances --region "$REGION" --query "DBInstances[].DBInstanceIdentifier" --output text 2>/dev/null)

if [ -n "$RDS_INSTANCES" ]; then
    for DB_INSTANCE in $RDS_INSTANCES; do
        # Check if the DB instance name contains the stack name
        if [[ "$DB_INSTANCE" == *"$STACK_NAME"* ]]; then
            echo "Found RDS instance: $DB_INSTANCE"

            # Always attempt to disable deletion protection without interactive output
            echo "Disabling deletion protection for RDS instance: $DB_INSTANCE"
            aws rds modify-db-instance \
                --region "$REGION" \
                --db-instance-identifier "$DB_INSTANCE" \
                --no-deletion-protection \
                --apply-immediately \
                --output json > /dev/null 2>&1

            echo "Deletion protection disabled for RDS instance: $DB_INSTANCE"
        fi
    done
else
    echo "No RDS instances found in region: $REGION"
fi

# Disable deletion protection for RDS clusters matching the stack name
echo "Looking for RDS clusters associated with stack name: $STACK_NAME"

# Get all RDS clusters
RDS_CLUSTERS=$(aws rds describe-db-clusters --region "$REGION" --query "DBClusters[].DBClusterIdentifier" --output text 2>/dev/null)

if [ -n "$RDS_CLUSTERS" ]; then
    for DB_CLUSTER in $RDS_CLUSTERS; do
        # Check if the DB cluster name contains the stack name
        if [[ "$DB_CLUSTER" == *"$STACK_NAME"* ]]; then
            echo "Found RDS cluster: $DB_CLUSTER"

            # Always attempt to disable deletion protection without interactive output
            echo "Disabling deletion protection for RDS cluster: $DB_CLUSTER"
            aws rds modify-db-cluster \
                --region "$REGION" \
                --db-cluster-identifier "$DB_CLUSTER" \
                --no-deletion-protection \
                --apply-immediately \
                --output json > /dev/null 2>&1

            echo "Deletion protection disabled for RDS cluster: $DB_CLUSTER"
        fi
    done
else
    echo "No RDS clusters found in region: $REGION"
fi

# Delete the CloudFormation stack
echo "Deleting CloudFormation stack: $STACK_NAME"
aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"

echo "CloudFormation stack deletion initiated for: $STACK_NAME"
echo "Note: Stack deletion may take some time to complete. You can check the status in the AWS CloudFormation console."
