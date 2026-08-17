variable "aws_region" {
  description = <<-EOT
    Region for compute/database/network resources. Defaults to us-east-1 for
    MVP simplicity (co-locates everything with the billing-metrics region so
    there's only one region to reason about). Confirm this against the
    operator's actual account default before applying — not assumed here.
  EOT
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment tag (prod | staging)."
  type        = string
  default     = "prod"
}

variable "owner_tag" {
  description = "Resource owner tag, per the strategy doc's cost-hygiene checklist."
  type        = string
  default     = "david"
}

variable "vpc_cidr" {
  description = "CIDR block for the Ceiba VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet (EC2 host)."
  type        = string
  default     = "10.20.1.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR block for the primary private subnet (RDS, and ElastiCache in Phase 2)."
  type        = string
  default     = "10.20.2.0/24"
}

variable "private_subnet_b_cidr" {
  description = <<-EOT
    CIDR block for the second private subnet. This exists solely to satisfy
    AWS's RDS DB subnet group requirement (a subnet group must span at
    least two AZs, always — not a Multi-AZ-specific requirement). No
    resource is deployed into this subnet in Phase 1; it stays private, no
    NAT, no route-table association, mirroring aws_subnet.private.
  EOT
  type        = string
  default     = "10.20.3.0/24"
}

variable "availability_zone" {
  description = <<-EOT
    Primary AZ: public subnet, EC2 app host, and the primary private
    subnet. RDS itself stays single-AZ in Phase 1 (see
    ceiba_aws_deployment_strategy.md §4) — Multi-AZ RDS is an explicit,
    additive Phase 2 upgrade, not part of this baseline. Confirm this AZ is
    valid in the chosen region before applying (e.g. us-east-1a).
  EOT
  type        = string
  default     = "us-east-1a"
}

variable "availability_zone_b" {
  description = <<-EOT
    Second AZ, required only because AWS's RDS DB subnet group must span at
    least two Availability Zones regardless of whether the instance itself
    is Multi-AZ. No compute is placed here in Phase 1. Must differ from
    var.availability_zone and be valid in the chosen region (e.g. us-east-1b).
  EOT
  type        = string
  default     = "us-east-1b"
}

variable "ec2_instance_type" {
  description = "Graviton (arm64) instance type for the app host. See docs/ADR-0002-graviton-instances.md."
  type        = string
  default     = "t4g.small"
}

variable "ec2_ami_id" {
  description = <<-EOT
    Pinned AMI ID for the app host (Amazon Linux 2023, arm64). No default,
    deliberately — a required value forces a conscious choice instead of
    silently floating.

    Why this is pinned rather than resolved live: wiring a `most_recent =
    true` data source directly into aws_instance.app's `ami` argument means
    every future `terraform apply` — for ANY reason, even one completely
    unrelated to this instance — re-resolves to whatever AMI AWS most
    recently published. `ami` is a ForceNew attribute, so any drift there
    destroys and recreates the instance. This happened for real on
    2026-08-17: an apply meant only to fix an unrelated IAM policy also
    silently replaced the running production host, causing genuine
    downtime. Pinning removes the "any apply might replace prod" risk
    entirely — this value only ever changes when someone deliberately edits
    it.

    To find the AMI a specific running instance actually uses (the value to
    copy in here on a fresh setup, so this variable starts out matching
    reality exactly):
      aws ec2 describe-instances --instance-ids <instance-id> \
        --query 'Reservations[0].Instances[0].ImageId' --output text \
        --region <region>

    To see whether a newer AMI is available, without changing anything:
      terraform output latest_available_ec2_ami_id

    To deliberately bump the AMI: set this variable to that value, run
    `terraform plan`, confirm it proposes exactly one replacement
    (aws_instance.app) with nothing else touched, review, then apply.
  EOT
  type        = string
}

variable "ec2_root_volume_size_gb" {
  description = <<-EOT
    Root EBS volume size in GB (gp3). 30 is not an arbitrary round number -
    it is the confirmed minimum for the al2023-ami-*-arm64 AMI actually
    resolved in ca-central-1 at first-apply time (2026-08-11): AWS rejected
    a 20GB root volume with "Volume of size 20GB is smaller than snapshot
    'snap-0dc130a50e2e0c33b', expect size >= 30GB". A new EBS volume can
    always be created larger than its source snapshot, never smaller.
    If a future AMI resolves with a larger snapshot floor than 30GB, this
    same error will recur with the actual required minimum stated in it -
    that is a real signal to raise this value again, not a bug.
  EOT
  type        = number
  default     = 30
}

variable "rds_instance_class" {
  description = "Graviton (arm64) RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "rds_allocated_storage_gb" {
  description = "RDS gp3 storage in GB."
  type        = number
  default     = 20
}

variable "rds_postgres_version" {
  description = <<-EOT
    Postgres major version. Matches ceiba-runtime's local dev Postgres
    (docker-compose.local.yml pins postgres:16-alpine) so migrations behave
    identically between local dev and production.
  EOT
  type        = string
  default     = "16"
}

variable "rds_db_name" {
  description = "Initial database name."
  type        = string
  default     = "ceiba"
}

variable "rds_master_username" {
  description = "RDS master username. The master password is never set here — see rds.tf (manage_master_user_password)."
  type        = string
  default     = "ceiba_admin"
}

variable "budget_limit_usd" {
  description = "Hard monthly budget ceiling in USD. Do not raise without an explicit Founder decision — see ceiba_aws_deployment_strategy.md §1."
  type        = number
  default     = 80
}

variable "billing_alarm_threshold_usd" {
  description = "CloudWatch EstimatedCharges alarm threshold — deliberately below budget_limit_usd to leave reaction room."
  type        = number
  default     = 70
}

variable "budget_alert_email" {
  description = <<-EOT
    Email address for AWS Budgets notifications and the billing-alarm SNS
    topic. Must be supplied via terraform.tfvars (gitignored) — no default,
    deliberately, so this can't be silently applied without a real operator
    email wired in.
  EOT
  type        = string
}

variable "ec2_target_name" {
  description = "Name tag for the Ceiba app EC2 instance, used by the auto-shutdown Lambda to resolve the instance ID at invoke time rather than hardcoding it."
  type        = string
  default     = "ceiba-app"
}

variable "cd_deploy_branch" {
  description = <<-EOT
    The one branch, per app repo, that github-oidc.tf's deploy role trusts.
    A push to any other branch cannot assume this role, even from inside the
    same repository — this is the whole point of pinning the OIDC trust
    policy to a ref instead of repo:OWNER/REPO:*. Change this value, not the
    trust policy, if the branch that triggers CD ever changes.
  EOT
  type        = string
  default     = "dev"
}
