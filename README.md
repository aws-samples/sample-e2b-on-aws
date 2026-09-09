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
- [Snapshot Retention](#-snapshot-retention)
- [Troubleshooting](#-troubleshooting)
- [Resource Cleanup](#-resource-cleanup)
- [License](#-license)

---

## ✨ Introduction

E2B on AWS provides a secure, scalable, and customizable environment for running AI agent sandboxes in your own AWS account. This project addresses the growing need for organizations to maintain control over their AI infrastructure while leveraging the power of E2B's sandbox technology for AI agent development, testing, and deployment.

> If you encounter any issues, please submit a PR directly. Special thanks to all contributors involved in the project transformation.

### Upstream version

The code layer (`packages/`, `spec/`, `scripts/`, `tests/`, `firecracker/`) is a
byte-for-byte copy of
[e2b-dev/infra](https://github.com/e2b-dev/infra) at
[`225f963`](https://github.com/e2b-dev/infra/commit/225f963a8dfbd516ee513b33d5f2846588c2f82c),
with two exceptions: three packages this deployment does not build and so does
not vendor (`dashboard-api`, `local-dev`, `nomad-nodepool-apm` — none of them
appear in `go.work`), and upstream's `.env*` samples, which `.gitignore`
excludes. A sync replaces that layer wholesale rather than merging into it. The
deployment layer (CloudFormation, `infra-iac/`, `nomad/`) is specific to this
repository.

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

### Step 4 — Run the Deployment (or Watch It Run)

The whole bootstrap writes to a single log, `/tmp/e2b.log` — the toolchain
install, every deployment step, and the output of each step:

```bash
sudo su root
tail -f /tmp/e2b.log
```

**If you left `AutoDeploy=true`** (the default), the chain is already running and
there is nothing to start. Follow it in the log above.

**If you set `AutoDeploy=false`**, the stack installed the toolchain and cloned
this repository but ran nothing. One command does the rest:

```bash
cd /opt/infra/sample-e2b-on-aws
sudo bash deploy-all.sh
```

It runs the same steps, in the same order, that `AutoDeploy=true` would:
`init` → `packer` → `terraform` → `init-db` → `build` → `prepare` → `deploy` →
`create-template`. Each step that succeeds writes `/opt/.e2b-step-<name>.done`,
so if one fails you can fix the cause and re-run the script — it resumes at the
step that broke instead of repeating the work before it.

```bash
sudo bash deploy-all.sh --list             # steps, and which are already done
sudo bash deploy-all.sh --skip-template    # stop after deploy, no test template
sudo bash deploy-all.sh --only terraform   # re-run one step, ignoring its marker
sudo bash deploy-all.sh --force            # clear all markers and start over
sudo bash deploy-all.sh --help
```

> **Note:** the full chain took about 45 minutes on an `x86_64` `dev` stack.
> `build` (compiling and pushing the service images, ~19 min) and `packer`
> (the AMI, ~14 min) dominate; everything else is minutes.

### Step 5 — Configure DNS Records (Cloudflare)

1. **Wildcard DNS**: Add a `*` CNAME record pointing to the Application Load Balancer (ALB) DNS name
2. **Nomad Dashboard**: Navigate to `https://nomad.<your-domain>`
3. **Retrieve Token**: Run `cat /opt/config.properties` to get the Nomad management token

<details>
<summary><strong>📊 Logging & Monitoring (Optional)</strong></summary>

The logging and monitoring stack consists of three components deployed via `nomad/deploy.sh --all`:

| Component | Type | Purpose | Port |
|---|---|---|---|
| **OTel Collector** | system (all nodes) | Collects metrics, traces, and application logs via OTLP | 4317 (gRPC), 4318 (HTTP) |
| **Logs Collector (Vector)** | system (all nodes) | Collects sandbox user logs, routes to Loki | 30006 |
| **Loki** | service (api node) | Log storage and query engine, backed by S3 | 3100 |

**Architecture:**

```
┌─────────────────────────────┐     ┌──────────────────────┐
│ Go Services (api/orch/proxy)│     │ Sandbox envd         │
│  OTel SDK → gRPC :4317      │     │  HTTP → :30006       │
└──────────┬──────────────────┘     └──────────┬───────────┘
           │                                    │
           ▼                                    ▼
┌──────────────────────┐            ┌──────────────────────┐
│   OTel Collector      │            │   Vector (logs-coll) │
│   Metrics/Traces/Logs │            │   Sandbox user logs  │
│   → Customer endpoint │            │   → Loki             │
└──────────────────────┘            └──────────┬───────────┘
                                               ▼
                                    ┌──────────────────────┐
                                    │   Loki               │
                                    │   Storage: S3 bucket │
                                    └──────────────────────┘
```

#### Deploy the logging module

Sandbox user logs are the one part of this stack that needs no external backend:
Vector ships them to a Loki that runs in the cluster and stores in S3. Two jobs,
Loki first because Vector's sink resolves `loki.service.consul`:

```bash
source nomad/nomad.sh          # exports NOMAD_ADDR / NOMAD_TOKEN
bash nomad/deploy.sh loki
bash nomad/deploy.sh logs-collector
```

`logs-collector` is a `system` job, so it lands one allocation per node — the api,
build and sandbox nodes all ship logs. Storage is the Loki bucket CloudFormation
created, `{stack-name}-loki-{account-id}`; retention is Loki's default, not S3
lifecycle, so set a lifecycle rule on that bucket if the volume matters to you.

**Deploy this even if you have no OTel backend.** Without `logs-collector` the
services keep POSTing to `localhost:30006`, nothing is listening, and the log line
is dropped — which is how a template build failure once surfaced only as
`Build failed: An internal error occurred` with the real cause
(`stat /fc-versions/...: no such file or directory`) discarded.

#### Query the logs

Loki has no UI of its own. It listens on the private address of the node its
allocation landed on, so find that node and query the HTTP API from the bastion:

```bash
source nomad/nomad.sh
ALLOC=$(nomad job status loki | sed -n '/^Allocations/,$p' | awk 'NR==3{print $1}')
NODE=$(nomad alloc status -json "$ALLOC" | jq -r .NodeID)
LOKI=$(nomad node status -json "$NODE" | jq -r .HTTPAddr | cut -d: -f1)

# What labels exist yet
curl -s "http://$LOKI:3100/loki/api/v1/labels" | jq -c .data
# ["buildID","category","envID","sandboxID","service","source","teamID"]

# Everything one sandbox emitted in the last 10 minutes
curl -s --get "http://$LOKI:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={sandboxID="<sandbox-id>"}' \
  --data-urlencode "start=$(( $(date +%s) - 600 ))000000000" \
  --data-urlencode 'limit=50' | jq -r '.data.result[]?.values[]?[1]'
```

Each line is a JSON object carrying the command, pid, exit status, `teamID` and
`envID`, so `{service="envd"}` gives every sandbox's activity and
`{sandboxID="..."}` narrows it to one. An empty label list means no logs have
arrived yet — either `logs-collector` is not deployed or no sandbox has run.

> Consul DNS is not resolvable from the bastion, which is why the address is
> looked up through Nomad rather than by using `loki.service.consul` directly.
> Inside the cluster that name works, and it is what Vector and the API use.

#### Deploy with Customer OTel Endpoint

Point the cluster at your own OTLP/HTTP backend — Grafana Cloud, Datadog,
Honeycomb, New Relic, or a collector you run. Three steps, and the only thing you
have to know is the endpoint:

```bash
# 1. Write the endpoint into config.properties
cat << EOF >> /opt/config.properties

# Customer OTel endpoint. http:// for plaintext, https:// for TLS.
otel_customer_endpoint=https://your-otel-backend:4318
EOF

# 2. Re-render the deploy HCLs so envsubst injects it
bash nomad/prepare.sh

# 3. Deploy the monitoring components
bash nomad/deploy.sh --all
```

**If your backend needs authentication** — every hosted one does — add the header
it expects. One header covers the common backends:

```bash
cat << EOF >> /opt/config.properties
otel_customer_header_name=Authorization
otel_customer_header_value=Basic <base64 of instanceID:token>
EOF
```

| Backend | `otel_customer_header_name` | `otel_customer_header_value` |
|---|---|---|
| Grafana Cloud | `Authorization` | `Basic <base64(instanceID:token)>` |
| Datadog | `DD-API-KEY` | your API key |
| Honeycomb | `x-honeycomb-team` | your ingest key |
| New Relic | `api-key` | your licence key |
| Self-hosted, no auth | *(leave both unset)* | |

Both keys are optional and independent of the endpoint: leave them out and the
exporter sends no headers, which is what an unauthenticated collector wants.

> **Important:** `otel_customer_endpoint` must be in `/opt/config.properties`
> **before** `nomad/prepare.sh` runs. `prepare.sh` renders `origin/*.hcl` →
> `deploy/*-deploy.hcl` with `envsubst`; with no endpoint the exporter gets an
> empty one and the otel-collector job fails to start — deliberately, since
> forwarding nowhere is a misconfiguration rather than a default.

> **No backend yet?** Sandbox user logs do not need one: `logs-collector` writes
> them to the in-cluster Loki, so `bash nomad/deploy.sh logs-collector` alone
> gives you searchable sandbox logs through Loki's HTTP API. Only the OTel
> pipeline (metrics, traces, service logs) requires an endpoint to send to.

#### Data Flow Details

| Data Type | Source | Pipeline | Storage |
|---|---|---|---|
| **Metrics** (application) | Go services OTel SDK | → OTel Collector → Customer endpoint | External |
| **Metrics** (infrastructure) | Nomad `/v1/metrics` | → OTel Collector (Prometheus scrape) → Customer endpoint | External |
| **Traces** | Go services OTel SDK | → OTel Collector → Customer endpoint | External |
| **Application Logs** | Go services zap logger | → OTel Collector (OTLP log bridge) → Customer endpoint | External |
| **Sandbox User Logs** | envd → orchestrator | → Vector (:30006) → Loki (:3100) | **S3** (Loki bucket) |

> **Note:** Sandbox user logs always go through Vector → Loki → S3, independent of the OTel pipeline. The Loki S3 bucket is created by CloudFormation (`{stack-name}-loki-{account-id}`); Terraform only grants the nodes access to it.

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
# (query teamApiKey from /opt/config.properties)
#
# E2B_ACCESS_TOKEN is not set here: upstream dropped the access_tokens table, so
# this deployment no longer issues an sk_e2b_ token. CLI commands that take a
# team API key work; the ones that authenticate as a user need an auth provider,
# which this deployment does not run.
export E2B_API_KEY=xxx
export E2B_DOMAIN="<e2bdomain>"

# Common commands
e2b sandbox list                  # List all sandboxes
e2b sandbox connect <sandbox-id>  # Connect to a sandbox
e2b sandbox kill <sandbox-id>     # Kill a sandbox
e2b sandbox kill --all            # Kill all sandboxes
```

### Client versions this deployment was verified with

| Client | Version | Install |
|---|---|---|
| E2B CLI | `2.16.1` | `npm i -g @e2b/cli` (or `brew install e2b`) |
| Python SDK `e2b` | `2.46.0` | `pip install e2b-code-interpreter` pulls it in |
| Python SDK `e2b-code-interpreter` | `2.9.2` | `pip install e2b-code-interpreter` |
| `envd` (in-sandbox agent, server side) | `0.7.0` | built by the deploy chain, not installed by you |

Verified against the code layer at upstream `225f963`. `envd` is reported by the
API on every create (`envdVersion`) and by `e2b sandbox list`, so it is the
quickest way to confirm which build a sandbox actually came from.

Only `E2B_API_KEY` and `E2B_DOMAIN` are needed — `e2b sandbox list` and
`e2b template list` were both checked with no `E2B_ACCESS_TOKEN` set, which is
what this deployment can offer now that upstream dropped user access tokens.

Two scripts in `tools/` exercise the API against a running deployment:

```bash
python3 tools/api-smoke-test.py                  # auth, templates, sandbox lifecycle
python3 tools/api-load-test.py --sandboxes 40    # concurrency: burst, fan-out, churn
# add --replicas <ip:port>,<ip:port> to also assert the API replicas share state
```

Both read the credentials the deploy chain wrote, so there is nothing to export
first, and both clean up every sandbox they create.

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

## 🗑️ Snapshot Retention

Pausing a sandbox writes a snapshot into the templates bucket, next to the
template builds it was layered on, and nothing upstream ever deletes it — not
even `DELETE /sandboxes/{id}`, which only hides the database row. The
`snapshot-retention` Nomad job (`nomad/origin/snapshot-retention.hcl`, built
from `tools/snapshot-retention`) runs daily at 03:00 UTC and applies one policy:

- A paused sandbox whose **last pause is older than 90 days** is soft-deleted:
  it disappears from `e2b sandbox list` and cannot be resumed, exactly as if it
  had been deleted through the API.
- **7 days later** its objects are deleted from the bucket and its build rows
  from the database — but only after the job has confirmed, from the headers of
  every live template and snapshot, that nothing still reads those blocks. A
  fork's checkpoint, a snapshot template, or a template built from one keeps its
  ancestors alive. Template objects are never touched.
- Snapshots deleted through the API follow the same 90-day / 7-day rule.

Why a job rather than an S3 lifecycle rule: snapshots are diffs. A newer
snapshot's header points at blocks of older snapshots and of the template, and a
running sandbox reads them lazily. Expiring objects by age would corrupt them.

The job ships as a **dry run**: it logs every `MARK`, `RESTORE` and `PURGE` it
would make and changes nothing. Review a run, then enable it:

```bash
# Trigger a run now and read its log
nomad job periodic force snapshot-retention
nomad job status snapshot-retention        # child job -> allocation id
nomad alloc logs <alloc-id>

# Enable deletion
echo "RETENTION_APPLY=true" >> /opt/config.properties
bash nomad/prepare.sh
bash nomad/deploy.sh snapshot-retention
```

Within the 7-day window a marked sandbox can be brought back by clearing the
soft delete on its snapshot env (the `env` in the `MARK` log line):

```sql
UPDATE envs SET deleted_at = NULL WHERE id = '<env-id>';
```

`RETENTION_DAYS` and `PURGE_DELAY_DAYS` live in the job spec. The delay must
exceed the longest sandbox lifetime (`tiers.max_length_hours`); the job refuses
to run otherwise.

The tool is compiled against the vendored code layer and pinned to the newest
database migration it was verified with (`verifiedMigration` in
`tools/snapshot-retention/schema.go`). After an upstream sync that adds
migrations, `go test` for the tool fails until the constant is bumped, and a
deployed binary that meets a newer schema runs as a dry run and exits non-zero.
Treat a failing build or test of `tools/snapshot-retention` as a failed sync.

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
