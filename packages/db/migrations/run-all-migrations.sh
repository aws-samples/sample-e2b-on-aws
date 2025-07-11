#!/bin/bash
set -e

echo "=== 从配置文件加载数据库连接信息 ==="
# 加载配置文件，但只提取我们需要的变量
CONFIG_FILE="/opt/config.properties"
if [ -f "$CONFIG_FILE" ]; then
  echo "找到配置文件: $CONFIG_FILE"
  # 只提取CFNDBURL变量，避免执行其他可能的命令
  CFNDBURL=$(grep "^CFNDBURL=" "$CONFIG_FILE" | cut -d'=' -f2-)
  AWSREGION=$(grep "^AWSREGION=" "$CONFIG_FILE" | cut -d'=' -f2-)
  
  if [ -z "$CFNDBURL" ]; then
    echo "错误: 配置文件中没有找到 CFNDBURL"
    exit 1
  fi
  
  echo "成功提取数据库连接信息"
else
  echo "错误: 配置文件 $CONFIG_FILE 不存在"
  exit 1
fi

echo "解析数据库连接字符串: $CFNDBURL"
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

# 检查数据库连接
echo -e "\n=== 检查数据库连接 ==="
max_attempts=5
attempt=0

while [ $attempt -lt $max_attempts ]; do
  attempt=$((attempt+1))
  echo "尝试连接数据库... 尝试 $attempt/$max_attempts"
  
  if PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "SELECT 1" > /dev/null 2>&1; then
    echo "数据库连接成功!"
    break
  else
    echo "连接失败，等待重试..."
    if [ $attempt -eq $max_attempts ]; then
      echo "错误: 无法连接到数据库，超过最大尝试次数"
      echo "请检查数据库连接信息和网络连接"
      exit 1
    fi
    sleep 5
  fi
done

# 按照文件名排序执行所有SQL文件
echo -e "\n=== 开始执行SQL迁移 ==="
for sql_file in $(ls -v *.sql); do
  echo "执行: $sql_file"
  if ! PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -U $DB_USER -d $DB_NAME -f $sql_file; then
    echo "执行 $sql_file 失败，重试..."
    # 重试最多3次
    for i in {1..3}; do
      echo "重试 $i/3..."
      if PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -U $DB_USER -d $DB_NAME -f $sql_file; then
        echo "重试成功!"
        break
      fi
      if [ $i -eq 3 ]; then
        echo "执行 $sql_file 失败，请检查SQL语法"
        exit 1
      fi
      sleep 2
    done
  fi
done

echo "所有SQL迁移已执行完成"

# 检查所有表是否存在
echo -e "\n=== 检查数据库表 ==="
PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
SELECT table_schema, table_name 
FROM information_schema.tables 
WHERE table_schema NOT IN ('pg_catalog', 'information_schema') 
ORDER BY table_schema, table_name;"

echo -e "\n=== 迁移完成! ==="
