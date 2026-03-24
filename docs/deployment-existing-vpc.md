# E2B on AWS 部署指南（使用已有 VPC）

本文档基于 `e2b-setup-env-existing-vpc.yml` CloudFormation 模板，详细说明如何在已有 VPC 环境中部署 E2B 平台，以及如何在线更新各服务。

---

## 目录

- [架构概述](#架构概述)
- [前置条件](#前置条件)
- [CloudFormation 参数详解](#cloudformation-参数详解)
- [部署步骤](#部署步骤)
- [DNS 配置](#dns-配置)
- [验证部署](#验证部署)
- [在线更新服务](#在线更新服务)
- [监控配置（可选）](#监控配置可选)
- [资源清理](#资源清理)

---

## 架构概述

E2B on AWS 采用以下架构：

```
                    ┌─────────────────────────────────────────────────┐
                    │                   VPC                            │
                    │                                                  │
   Internet ──▶  ALB (443/80)                                         │
                    │                                                  │
                    ├──▶ api.domain     ──▶  API 集群 (1x m6i.xlarge) │
                    ├──▶ nomad.domain   ──▶  Server 集群 (3x)         │
                    ├──▶ docker.domain  ──▶  Docker Proxy              │
                    └──▶ *.domain       ──▶  Client Proxy              │
                    │                                                  │
                    │  Server 集群 (3 台)  ── Consul + Nomad Server    │
                    │  Client 集群 (1-多台) ── Sandbox 运行 (metal)     │
                    │  API 集群 (1 台)     ── API + Edge + Proxy       │
                    │  Build 集群 (0-5台)  ── 模板构建（按需启用）      │
                    │                                                  │
                    │  外部依赖: RDS PostgreSQL / ElastiCache Redis    │
                    │            S3 (存储) / ACM (证书)                │
                    └─────────────────────────────────────────────────┘
```

**核心组件：**

| 组件                     | 说明                           | 调度方式                      |
| ------------------------ | ------------------------------ | ----------------------------- |
| **Consul**               | 服务发现与配置管理             | 运行在所有节点                |
| **Nomad**                | 容器与任务编排                 | Server 集群运行 Nomad Server  |
| **API**                  | E2B API 服务（Go），端口 50001 | Nomad Docker 作业             |
| **Orchestrator**         | 沙箱编排器，端口 5008          | Nomad raw_exec 作业（系统级） |
| **Client-Proxy**         | 会话代理，端口 3001/3002       | Nomad Docker 作业             |
| **Template-Manager**     | 模板管理服务，端口 5009        | Nomad raw_exec 作业           |
| **Docker-Reverse-Proxy** | Docker 镜像代理，端口 5000     | Nomad Docker 作业             |

---

## 前置条件

使用 `e2b-setup-env-existing-vpc.yml` 模板前，需提前准备以下外部资源：

### 1. 网络资源

| 资源            | 要求                                                         |
| --------------- | ------------------------------------------------------------ |
| **VPC**         | 已有 VPC，需启用 DNS 支持和 DNS 主机名                       |
| **私有子网**    | 2 个，分布在不同可用区（用于 Server/Client/API/Build 集群）  |
| **公有子网**    | 2 个，分布在不同可用区（用于 ALB，private 模式下可填占位值） |
| **NAT Gateway** | 私有子网需要访问外网（拉取镜像、下载依赖）                   |

### 2. 存储资源

| 资源           | 说明                                                               |
| -------------- | ------------------------------------------------------------------ |
| **E2B S3 桶**  | 统一存储桶，用于 Terraform 状态、集群脚本、FC 内核、环境构建产物等 |
| **Loki S3 桶** | 日志存储桶（用于 Grafana Loki）                                    |

### 3. 数据库与缓存

| 资源                  | 说明                                                                                                    |
| --------------------- | ------------------------------------------------------------------------------------------------------- |
| **RDS PostgreSQL**    | 密码只能包含大小写字母和数字，不能有特殊字符，连接字符串格式：`postgresql://user:pass@host:port/dbname` |
| **ElastiCache Redis** | 端点地址（不含端口）比如开启tls，且无密码，如 `xxx.serverless.use1.cache.amazonaws.com`                 |

### 4. 证书与密钥

| 资源               | 说明                                              |
| ------------------ | ------------------------------------------------- |
| **ACM 通配符证书** | 如 `*.yourdomain.com`，需已验证通过，提供证书 ARN |
| **EC2 Key Pair**   | 用于 SSH 访问集群实例                             |

---

## CloudFormation 参数详解

在 AWS CloudFormation 控制台创建 Stack 时，需填写以下参数：

### 环境配置

| 参数                 | 类型               | 说明                                                                                                             |
| -------------------- | ------------------ | ---------------------------------------------------------------------------------------------------------------- |
| `Environment`        | `prod` / `dev`     | 环境类型。prod 使用更高规格实例（m6i.xlarge），dev 使用 t3.xlarge                                                |
| `Architecture`       | `x86_64` / `arm64` | CPU 架构。arm64 使用 AWS Graviton 处理器，成本更低                                                               |
| `ClientInstanceType` | String（可选）     | Client 节点实例类型，需支持嵌套虚拟化（如 `*.metal`）。留空则按架构默认：x86 用 `c5.metal`，arm64 用 `c7g.metal` |

### 网络配置

| 参数                       | 类型                 | 说明                   |
| -------------------------- | -------------------- | ---------------------- |
| `ExistingVpcId`            | VPC ID               | 已有 VPC 的 ID         |
| `ExistingPrivateSubnet1Id` | Subnet ID            | 第一个可用区的私有子网 |
| `ExistingPrivateSubnet2Id` | Subnet ID            | 第二个可用区的私有子网 |
| `ExistingPublicSubnet1Id`  | Subnet ID            | 第一个可用区的公有子网 |
| `ExistingPublicSubnet2Id`  | Subnet ID            | 第二个可用区的公有子网 |
| `PublicAccess`             | `public` / `private` | ALB 对外访问模式       |

### 域名配置

| 参数         | 类型   | 说明                                             |
| ------------ | ------ | ------------------------------------------------ |
| `BaseDomain` | String | 基础域名（如 `e2b.example.com`），需符合域名格式 |

### SSH 密钥

| 参数      | 类型             | 说明                     |
| --------- | ---------------- | ------------------------ |
| `KeyName` | EC2 KeyPair Name | 已有的 EC2 Key Pair 名称 |

### 外部资源

| 参数                     | 类型            | 说明                       |
| ------------------------ | --------------- | -------------------------- |
| `ExistingE2BBucketName`  | String          | E2B 统一 S3 桶名称         |
| `ExistingLokiBucketName` | String          | Loki 日志 S3 桶名称        |
| `ExistingDBURL`          | String (NoEcho) | PostgreSQL 连接字符串      |
| `ExistingRedisEndpoint`  | String          | Redis 端点地址（不含端口） |
| `ExistingCertificateArn` | String          | ACM 通配符证书 ARN         |

### 自定义脚本（可选）

| 参数              | 类型   | 说明                                                       |
| ----------------- | ------ | ---------------------------------------------------------- |
| `CustomScriptUrl` | String | EC2 启动后执行的自定义脚本 URL，支持 `s3://` 和 `https://` |

---

## 部署步骤

### Step 1 — 创建 CloudFormation Stack

1. 打开 AWS CloudFormation 控制台
2. 选择 **Create stack** > **With new resources**
3. 上传 `e2b-setup-env-existing-vpc.yml` 文件
4. 填写上述参数，Stack Name 必须小写（如 `e2b-infra`）
5. 确认创建，等待 Stack 状态变为 `CREATE_COMPLETE`

> CloudFormation 会自动创建：VPC Endpoint（S3）、IAM Role/InstanceProfile、Lambda（VPC CIDR 查询），并将所有配置导出为 Stack Outputs。

### Step 2 — 连接 Bastion / 部署机器

需要一台能访问私有子网的 EC2 实例作为部署机器（可以是已有的 Bastion 或新建实例）。确保该实例：
- 使用 CloudFormation 创建的 `EC2InstanceProfile`
- 位于私有子网中
- 能访问外网（通过 NAT Gateway）

```bash
# 通过 SSH 连接
ssh -i your-key.pem ubuntu@<bastion-ip>

# 或通过 AWS Session Manager
aws ssm start-session --target <instance-id>
```

### Step 3 — 克隆代码并启动部署

```bash
sudo su root
cd /opt/infra
git clone https://github.com/aws-samples/sample-e2b-on-aws.git
cd sample-e2b-on-aws

# 一键部署（传入 CloudFormation Stack Name）
bash infra-iac/deploy-all.sh <your-stack-name>
```

部署脚本 `deploy-all.sh` 自动执行以下 10 个步骤：

| 步骤   | 脚本                           | 说明                                                                |
| ------ | ------------------------------ | ------------------------------------------------------------------- |
| Step 0 | deploy-all.sh 内置             | 自动安装依赖：Docker, Go, AWS CLI, Packer, Terraform, Nomad         |
| Step 1 | `infra-iac/init.sh`            | 读取 CloudFormation Outputs，生成 `/opt/config.properties` 配置文件 |
| Step 2 | `infra-iac/packer/packer.sh`   | 使用 Packer 构建集群 AMI 镜像                                       |
| Step 3 | `infra-iac/terraform/start.sh` | Terraform 创建基础设施（ASG、ALB、安全组、Launch Template 等）      |
| Step 4 | `infra-iac/db/init-db.sh`      | 初始化数据库（建表、种子数据、生成 API Key）                        |
| Step 5 | `packages/build.sh`            | 构建所有服务镜像并推送到 ECR                                        |
| Step 6 | `nomad/nomad.sh`               | 发现 Nomad Server 地址，设置环境变量                                |
| Step 7 | `nomad/prepare.sh`             | 用 `envsubst` 渲染 Nomad HCL 模板，生成部署文件                     |
| Step 8 | `nomad/deploy.sh`              | 部署所有 Nomad 作业                                                 |
| Step 9 | `packages/create_template.sh`  | 创建默认 E2B 沙箱模板                                               |

### Step 4 — 监控部署进度

```bash
tail -f /tmp/e2b.log
```

整个部署过程约需 20-40 分钟（取决于 AMI 构建和镜像推送速度）。

---

## DNS 配置

部署完成后，需配置 DNS 解析：

1. 获取 ALB 的 DNS 名称：
```bash
# 从 Terraform 输出中获取
grep alb_dns /opt/config.properties
```

2. 在 DNS 服务商（如 Cloudflare）添加以下记录：

| 类型  | 名称 | 目标             | 说明                       |
| ----- | ---- | ---------------- | -------------------------- |
| CNAME | `*`  | `<ALB-DNS-Name>` | 通配符解析，覆盖所有子域名 |

这会使以下域名生效：
- `api.<domain>` — E2B API
- `nomad.<domain>` — Nomad Dashboard
- `docker.<domain>` — Docker 镜像代理

---

## 验证部署

### 1. 访问 Nomad Dashboard

```bash
# 获取 Nomad Token
grep nomad_acl_token /opt/config.properties
```

浏览器访问 `https://nomad.<your-domain>`，使用 Token 登录，确认所有作业状态为 Running。

### 2. 创建模板

```bash
# 使用默认模板
bash packages/create_template.sh
```

### 3. 创建沙箱

```bash
# 获取 API Key
cat infra-iac/db/config.json

curl -X POST \
  https://api.<your-domain>/sandboxes \
  -H "X-API-Key: <your-api-key>" \
  -H 'Content-Type: application/json' \
  -d '{
    "templateID": "<template-id>",
    "timeout": 3600,
    "metadata": { "purpose": "test" }
  }'
```

---

## 在线更新服务

当需要修改代码后更新线上服务时，按以下步骤操作。所有操作在部署机器上执行。

### 前置准备

每次更新前，先加载 Nomad 环境变量：

```bash
cd /opt/infra/sample-e2b-on-aws
source nomad/nomad.sh
```

### 更新 API Server

API 是 Docker 容器化服务，镜像存储在 ECR。

```bash
cd /opt/infra/sample-e2b-on-aws

# 1. 构建新镜像并推送到 ECR
cd packages/api
make build-and-upload-aws

# 2. 重新部署 Nomad 作业（拉取最新镜像）
cd /opt/infra/sample-e2b-on-aws
bash nomad/prepare.sh
bash nomad/deploy.sh api
```

> Nomad 会自动停止旧任务、拉取最新 Docker 镜像并启动新实例。API 的健康检查路径为 `/health`，Nomad 会在新实例健康后才完成切换。

### 更新 Client-Proxy

```bash
cd /opt/infra/sample-e2b-on-aws/packages/client-proxy
make build-and-upload-aws

cd /opt/infra/sample-e2b-on-aws
nomad job run nomad/deploy/edge-deploy.hcl
```

### 更新 Docker-Reverse-Proxy

```bash
cd /opt/infra/sample-e2b-on-aws/packages/docker-reverse-proxy
make build-and-upload-aws

cd /opt/infra/sample-e2b-on-aws
bash nomad/prepare.sh
bash nomad/deploy.sh docker-reverse-proxy
```

### 更新 Orchestrator

Orchestrator 是二进制文件，存储在 S3，通过 Nomad `raw_exec` 运行。

```bash
cd /opt/infra/sample-e2b-on-aws/packages/orchestrator
make build-and-upload

cd /opt/infra/sample-e2b-on-aws
bash nomad/prepare.sh
bash nomad/deploy.sh orchestrator
```

> 注意：Orchestrator 是 system 类型作业，运行在所有 client 节点上，更新会在所有节点同时生效。

### 更新 Template-Manager

Template-Manager 与 Orchestrator 共用同一个二进制文件（由 Orchestrator 的 `make build-and-upload` 同时上传）。

```bash
# 如果已经更新过 Orchestrator 的二进制，直接重新部署即可
bash nomad/prepare.sh
bash nomad/deploy.sh template-manager
```

### 批量更新所有服务

```bash
cd /opt/infra/sample-e2b-on-aws

# 1. 构建所有服务（API, Client-Proxy, Docker-Reverse-Proxy, Orchestrator, Envd）
bash packages/build.sh

# 2. 加载 Nomad 环境
source nomad/nomad.sh

# 3. 重新渲染 Nomad HCL 模板（如果 /opt/config.properties 有变更）
bash nomad/prepare.sh

# 4. 部署所有服务
bash nomad/deploy.sh          # 最小部署（核心服务）
# 或
bash nomad/deploy.sh --all    # 完整部署（含监控和日志组件）
```

### API 节点蓝绿部署

当需要替换整个 API EC2 实例时（如 AMI 更新、系统配置变更、Launch Template 修改、重大版本更新），可使用蓝绿部署实现近零停机切换。

**原理：** API ASG 同时注册到 3 个 ALB Target Group（e2b-api、client-proxy、docker-proxy）。通过 ASG 扩容启动绿色实例，再用 Nomad node drain 将工作负载从蓝色迁移到绿色，最后显式终止蓝色实例。

#### 前提条件

```bash
cd /opt/infra/sample-e2b-on-aws
source nomad/nomad.sh

# 确认当前 API ASG 正常（1 实例 InService）
source /opt/config.properties
ASG_NAME="${CFNSTACKNAME}-api-asg"
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $ASG_NAME \
  --query 'AutoScalingGroups[0].Instances[*].[InstanceId,LifecycleState]' --output table
```

#### Step 1 — 准备新版本

根据更新类型执行对应操作：

| 更新类型 | 操作 |
|----------|------|
| **代码变更** | 构建新 Docker 镜像：`cd packages/api && make build-and-upload-aws` |
| **系统/AMI 变更** | 构建新 AMI：`cd infra-iac/packer && bash packer.sh`，然后 `cd infra-iac/terraform && terraform apply` 更新 Launch Template |
| **Nomad 配置变更** | 重新渲染模板：`bash nomad/prepare.sh` |

#### Step 2 — 记录蓝色实例并扩容

```bash
# 记录当前蓝色实例 ID（后续显式终止用）
BLUE_INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names $ASG_NAME \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
echo "蓝色实例: $BLUE_INSTANCE_ID"

# 扩容到 2（启动绿色实例）
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name $ASG_NAME \
  --min-size 1 --max-size 2 --desired-capacity 2

# 等待新实例 InService（约 2-5 分钟）
aws autoscaling wait group-in-service --auto-scaling-group-name $ASG_NAME
echo "绿色实例已启动"
```

#### Step 3 — 等待绿色节点加入 Nomad

```bash
# 查看 Nomad client 节点列表，确认新节点出现（应有 2 个 api pool 节点）
nomad node status

# 获取蓝色节点的私有 IP 和 Nomad Node ID
BLUE_IP=$(aws ec2 describe-instances --instance-ids $BLUE_INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
echo "蓝色节点 IP: $BLUE_IP"

BLUE_NODE_ID=$(nomad node status -json | jq -r ".[] | select(.Address == \"$BLUE_IP\") | .ID")
echo "蓝色 Nomad Node: $BLUE_NODE_ID"
```

> 如果绿色节点长时间未出现在 Nomad 中，可 SSH 到绿色实例检查 Nomad client 日志：`journalctl -u nomad -f`

#### Step 4 — 排空蓝色节点

```bash
# 排空蓝色节点（Nomad 自动将 job 迁移到绿色节点，deadline 后强制迁移）
nomad node drain -enable -deadline 5m -yes $BLUE_NODE_ID

# 观察 job 迁移状态
watch -n 5 'nomad job status api | tail -10; echo "---"; \
  nomad job status client-proxy | tail -10; echo "---"; \
  nomad job status docker-reverse-proxy | tail -10'
```

> 排空期间，Nomad 会先在绿色节点启动新 allocation，然后停止蓝色节点上的旧 allocation。由于 API 使用静态端口且 count=1，会有短暂切换时间（通常 30-60 秒），ALB 会在健康检查通过后自动恢复路由。

#### Step 5 — 验证绿色环境

```bash
# 确认所有 job 在绿色节点上运行
nomad job status api
nomad job status client-proxy
nomad job status docker-reverse-proxy

# 测试 API 健康检查
curl -s https://api.<your-domain>/health
```

#### Step 6 — 终止蓝色实例

```bash
# 显式终止蓝色实例（同时自动减少 desired-capacity）
aws autoscaling terminate-instance-in-auto-scaling-group \
  --instance-id $BLUE_INSTANCE_ID \
  --should-decrement-desired-capacity

# 恢复 ASG 配置为 max=1
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name $ASG_NAME \
  --min-size 1 --max-size 1

echo "蓝绿部署完成"
```

> **为什么不依赖 ASG 自动缩容？** ASG 默认终止策略在两台实例使用相同 Launch Template 版本时，无法保证终止旧实例。使用 `terminate-instance-in-auto-scaling-group` 显式指定实例 ID，确保终止正确的实例。

#### 回滚（在 Step 6 之前）

如果绿色实例出现问题，可快速回滚到蓝色：

```bash
# 1. 取消蓝色节点的 drain
nomad node drain -disable -yes $BLUE_NODE_ID

# 2. 排空绿色节点，让 job 迁回蓝色
GREEN_NODE_ID=$(nomad node status -json | \
  jq -r ".[] | select(.Address != \"$BLUE_IP\" and .NodePool == \"api\") | .ID")
nomad node drain -enable -deadline 5m -yes $GREEN_NODE_ID

# 3. 确认 job 迁回蓝色后，终止绿色实例
GREEN_INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names $ASG_NAME \
  --query "AutoScalingGroups[0].Instances[?InstanceId!=\`$BLUE_INSTANCE_ID\`].InstanceId" \
  --output text)
aws autoscaling terminate-instance-in-auto-scaling-group \
  --instance-id $GREEN_INSTANCE_ID \
  --should-decrement-desired-capacity

# 4. 恢复 ASG 配置
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name $ASG_NAME \
  --min-size 1 --max-size 1
```

### 更新单个服务的快速参考

| 服务                 | 构建命令                                                        | 部署文件                                       |
| -------------------- | --------------------------------------------------------------- | ---------------------------------------------- |
| API                  | `cd packages/api && make build-and-upload-aws`                  | `nomad/deploy/api-deploy.hcl`                  |
| Client-Proxy         | `cd packages/client-proxy && make build-and-upload-aws`         | `nomad/deploy/edge-deploy.hcl`                 |
| Docker-Reverse-Proxy | `cd packages/docker-reverse-proxy && make build-and-upload-aws` | `nomad/deploy/docker-reverse-proxy-deploy.hcl` |
| Orchestrator         | `cd packages/orchestrator && make build-and-upload`             | `nomad/deploy/orchestrator-deploy.hcl`         |
| Template-Manager     | （同 Orchestrator）                                             | `nomad/deploy/template-manager-deploy.hcl`     |
| Loki                 | —                                                               | `nomad/deploy/loki-deploy.hcl`                 |
| Logs-Collector       | —                                                               | `nomad/deploy/logs-collector-deploy.hcl`       |
| OTel-Collector       | —                                                               | `nomad/deploy/otel-collector-deploy.hcl`       |

### 查看服务状态

```bash
# 查看所有作业状态
nomad job status

# 查看某个作业详情
nomad job status api

# 查看分配的日志
nomad alloc logs <alloc-id>

# 查看分配状态
nomad alloc status <alloc-id>
```

---

## 监控配置（可选）

### Grafana Cloud + OpenTelemetry

1. 登录 [Grafana Cloud](https://grafana.com/)，获取 OTLP 配置：
   - Endpoint URL
   - Instance ID
   - API Token

2. 写入配置：
```bash
cat << EOF >> /opt/config.properties

# Grafana configuration
grafana_otel_collector_token=<your-token>
grafana_otlp_url=<your-endpoint>
grafana_username=<your-instance-id>
EOF
```

3. 重新渲染并部署 OTel Collector：
```bash
source nomad/nomad.sh
bash nomad/prepare.sh
bash nomad/deploy.sh otel-collector
```

---

## 资源清理

### 1. 销毁 Terraform 资源

```bash
cd /opt/infra/sample-e2b-on-aws/infra-iac/
bash destroy.sh
```

> 这会销毁 EC2 实例、ASG、ALB、安全组等 Terraform 管理的资源。

### 2. 删除 CloudFormation Stack

- 先在 AWS 控制台删除 CloudFormation Stack
- 此操作会删除 IAM Role、VPC Endpoint、Lambda 等 CFN 管理的资源

### 3. 手动清理外部资源

由于使用 existing-vpc 模板，以下外部资源需手动处理：

| 资源              | 操作                            |
| ----------------- | ------------------------------- |
| S3 桶             | 先清空桶内容，再删除桶          |
| RDS 数据库        | 如需删除，先关闭删除保护        |
| ElastiCache Redis | 手动删除                        |
| ACM 证书          | 手动删除                        |
| ECR 仓库          | 删除 `e2b-orchestration/*` 仓库 |

### 4. 验证清理

在 AWS 控制台检查以下服务，确认无残留资源：

- EC2（实例、安全组、负载均衡器、Launch Template）
- S3
- ECR
- CloudWatch（日志组）
- Secrets Manager（`*e2b*` 相关密钥）
