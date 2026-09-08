variable "aws_region" {
  description = "AWS region the registry bucket and IAM resources live in."
  type        = string
  default     = "us-east-1"
}

variable "aws_account_id" {
  description = "AWS account ID that owns the registry bucket (used to build the default bucket name and IAM ARNs)."
  type        = string
}

variable "bucket_name" {
  description = "Name of the S3 bucket used as the Hugging Face model registry. Defaults to huggingface-model-registry-<account>-<region>."
  type        = string
  default     = null
}

variable "github_org" {
  description = "GitHub organization or user that owns the repo allowed to assume the CI role via OIDC."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name (without org prefix), e.g. huggingface-s3-model-registry."
  type        = string
  default     = "huggingface-s3-model-registry"
}

variable "github_owner_id" {
  description = "Numeric GitHub user/org ID for github_org. Required because this repo was created after 2026-07-15 and uses GitHub's immutable OIDC subject-claim format (repo:OWNER@OWNER_ID/REPO@REPO_ID:...) instead of the classic repo:OWNER/REPO:... form. Find it via CloudTrail (userIdentity.userName on a failed/succeeded AssumeRoleWithWebIdentity event) or `gh api users/<org>` -> .id."
  type        = string
  default     = "23156713"
}

variable "github_repo_id" {
  description = "Numeric GitHub repository ID for github_repo. See github_owner_id for why this is required. Find it via `gh api repos/<org>/<repo>` -> .id."
  type        = string
  default     = "1361377686"
}

variable "github_branch" {
  description = "Branch allowed to assume the sync-models role via OIDC (that workflow has no `environment:` key, so its OIDC sub claim is branch-ref based). Pull requests from other branches only get plan/read access."
  type        = string
  default     = "main"
}

variable "github_environment" {
  description = "GitHub Actions environment name that gates the terraform-apply role. Must match the `environment:` value set on the apply job in terraform-apply.yml, since that changes the workflow's OIDC sub claim to repo:ORG/REPO:environment:NAME."
  type        = string
  default     = "production"
}

variable "model_type_prefixes" {
  description = "Top-level prefixes ('folders') maintained in the registry bucket."
  type        = list(string)
  default     = ["inference", "embedding", "reranker", "classifier"]
}

variable "noncurrent_version_expiration_days" {
  description = "Days to retain noncurrent object versions before they are expired."
  type        = number
  default     = 90
}

variable "tags" {
  description = "Common tags applied to all resources."
  type        = map(string)
  default = {
    Project   = "huggingface-s3-model-registry"
    ManagedBy = "terraform"
  }
}

locals {
  bucket_name = coalesce(var.bucket_name, "huggingface-model-registry-${var.aws_account_id}-${var.aws_region}")
}
