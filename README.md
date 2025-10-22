# E2B on AWS Deployment Guide

## Introduction

### Purpose

E2B on AWS provides a secure, scalable, and customizable environment for running AI agent sandboxes in your own AWS account. This project addresses the growing need for organizations to maintain control over their AI infrastructure while leveraging the power of E2B's sandbox technology for AI agent development, testing, and deployment.

This project is built based on version [0c35ed5c3b8492f96d1e0bbfb91fff96541a8c74](https://github.com/e2b-dev/infra/commit/0c35ed5c3b8492f96d1e0bbfb91fff96541a8c74) (Jul 1). This E2B deployment can be used for testing purposes. If you encounter any issues, please contact the relevant team members or submit a PR directly. We would like to express our special thanks to all contributors involved in the project transformation.

## Table of Contents

- [Prerequisites](#prerequisites)
- [How to Deploy](#deployment)
- [Using E2B CLI](#using-e2b-cli)
- [E2B SDK Cookbook](#e2b-sdk-cookbook)
- [Troubleshooting](#troubleshooting)
- [Resource Cleanup Recommendations](#resource-cleanup-recommendations)
- [Appendix](#appendix)
- [Architecture Diagram](#architecture-diagram)

## Prerequisites

- An AWS account with appropriate permissions
- A domain name that you own(Cloudflare is recommended)

- Recommended for monitoring and logging
  - Grafana Account & Stack (see Step 15 for detailed notes)
  - Posthog Account (optional)

> **Production Security Checklist:** Before deploying to production, verify these critical security and reliability settings are enabled:
> - `DB_INSTANCE_BACKUP_ENABLED`
> - `RDS_AUTOMATIC_MINOR_VERSION_UPGRADE_ENABLED`
> - `RDS_ENHANCED_MONITORING_ENABLED`
> - `RDS_INSTANCE_LOGGING_ENABLED`
> - `RDS_MULTI_AZ_SUPPORT`
> - `S3_BUCKET_LOGGING_ENABLED`
> - `EC2 Metadata service configuration`

## Deployment
### 1. E2B Deployment
1. **Deploy CloudFormation Stack**
   - Git Clone the project
   - Open AWS CloudFormation console and create a new stack
   - Upload the `e2b-setup-env.yml` file
   - Configure the following parameters:
     - **Stack Name**: Enter a name for the stack, **must be lowercase**(e.g., `e2b-infra`)
     - **VPC Configuration**: Deployed new VPC environment configuration
     - **Environment Configuration**: Choose an Environment (Support dev and prod, prod has a more stringent resource protection mechanism)
     - **Architecture Configuration**: Choose CPU architecture (Support x64 and [AWS Graviton](https://aws.amazon.com/cn/ec2/graviton/))
     - **Domain Configuration**: Enter a domain you own(e.g., `example.com`)
     - **EC2 Key Pair**: Select an existing key pair for SSH access
     - **AllowRemoteSSHIPs**: Adjust IP range for SSH access (default restricts to private networks for security)
     - **Database Settings**: Configure RDS parameters following password requirements(must be 8-30 characters with letters and numbers)
   - Complete all required fields and launch the stack

   **Note:** You can refer to [AWS Graviton Technical Guide](https://github.com/aws/aws-graviton-getting-started) for best practice on Graviton-based EC2 instances.
2. **Validate Domain Certificate**
   - Navigate to Amazon Certificate Manager (ACM)
   - Find your domain certificate and note the required CNAME record
   - Add the CNAME record to your domain's DNS settings(Cloudflare DNS settings)
   - Wait for domain validation (typically in **5 minutes**)

3. **Connect to Bastion Machine**
   - Use SSH with your EC2 key pair: `ssh -i your-key.pem ubuntu@<instance-ip>`
   - Or use AWS Session Manager from the EC2 console for browser-based access

4. **Watch Deployment Logs**
```bash 
# Switch to root user for administrative privileges required for infrastructure setup
sudo su root

tail -f /tmp/e2b.log
```

5. **Configure E2B DNS records(in Cloudflare)**
   - **Setup Wildcard DNS**: Add a CNAME record for `*` (wildcard) pointing to the DNS name of the automatically created Application Load Balancer (ALB). This enables all E2B subdomains to route through the load balancer.
   - **Access Nomad Dashboard**: Navigate to `https://nomad.<your-domain>` in your browser and authenticate using the retrieved token to monitor and manage the Nomad cluster workloads.
   - **Retrieve Nomad Access Token**: Execute `cat /opt/config.properties` to extract the Nomad cluster management token from the configuration file.

### 2. Configure E2B Monitoring (Optional)

1. Login to https://grafana.com/ (register if needed)
2. Access your settings page at https://grafana.com/orgs/<username>
3. In your Stack, find 'Manage your stack' page
4. Find 'OpenTelemetry' and click 'Configure'
5. Note the following values from the dashboard:
   ```
   Endpoint for sending OTLP signals: xxxx
   Instance ID: xxxxxxx
   Password / API Token: xxxxx
   ```

6. Export NOMAD environment variables:（Optional）
```bash
cat << EOF >> /opt/config.properties

# Grafana configuration
grafana_otel_collector_token=xxx
grafana_otlp_url=xxx
grafana_username=xxx
EOF

echo "Appended Grafana configuration to /opt/config.properties"
```

7. Deploy OpenTelemetry collector:（Optional）
```bash
bash nomad/deploy.sh otel-collector
```

8. Open Grafana Cloud Dashboard to view metrics, traces, and logs（Optional）

### 3. E2B Test

1. Create a template:
```bash
# There are three ways to create E2B templates:
# Create a template from e2bdev/code-interpreter 
bash packages/create_template.sh

# Create a template from a Dockerfile
bash packages/create_template.sh --docker-file <Docker_File_Path>

# Example for create a template of Desktop
bash packages/create_template.sh --docker-file test_use_case/Docckerfile/e2b.Dockerfile.Desktop

# Example for create a template of BrowserUse
bash packages/create_template.sh --docker-file test_use_case/Docckerfile/e2b.Dockerfile.BrowserUse

# Create a template from an ECR image that in your own account
bash packages/create_template.sh --ecr-image <ECR_IMAGE_URI>
```

2. Create a sandbox(Get the value of e2b_API to execute commands --- more ../infra-iac/db/config.json):
```bash
curl -X POST \
 https://api.<e2bdomain>/sandboxes \
 -H "X-API-Key: <e2b_API>" \
 -H 'Content-Type: application/json' \
 -d '{
        "templateID": "<template_ID>",
        "timeout": 3600,
        "autoPause": true,
        "metadata": {
            "purpose": "test"
        }
 }'
```

## Using E2B CLI

```bash
# Installation Guide: https://e2b.dev/docs/cli
# For macOS
brew install e2b

# Export environment variables(you can query the  accessToken and teamApiKey in /opt/config.properties)
export E2B_API_KEY=xxx
export E2B_ACCESS_TOKEN=xxx
export E2B_DOMAIN="<e2bdomain>"

# Common E2B CLI commands
# List all sandboxes
e2b sandbox list
 
# Connect to a sandbox
e2b sandbox connect <sandbox-id>
 
# Kill a sandbox
e2b sandbox kill <sandbox-id>
e2b sandbox kill --all
```

## E2B SDK Cookbook

```bash
git clone https://github.com/e2b-dev/e2b-cookbook.git
cd e2b-cookbook/examples/hello-world-python
poetry install

# Edit .env file
vim .env
# Change E2B_API_KEY value

poetry run start
```

## Troubleshooting

1. **No nodes were eligible for evaluation error when deploying applications**
   - Check node status and constraints

2. **Driver Failure: Failed to pull from ECR**
   - Error: `Failed to pull xxx.dkr.ecr.us-west-2.amazonaws.com/e2b-orchestration/api:latest: API error (404): pull access denied for xxx.dkr.ecr.us-west-2.amazonaws.com/e2b-orchestration/api, repository does not exist or may require 'docker login': denied: Your authorization token has expired. Reauthenticate and try again.`
   - Solution: Execute `aws ecr get-login-password --region us-east-1` to get a new ECR token and update the HCL file

3. For other unresolved issues, contact support

## Resource Cleanup Recommendations

When you need to delete the E2B environment, follow these steps:

1. **Terraform Resource Cleanup**:
   - Navigate to the Terraform directory: `cd ~/infra-iac/terraform/`
   - Run `terraform destroy` to remove infrastructure resources
   - **Note**: Some resources have deletion protection enabled and cannot be deleted directly:
     - **S3 Buckets**: You must manually empty these buckets before they can be deleted
     - **Application Load Balancers (ALB)**: These may require manual deletion through the AWS console

2. **CloudFormation Stack Cleanup**:
   - **RDS Database**: The database has deletion protection enabled for compliance reasons
     - First disable deletion protection through the RDS console
     - Then delete the CloudFormation stack

3. **Manual Resource Verification**:
   - After running the automated cleanup steps, verify in the AWS console that all resources have been properly removed
   - Check for any orphaned resources in:
     - EC2 (instances, security groups, load balancers)
     - S3 (buckets)
     - RDS (database instances)
     - ECR (container repositories)

## Appendix
## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This project is licensed under the Apache-2.0 License.

#### Application Image Configuration
