# -----------------------------------------------------------------------------
# IAM roles assumed by GitHub Actions via OIDC.
#
#   gha-plan      -> read-only, assumable from any ref of the repo (PRs included)
#   gha-apply     -> terraform apply, assumable only from github_branch
#   gha-sync      -> sync_models.py write access, assumable only from github_branch
#   registry-read -> attach to EKS/vLLM/RAG service roles that only ever read
# -----------------------------------------------------------------------------

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
      values   = ["repo:${var.github_org}/${var.github_repo}:*"]
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
      values   = ["repo:${var.github_org}/${var.github_repo}:ref:refs/heads/${var.github_branch}"]
    }
  }
}

# terraform-apply.yml runs its job with `environment: production`. Any job
# that declares a GitHub Actions `environment:` gets an OIDC sub claim of
# repo:ORG/REPO:environment:NAME instead of repo:ORG/REPO:ref:refs/heads/BRANCH
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
      values   = ["repo:${var.github_org}/${var.github_repo}:environment:${var.github_environment}"]
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
    actions   = ["iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:GetOpenIDConnectProvider"]
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
      "iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies",
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
