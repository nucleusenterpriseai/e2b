output "alb_dns_name" {
  description = "DNS name of the ALB"
  value       = aws_lb.main.dns_name
}

output "alb_arn" {
  description = "ARN of the ALB"
  value       = aws_lb.main.arn
}

output "api_tg_arn" {
  description = "ARN of the API target group"
  value       = aws_lb_target_group.api.arn
}

output "client_proxy_tg_arn" {
  description = "ARN of the client proxy target group"
  value       = aws_lb_target_group.client_proxy.arn
}

output "docker_proxy_tg_arn" {
  description = "ARN of the docker proxy target group"
  value       = aws_lb_target_group.docker_proxy.arn
}

output "nomad_tg_arn" {
  description = "ARN of the Nomad target group"
  value       = aws_lb_target_group.nomad.arn
}

output "certificate_arn" {
  description = "ARN of the ACM wildcard certificate"
  value       = aws_acm_certificate.wildcard.arn
}
