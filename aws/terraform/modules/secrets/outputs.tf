output "consul_token_arn" {
  description = "ARN of the Consul ACL token secret"
  value       = aws_secretsmanager_secret.consul_token.arn
}

output "nomad_token_arn" {
  description = "ARN of the Nomad ACL token secret"
  value       = aws_secretsmanager_secret.nomad_token.arn
}

output "gossip_key_arn" {
  description = "ARN of the gossip encryption key secret"
  value       = aws_secretsmanager_secret.gossip_key.arn
}

output "dns_token_arn" {
  description = "ARN of the DNS request token secret"
  value       = aws_secretsmanager_secret.dns_request_token.arn
}

output "db_password" {
  description = "Generated database password"
  value       = random_password.db_password.result
  sensitive   = true
}

output "db_password_secret_arn" {
  description = "ARN of the database password secret in Secrets Manager"
  value       = aws_secretsmanager_secret.db_password.arn
}
