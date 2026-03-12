output "bastion_public_ip" {
  description = "Public IP of the bastion host"
  value       = aws_instance.bastion.public_ip
}

output "server_asg_name" {
  description = "Name of the server Auto Scaling Group"
  value       = aws_autoscaling_group.server.name
}

output "client_asg_name" {
  description = "Name of the client Auto Scaling Group"
  value       = aws_autoscaling_group.client.name
}

output "api_asg_name" {
  description = "Name of the API Auto Scaling Group"
  value       = aws_autoscaling_group.api.name
}
