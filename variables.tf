variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "ap-southeast-3"
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "mssql-proxy"
}

variable "environment" {
  description = "Environment name (e.g. dev, staging, prod)"
  type        = string
  default     = "dev"
}

# --- VPC / Subnet lookup filters ---

variable "vpc_tag_name" {
  description = "Tag Name value to filter the existing VPC"
  type        = string
}

variable "db_subnet_tag_name" {
  description = "Tag Name value to filter existing DB subnets"
  type        = string
}

variable "private_subnet_tag_name" {
  description = "Tag Name value to filter existing private subnets (for RDS Proxy)"
  type        = string
}

# --- RDS ---

variable "db_name" {
  description = "Initial database name (leave null for MSSQL)"
  type        = string
  default     = null
}

variable "db_username" {
  description = "Master username for the RDS instance"
  type        = string
  default     = "admin"
}

variable "db_instance_class" {
  description = "RDS instance class (smallest for Enterprise is db.t3.xlarge)"
  type        = string
  default     = "db.t3.xlarge"
}

variable "db_allocated_storage" {
  description = "Allocated storage in GB"
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Maximum storage for autoscaling in GB"
  type        = number
  default     = 100
}

variable "db_engine_version" {
  description = "MSSQL engine version (must be 15.00 for RDS Proxy support)"
  type        = string
  default     = "15.00"
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}
