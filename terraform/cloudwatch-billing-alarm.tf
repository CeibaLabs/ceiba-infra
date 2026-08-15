# Auto-shutdown circuit breaker: CloudWatch billing alarm -> SNS -> Lambda.
# Per ceiba_aws_deployment_strategy.md §5.2.
#
# Everything in this file runs in us-east-1 (the aws.billing provider alias
# from providers.tf) because AWS billing metrics (AWS/Billing EstimatedCharges)
# only exist in that region, regardless of where the EC2/RDS resources
# themselves run. The Lambda is told the *resource* region via an environment
# variable so ec2:StopInstances still targets the right region even if
# var.aws_region is ever changed away from us-east-1.
#
# Two caveats this alarm does NOT cover (see ceiba_aws_deployment_strategy.md
# §5.2 and README "Cost guardrails"): it reacts to a slow leak, not an
# instant spend spike (billing metrics update every few hours, not
# real-time), and it deliberately never touches RDS (stopping RDS only
# pauses billing for up to 7 days before AWS silently restarts it).
#
# Manual prerequisite this Terraform cannot do for you: "Receive Billing
# Alerts" must be enabled once in Billing preferences (console-only toggle,
# no Terraform resource exists for it) before this alarm can evaluate any
# data. Operator response procedure is in the private billing-guardrail runbook.

resource "aws_sns_topic" "billing_alert" {
  provider = aws.billing
  name     = "ceiba-billing-alert"
}

resource "aws_sns_topic_subscription" "billing_alert_email" {
  provider  = aws.billing
  topic_arn = aws_sns_topic.billing_alert.arn
  protocol  = "email"
  endpoint  = var.budget_alert_email
}

data "archive_file" "lambda_auto_shutdown" {
  type        = "zip"
  source_file = "${path.module}/lambda-auto-shutdown/handler.py"
  output_path = "${path.module}/lambda-auto-shutdown/handler.zip"
}

resource "aws_lambda_function" "auto_shutdown" {
  provider = aws.billing

  function_name = "ceiba-auto-shutdown"
  role          = aws_iam_role.lambda_auto_shutdown.arn
  handler       = "handler.lambda_handler"
  runtime       = "python3.12"
  architectures = ["arm64"]
  timeout       = 30

  filename         = data.archive_file.lambda_auto_shutdown.output_path
  source_code_hash = data.archive_file.lambda_auto_shutdown.output_base64sha256

  environment {
    variables = {
      TARGET_INSTANCE_NAME = var.ec2_target_name
      TARGET_REGION        = var.aws_region
    }
  }

  tags = {
    Name = "ceiba-auto-shutdown"
  }
}

resource "aws_sns_topic_subscription" "billing_alert_lambda" {
  provider  = aws.billing
  topic_arn = aws_sns_topic.billing_alert.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.auto_shutdown.arn
}

resource "aws_lambda_permission" "allow_sns" {
  provider      = aws.billing
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.auto_shutdown.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.billing_alert.arn
}

resource "aws_cloudwatch_metric_alarm" "billing" {
  provider = aws.billing

  alarm_name          = "ceiba-billing-estimated-charges"
  alarm_description   = "Fires when AWS estimated charges exceed the pre-ceiling threshold. See the billing-guardrail runbook."
  namespace           = "AWS/Billing"
  metric_name         = "EstimatedCharges"
  dimensions          = { Currency = "USD" }
  statistic           = "Maximum"
  period              = 21600 # 6 hours — matches how infrequently this metric actually updates
  evaluation_periods  = 1
  threshold           = var.billing_alarm_threshold_usd
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.billing_alert.arn]
}
