################################################################################
# Secrets Manager - RDS Master Password
################################################################################

resource "random_password" "master" {
  length           = 24
  special          = true
  override_special = "!#$%^&*()-_=+[]{}|;:,.<>?"
}

resource "aws_secretsmanager_secret" "rds_credentials" {
  name                    = "${local.name_prefix}-rds-mssql-credentials"
  description             = "RDS MSSQL master credentials"
  recovery_window_in_days = 7

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "rds_credentials" {
  secret_id = aws_secretsmanager_secret.rds_credentials.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.master.result
  })
}

################################################################################
# RDS MSSQL Instance
################################################################################

module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.0"

  identifier = "${local.name_prefix}-mssql"

  # Engine
  engine               = "sqlserver-ee"
  engine_version       = var.db_engine_version
  instance_class       = var.db_instance_class
  license_model        = "license-included"
  major_engine_version = "15.00"

  # Storage
  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  # Credentials
  username                    = var.db_username
  manage_master_user_password = false
  password                    = random_password.master.result

  # Network
  multi_az               = false
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [module.rds_sg.security_group_id]
  publicly_accessible    = false
  port                   = 1433

  # Maintenance & Backup
  maintenance_window      = "Sun:05:00-Sun:06:00"
  backup_window           = "03:00-04:00"
  backup_retention_period = 7
  skip_final_snapshot     = true
  deletion_protection     = false
  copy_tags_to_snapshot   = true

  # Monitoring
  monitoring_interval             = 0
  performance_insights_enabled    = false
  create_cloudwatch_log_group     = false
  enabled_cloudwatch_logs_exports = []

  # Parameter & Option groups
  family                    = "sqlserver-ee-15.0"
  create_db_parameter_group = true
  create_db_option_group    = true

  # MSSQL does not support db_name parameter
  create_db_instance = true

  tags = var.tags
}

################################################################################
# DB Subnet Group (using existing subnets)
################################################################################

resource "aws_db_subnet_group" "this" {
  name       = "${local.name_prefix}-db-subnet-group"
  subnet_ids = data.aws_subnets.db.ids

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-db-subnet-group"
  })
}
