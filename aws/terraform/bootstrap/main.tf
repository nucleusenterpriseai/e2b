# Terraform State Bootstrap
#
# Creates the S3 bucket and DynamoDB table required for Terraform remote state.
# This must be applied BEFORE the main Terraform configuration.
#
# Usage:
#   cd aws/terraform/bootstrap
#   terraform init
#   terraform apply
#
# After applying, configure the main Terraform backend:
#   terraform {
#     backend "s3" {
#       bucket         = "<output: bucket_name>"
#       key            = "e2b/terraform.tfstate"
#       region         = "<region>"
#       dynamodb_table = "<output: dynamodb_table_name>"
#       encrypt        = true
#     }
#   }

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# --- Variables ---

variable "region" {
  description = "AWS region for the state backend"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "project" {
  description = "Project name prefix"
  type        = string
  default     = "e2b"
}

# --- Locals ---

locals {
  bucket_name = "${var.project}-${var.environment}-tfstate-${data.aws_caller_identity.current.account_id}"
  table_name  = "${var.project}-${var.environment}-tflock"
}

data "aws_caller_identity" "current" {}

# --- S3 Bucket for Terraform State ---

resource "aws_s3_bucket" "tfstate" {
  bucket = local.bucket_name

  # Prevent accidental deletion of the state bucket
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name        = local.bucket_name
    Project     = var.project
    Environment = var.environment
    Purpose     = "terraform-state"
    ManagedBy   = "terraform-bootstrap"
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "cleanup-old-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "STANDARD_IA"
    }
  }
}

# --- DynamoDB Table for State Locking ---

resource "aws_dynamodb_table" "tflock" {
  name         = local.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  # Prevent accidental deletion
  lifecycle {
    prevent_destroy = true
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = {
    Name        = local.table_name
    Project     = var.project
    Environment = var.environment
    Purpose     = "terraform-state-lock"
    ManagedBy   = "terraform-bootstrap"
  }
}

# --- Outputs ---

output "bucket_name" {
  description = "S3 bucket name for Terraform state"
  value       = aws_s3_bucket.tfstate.id
}

output "bucket_arn" {
  description = "S3 bucket ARN for Terraform state"
  value       = aws_s3_bucket.tfstate.arn
}

output "dynamodb_table_name" {
  description = "DynamoDB table name for Terraform state locking"
  value       = aws_dynamodb_table.tflock.name
}

output "dynamodb_table_arn" {
  description = "DynamoDB table ARN for Terraform state locking"
  value       = aws_dynamodb_table.tflock.arn
}

output "region" {
  description = "AWS region of the state backend"
  value       = var.region
}

output "backend_config" {
  description = "Backend configuration snippet for main Terraform"
  value       = <<-EOT
    terraform {
      backend "s3" {
        bucket         = "${aws_s3_bucket.tfstate.id}"
        key            = "e2b/terraform.tfstate"
        region         = "${var.region}"
        dynamodb_table = "${aws_dynamodb_table.tflock.name}"
        encrypt        = true
      }
    }
  EOT
}
