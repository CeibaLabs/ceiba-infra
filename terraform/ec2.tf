# App host: Graviton (arm64) t4g.small running Caddy (TLS) + Ceiba control
# plane + Ceiba runtime + self-hosted Redis, all in containers.
# See docs/ADR-0002-graviton-instances.md.
#
# Both app repos now have production Dockerfiles (ceiba-runtime 7437ee0,
# ceiba-control-plane cbda7a5, both built and run-verified on arm64), so the
# gap this comment used to flag is closed. This resource still provisions
# only the host and the container runtime: it deliberately does NOT pull or
# start application images, because that requires a registry and a
# production compose stack. Bringing those up stays an explicit operator
# step, documented in the private operator runbooks.

# Informational only — deliberately NOT wired into aws_instance.app below.
# See var.ec2_ami_id's own description for why: wiring most_recent = true
# directly into a live instance's `ami` argument means every future
# `terraform apply`, for any reason, re-resolves this to whatever AMI AWS
# has most recently published and force-replaces the running production
# host if it has changed — confirmed 2026-08-17, when an apply intended
# only to fix an unrelated IAM policy also silently destroyed and recreated
# aws_instance.app, causing real downtime. This data source stays only so
# `terraform plan` can show what a *deliberate* AMI bump would move to, via
# the latest_available_ec2_ami_id output.
data "aws_ami" "al2023_arm64" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-arm64"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

resource "aws_instance" "app" {
  ami                    = var.ec2_ami_id
  instance_type          = var.ec2_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  # No key_pair specified deliberately — access is via SSM Session Manager
  # only (iam.tf's AmazonSSMManagedInstanceCore attachment), no SSH keypair,
  # no open port 22 (see vpc.tf's aws_security_group.ec2).

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.ec2_root_volume_size_gb
    encrypted             = true
    delete_on_termination = true
  }

  # Installs the container runtime and reverse proxy only. Does not deploy
  # application containers — see the file-level comment above.
  user_data = <<-EOT
    #!/bin/bash
    set -euxo pipefail
    dnf update -y
    dnf install -y docker
    systemctl enable --now docker
    usermod -aG docker ec2-user

    DOCKER_CONFIG=/usr/local/lib/docker
    mkdir -p $DOCKER_CONFIG/cli-plugins
    curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-aarch64 \
      -o $DOCKER_CONFIG/cli-plugins/docker-compose
    chmod +x $DOCKER_CONFIG/cli-plugins/docker-compose

    mkdir -p /opt/ceiba
    echo "Host provisioned by Terraform. Application containers are deployed" \
         "manually per the rollout runbook (docs/billing-guardrail-runbook.md" \
         "and _workspace/context — see ceiba-infra README Rollout section)" \
         > /opt/ceiba/PROVISIONED_BY_TERRAFORM
  EOT

  user_data_replace_on_change = false

  tags = {
    Name = var.ec2_target_name
  }
}

resource "aws_eip" "app" {
  instance = aws_instance.app.id
  domain   = "vpc"

  tags = {
    Name = "ceiba-app-eip"
  }
}
