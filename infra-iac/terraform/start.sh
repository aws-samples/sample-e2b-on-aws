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
# Parse CFNDBURL to extract postgres host, port, username and password
DB_URL=$(grep "^CFNDBURL=" "$CONFIG_FILE" | cut -d'=' -f2)
if [ -n "$DB_URL" ]; then
    # Extract host and port from URL (format: postgresql://user:pass@host:port/dbname)
    HOST_PORT=$(echo "$DB_URL" | sed -E 's|.*@([^/]+)/.*|\1|')
    DB_HOST=$(echo "$HOST_PORT" | cut -d':' -f1)
    DB_PORT=$(echo "$HOST_PORT" | cut -d':' -f2 2>/dev/null || echo "5432")
    DB_NAME=$(echo "$DB_URL" | sed -E 's|.*/([^?]+).*|\1|' || echo "postgres")
    
    # Extract username and password
    USER_PASS=$(echo "$DB_URL" | sed -E 's|.*://([^@]+)@.*|\1|')
    DB_USER=$(echo "$USER_PASS" | cut -d':' -f1)
    DB_PASS=$(echo "$USER_PASS" | cut -d':' -f2)
    
    echo "postgres_host=${DB_HOST}" >> "$CONFIG_FILE"
    echo "DB_PORT=5432" >> "$CONFIG_FILE"
    echo "DB_NAME=${DB_NAME}" >> "$CONFIG_FILE"
    echo "postgres_user=${DB_USER}" >> "$CONFIG_FILE"
    echo "postgres_password=${DB_PASS}" >> "$CONFIG_FILE"
else
    echo "Warning: CFNDBURL not found in config file, cannot set postgres parameters"
fi

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

# Generate random admin token
ADMIN_TOKEN=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9!@#$%^&*()_+{}|:<>?=-' | head -c 30)
echo "admin_token=${ADMIN_TOKEN}" >> "$CONFIG_FILE"

# Get ECR token
ECR_TOKEN=$(aws ecr get-login-password --region "$AWSREGION" 2>/dev/null)
if [ -n "$ECR_TOKEN" ]; then
    echo "ecr_token=${ECR_TOKEN}" >> "$CONFIG_FILE"
else
    echo "Warning: Failed to get ECR token"
fi

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
