# Consul ACL token
resource "random_uuid" "consul_token" {}

resource "aws_secretsmanager_secret" "consul_token" {
  name                    = "${var.prefix}/consul-token"
  description             = "Consul ACL master token"
  recovery_window_in_days = 7

  tags = { Name = "${var.prefix}-consul-token" }
}

resource "aws_secretsmanager_secret_version" "consul_token" {
  secret_id     = aws_secretsmanager_secret.consul_token.id
  secret_string = random_uuid.consul_token.result
}

# Nomad ACL token
resource "random_uuid" "nomad_token" {}

resource "aws_secretsmanager_secret" "nomad_token" {
  name                    = "${var.prefix}/nomad-token"
  description             = "Nomad ACL bootstrap token"
  recovery_window_in_days = 7

  tags = { Name = "${var.prefix}-nomad-token" }
}

resource "aws_secretsmanager_secret_version" "nomad_token" {
  secret_id     = aws_secretsmanager_secret.nomad_token.id
  secret_string = random_uuid.nomad_token.result
}

# Gossip encryption key (32-byte base64)
resource "random_password" "gossip_key" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "gossip_key" {
  name                    = "${var.prefix}/gossip-key"
  description             = "Consul/Nomad gossip encryption key"
  recovery_window_in_days = 7

  tags = { Name = "${var.prefix}-gossip-key" }
}

resource "aws_secretsmanager_secret_version" "gossip_key" {
  secret_id     = aws_secretsmanager_secret.gossip_key.id
  secret_string = base64encode(random_password.gossip_key.result)
}

# DNS request token
resource "random_password" "dns_request_token" {
  length  = 32
  special = true
}

resource "aws_secretsmanager_secret" "dns_request_token" {
  name                    = "${var.prefix}/dns-request-token"
  description             = "DNS request authentication token"
  recovery_window_in_days = 7

  tags = { Name = "${var.prefix}-dns-request-token" }
}

resource "aws_secretsmanager_secret_version" "dns_request_token" {
  secret_id     = aws_secretsmanager_secret.dns_request_token.id
  secret_string = random_password.dns_request_token.result
}

# Database password (generated, not user-supplied)
resource "random_password" "db_password" {
  length           = 32
  special          = true
  override_special = "!#$%^&*()-_=+"
}

resource "aws_secretsmanager_secret" "db_password" {
  name                    = "${var.prefix}/db-password"
  description             = "RDS PostgreSQL master password"
  recovery_window_in_days = 7

  tags = { Name = "${var.prefix}-db-password" }
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = random_password.db_password.result
}
