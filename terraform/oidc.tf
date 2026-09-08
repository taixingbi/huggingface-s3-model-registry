# -----------------------------------------------------------------------------
# GitHub Actions OIDC federation — lets workflows in github_org/github_repo
# assume AWS roles with short-lived, per-run credentials. No AWS access key
# or secret key is ever stored in GitHub.
#
# NOTE (bootstrap): an AWS account can only have one OIDC provider per issuer
# URL. If your account already has a "token.actions.githubusercontent.com"
# provider (e.g. shared across repos), set create_oidc_provider = false and
# pass its ARN via existing_oidc_provider_arn instead of creating a second one.
# -----------------------------------------------------------------------------

variable "create_oidc_provider" {
  description = "Whether to create the GitHub Actions OIDC provider in this account. Set false if one already exists and pass existing_oidc_provider_arn."
  type        = bool
  default     = true
}

variable "existing_oidc_provider_arn" {
  description = "ARN of an existing GitHub Actions OIDC provider, used when create_oidc_provider = false."
  type        = string
  default     = null
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  count = var.create_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]

  # GitHub's OIDC signing certificate root thumbprint. AWS has validated
  # against the full CA chain (not just this pinned value) since 2023, but
  # the argument is still required by the resource.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github_actions[0].arn : var.existing_oidc_provider_arn
}
