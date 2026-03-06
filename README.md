<div align="center">

# E2B on AWS

**Deploy E2B AI Sandboxes in Your Own AWS Account**

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-AWS-orange.svg)](https://aws.amazon.com/)
[![CloudFormation](https://img.shields.io/badge/IaC-CloudFormation-purple.svg)](https://aws.amazon.com/cloudformation/)

[English](README.md) | [中文](README_CN.md)

</div>

---

## 📋 Table of Contents

- [Introduction](#-introduction)
- [Prerequisites](#-prerequisites)
- [Deployment (New VPC)](#-deployment-new-vpc)
- [Deployment (Existing VPC)](#-deployment-existing-vpc)
- [Using E2B CLI](#-using-e2b-cli)
- [E2B SDK Cookbook](#-e2b-sdk-cookbook)
- [Troubleshooting](#-troubleshooting)
- [Resource Cleanup](#-resource-cleanup)
- [License](#-license)

---

## ✨ Introduction

E2B on AWS provides a secure, scalable, and customizable environment for running AI agent sandboxes in your own AWS account. This project addresses the growing need for organizations to maintain control over their AI infrastructure while leveraging the power of E2B's sandbox technology for AI agent development, testing, and deployment.

> Built based on version [`0c35ed5`](https://github.com/e2b-dev/infra/commit/0c35ed5c3b8492f96d1e0bbfb91fff96541a8c74). If you encounter any issues, please submit a PR directly. Special thanks to all contributors involved in the project transformation.

---

## 📦 Prerequisites

| Requirement | Description |
|---|---|
| **AWS Account** | With appropriate permissions |
| **Domain Name** | A domain you own (Cloudflare recommended) |
| **Grafana Account** | *(Optional)* For monitoring and logging |
| **Posthog Account** | *(Optional)* For analytics |

<details>
<summary><strong>🔒 Production Security Checklist</strong></summary>

Before deploying to production, verify these critical security and reliability settings are enabled:

- `DB_INSTANCE_BACKUP_ENABLED`
- `RDS_AUTOMATIC_MINOR_VERSION_UPGRADE_ENABLED`
- `RDS_ENHANCED_MONITORING_ENABLED`
- `RDS_INSTANCE_LOGGING_ENABLED`
- `RDS_MULTI_AZ_SUPPORT`
- `S3_BUCKET_LOGGING_ENABLED`
- `IMDSv2 enforced` - Instance Metadata Service v2 is required on all EC2 instances (`HttpTokens: required`)

</details>

---

## 🚀 Deployment (New VPC)

> To deploy into an existing VPC instead, see [Deployment (Existing VPC)](#-deployment-existing-vpc).

### Step 1 — Deploy CloudFormation Stack

1. Clone this repository
2. Open AWS CloudFormation console and create a new stack
3. Upload the `e2b-setup-env.yml` file
4. Configure the following parameters:

| Parameter | Description |
|---|---|
| **Stack Name** | Must be lowercase (e.g., `e2b-infra`) |
| **VPC Configuration** | New VPC environment configuration |
| **Environment** | `dev` or `prod` (prod has stricter resource protection) |
| **Architecture** | x64 or [AWS Graviton](https://aws.amazon.com/ec2/graviton/) |
| **Domain** | A domain you own (e.g., `example.com`) |
| **EC2 Key Pair** | Existing key pair for SSH access |
| **AllowRemoteSSHIPs** | IP range for SSH access (defaults to private networks) |
| **Database Settings** | RDS password: 8-30 characters with letters and numbers |

5. Complete all required fields and launch the stack

> **Note:** See [AWS Graviton Technical Guide](https://github.com/aws/aws-graviton-getting-started) for Graviton best practices.

### Step 2 — Validate Domain Certificate

1. Navigate to Amazon Certificate Manager (ACM)
2. Find your domain certificate and note the required CNAME record
3. Add the CNAME record to your DNS settings (Cloudflare DNS)
4. Wait for domain validation (typically **5 minutes**)

### Step 3 — Connect to Bastion Machine

```bash
# Option A: SSH with your key pair
ssh -i your-key.pem ubuntu@<instance-ip>

# Option B: AWS Session Manager from the EC2 console
```

### Step 4 — Watch Deployment Logs

```bash
sudo su root
tail -f /tmp/e2b.log
```

### Step 5 — Configure DNS Records (Cloudflare)

1. **Wildcard DNS**: Add a `*` CNAME record pointing to the Application Load Balancer (ALB) DNS name
2. **Nomad Dashboard**: Navigate to `https://nomad.<your-domain>`
3. **Retrieve Token**: Run `cat /opt/config.properties` to get the Nomad management token

<details>
<summary><strong>📊 Configure E2B Monitoring (Optional)</strong></summary>

1. Login to https://grafana.com/ (register if needed)
2. Access your settings page at `https://grafana.com/orgs/<username>`
3. In your Stack, find **Manage your stack** page
4. Find **OpenTelemetry** and click **Configure**
5. Note the following values:
   ```
   Endpoint for sending OTLP signals: xxxx
   Instance ID: xxxxxxx
   Password / API Token: xxxxx
   ```
6. Export Grafana environment variables:
   ```bash
   cat << EOF >> /opt/config.properties

   # Grafana configuration
   grafana_otel_collector_token=xxx
   grafana_otlp_url=xxx
   grafana_username=xxx
   EOF
   ```
7. Deploy OpenTelemetry collector:
   ```bash
   bash nomad/deploy.sh otel-collector
   ```
8. Open Grafana Cloud Dashboard to view metrics, traces, and logs

</details>

### Step 6 — Test E2B

**Create a template:**

```bash
# Create from e2bdev/code-interpreter (default)
bash packages/create_template.sh

# Create from a Dockerfile
bash packages/create_template.sh --docker-file <Docker_File_Path>

# Example: Desktop
bash packages/create_template.sh --docker-file test_use_case/Dockerfile/e2b.Dockerfile.Desktop

# Example: BrowserUse
bash packages/create_template.sh --docker-file test_use_case/Dockerfile/e2b.Dockerfile.BrowserUse

# Example: S3FS
bash packages/create_template.sh --docker-file test_use_case/Dockerfile/e2b.Dockerfile.s3fs

# Example: Code Interpreter (customized)
bash packages/create_template.sh --docker-file test_use_case/Dockerfile/e2b.Dockerfile.code_interpreter

# Create from an ECR image in your own account
bash packages/create_template.sh --ecr-image <ECR_IMAGE_URI>
```

**Create a sandbox:**

```bash
# Get e2b_API value from: cat ../infra-iac/db/config.json
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

## 🔄 Deployment (Existing VPC)

If you already have a VPC with subnets configured, use the `e2b-setup-env-existing-vpc.yml` template instead.

### Step 1 — Deploy CloudFormation Stack

1. Open AWS CloudFormation console and create a new stack
2. Upload the `e2b-setup-env-existing-vpc.yml` file
3. Configure the following parameters:

| Parameter | Description |
|---|---|
| **Stack Name** | Must be lowercase (e.g., `e2b-infra`) |
| `ExistingVpcId` | Your existing VPC ID |
| `ExistingPrivateSubnet1Id` / `2Id` | Private subnet IDs (two AZs) |
| `ExistingPublicSubnet1Id` / `2Id` | Public subnet IDs (two AZs) |
| `PublicAccess` | `public` or `private` access mode |
| **Architecture, Domain, Key Pair, DB** | Same as standard deployment |

4. The template automatically discovers your VPC CIDR block via a Lambda function

### Step 2 — Post-Deployment

Domain validation, bastion access, DNS setup, monitoring, and testing follow the same process as the [standard deployment](#step-2--validate-domain-certificate) starting from Step 2.

> **Note:** The existing VPC template uses Aurora Serverless PostgreSQL and Redis Serverless.

---

## 🖥️ Using E2B CLI

```bash
# Installation Guide: https://e2b.dev/docs/cli
# macOS
brew install e2b

# Export environment variables
# (query accessToken and teamApiKey from /opt/config.properties)
export E2B_API_KEY=xxx
export E2B_ACCESS_TOKEN=xxx
export E2B_DOMAIN="<e2bdomain>"

# Common commands
e2b sandbox list                  # List all sandboxes
e2b sandbox connect <sandbox-id>  # Connect to a sandbox
e2b sandbox kill <sandbox-id>     # Kill a sandbox
e2b sandbox kill --all            # Kill all sandboxes
```

---

## 📚 E2B SDK Cookbook

```bash
git clone https://github.com/e2b-dev/e2b-cookbook.git
cd e2b-cookbook/examples/hello-world-python
poetry install

# Edit .env and set E2B_API_KEY
vim .env

poetry run start
```

---

## 🔧 Troubleshooting

<details>
<summary><strong>No nodes were eligible for evaluation</strong></summary>

Check node status and constraints in the Nomad dashboard.

</details>

<details>
<summary><strong>Driver Failure: Failed to pull from ECR</strong></summary>

**Error:** `pull access denied ... Your authorization token has expired`

**Solution:** Execute `aws ecr get-login-password --region us-east-1` to get a new ECR token and update the HCL file.

</details>

For other unresolved issues, contact support.

---

## 🧹 Resource Cleanup

When you need to delete the E2B environment, follow these steps:

**1. Terraform Resource Cleanup**

```bash
cd ~/infra-iac/terraform/
terraform destroy
```

> **Note:** S3 Buckets must be manually emptied first. ALBs may require manual deletion through the AWS console.

**2. CloudFormation Stack Cleanup**

- Disable RDS deletion protection through the RDS console first
- Then delete the CloudFormation stack

**3. Manual Verification**

After automated cleanup, verify in the AWS console that all resources are removed:

| Service | Check |
|---|---|
| EC2 | Instances, Security Groups, Load Balancers |
| S3 | Buckets |
| RDS | Database instances |
| ECR | Container repositories |

---

## 🔐 Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## 📄 License

This project is licensed under the [Apache-2.0 License](LICENSE).
