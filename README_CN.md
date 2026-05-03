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
- [故障排查](#-故障排查)
- [资源清理](#-资源清理)
- [许可证](#-许可证)

---

## ✨ 项目简介

E2B on AWS 为在您自己的 AWS 账户中运行 AI Agent 沙箱提供了安全、可扩展、可定制的环境。该项目旨在满足组织对 AI 基础设施控制权的需求，同时充分利用 E2B 的沙箱技术进行 AI Agent 开发、测试和部署。

> 基于版本 [`0c35ed5`](https://github.com/e2b-dev/infra/commit/0c35ed5c3b8492f96d1e0bbfb91fff96541a8c74) 构建。如遇问题，请直接提交 PR。特别感谢所有参与项目转型的贡献者。

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
| **Database Settings** | RDS 密码：8-30 个字符，包含字母和数字 |

5. 填写所有必填字段并启动堆栈

> **提示：** 参阅 [AWS Graviton 技术指南](https://github.com/aws/aws-graviton-getting-started) 了解 Graviton 最佳实践。

### 步骤 2 — 验证域名证书

1. 进入 Amazon Certificate Manager (ACM)
2. 找到您的域名证书，记录所需的 CNAME 记录
3. 在 DNS 设置中添加 CNAME 记录（Cloudflare DNS）
4. 等待域名验证完成（通常约 **5 分钟**）

### 步骤 3 — 连接堡垒机

通过 AWS Systems Manager Session Manager 连接：

```bash
aws ssm start-session --target <instance-id>
```

或通过 AWS EC2 控制台 → 选择实例 → 连接 → Session Manager。

### 步骤 4 — 查看部署日志

```bash
sudo su root
tail -f /tmp/e2b.log
```

### 步骤 5 — 配置 DNS 记录（Cloudflare）

1. **通配符 DNS**：添加 `*` CNAME 记录，指向 Application Load Balancer (ALB) 的 DNS 名称
2. **Nomad 控制台**：访问 `https://nomad.<your-domain>`
3. **获取 Token**：执行 `cat /opt/config.properties` 获取 Nomad 管理 Token

<details>
<summary><strong>📊 配置 E2B 监控（可选）</strong></summary>

1. 登录 https://grafana.com/（如需注册）
2. 访问设置页面 `https://grafana.com/orgs/<username>`
3. 在 Stack 中找到 **Manage your stack** 页面
4. 找到 **OpenTelemetry** 并点击 **Configure**
5. 记录以下值：
   ```
   Endpoint for sending OTLP signals: xxxx
   Instance ID: xxxxxxx
   Password / API Token: xxxxx
   ```
6. 导出 Grafana 环境变量：
   ```bash
   cat << EOF >> /opt/config.properties

   # Grafana configuration
   grafana_otel_collector_token=xxx
   grafana_otlp_url=xxx
   grafana_username=xxx
   EOF
   ```
7. 部署 OpenTelemetry collector：
   ```bash
   bash nomad/deploy.sh otel-collector
   ```
8. 打开 Grafana Cloud Dashboard 查看指标、链路追踪和日志

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
# （从 /opt/config.properties 查询 accessToken 和 teamApiKey）
export E2B_API_KEY=xxx
export E2B_ACCESS_TOKEN=xxx
export E2B_DOMAIN="<e2bdomain>"

# 常用命令
e2b sandbox list                  # 列出所有沙箱
e2b sandbox connect <sandbox-id>  # 连接到沙箱
e2b sandbox kill <sandbox-id>     # 终止沙箱
e2b sandbox kill --all            # 终止所有沙箱
```

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
