# S3 (backups + static assets) and CloudTrail (management-event audit log).
# Both are already-committed parts of the Phase 1 architecture and cost
# table (ceiba_aws_deployment_strategy.md §3, §6; README cost table's "S3"
# and "Observability" lines) — not new resources introduced here, just the
# not-yet-codified half of what vpc.tf/ec2.tf/rds.tf already assume exists.
#
# Note on file layout: the README's declared terraform/ layout lists
# vpc.tf/ec2.tf/rds.tf/iam.tf/budgets.tf/cloudwatch-billing-alarm.tf
# explicitly; this file and outputs.tf/variables.tf/providers.tf are
# necessary supporting files the README's list wasn't meant to enumerate
# exhaustively (see this pass's summary output, item 2).

resource "aws_s3_bucket" "backups" {
  bucket = "ceiba-prod-backups-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name = "ceiba-backups"
  }
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket = aws_s3_bucket.backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Cost hygiene: RDS automated backups already cover the primary recovery
# path (rds.tf, 7-day retention). This bucket is for the periodic *manual*
# snapshot export the strategy doc calls for as an off-instance copy — keep
# it small by expiring old exports rather than retaining forever.
resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "expire-old-manual-snapshots"
    status = "Enabled"

    filter {
      prefix = "manual-snapshots/"
    }

    expiration {
      days = 90
    }
  }
}

data "aws_caller_identity" "current" {}

# --- CloudTrail ------------------------------------------------------------

data "aws_iam_policy_document" "cloudtrail_bucket_policy" {
  statement {
    sid    = "AWSCloudTrailAclCheck"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.backups.arn]
  }

  statement {
    sid    = "AWSCloudTrailWrite"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.backups.arn}/cloudtrail/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.backups.id
  policy = data.aws_iam_policy_document.cloudtrail_bucket_policy.json
}

resource "aws_cloudtrail" "ceiba" {
  name                          = "ceiba-management-events"
  s3_bucket_name                = aws_s3_bucket.backups.id
  s3_key_prefix                 = "cloudtrail"
  include_global_service_events = true
  is_multi_region_trail         = false
  enable_log_file_validation    = true

  depends_on = [aws_s3_bucket_policy.cloudtrail]

  tags = {
    Name = "ceiba-cloudtrail"
  }
}
