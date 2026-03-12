data "aws_region" "current" {}

# ---------------------------------------------------------
# IAM Policy for EC2 Role (S3, ECR, Secrets Manager, SSM, CW)
# ---------------------------------------------------------
resource "aws_iam_role_policy" "ec2" {
  name = "${var.prefix}-ec2-policy"
  role = var.ec2_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3Access"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket",
          "s3:DeleteObject",
          "s3:GetBucketLocation",
        ]
        Resource = concat(
          var.s3_bucket_arns,
          [for arn in var.s3_bucket_arns : "${arn}/*"],
        )
      },
      {
        Sid    = "ECRAccess"
        Effect = "Allow"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeRepositories",
          "ecr:ListImages",
        ]
        Resource = var.ecr_repo_arns
      },
      {
        Sid    = "ECRAuth"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
        ]
        Resource = "*"
      },
      {
        Sid    = "SecretsManagerRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
        ]
        Resource = [
          var.consul_token_arn,
          var.nomad_token_arn,
          var.gossip_key_arn,
        ]
      },
      {
        Sid    = "SSM"
        Effect = "Allow"
        Action = [
          "ssm:DescribeAssociation",
          "ssm:GetDeployablePatchSnapshotForInstance",
          "ssm:GetDocument",
          "ssm:DescribeDocument",
          "ssm:GetManifest",
          "ssm:ListAssociations",
          "ssm:ListInstanceAssociations",
          "ssm:PutInventory",
          "ssm:PutComplianceItems",
          "ssm:PutConfigurePackageResult",
          "ssm:UpdateAssociationStatus",
          "ssm:UpdateInstanceAssociationStatus",
          "ssm:UpdateInstanceInformation",
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel",
          "ec2messages:AcknowledgeMessage",
          "ec2messages:DeleteMessage",
          "ec2messages:FailMessage",
          "ec2messages:GetEndpoint",
          "ec2messages:GetMessages",
          "ec2messages:SendReply",
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudWatch"
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
        ]
        Resource = "*"
      },
      {
        Sid    = "EC2DiscoveryForConsulAutoJoin"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeTags",
        ]
        Resource = "*"
      },
    ]
  })
}

# ---------------------------------------------------------
# Bastion Host
# ---------------------------------------------------------
resource "aws_instance" "bastion" {
  ami                    = var.ami_id
  instance_type          = "t3.small"
  key_name               = var.key_name
  subnet_id              = var.public_subnets[0]
  vpc_security_group_ids = [var.bastion_sg_id]

  associate_public_ip_address = true

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  tags = { Name = "${var.prefix}-bastion" }
}

# ---------------------------------------------------------
# Launch Template - Servers (Nomad/Consul)
# ---------------------------------------------------------
resource "aws_launch_template" "server" {
  name_prefix   = "${var.prefix}-server-"
  image_id      = var.ami_id
  instance_type = var.server_instance_type
  key_name      = var.key_name

  iam_instance_profile {
    name = var.instance_profile_name
  }

  vpc_security_group_ids = [var.server_sg_id]

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  user_data = base64encode(templatefile("${path.module}/user-data/server.sh", {
    prefix           = var.prefix
    region           = data.aws_region.current.name
    consul_token_arn = var.consul_token_arn
    nomad_token_arn  = var.nomad_token_arn
    gossip_key_arn   = var.gossip_key_arn
    server_count     = var.server_count
    domain           = var.domain
    environment      = var.environment
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.prefix}-server"
      Role = "server"
    }
  }

  lifecycle { create_before_destroy = true }
}

# ---------------------------------------------------------
# Launch Template - Clients (Firecracker hosts)
# ---------------------------------------------------------
resource "aws_launch_template" "client" {
  name_prefix   = "${var.prefix}-client-"
  image_id      = var.ami_id
  instance_type = var.client_instance_type
  key_name      = var.key_name

  iam_instance_profile {
    name = var.instance_profile_name
  }

  vpc_security_group_ids = [var.client_sg_id]

  # 200GB gp3 volume for Firecracker VM rootfs overlays and snapshots
  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_size           = 200
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  user_data = base64encode(templatefile("${path.module}/user-data/client.sh", {
    prefix           = var.prefix
    region           = data.aws_region.current.name
    consul_token_arn = var.consul_token_arn
    nomad_token_arn  = var.nomad_token_arn
    gossip_key_arn   = var.gossip_key_arn
    domain           = var.domain
    environment      = var.environment
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.prefix}-client"
      Role = "client"
    }
  }

  lifecycle { create_before_destroy = true }
}

# ---------------------------------------------------------
# Launch Template - API Nodes
# ---------------------------------------------------------
resource "aws_launch_template" "api" {
  name_prefix   = "${var.prefix}-api-"
  image_id      = var.ami_id
  instance_type = var.api_instance_type
  key_name      = var.key_name

  iam_instance_profile {
    name = var.instance_profile_name
  }

  vpc_security_group_ids = [var.api_sg_id]

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  user_data = base64encode(templatefile("${path.module}/user-data/api.sh", {
    prefix           = var.prefix
    region           = data.aws_region.current.name
    consul_token_arn = var.consul_token_arn
    nomad_token_arn  = var.nomad_token_arn
    gossip_key_arn   = var.gossip_key_arn
    domain           = var.domain
    environment      = var.environment
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.prefix}-api"
      Role = "api"
    }
  }

  lifecycle { create_before_destroy = true }
}

# ---------------------------------------------------------
# ASG - Servers
# ---------------------------------------------------------
resource "aws_autoscaling_group" "server" {
  name                      = "${var.prefix}-server-asg"
  desired_capacity          = var.server_count
  min_size                  = var.server_count
  max_size                  = var.server_count
  vpc_zone_identifier       = var.private_subnets
  target_group_arns         = [var.nomad_tg_arn]
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.server.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.prefix}-server"
    propagate_at_launch = true
  }

  tag {
    key                 = "Role"
    value               = "server"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------
# ASG - Clients
# ---------------------------------------------------------
resource "aws_autoscaling_group" "client" {
  name                      = "${var.prefix}-client-asg"
  desired_capacity          = var.client_desired_count
  min_size                  = var.client_min_count
  max_size                  = var.client_max_count
  vpc_zone_identifier       = var.private_subnets
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.client.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.prefix}-client"
    propagate_at_launch = true
  }

  tag {
    key                 = "Role"
    value               = "client"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------
# ASG - API Nodes
# ---------------------------------------------------------
resource "aws_autoscaling_group" "api" {
  name                      = "${var.prefix}-api-asg"
  desired_capacity          = var.api_count
  min_size                  = var.api_count
  max_size                  = var.api_count
  vpc_zone_identifier       = var.private_subnets
  target_group_arns         = [var.api_tg_arn, var.client_proxy_tg_arn, var.docker_proxy_tg_arn]
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.api.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.prefix}-api"
    propagate_at_launch = true
  }

  tag {
    key                 = "Role"
    value               = "api"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}
