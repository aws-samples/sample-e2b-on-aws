#!/bin/bash
set -e

echo "=== 开始清理所有创建的内容 ==="

# 停止并删除Docker容器和卷
echo "停止并删除Docker容器和卷..."
docker-compose down -v || echo "Docker容器可能已经停止或不存在"

# 删除Docker镜像（可选，取消注释以删除）
# echo "删除PostgreSQL Docker镜像..."
# docker rmi postgres:15 || echo "PostgreSQL镜像可能不存在或正在被使用"

# 删除创建的脚本文件
echo "删除创建的脚本文件..."
rm -f run-all-migrations.sh check-tables.sh migrate-and-verify.sh

# 删除init-scripts目录
echo "删除init-scripts目录..."
rm -rf init-scripts

# 删除本清理脚本（最后执行）
echo "=== 清理完成 ==="
echo "注意：此脚本(cleanup.sh)将在执行后自删除"
echo "执行 'rm -f cleanup.sh' 删除此脚本"
