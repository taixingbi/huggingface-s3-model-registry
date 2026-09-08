# -----------------------------------------------------------------------------
# IAM roles assumed by GitHub Actions via OIDC.
#
#   gha-plan      -> read-only, assumable from any ref of the repo (PRs included)
#   gha-apply     -> terraform apply, assumable only from github_branch
#   gha-sync      -> sync_models.py write access, assumable only from github_branch
#   registry-read -> attach to EKS/vLLM/RAG service roles that only ever read
#
# NOTE (sub claim format): repos created after 2026-07-15 get GitHub's
# "immutable subject claim" format by default — the sub embeds the numeric
# owner/repo IDs, e.g. repo:OWNER@OWNER_ID/REPO@REPO_ID:ref:refs/heads/main,
# instead of the classic repo:OWNER/REPO:ref:refs/heads/main. This repo uses
# that new format (confirmed via CloudTrail), so github_owner_id /
# github_repo_id below are required, not cosmetic.
# -----------------------------------------------------------------------------

locals {
  # repo:OWNER@OWNER_ID/REPO@REPO_ID — see NOTE above.
  github_sub_repo = "${var.github_org}@${var.github_owner_id}/${var.github_repo}@${var.github_repo_id}"

  # The tfstate S3 bucket + DynamoDB lock table (main.tf backend block) are
  # bootstrapped by hand outside this config, so their names/ARNs are
  # literals here rather than resource references — keep in sync with main.tf.
  tf_state_bucket   = "huggingface-s3-model-registry-tfstate-${var.aws_account_id}"
  tf_state_key      = "huggingface-s3-model-registry/terraform.tfstate"
  tf_lock_table_arn = "arn:aws:dynamodb:${var.aws_region}:${var.aws_account_id}:table/huggingface-s3-model-registry-tf-lock"
}

data "aws_iam_policy_document" "gha_assume_any_ref" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.github_sub_repo}:*"]
    }
  }
}

data "aws_iam_policy_document" "gha_assume_protected_branch" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.github_sub_repo}:ref:refs/heads/${var.github_branch}"]
    }
  }
}

# terraform-apply.yml runs its job with `environment: production`. Any job
# that declares a GitHub Actions `environment:` gets an OIDC sub claim of
# repo:.../...:environment:NAME instead of repo:.../...:ref:refs/heads/BRANCH
# — so gha_apply needs its own trust condition matching that form, not the
# branch-ref one used by gha_assume_protected_branch above.
data "aws_iam_policy_document" "gha_assume_environment" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.github_sub_repo}:environment:${var.github_environment}"]
    }
  }
}

# --- terraform plan (read-only, any ref / PRs) -------------------------------

resource "aws_iam_role" "gha_plan" {
  name               = "gha-huggingface-registry-plan"
  assume_role_policy = data.aws_iam_policy_document.gha_assume_any_ref.json
}

resource "aws_iam_role_policy" "gha_plan" {
  name   = "terraform-plan-readonly"
  role   = aws_iam_role.gha_plan.id
  policy = data.aws_iam_policy_document.plan_readonly.json
}

# Separate from plan_readonly above because that data source is also reused
# by aws_iam_role_policy.registry_read (the EKS/vLLM/RAG consumer role),
# which must never get access to the tfstate bucket/lock table.
resource "aws_iam_role_policy" "gha_plan_state" {
  name   = "terraform-state-read"
  role   = aws_iam_role.gha_plan.id
  policy = data.aws_iam_policy_document.terraform_state_read.json
}

data "aws_iam_policy_document" "terraform_state_read" {
  statement {
    sid    = "TerraformStateS3Read"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::${local.tf_state_bucket}",
      "arn:aws:s3:::${local.tf_state_bucket}/${local.tf_state_key}",
    ]
  }

  statement {
    sid    = "TerraformStateLock"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
    ]
    resources = [local.tf_lock_table_arn]
  }
}

data "aws_iam_policy_document" "plan_readonly" {
  statement {
    sid    = "S3Read"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
      "s3:GetBucketPolicy",
      "s3:GetEncryptionConfiguration",
      "s3:GetLifecycleConfiguration",
    ]
    resources = [
      aws_s3_bucket.model_registry.arn,
      "${aws_s3_bucket.model_registry.arn}/*",
    ]
  }

  statement {
    sid       = "IamRead"
    effect    = "Allow"
    actions   = ["iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:GetOpenIDConnectProvider"]
    resources = ["*"]
  }
}

# --- terraform apply (write, main branch only) --------------------------------

resource "aws_iam_role" "gha_apply" {
  name               = "gha-huggingface-registry-apply"
  assume_role_policy = data.aws_iam_policy_document.gha_assume_environment.json
}

resource "aws_iam_role_policy" "gha_apply" {
  name   = "terraform-apply"
  role   = aws_iam_role.gha_apply.id
  policy = data.aws_iam_policy_document.apply_write.json
}

resource "aws_iam_role_policy" "gha_apply_state" {
  name   = "terraform-state-write"
  role   = aws_iam_role.gha_apply.id
  policy = data.aws_iam_policy_document.terraform_state_write.json
}

data "aws_iam_policy_document" "terraform_state_write" {
  statement {
    sid    = "TerraformStateS3Write"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::${local.tf_state_bucket}",
      "arn:aws:s3:::${local.tf_state_bucket}/${local.tf_state_key}",
    ]
  }

  statement {
    sid    = "TerraformStateLock"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
    ]
    resources = [local.tf_lock_table_arn]
  }
}

data "aws_iam_policy_document" "apply_write" {
  statement {
    sid    = "S3Manage"
    effect = "Allow"
    actions = [
      "s3:*",
    ]
    resources = [
      aws_s3_bucket.model_registry.arn,
      "${aws_s3_bucket.model_registry.arn}/*",
    ]
  }

  statement {
    sid    = "IamManageScoped"
    effect = "Allow"
    actions = [
      "iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
      "iam:CreateRole", "iam:DeleteRole", "iam:TagRole",
      "iam:PutRolePolicy", "iam:DeleteRolePolicy",
      "iam:GetOpenIDConnectProvider", "iam:UpdateOpenIDConnectProviderThumbprint",
    ]
    resources = [
      "arn:aws:iam::${var.aws_account_id}:role/gha-huggingface-registry-*",
      "arn:aws:iam::${var.aws_account_id}:role/registry-read",
      "arn:aws:iam::${var.aws_account_id}:oidc-provider/token.actions.githubusercontent.com",
    ]
  }
}

# --- model sync (write, main branch only) -------------------------------------

resource "aws_iam_role" "gha_sync" {
  name               = "gha-huggingface-registry-sync"
  assume_role_policy = data.aws_iam_policy_document.gha_assume_protected_branch.json
}

resource "aws_iam_role_policy" "gha_sync" {
  name   = "sync-models-write"
  role   = aws_iam_role.gha_sync.id
  policy = data.aws_iam_policy_document.sync_write.json
}

data "aws_iam_policy_document" "sync_write" {
  statement {
    sid    = "SyncModelsToRegistry"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.model_registry.arn,
      "${aws_s3_bucket.model_registry.arn}/*",
    ]
  }
}

# --- consumer role (EKS / vLLM / RAG services reading the registry) ----------

resource "aws_iam_role" "registry_read" {
  name = "registry-read"

  # Placeholder trust policy — replace with your EKS OIDC provider / IRSA
  # trust relationship, or reference this policy document from an existing
  # node/service role instead of using this role directly.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${var.aws_account_id}:root" }
      Action    = "sts:AssumeRole"
      Condition = {}
    }]
  })
}

resource "aws_iam_role_policy" "registry_read" {
  name   = "read-model-registry"
  role   = aws_iam_role.registry_read.id
  policy = data.aws_iam_policy_document.plan_readonly.json
}

output "gha_plan_role_arn" {
  value = aws_iam_role.gha_plan.arn
}

output "gha_apply_role_arn" {
  value = aws_iam_role.gha_apply.arn
}

output "gha_sync_role_arn" {
  value = aws_iam_role.gha_sync.arn
}

output "registry_read_role_arn" {
  value = aws_iam_role.registry_read.arn
}
