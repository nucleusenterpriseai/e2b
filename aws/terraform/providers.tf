terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  backend "s3" {
    bucket         = "e2b-terraform-state"
    key            = "e2b/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "e2b-terraform-locks"
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
