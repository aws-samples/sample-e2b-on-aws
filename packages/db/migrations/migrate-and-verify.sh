#!/bin/bash
set -e

echo "=== 开始数据库迁移和验证流程 ==="

# 检查配置文件是否存在
CONFIG_FILE="/opt/config.properties"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "错误: 配置文件 $CONFIG_FILE 不存在"
  exit 1
fi

# Read all database connection information from Secrets Manager
DB_CREDENTIAL_SECRET=$(grep "^CFNDBCredentialSecretName=" "$CONFIG_FILE" | cut -d'=' -f2-)
DB_SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$DB_CREDENTIAL_SECRET" --query SecretString --output text)
DB_HOST=$(echo "$DB_SECRET_JSON" | jq -r '.host')
DB_USER=$(echo "$DB_SECRET_JSON" | jq -r '.username')
DB_NAME=$(echo "$DB_SECRET_JSON" | jq -r '.dbname')
DB_PASSWORD=$(echo "$DB_SECRET_JSON" | jq -r '.password')
AWSREGION=$(grep "^AWSREGION=" "$CONFIG_FILE" | cut -d'=' -f2-)

echo "数据库连接信息:"
echo "- 主机: $DB_HOST"
echo "- 数据库: $DB_NAME"
echo "- 用户: $DB_USER"
echo "- 密码: ********"
echo "- 区域: $AWSREGION"

# 执行迁移
echo -e "\n=== 执行SQL迁移 ==="
./run-all-migrations.sh

# 验证表
echo -e "\n=== 验证数据库表 ==="
./check-tables.sh

echo -e "\n=== 迁移和验证完成 ==="
echo "数据库已成功初始化，所有表都已创建"
echo "数据库连接信息:"
echo "- 主机: $DB_HOST"
echo "- 数据库: $DB_NAME"
echo "- 用户: $DB_USER"
