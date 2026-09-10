<div align="center">

# E2B on AWS

**在您的 AWS 账户中部署 E2B AI 沙箱**

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-AWS-orange.svg)](https://aws.amazon.com/)
[![CloudFormation](https://img.shields.io/badge/IaC-CloudFormation-purple.svg)](https://aws.amazon.com/cloudformation/)

[English](README.md) | [中文](README_CN.md)

</div>

---

## 📋 目录

- [项目简介](#-项目简介)
- [前置要求](#-前置要求)
- [部署（新建 VPC）](#-部署新建-vpc)
- [部署（使用现有 VPC）](#-部署使用现有-vpc)
- [使用 E2B CLI](#-使用-e2b-cli)
- [E2B SDK Cookbook](#-e2b-sdk-cookbook)
- [快照保留](#-快照保留)
- [故障排查](#-故障排查)
- [资源清理](#-资源清理)
- [许可证](#-许可证)

---

## ✨ 项目简介

E2B on AWS 为在您自己的 AWS 账户中运行 AI Agent 沙箱提供了安全、可扩展、可定制的环境。该项目旨在满足组织对 AI 基础设施控制权的需求，同时充分利用 E2B 的沙箱技术进行 AI Agent 开发、测试和部署。

> 如遇问题，请直接提交 PR。特别感谢所有参与项目转型的贡献者。

### 上游版本

代码层（`packages/`、`spec/`、`scripts/`、`tests/`、`firecracker/`）是
[e2b-dev/infra](https://github.com/e2b-dev/infra) 在
[`225f963`](https://github.com/e2b-dev/infra/commit/225f963a8dfbd516ee513b33d5f2846588c2f82c)
处的逐字节副本，仅有两处例外：本部署不构建、因此不 vendor 的三个包
（`dashboard-api`、`local-dev`、`nomad-nodepool-apm`，三者都不在 `go.work` 中），
以及被 `.gitignore` 排除的上游 `.env*` 样例文件。同步的做法是整体替换该层，而不是
往里合并。部署层（CloudFormation、`infra-iac/`、`nomad/`）为本仓库自研。

---

## 📦 前置要求

| 要求 | 说明 |
|---|---|
| **AWS 账户** | 具备相应权限 |
| **域名** | 您拥有的域名（推荐使用 Cloudflare） |
| **Grafana 账户** | *（可选）* 用于监控和日志 |
| **Posthog 账户** | *（可选）* 用于分析 |

<details>
<summary><strong>🔒 生产环境安全检查清单</strong></summary>

部署到生产环境前，请确认已启用以下关键安全和可靠性设置：

- `DB_INSTANCE_BACKUP_ENABLED`
- `RDS_AUTOMATIC_MINOR_VERSION_UPGRADE_ENABLED`
- `RDS_ENHANCED_MONITORING_ENABLED`
- `RDS_INSTANCE_LOGGING_ENABLED`
- `RDS_MULTI_AZ_SUPPORT`
- `S3_BUCKET_LOGGING_ENABLED`
- `IMDSv2 enforced` - 所有 EC2 实例强制要求使用 Instance Metadata Service v2（`HttpTokens: required`）

</details>

---

## 🚀 部署（新建 VPC）

> 如需部署到现有 VPC，请参阅 [部署（使用现有 VPC）](#-部署使用现有-vpc)。

### 步骤 1 — 部署 CloudFormation 堆栈

1. 克隆本仓库
2. 打开 AWS CloudFormation 控制台，创建新堆栈
3. 上传 `e2b-setup-env.yml` 文件
4. 配置以下参数：

| 参数 | 说明 |
|---|---|
| **Stack Name** | 必须小写（例如 `e2b-infra`） |
| **VPC Configuration** | 新建 VPC 环境配置 |
| **Environment** | `dev` 或 `prod`（prod 有更严格的资源保护机制） |
| **Architecture** | x64 或 [AWS Graviton](https://aws.amazon.com/ec2/graviton/) |
| **Domain** | 您拥有的域名（例如 `example.com`） |
| **EC2 Key Pair** | 用于 SSH 访问的现有密钥对 |
| **AllowRemoteSSHIPs** | SSH 访问的 IP 范围（默认限制为私有网络） |
| **Database Settings** | RDS 密码：8-30 个字符，包含字母和数字 |

5. 填写所有必填字段并启动堆栈

> **提示：** 参阅 [AWS Graviton 技术指南](https://github.com/aws/aws-graviton-getting-started) 了解 Graviton 最佳实践。

### 步骤 2 — 验证域名证书

1. 进入 Amazon Certificate Manager (ACM)
2. 找到您的域名证书，记录所需的 CNAME 记录
3. 在 DNS 设置中添加 CNAME 记录（Cloudflare DNS）
4. 等待域名验证完成（通常约 **5 分钟**）

### 步骤 3 — 连接堡垒机

```bash
# 方式 A：使用密钥对 SSH 连接
ssh -i your-key.pem ubuntu@<instance-ip>

# 方式 B：通过 EC2 控制台使用 AWS Session Manager
```

### 步骤 4 — 执行部署（或查看部署进度）

整个引导过程只写一个日志文件 `/tmp/e2b.log`：工具链安装、每一个部署步骤、以及每步的完整输出都在里面：

```bash
sudo su root
tail -f /tmp/e2b.log
```

**如果保持 `AutoDeploy=true`**（默认值），部署链已经在跑，无需再做任何事，看上面的日志即可。

**如果创建栈时把 `AutoDeploy` 设为 `false`**，栈只安装了工具链并克隆了本仓库，没有执行任何部署步骤。剩下的全部步骤由一条命令完成：

```bash
cd /opt/infra/sample-e2b-on-aws
sudo bash deploy-all.sh
```

它执行的步骤与顺序和 `AutoDeploy=true` 完全一致：`init` → `packer` → `terraform` → `init-db` → `build` → `prepare` → `deploy` → `create-template`。每个成功的步骤会写下 `/opt/.e2b-step-<name>.done`，因此某一步失败时，修好原因后直接重跑脚本即可 —— 它会从失败的那一步继续，不会重复已完成的工作。

```bash
sudo bash deploy-all.sh --list             # 列出各步骤及完成情况
sudo bash deploy-all.sh --skip-template    # 部署到 deploy 为止，不构建测试模板
sudo bash deploy-all.sh --only terraform   # 忽略标记，只重跑某一步
sudo bash deploy-all.sh --force            # 清空所有标记，从头再来
sudo bash deploy-all.sh --help
```

> **说明：** 在 `x86_64` 的 `dev` 栈上，完整链约耗时 45 分钟。其中 `build`（编译并推送服务镜像，约 19 分钟）和 `packer`（构建 AMI，约 14 分钟）占绝大部分，其余步骤都在分钟级。

### 步骤 5 — 配置 DNS 记录（Cloudflare）

1. **通配符 DNS**：添加 `*` CNAME 记录，指向 Application Load Balancer (ALB) 的 DNS 名称
2. **Nomad 控制台**：访问 `https://nomad.<your-domain>`
3. **获取 Token**：执行 `cat /opt/config.properties` 获取 Nomad 管理 Token

<details>
<summary><strong>📊 日志与监控（可选）</strong></summary>

日志与监控组件由 `nomad/deploy.sh --all` 一次性部署，共三个：

| 组件 | 类型 | 用途 | 端口 |
|---|---|---|---|
| **OTel Collector** | system（全节点） | 通过 OTLP 采集 metrics / traces / application logs | 4317 (gRPC), 4318 (HTTP) |
| **Logs Collector (Vector)** | system（全节点） | 采集 sandbox 内用户日志，转发到 Loki | 30006 |
| **Loki** | service（api 节点） | 日志存储与查询，后端 S3 | 3100 |

**架构：**

```
┌─────────────────────────────┐     ┌──────────────────────┐
│ Go Services (api/orch/proxy)│     │ Sandbox envd         │
│  OTel SDK → gRPC :4317      │     │  HTTP → :30006       │
└──────────┬──────────────────┘     └──────────┬───────────┘
           │                                    │
           ▼                                    ▼
┌──────────────────────┐            ┌──────────────────────┐
│   OTel Collector      │            │   Vector (logs-coll) │
│   Metrics/Traces/Logs │            │   Sandbox 用户日志    │
│   → 客户端点          │            │   → Loki             │
└──────────────────────┘            └──────────┬───────────┘
                                               ▼
                                    ┌──────────────────────┐
                                    │   Loki               │
                                    │   存储：S3 桶         │
                                    └──────────────────────┘
```

#### 部署日志模块

沙箱用户日志是这套系统里唯一**不需要外部后端**的部分：Vector 把日志送进集群内的 Loki，
Loki 存到 S3。两个 job，先 Loki，因为 Vector 的 sink 要解析 `loki.service.consul`：

```bash
source nomad/nomad.sh          # 导出 NOMAD_ADDR / NOMAD_TOKEN
bash nomad/deploy.sh loki
bash nomad/deploy.sh logs-collector
```

`logs-collector` 是 `system` 类型 job，每个节点一个 alloc —— api、build、沙箱节点都会上报。
存储用 CloudFormation 创建的 Loki 桶 `{stack-name}-loki-{account-id}`；保留策略走 Loki 默认值而非 S3
生命周期，日志量大的话请自行给该桶加 lifecycle 规则。

**即使暂时没有 OTel 后端也建议部署它。** 不部署 `logs-collector` 时，各服务仍会往
`localhost:30006` POST 日志，而那里没人监听，日志行被直接丢弃 —— 之前一次模板构建失败就只
留下 `Build failed: An internal error occurred`，真实原因
（`stat /fc-versions/...: no such file or directory`）被丢掉了。

#### 查询日志

Loki 自身没有 UI，且只监听其 alloc 所在节点的私网地址。在堡垒机上先定位节点，再查 HTTP API：

```bash
source nomad/nomad.sh
ALLOC=$(nomad job status loki | sed -n '/^Allocations/,$p' | awk 'NR==3{print $1}')
NODE=$(nomad alloc status -json "$ALLOC" | jq -r .NodeID)
LOKI=$(nomad node status -json "$NODE" | jq -r .HTTPAddr | cut -d: -f1)

# 当前有哪些标签
curl -s "http://$LOKI:3100/loki/api/v1/labels" | jq -c .data
# ["buildID","category","envID","sandboxID","service","source","teamID"]

# 某个沙箱最近 10 分钟的全部日志
curl -s --get "http://$LOKI:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={sandboxID="<sandbox-id>"}' \
  --data-urlencode "start=$(( $(date +%s) - 600 ))000000000" \
  --data-urlencode 'limit=50' | jq -r '.data.result[]?.values[]?[1]'
```

每行是一个 JSON 对象，含命令行、pid、退出状态、`teamID`、`envID`。用 `{service="envd"}`
可看全部沙箱活动，`{sandboxID="..."}` 收敛到单个沙箱。标签列表为空说明还没有日志到达 ——
要么 `logs-collector` 未部署，要么还没有沙箱运行过。

> 堡垒机上无法解析 Consul DNS，所以这里通过 Nomad 查地址而不是直接用
> `loki.service.consul`。集群内部该域名是可用的，Vector 和 API 用的就是它。

#### 使用客户 OTel 端点部署

把集群的遥测数据指向您自己的 OTLP/HTTP 后端（Grafana Cloud、Datadog、Honeycomb、
New Relic，或自建 collector）。三步，唯一需要知道的就是端点地址：

```bash
# 1. 把端点写入 config.properties
cat << EOF >> /opt/config.properties

# 客户 OTel 端点。明文用 http://，TLS 用 https://
otel_customer_endpoint=https://your-otel-backend:4318
EOF

# 2. 重新渲染 deploy HCL，让 envsubst 注入
bash nomad/prepare.sh

# 3. 部署监控组件
bash nomad/deploy.sh --all
```

**如果后端需要认证**（所有托管服务都需要），再加上它要求的 header。一个 header 足以覆盖常见后端：

```bash
cat << EOF >> /opt/config.properties
otel_customer_header_name=Authorization
otel_customer_header_value=Basic <base64(instanceID:token)>
EOF
```

| 后端 | `otel_customer_header_name` | `otel_customer_header_value` |
|---|---|---|
| Grafana Cloud | `Authorization` | `Basic <base64(instanceID:token)>` |
| Datadog | `DD-API-KEY` | 您的 API key |
| Honeycomb | `x-honeycomb-team` | 您的 ingest key |
| New Relic | `api-key` | 您的 licence key |
| 自建、免认证 | *（两项都不填）* | |

这两个键是可选的、与端点相互独立：不填则 exporter 不发送任何 header，正是免认证 collector 需要的形式。

> **重要：** 运行 `nomad/prepare.sh` **之前**，`/opt/config.properties` 里必须已定义
> `otel_customer_endpoint`。`prepare.sh` 用 `envsubst` 把 `origin/*.hcl` 渲染成
> `deploy/*-deploy.hcl`；端点缺失时 exporter 会拿到空地址、otel-collector 启动失败 ——
> 这是故意的：转发到空地址属于配置错误，不是默认值。

> **暂时没有后端？** 沙箱用户日志不需要它：`logs-collector` 会把日志写入集群内的 Loki，
> 只跑 `bash nomad/deploy.sh logs-collector` 就能通过 Loki 的 HTTP API 检索沙箱日志。
> 只有 OTel 管道（metrics、traces、服务日志）才必须有一个可发送的端点。

#### 数据流详情

| 数据类型 | 来源 | 管道 | 存储 |
|---|---|---|---|
| **Metrics**（应用） | Go 服务 OTel SDK | → OTel Collector → 客户端点 | 外部 |
| **Metrics**（基础设施） | Nomad `/v1/metrics` | → OTel Collector（Prometheus scrape）→ 客户端点 | 外部 |
| **Traces** | Go 服务 OTel SDK | → OTel Collector → 客户端点 | 外部 |
| **应用日志** | Go 服务 zap logger | → OTel Collector（OTLP log bridge）→ 客户端点 | 外部 |
| **Sandbox 用户日志** | envd → orchestrator | → Vector (:30006) → Loki (:3100) | **S3**（Loki 桶） |

> **注意：** Sandbox 用户日志始终走 Vector → Loki → S3，独立于 OTel 管道。Loki S3 桶由 CloudFormation 创建（`{stack-name}-loki-{account-id}`），Terraform 只负责给节点授权访问。

</details>

### 步骤 6 — 测试 E2B

**创建模板：**

```bash
# 从 e2bdev/code-interpreter 创建（默认）
bash packages/create_template.sh

# 从 Dockerfile 创建
bash packages/create_template.sh --docker-file <Docker_File_Path>

# 示例：Desktop
bash packages/create_template.sh --docker-file test_use_case/Dockerfile/e2b.Dockerfile.Desktop

# 示例：BrowserUse
bash packages/create_template.sh --docker-file test_use_case/Dockerfile/e2b.Dockerfile.BrowserUse

# 示例：S3FS
bash packages/create_template.sh --docker-file test_use_case/Dockerfile/e2b.Dockerfile.s3fs

# 示例：Code Interpreter（自定义）
bash packages/create_template.sh --docker-file test_use_case/Dockerfile/e2b.Dockerfile.code_interpreter

# 从您账户中的 ECR 镜像创建
bash packages/create_template.sh --ecr-image <ECR_IMAGE_URI>
```

**创建沙箱：**

```bash
# 获取 e2b_API 值：cat ../infra-iac/db/config.json
curl -X POST \
  https://api.<e2bdomain>/sandboxes \
  -H "X-API-Key: <e2b_API>" \
  -H 'Content-Type: application/json' \
  -d '{
    "templateID": "<template_ID>",
    "timeout": 3600,
    "autoPause": true,
    "metadata": { "purpose": "test" }
  }'
```

---

## 🔄 部署（使用现有 VPC）

如果您已有配置好子网的 VPC，请改用 `e2b-setup-env-existing-vpc.yml` 模板。

### 步骤 1 — 部署 CloudFormation 堆栈

1. 打开 AWS CloudFormation 控制台，创建新堆栈
2. 上传 `e2b-setup-env-existing-vpc.yml` 文件
3. 配置以下参数：

| 参数 | 说明 |
|---|---|
| **Stack Name** | 必须小写（例如 `e2b-infra`） |
| `ExistingVpcId` | 您现有的 VPC ID |
| `ExistingPrivateSubnet1Id` / `2Id` | 私有子网 ID（两个可用区） |
| `ExistingPublicSubnet1Id` / `2Id` | 公有子网 ID（两个可用区） |
| `PublicAccess` | `public` 或 `private` 访问模式 |
| **Architecture、Domain、Key Pair、DB** | 与标准部署相同 |

4. 模板会通过 Lambda 函数自动发现您的 VPC CIDR 块

### 步骤 2 — 后续步骤

域名验证、堡垒机访问、DNS 设置、监控和测试均与[标准部署](#步骤-2--验证域名证书)从步骤 2 起的流程相同。

> **提示：** 现有 VPC 模板使用 Aurora Serverless PostgreSQL 和 Redis Serverless。

---

## 🖥️ 使用 E2B CLI

```bash
# 安装指南：https://e2b.dev/docs/cli
# macOS
brew install e2b

# 导出环境变量
# （从 /opt/config.properties 查询 teamApiKey）
#
# 这里不再设置 E2B_ACCESS_TOKEN：上游已删除 access_tokens 表，本部署不再签发
# sk_e2b_ token。使用 team API key 的命令可正常工作；需要以用户身份认证的命令
# 依赖 auth provider，本部署未运行该组件。
export E2B_API_KEY=xxx
export E2B_DOMAIN="<e2bdomain>"

# 常用命令
e2b sandbox list                  # 列出所有沙箱
e2b sandbox connect <sandbox-id>  # 连接到沙箱
e2b sandbox kill <sandbox-id>     # 终止沙箱
e2b sandbox kill --all            # 终止所有沙箱
```

### 本部署已验证的客户端版本

| 客户端 | 版本 | 安装方式 |
|---|---|---|
| E2B CLI | `2.16.1` | `npm i -g @e2b/cli`（或 `brew install e2b`） |
| Python SDK `e2b` | `2.46.0` | 随 `pip install e2b-code-interpreter` 一起安装 |
| Python SDK `e2b-code-interpreter` | `2.9.2` | `pip install e2b-code-interpreter` |
| `envd`（沙箱内 agent，服务端） | `0.7.0` | 由部署链构建，无需手动安装 |

以上针对上游 `225f963` 的代码层验证。`envd` 版本由 API 在每次创建时返回（`envdVersion`），
`e2b sandbox list` 也会显示 —— 这是确认沙箱来自哪个构建最快的办法。

只需要 `E2B_API_KEY` 和 `E2B_DOMAIN`：`e2b sandbox list` 与 `e2b template list` 都在
未设置 `E2B_ACCESS_TOKEN` 的情况下验证通过 —— 上游删除用户 access token 之后，这是本部署
能提供的认证方式。

`tools/` 下有两个脚本用于对运行中的部署做 API 验证：

```bash
python3 tools/api-smoke-test.py                  # 认证、模板、沙箱生命周期
python3 tools/api-load-test.py --sandboxes 40    # 并发：突发创建、读扇出、状态翻转
# 加 --replicas <ip:port>,<ip:port> 可同时验证多个 API 副本共享状态
```

两者都自行读取部署链写下的凭据，无需预先 export，并且会清理自己创建的全部沙箱。

---

## 📚 E2B SDK Cookbook

```bash
git clone https://github.com/e2b-dev/e2b-cookbook.git
cd e2b-cookbook/examples/hello-world-python
poetry install

# 编辑 .env 并设置 E2B_API_KEY
vim .env

poetry run start
```

---

## 🗑️ 快照保留

暂停沙箱会把快照写进模板桶，与它所基于的模板构建放在一起，而上游从不删除它——
即使调用 `DELETE /sandboxes/{id}` 也只是隐藏数据库行。`snapshot-retention`
Nomad 任务（`nomad/origin/snapshot-retention.hcl`，由 `tools/snapshot-retention`
构建）每天 03:00 UTC 运行，执行一条策略：

- **最后一次 pause 超过 90 天**的暂停沙箱会被软删：它从 `e2b sandbox list` 消失、
  不能再恢复，效果与通过 API 删除完全相同。
- **再过 7 天**，它的对象从桶里删除、构建记录从数据库删除——但前提是任务已经读取
  所有仍在使用的模板与快照的 header，确认没有谁还引用这些数据块。fork 的 checkpoint、
  快照模板、基于快照模板构建的模板都会让它们的祖先保持存活。模板对象永远不会被碰。
- 通过 API 删除的快照遵循同样的 90 天 / 7 天规则。

为什么用任务而不是 S3 生命周期规则：快照是增量的。新快照的 header 指向旧快照和模板
的数据块，运行中的沙箱按需读取它们。按对象年龄过期会把它们弄坏。

任务默认是**演习模式**：只记录它将要做的每一条 `MARK`、`PURGE`，不改动任何数据。
先看一轮日志，再启用：

```bash
# 立即触发一轮并查看日志
nomad job periodic force snapshot-retention
nomad job status snapshot-retention        # 子任务 -> allocation id
nomad alloc logs <alloc-id>

# 启用删除
echo "RETENTION_APPLY=true" >> /opt/config.properties
bash nomad/prepare.sh
bash nomad/deploy.sh snapshot-retention
```

同一时刻只会有一轮在跑：定时任务活跃期间手工启动的那一轮会立刻退出，并提示
`another snapshot-retention run holds the lock`。

7 天窗口内，清掉快照 env（`MARK` 日志行里的 `env`）上的软删标记即可把沙箱找回来。
后面两个条件防止 id 贴错时把用户有意删除的模板复活：

```sql
UPDATE envs SET deleted_at = NULL
WHERE id = '<env-id>' AND source = 'snapshot' AND deleted_at IS NOT NULL;
```

同一条语句也覆盖任务自身不处理的唯一边界情况：沙箱恰好在被标记的那一刻正在运行，
下次 pause 之后它会保持隐藏。它的对象是安全的——那次 pause 让它们再保留 90 天——
只需清掉软删标记就能重新出现。这类 env 的特征是"软删之后又有了新 build"，不依赖日志
也能列出来：

```sql
SELECT e.id, s.sandbox_id, e.deleted_at
FROM envs e JOIN snapshots s ON s.env_id = e.id
WHERE e.source = 'snapshot' AND e.deleted_at IS NOT NULL
  AND EXISTS (SELECT 1 FROM env_build_assignments a JOIN env_builds b ON b.id = a.build_id
              WHERE a.env_id = e.id AND GREATEST(b.created_at, a.created_at) > e.deleted_at);
```

`RETENTION_DAYS` 与 `PURGE_DELAY_DAYS` 在任务定义里。延迟必须大于沙箱最长存活时间
（`tiers.max_length_hours`），否则任务拒绝运行。

工具针对 vendored 代码层编译，并钉在它已验证过的最新数据库迁移版本上
（`tools/snapshot-retention/schema.go` 里的 `verifiedMigration`）。上游同步带来新迁移后，
工具的 `go test` 会失败直到常量被更新；已部署的二进制遇到更新的 schema 时只做演习并以非零
退出码结束。请把 `tools/snapshot-retention` 构建或测试失败视为同步失败。

---

## 🔧 故障排查

<details>
<summary><strong>No nodes were eligible for evaluation</strong></summary>

在 Nomad Dashboard 中检查节点状态和约束条件。

</details>

<details>
<summary><strong>Driver Failure: Failed to pull from ECR</strong></summary>

**错误信息：** `pull access denied ... Your authorization token has expired`

**解决方案：** 执行 `aws ecr get-login-password --region us-east-1` 获取新的 ECR Token 并更新 HCL 文件。

</details>

如遇其他问题，请联系支持团队。

---

## 🧹 资源清理

需要删除 E2B 环境时，请按以下步骤操作：

**1. Terraform 资源清理**

```bash
cd ~/infra-iac/terraform/
terraform destroy
```

> **注意：** S3 存储桶需先手动清空。ALB 可能需要通过 AWS 控制台手动删除。

**2. CloudFormation 堆栈清理**

- 先在 RDS 控制台中禁用删除保护
- 然后删除 CloudFormation 堆栈

**3. 手动验证**

自动清理完成后，在 AWS 控制台中确认所有资源已移除：

| 服务 | 检查项 |
|---|---|
| EC2 | 实例、安全组、负载均衡器 |
| S3 | 存储桶 |
| RDS | 数据库实例 |
| ECR | 容器镜像仓库 |

---

## 🔐 安全

详见 [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications)。

## 📄 许可证

本项目基于 [Apache-2.0 许可证](LICENSE) 发布。
