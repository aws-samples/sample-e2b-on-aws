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
# Amazon Resource Name of the SSL/TLS certificate in AWS Certificate Manager
variable "certarn" {
  description = "arn of acm certification"
  type        = string
  default     = "${CFNCERTARN}"
}

# Domain Name
# The domain name to be used for the application
variable "domainname" {
  description = "name of domain"
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
    private_subnets = ["${CFNPRIVATESUBNET1}", "${CFNPRIVATESUBNET2}"]  # Private subnet ID placeholders
    public_subnets  = ["${CFNPUBLICSUBNET1}", "${CFNPUBLICSUBNET2}"]    # Public subnet ID placeholders
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

variable "publicaccess" {
  description = "Specify whether public or private access to E2B"
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

variable "custom_script_url" {
  description = "URL of custom script to run on instances after startup"
  default     = "${CFNCustomScriptUrl}"
}
