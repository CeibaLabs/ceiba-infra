# Continuous external uptime monitoring for the two public readiness
# endpoints.
#
# WHY: both production database outages (2026-08-19 and 2026-08-27) were
# discovered by a human clicking a link, not by a monitor. Nothing in this
# account polls the application from outside. The readiness endpoints and the
# CD verification gates both already exist and both work - but CD only checks
# at deploy time, and the 2026-08-27 outage happened with no deploy at all
# (the RDS master password rotated on its own 7-day schedule). An endpoint
# that is only checked during deploys cannot catch a failure that isn't
# caused by one.
#
# WHY ROUTE 53 rather than a CloudWatch Synthetics canary: health checks run
# from AWS's global checker fleet outside this VPC, so they exercise the same
# path a customer does - DNS, Caddy, TLS, the container - and they cost
# roughly a dollar a month rather than per-run Lambda charges.
#
# String matching, not just HTTP 200: /ready returns 503 with a JSON body
# when a dependency is down, but a plain status check would also pass on any
# 2xx from something that isn't the app at all. Matching '"ok":true' asserts
# the app answered AND its dependencies are healthy.

# Deliberately NOT aws_sns_topic.billing_alert. That topic is subscribed by
# aws_lambda_function.auto_shutdown, which STOPS THE EC2 INSTANCE. Wiring an
# uptime alarm to it would mean "the site is down" triggers "shut the site
# down" - an outage that escalates itself into a longer outage. Separate
# topic, no Lambda subscriber.
resource "aws_sns_topic" "uptime_alert" {
  provider = aws.billing # us-east-1: Route 53 health-check metrics are only published there
  name     = "ceiba-uptime-alert"
}

resource "aws_sns_topic_subscription" "uptime_alert_email" {
  provider  = aws.billing
  topic_arn = aws_sns_topic.uptime_alert.arn
  protocol  = "email"
  endpoint  = var.uptime_alert_email
}

locals {
  # resource_path is what each app actually serves - the two differ, and that
  # mismatch is itself on the backlog to align.
  uptime_targets = {
    runtime = {
      fqdn = var.ceiba_api_host
      path = "/ready"
    }
    control_plane = {
      fqdn = var.ceiba_app_host
      path = "/api/ready"
    }
  }
}

resource "aws_route53_health_check" "readiness" {
  for_each = local.uptime_targets

  type              = "HTTPS_STR_MATCH"
  fqdn              = each.value.fqdn
  port              = 443
  resource_path     = each.value.path
  search_string     = "\"ok\":true"
  request_interval  = 30
  failure_threshold = 2 # two consecutive failed checks before unhealthy

  measure_latency = true

  tags = {
    Name = "ceiba-readiness-${each.key}"
  }
}

resource "aws_cloudwatch_metric_alarm" "readiness" {
  provider = aws.billing
  for_each = aws_route53_health_check.readiness

  alarm_name        = "ceiba-readiness-${each.key}"
  alarm_description = "${local.uptime_targets[each.key].fqdn}${local.uptime_targets[each.key].path} is not returning \"ok\":true. Check the containers and RDS before assuming a false positive."

  namespace   = "AWS/Route53"
  metric_name = "HealthCheckStatus"
  statistic   = "Minimum"
  dimensions = {
    HealthCheckId = each.value.id
  }

  comparison_operator = "LessThanThreshold"
  threshold           = 1
  period              = 60
  evaluation_periods  = 2 # ~2 minutes down before paging, so a container restart doesn't alert

  # Missing data means the checkers themselves stopped reporting. Treating
  # that as "breaching" is deliberate: silence is not evidence of health, and
  # the whole point of this file is that we stopped finding out.
  treat_missing_data = "breaching"

  alarm_actions = [aws_sns_topic.uptime_alert.arn]
  ok_actions    = [aws_sns_topic.uptime_alert.arn] # recovery notification
}

output "uptime_alert_topic_arn" {
  description = "SNS topic for readiness alarms. Separate from the billing topic on purpose - that one can stop the instance."
  value       = aws_sns_topic.uptime_alert.arn
}
