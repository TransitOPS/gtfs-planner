locals {
  token_domain = "token.actions.githubusercontent.com"
  audience     = "sts.amazonaws.com"
}

resource "aws_iam_openid_connect_provider" "this" {
  client_id_list = [local.audience]
  # AWS manages the thumbprints independently now
  thumbprint_list = ["0000000000000000000000000000000000000000"]
  url             = "https://${local.token_domain}"

  lifecycle {
    ignore_changes = [thumbprint_list]
  }
}

resource "aws_iam_role" "this" {
  name               = var.github_actions_role_name
  description        = "Role assumed by GitHub Actions"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_role_policy" "permissions" {
  count = length(var.permissions) > 0 ? 1 : 0
  name  = "permissions"
  role  = aws_iam_role.this.id

  # checkov:skip=CKV_AWS_288:permissions are limited at the account level
  # checkov:skip=CKV_AWS_289
  # checkov:skip=CKV_AWS_290
  # checkov:skip=CKV_AWS_355
  policy = jsonencode(
    {
      Version = "2012-10-17"
      Statement = [
        {
          Action   = var.permissions
          Effect   = "Allow"
          Resource = "*"
        }
      ]
    }
  )
}

# https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws
data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringLike"
      variable = "${local.token_domain}:sub"
      values   = ["repo:${var.github_repo}:*"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.token_domain}:aud"
      values   = [local.audience]
    }

    principals {
      identifiers = [aws_iam_openid_connect_provider.this.arn]
      type        = "Federated"
    }
  }
}
