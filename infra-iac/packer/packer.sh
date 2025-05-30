#!/bin/bash

# Navigate to the directory containing the script
cd "$(dirname "$0")"

# Source the config file if it exists
CONFIG_FILE="/opt/config.properties"
if [ -f "$CONFIG_FILE" ]; then
    # Parse the config file and extract AWSREGION
    AWSREGION=$(grep "^AWSREGION=" "$CONFIG_FILE" | cut -d'=' -f2)
fi

# Get Region from params or env or config file
AWS_REGION="${1:-${AWSREGION}}"

# Check Region
if [ -z "${AWS_REGION}" ]; then
    echo "Error: AWS region not specified. Please provide the region via command line argument, set the AWSREGION environment variable, or define it in $CONFIG_FILE."
    exit 1
fi

echo "Using AWS Region: ${AWS_REGION}"

# Check if Packer is installed
if ! command -v packer &> /dev/null; then
    echo "Packer not found. Installing Packer 1.12.0..."
    wget https://releases.hashicorp.com/packer/1.12.0/packer_1.12.0_linux_amd64.zip
    unzip packer_1.12.0_linux_amd64.zip
    mv packer /usr/local/bin/packer
    rm packer_1.12.0_linux_amd64.zip
    echo "Packer installed successfully."
fi


packer init -upgrade .

sleep 10

packer build -only=amazon-ebs.orch -var "aws_region=${AWS_REGION}" .