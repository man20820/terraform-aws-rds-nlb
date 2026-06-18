################################################################################
# Security Groups
################################################################################

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

# Security group for RDS MSSQL instance
module "rds_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = "${local.name_prefix}-rds-mssql-sg"
  description = "Security group for RDS MSSQL instance"
  vpc_id      = data.aws_vpc.this.id

  # Allow inbound from RDS Proxy SG on MSSQL port
  ingress_with_source_security_group_id = [
    {
      from_port                = 1433
      to_port                  = 1433
      protocol                 = "tcp"
      description              = "MSSQL access from RDS Proxy"
      source_security_group_id = module.rds_proxy_sg.security_group_id
    }
  ]

  egress_rules = ["all-all"]

  tags = var.tags
}

# Security group for RDS Proxy
module "rds_proxy_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = "${local.name_prefix}-rds-proxy-sg"
  description = "Security group for RDS Proxy"
  vpc_id      = data.aws_vpc.this.id

  # Allow inbound MSSQL from within the VPC
  ingress_with_cidr_blocks = [
    {
      from_port   = 1433
      to_port     = 1433
      protocol    = "tcp"
      description = "MSSQL access from VPC"
      cidr_blocks = data.aws_vpc.this.cidr_block
    }
  ]

  egress_rules = ["all-all"]

  tags = var.tags
}
