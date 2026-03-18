# S3 Buckets
output "loki_storage_bucket_name" {
  description = "The name of the S3 bucket for Loki storage"
  value       = var.loki_bucket
}

output "e2b_bucket_name" {
  description = "The name of the unified E2B S3 bucket"
  value       = var.e2b_bucket
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
