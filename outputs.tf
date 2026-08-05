################################################################################
# Outputs
################################################################################

output "rds_instance_id" {
  description = "The RDS instance identifier"
  value       = module.rds.db_instance_identifier
}

output "rds_instance_endpoint" {
  description = "The RDS instance endpoint (direct)"
  value       = module.rds.db_instance_endpoint
}

output "rds_instance_port" {
  description = "The RDS instance port"
  value       = module.rds.db_instance_port
}

output "nlb_dns_name" {
  description = "The NLB DNS name (use this for application connections)"
  value       = module.nlb.dns_name
}

output "nlb_arn" {
  description = "The ARN of the Network Load Balancer"
  value       = module.nlb.arn
}

output "rds_credentials_secret_arn" {
  description = "ARN of the Secrets Manager secret containing RDS credentials"
  value       = aws_secretsmanager_secret.rds_credentials.arn
}

output "rds_security_group_id" {
  description = "Security group ID for the RDS instance"
  value       = module.rds_sg.security_group_id
}

output "nlb_security_group_id" {
  description = "Security group ID for the Network Load Balancer"
  value       = module.nlb_sg.security_group_id
}
