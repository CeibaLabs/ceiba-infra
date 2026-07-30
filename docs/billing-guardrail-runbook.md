# Billing guardrail runbook

Two layers, because a budget alert that only emails you is not a control (README "Cost guardrails"). This runbook covers setup, what each layer actually does and doesn't catch, and what to do when the alarm fires.

## 1. One-time manual prerequisite (cannot be done via Terraform)

**Enable "Receive Billing Alerts"** in the account's Billing preferences console page, under the root/management account. This is a console-only toggle — there is no Terraform resource for it, and `terraform apply` will not fail if it's off, it will just mean the CloudWatch alarm in step 3 never receives data. Do this before or immediately after the first `apply`.

Billing metrics (the `AWS/Billing` `EstimatedCharges` metric) only exist in `us-east-1`, regardless of which region your actual resources run in — this is why `terraform/cloudwatch-billing-alarm.tf` uses the `aws.billing` provider alias pinned to `us-east-1`.

## 2. What `terraform apply` sets up automatically

- **AWS Budgets** (`terraform/budgets.tf`): one monthly cost budget at $80, tagged-resource-scoped (`project=ceiba`). Notifies at 50%/80%/100% of actual spend, plus a forecasted-to-exceed alert. Every notification goes to both the operator's email (direct) and the shared `ceiba-billing-alert` SNS topic.
- **CloudWatch alarm → SNS → Lambda** (`terraform/cloudwatch-billing-alarm.tf`, `terraform/iam.tf`, `terraform/lambda-auto-shutdown/`): an alarm on `EstimatedCharges` fires when estimated charges exceed $70 (configurable via `billing_alarm_threshold_usd`, deliberately below the $80 ceiling to leave reaction room). The alarm action publishes to the same `ceiba-billing-alert` SNS topic, which has two subscribers: the operator's email, and the `ceiba-auto-shutdown` Lambda.
- The Lambda (`handler.py`) resolves the Ceiba app EC2 instance by its `Name` tag (not a hardcoded instance ID, since the ID doesn't exist until after the first `apply`) and calls `ec2:StopInstances` on it.

## 3. What this guardrail is — and, just as importantly, what it is not

**It is:** a safety net for a slow leak — an oversized instance accidentally left running, a forgotten resource, a debugging session that didn't get cleaned up.

**It is not:**

- **Not real-time.** AWS billing metrics update roughly every few hours, not instantly. This will not catch an instant spend spike — e.g., a compromised credential spinning up dozens of large instances in minutes. Against that class of risk, the IAM/secrets/network controls in the README's "Security" section (no long-lived keys, MFA, least privilege, SSM-only access) matter far more than this alarm does.
- **Not an RDS control.** The Lambda deliberately never stops RDS. Stopping an RDS instance only pauses billing for up to 7 days, after which AWS automatically and silently restarts it — a false sense of security if you assume "stopped" means "stopped." A cost-driven RDS pause has to be a deliberate, monitored, manual action, never part of an automated circuit breaker.
- **Not a substitute for the cost-hygiene checklist.** Even with both layers active, orphaned EBS volumes, unattached Elastic IPs, and idle snapshots don't trigger either layer meaningfully at MVP scale — they're caught by the monthly manual sweep in the README's checklist, not by an alarm.

## 4. When the alarm fires — operator response sequence

1. Check email/SNS for the alarm notification; confirm it's real (not a one-off spike from, e.g., a burst of legitimate signups).
2. Confirm the Lambda actually stopped the instance: `aws ec2 describe-instances --filters "Name=tag:Name,Values=ceiba-app"` and check `State.Name`.
3. Check Cost Explorer for what actually drove the estimated-charges increase — don't assume it was the app instance just because that's what the Lambda stops.
4. If it was a genuine leak (oversized instance, forgotten resource): fix the root cause, then manually restart the app instance (`aws ec2 start-instances`) once confirmed safe. It will not restart itself — this is intentional.
5. If it was a false positive (legitimate traffic growth, a one-time cost like a snapshot export): restart the instance, and consider whether `billing_alarm_threshold_usd` or the Budget's percentage thresholds need adjustment — that's a `terraform.tfvars` change plus a Founder-reviewed `apply`, not a console workaround.
6. Record the incident in `_workspace/blockers.md` or `_workspace/daily-log.md` if it caused user-facing downtime.

## 5. AWS Budget Actions — a simpler alternative, not used here

AWS also offers native **Budget Actions**: attach a deny-spend IAM policy, or stop specific EC2/RDS instances, directly from a budget threshold, with no Lambda required. This is a genuinely simpler path and worth knowing about. The Lambda approach is used here instead because it's more flexible (the instance-resolution-by-tag logic, structured logging, and room to extend to a Slack/PagerDuty notification later are all easier in a Lambda than in a Budget Action) and more explicitly auditable as a portfolio piece — not because Budget Actions are deficient.
