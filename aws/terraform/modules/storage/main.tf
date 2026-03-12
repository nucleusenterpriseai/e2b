# S3 Buckets
locals {
  bucket_names = [
    "fc-kernels",
    "fc-versions",
    "fc-templates",
    "env-pipeline",
    "docker-contexts",
    "cluster-setup",
    "loki-storage",
  ]
}

resource "aws_s3_bucket" "buckets" {
  for_each = toset(local.bucket_names)

  bucket        = "${var.prefix}-${each.key}"
  force_destroy = true

  tags = {
    Name        = "${var.prefix}-${each.key}"
    Environment = var.environment
  }
}

resource "aws_s3_bucket_versioning" "buckets" {
  for_each = aws_s3_bucket.buckets

  bucket = each.value.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "buckets" {
  for_each = aws_s3_bucket.buckets

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "buckets" {
  for_each = aws_s3_bucket.buckets

  bucket = each.value.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ECR Repositories
locals {
  ecr_repos = [
    "e2b-orchestration/api",
    "e2b-orchestration/client-proxy",
    "docker-reverse-proxy",
  ]
}

resource "aws_ecr_repository" "repos" {
  for_each = toset(local.ecr_repos)

  name                 = "${var.prefix}/${each.key}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name        = "${var.prefix}-${replace(each.key, "/", "-")}"
    Environment = var.environment
  }
}

resource "aws_ecr_lifecycle_policy" "repos" {
  for_each = aws_ecr_repository.repos

  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 20 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 20
      }
      action = {
        type = "expire"
      }
    }]
  })
}
