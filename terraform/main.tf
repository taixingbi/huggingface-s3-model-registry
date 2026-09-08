terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state is account-specific — fill this in (or pass via -backend-config
  # in CI) rather than hardcoding a bucket/table here.
  # backend "s3" {
  #   bucket         = "REPLACE_ME-terraform-state"
  #   key            = "huggingface-s3-model-registry/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "REPLACE_ME-terraform-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.tags
  }
}

data "aws_caller_identity" "current" {}
