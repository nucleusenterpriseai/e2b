output "bucket_arns" {
  description = "List of all S3 bucket ARNs"
  value       = [for b in aws_s3_bucket.buckets : b.arn]
}

output "bucket_names" {
  description = "Map of bucket key to bucket name"
  value       = { for k, b in aws_s3_bucket.buckets : k => b.id }
}

output "ecr_repo_arns" {
  description = "List of all ECR repository ARNs"
  value       = [for r in aws_ecr_repository.repos : r.arn]
}

output "ecr_repo_urls" {
  description = "Map of ECR repo key to repository URL"
  value       = { for k, r in aws_ecr_repository.repos : k => r.repository_url }
}
