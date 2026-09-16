# EC2 instance lifecycle audit trail.
#
# WHY THIS EXISTS
# ---------------
# Two separate incidents made the case:
#
# 1. 2026-08-17 — a `terraform apply` intended only to fix an IAM policy also
#    replaced aws_instance.app, destroying deploy/.env with it. Reconstructing
#    what happened took real effort, weeks later, from indirect evidence. A
#    lifecycle log would have shown `shutting-down -> terminated` on one
#    instance and `pending -> running` on its replacement, at exact times, in
#    one place.
#
# 2. 2026-09-14 — the billing-guardrail drill could not report when the
#    instance reached `stopping` or `stopped`. Polling `describe-instances`
#    19 seconds after the stop already returned `stopped`.
#
# WHY POLLING AND CLOUDTRAIL BOTH FAIL HERE
# -----------------------------------------
# `describe-instances` is a point-in-time call, not a state-history mechanism -
# it reports what is true now. A transition completing in under 19 seconds
# cannot be reliably sampled, and even a lucky hit yields an OBSERVATION time,
# not a TRANSITION time.
#
# CloudTrail does not substitute. It records the `StopInstances` API CALL
# (confirmed during the drill: 04:20:25Z, user ceiba-auto-shutdown). It answers
# "who asked, and when" - never "when did the instance actually stop."
#
# EventBridge emits an `EC2 Instance State-change Notification` per state, at
# the moment of transition. That is the only one of the three that answers the
# question.
#
# DELIBERATELY NOT WIRED TO SNS
# -----------------------------
# This records; it does not alert. In particular it must never target
# aws_sns_topic.billing_alert - that topic's Lambda subscriber
# (lambda-auto-shutdown/handler.py) does not inspect the payload and stops the
# instance on ANY message. An alert on `terminated` via the uptime topic was
# considered and deliberately deferred (2026-09-16): it would also fire on
# every legitimate Terraform replacement, which is a behavioural change worth
# deciding on its own rather than inheriting from this file.
#
# Region: default provider (ca-central-1), where the instance is. NOT the
# aws.billing / us-east-1 alias used by the billing and readiness alarms -
# EC2 events are emitted in the instance's own region.

resource "aws_cloudwatch_log_group" "instance_lifecycle" {
  name = "/aws/events/ceiba-instance-lifecycle"

  # 365 days, not the 30 that was first proposed. The 2026-08-17 replacement
  # was investigated weeks after the fact; a 30-day window would already have
  # expired by then, which defeats the audit-trail purpose. At a handful of
  # ~1 KB events per year the storage difference is immaterial.
  retention_in_days = 365

  tags = {
    Name = "ceiba-instance-lifecycle"
  }
}

# A CloudWatch Logs target has no role to attach - EventBridge writes as a
# service principal, so the grant has to live on the log group itself.
#
# NOTE: `events.amazonaws.com` is the principal EventBridge actually uses for
# this target type. `delivery.logs.amazonaws.com` is included because the
# console-created equivalent adds it and newer log-delivery paths use it;
# it is harmless if unused, and cheaper than diagnosing a silent non-delivery.
data "aws_iam_policy_document" "events_to_instance_lifecycle_logs" {
  statement {
    sid = "EventBridgeWriteInstanceLifecycle"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = ["${aws_cloudwatch_log_group.instance_lifecycle.arn}:*"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "delivery.logs.amazonaws.com"]
    }

    # Scope the grant to this one rule rather than "any EventBridge rule in
    # this account." Consistent with iam.tf's posture everywhere else.
    #
    # ⚠️ This repo has shipped two confidently-worded IAM comments that turned
    # out to be wrong (the original ec2:StopInstances scoping, and the
    # ssm:SendCommand resource type). Both were caught only by a real failure.
    # A wrong condition here fails SILENTLY - events simply never arrive, and
    # the log group stays empty. So the verification step is not optional:
    # after apply, cause one real state change and confirm an event lands.
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.instance_state_change.arn]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "events_to_instance_lifecycle_logs" {
  policy_name     = "ceiba-events-to-instance-lifecycle-logs"
  policy_document = data.aws_iam_policy_document.events_to_instance_lifecycle_logs.json

  # AWS allows 10 CloudWatch Logs resource policies per account per region.
  # This is the first; worth knowing before adding more log targets.
}

# DELIBERATELY NOT FILTERED BY instance-id.
#
# This account runs exactly one EC2 instance, so "every EC2 state change" and
# "this instance's state changes" are the same event stream - the filter would
# buy nothing and cost correctness:
#
#   - A replacement produces a NEW instance ID. A rule pinned to the old one
#     records the termination and then goes silent on the replacement until
#     the next apply updates it - failing on precisely the event this rule
#     exists to capture.
#   - `aws_instance.app.id` would solve the public-repo half (no literal in a
#     public file) but not the replacement half.
#
# REVISIT if a second EC2 instance is ever introduced: then filter by tag or
# by ID and accept the maintenance cost. This trade-off is only correct while
# the account has one instance.
resource "aws_cloudwatch_event_rule" "instance_state_change" {
  name        = "ceiba-instance-state-change"
  description = "Record every EC2 instance state transition to CloudWatch Logs. Audit trail only - no alerting, no Lambda."

  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["EC2 Instance State-change Notification"]
    detail = {
      # shutting-down and terminated are the two that matter most: together
      # they are the 2026-08-17 replacement.
      state = [
        "pending",
        "running",
        "stopping",
        "stopped",
        "shutting-down",
        "terminated",
      ]
    }
  })

  tags = {
    Name = "ceiba-instance-state-change"
  }
}

resource "aws_cloudwatch_event_target" "instance_state_change_logs" {
  rule      = aws_cloudwatch_event_rule.instance_state_change.name
  target_id = "ceiba-instance-lifecycle-logs"
  arn       = aws_cloudwatch_log_group.instance_lifecycle.arn
}

output "instance_lifecycle_log_group" {
  description = "CloudWatch Logs group holding EC2 state-change events. Query this for real stop/start transition times - describe-instances and CloudTrail both answer different questions."
  value       = aws_cloudwatch_log_group.instance_lifecycle.name
}
