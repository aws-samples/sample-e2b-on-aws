# S3 Buckets
output "loki_storage_bucket_name" {
  description = "The name of the S3 bucket for Loki storage"
  value       = aws_s3_bucket.loki_storage_bucket.bucket
}

output "envs_docker_context_bucket_name" {
  description = "The name of the S3 bucket for Docker contexts"
  value       = aws_s3_bucket.envs_docker_context.bucket
}

output "setup_bucket_name" {
  description = "The name of the S3 bucket for cluster setup files"
  value       = aws_s3_bucket.setup_bucket.bucket
}

output "fc_kernels_bucket_name" {
  description = "The name of the S3 bucket for FC kernels"
  value       = aws_s3_bucket.fc_kernels_bucket.bucket
}

output "fc_versions_bucket_name" {
  description = "The name of the S3 bucket for FC versions"
  value       = aws_s3_bucket.fc_versions_bucket.bucket
}

output "fc_env_pipeline_bucket_name" {
  description = "The name of the S3 bucket for FC environment pipeline"
  value       = aws_s3_bucket.fc_env_pipeline_bucket.bucket
}

output "fc_template_bucket_name" {
  description = "The name of the S3 bucket for FC templates"
  value       = aws_s3_bucket.fc_template_bucket.bucket
}

output "docker_contexts_bucket_name" {
  description = "The name of the S3 bucket for Docker contexts"
  value       = aws_s3_bucket.docker_contexts_bucket.bucket
}

# Secrets Manager Secrets
output "consul_acl_token_secret_name" {
  description = "The name of the Consul ACL token secret"
  value       = aws_secretsmanager_secret.consul_acl_token.name
}

output "nomad_acl_token_secret_name" {
  description = "The name of the Nomad ACL token secret"
  value       = aws_secretsmanager_secret.nomad_acl_token.name
}

output "consul_gossip_encryption_key_name" {
  description = "The name of the Consul gossip encryption key secret"
  value       = aws_secretsmanager_secret.consul_gossip_encryption_key.name
}

output "consul_dns_request_token_name" {
  description = "The name of the Consul DNS request token secret"
  value       = aws_secretsmanager_secret.consul_dns_request_token.name
}

output "infra_tokens_secret_name" {
  description = "The name of the infrastructure tokens secret"
  value       = aws_secretsmanager_secret.infra_tokens.name
}

output "e2b_config_secret_name" {
  description = "The name of the E2B config secret"
  value       = aws_secretsmanager_secret.e2b_config.name
}
