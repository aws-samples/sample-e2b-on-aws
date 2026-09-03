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
      version = "~> 5.82"
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
    # Archive provider: zips the drain-warden Lambda sources at plan time, so the
    # functions have no build step of their own.
    archive = {
      source  = "hashicorp/archive"
      version = "2.8.0"
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
    "scripts/run-custom-script.sh"       = substr(filesha256("${path.module}/scripts/run-custom-script.sh"), 0, 5)
  }

  # Define common resource tags to be applied to all resources
  common_tags = {
    Environment = var.environment
    Project     = "E2B"
    ManagedBy   = "Terraform"
  }
  
  # Instance types for the two Firecracker-hosting pools. Declared here rather
  # than taken from var.client_instance_type (which carries the stack's
  # CFNCLIENTINSTANCETYPE parameter) because changing that would require a
  # CloudFormation stack update. data.aws_ec2_instance_type below reads the same
  # locals, so the bare-metal detection can never drift from what the ASG runs.

  # Client nodes host customer sandboxes. Bare metal, so Firecracker gets
  # hardware virtualization directly.
  #
  # The size floor is not ours to choose: a sandbox may only be placed on a node
  # whose CPU model matches the one its template was built on
  # (shared/pkg/machineinfo.IsCompatibleWith allows same architecture + family +
  # model, with a single hardcoded exception for Ice Lake builds on Emerald
  # Rapids nodes). The build pool has to be 8th-generation Intel for nested
  # virtualization, so the client pool has to be 8th-generation Intel metal - and
  # AWS only sells that in metal-48xl (192 vCPU) and metal-96xl (384 vCPU).
  #
  # An earlier attempt at m5zn.metal, the smallest x86 metal at 48 vCPU, deployed
  # cleanly and then refused every sandbox with
  #   503 sandbox_no_compatible_node: no compatible node for this template's
  #   requirements
  # because Cascade Lake is not the Granite Rapids the build ran on.
  #
  # c8i rather than m8i at the same 192 vCPU: half the memory (384 GiB against
  # 768 GiB) for the same CPU generation, and sandbox density here is bounded by
  # vCPU, not by RAM.
  client_instance_type_x86 = "c8i.metal-48xl"

  # arm64: the same rule applies, so this has to match whatever the arm build
  # node reports. c8g.metal-48xl is the Graviton4 equivalent; a1.metal is not an
  # option regardless, since Firecracker's aarch64 support starts at Graviton2.
  client_instance_type_arm = "c8g.metal-48xl"

  # Resolved once so data.aws_ec2_instance_type.client below describes the shape
  # this deployment actually launches; reading the x86 value unconditionally
  # would report x86 bare-metal facts for an arm64 stack.
  client_instance_type = var.architecture == "x86_64" ? local.client_instance_type_x86 : local.client_instance_type_arm

  # The build node runs template-manager on its own. It does not need bare
  # metal: nested virtualization is supported on 8th-generation Intel families
  # (c8i, m8i, r8i and their flex variants, per the CpuOptions API), which gives
  # the build sandbox a working /dev/kvm at a fraction of a metal instance.
  # null_resource.build_nested_virtualization turns the flag on, because the AWS
  # provider pinned here has no cpu_options.nested_virtualization argument.
  build_instance_type = "m8i.4xlarge"

  # Define cluster configurations for different node types
  clusters = {
    # Server nodes run Consul and Nomad servers
    server = {
      instance_type_x86    = var.environment == "prod" ? "m7i.4xlarge" : "t3.xlarge"
      instance_type_arm    = var.environment == "prod" ? "m7g.4xlarge" : "t4g.xlarge"
      desired_capacity = 3
      max_size         = 3
      min_size         = 3
    }
    # Client nodes run workloads and containers
    client = {
      instance_type_x86    = local.client_instance_type_x86
      instance_type_arm    = local.client_instance_type_arm
      desired_capacity = 1
      max_size         = 5
      min_size         = 0
    }
    # API nodes run the API service.
    #
    # Two nodes, because the api job asks for two allocations and carries a
    # distinct_hosts constraint with static ports (50001, 5009): a second
    # allocation has nowhere to land without a second node. The API itself is
    # stateless - every sandbox state transition goes through Redis under a lock
    # (api/internal/sandbox/storage/redis), which is the only storage backend
    # there is - so replicas share one view rather than diverging.
    api = {
      instance_type_x86    = var.environment == "prod" ? "m7i.4xlarge" : "t3.xlarge"
      instance_type_arm    = var.environment == "prod" ? "m7g.4xlarge" : "t4g.xlarge"
      desired_capacity = 2
      max_size         = 3
      min_size         = 2
    }
    # Build nodes run template-manager. It has to be a pool of its own: the
    # orchestrator and template-manager both allocate host-global network slots
    # (veth-<idx>, 10.11.0.x) and both program the nftables rules that redirect
    # sandbox egress into their own proxy, so on a shared host whichever wrote
    # last takes over the other's sandboxes and template builds lose the network.
    build = {
      instance_type_x86    = local.build_instance_type
      instance_type_arm    = local.build_instance_type
      desired_capacity = 1
      max_size         = 1
      min_size         = 1
    }
  }
}


# =========================================================
# AMI AND BASE INFRASTRUCTURE
# =========================================================

# Find the latest E2B base AMI to use for all instances.
#
# The name is scoped by var.prefix (the CloudFormation stack name) and must stay
# in sync with ami_name in infra-iac/packer/main.pkr.hcl. A globally-shared
# pattern combined with most_recent = true makes two deployments in the same
# account pick up each other's AMI.
data "aws_ami" "e2b" {
  most_recent = true
  owners      = [local.account_id]

  filter {
    name   = "name"
    values = ["${var.prefix}-orch-*"]
  }
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

# -------------------- API Secret --------------------
# Consumed by template-manager as API_SECRET to authenticate against the API.
resource "random_password" "api_secret" {
  length  = 32
  special = false
}

# -------------------- Admin Token --------------------
# The credential for the admin-only routes (X-Admin-Token), which is what the
# scale-in controller authenticates with. A Secrets Manager entry rather than
# something start.sh generates: openssl there produced a fresh value on every
# apply, so the running api and /opt/config.properties drifted apart and the
# admin routes answered 401 until the job was redeployed.
resource "aws_secretsmanager_secret" "admin_token" {
  name        = "${var.prefix}-admin-token"
  description = "Credential for the API's admin routes (X-Admin-Token)"
  tags        = local.common_tags
}

resource "random_password" "admin_token" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret_version" "admin_token" {
  secret_id     = aws_secretsmanager_secret.admin_token.id
  secret_string = random_password.admin_token.result
}

# -------------------- Sandbox Access Token Hash Seed --------------------
# Separate from the admin token, which it used to share a value with. It seeds
# the hash that validates sandbox traffic tokens
# (api/internal/handlers/store.go), so rotating it invalidates every live
# sandbox's access token - and handing the admin credential to an automation
# would otherwise hand over this seed with it.
resource "aws_secretsmanager_secret" "sandbox_access_token_hash_seed" {
  name        = "${var.prefix}-sandbox-access-token-hash-seed"
  description = "Seed for hashing sandbox traffic access tokens"
  tags        = local.common_tags
}

resource "random_password" "sandbox_access_token_hash_seed" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret_version" "sandbox_access_token_hash_seed" {
  secret_id     = aws_secretsmanager_secret.sandbox_access_token_hash_seed.id
  secret_string = random_password.sandbox_access_token_hash_seed.result
}

resource "aws_secretsmanager_secret" "api_secret" {
  name        = "${var.prefix}-api-secret"
  description = "Shared secret used by template-manager to call the API"
  tags        = local.common_tags
}

resource "aws_secretsmanager_secret_version" "api_secret" {
  secret_id     = aws_secretsmanager_secret.api_secret.id
  secret_string = random_password.api_secret.result
}

# -------------------- Volume Token Signing Key --------------------
# Consumed by the API as VOLUME_TOKEN_SIGNING_KEY ("HMAC:<base64>").
# Rotating this invalidates every outstanding persistent-volume token, so the
# generation parameters are pinned to keep Terraform from recreating it.
resource "random_password" "volume_token_key" {
  length  = 32
  special = false

  lifecycle {
    ignore_changes = [length, special]
  }
}

# -------------------- LaunchDarkly API Key --------------------
# The upstream services all read LAUNCH_DARKLY_API_KEY for feature flags and
# fall back to their offline store when it is blank. The secret exists so the
# value can be filled in later without a Terraform change.
resource "aws_secretsmanager_secret" "launch_darkly_api_key" {
  name        = "${var.prefix}-launch-darkly-api-key"
  description = "LaunchDarkly SDK key; blank means use the offline flag store"
  tags        = local.common_tags
}

resource "aws_secretsmanager_secret_version" "launch_darkly_api_key" {
  secret_id     = aws_secretsmanager_secret.launch_darkly_api_key.id
  secret_string = " "

  lifecycle {
    ignore_changes = [secret_string]
  }
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
  name = "${var.prefix}-infra-instances-role"

  # Trust policy allowing EC2 to assume this role
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

resource "aws_iam_role_policy" "runtime_access" {
  name = "${var.prefix}-runtime-access"
  role = aws_iam_role.infra_instances_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3BucketAccess"
        Effect = "Allow"
        Action = ["s3:*"]
        Resource = [
          "arn:aws:s3:::${var.e2b_bucket}",
          "arn:aws:s3:::${var.e2b_bucket}/*",
          "arn:aws:s3:::${var.loki_bucket}",
          "arn:aws:s3:::${var.loki_bucket}/*",
          # Dedicated orchestrator storage buckets. The Go storage layer no
          # longer supports a key prefix, so these cannot live under the
          # unified e2b bucket.
          "arn:aws:s3:::${var.templates_bucket}",
          "arn:aws:s3:::${var.templates_bucket}/*",
          "arn:aws:s3:::${var.build_cache_bucket}",
          "arn:aws:s3:::${var.build_cache_bucket}/*"
        ]
      },
      {
        Sid      = "EC2SelfTerminate"
        Effect   = "Allow"
        Action   = ["ec2:TerminateInstances"]
        Resource = "arn:aws:ec2:*:*:instance/*"
        Condition = {
          StringLike = {
            "ec2:ResourceTag/aws:autoscaling:groupName" = "${var.prefix}-*"
          }
        }
      },
      {
        Sid      = "ECRAuthToken"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPull"
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchCheckLayerAvailability",
          "ecr:DescribeRepositories"
        ]
        # e2b-* covers e2b-orchestration/{api,client-proxy,db-migrator};
        # e2bdev/* covers the custom sandbox environment images.
        Resource = [
          "arn:aws:ecr:*:*:repository/e2b-*",
          "arn:aws:ecr:*:*:repository/e2bdev/*"
        ]
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:CreateRepository"
        ]
        Resource = [
          "arn:aws:ecr:*:*:repository/e2b-*",
          "arn:aws:ecr:*:*:repository/e2bdev/*"
        ]
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
    "scripts/run-consul.sh"              = "run-consul",
    # Every start-*.sh downloads this by RUN_CUSTOM_SCRIPT_FILE_HASH and runs
    # under `set -euo pipefail`, so leaving it out of this map made the fetch
    # 404 and killed node bootstrap along with the backgrounded run-nomad.sh.
    # The script is a no-op when custom_script_url is empty, so it is always
    # uploaded rather than made conditional.
    "scripts/run-custom-script.sh"       = "run-custom-script"
  }
}

# Upload setup scripts to S3
resource "aws_s3_object" "setup_config_objects" {
  for_each = var.setup_files
  bucket   = var.e2b_bucket
  key      = "cluster-setup/${each.value}-${local.file_hash[each.key]}.sh"
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

  # Nomad ports
  ingress {
    from_port   = 4646
    to_port     = 4646
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
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
  key_name               = var.sshkey

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
    CLUSTER_TAG_NAME             = "${var.prefix}-server-cluster"
    E2B_BUCKET                   = var.e2b_bucket
    NOMAD_TOKEN                  = aws_secretsmanager_secret_version.nomad_acl_token.secret_string
    CONSUL_TOKEN                 = aws_secretsmanager_secret_version.consul_acl_token.secret_string
    RUN_CONSUL_FILE_HASH         = local.file_hash["scripts/run-consul.sh"]
    RUN_NOMAD_FILE_HASH          = local.file_hash["scripts/run-nomad.sh"]
    RUN_CUSTOM_SCRIPT_FILE_HASH  = local.file_hash["scripts/run-custom-script.sh"]
    CUSTOM_SCRIPT_URL            = var.custom_script_url
    CONSUL_GOSSIP_ENCRYPTION_KEY = aws_secretsmanager_secret_version.consul_gossip_encryption_key.secret_string
    AWS_REGION                   = local.aws_region
    AWS_ACCOUNT_ID               = local.account_id
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(
      local.common_tags,
      {
        Name        = "server-cluster",
        ec2-e2b-key = var.prefix
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

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
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
  key_name               = var.sshkey
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
      volume_size           = 4000
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
    CLUSTER_TAG_NAME             = "${var.prefix}-client-cluster"
    E2B_BUCKET                   = var.e2b_bucket
    AWS_REGION                   = local.aws_region
    AWS_ACCOUNT_ID               = local.account_id
    NODE_LABELS                  = var.client_node_labels
    NOMAD_TOKEN                  = aws_secretsmanager_secret_version.nomad_acl_token.secret_string
    CONSUL_TOKEN                 = aws_secretsmanager_secret_version.consul_acl_token.secret_string
    RUN_CONSUL_FILE_HASH         = local.file_hash["scripts/run-consul.sh"]
    RUN_NOMAD_FILE_HASH          = local.file_hash["scripts/run-nomad.sh"]
    RUN_CUSTOM_SCRIPT_FILE_HASH  = local.file_hash["scripts/run-custom-script.sh"]
    CUSTOM_SCRIPT_URL            = var.custom_script_url
    CONSUL_GOSSIP_ENCRYPTION_KEY = aws_secretsmanager_secret_version.consul_gossip_encryption_key.secret_string
    CONSUL_DNS_REQUEST_TOKEN     = aws_secretsmanager_secret_version.consul_dns_request_token.secret_string
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(
      local.common_tags,
      {
        Name        = "client-cluster",
        ec2-e2b-key = var.prefix
      }
    )
  }

  depends_on = [aws_s3_object.setup_config_objects]
}

data "aws_ec2_instance_type" "client" {
  instance_type = local.client_instance_type
}

data "aws_ec2_instance_type" "build" {
  instance_type = local.build_instance_type
}

# Create a new launch template version with NestedVirtualization enabled via AWS CLI
# Terraform AWS provider does not support the NestedVirtualization parameter in cpu_options
resource "null_resource" "client_nested_virtualization" {
  count = data.aws_ec2_instance_type.client.bare_metal ? 0 : 1

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

# Same treatment for the build launch template. This is the one that actually
# needs it: the build pool runs a non-metal m8i, so Firecracker inside the
# template build only gets /dev/kvm with nested virtualization turned on.
# The ASG tracks version "$Latest", so it picks up the version created here.
resource "null_resource" "build_nested_virtualization" {
  count = data.aws_ec2_instance_type.build.bare_metal ? 0 : 1

  triggers = {
    launch_template_id      = aws_launch_template.build.id
    launch_template_version = aws_launch_template.build.latest_version
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws ec2 create-launch-template-version \
        --launch-template-id ${aws_launch_template.build.id} \
        --source-version ${aws_launch_template.build.latest_version} \
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

  # Tracking $Latest is not enough on its own: it decides what the *next*
  # instance launches with and leaves the running one alone, so an instance-type
  # or AMI change applied cleanly and then did nothing until something happened
  # to replace the node. That is how a client pool kept serving m5zn.metal after
  # terraform had already moved the launch template to c8i.metal-48xl - and the
  # mismatch only surfaced as sandboxes failing to place, far from its cause.
  #
  # Launch before terminate: the replacement is launched and healthy first, and
  # only then does the old node enter Terminating:Wait and drain.
  #
  # This was min_healthy_percentage = 0 (terminate first), which a one-node pool
  # needs to refresh at all when a refresh is instantaneous. It stops being
  # acceptable the moment the lifecycle hook below exists: the old node then
  # drains for up to 65 minutes before it dies, and with terminate-first the
  # replacement does not launch until it is gone - so any apply touching the
  # launch template would leave the pool with no capacity for the whole drain.
  #
  # AWS requires max - min <= 100, which 100/200 satisfies. The cost is one extra
  # bare-metal node for the duration of a drain.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 100
      max_healthy_percentage = 200
      # Consul and Nomad have to come up and the node has to register before the
      # refresh calls it done.
      instance_warmup = 300
    }
    # No triggers block: a launch_template change already triggers the refresh on
    # its own, and naming it explicitly is what terraform validate warns about.
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

  # Nomad ports
  ingress {
    from_port   = 4646
    to_port     = 4646
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # API port
  ingress {
    from_port   = 50001
    to_port     = 50001
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
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

  # API internal gRPC port. client-proxy reaches the API over this via
  # api-internal-grpc.service.consul, so VPC-internal only.
  ingress {
    from_port   = 5009
    to_port     = 5009
    protocol    = "tcp"
    cidr_blocks = [var.VPC.CIDR]
  }

  # Nomad dynamic port range, used by the API's grpc_api port allocation.
  ingress {
    from_port   = 20000
    to_port     = 32000
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

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    local.common_tags,
    {
      Name = "${var.prefix}-api-sg"
    }
  )
}

# =========================================================
# LOAD BALANCER ATTACHMENTS
# =========================================================
#
# The load balancer, its security group, the three target groups, the HTTPS
# listener and its host-header rules all live in the CloudFormation stack, not
# here. They used to be Terraform resources, which meant every terraform
# destroy/apply produced a load balancer with a new DNS name and the wildcard
# DNS record had to be re-pointed by hand - the only manual step in an otherwise
# unattended deployment. Putting them on the same lifecycle as the wildcard
# certificate (also CloudFormation-owned) makes that record a one-time setup.
#
# What stays here is the part that genuinely belongs to Terraform: attaching the
# autoscaling groups it owns to those target groups. The ARNs arrive through
# infra-iac/init.sh -> /opt/config.properties -> prepare.sh -> var.tf.
#
# NOTE: the docker-proxy target group, its ASG attachment and the
# docker.<domain> listener rule were removed together with the
# docker-reverse-proxy component, which upstream deprecated and deleted.

resource "aws_autoscaling_attachment" "nomad-server" {
  autoscaling_group_name = aws_autoscaling_group.server.name
  lb_target_group_arn    = var.nomad_server_tg_arn
}

resource "aws_autoscaling_attachment" "e2b-api" {
  autoscaling_group_name = aws_autoscaling_group.api.name
  lb_target_group_arn    = var.e2b_api_tg_arn
}

resource "aws_autoscaling_attachment" "client-proxy" {
  autoscaling_group_name = aws_autoscaling_group.api.name
  lb_target_group_arn    = var.client_proxy_tg_arn
}

# Create API cluster instances in an Auto Scaling Group
resource "aws_launch_template" "api" {
  name_prefix            = "${var.prefix}-api-"
  update_default_version = true
  image_id               = data.aws_ami.e2b.id
  instance_type          = var.architecture == "x86_64" ? local.clusters.api.instance_type_x86 : local.clusters.api.instance_type_arm
  key_name               = var.sshkey

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
    CLUSTER_TAG_NAME             = "${var.prefix}-api-cluster"
    E2B_BUCKET                   = var.e2b_bucket
    AWS_REGION                   = local.aws_region
    AWS_ACCOUNT_ID               = local.account_id
    NOMAD_TOKEN                  = aws_secretsmanager_secret_version.nomad_acl_token.secret_string
    CONSUL_TOKEN                 = aws_secretsmanager_secret_version.consul_acl_token.secret_string
    RUN_CONSUL_FILE_HASH         = local.file_hash["scripts/run-consul.sh"]
    RUN_NOMAD_FILE_HASH          = local.file_hash["scripts/run-nomad.sh"]
    RUN_CUSTOM_SCRIPT_FILE_HASH  = local.file_hash["scripts/run-custom-script.sh"]
    CUSTOM_SCRIPT_URL            = var.custom_script_url
    CONSUL_GOSSIP_ENCRYPTION_KEY = aws_secretsmanager_secret_version.consul_gossip_encryption_key.secret_string
    CONSUL_DNS_REQUEST_TOKEN     = aws_secretsmanager_secret_version.consul_dns_request_token.secret_string
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(
      local.common_tags,
      {
        Name        = "api-cluster",
        ec2-e2b-key = var.prefix
      }
    )
  }

  depends_on = [aws_s3_object.setup_config_objects]
}

# Create API auto scaling group
# Holds a terminating client node in Terminating:Wait so its sandboxes can finish
# before the instance dies. Without it EC2 terminates immediately and every
# sandbox on the node is lost.
#
# heartbeat_timeout is deliberately short: the drain controller heartbeats every
# loop, so this only has to cover one loop plus a cold start. A controller that
# wedges therefore releases the instance in five minutes rather than holding it
# for the whole drain budget. default_result = CONTINUE means every failure path
# ends with the instance released - the hook protects the ASG from stalling, not
# the sandboxes from being lost, and the controller is what protects those.
#
# The ASG's own ceiling is min(48h, 100 x heartbeat_timeout) = 8h20m here, well
# past the 65-minute budget the controller works to.
resource "aws_autoscaling_lifecycle_hook" "client_terminating" {
  name                   = "${var.prefix}-client-drain"
  autoscaling_group_name = aws_autoscaling_group.client.name
  lifecycle_transition   = "autoscaling:EC2_INSTANCE_TERMINATING"
  heartbeat_timeout      = 300
  default_result         = "CONTINUE"
}

resource "aws_autoscaling_group" "api" {
  name                = "${var.prefix}-api-asg"
  vpc_zone_identifier = var.VPC.private_subnets
  # desired_capacity    = var.api_asg_desired_capacity
  # max_size            = var.api_asg_desired_capacity
  # min_size            = var.api_asg_desired_capacity
  desired_capacity = local.clusters.api.desired_capacity
  max_size         = local.clusters.api.max_size
  min_size         = local.clusters.api.min_size

  # Target groups are wired up exclusively through aws_autoscaling_attachment
  # (e2b-api and client-proxy below). Declaring target_group_arns here as well
  # made every plan want to strip the client-proxy group back off, because this
  # list only ever held e2b-api. The AWS provider documents the two mechanisms
  # as mutually exclusive.

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

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
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
  key_name               = var.sshkey

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
    CLUSTER_TAG_NAME             = "${var.prefix}-build-cluster"
    E2B_BUCKET                   = var.e2b_bucket
    AWS_REGION                   = local.aws_region
    AWS_ACCOUNT_ID               = local.account_id
    NODE_LABELS                  = var.build_node_labels
    NOMAD_TOKEN                  = aws_secretsmanager_secret_version.nomad_acl_token.secret_string
    CONSUL_TOKEN                 = aws_secretsmanager_secret_version.consul_acl_token.secret_string
    RUN_CONSUL_FILE_HASH         = local.file_hash["scripts/run-consul.sh"]
    RUN_NOMAD_FILE_HASH          = local.file_hash["scripts/run-nomad.sh"]
    RUN_CUSTOM_SCRIPT_FILE_HASH  = local.file_hash["scripts/run-custom-script.sh"]
    CUSTOM_SCRIPT_URL            = var.custom_script_url
    CONSUL_GOSSIP_ENCRYPTION_KEY = aws_secretsmanager_secret_version.consul_gossip_encryption_key.secret_string
    CONSUL_DNS_REQUEST_TOKEN     = aws_secretsmanager_secret_version.consul_dns_request_token.secret_string
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(
      local.common_tags,
      {
        Name        = "build-cluster",
        ec2-e2b-key = var.prefix
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

  # The nested-virtualization flag is added as a new launch template version by
  # a local-exec, which Terraform cannot order implicitly. Without this the first
  # instance launches from the version that predates the flag and comes up with
  # no /dev/kvm, so every template build fails until the node is replaced.
  depends_on = [null_resource.build_nested_virtualization]

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

# Create CloudWatch logs group for cluster
resource "aws_cloudwatch_log_group" "cluster_logs" {
  name              = "${var.prefix}-cluster-logs"
  retention_in_days = 7

  tags = local.common_tags
}