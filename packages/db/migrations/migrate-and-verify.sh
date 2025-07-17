#!/bin/bash
set -e

echo "=== 开始数据库迁移和验证流程 ==="

# 检查配置文件是否存在
CONFIG_FILE="/opt/config.properties"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "错误: 配置文件 $CONFIG_FILE 不存在"
  exit 1
fi

# 只提取CFNDBURL变量，避免执行其他可能的命令
CFNDBURL=$(grep "^CFNDBURL=" "$CONFIG_FILE" | cut -d'=' -f2-)
AWSREGION=$(grep "^AWSREGION=" "$CONFIG_FILE" | cut -d'=' -f2-)

if [ -z "$CFNDBURL" ]; then
  echo "错误: 配置文件中没有找到 CFNDBURL"
  exit 1
fi

# 从连接字符串中提取用户名、密码、主机和数据库名
DB_USER=$(echo $CFNDBURL | sed -n 's/^postgresql:\/\/\([^:]*\):.*/\1/p')
DB_PASSWORD=$(echo $CFNDBURL | sed -n 's/^postgresql:\/\/[^:]*:\([^@]*\)@.*/\1/p')
DB_HOST=$(echo $CFNDBURL | sed -n 's/^postgresql:\/\/[^@]*@\([^\/]*\)\/.*/\1/p')
DB_NAME=$(echo $CFNDBURL | sed -n 's/^postgresql:\/\/[^\/]*\/\(.*\)$/\1/p')

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
