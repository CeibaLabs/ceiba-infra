terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Local state for now — single operator, no CI apply yet. See docs/ADR-0003-local-state.md.
  # Migrating to an S3 + DynamoDB backend is the documented next step, not a silent gap.
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      project = "ceiba"
      env     = var.environment
      owner   = var.owner_tag
    }
  }
}

# AWS billing metrics (the CloudWatch EstimatedCharges metric that
# cloudwatch-billing-alarm.tf alarms on) only exist in us-east-1, regardless
# of which region the rest of the resources run in. Provisioned unconditionally
# so budgets.tf / cloudwatch-billing-alarm.tf can target it even if
# var.aws_region is ever changed to something other than us-east-1.
provider "aws" {
  alias  = "billing"
  region = "us-east-1"

  default_tags {
    tags = {
      project = "ceiba"
      env     = var.environment
      owner   = var.owner_tag
    }
  }
}
