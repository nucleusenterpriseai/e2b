variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "public_subnets" {
  description = "List of public subnet IDs for ALB"
  type        = list(string)
}

variable "alb_sg_id" {
  description = "Security group ID for the ALB"
  type        = string
}

variable "domain" {
  description = "Base domain (e.g., e2b.yourcompany.com)"
  type        = string
}

variable "prefix" {
  description = "Resource name prefix"
  type        = string
}

variable "zone_id" {
  description = "Route53 hosted zone ID for DNS validation and records"
  type        = string
}
