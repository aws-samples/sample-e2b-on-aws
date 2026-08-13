#!/bin/bash

# 设置LC_ALL=C以避免字符编码问题
export LC_ALL=C

# 只写入非凭据字段。teamId / accessToken / teamApiKey 由上游的
# packages/db/scripts/seed/postgres/seed-db.go 生成，init-db.sh 在 seed 之后把
# 真实值回填到本文件。
#
# 这里不再自造凭据：上游把 access_tokens / team_api_keys 改成只存哈希
# (access_token_hash / api_key_hash 加 prefix/length/mask 列)，而哈希由
# packages/shared/pkg/keys 计算，且要求原始值是 hex。本脚本以前生成的
# "e2b_" + 32 个随机小写字母数字既不是 hex，也无法写进已经没有明文列的表。
cat << EOF > config.json
{
    "email": "e2b@example.com",
    "cloud": "aws",
    "region": "us-east-1"
}
EOF

DOMAIN=$(grep "^CFNDOMAIN=" /opt/config.properties | cut -d= -f2)
echo "export E2B_DOMAIN=$DOMAIN"