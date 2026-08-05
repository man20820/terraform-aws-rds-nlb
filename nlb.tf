################################################################################
# Network Load Balancer for RDS MSSQL
################################################################################

module "nlb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 9.0"

  name               = "${local.name_prefix}-mssql-nlb"
  load_balancer_type = "network"
  internal           = true

  vpc_id  = data.aws_vpc.this.id
  subnets = data.aws_subnets.private.ids

  security_groups                  = [module.nlb_sg.security_group_id]
  enable_cross_zone_load_balancing = true

  # Target Group
  target_groups = {
    mssql = {
      name        = "${local.name_prefix}-mssql-tg"
      protocol    = "TCP"
      port        = 1433
      target_type = "ip"

      health_check = {
        enabled             = true
        protocol            = "TCP"
        port                = "traffic-port"
        healthy_threshold   = 3
        unhealthy_threshold = 3
        interval            = 30
      }
    }
  }

  # Listener
  listeners = {
    mssql = {
      port     = 1433
      protocol = "TCP"

      forward = {
        target_group_key = "mssql"
      }
    }
  }

  tags = var.tags
}

################################################################################
# Target Group Attachment - RDS Instance IP
################################################################################

resource "aws_lb_target_group_attachment" "mssql" {
  target_group_arn = module.nlb.target_groups["mssql"].arn
  target_id        = data.dns_a_record_set.rds.addrs[0]
  port             = 1433
}

################################################################################
# DNS lookup to resolve RDS endpoint to IP
################################################################################

data "dns_a_record_set" "rds" {
  host = module.rds.db_instance_address
}
