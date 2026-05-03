# =========================================================
# TERRAFORM CONFIGURATION AND DATA SOURCES
# =========================================================

# Get AWS account and region information for use in resource creation
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Define required Terraform providers and their versions
terraform {
  required_providers {
    # AWS provider for creating and managing AWS resources
    aws = {
      source  = "hashicorp/aws"
      version = "5.34.0"
    }
    # Random provider for generating random values (UUIDs, encryption keys, etc.)
    random = {
      source  = "hashicorp/random"
      version = "3.5.1"
    }
    # Null provider for running local-exec provisioners
    null = {
      source  = "hashicorp/null"
      version = "3.2.2"
    }
  }
}

# =========================================================
# LOCAL VARIABLES AND CONFIGURATION
# =========================================================

locals {
  # Extract account ID and region from data sources for use in resource configuration
  account_id = data.aws_caller_identity.current.account_id
  aws_region = data.aws_region.current.name
  
  # Calculate file hashes for setup scripts to detect changes and force updates
  file_hash = {
    "scripts/run-consul.sh"              = substr(filesha256("${path.module}/scripts/run-consul.sh"), 0, 5)
    "scripts/run-nomad.sh"               = substr(filesha256("${path.module}/scripts/run-nomad.sh"), 0, 5)
    "scripts/run-api-nomad.sh"           = substr(filesha256("${path.module}/scripts/run-api-nomad.sh"), 0, 5)
    "scripts/run-build-cluster-nomad.sh" = substr(filesha256("${path.module}/scripts/run-build-cluster-nomad.sh"), 0, 5)
  }

  # Define common resource tags to be applied to all resources
  common_tags = {
    Environment = var.environment
    Project     = "E2B"
    ManagedBy   = "Terraform"
  }
  
  # Define cluster configurations for different node types
  clusters = {
    # Server nodes run Consul and Nomad servers
    server = {
      instance_type_x86    = var.environment == "prod" ? "m7i.xlarge" : "t3.xlarge"
      instance_type_arm    = var.environment == "prod" ? "m7g.xlarge" : "t4g.xlarge"
      desired_capacity = 3
      max_size         = 3
      min_size         = 3
    }
    # Client nodes run workloads and containers
    client = {
      instance_type_x86    = var.client_instance_type
      instance_type_arm    = var.client_instance_type
      desired_capacity = 1
      max_size         = 5
      min_size         = 0
    }
    # API nodes run the API service
    api = {
      instance_type_x86    = var.environment == "prod" ? "m7i.4xlarge" : "t3.xlarge"
      instance_type_arm    = var.environment == "prod" ? "m7g.xlarge" : "t4g.xlarge"
      desired_capacity = 1
      max_size         = 1
      min_size         = 1
    }
    # Build nodes for environment building (currently not active)
    build = {
      instance_type_x86    = var.client_instance_type
      instance_type_arm    = var.client_instance_type
      desired_capacity = 0
      max_size         = 0
      min_size         = 0
    }
  }
}


# =========================================================
# AMI AND BASE INFRASTRUCTURE
# =========================================================

# Find the latest E2B base AMI to use for all instances
data "aws_ami" "e2b" {
  most_recent = true
  owners = [local.account_id]
  
  # Filter for AMIs with the specific naming pattern
  filter {
    name   = "name"
    values = ["e2b-ubuntu-ami-*"]
  }
}

# =========================================================
# S3 BUCKETS
# =========================================================

# Bucket for Loki log storage
resource "aws_s3_bucket" "loki_storage_bucket" {
  bucket = "${var.prefix}-loki-storage-${local.account_id}"
  force_destroy = var.environment == "prod" ? false : true
  tags = local.common_tags
}

# Bucket for Docker contexts used by environments
resource "aws_s3_bucket" "envs_docker_context" {
  bucket = "${var.prefix}-envs-docker-context-${local.account_id}"
  force_destroy = var.environment == "prod" ? false : true
  tags = local.common_tags
}

# Bucket for cluster setup scripts and configuration
resource "aws_s3_bucket" "setup_bucket" {
  bucket = "${var.prefix}-cluster-setup-${local.account_id}"
  force_destroy = var.environment == "prod" ? false : true
  tags = local.common_tags
}

# Bucket for Firecracker kernels
resource "aws_s3_bucket" "fc_kernels_bucket" {
  bucket = "${var.prefix}-fc-kernels-${local.account_id}"
  force_destroy = var.environment == "prod" ? false : true
  tags = local.common_tags
}

# Bucket for Firecracker versions
resource "aws_s3_bucket" "fc_versions_bucket" {
  bucket = "${var.prefix}-fc-versions-${local.account_id}"
  force_destroy = var.environment == "prod" ? false : true
  tags = local.common_tags
}

# Bucket for Firecracker environment pipeline artifacts
resource "aws_s3_bucket" "fc_env_pipeline_bucket" {
  bucket = "${var.prefix}-fc-env-pipeline-${local.account_id}"
  tags = local.common_tags
}

# Bucket for Firecracker templates
resource "aws_s3_bucket" "fc_template_bucket" {
  bucket = "${var.prefix}-fc-template-${local.account_id}"
  tags = local.common_tags
}

# Bucket for Docker contexts
resource "aws_s3_bucket" "docker_contexts_bucket" {
  bucket = "${var.prefix}-docker-contexts-${local.account_id}"
  tags = local.common_tags
}

# ---------------------------------------------------------
# S3 Bucket Security Hardening
# ---------------------------------------------------------

locals {
  all_buckets = {
    loki_storage     = aws_s3_bucket.loki_storage_bucket.id
    envs_docker_ctx  = aws_s3_bucket.envs_docker_context.id
    setup            = aws_s3_bucket.setup_bucket.id
    fc_kernels       = aws_s3_bucket.fc_kernels_bucket.id
    fc_versions      = aws_s3_bucket.fc_versions_bucket.id
    fc_env_pipeline  = aws_s3_bucket.fc_env_pipeline_bucket.id
    fc_template      = aws_s3_bucket.fc_template_bucket.id
    docker_contexts  = aws_s3_bucket.docker_contexts_bucket.id
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "bucket_encryption" {
  for_each = local.all_buckets
  bucket   = each.value

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "bucket_versioning" {
  for_each = local.all_buckets
  bucket   = each.value

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "bucket_public_access" {
  for_each = local.all_buckets
  bucket   = each.value

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# =========================================================
# SECRETS MANAGEMENT
# =========================================================

# -------------------- Consul ACL Token --------------------
# Secret for storing the Consul ACL token used for authentication and authorization
resource "aws_secretsmanager_secret" "consul_acl_token" {
  name = "${var.prefix}-consul-secret-id"
  tags = local.common_tags
}

# Generate a random UUID for the Consul ACL token
resource "random_uuid" "consul_acl_token" {}

# Store the generated UUID in the secret
resource "aws_secretsmanager_secret_version" "consul_acl_token" {
  secret_id     = aws_secretsmanager_secret.consul_acl_token.id
  secret_string = random_uuid.consul_acl_token.result
}

# -------------------- Nomad ACL Token --------------------
# Secret for storing the Nomad ACL token used for authentication and authorization
resource "aws_secretsmanager_secret" "nomad_acl_token" {
  name = "${var.prefix}-nomad-secret-id"
  tags = local.common_tags
}

# Generate a random UUID for the Nomad ACL token
resource "random_uuid" "nomad_acl_token" {}

# Store the generated UUID in the secret
resource "aws_secretsmanager_secret_version" "nomad_acl_token" {
  secret_id     = aws_secretsmanager_secret.nomad_acl_token.id
  secret_string = random_uuid.nomad_acl_token.result
}

# -------------------- Consul Gossip Encryption Key --------------------
# Secret for storing the Consul gossip encryption key for secure node-to-node communication
resource "aws_secretsmanager_secret" "consul_gossip_encryption_key" {
  name        = "${var.prefix}-consul-gossip-key"
  description = "Consul gossip encryption key"
  tags        = local.common_tags
}

# Generate a random 32-byte key for Consul gossip encryption
resource "random_id" "consul_gossip_encryption_key" {
  byte_length = 32
}

# Store the generated key in the secret
resource "aws_secretsmanager_secret_version" "consul_gossip_encryption_key" {
  secret_id     = aws_secretsmanager_secret.consul_gossip_encryption_key.id
  secret_string = random_id.consul_gossip_encryption_key.b64_std
}

# -------------------- Consul DNS Request Token --------------------
# Secret for storing the Consul DNS request token for DNS query authentication
resource "aws_secretsmanager_secret" "consul_dns_request_token" {
  name        = "${var.prefix}-consul-dns-request-token"
  description = "Consul DNS request token"
  tags        = local.common_tags
}

# Generate a random UUID for the Consul DNS request token
resource "random_uuid" "consul_dns_request_token" {
}

# Store the generated UUID in the secret
resource "aws_secretsmanager_secret_version" "consul_dns_request_token" {
  secret_id     = aws_secretsmanager_secret.consul_dns_request_token.id
  secret_string = random_uuid.consul_dns_request_token.result
}

# -------------------- Admin Token --------------------
# Generate a random password for the admin API token
resource "random_password" "admin_token" {
  length           = 30
  special          = true
  override_special = "!@#$%^&*()_+{}|:<>?=-"
}

# -------------------- Sandbox Access Token Hash Seed --------------------
# Dedicated HMAC seed for generating sandbox access tokens, separate from admin_token
resource "random_password" "sandbox_access_token_hash_seed" {
  length  = 32
  special = false
}

# -------------------- Infra Tokens (aggregated) --------------------
# Aggregated secret containing nomad_acl_token, consul_http_token, admin_token, and sandbox seed
resource "aws_secretsmanager_secret" "infra_tokens" {
  name        = "${var.prefix}-infra-tokens"
  description = "Infrastructure tokens (nomad_acl_token, consul_http_token, admin_token, sandbox_access_token_hash_seed)"
  tags        = local.common_tags
}

resource "aws_secretsmanager_secret_version" "infra_tokens" {
  secret_id = aws_secretsmanager_secret.infra_tokens.id
  secret_string = jsonencode({
    nomad_acl_token                = random_uuid.nomad_acl_token.result
    consul_http_token              = random_uuid.consul_acl_token.result
    admin_token                    = random_password.admin_token.result
    sandbox_access_token_hash_seed = random_password.sandbox_access_token_hash_seed.result
  })
}

# -------------------- E2B Config --------------------
# Empty secret container for E2B configuration (populated by init-config.sh at runtime)
resource "aws_secretsmanager_secret" "e2b_config" {
  name        = "${var.prefix}-e2b-config"
  description = "E2B configuration (teamId, accessToken, teamApiKey)"
  tags        = local.common_tags
}

# =========================================================
# NOMAD TLS CERTIFICATES
# =========================================================

# CA Private Key
resource "tls_private_key" "nomad_ca" {
  algorithm = "ECDSA"
  ecdsa_curve = "P384"
}

# Self-signed CA Certificate
resource "tls_self_signed_cert" "nomad_ca" {
  private_key_pem = tls_private_key.nomad_ca.private_key_pem

  subject {
    common_name  = "Nomad CA"
    organization = "E2B"
  }

  validity_period_hours = 87600 # 10 years
  is_ca_certificate     = true

  allowed_uses = [
    "cert_signing",
    "crl_signing",
  ]
}

# Server Private Key
resource "tls_private_key" "nomad_server" {
  algorithm = "ECDSA"
  ecdsa_curve = "P384"
}

# Server Certificate Signing Request
resource "tls_cert_request" "nomad_server" {
  private_key_pem = tls_private_key.nomad_server.private_key_pem

  subject {
    common_name  = "server.${local.aws_region}.nomad"
    organization = "E2B"
  }

  dns_names = [
    "server.${local.aws_region}.nomad",
    "server.global.nomad",
    "server.${local.aws_region}.consul",
    "localhost",
  ]

  ip_addresses = ["127.0.0.1"]
}

# Server Certificate signed by CA
resource "tls_locally_signed_cert" "nomad_server" {
  cert_request_pem   = tls_cert_request.nomad_server.cert_request_pem
  ca_private_key_pem = tls_private_key.nomad_ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.nomad_ca.cert_pem

  validity_period_hours = 43800 # 5 years

  allowed_uses = [
    "digital_signature",
    "key_encipherment",
    "server_auth",
    "client_auth",
  ]
}

# Client Private Key
resource "tls_private_key" "nomad_client" {
  algorithm = "ECDSA"
  ecdsa_curve = "P384"
}

# Client Certificate Signing Request
resource "tls_cert_request" "nomad_client" {
  private_key_pem = tls_private_key.nomad_client.private_key_pem

  subject {
    common_name  = "client.${local.aws_region}.nomad"
    organization = "E2B"
  }

  dns_names = [
    "client.${local.aws_region}.nomad",
    "client.${local.aws_region}.consul",
    "localhost",
  ]

  ip_addresses = ["127.0.0.1"]
}

# Client Certificate signed by CA
resource "tls_locally_signed_cert" "nomad_client" {
  cert_request_pem   = tls_cert_request.nomad_client.cert_request_pem
  ca_private_key_pem = tls_private_key.nomad_ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.nomad_ca.cert_pem

  validity_period_hours = 43800 # 5 years

  allowed_uses = [
    "digital_signature",
    "key_encipherment",
    "server_auth",
    "client_auth",
  ]
}

# Store certificates in Secrets Manager
resource "aws_secretsmanager_secret" "nomad_tls_ca_cert" {
  name = "${var.prefix}-nomad-tls-ca-cert"
  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "nomad_tls_ca_cert" {
  secret_id     = aws_secretsmanager_secret.nomad_tls_ca_cert.id
  secret_string = tls_self_signed_cert.nomad_ca.cert_pem
}

resource "aws_secretsmanager_secret" "nomad_tls_server_cert" {
  name = "${var.prefix}-nomad-tls-server-cert"
  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "nomad_tls_server_cert" {
  secret_id     = aws_secretsmanager_secret.nomad_tls_server_cert.id
  secret_string = tls_locally_signed_cert.nomad_server.cert_pem
}

resource "aws_secretsmanager_secret" "nomad_tls_server_key" {
  name = "${var.prefix}-nomad-tls-server-key"
  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "nomad_tls_server_key" {
  secret_id     = aws_secretsmanager_secret.nomad_tls_server_key.id
  secret_string = tls_private_key.nomad_server.private_key_pem
}

resource "aws_secretsmanager_secret" "nomad_tls_client_cert" {
  name = "${var.prefix}-nomad-tls-client-cert"
  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "nomad_tls_client_cert" {
  secret_id     = aws_secretsmanager_secret.nomad_tls_client_cert.id
  secret_string = tls_locally_signed_cert.nomad_client.cert_pem
}

resource "aws_secretsmanager_secret" "nomad_tls_client_key" {
  name = "${var.prefix}-nomad-tls-client-key"
  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "nomad_tls_client_key" {
  secret_id     = aws_secretsmanager_secret.nomad_tls_client_key.id
  secret_string = tls_private_key.nomad_client.private_key_pem
}

# =========================================================
# IAM ROLES AND POLICIES
# =========================================================

# Define IAM policy for EC2 instances to have monitoring and logging access
resource "aws_iam_policy" "monitoring_policy" {
  name        = "${var.prefix}-monitoring-policy"
  description = "Policy for EC2 instances to have monitoring and logging access"
  
  # Policy document defining permissions for CloudWatch metrics and logs
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      # CloudWatch metrics permissions
      {
        Effect = "Allow",
        Action = [
          "cloudwatch:PutMetricData",
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics"
        ],
        Resource = "*"
      },
      # CloudWatch logs and EC2 describe permissions
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
          "ec2:DescribeInstances",
          "ec2:DescribeTags"
        ],
        Resource = "*"
      }
    ]
  })

  tags = local.common_tags
}

# Create IAM Role for EC2 instances
resource "aws_iam_role" "infra_instances_role" {
  name                 = "${var.prefix}-infra-instances-role"
  permissions_boundary = "arn:aws:iam::${local.account_id}:policy/${var.prefix}-e2b-permissions-boundary"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })

  tags = local.common_tags
}

# Scoped S3 access policy - restricted to project-specific buckets
resource "aws_iam_role_policy" "s3_scoped_access" {
  name = "${var.prefix}-s3-scoped-access"
  role = aws_iam_role.infra_instances_role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3BucketAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:ListBucketMultipartUploads",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts"
        ]
        Resource = [
          "arn:aws:s3:::${var.prefix}-*",
          "arn:aws:s3:::${var.prefix}-*/*",
          "arn:aws:s3:::software-${var.prefix}-*",
          "arn:aws:s3:::software-${var.prefix}-*/*"
        ]
      },
      {
        Sid    = "KMSDecryptAccess"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = "*"
      }
    ]
  })
}

# Scoped ECR access policy - restricted to e2b repositories
resource "aws_iam_role_policy" "ecr_scoped_access" {
  name = "${var.prefix}-ecr-scoped-access"
  role = aws_iam_role.infra_instances_role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAuth"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Sid    = "ECRRepositoryAccess"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchDeleteImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:CreateRepository",
          "ecr:DescribeRepositories",
          "ecr:ListImages",
          "ecr:DescribeImages",
          "ecr:TagResource"
        ]
        Resource = "arn:aws:ecr:*:${local.account_id}:repository/e2b*"
      }
    ]
  })
}

# Scoped Secrets Manager access policy - read-only for e2b secrets
resource "aws_iam_role_policy" "secrets_manager_scoped_access" {
  name = "${var.prefix}-secrets-manager-scoped-access"
  role = aws_iam_role.infra_instances_role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SecretsManagerReadAccess"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecrets"
        ]
        Resource = "arn:aws:secretsmanager:*:${local.account_id}:secret:*e2b*"
      }
    ]
  })
}

# Attach SSM access policy for Systems Manager access
resource "aws_iam_role_policy_attachment" "ssm_managed_instance_core" {
  role       = aws_iam_role.infra_instances_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Get the IAM role name from the ARN
locals {
  iam_role_name = aws_iam_role.infra_instances_role.name
}

# Attach the monitoring policy to the role
resource "aws_iam_role_policy_attachment" "monitoring_policy_attachment" {
  role       = local.iam_role_name
  policy_arn = aws_iam_policy.monitoring_policy.arn
}

# Create IAM instance profile for EC2 instances
resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "${var.prefix}-ec2-instance-profile"
  role = local.iam_role_name
}


# Setup files to be uploaded to S3
variable "setup_files" {
  type = map(string)
  default = {
    "scripts/run-nomad.sh"               = "run-nomad",
    "scripts/run-api-nomad.sh"           = "run-api-nomad",
    "scripts/run-build-cluster-nomad.sh" = "run-build-cluster-nomad",
    "scripts/run-consul.sh"              = "run-consul"
  }
}

# Upload setup scripts to S3
resource "aws_s3_object" "setup_config_objects" {
  for_each = var.setup_files
  bucket   = aws_s3_bucket.setup_bucket.bucket
  key      = "${each.value}-${local.file_hash[each.key]}.sh"
  source   = "${path.module}/${each.key}"
  etag     = filemd5("${path.module}/${each.key}")
}

# Security group for server instances
resource "aws_security_group" "server_sg" {
  name        = "${var.prefix}-server-sg"
  description = "Security group for server instances"
  vpc_id      = var.VPC.id

  # Consul ports
  ingress {
    from_port   = 8300
    to_port     = 8302
    protocol    = "tcp"
    cidr_blocks = [var.VPC.CIDR]
  }

  # Allow all inbound traffic
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.VPC.CIDR]
  }

  # Nomad ports - restricted to VPC CIDR only
  ingress {
    from_port   = 4646
    to_port     = 4646
    protocol    = "tcp"
    cidr_blocks = [var.VPC.CIDR]
  }

  # Allow outbound to VPC
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.VPC.CIDR]
  }

  # Allow HTTP outbound for apt/package updates via NAT
  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow HTTPS outbound for ECR/S3/API access via NAT
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    local.common_tags,
    {
      Name = "${var.prefix}-server-sg"
    }
  )
}

# Create server cluster instances in an Auto Scaling Group
resource "aws_launch_template" "server" {
  name_prefix            = "${var.prefix}-server-"
  update_default_version = true
  image_id               = data.aws_ami.e2b.id
  instance_type          = var.architecture == "x86_64" ? local.clusters.server.instance_type_x86 : local.clusters.server.instance_type_arm
  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_instance_profile.name
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_size           = 100
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.server_sg.id]
  }

  user_data = base64encode(templatefile("${path.module}/scripts/start-server.sh", {
    NUM_SERVERS                  = 3
    CLUSTER_TAG_NAME             = "server-cluster"
    SCRIPTS_BUCKET               = aws_s3_bucket.setup_bucket.bucket
    NOMAD_SECRET_NAME            = aws_secretsmanager_secret.nomad_acl_token.name
    CONSUL_SECRET_NAME           = aws_secretsmanager_secret.consul_acl_token.name
    RUN_CONSUL_FILE_HASH         = local.file_hash["scripts/run-consul.sh"]
    RUN_NOMAD_FILE_HASH          = local.file_hash["scripts/run-nomad.sh"]
    CONSUL_GOSSIP_SECRET_NAME    = aws_secretsmanager_secret.consul_gossip_encryption_key.name
    NOMAD_TLS_CA_SECRET          = aws_secretsmanager_secret.nomad_tls_ca_cert.name
    NOMAD_TLS_CERT_SECRET        = aws_secretsmanager_secret.nomad_tls_server_cert.name
    NOMAD_TLS_KEY_SECRET         = aws_secretsmanager_secret.nomad_tls_server_key.name
    AWS_REGION                   = local.aws_region
    AWS_ACCOUNT_ID               = local.account_id
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(
      local.common_tags,
      {
        Name        = "server-cluster",
        ec2-e2b-key = "ec2-e2b-value",
        team        = "GENAI",
        service     = "GENAI",
        owner       = "GENAI",
        cost_center = "GENAI",
        component   = "GENAI"
      }
    )
  }

  depends_on = [aws_s3_object.setup_config_objects]
}

# Create server auto scaling group
resource "aws_autoscaling_group" "server" {
  name                = "${var.prefix}-server-asg"
  vpc_zone_identifier = var.VPC.private_subnets
  desired_capacity    = local.clusters.server.desired_capacity
  max_size            = local.clusters.server.max_size
  min_size            = local.clusters.server.min_size

  launch_template {
    id      = aws_launch_template.server.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.prefix}-server"
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = local.common_tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}

# Security group for client instances
resource "aws_security_group" "client_sg" {
  name        = "${var.prefix}-client-sg"
  description = "Security group for client instances"
  vpc_id      = var.VPC.id

  # Consul ports
  ingress {
    from_port   = 8300
    to_port     = 8302
    protocol    = "tcp"
    cidr_blocks = [var.VPC.CIDR]
  }

  # Nomad ports
  ingress {
    from_port   = 4646
    to_port     = 4646
    protocol    = "tcp"
    cidr_blocks = [var.VPC.CIDR]
  }

  # Allow all inbound traffic
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.VPC.CIDR]
  }

  # Allow outbound to VPC
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.VPC.CIDR]
  }

  # Allow HTTP outbound for apt/package updates via NAT
  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow HTTPS outbound for ECR/S3/API access via NAT
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow DNS outbound (UDP) for microVM DNS resolution
  egress {
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow DNS outbound (TCP) for large DNS responses
  egress {
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    local.common_tags,
    {
      Name = "${var.prefix}-client-sg"
    }
  )
}

# Create client cluster instances in an Auto Scaling Group
resource "aws_launch_template" "client" {
  name_prefix            = "${var.prefix}-client-"
  update_default_version = true
  image_id      = data.aws_ami.e2b.id
  instance_type = var.architecture == "x86_64" ? local.clusters.client.instance_type_x86 : local.clusters.client.instance_type_arm

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_instance_profile.name
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_size           = 300
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  block_device_mappings {
    device_name = "/dev/sda2"

    ebs {
      volume_size           = 500
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.client_sg.id]
  }

  user_data = base64encode(templatefile("${path.module}/scripts/start-client.sh", {
    CLUSTER_TAG_NAME             = "client-cluster"
    SCRIPTS_BUCKET               = aws_s3_bucket.setup_bucket.bucket
    FC_KERNELS_BUCKET_NAME       = aws_s3_bucket.fc_kernels_bucket.bucket
    FC_VERSIONS_BUCKET_NAME      = aws_s3_bucket.fc_versions_bucket.bucket
    FC_ENV_PIPELINE_BUCKET_NAME  = aws_s3_bucket.fc_env_pipeline_bucket.bucket
    DOCKER_CONTEXTS_BUCKET_NAME  = aws_s3_bucket.docker_contexts_bucket.bucket
    AWS_REGION                   = local.aws_region
    AWS_ACCOUNT_ID               = local.account_id
    NOMAD_SECRET_NAME            = aws_secretsmanager_secret.nomad_acl_token.name
    CONSUL_SECRET_NAME           = aws_secretsmanager_secret.consul_acl_token.name
    RUN_CONSUL_FILE_HASH         = local.file_hash["scripts/run-consul.sh"]
    RUN_NOMAD_FILE_HASH          = local.file_hash["scripts/run-nomad.sh"]
    CONSUL_GOSSIP_SECRET_NAME    = aws_secretsmanager_secret.consul_gossip_encryption_key.name
    CONSUL_DNS_SECRET_NAME       = aws_secretsmanager_secret.consul_dns_request_token.name
    NOMAD_TLS_CA_SECRET          = aws_secretsmanager_secret.nomad_tls_ca_cert.name
    NOMAD_TLS_CERT_SECRET        = aws_secretsmanager_secret.nomad_tls_client_cert.name
    NOMAD_TLS_KEY_SECRET         = aws_secretsmanager_secret.nomad_tls_client_key.name
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(
      local.common_tags,
      {
        Name        = "client-cluster",
        ec2-e2b-key = "ec2-e2b-value",
        team        = "GENAI",
        service     = "GENAI",
        owner       = "GENAI",
        cost_center = "GENAI",
        component   = "GENAI"
      }
    )
  }

  depends_on = [aws_s3_object.setup_config_objects]
}

# Create a new launch template version with NestedVirtualization enabled via AWS CLI
# Terraform AWS provider does not support the NestedVirtualization parameter in cpu_options
resource "null_resource" "client_nested_virtualization" {
  count = endswith(var.client_instance_type, ".metal") ? 0 : 1

  triggers = {
    launch_template_id      = aws_launch_template.client.id
    launch_template_version = aws_launch_template.client.latest_version
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws ec2 create-launch-template-version \
        --launch-template-id ${aws_launch_template.client.id} \
        --source-version ${aws_launch_template.client.latest_version} \
        --launch-template-data '{"CpuOptions":{"NestedVirtualization":"enabled"}}'
    EOT
  }
}

# Create client auto scaling group
resource "aws_autoscaling_group" "client" {
  name                = "${var.prefix}-client-asg"
  vpc_zone_identifier = var.VPC.private_subnets
  # desired_capacity    = var.client_asg_desired_capacity
  # max_size            = max(var.client_asg_max_size, var.client_asg_desired_capacity)
  # min_size            = var.client_asg_desired_capacity
  desired_capacity = local.clusters.client.desired_capacity
  max_size         = local.clusters.client.max_size
  min_size         = local.clusters.client.min_size

  launch_template {
    id      = aws_launch_template.client.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.prefix}-client"
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = local.common_tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}

# Security group for API instances
resource "aws_security_group" "api_sg" {
  name        = "${var.prefix}-api-sg"
  description = "Security group for API instances"
  vpc_id      = var.VPC.id

  # Consul ports
  ingress {
    from_port   = 8300
    to_port     = 8302
    protocol    = "tcp"
    cidr_blocks = [var.VPC.CIDR]
  }

  # Nomad ports - restricted to VPC CIDR only
  ingress {
    from_port   = 4646
    to_port     = 4646
    protocol    = "tcp"
    cidr_blocks = [var.VPC.CIDR]
  }

  # API port - restricted to VPC CIDR only (accessed via ALB)
  ingress {
    from_port   = 50001
    to_port     = 50001
    protocol    = "tcp"
    cidr_blocks = [var.VPC.CIDR]
  }

  # Client proxy health check port
  ingress {
    from_port   = 3001
    to_port     = 3001
    protocol    = "tcp"
    cidr_blocks = [var.VPC.CIDR]
  }

  # Client proxy service port
  ingress {
    from_port   = 3002
    to_port     = 3002
    protocol    = "tcp"
    cidr_blocks = [var.VPC.CIDR]
  }

  # Allow all inbound traffic
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.VPC.CIDR]
  }

  # Allow outbound to VPC
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.VPC.CIDR]
  }

  # Allow HTTP outbound for apt/package updates via NAT
  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow HTTPS outbound for ECR/S3/API access via NAT
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    local.common_tags,
    {
      Name = "${var.prefix}-api-sg"
    }
  )
}

# Create Application Load Balancer
resource "aws_lb" "alb" {
  name               = "${var.prefix}-alb"
  internal           = var.publicaccess == "private" ? true : false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = var.publicaccess == "private" ? var.VPC.private_subnets : var.VPC.public_subnets
  enable_deletion_protection = var.environment == "prod" ? true : false
  
  tags = merge(
    local.common_tags,
    {
      Name = "${var.prefix}-alb"
    }
  )
}

# Security group for ALB
resource "aws_security_group" "alb_sg" {
  name        = "${var.prefix}-alb-sg"
  description = "Security group for ALB"
  vpc_id      = var.VPC.id

  # HTTP
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow outbound to VPC only (ALB connects to backend instances)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.VPC.CIDR]
  }

  tags = merge(
    local.common_tags,
    {
      Name = "${var.prefix}-alb-sg"
    }
  )
}

# Create target group for Nomad server UI
resource "aws_lb_target_group" "nomad-server" {
  name     = "${var.prefix}-nomad-server"
  port     = 4646
  protocol = "HTTPS"
  vpc_id   = var.VPC.id

  health_check {
    enabled             = true
    path                = "/ui/"
    interval            = 30
    protocol            = "HTTPS"
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }

  lifecycle {
    create_before_destroy = true
  }
  
  tags = local.common_tags
}

# Attach server ASG to Nomad server target group
resource "aws_autoscaling_attachment" "nomad-server" {
  autoscaling_group_name = aws_autoscaling_group.server.name
  lb_target_group_arn    = aws_lb_target_group.nomad-server.arn
}

# Create target group for E2B API
resource "aws_lb_target_group" "e2b-api" {
  name     = "${var.prefix}-e2b-api"
  port     = 50001
  protocol = "HTTP"
  vpc_id   = var.VPC.id

  health_check {
    enabled             = true
    path                = "/health"
    interval            = 30
    protocol            = "HTTP"
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }

  lifecycle {
    create_before_destroy = true
  }
  
  tags = local.common_tags
}

# Attach API ASG to E2B API target group
resource "aws_autoscaling_attachment" "e2b-api" {
  autoscaling_group_name = aws_autoscaling_group.api.name
  lb_target_group_arn    = aws_lb_target_group.e2b-api.arn
}

# Create target group for client proxy service
resource "aws_lb_target_group" "client-proxy" {
  name     = "${var.prefix}-client-proxy"
  port     = 3002
  protocol = "HTTP"
  vpc_id   = var.VPC.id

  health_check {
    port                = 3001
    enabled             = true
    path                = "/health"
    interval            = 30
    protocol            = "HTTP"
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }

  lifecycle {
    create_before_destroy = true
  }
  
  tags = local.common_tags
}

# Attach API ASG to client proxy target group
resource "aws_autoscaling_attachment" "client-proxy" {
  autoscaling_group_name = aws_autoscaling_group.api.name
  lb_target_group_arn    = aws_lb_target_group.client-proxy.arn
}

# Create target group for Docker proxy service
resource "aws_lb_target_group" "docker-proxy" {
  name     = "${var.prefix}-docker-proxy"
  port     = 5000
  protocol = "HTTP"
  vpc_id   = var.VPC.id

  health_check {
    enabled             = true
    path                = "/health"
    interval            = 30
    protocol            = "HTTP"
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }

  lifecycle {
    create_before_destroy = true
  }
  
  tags = local.common_tags
}

# Attach api ASG to Docker proxy target group
resource "aws_autoscaling_attachment" "docker-proxy" {
  autoscaling_group_name = aws_autoscaling_group.api.name
  lb_target_group_arn    = aws_lb_target_group.docker-proxy.arn
}

# Create HTTP listener for ALB with default action to client-proxy
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certarn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.client-proxy.arn
  }
}

# Create HTTPS listener for ALB (commented out as it requires a certificate)
# resource "aws_lb_listener" "https" {
#   load_balancer_arn = aws_lb.alb.arn
#   port              = 443
#   protocol          = "HTTPS"
#   ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
#   certificate_arn   = var.certarn
#   
#   default_action {
#     type             = "forward"
#     target_group_arn = aws_lb_target_group.client-proxy.arn
#   }
# }

# Create listener rule for API subdomain
resource "aws_lb_listener_rule" "api" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.e2b-api.arn
  }
  
  condition {
    host_header {
      values = ["api.${var.domainname}"]
    }
  }
}

# Create listener rule for Docker subdomain
resource "aws_lb_listener_rule" "docker" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.docker-proxy.arn
  }
  
  condition {
    host_header {
      values = ["docker.${var.domainname}"]
    }
  }
}

# Create listener rule for Nomad subdomain
resource "aws_lb_listener_rule" "nomad" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 30

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nomad-server.arn
  }
  
  condition {
    host_header {
      values = ["nomad.${var.domainname}"]
    }
  }
}

# Create API cluster instances in an Auto Scaling Group
resource "aws_launch_template" "api" {
  name_prefix            = "${var.prefix}-api-"
  update_default_version = true
  image_id               = data.aws_ami.e2b.id
  instance_type          = var.architecture == "x86_64" ? local.clusters.api.instance_type_x86 : local.clusters.api.instance_type_arm
  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_instance_profile.name
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_size           = 100
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.api_sg.id]
  }

  user_data = base64encode(templatefile("${path.module}/scripts/start-api.sh", {
    CLUSTER_TAG_NAME             = "api-cluster"
    SCRIPTS_BUCKET               = aws_s3_bucket.setup_bucket.bucket
    FC_KERNELS_BUCKET_NAME       = aws_s3_bucket.fc_kernels_bucket.bucket
    FC_VERSIONS_BUCKET_NAME      = aws_s3_bucket.fc_versions_bucket.bucket
    FC_ENV_PIPELINE_BUCKET_NAME  = aws_s3_bucket.fc_env_pipeline_bucket.bucket
    DOCKER_CONTEXTS_BUCKET_NAME  = aws_s3_bucket.docker_contexts_bucket.bucket
    AWS_REGION                   = local.aws_region
    AWS_ACCOUNT_ID               = local.account_id
    NOMAD_SECRET_NAME            = aws_secretsmanager_secret.nomad_acl_token.name
    CONSUL_SECRET_NAME           = aws_secretsmanager_secret.consul_acl_token.name
    RUN_CONSUL_FILE_HASH         = local.file_hash["scripts/run-consul.sh"]
    RUN_NOMAD_FILE_HASH          = local.file_hash["scripts/run-api-nomad.sh"]
    CONSUL_GOSSIP_SECRET_NAME    = aws_secretsmanager_secret.consul_gossip_encryption_key.name
    CONSUL_DNS_SECRET_NAME       = aws_secretsmanager_secret.consul_dns_request_token.name
    NOMAD_TLS_CA_SECRET          = aws_secretsmanager_secret.nomad_tls_ca_cert.name
    NOMAD_TLS_CERT_SECRET        = aws_secretsmanager_secret.nomad_tls_client_cert.name
    NOMAD_TLS_KEY_SECRET         = aws_secretsmanager_secret.nomad_tls_client_key.name
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(
      local.common_tags,
      {
        Name        = "api-cluster",
        ec2-e2b-key = "ec2-e2b-value",
        team        = "GENAI",
        service     = "GENAI",
        owner       = "GENAI",
        cost_center = "GENAI",
        component   = "GENAI"
      }
    )
  }

  depends_on = [aws_s3_object.setup_config_objects]
}

# Create API auto scaling group
resource "aws_autoscaling_group" "api" {
  name                = "${var.prefix}-api-asg"
  vpc_zone_identifier = var.VPC.private_subnets
  # desired_capacity    = var.api_asg_desired_capacity
  # max_size            = var.api_asg_desired_capacity
  # min_size            = var.api_asg_desired_capacity
  desired_capacity  = local.clusters.api.desired_capacity
  max_size          = local.clusters.api.max_size
  min_size          = local.clusters.api.min_size
  target_group_arns = [aws_lb_target_group.e2b-api.arn]

  launch_template {
    id      = aws_launch_template.api.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.prefix}-api"
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = local.common_tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}



# Security group for build instances
resource "aws_security_group" "build_sg" {
  name        = "${var.prefix}-build-sg"
  description = "Security group for build instances"
  vpc_id      = var.VPC.id

  # Consul ports
  ingress {
    from_port   = 8300
    to_port     = 8302
    protocol    = "tcp"
    cidr_blocks = [var.VPC.CIDR]
  }

  # Nomad ports
  ingress {
    from_port   = 4646
    to_port     = 4646
    protocol    = "tcp"
    cidr_blocks = [var.VPC.CIDR]
  }

  # Docker reverse proxy port
  ingress {
    from_port   = 5000
    to_port     = 5000
    protocol    = "tcp"
    cidr_blocks = [var.VPC.CIDR]
  }

  # Allow all inbound traffic
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.VPC.CIDR]
  }

  # Allow outbound to VPC
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.VPC.CIDR]
  }

  # Allow HTTP outbound for apt/package updates via NAT
  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow HTTPS outbound for ECR/S3/API access via NAT
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow DNS outbound (UDP) for microVM DNS resolution
  egress {
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow DNS outbound (TCP) for large DNS responses
  egress {
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    local.common_tags,
    {
      Name = "${var.prefix}-build-sg"
    }
  )
}

# Create build cluster instances in an Auto Scaling Group
resource "aws_launch_template" "build" {
  name_prefix            = "${var.prefix}-build-"
  update_default_version = true
  image_id               = data.aws_ami.e2b.id
  instance_type          = var.architecture == "x86_64" ? local.clusters.build.instance_type_x86 : local.clusters.build.instance_type_arm
  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_instance_profile.name
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_size           = 100
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.build_sg.id]
  }

  user_data = base64encode(templatefile("${path.module}/scripts/start-build-cluster.sh", {
    CLUSTER_TAG_NAME             = "build-cluster"
    SCRIPTS_BUCKET               = aws_s3_bucket.setup_bucket.bucket
    FC_KERNELS_BUCKET_NAME       = aws_s3_bucket.fc_kernels_bucket.bucket
    FC_VERSIONS_BUCKET_NAME      = aws_s3_bucket.fc_versions_bucket.bucket
    FC_ENV_PIPELINE_BUCKET_NAME  = aws_s3_bucket.fc_env_pipeline_bucket.bucket
    DOCKER_CONTEXTS_BUCKET_NAME  = aws_s3_bucket.docker_contexts_bucket.bucket
    AWS_REGION                   = local.aws_region
    AWS_ACCOUNT_ID               = local.account_id
    NOMAD_SECRET_NAME            = aws_secretsmanager_secret.nomad_acl_token.name
    CONSUL_SECRET_NAME           = aws_secretsmanager_secret.consul_acl_token.name
    RUN_CONSUL_FILE_HASH         = local.file_hash["scripts/run-consul.sh"]
    RUN_NOMAD_FILE_HASH          = local.file_hash["scripts/run-build-cluster-nomad.sh"]
    CONSUL_GOSSIP_SECRET_NAME    = aws_secretsmanager_secret.consul_gossip_encryption_key.name
    CONSUL_DNS_SECRET_NAME       = aws_secretsmanager_secret.consul_dns_request_token.name
    NOMAD_TLS_CA_SECRET          = aws_secretsmanager_secret.nomad_tls_ca_cert.name
    NOMAD_TLS_CERT_SECRET        = aws_secretsmanager_secret.nomad_tls_client_cert.name
    NOMAD_TLS_KEY_SECRET         = aws_secretsmanager_secret.nomad_tls_client_key.name
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(
      local.common_tags,
      {
        Name        = "build-cluster",
        ec2-e2b-key = "ec2-e2b-value",
        team        = "GENAI",
        service     = "GENAI",
        owner       = "GENAI",
        cost_center = "GENAI",
        component   = "GENAI"
      }
    )
  }

  depends_on = [aws_s3_object.setup_config_objects]
}

# Create build auto scaling group
resource "aws_autoscaling_group" "build" {
  name                = "${var.prefix}-build-asg"
  vpc_zone_identifier = var.VPC.private_subnets
  # desired_capacity    = var.build_asg_desired_capacity
  # max_size            = var.build_asg_desired_capacity
  # min_size            = var.build_asg_desired_capacity
  desired_capacity = local.clusters.build.desired_capacity
  max_size         = local.clusters.build.max_size
  min_size         = local.clusters.build.min_size

  launch_template {
    id      = aws_launch_template.build.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.prefix}-build"
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = local.common_tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}

