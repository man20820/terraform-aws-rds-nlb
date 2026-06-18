# Terraform AWS RDS MSSQL with RDS Proxy

Provisions an AWS RDS SQL Server Enterprise instance on a DB subnet and an RDS Proxy on a private subnet in the Jakarta region (`ap-southeast-3`).

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                       VPC                           │
│                                                     │
│  ┌──────────────────┐     ┌──────────────────────┐ │
│  │  Private Subnets │     │     DB Subnets       │ │
│  │                  │     │                      │ │
│  │  ┌────────────┐  │     │  ┌────────────────┐  │ │
│  │  │ RDS Proxy  │──┼─────┼─▶│ RDS MSSQL EE   │  │ │
│  │  │ (port 1433)│  │     │  │ (db.t3.xlarge) │  │ │
│  │  └────────────┘  │     │  └────────────────┘  │ │
│  └──────────────────┘     └──────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.0
- AWS CLI configured with appropriate credentials
- An existing VPC with tagged subnets (DB subnets + private subnets)
- An existing S3 bucket for Terraform state

## Quick Start

### 1. Configure backend

Edit `provider.tf` and replace `CHANGE_ME` with your S3 bucket name:

```hcl
backend "s3" {
  bucket = "your-terraform-state-bucket"
  key    = "rds-mssql-proxy/terraform.tfstate"
  region = "ap-southeast-3"
}
```

### 2. Create your variables file

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your actual tag names:

```hcl
vpc_tag_name            = "production-vpc"
db_subnet_tag_name      = "db-subnet-*"
private_subnet_tag_name = "private-subnet-*"
```

> **Note:** The subnet tag filters support wildcards. Use `*` to match multiple subnets (e.g. `private-subnet-*` matches `private-subnet-1a`, `private-subnet-1b`).

### 3. Initialize Terraform

```bash
terraform init
```

### 4. Review the plan

```bash
terraform plan
```

### 5. Apply

```bash
terraform apply
```

### 6. Get connection info

After apply completes:

```bash
# RDS Proxy endpoint (use this in your application)
terraform output rds_proxy_endpoint

# Direct RDS endpoint (for admin/debug only)
terraform output rds_instance_endpoint

# Secrets Manager ARN (retrieve credentials from here)
terraform output rds_credentials_secret_arn
```

## Retrieving Database Credentials

The master password is stored in AWS Secrets Manager. To retrieve it:

```bash
aws secretsmanager get-secret-value \
  --secret-id $(terraform output -raw rds_credentials_secret_arn) \
  --region ap-southeast-3 \
  --query SecretString \
  --output text
```

## Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `vpc_tag_name` | Tag Name to filter existing VPC | (required) |
| `db_subnet_tag_name` | Tag Name to filter DB subnets | (required) |
| `private_subnet_tag_name` | Tag Name to filter private subnets | (required) |
| `project_name` | Project name for resource naming | `mssql-proxy` |
| `environment` | Environment name | `dev` |
| `db_username` | Master DB username | `admin` |
| `db_instance_class` | RDS instance class | `db.t3.xlarge` |
| `db_allocated_storage` | Initial storage (GB) | `20` |
| `db_max_allocated_storage` | Max autoscale storage (GB) | `100` |
| `db_engine_version` | MSSQL engine version | `16.00` |

## Destroy

```bash
terraform destroy
```

## Notes

- **Instance class:** `db.t3.xlarge` is the smallest supported class for MSSQL Enterprise Edition.
- **Multi-AZ:** Disabled for non-prod cost savings. Set `multi_az = true` in `rds.tf` for production.
- **TLS:** Enforced on RDS Proxy connections.
- **Storage:** gp3 with encryption enabled.
- **Deletion protection:** Disabled for dev. Enable for production workloads.
