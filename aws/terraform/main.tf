data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  az1              = data.aws_availability_zones.available.names[0]
  az2              = data.aws_availability_zones.available.names[1]
  ami_arch_suffix  = var.architecture == "arm64" ? "arm64" : "amd64"
}

# Auto-lookup latest Packer-built AMI (no manual ami_id needed)
data "aws_ami" "e2b_node" {
  most_recent = true
  owners      = ["self"]

  filter {
    name   = "name"
    values = ["${var.ami_name_prefix}-${local.ami_arch_suffix}-*"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }

  filter {
    name   = "tag:Project"
    values = ["e2b"]
  }
}

module "vpc" {
  source   = "./modules/vpc"
  vpc_cidr = var.vpc_cidr
  az1      = local.az1
  az2      = local.az2
  prefix   = "e2b-${var.environment}"
}

module "security" {
  source       = "./modules/security"
  vpc_id       = module.vpc.vpc_id
  vpc_cidr     = var.vpc_cidr
  ssh_cidr     = var.allowed_ssh_cidr
  prefix       = "e2b-${var.environment}"
}

module "database" {
  source            = "./modules/database"
  vpc_id            = module.vpc.vpc_id
  private_subnets   = module.vpc.private_subnet_ids
  db_sg_id          = module.security.db_sg_id
  redis_sg_id       = module.security.redis_sg_id
  db_username       = var.db_username
  db_password       = module.secrets.db_password
  db_instance_class = var.db_instance_class
  redis_node_type   = var.redis_node_type
  multi_az          = var.db_multi_az
  prefix            = "e2b-${var.environment}"
}

module "storage" {
  source      = "./modules/storage"
  prefix      = "e2b-${var.environment}"
  environment = var.environment
}

module "secrets" {
  source = "./modules/secrets"
  prefix = "e2b-${var.environment}"
}

module "dns" {
  source = "./modules/dns"
  domain = var.domain
  prefix = "e2b-${var.environment}"
}

module "alb" {
  source         = "./modules/alb"
  vpc_id         = module.vpc.vpc_id
  public_subnets = module.vpc.public_subnet_ids
  alb_sg_id      = module.security.alb_sg_id
  domain         = var.domain
  prefix         = "e2b-${var.environment}"
  zone_id        = module.dns.zone_id
}

module "compute" {
  source                = "./modules/compute"
  vpc_id                = module.vpc.vpc_id
  private_subnets       = module.vpc.private_subnet_ids
  public_subnets        = module.vpc.public_subnet_ids
  server_sg_id          = module.security.server_sg_id
  client_sg_id          = module.security.client_sg_id
  api_sg_id             = module.security.api_sg_id
  bastion_sg_id         = module.security.bastion_sg_id
  instance_profile_name = module.security.instance_profile_name
  ec2_role_name         = module.security.ec2_role_name
  key_name              = var.key_name
  ami_id                = data.aws_ami.e2b_node.id

  server_instance_type = var.server_instance_type
  server_count         = var.server_count
  api_instance_type    = var.api_instance_type
  api_count            = var.api_count
  client_instance_type = var.client_instance_type
  client_desired_count = var.client_desired_count
  client_max_count     = var.client_max_count
  client_min_count     = var.client_min_count

  api_tg_arn          = module.alb.api_tg_arn
  client_proxy_tg_arn = module.alb.client_proxy_tg_arn
  docker_proxy_tg_arn = module.alb.docker_proxy_tg_arn
  nomad_tg_arn        = module.alb.nomad_tg_arn

  consul_token_arn = module.secrets.consul_token_arn
  nomad_token_arn  = module.secrets.nomad_token_arn
  gossip_key_arn   = module.secrets.gossip_key_arn

  domain      = var.domain
  environment = var.environment
  prefix      = "e2b-${var.environment}"

  s3_bucket_arns = module.storage.bucket_arns
  ecr_repo_arns  = module.storage.ecr_repo_arns
}
