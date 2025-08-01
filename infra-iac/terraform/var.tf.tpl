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
