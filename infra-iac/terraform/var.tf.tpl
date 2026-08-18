# Terraform Variables Template File
# This file defines all variables used in the Terraform configuration
# Placeholder values will be replaced by the prepare.sh script using values from config.properties

# Terraform Environment
variable "environment" {
  type    = string
  default = "${CFNENVIRONMENT}"
}

# Resource Prefix
# Used to name and tag all resources created by Terraform
variable "prefix" {
  description = "Prefix of Resource"
  type        = string
  default     = "${CFNSTACKNAME}"
}

# SSH Key Name
# The name of the SSH key pair to be used for EC2 instances
variable "sshkey" {
  description = "Name of ssh Key"
  type        = string
  default     = "${CFNSSHKEY}"
}

# ACM Certificate ARN
# Amazon Resource Name of the SSL/TLS certificate in AWS Certificate Manager.
#
# Unused by main.tf since the load balancer moved into CloudFormation, which
# references the certificate resource directly. Kept because prepare.sh
# substitutes every ${CFN...} placeholder it finds in this template; dropping the
# variable while the placeholder logic stays would only move the coupling around.
variable "certarn" {
  description = "arn of acm certification (unused: the ALB lives in CloudFormation)"
  type        = string
  default     = "${CFNCERTARN}"
}

# Domain Name
# The domain name to be used for the application.
# Also unused by main.tf now - the host-header listener rules moved to
# CloudFormation along with the load balancer.
variable "domainname" {
  description = "name of domain (unused: listener rules live in CloudFormation)"
  type        = string
  default     = "${CFNDOMAIN}"
}

# VPC Configuration
# Contains all necessary VPC information including ID, CIDR block, and subnet IDs
variable "VPC" {
  description = "VPC infos"
  type = object({
    id              = string                           # VPC ID
    CIDR            = optional(string, "Create by Terraform")  # CIDR block for the VPC
    public_subnets  = list(string)                     # List of public subnet IDs
    private_subnets = list(string)                     # List of private subnet IDs
  })
  default = {
    id              = "${CFNVPCID}"                    # VPC ID placeholder
    CIDR            = "${CFNVPCCIDR}"                  # VPC CIDR block placeholder
    private_subnets = ["${CFNPRIVATESUBNET1}", "${CFNPRIVATESUBNET2}", "${CFNPRIVATESUBNET3}"]  # Private subnet ID placeholders
    public_subnets  = ["${CFNPUBLICSUBNET1}", "${CFNPUBLICSUBNET2}", "${CFNPUBLICSUBNET3}"]    # Public subnet ID placeholders
  }
}

# Architecture
# CPU architecture to use for EC2 instances (x86_64 or arm64)
variable "architecture" {
  description = "CPU architecture to use for EC2 instances"
  type        = string
  default     = "${CFNARCHITECTURE}"
}

# Client Instance Type
variable "client_instance_type" {
  description = "Instance type for client cluster"
  type        = string
  default     = "${CFNCLIENTINSTANCETYPE}"
}

# Also unused by main.tf now: it only ever selected the load balancer's scheme
# and subnets, and that decision moved to CloudFormation's IsPrivateAccess
# condition along with the load balancer itself.
variable "publicaccess" {
  description = "Specify whether public or private access to E2B (unused: the ALB lives in CloudFormation)"
  type        = string
  default     = "${CFNPUBLICACCESS}"
}

variable "e2b_bucket" {
  description = "Name of the unified E2B S3 bucket"
  default     = "${CFNE2BBUCKET}"
}

variable "loki_bucket" {
  description = "Name of the Loki log storage S3 bucket"
  default     = "${CFNLOKIBUCKET}"
}

# Dedicated orchestrator storage buckets.
# The Go storage layer resolves TEMPLATE_BUCKET_NAME / BUILD_CACHE_BUCKET_NAME
# into a bare s3:// destination and no longer honours a key prefix, so these
# two roles cannot be served out of the unified E2B bucket.
variable "templates_bucket" {
  description = "Name of the sandbox template S3 bucket (TEMPLATE_BUCKET_NAME)"
  default     = "${CFNTEMPLATESBUCKET}"
}

variable "build_cache_bucket" {
  description = "Name of the template build cache S3 bucket (BUILD_CACHE_BUCKET_NAME)"
  default     = "${CFNBUILDCACHEBUCKET}"
}

# Node labels exposed to Nomad as meta.node_labels and consumed by the
# orchestrator / template-manager jobs as NODE_LABELS.
#
# Not driven by CloudFormation: label-based sandbox scheduling is opt-in and
# empty is the correct default. Override with -var when you need it, e.g.
#   terraform apply -var 'client_node_labels=gpu,large-mem'
variable "client_node_labels" {
  description = "Comma-separated labels applied to client nodes for sandbox scheduling"
  type        = string
  default     = ""
}

variable "build_node_labels" {
  description = "Comma-separated labels applied to build nodes for sandbox scheduling"
  type        = string
  default     = ""
}

# Target group ARNs for the CloudFormation-owned load balancer.
#
# The load balancer lives in the CFN stack so that its DNS name survives
# terraform destroy/apply and the wildcard DNS record only has to be set once.
# Terraform only attaches its autoscaling groups to these target groups.
variable "nomad_server_tg_arn" {
  description = "Target group ARN for the Nomad server UI/API (port 4646)"
  type        = string
  default     = "${CFNNOMADSERVERTGARN}"
}

variable "e2b_api_tg_arn" {
  description = "Target group ARN for the E2B API (port 50001)"
  type        = string
  default     = "${CFNE2BAPITGARN}"
}

variable "client_proxy_tg_arn" {
  description = "Target group ARN for sandbox traffic (port 3002, health 3001)"
  type        = string
  default     = "${CFNCLIENTPROXYTGARN}"
}

variable "custom_script_url" {
  description = "URL of custom script to run on instances after startup"
  default     = "${CFNCustomScriptUrl}"
}
