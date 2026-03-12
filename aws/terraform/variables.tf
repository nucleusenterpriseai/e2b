variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
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
  default = "c5.metal"

  validation {
    condition     = can(regex("metal", var.client_instance_type))
    error_message = "Client instances must be bare metal for KVM support (e.g., c5.metal, c7i.metal-24xl)."
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

variable "ami_id" {
  description = "AMI ID for E2B nodes (from Packer build)"
  type        = string
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed to SSH to bastion (must be explicitly set, no default for security)"
  type        = string

  validation {
    condition     = var.allowed_ssh_cidr != "0.0.0.0/0"
    error_message = "SSH CIDR must not be 0.0.0.0/0. Restrict to your office/VPN IP range."
  }
}
