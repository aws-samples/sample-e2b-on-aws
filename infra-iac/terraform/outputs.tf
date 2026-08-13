# S3 Buckets
#
# infra-iac/terraform/start.sh turns every output whose name ends in
# `_bucket_name` into a BUCKET_<NAME> entry in /opt/config.properties by
# stripping that suffix and upper-casing the rest. Keep the suffix, or the
# bucket will not reach the Nomad job templates.
#   e2b_bucket_name         -> BUCKET_E2B
#   loki_storage_bucket_name -> BUCKET_LOKI_STORAGE
#   templates_bucket_name    -> BUCKET_TEMPLATES
#   build_cache_bucket_name  -> BUCKET_BUILD_CACHE
output "e2b_bucket_name" {
  value = var.e2b_bucket
}

output "loki_storage_bucket_name" {
  value = var.loki_bucket
}

output "templates_bucket_name" {
  description = "Sandbox template bucket, consumed as TEMPLATE_BUCKET_NAME"
  value       = var.templates_bucket
}

output "build_cache_bucket_name" {
  description = "Template build cache bucket, consumed as BUILD_CACHE_BUCKET_NAME"
  value       = var.build_cache_bucket
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

output "api_secret_name" {
  description = "The name of the API shared secret used by template-manager"
  value       = aws_secretsmanager_secret.api_secret.name
}

output "launch_darkly_api_key_name" {
  description = "The name of the LaunchDarkly SDK key secret"
  value       = aws_secretsmanager_secret.launch_darkly_api_key.name
}

# Emitted directly rather than through Secrets Manager: start.sh normalises it
# into the volume_token_key config key, which nomad/prepare.sh base64-encodes
# into the API's VOLUME_TOKEN_SIGNING_KEY.
output "volume_token_key" {
  description = "Raw HMAC key for signing persistent-volume tokens"
  value       = random_password.volume_token_key.result
  sensitive   = true
}
