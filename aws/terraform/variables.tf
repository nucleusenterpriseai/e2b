variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-1"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "domain" {
  description = "Base domain for E2B (e.g., e2b.yourcompany.com)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "key_name" {
  description = "EC2 key pair name"
  type        = string
}

# Database
variable "db_username" {
  description = "RDS PostgreSQL master username"
  type        = string
  default     = "e2badmin"
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.medium"
}

variable "redis_node_type" {
  description = "ElastiCache Redis node type"
  type        = string
  default     = "cache.t3.medium"
}

# Compute
variable "server_instance_type" {
  description = "EC2 instance type for Nomad/Consul servers"
  type        = string
  default     = "t3.xlarge"
}

variable "server_count" {
  description = "Number of Nomad/Consul server instances"
  type        = number
  default     = 3
}

variable "api_instance_type" {
  description = "EC2 instance type for API nodes"
  type        = string
  default     = "t3.xlarge"
}

variable "api_count" {
  description = "Number of API node instances"
  type        = number
  default     = 1
}

variable "client_instance_type" {
  description = "EC2 instance type for Nomad client nodes (must be bare metal for KVM/Firecracker support)"
  type        = string
  # Firecracker requires /dev/kvm, which is only available on bare metal instances
  default = "c6g.metal"

  validation {
    condition     = can(regex("metal", var.client_instance_type))
    error_message = "Client instances must be bare metal for KVM support (e.g., c5.metal, c6g.metal, c7g.metal)."
  }
}

variable "client_desired_count" {
  description = "Desired number of client node instances"
  type        = number
  default     = 1
}

variable "client_max_count" {
  description = "Maximum number of client node instances"
  type        = number
  default     = 5
}

variable "client_min_count" {
  description = "Minimum number of client node instances"
  type        = number
  default     = 1
}

variable "db_multi_az" {
  description = "Enable Multi-AZ for RDS (doubles cost, recommended for production)"
  type        = bool
  default     = false
}

variable "architecture" {
  description = "CPU architecture for EC2 instances: x86_64 or arm64"
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["x86_64", "arm64"], var.architecture)
    error_message = "Architecture must be x86_64 or arm64."
  }
}

variable "ami_name_prefix" {
  description = "AMI name prefix (must match Packer ami_name_prefix). Architecture suffix is appended automatically."
  type        = string
  default     = "e2b-node"
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed to SSH to bastion (must be explicitly set, no default for security)"
  type        = string

  validation {
    condition     = var.allowed_ssh_cidr != "0.0.0.0/0"
    error_message = "SSH CIDR must not be 0.0.0.0/0. Restrict to your office/VPN IP range."
  }
}
