terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Shared by local runs and CI (.github/workflows/terraform-*.yml) so both
  # see the same state — without this, CI starts from empty state every run
  # and tries to recreate resources that already exist.
  backend "s3" {
    bucket         = "huggingface-s3-model-registry-tfstate-646821141010"
    key            = "huggingface-s3-model-registry/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "huggingface-s3-model-registry-tf-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.tags
  }
}

data "aws_caller_identity" "current" {}
