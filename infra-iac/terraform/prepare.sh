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

# Fail fast on placeholders the config file had no key for.
#
# Substitution above is per-key sed, so an absent key leaves the literal
# ${CFNSOMETHING} in the output. Terraform then reads that as one of its own
# interpolations and dies on an undefined reference somewhere inside init or
# plan - far from the actual cause. Catching it here names the missing keys.
#
# This is the failure mode you get when a 3-AZ template variable meets a 2-AZ
# stack: var.tf.tpl asks for CFNPRIVATESUBNET3, and only the 3-AZ template
# exports it.
LEFTOVER=$(grep -oh '\${CFN[A-Za-z0-9_]*}' "$PROVIDER_OUTPUT" "$TFVARS_OUTPUT" 2>/dev/null | sort -u)
if [ -n "$LEFTOVER" ]; then
    echo "Error: these placeholders had no matching key in $CONFIG_FILE:" >&2
    echo "$LEFTOVER" | sed 's/^/       /' >&2
    echo "       Check the stack's Outputs, then re-run infra-iac/init.sh." >&2
    exit 1
fi

# Initialize Terraform
echo "Initializing Terraform..."
terraform init

echo "Terraform initialization complete!"