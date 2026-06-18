################################################################################
# IAM Role for RDS Proxy (to read Secrets Manager)
################################################################################

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "rds_proxy" {
  name = "${local.name_prefix}-rds-proxy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "rds.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "rds_proxy_secrets" {
  name = "${local.name_prefix}-rds-proxy-secrets-policy"
  role = aws_iam_role.rds_proxy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          aws_secretsmanager_secret.rds_credentials.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt"
        ]
        Resource = ["*"]
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${var.aws_region}.amazonaws.com"
          }
        }
      }
    ]
  })
}

################################################################################
# RDS Proxy
################################################################################

module "rds_proxy" {
  source  = "terraform-aws-modules/rds-proxy/aws"
  version = "~> 3.0"

  name            = "${local.name_prefix}-rds-proxy"
  iam_role_name   = aws_iam_role.rds_proxy.name
  create_iam_role = false
  role_arn        = aws_iam_role.rds_proxy.arn

  vpc_subnet_ids         = data.aws_subnets.private.ids
  vpc_security_group_ids = [module.rds_proxy_sg.security_group_id]

  db_proxy_endpoints = {}

  engine_family = "SQLSERVER"
  debug_logging = false

  # Target RDS instance
  target_db_instance     = true
  db_instance_identifier = module.rds.db_instance_identifier

  # Authentication via Secrets Manager
  auth = {
    "superuser" = {
      description = "RDS MSSQL superuser credentials"
      secret_arn  = aws_secretsmanager_secret.rds_credentials.arn
    }
  }

  # Connection settings
  idle_client_timeout       = 1800
  require_tls               = true
  connection_borrow_timeout = 120

  tags = var.tags
}
