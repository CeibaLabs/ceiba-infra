# AWS Budgets: one monthly cost budget at the $80 hard ceiling.
# Per ceiba_aws_deployment_strategy.md §5.1 — 50%/80%/100% actual plus a
# forecasted-to-exceed alert, notifying both the shared billing SNS topic
# (cloudwatch-billing-alarm.tf) and a direct email subscription.
#
# Do not raise budget_limit_usd above 80 without an explicit Founder
# decision — see variables.tf and ceiba_aws_deployment_strategy.md §1.

resource "aws_budgets_budget" "ceiba_monthly" {
  name         = "ceiba-monthly-ceiling"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:project$ceiba"]
  }

  dynamic "notification" {
    for_each = [50, 80, 100]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.budget_alert_email]
      subscriber_sns_topic_arns  = [aws_sns_topic.billing_alert.arn]
    }
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
    subscriber_sns_topic_arns  = [aws_sns_topic.billing_alert.arn]
  }
}
