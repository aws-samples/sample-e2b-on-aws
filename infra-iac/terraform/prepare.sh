#!/bin/bash

# Define paths
CONFIG_FILE="/opt/config.properties"
PROVIDER_TEMPLATE="provider.tf.tpl"
PROVIDER_OUTPUT="provider.tf"
TFVARS_TEMPLATE="var.tf.tpl"
TFVARS_OUTPUT="var.tf"

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file $CONFIG_FILE not found!"
    exit 1
fi

# Check if template files exist
if [ ! -f "$PROVIDER_TEMPLATE" ]; then
    echo "Error: Template file $PROVIDER_TEMPLATE not found!"
    exit 1
fi

if [ ! -f "$TFVARS_TEMPLATE" ]; then
    echo "Error: Template file $TFVARS_TEMPLATE not found!"
    exit 1
fi

# Load variables from config file
echo "Loading configuration from $CONFIG_FILE"
source "$CONFIG_FILE"

# Process provider.tf template
echo "Generating $PROVIDER_OUTPUT from $PROVIDER_TEMPLATE"
cp "$PROVIDER_TEMPLATE" "$PROVIDER_OUTPUT"

# Process terraform.tfvars template
echo "Generating $TFVARS_OUTPUT from $TFVARS_TEMPLATE"
cp "$TFVARS_TEMPLATE" "$TFVARS_OUTPUT"

# Replace variables in both files
echo "Replacing variables in output files..."
while IFS='=' read -r key value || [[ -n "$key" ]]; do
    # Skip comments and empty lines
    if [[ $key == \#* ]] || [[ -z "$key" ]]; then
        continue
    fi

    # Remove any leading/trailing whitespace
    key=$(echo "$key" | xargs)
    value=$(echo "$value" | xargs)

    echo "Replacing \${$key} with $value"

    # Replace the variable in both output files
    sed -i "s|\${$key}|$value|g" "$PROVIDER_OUTPUT" 2>/dev/null
    sed -i "s|\${$key}|$value|g" "$TFVARS_OUTPUT" 2>/dev/null
done < "$CONFIG_FILE"

echo "Files generated successfully!"

# Initialize Terraform
echo "Initializing Terraform..."
terraform init

echo "Terraform initialization complete!"