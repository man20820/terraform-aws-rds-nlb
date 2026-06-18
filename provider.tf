terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  backend "s3" {
    bucket = "CHANGE_ME"            # <-- set your S3 bucket name here
    key    = "rds-mssql-proxy/terraform.tfstate"
    region = "ap-southeast-3"
  }
}

provider "aws" {
  region = var.aws_region
}
