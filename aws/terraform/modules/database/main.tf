# RDS PostgreSQL
resource "aws_db_subnet_group" "main" {
  name       = "${var.prefix}-db-subnet-group"
  subnet_ids = var.private_subnets

  tags = { Name = "${var.prefix}-db-subnet-group" }
}

resource "aws_db_instance" "postgres" {
  identifier     = "${var.prefix}-postgres"
  engine         = "postgres"
  engine_version = "15"
  instance_class = var.db_instance_class

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = "e2b"
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.db_sg_id]

  multi_az            = var.multi_az
  publicly_accessible = false
  skip_final_snapshot = false

  final_snapshot_identifier = "${var.prefix}-postgres-final-snapshot"
  deletion_protection       = true

  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  tags = { Name = "${var.prefix}-postgres" }
}

# ElastiCache Redis
resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.prefix}-redis-subnet-group"
  subnet_ids = var.private_subnets

  tags = { Name = "${var.prefix}-redis-subnet-group" }
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "${var.prefix}-redis"
  description          = "${var.prefix} Redis cluster"
  node_type            = var.redis_node_type
  num_cache_clusters   = 2

  engine               = "redis"
  engine_version       = "7.0"
  parameter_group_name = "default.redis7"
  port                 = 6379

  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [var.redis_sg_id]

  automatic_failover_enabled = true
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  tags = { Name = "${var.prefix}-redis" }
}
