# Least-privilege IAM per ceiba_aws_deployment_strategy.md §6.
# No long-lived access keys anywhere — EC2 and Lambda assume roles.

# --- EC2 instance role -------------------------------------------------

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "ceiba-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

# Enables AWS Systems Manager Session Manager — this is how the operator
# reaches a shell on the instance instead of SSH. No port 22 is open in
# vpc.tf's aws_security_group.ec2 by design.
resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "ec2_secrets_read" {
  statement {
    sid       = "ReadCeibaSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [for s in aws_secretsmanager_secret.app : s.arn]
  }
}

resource "aws_iam_role_policy" "ec2_secrets_read" {
  name   = "ceiba-ec2-secrets-read"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.ec2_secrets_read.json
}

data "aws_iam_policy_document" "ec2_s3_backups" {
  statement {
    sid = "BackupBucketReadWrite"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.backups.arn,
      "${aws_s3_bucket.backups.arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "ec2_s3_backups" {
  name   = "ceiba-ec2-s3-backups"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.ec2_s3_backups.json
}

# Pull only, from the two repositories the app images actually live in
# (ecr.tf) - the host must never be able to push. Split into two statements
# because the three actions do not share resource-level support, confirmed
# against AWS's Service Authorization Reference for Amazon ECR (2026-07-30)
# rather than assumed - the apply-blockers fix earlier in this repo's
# history was a confidently-worded IAM comment that turned out to be wrong,
# and this statement split exists specifically so that doesn't repeat.
data "aws_iam_policy_document" "ec2_ecr_pull" {
  statement {
    # ecr:GetAuthorizationToken genuinely has no resource-level support -
    # it must be "*", regardless of which repositories are pulled from.
    sid       = "EcrAuthToken"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    # These three DO support resource-level permissions - scoped to the two
    # repository ARNs this host is meant to pull from, nothing wider.
    sid = "EcrPullFromCeibaRepos"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
    ]
    resources = [
      aws_ecr_repository.runtime.arn,
      aws_ecr_repository.control_plane.arn,
    ]
  }
}

resource "aws_iam_role_policy" "ec2_ecr_pull" {
  name   = "ceiba-ec2-ecr-pull"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.ec2_ecr_pull.json
}

resource "aws_iam_instance_profile" "ec2" {
  name = "ceiba-ec2-profile"
  role = aws_iam_role.ec2.name
}

# --- App secrets placeholders -------------------------------------------
#
# Containers only — Terraform creates the Secrets Manager entries but never
# writes real values into them (no aws_secretsmanager_secret_version here).
# The operator populates real values out-of-band, post-apply:
#   aws secretsmanager put-secret-value --secret-id ceiba/stripe-secret-key --secret-string '...'
# This keeps real credentials out of both git and Terraform state.

# Every name here must also appear in deploy/bootstrap-host.sh's FLAT_SECRETS
# (or, for the database, as APP_DB_SECRET). A name in one and not the other is
# either a secret nothing consumes or a secret nothing creates.
locals {
  app_secret_names = [
    "stripe-secret-key",
    "stripe-webhook-secret",
    "clerk-secret-key",
    "clerk-publishable-key",
    "resend-api-key",
    "seed-starter-stripe-price-id",
    "seed-pro-stripe-price-id",

    # Runtime database credential: the dedicated ceiba_app role, NOT the
    # RDS-managed master. Long-running containers connect with this; the
    # master credential is for migrations and admin only and never reaches
    # deploy/.env. Added after the 2026-08-27 outage, where the master
    # password's 7-day automatic rotation broke every container that had it
    # baked into .env at provisioning time.
    "production/app-database",

    # --- Added 2026-08-31 ---------------------------------------------------
    # These five existed ONLY in deploy/.env on the running host: not in
    # Secrets Manager, not in Terraform, not in git. When aws_instance.app was
    # replaced on 2026-08-17 they were destroyed with it and had to be
    # reconstructed by hand from external dashboards.
    #
    # What makes them dangerous is that every one fails SILENTLY. Nothing
    # crashes, no readiness check goes red, no alarm fires - a webhook simply
    # stops verifying, analytics simply stops recording, receipt email simply
    # stops sending. The stack looks perfectly healthy while quietly doing
    # less than it should.
    #
    # The last four are not secret in the cryptographic sense (the PostHog
    # key ships to the browser; the receipt addresses are on outbound mail).
    # They are here for DURABILITY, not confidentiality - one uniform place a
    # replacement host can rebuild its entire .env from, unattended. That is
    # worth ~$0.40/secret/month against a repeat of the 2026-08-17 recovery.
    "clerk-webhook-signing-secret",
    "posthog-key",
    "posthog-host",
    "receipt-from-email",
    "receipt-reply-to",
    "acme-email"
  ]
}

resource "aws_secretsmanager_secret" "app" {
  for_each = toset(local.app_secret_names)

  name        = "ceiba/${each.value}"
  description = "Ceiba production secret: ${each.value}. Value set out-of-band by the operator, never via Terraform."
}

# --- Lambda auto-shutdown execution role --------------------------------
#
# Exactly the policy from ceiba_aws_deployment_strategy.md §5.2 — nothing
# more than stop/describe the instance and write its own logs.

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_auto_shutdown" {
  name               = "ceiba-auto-shutdown-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "lambda_auto_shutdown" {
  statement {
    # ec2:StopInstances DOES support resource-level permissions (resource
    # type "instance", arn:aws:ec2:region:account-id:instance/instance-id) —
    # scoped directly to the one instance this Lambda is meant to stop, not
    # every instance in the account. A Name-tag filter in handler.py is
    # still there for defense in depth, but it is application logic, not a
    # security boundary — the IAM scope is the real boundary.
    sid       = "StopCeibaInstance"
    actions   = ["ec2:StopInstances"]
    resources = [aws_instance.app.arn]
  }

  statement {
    # ec2:DescribeInstances genuinely does not support resource-level
    # permissions — "*" is correct and required here, not a scoping gap.
    sid       = "DescribeInstances"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    sid       = "LambdaOwnLogs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:*:*"]
  }
}

resource "aws_iam_role_policy" "lambda_auto_shutdown" {
  name   = "ceiba-auto-shutdown-lambda-policy"
  role   = aws_iam_role.lambda_auto_shutdown.id
  policy = data.aws_iam_policy_document.lambda_auto_shutdown.json
}
