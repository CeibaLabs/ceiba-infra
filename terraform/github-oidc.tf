# GitHub Actions authenticates to AWS via OIDC federation — short-lived,
# per-run credentials, no long-lived access key stored in any repository
# secret. Two roles, deliberately not one, because they have genuinely
# different blast radii:
#   - ceiba-github-plan:   read-only, terraform-plan.yml (ceiba-infra only)
#   - ceiba-github-deploy: ECR push + SSM SendCommand, the two app repos' CD

# Fetched live rather than hardcoded. AWS has validated OIDC IdP TLS
# certificates against its own trusted root CA store since July 2023 for any
# provider reachable over TLS (GitHub included) — the thumbprint_list
# argument is still required by the resource schema, but AWS does not
# actually check it in that case. Fetching it live means this file can never
# carry a stale or wrong value, which matters in a repo that has already
# shipped one confidently-wrong IAM comment (the pre-fix ec2:StopInstances
# scoping). It does mean `terraform plan` needs network access to
# token.actions.githubusercontent.com, which is already true of this
# configuration for other reasons (STS credential validation, AMI lookup).
data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]

  tags = {
    Name = "ceiba-github-actions"
  }
}

# --- Plan role: read-only, ceiba-infra's own terraform-plan.yml ------------
#
# Trust is pinned to the exact `sub` claim GitHub issues for this workflow's
# actual trigger. .github/workflows/terraform-plan.yml runs on `pull_request`
# only (not push) — for that event GitHub does not include a ref, and the sub
# claim is exactly "repo:CeibaLabs/ceiba-infra:pull_request". If that
# workflow's trigger ever changes (e.g. to also run on push), this condition
# must change with it or the role will stop trusting the workflow — a
# deliberate fail-closed choice over a loose repo:CeibaLabs/ceiba-infra:*
# match that would trust every ref indiscriminately.
data "aws_iam_policy_document" "github_plan_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:CeibaLabs/ceiba-infra:pull_request"]
    }
  }
}

resource "aws_iam_role" "github_plan" {
  name               = "ceiba-github-plan"
  assume_role_policy = data.aws_iam_policy_document.github_plan_assume_role.json
}

resource "aws_iam_role_policy_attachment" "github_plan_read_only" {
  role       = aws_iam_role.github_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# --- Deploy role: CD for the two app repos ---------------------------------
#
# Trust is pinned to a specific branch ref per repo, not repo:OWNER/REPO:*.
# The looser form would let ANY branch pushed to either app repo — not just
# the one CD actually deploys from — assume a role that can push images and
# run shell commands on the production host. var.cd_deploy_branch names the
# one branch CD watches; change it there, not by widening this trust policy.
data "aws_iam_policy_document" "github_deploy_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:CeibaLabs/ceiba-runtime:ref:refs/heads/${var.cd_deploy_branch}",
        "repo:CeibaLabs/ceiba-control-plane:ref:refs/heads/${var.cd_deploy_branch}",
      ]
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  name               = "ceiba-github-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_deploy_assume_role.json
}

# ECR: push and pull, scoped to the two repositories ecr.tf provisions.
# GetAuthorizationToken genuinely has no resource-level support (same
# confirmed exception as the EC2 pull role in iam.tf) and sits in its own
# statement; everything else is scoped to the two repository ARNs, nothing
# wider — this role can push images, it cannot create or delete a repository.
data "aws_iam_policy_document" "github_deploy_ecr" {
  statement {
    sid       = "EcrAuthToken"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPushPullCeibaRepos"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = [
      aws_ecr_repository.runtime.arn,
      aws_ecr_repository.control_plane.arn,
    ]
  }
}

resource "aws_iam_role_policy" "github_deploy_ecr" {
  name   = "ceiba-github-deploy-ecr"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.github_deploy_ecr.json
}

# SSM: run the deploy script on the one app host via Run Command.
#
# ssm:SendCommand requires the caller to have access to BOTH the target and
# the document — a single statement listing both ARNs, not two separate
# statements — confirmed against AWS's Systems Manager IAM documentation
# (docs.aws.amazon.com/systems-manager/latest/userguide/
# auth-and-access-control-iam-access-control-identity-based.html, fetched
# 2026-08-15). The target for a real EC2 instance (not a hybrid/on-prem
# node) is expressed as an ssm: managed-instance ARN using the EC2 instance
# ID, NOT an ec2: instance ARN — SSM's own resource-type table lists only
# "Managed node | arn:aws:ssm:{region}:{account-id}:managed-instance/{id}",
# with no ec2:instance resource type for this service. Getting this backwards
# is exactly the class of mistake that shipped once already in this repo
# (the original, factually wrong ec2:StopInstances comment) — verified
# against the current docs rather than assumed from memory.
#
# AWS-RunShellScript is an AWS-owned public document; its ARN carries no
# account ID, per the same documentation.
data "aws_iam_policy_document" "github_deploy_ssm" {
  statement {
    sid     = "SsmSendCommandToAppHost"
    actions = ["ssm:SendCommand"]
    resources = [
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:managed-instance/${aws_instance.app.id}",
      "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript",
    ]
  }

  statement {
    # GetCommandInvocation / ListCommandInvocations read back a command's
    # output and exit status — needed to know whether the deploy script (and
    # its own digest/health checks) actually succeeded. SSM's documented
    # resource-type table has no dedicated resource type for a command
    # invocation, so resource-level scoping for these two actions was not
    # confirmed rather than guessed at; "*" is deliberate, not an oversight,
    # and both actions are read-only status checks, not mutations.
    sid = "SsmReadCommandStatus"
    actions = [
      "ssm:GetCommandInvocation",
      "ssm:ListCommandInvocations",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_deploy_ssm" {
  name   = "ceiba-github-deploy-ssm"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.github_deploy_ssm.json
}
