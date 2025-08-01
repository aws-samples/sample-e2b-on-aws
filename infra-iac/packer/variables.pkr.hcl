
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

variable "consul_version" {
  type    = string
  default = "1.16.2"
}

variable "nomad_version" {
  type    = string
  default = "1.6.2"
}
