#!/bin/bash

# 设置LC_ALL=C以避免字符编码问题
export LC_ALL=C

# 生成UUID格式的teamId
generate_uuid() {
    if command -v uuidgen &> /dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        # 使用更可靠的方法生成UUID
        printf '%04x%04x-%04x-%04x-%04x-%04x%04x%04x\n' \
            $((RANDOM%65536)) $((RANDOM%65536)) \
            $((RANDOM%65536)) \
            $(((RANDOM%16384)+16384)) \
            $(((RANDOM%16384)+32768)) \
            $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536))
    fi
}

# 生成随机的accessToken (格式: sk_e2b_后跟32个随机字符)
generate_access_token() {
    local chars="abcdefghijklmnopqrstuvwxyz0123456789"
    local token="sk_e2b_"
    
    for i in {1..32}; do
        token="${token}${chars:$(( RANDOM % ${#chars} )):1}"
    done
    
    echo "$token"
}

# 生成随机的teamApiKey (格式: e2b_后跟32个随机字符)
generate_team_api_key() {
    local chars="abcdefghijklmnopqrstuvwxyz0123456789"
    local key="e2b_"
    
    for i in {1..32}; do
        key="${key}${chars:$(( RANDOM % ${#chars} )):1}"
    done
    
    echo "$key"
}

# 生成随机值
TEAM_ID=$(generate_uuid)
ACCESS_TOKEN=$(generate_access_token)
TEAM_API_KEY=$(generate_team_api_key)

# 创建JSON文件
cat << EOF > config.json
{
    "email": "e2b@example.com",
    "teamId": "$TEAM_ID",
    "accessToken": "$ACCESS_TOKEN",
    "teamApiKey": "$TEAM_API_KEY",
    "cloud": "aws",
    "region": "us-east-1"
}
EOF

# 将值添加到/opt/config.properties文件的末尾
cat << EOF >> /opt/config.properties

# E2B配置
teamId=$TEAM_ID
accessToken=$ACCESS_TOKEN
teamApiKey=$TEAM_API_KEY
EOF

DOMAIN=$(grep "^CFNDOMAIN=" /opt/config.properties | cut -d= -f2)
echo "export E2B_DOMAIN=$DOMAIN"
echo "export E2B_API_KEY=$TEAM_API_KEY"
echo "export E2B_ACCESS_TOKEN=$ACCESS_TOKEN"