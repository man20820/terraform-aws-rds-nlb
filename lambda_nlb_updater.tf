################################################################################
# Lambda - NLB Target Group IP Updater
#
# Triggered by EventBridge on RDS failover events and on a 5-minute schedule.
# Resolves the RDS endpoint DNS and updates the NLB target group with the
# new IP address.
################################################################################

locals {
  lambda_function_name = "${local.name_prefix}-nlb-target-updater"
}

################################################################################
# Lambda Function (terraform-aws-modules/lambda/aws)
# - Handles packaging, IAM role creation, and log group automatically
################################################################################

module "lambda_nlb_updater" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 7.0"

  function_name = local.lambda_function_name
  description   = "Syncs NLB target group IP with RDS endpoint on failover"
  handler       = "update_nlb_target.handler"
  runtime       = "nodejs22.x"
  timeout       = 30

  # Package Lambda source from local directory
  source_path = "${path.module}/lambda/update_nlb_target.mjs"

  environment_variables = {
    TARGET_GROUP_ARN = module.nlb.target_groups["mssql"].arn
    RDS_ENDPOINT     = module.rds.db_instance_address
    RDS_PORT         = "1433"
  }

  # CloudWatch log group
  cloudwatch_logs_retention_in_days = 14

  # IAM policy for target group updates
  attach_policy_statements = true
  policy_statements = {
    allow_target_group_updates = {
      sid    = "AllowTargetGroupUpdates"
      effect = "Allow"
      actions = [
        "elasticloadbalancing:DescribeTargetHealth",
        "elasticloadbalancing:RegisterTargets",
        "elasticloadbalancing:DeregisterTargets",
      ]
      resources = [module.nlb.target_groups["mssql"].arn]
    }
  }

  # NOTE: allowed_triggers intentionally omitted here to avoid circular dependency
  # with module.eventbridge_nlb_updater. Permissions are granted via standalone
  # aws_lambda_permission resources below.

  tags = var.tags
}

################################################################################
# EventBridge Rules (terraform-aws-modules/eventbridge/aws)
# - RDS failover event rule
# - Periodic 5-minute sync schedule
################################################################################

module "eventbridge_nlb_updater" {
  source  = "terraform-aws-modules/eventbridge/aws"
  version = "~> 3.0"

  # Use the default event bus
  create_bus = false

  rules = {
    rds-failover = {
      description = "Trigger NLB target updater on RDS failover"
      event_pattern = jsonencode({
        source      = ["aws.rds"]
        detail-type = ["RDS DB Instance Event"]
        detail = {
          EventID = [
            "RDS-EVENT-0049", # Failover started
            "RDS-EVENT-0050", # Failover completed
            "RDS-EVENT-0051", # Multi-AZ failover
            "RDS-EVENT-0053", # Multi-AZ failover complete
          ]
        }
      })
    }

    periodic-sync = {
      description         = "Periodically sync NLB target group IP with RDS endpoint"
      schedule_expression = "rate(5 minutes)"
    }
  }

  targets = {
    rds-failover = [
      {
        name = "NlbTargetUpdaterLambda"
        arn  = module.lambda_nlb_updater.lambda_function_arn
      }
    ]

    periodic-sync = [
      {
        name = "NlbTargetUpdaterLambdaSync"
        arn  = module.lambda_nlb_updater.lambda_function_arn
      }
    ]
  }

  tags = var.tags
}

################################################################################
# Lambda permissions for EventBridge
# Standalone resources to break circular dependency between Lambda and
# EventBridge modules (Lambda needs EventBridge ARN, EventBridge needs Lambda ARN)
################################################################################

resource "aws_lambda_permission" "eventbridge_rds_failover" {
  statement_id  = "AllowEventBridgeRdsFailover"
  action        = "lambda:InvokeFunction"
  function_name = module.lambda_nlb_updater.lambda_function_name
  principal     = "events.amazonaws.com"
  source_arn    = module.eventbridge_nlb_updater.eventbridge_rule_arns["rds-failover"]
}

resource "aws_lambda_permission" "eventbridge_periodic_sync" {
  statement_id  = "AllowEventBridgePeriodicSync"
  action        = "lambda:InvokeFunction"
  function_name = module.lambda_nlb_updater.lambda_function_name
  principal     = "events.amazonaws.com"
  source_arn    = module.eventbridge_nlb_updater.eventbridge_rule_arns["periodic-sync"]
}
