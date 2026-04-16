#!/bin/bash

# Set the output environment variable file path
ENV_FILE="/tmp/nomad_env.sh"

# Clear or create the environment variable file with restricted permissions
> $ENV_FILE
chmod 600 $ENV_FILE

# Read the configuration file and extract CFNSTACKNAME
if [ -f /opt/config.properties ]; then
    # Use grep to extract variables instead of directly sourcing the config file
    # This avoids potential command execution issues that might exist in the config file
    CFNSTACKNAME=$(grep -E "^CFNSTACKNAME=" /opt/config.properties | cut -d'=' -f2)
    AWSREGION=$(grep -E "^AWSREGION=" /opt/config.properties | cut -d'=' -f2)
    nomad_acl_token=$(grep -E "^nomad_acl_token=" /opt/config.properties | cut -d'=' -f2)
    consul_http_token=$(grep -E "^consul_http_token=" /opt/config.properties | cut -d'=' -f2)

    # Confirm that CFNSTACKNAME has been set
    if [ -z "$CFNSTACKNAME" ]; then
        echo "Error: CFNSTACKNAME not found in config file"
        echo "export NOMAD_SETUP_ERROR=\"CFNSTACKNAME not found\"" >> $ENV_FILE
        exit 1
    fi

    # Build the instance name
    INSTANCE_NAME="${CFNSTACKNAME}-server"

    echo "Looking for EC2 instances with Name tag: $INSTANCE_NAME"

    # Use AWS CLI to query private IPs of instances with the specified name tag, get all matching IPs
    ALL_IPS=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=running" \
        --query "Reservations[*].Instances[*].PrivateIpAddress" \
        --output text \
        --region $AWSREGION)

    # Check if the command executed successfully
    if [ $? -ne 0 ]; then
        echo "Error: Failed to query AWS EC2 instances"
        echo "export NOMAD_SETUP_ERROR=\"AWS EC2 query failed\"" >> $ENV_FILE
        exit 1
    fi

    # Convert all IPs to an array
    # With these lines:
    IP_ARRAY=()
    for ip in $ALL_IPS; do
        if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            IP_ARRAY+=("$ip")
        fi
    done

    # Check if there are at least two IPs
    if [ ${#IP_ARRAY[@]} -lt 2 ]; then
        echo "Error: Found fewer than 2 instances with Name tag: $INSTANCE_NAME"
        echo "Available IPs: ${ALL_IPS}"
        echo "export NOMAD_SETUP_ERROR=\"Insufficient instances found (${#IP_ARRAY[@]})\"" >> $ENV_FILE
        exit 1
    else
        # Select the second IP (index 1)
        NOMAD_IP=${IP_ARRAY[1]}

        echo "Found ${#IP_ARRAY[@]} instances with Name tag: $INSTANCE_NAME"
        echo "All IPs: ${ALL_IPS}"
        echo "Selected second IP: $NOMAD_IP"

        # Write NOMAD_ADDR to the environment variable file
        echo "export NOMAD_ADDR=\"https://${NOMAD_IP}:4646\"" >> $ENV_FILE
        echo "NOMAD_ADDR set to: https://${NOMAD_IP}:4646"

        # Check and set NOMAD_TOKEN
        if [ -n "$nomad_acl_token" ]; then
            echo "export NOMAD_TOKEN=\"${nomad_acl_token}\"" >> $ENV_FILE
            echo "NOMAD_TOKEN from config file has been set"
        else
            echo "Warning: nomad_acl_token not found in config file"
            echo "# Warning: nomad_acl_token not found in config file" >> $ENV_FILE
        fi

        # Check and set CONSUL_HTTP_TOKEN
        if [ -n "$consul_http_token" ]; then
            echo "export CONSUL_HTTP_TOKEN=\"${consul_http_token}\"" >> $ENV_FILE
            echo "CONSUL_HTTP_TOKEN from config file has been set"
        else
            echo "# Warning: consul_http_token not found in config file" >> $ENV_FILE
        fi

        # Download Nomad TLS certificates from Secrets Manager
        mkdir -p /opt/nomad/tls
        aws secretsmanager get-secret-value --secret-id "${CFNSTACKNAME}-nomad-tls-ca-cert" --region "$AWSREGION" --query SecretString --output text > /opt/nomad/tls/ca.pem 2>/dev/null
        aws secretsmanager get-secret-value --secret-id "${CFNSTACKNAME}-nomad-tls-client-cert" --region "$AWSREGION" --query SecretString --output text > /opt/nomad/tls/cert.pem 2>/dev/null
        aws secretsmanager get-secret-value --secret-id "${CFNSTACKNAME}-nomad-tls-client-key" --region "$AWSREGION" --query SecretString --output text > /opt/nomad/tls/key.pem 2>/dev/null
        chmod 600 /opt/nomad/tls/*.pem

        # Set Nomad TLS environment variables
        echo "export NOMAD_CACERT=\"/opt/nomad/tls/ca.pem\"" >> $ENV_FILE
        echo "export NOMAD_CLIENT_CERT=\"/opt/nomad/tls/cert.pem\"" >> $ENV_FILE
        echo "export NOMAD_CLIENT_KEY=\"/opt/nomad/tls/key.pem\"" >> $ENV_FILE

        # Add a flag indicating successful setup
        echo "export NOMAD_SETUP_SUCCESS=true" >> $ENV_FILE

        # Add timestamp
        echo "export NOMAD_SETUP_TIMESTAMP=\"$(date)\"" >> $ENV_FILE

        echo ""
        echo "Environment variables have been written to $ENV_FILE"
        echo "To load these variables into your shell, run:"
        echo "source $ENV_FILE"
        echo "# Or you can use this alias for future use:"
        echo "alias load_nomad='source $ENV_FILE'"
    fi
else
    echo "Error: Configuration file /opt/config.properties not found"
    echo "export NOMAD_SETUP_ERROR=\"Configuration file not found\"" >> $ENV_FILE
    exit 1
fi

# If the script is executed via source, automatically load the environment variables
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    source $ENV_FILE
    echo ""
    echo "Environment variables have been automatically loaded into current shell:"
    echo "NOMAD_ADDR = ${NOMAD_ADDR}"
    if [ -n "$NOMAD_TOKEN" ]; then
        echo "NOMAD_TOKEN is set"
    else
        echo "NOMAD_TOKEN is not set"
    fi
    if [ -n "$CONSUL_HTTP_TOKEN" ]; then
        echo "CONSUL_HTTP_TOKEN is set"
    else
        echo "CONSUL_HTTP_TOKEN is not set"
    fi
fi
