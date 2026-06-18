################################################################################
# Outputs
################################################################################

output "rds_instance_id" {
  description = "The RDS instance identifier"
  value       = module.rds.db_instance_identifier
}

output "rds_instance_endpoint" {
  description = "The RDS instance endpoint (direct, bypass proxy)"
  value       = module.rds.db_instance_endpoint
}

output "rds_instance_port" {
  description = "The RDS instance port"
  value       = module.rds.db_instance_port
}

output "rds_proxy_endpoint" {
  description = "The RDS Proxy endpoint (use this for application connections)"
  value       = module.rds_proxy.proxy_endpoint
}

output "rds_proxy_arn" {
  description = "The ARN of the RDS Proxy"
  value       = module.rds_proxy.proxy_arn
}

output "rds_credentials_secret_arn" {
  description = "ARN of the Secrets Manager secret containing RDS credentials"
  value       = aws_secretsmanager_secret.rds_credentials.arn
}

output "rds_security_group_id" {
  description = "Security group ID for the RDS instance"
  value       = module.rds_sg.security_group_id
}

output "rds_proxy_security_group_id" {
  description = "Security group ID for the RDS Proxy"
  value       = module.rds_proxy_sg.security_group_id
}
