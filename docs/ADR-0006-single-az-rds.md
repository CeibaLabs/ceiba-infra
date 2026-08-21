# ADR-0006: Single-AZ RDS in Phase 1

**Status:** accepted
**Date:** 2026-08-20 (retroactively documenting `terraform/rds.tf`, decided at first-apply, 2026-08-04)

## Context

RDS supports Multi-AZ deployment: a synchronously-replicated standby instance in a second Availability Zone with automatic failover on a primary-instance or AZ-level failure. `terraform/rds.tf` provisions a single-AZ `db.t4g.micro` instead (`multi_az = false`), even though `aws_db_subnet_group.ceiba` already spans two AZs — a requirement of creating the subnet group at all, not a signal that Multi-AZ was ever close to being enabled.

## Decision

**Stay single-AZ through Phase 1.** Ceiba is pre-launch with no real customers and no uptime SLA to meet. RDS's own automated backups (7-day retention, already configured) cover the primary recovery path for data loss; what Multi-AZ buys on top of that is faster failover during an AZ-level outage, not better durability.

**Alternative priced:** Multi-AZ roughly **doubles** the RDS line item — `db.t4g.micro` single-AZ runs ~$12.41/month; Multi-AZ would put that closer to ~$24.82/month. Against the $80/month ceiling, that's the difference between the database tier being ~15% or ~31% of the entire budget, for a failure mode (AZ-level outage) that hasn't happened and that single-AZ RDS's own automatic instance recovery (a different, cheaper mechanism — AWS detects a failed instance and recreates it, just not across AZs) already partially covers.

## Consequences

- A full AZ outage in `ca-central-1a` (where the DB subnet group's primary subnet lives) would take RDS down until AWS's own instance-recovery mechanism restores it, or until an operator manually intervenes — real downtime risk, accepted deliberately for a pre-revenue product rather than discovered as a surprise.
- The second private subnet (`private_b`, a second AZ) already exists purely to satisfy the DB subnet group's two-AZ requirement — enabling Multi-AZ later needs no new subnet, only a Terraform flag flip and the associated cost increase.
- `README.md`'s cost table and `docs/cost-breakdown.md` both already price the Multi-AZ upgrade path under "Phase 2 — only once traffic or revenue justifies it," consistent with this decision.

## Reversal criteria

Upgrade to Multi-AZ at the first of: real customer traffic exists and an uptime SLA becomes a genuine commercial commitment, **or** a single-AZ outage actually causes customer-facing downtime (not a hypothetical — a real incident). Cost alone does not justify waiting past either trigger; this decision is about not paying for redundancy before there's anything meaningful to protect, not about avoiding the cost forever.

## Source

`_workspace/context/ceiba_aws_deployment_strategy.md` §4 already scoped single-AZ as the Phase 1 baseline; this ADR formalizes that into the ADR format the README references and adds the priced Multi-AZ comparison.
