#!/bin/bash

# Navigate to the directory containing the script
cd "$(dirname "$0")"

# terraform-output-to-config.sh - Convert Terraform outputs to configuration and append to file

# Default values
CONFIG_FILE="/opt/config.properties"
ENVIRONMENT=$(grep "^CFNENVIRONMENT=" "$CONFIG_FILE" | cut -d'=' -f2)

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config-file)
            CONFIG_FILE=$2
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  -c, --config-file FILE  Specify the config file to append to (default: /opt/config.properties)"
            echo "  -e, --env ENV           Specify the environment to deploy (default: dev)"
            echo "  -h, --help              Show this help message"
            exit 0
            ;;
        *)
            echo "Error: Unknown parameter $1"
            exit 1
            ;;
    esac
done

# Check if config file exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: Config file $CONFIG_FILE does not exist"
    exit 1
fi

# Execute prepare3.sh script
echo "Executing prepare.sh script..."
chmod u+x prepare.sh
./prepare.sh
if [ $? -ne 0 ]; then
    echo "prepare.sh execution failed!"
    exit 1
else
    echo "prepare.sh executed successfully"
fi

# Execute terraform plan and apply with environment variable
echo "Creating Terraform plan for environment: $ENVIRONMENT..."
terraform plan -var="environment=$ENVIRONMENT" -out=tfplan

echo "Applying Terraform plan for environment: $ENVIRONMENT..."
terraform apply tfplan

# Check if apply was successful
if [ $? -ne 0 ]; then
    echo "Terraform apply failed!"
    exit 1
else
    echo "Terraform deployment completed successfully!"
fi

# Clean up existing Terraform outputs
echo "Cleaning up existing Terraform outputs in $CONFIG_FILE..."
# Remove any lines that start with "# Terraform outputs added on" and all lines after it
sed -i '/^# Terraform outputs added on/,$d' "$CONFIG_FILE"

# Add separator comment to config file
echo "" >> "$CONFIG_FILE"
echo "# Terraform outputs added on $(date)" >> "$CONFIG_FILE"

#!/bin/bash

# 确保 CONFIG_FILE 变量已定义
if [ -z "$CONFIG_FILE" ]; then
    CONFIG_FILE="./config.env"
    echo "CONFIG_FILE not set, using default: $CONFIG_FILE"
fi

# 处理所有 bucket 输出
echo "Processing bucket outputs..."

# 获取所有以 _bucket_name 结尾的输出
bucket_outputs=$(terraform output | grep "_bucket_name" | cut -d "=" -f1 | tr -d " ")

for output_name in $bucket_outputs; do
    # 获取 bucket 名称值
    bucket_value=$(terraform output -raw $output_name)
    
    # 转换输出名称为所需格式 (去掉 _bucket_name 后缀，转换为大写，替换 _ 为 _)
    formatted_name=$(echo $output_name | sed 's/_bucket_name$//' | tr '[:lower:]' '[:upper:]' | tr '-' '_')
    
    # 写入配置文件
    echo "BUCKET_${formatted_name}=${bucket_value}" >> "$CONFIG_FILE"
    echo "Added bucket: BUCKET_${formatted_name}=${bucket_value}"
done

# 处理所有 secret 输出
echo "Processing secret outputs..."

# 获取所有以 _secret_name 或 _token_name 或 _key_name 结尾的输出
secret_outputs=$(terraform output | grep -E "_(secret|token|key)_name" | cut -d "=" -f1 | tr -d " ")

for output_name in $secret_outputs; do
    # 获取 secret 名称
    secret_name=$(terraform output -raw $output_name)
    
    echo "Fetching value for AWS secret: $secret_name"
    
    # 访问 secret 值
    secret_response=$(aws secretsmanager get-secret-value --secret-id "$secret_name" 2>/dev/null)
    
    # 检查 secret 获取是否成功
    if [ $? -eq 0 ] && [ -n "$secret_response" ]; then
        # 从 JSON 响应中提取 secret 值
        secret_value=$(echo "$secret_response" | jq -r '.SecretString')
        
        # 将 secret 名称转换为所需格式
        formatted_name=$(echo "$secret_name" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
        
        # 添加 secret 值到配置文件
        echo "SECRET_${formatted_name}=${secret_value}" >> "$CONFIG_FILE"
        echo "Added secret: SECRET_${formatted_name}"
    else
        echo "Warning: Failed to retrieve value for AWS secret: $secret_name"
        # 添加 secret 名称但带有表示检索失败的注释
        echo "# SECRET_${formatted_name}=<retrieval_failed> (Secret name: $secret_name)" >> "$CONFIG_FILE"
    fi
done

echo "Configuration file $CONFIG_FILE has been updated."



# Add additional parameters
echo "" >> "$CONFIG_FILE"
echo "# Additional parameters" >> "$CONFIG_FILE"
echo "account_id=$(aws sts get-caller-identity --query Account --output text)" >> "$CONFIG_FILE"
echo "build_id=latest" >> "$CONFIG_FILE"
echo "environment=$ENVIRONMENT" >> "$CONFIG_FILE"

# Extract AWSREGION value from the config file
AWSREGION=$(grep "^AWSREGION=" "$CONFIG_FILE" | cut -d'=' -f2)
# Extract CFNAZ1 value from the config file
CFNAZ1=$(grep "^CFNAZ1=" "$CONFIG_FILE" | cut -d'=' -f2)
if [ -n "$CFNAZ1" ]; then
    echo "aws_az1=${CFNAZ1}" >> "$CONFIG_FILE"
else
    echo "Warning: CFNAZ1 not found in config file, cannot set aws_az1"
fi

# Extract CFNAZ2 value from the config file
CFNAZ2=$(grep "^CFNAZ2=" "$CONFIG_FILE" | cut -d'=' -f2)
if [ -n "$CFNAZ2" ]; then
    echo "aws_az2=${CFNAZ2}" >> "$CONFIG_FILE"
else
    echo "Warning: CFNAZ2 not found in config file, cannot set aws_az2"
fi

# Extract CFNAZ3 value from the config file. Nomad job datacenters are built
# from aws_az*, so a missing aws_az3 silently keeps AZ3 nodes unschedulable.
CFNAZ3=$(grep "^CFNAZ3=" "$CONFIG_FILE" | cut -d'=' -f2)
if [ -n "$CFNAZ3" ]; then
    echo "aws_az3=${CFNAZ3}" >> "$CONFIG_FILE"
else
    echo "Warning: CFNAZ3 not found in config file, cannot set aws_az3"
fi
# Database credentials are stored in Secrets Manager (CFNDBCredentialSecretName in config file)
# No DB parameters (host, port, user, password) written to config file

# Set Nomad ACL token from the secret
NOMAD_TOKEN=$(grep -i "NOMAD_SECRET_ID=" "$CONFIG_FILE" | cut -d'=' -f2)
if [ -n "$NOMAD_TOKEN" ]; then
    echo "nomad_acl_token=${NOMAD_TOKEN}" >> "$CONFIG_FILE"
else
    echo "Warning: Nomad ACL token not found in config file"
fi

# Set Consul HTTP token from the secret
CONSUL_TOKEN=$(grep -i "CONSUL_SECRET_ID=" "$CONFIG_FILE" | cut -d'=' -f2)
if [ -n "$CONSUL_TOKEN" ]; then
    echo "consul_http_token=${CONSUL_TOKEN}" >> "$CONFIG_FILE"
else
    echo "Warning: Consul ACL token not found in config file"
fi

# admin_token and sandbox_access_token_hash_seed come from Secrets Manager, via
# the SECRET_* keys written above. They used to be one openssl call here, which
# had two consequences: the value changed on every apply, so the running api and
# this file disagreed and the admin routes answered 401 until a redeploy; and the
# same value seeded the hash that validates sandbox traffic tokens, so anything
# given the admin credential was also given that seed.

# The SECRET_* keys written above are prefixed with the stack name, so the Nomad
# job templates cannot reference them directly. Normalise the ones the jobs need
# into stable lower-case keys, the same way nomad_acl_token is derived above.

# api: ADMIN_TOKEN
ADMIN_TOKEN=$(grep -i "_ADMIN_TOKEN=" "$CONFIG_FILE" | head -1 | cut -d'=' -f2-)
if [ -n "$ADMIN_TOKEN" ]; then
    echo "admin_token=${ADMIN_TOKEN}" >> "$CONFIG_FILE"
else
    echo "Warning: admin token not found in config file"
fi

# api: SANDBOX_ACCESS_TOKEN_HASH_SEED. Rotating this invalidates every live
# sandbox's traffic access token, which is why it is its own secret rather than
# a second use of the admin token.
SANDBOX_SEED=$(grep -i "_SANDBOX_ACCESS_TOKEN_HASH_SEED=" "$CONFIG_FILE" | head -1 | cut -d'=' -f2-)
if [ -n "$SANDBOX_SEED" ]; then
    echo "sandbox_access_token_hash_seed=${SANDBOX_SEED}" >> "$CONFIG_FILE"
else
    echo "Warning: sandbox access token hash seed not found in config file"
fi

# template-manager: API_SECRET
API_SECRET=$(grep -i "_API_SECRET=" "$CONFIG_FILE" | head -1 | cut -d'=' -f2-)
if [ -n "$API_SECRET" ]; then
    echo "api_secret=${API_SECRET}" >> "$CONFIG_FILE"
else
    echo "Warning: API secret not found in config file"
fi

# All services: LAUNCH_DARKLY_API_KEY. Blank is valid and means "use the
# offline flag store", so an empty value is not an error.
LAUNCH_DARKLY_API_KEY=$(grep -i "_LAUNCH_DARKLY_API_KEY=" "$CONFIG_FILE" | head -1 | cut -d'=' -f2-)
echo "launch_darkly_api_key=${LAUNCH_DARKLY_API_KEY}" >> "$CONFIG_FILE"

# api: VOLUME_TOKEN_SIGNING_KEY. Emitted as a plain (sensitive) Terraform
# output rather than a Secrets Manager entry, so read it directly.
VOLUME_TOKEN_KEY=$(terraform output -raw volume_token_key 2>/dev/null)
if [ -n "$VOLUME_TOKEN_KEY" ]; then
    echo "volume_token_key=${VOLUME_TOKEN_KEY}" >> "$CONFIG_FILE"
else
    echo "Warning: Failed to read volume_token_key from Terraform outputs"
fi

# ECR authentication is handled on the nodes by amazon-ecr-credential-helper
# using their instance profile, so no ECR token is materialised here. The
# bastion's own docker login happens in tools/build-and-upload.sh, right before
# the images are pushed.

# Extract CFNREDISNAME value from the config file
CFNREDISNAME=$(grep "^CFNREDISNAME=" "$CONFIG_FILE" | cut -d'=' -f2)


REDIS_ENDPOINT=$(aws elasticache describe-serverless-caches \
  --serverless-cache-name "$CFNREDISNAME" \
  --query 'ServerlessCaches[0].Endpoint.Address' \
  --output text)

if [ -n "$REDIS_ENDPOINT" ]; then
    echo "REDIS_ENDPOINT=${REDIS_ENDPOINT}" >> "$CONFIG_FILE"
else
    echo "Warning: Failed to get REDIS_ENDPOINT"
fi

echo "Configuration successfully appended to $CONFIG_FILE"


# Show the last few lines of the config file
echo "Latest content in config file:"
tail -n 15 "$CONFIG_FILE"
