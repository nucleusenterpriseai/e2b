variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "private_subnets" {
  description = "List of private subnet IDs"
  type        = list(string)
}

variable "public_subnets" {
  description = "List of public subnet IDs"
  type        = list(string)
}

variable "server_sg_id" {
  description = "Security group ID for server nodes"
  type        = string
}

variable "client_sg_id" {
  description = "Security group ID for client nodes"
  type        = string
}

variable "api_sg_id" {
  description = "Security group ID for API nodes"
  type        = string
}

variable "bastion_sg_id" {
  description = "Security group ID for bastion host"
  type        = string
}

variable "instance_profile_name" {
  description = "IAM instance profile name for EC2 instances"
  type        = string
}

variable "ec2_role_name" {
  description = "IAM role name for EC2 instances (used for policy attachment)"
  type        = string
}

variable "key_name" {
  description = "EC2 key pair name"
  type        = string
}

variable "ami_id" {
  description = "AMI ID for E2B nodes"
  type        = string
}

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
  description = "EC2 instance type for Nomad client nodes (must be bare metal for KVM)"
  type        = string
  default     = "c5.metal"
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

variable "api_tg_arn" {
  description = "ARN of the API target group"
  type        = string
}

variable "client_proxy_tg_arn" {
  description = "ARN of the client proxy target group"
  type        = string
}

variable "docker_proxy_tg_arn" {
  description = "ARN of the docker proxy target group"
  type        = string
}

variable "nomad_tg_arn" {
  description = "ARN of the Nomad target group"
  type        = string
}

variable "consul_token_arn" {
  description = "ARN of the Consul token secret"
  type        = string
}

variable "nomad_token_arn" {
  description = "ARN of the Nomad token secret"
  type        = string
}

variable "gossip_key_arn" {
  description = "ARN of the gossip key secret"
  type        = string
}

variable "domain" {
  description = "Base domain"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "prefix" {
  description = "Resource name prefix"
  type        = string
}

variable "s3_bucket_arns" {
  description = "List of S3 bucket ARNs for IAM policy"
  type        = list(string)
}

variable "ecr_repo_arns" {
  description = "List of ECR repository ARNs for IAM policy"
  type        = list(string)
}
