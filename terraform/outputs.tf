output "app_public_ip" {
  description = "Elastic IP of the Ceiba app host — point Route 53 (DNS is an operator action, not automated here) at this."
  value       = aws_eip.app.public_ip
}

output "app_instance_id" {
  description = "EC2 instance ID of the Ceiba app host."
  value       = aws_instance.app.id
}

output "rds_endpoint" {
  description = "RDS Postgres connection endpoint (host:port)."
  value       = aws_db_instance.ceiba.endpoint
}

output "rds_master_user_secret_arn" {
  description = "Secrets Manager ARN holding the RDS-managed master credential."
  value       = aws_db_instance.ceiba.master_user_secret[0].secret_arn
}

output "app_secret_arns" {
  description = "Secrets Manager ARNs for the app-secret placeholders — populate these values out-of-band post-apply."
  value       = { for k, v in aws_secretsmanager_secret.app : k => v.arn }
}

output "backups_bucket_name" {
  description = "S3 bucket for RDS manual-snapshot exports, static assets, and CloudTrail logs."
  value       = aws_s3_bucket.backups.id
}

output "billing_alert_topic_arn" {
  description = "SNS topic backing both the CloudWatch billing alarm and AWS Budgets notifications."
  value       = aws_sns_topic.billing_alert.arn
}

output "ecr_runtime_repository_url" {
  description = "ECR repository URL for ceiba-runtime - copy into deploy/.env as RUNTIME_IMAGE's registry prefix."
  value       = aws_ecr_repository.runtime.repository_url
}

output "ecr_control_plane_repository_url" {
  description = "ECR repository URL for ceiba-control-plane - copy into deploy/.env as CONTROL_PLANE_IMAGE's registry prefix."
  value       = aws_ecr_repository.control_plane.repository_url
}

output "github_plan_role_arn" {
  description = "Set as ceiba-infra's own repository variable AWS_PLAN_ROLE_ARN (Settings > Secrets and variables > Actions > Variables) - this is what terraform-plan.yml has assumed exists since it was written."
  value       = aws_iam_role.github_plan.arn
}

output "github_deploy_role_arn" {
  description = "Set as a repository variable AWS_DEPLOY_ROLE_ARN in BOTH ceiba-runtime and ceiba-control-plane - the CD workflow in each assumes this role via OIDC to push to ECR and run the deploy script over SSM."
  value       = aws_iam_role.github_deploy.arn
}
