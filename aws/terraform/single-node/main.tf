# E2B Self-Hosted — Single-Node Deployment
#
# Deploys 1 bare-metal EC2 (ARM64 Graviton or x86) with everything on it:
#   - Orchestrator, API, envd, Firecracker, PostgreSQL, Redis
#   - Auto-configures via user-data → ec2-setup.sh
#   - No VPC/ALB/RDS/ElastiCache overhead — single box
#
# Usage:
#   cd aws/terraform/single-node
#   cp terraform.tfvars.example terraform.tfvars  # edit values
#   terraform init
#   terraform apply
#
# After apply (if auto_setup = false):
#   ssh -i ~/.ssh/<key>.pem ubuntu@<public_ip>
#   sudo bash /opt/e2b/ec2-setup.sh

terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "e2b"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# ── Variables ──────────────────────────────────────────────

variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "key_name" {
  description = "EC2 key pair name for SSH access"
  type        = string
}

variable "instance_type" {
  description = "Bare metal instance type (must have KVM support)"
  type        = string
  default     = "c6g.metal"

  validation {
    condition     = can(regex("metal", var.instance_type))
    error_message = "Must be a bare metal instance type for KVM support."
  }
}

variable "use_spot" {
  description = "Use spot instance (cheaper, may be interrupted)"
  type        = bool
  default     = true
}

variable "volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 200
}

variable "allowed_ssh_cidrs" {
  description = "CIDR blocks allowed to access the instance (SSH + services)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ami_override" {
  description = "Override AMI ID (e.g., Packer-built). If empty, uses latest Ubuntu 22.04."
  type        = string
  default     = ""
}

variable "e2b_repo_url" {
  description = "Git URL of your e2b project repo (contains ec2-setup.sh and custom configs)"
  type        = string
  default     = ""
}

variable "e2b_repo_ref" {
  description = "Git branch or tag of the e2b repo to clone (commit SHAs are not supported; use a branch)"
  type        = string
  default     = ""
}

variable "fc_version" {
  description = "Firecracker version"
  type        = string
  default     = "v1.12.1"
}

variable "fc_commit" {
  description = "Firecracker commit hash (used in directory naming)"
  type        = string
  default     = "a41d3fb"
}

variable "kernel_version" {
  description = "Firecracker kernel version"
  type        = string
  default     = "vmlinux-6.1.158"
}

variable "kernel_url" {
  description = "HTTPS URL to download the Firecracker kernel binary. If empty, downloads from project GitHub release."
  type        = string
  default     = ""
}

variable "go_version" {
  description = "Go toolchain version"
  type        = string
  default     = "1.25.4"
}

variable "infra_repo_url" {
  description = "Git URL of the e2b infra repo (use your fork with standard FC patches)"
  type        = string
  default     = "https://github.com/e2b-dev/infra.git"
}

variable "infra_repo_ref" {
  description = "Git branch/tag/commit of the infra repo to clone"
  type        = string
  default     = "main"
}

# ── Architecture detection ────────────────────────────────

locals {
  is_arm64   = can(regex("^(c6g|c7g|t4g|m6g|m7g|r6g|r7g)", var.instance_type))
  ami_arch   = local.is_arm64 ? "arm64" : "amd64"
  ubuntu_ami = local.is_arm64 ? "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*" : "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
  ami_id     = var.ami_override != "" ? var.ami_override : data.aws_ami.ubuntu.id
}

# ── AMI lookup ────────────────────────────────────────────

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = [local.ubuntu_ami]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# ── Security Group ────────────────────────────────────────

resource "aws_security_group" "e2b" {
  name_prefix = "e2b-${var.environment}-"
  description = "E2B single-node: SSH, API, orchestrator, sandbox proxy"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  ingress {
    description = "API"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  ingress {
    description = "Sandbox proxy"
    from_port   = 5007
    to_port     = 5007
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  ingress {
    description = "Orchestrator gRPC"
    from_port   = 5008
    to_port     = 5008
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "e2b-${var.environment}-sg" }
}

# ── EC2 Instance ──────────────────────────────────────────

resource "aws_instance" "e2b" {
  ami                    = local.ami_id
  instance_type          = var.instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.e2b.id]

  associate_public_ip_address = true

  root_block_device {
    volume_size = var.volume_size
    volume_type = "gp3"
    iops        = 6000
    throughput  = 400
    encrypted   = true
  }

  # Spot instance support
  dynamic "instance_market_options" {
    for_each = var.use_spot ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        spot_instance_type = "one-time"
      }
    }
  }

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  user_data = base64encode(templatefile("${path.module}/user-data.sh", {
    environment    = var.environment
    fc_version     = var.fc_version
    fc_commit      = var.fc_commit
    kernel_version = var.kernel_version
    kernel_url     = var.kernel_url
    go_version     = var.go_version
    e2b_repo_url   = var.e2b_repo_url
    e2b_repo_ref   = var.e2b_repo_ref
    infra_repo_url = var.infra_repo_url
    infra_repo_ref = var.infra_repo_ref
  }))

  user_data_replace_on_change = true

  tags = {
    Name = "e2b-${var.environment}-node"
  }
}

# ── Outputs ───────────────────────────────────────────────

output "instance_id" {
  value = aws_instance.e2b.id
}

output "public_ip" {
  value = aws_instance.e2b.public_ip
}

output "ssh_command" {
  value = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${aws_instance.e2b.public_ip}"
}

output "ami_used" {
  value = local.ami_id
}

output "instance_type" {
  value = var.instance_type
}

output "api_url" {
  value = "http://${aws_instance.e2b.public_ip}:80"
}

output "sandbox_proxy_url" {
  value = "http://${aws_instance.e2b.public_ip}:5007"
}

output "setup_log" {
  description = "View setup progress"
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${aws_instance.e2b.public_ip} 'tail -f /var/log/e2b-setup.log'"
}
