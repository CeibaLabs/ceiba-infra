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

  statement {
    sid       = "ReadRdsMasterCredential"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.ceiba.master_user_secret[0].secret_arn]
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

locals {
  app_secret_names = [
    "stripe-secret-key",
    "stripe-webhook-secret",
    "clerk-secret-key",
    "clerk-publishable-key",
    "resend-api-key",
    "seed-starter-stripe-price-id",
    "seed-pro-stripe-price-id",
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
