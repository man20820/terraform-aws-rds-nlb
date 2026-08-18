# Terraform AWS RDS MSSQL with Network Load Balancer

Provisions an AWS RDS SQL Server Enterprise instance on a DB subnet with a Network Load Balancer (NLB) in front, deployed in the Jakarta region (`ap-southeast-3`). A Lambda function keeps the NLB target group in sync with the RDS endpoint IP on failover.

> Forked from a previous RDS + RDS Proxy setup. RDS Proxy was replaced with an NLB to avoid [SQL Server version compatibility limitations](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy.html) and to support SQL Server 2022.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                              VPC                                      │
│                                                                      │
│  ┌─────────────────────────┐       ┌─────────────────────────────┐  │
│  │     Private Subnets     │       │        DB Subnets            │  │
│  │                         │       │                              │  │
│  │  ┌───────────────────┐  │       │  ┌───────────────────────┐  │  │
│  │  │   NLB (TCP:1433)  │──┼───────┼─▶│  RDS MSSQL Enterprise │  │  │
│  │  └───────────────────┘  │       │  │  (db.t3.xlarge)        │  │  │
│  │           ▲              │       │  └───────────────────────┘  │  │
│  └───────────┼─────────────┘       └─────────────────────────────┘  │
│              │                                     ▲                  │
│              │                                     │                  │
│  ┌───────────┼─────────────────────────────────────┼──────────────┐  │
│  │    EventBridge                          Lambda (IP Updater)    │  │
│  │  • RDS failover events ──────────────▶  Resolves RDS DNS      │  │
│  │  • Every 5 minutes    ──────────────▶  Updates NLB targets    │  │
│  └────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
```

## How It Works

1. **NLB** listens on TCP port 1433 and forwards traffic to an IP-type target group.
2. At deploy time, the RDS endpoint DNS is resolved and the IP is registered as the initial target.
3. A **Lambda function** (`update_nlb_target.mjs`) handles IP drift:
   - Triggered by **EventBridge** on RDS failover events (`RDS-EVENT-0049/0050/0051/0053`).
   - Also runs on a **5-minute schedule** as a safety net.
   - Resolves the RDS endpoint, deregisters stale IPs, and registers the current IP.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.0
- AWS CLI configured with appropriate credentials
- An existing VPC with tagged subnets (DB subnets + private subnets)
- An existing S3 bucket for Terraform state

## Quick Start

### 1. Configure backend

Edit `provider.tf` and set your S3 bucket name:

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

> **Note:** Subnet tag filters support wildcards. Use `*` to match multiple subnets (e.g. `private-subnet-*` matches `private-subnet-1a`, `private-subnet-1b`).

### 3. Deploy

```bash
terraform init
terraform plan
terraform apply
```

### 4. Get connection info

```bash
# NLB endpoint (use this in your application)
terraform output nlb_dns_name

# Direct RDS endpoint (for admin/debug only)
terraform output rds_instance_endpoint

# Secrets Manager ARN (retrieve credentials from here)
terraform output rds_credentials_secret_arn
```

## Retrieving Database Credentials

The master password is stored in AWS Secrets Manager:

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
| `tags` | Common tags to apply to all resources | `{}` |

## Outputs

| Output | Description |
|--------|-------------|
| `nlb_dns_name` | NLB DNS name (application connection endpoint) |
| `nlb_arn` | ARN of the Network Load Balancer |
| `rds_instance_endpoint` | Direct RDS endpoint (admin use) |
| `rds_instance_id` | RDS instance identifier |
| `rds_instance_port` | RDS instance port |
| `rds_credentials_secret_arn` | Secrets Manager secret ARN |
| `rds_security_group_id` | RDS security group ID |
| `nlb_security_group_id` | NLB security group ID |
| `lambda_nlb_updater_function_name` | Lambda function name |
| `lambda_nlb_updater_arn` | Lambda function ARN |

## Project Structure

```
.
├── data.tf                  # VPC and subnet data sources
├── lambda/
│   └── update_nlb_target.mjs  # Lambda: resolves RDS IP and updates NLB targets
├── lambda_nlb_updater.tf    # Lambda function, EventBridge rules, permissions
├── nlb.tf                   # Network Load Balancer, target group, listener
├── outputs.tf               # Terraform outputs
├── provider.tf              # Provider config and S3 backend
├── rds.tf                   # RDS instance, Secrets Manager, subnet group
├── security_groups.tf       # Security groups for RDS and NLB
├── variables.tf             # Input variables
└── terraform.tfvars.example # Example variable values
```

## Why NLB Instead of RDS Proxy?

AWS RDS Proxy does **not** support SQL Server 2022 (engine version `16.00`). The supported versions are limited to SQL Server 2016–2019. Using an NLB removes this constraint and allows running the latest SQL Server engine.

The tradeoff is that NLB doesn't provide connection pooling or IAM-based authentication the way RDS Proxy does. The Lambda + EventBridge pattern handles the main operational concern (IP changes during failover) automatically.

## Destroy

```bash
terraform destroy
```

## Notes

- **Instance class:** `db.t3.xlarge` is the smallest supported class for MSSQL Enterprise Edition.
- **Multi-AZ:** Disabled for non-prod cost savings. Set `multi_az = true` in `rds.tf` for production.
- **Storage:** gp3 with encryption enabled.
- **Deletion protection:** Disabled for dev. Enable for production workloads.
- **Lambda runtime:** Node.js 22.x using the AWS SDK v3.
- **DNS provider:** The `hashicorp/dns` provider is used at plan/apply time for initial target registration.
