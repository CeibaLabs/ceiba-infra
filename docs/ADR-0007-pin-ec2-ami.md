# ADR-0007: Pin the app-host AMI instead of resolving `most_recent` on every apply

**Status:** accepted, applied
**Date:** 2026-08-20 (retroactively documenting `var.ec2_ami_id`, decided 2026-08-17, applied 2026-08-20)

## Context

`terraform/ec2.tf` originally wired `data.aws_ami.al2023_arm64` (`most_recent = true`) directly into `aws_instance.app.ami`. `ami` is a `ForceNew` attribute on `aws_instance` — any drift there destroys and recreates the instance. On 2026-08-17, an apply intended only to fix an unrelated IAM policy statement re-resolved that data source to a newly-published AMI and silently replaced the running production app host, causing real downtime until it was manually re-bootstrapped. RDS, ECR, Secrets Manager, and S3 were all untouched by that incident — the loss was compute state and availability, not data.

## Decision

**Pin the AMI to a specific, deliberately-chosen ID** via a required `var.ec2_ami_id` variable with **no default** — a missing value halts `plan` rather than silently floating to whatever's newest. The `most_recent` data source is kept only as an informational `latest_available_ec2_ami_id` output, so `terraform plan` can show what a *deliberate* bump would move to without ever wiring it into a live resource's argument.

**Alternatives priced, both rejected:**
- **"Keep `most_recent`, just review plans more carefully."** Zero implementation cost, but already proven insufficient — the incident this ADR exists to prevent happened *despite* plan review being the stated discipline at the time. A human reading a plan summary line ("1 to change") has no reason to expect an unrelated IAM edit to also replace a running instance; the risk is structural, not a discipline gap.
- **A launch-template + ASG + traffic-cutover pattern** (true blue-green AMI rollout). Genuinely more robust, but disproportionate for a single-instance MVP with no ALB and no ASG today — adopting it here would mean building both, undoing the same cost discipline ADR-0001 applied to skip a NAT Gateway (an ALB alone runs ~$16-20/month fixed, already priced in `docs/cost-breakdown.md`'s Phase 2 section for an unrelated reason). Deferred to whenever horizontal scaling is a real requirement, not adopted early just to make AMI bumps marginally smoother.

## Consequences

- `terraform.tfvars` must set `ec2_ami_id` explicitly — confirmed 2026-08-20 to the AMI of the actual running instance (`ami-0f97d2a7376b155c7`, instance `i-0898653c31f17bbf7`) via `aws ec2 describe-instances`, not copied from an example or assumed.
- A deliberate AMI bump is now a two-step, reviewable action: change `ec2_ami_id`, then confirm `terraform plan` proposes **exactly one** resource change (`aws_instance.app`, a replacement) with nothing else touched, before applying.
- **Applied 2026-08-20**, confirmed clean: `Resources: 0 added, 0 changed, 0 destroyed` — the pinned value already matched the live instance exactly, so this apply only recorded the new output, touching zero real infrastructure.

## Reversal criteria

Revisit if/when a second EC2 instance or an Auto Scaling Group enters the picture (Phase 2 horizontal scaling) — a single hardcoded AMI ID doesn't scale to fleet management the same way a launch template does, and that's the point at which the second, more robust alternative above becomes proportionate rather than premature.

## Source

`_workspace/decisions.md` and `_workspace/blockers.md`'s "The app-host AMI floats" entry record the incident and the fix; this ADR formalizes it into the ADR format the README references.
