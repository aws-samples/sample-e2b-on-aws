#!/bin/bash
set -e

echo "=== 从配置文件加载数据库连接信息 ==="
# 加载配置文件，但只提取我们需要的变量
CONFIG_FILE="/opt/config.properties"
if [ -f "$CONFIG_FILE" ]; then
  echo "找到配置文件: $CONFIG_FILE"
  # 只提取CFNDBURL变量，避免执行其他可能的命令
  CFNDBURL=$(grep "^CFNDBURL=" "$CONFIG_FILE" | cut -d'=' -f2-)
  
  if [ -z "$CFNDBURL" ]; then
    echo "错误: 配置文件中没有找到 CFNDBURL"
    exit 1
  fi
  
  echo "成功提取数据库连接信息"
else
  echo "错误: 配置文件 $CONFIG_FILE 不存在"
  exit 1
fi

# 从连接字符串中提取用户名、密码、主机和数据库名
DB_USER=$(echo $CFNDBURL | sed -n 's/^postgresql:\/\/\([^:]*\):.*/\1/p')
DB_PASSWORD=$(echo $CFNDBURL | sed -n 's/^postgresql:\/\/[^:]*:\([^@]*\)@.*/\1/p')
DB_HOST=$(echo $CFNDBURL | sed -n 's/^postgresql:\/\/[^@]*@\([^\/]*\)\/.*/\1/p')
DB_NAME=$(echo $CFNDBURL | sed -n 's/^postgresql:\/\/[^\/]*\/\(.*\)$/\1/p')

echo "检查数据库中的表..."

# 提取所有SQL文件中的CREATE TABLE语句，获取表名
echo "分析SQL文件中的表定义..."
expected_tables=$(grep -h -i "CREATE TABLE" *.sql | grep -v "IF NOT EXISTS" | sed -E 's/.*CREATE TABLE[[:space:]]+([^[:space:]()]+).*/\1/i' | sort | uniq)

# 如果没有找到表，可能是因为表名格式不同，尝试另一种方式
if [ -z "$expected_tables" ]; then
  expected_tables=$(grep -h -i "CREATE TABLE" *.sql | grep -v "IF NOT EXISTS" | sed -E 's/.*CREATE TABLE[[:space:]]+"?([^"[:space:]()]+)"?.*/\1/i' | sort | uniq)
fi

echo "预期的表:"
echo "$expected_tables"

# 从数据库中获取实际表
echo -e "\n从数据库获取实际表..."
actual_tables=$(PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -c "
SELECT table_name 
FROM information_schema.tables 
WHERE table_schema NOT IN ('pg_catalog', 'information_schema') 
AND table_type = 'BASE TABLE'
ORDER BY table_name;")

echo "数据库中的表:"
echo "$actual_tables"

# 检查是否所有预期的表都存在
echo -e "\n验证表是否存在..."
missing_tables=0

for table in $expected_tables; do
  # 移除引号和模式前缀
  clean_table=$(echo $table | sed 's/"//g' | sed 's/.*\.//')
  if ! echo "$actual_tables" | grep -q "$clean_table"; then
    echo "❌ 表 '$clean_table' 不存在!"
    missing_tables=$((missing_tables+1))
  else
    echo "✅ 表 '$clean_table' 存在"
  fi
done

if [ $missing_tables -eq 0 ]; then
  echo -e "\n✅ 所有表都已成功创建!"
else
  echo -e "\n❌ 有 $missing_tables 个表未创建成功，请检查SQL文件"
  exit 1
fi
