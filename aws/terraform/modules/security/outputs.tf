output "alb_sg_id" {
  value = aws_security_group.alb.id
}

output "bastion_sg_id" {
  value = aws_security_group.bastion.id
}

output "server_sg_id" {
  value = aws_security_group.server.id
}

output "client_sg_id" {
  value = aws_security_group.client.id
}

output "api_sg_id" {
  value = aws_security_group.api.id
}

output "db_sg_id" {
  value = aws_security_group.db.id
}

output "redis_sg_id" {
  value = aws_security_group.redis.id
}

output "instance_profile_name" {
  value = aws_iam_instance_profile.ec2.name
}

output "ec2_role_name" {
  value = aws_iam_role.ec2.name
}
