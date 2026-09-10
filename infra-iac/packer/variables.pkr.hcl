
variable "gcp_project_id" {
  type    = string
  default = ""
}

variable "gcp_zone" {
  type    = string
  default = "us-east1"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "gcp_instance_type" {
  type = string
  default = ""
}

variable "aws_instance_type" {
  type    = string
  default = ""  # Empty default, will be determined dynamically in main.pkr.hcl
  description = "AWS instance type to use for building the AMI"
}

variable "architecture" {
  type        = string
  default     = "x86_64"
  description = "CPU architecture (x86_64 or arm64)"
}

variable "image_family" {
  type    = string
  default = "e2b-orch"
}

variable "vpc_id" {
  type    = string
  default = ""
}

variable "subnet_id" {
  type    = string
  default = ""
}

# Resource name prefix (the CloudFormation stack name). The produced AMI is
# named "${prefix}-orch-<timestamp>" so that two deployments in the same account
# do not resolve each other's image; keep in sync with the aws_ami "e2b" filter
# in infra-iac/terraform/main.tf.
variable "prefix" {
  type        = string
  default     = "e2b"
  description = "Resource name prefix used for the AMI name"
}

# Consul/Nomad versions track upstream's shared cluster disk image
# (iac/provider-aws/nomad-cluster-disk-image/variables.pkr.hcl). Nomad >= 1.8 is
# required for Nomad-native service registration and memory oversubscription.
variable "consul_version" {
  type    = string
  default = "1.17.3"
}

variable "nomad_version" {
  type    = string
  default = "1.8.4"
}
