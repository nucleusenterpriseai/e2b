# ---------------------------------------------------------
# Networking
# ---------------------------------------------------------
output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

# ---------------------------------------------------------
# Load Balancer
# ---------------------------------------------------------
output "alb_dns_name" {
  description = "ALB DNS name - point your domain CNAME here"
  value       = module.alb.alb_dns_name
}

output "certificate_arn" {
  description = "ACM wildcard certificate ARN"
  value       = module.alb.certificate_arn
}

# ---------------------------------------------------------
# Database
# ---------------------------------------------------------
output "db_endpoint" {
  description = "RDS PostgreSQL endpoint (host:port)"
  value       = module.database.db_endpoint
}

output "db_address" {
  description = "RDS PostgreSQL hostname"
  value       = module.database.db_address
}

output "db_port" {
  description = "RDS PostgreSQL port"
  value       = module.database.db_port
}

output "redis_endpoint" {
  description = "ElastiCache Redis primary endpoint"
  value       = module.database.redis_endpoint
}

output "redis_address" {
  description = "ElastiCache Redis hostname"
  value       = module.database.redis_address
}

output "redis_port" {
  description = "ElastiCache Redis port"
  value       = module.database.redis_port
}

# ---------------------------------------------------------
# Storage
# ---------------------------------------------------------
output "s3_bucket_names" {
  description = "Map of S3 bucket logical names to actual bucket names"
  value       = module.storage.bucket_names
}

output "ecr_repo_urls" {
  description = "Map of ECR repository names to URLs"
  value       = module.storage.ecr_repo_urls
}

# ---------------------------------------------------------
# Compute
# ---------------------------------------------------------
output "bastion_public_ip" {
  description = "Public IP of the bastion host"
  value       = module.compute.bastion_public_ip
}

output "server_asg_name" {
  description = "Name of the server Auto Scaling Group"
  value       = module.compute.server_asg_name
}

output "client_asg_name" {
  description = "Name of the client Auto Scaling Group"
  value       = module.compute.client_asg_name
}

output "api_asg_name" {
  description = "Name of the API Auto Scaling Group"
  value       = module.compute.api_asg_name
}

# ---------------------------------------------------------
# Secrets
# ---------------------------------------------------------
output "consul_token_arn" {
  description = "ARN of the Consul token in Secrets Manager"
  value       = module.secrets.consul_token_arn
}

output "nomad_token_arn" {
  description = "ARN of the Nomad token in Secrets Manager"
  value       = module.secrets.nomad_token_arn
}

output "gossip_key_arn" {
  description = "ARN of the gossip encryption key in Secrets Manager"
  value       = module.secrets.gossip_key_arn
}

output "dns_token_arn" {
  description = "ARN of the DNS request token in Secrets Manager"
  value       = module.secrets.dns_token_arn
}

output "db_password_secret_arn" {
  description = "ARN of the DB password secret in Secrets Manager"
  value       = module.secrets.db_password_secret_arn
}

# ---------------------------------------------------------
# DNS
# ---------------------------------------------------------
output "route53_zone_id" {
  description = "Route53 hosted zone ID"
  value       = module.dns.zone_id
}

output "route53_name_servers" {
  description = "Route53 name servers (delegate your domain to these)"
  value       = module.dns.name_servers
}
