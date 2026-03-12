# ALB Security Group
resource "aws_security_group" "alb" {
  name_prefix = "${var.prefix}-alb-"
  vpc_id      = var.vpc_id
  description = "ALB security group"

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS from internet"
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP from internet (redirect to HTTPS)"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.prefix}-alb-sg" }

  lifecycle { create_before_destroy = true }
}

# Bastion Security Group
resource "aws_security_group" "bastion" {
  name_prefix = "${var.prefix}-bastion-"
  vpc_id      = var.vpc_id
  description = "Bastion host"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_cidr]
    description = "SSH access"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.prefix}-bastion-sg" }

  lifecycle { create_before_destroy = true }
}

# Nomad/Consul Server Security Group
resource "aws_security_group" "server" {
  name_prefix = "${var.prefix}-server-"
  vpc_id      = var.vpc_id
  description = "Nomad/Consul servers"

  # Nomad RPC
  ingress {
    from_port   = 4646
    to_port     = 4648
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Nomad ports"
  }

  # Consul ports
  ingress {
    from_port   = 8300
    to_port     = 8302
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Consul server RPC + serf"
  }

  ingress {
    from_port   = 8301
    to_port     = 8302
    protocol    = "udp"
    cidr_blocks = [var.vpc_cidr]
    description = "Consul serf UDP"
  }

  ingress {
    from_port   = 8500
    to_port     = 8500
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Consul HTTP API"
  }

  ingress {
    from_port   = 8600
    to_port     = 8600
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Consul DNS"
  }

  ingress {
    from_port   = 8600
    to_port     = 8600
    protocol    = "udp"
    cidr_blocks = [var.vpc_cidr]
    description = "Consul DNS UDP"
  }

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
    description     = "SSH from bastion"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.prefix}-server-sg" }

  lifecycle { create_before_destroy = true }
}

# Nomad Client (Firecracker host) Security Group
resource "aws_security_group" "client" {
  name_prefix = "${var.prefix}-client-"
  vpc_id      = var.vpc_id
  description = "Nomad clients (Firecracker hosts)"

  # Orchestrator gRPC
  ingress {
    from_port   = 5008
    to_port     = 5008
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Orchestrator gRPC"
  }

  # Template manager gRPC
  ingress {
    from_port   = 5009
    to_port     = 5009
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Template manager gRPC"
  }

  # Nomad client ports
  ingress {
    from_port   = 4646
    to_port     = 4648
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Nomad client ports"
  }

  # Consul agent
  ingress {
    from_port   = 8300
    to_port     = 8302
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    from_port   = 8301
    to_port     = 8302
    protocol    = "udp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Dynamic port range for Nomad tasks
  ingress {
    from_port   = 20000
    to_port     = 32000
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Nomad dynamic ports"
  }

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
    description     = "SSH from bastion"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.prefix}-client-sg" }

  lifecycle { create_before_destroy = true }
}

# API Node Security Group
resource "aws_security_group" "api" {
  name_prefix = "${var.prefix}-api-"
  vpc_id      = var.vpc_id
  description = "API nodes"

  # API server
  ingress {
    from_port       = 50001
    to_port         = 50001
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "API from ALB"
  }

  # Client proxy
  ingress {
    from_port       = 3001
    to_port         = 3002
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "Client proxy from ALB"
  }

  # Docker reverse proxy
  ingress {
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "Docker proxy from ALB"
  }

  # Nomad client + Consul
  ingress {
    from_port   = 4646
    to_port     = 4648
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    from_port   = 8300
    to_port     = 8302
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    from_port   = 8301
    to_port     = 8302
    protocol    = "udp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
    description     = "SSH from bastion"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.prefix}-api-sg" }

  lifecycle { create_before_destroy = true }
}

# Database Security Group
resource "aws_security_group" "db" {
  name_prefix = "${var.prefix}-db-"
  vpc_id      = var.vpc_id
  description = "RDS PostgreSQL"

  ingress {
    from_port = 5432
    to_port   = 5432
    protocol  = "tcp"
    security_groups = [
      aws_security_group.server.id,
      aws_security_group.client.id,
      aws_security_group.api.id,
      aws_security_group.bastion.id,
    ]
    description = "PostgreSQL from internal services"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.prefix}-db-sg" }

  lifecycle { create_before_destroy = true }
}

# Redis Security Group
resource "aws_security_group" "redis" {
  name_prefix = "${var.prefix}-redis-"
  vpc_id      = var.vpc_id
  description = "ElastiCache Redis"

  ingress {
    from_port = 6379
    to_port   = 6379
    protocol  = "tcp"
    security_groups = [
      aws_security_group.server.id,
      aws_security_group.client.id,
      aws_security_group.api.id,
    ]
    description = "Redis from internal services"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.prefix}-redis-sg" }

  lifecycle { create_before_destroy = true }
}

# IAM Role for EC2 instances
resource "aws_iam_role" "ec2" {
  name = "${var.prefix}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.prefix}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# IAM policies are attached in the compute module where S3/ECR ARNs are available
