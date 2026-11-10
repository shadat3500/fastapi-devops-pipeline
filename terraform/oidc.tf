# GitHub Actions -> AWS without long-lived keys: the workflow exchanges its OIDC token
# for short-lived credentials of this role (aws-actions/configure-aws-credentials).

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  github_oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

data "aws_iam_policy_document" "github_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only jobs of THIS repo running in the matching GitHub *environment* may assume
    # the role (the deploy job declares `environment: staging|production`), so a PR
    # from a fork or another branch can't deploy.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:environment:${var.environment}"]
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  name                 = "${local.name}-github-deploy"
  description          = "Assumed by GitHub Actions (OIDC) to deploy devops-app to ${var.environment}"
  assume_role_policy   = data.aws_iam_policy_document.github_assume.json
  max_session_duration = 3600
}

# Least privilege: run shell commands on THIS instance only, and read the result.
data "aws_iam_policy_document" "github_deploy" {
  statement {
    sid     = "SendDeployCommandToThisInstance"
    actions = ["ssm:SendCommand"]
    resources = [
      aws_instance.app.arn,
      "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript",
    ]
  }

  statement {
    sid       = "ReadCommandResults"
    actions   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
    resources = ["*"] # these actions don't support resource-level permissions
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  name   = "ssm-deploy"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.github_deploy.json
}
