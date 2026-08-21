# ADR-0002: Graviton (arm64) instances

**Status:** accepted
**Date:** 2026-07-13

## Context

Both the app host (`terraform/ec2.tf`) and the database (`terraform/rds.tf`) need an instance family. AWS offers equivalent x86 (`t3`) and Graviton/arm64 (`t4g`) burstable families at the small sizes Ceiba's Phase 1 baseline needs (`t3.small`/`t4g.small`, `db.t3.micro`/`db.t4g.micro`).

## Decision

**Use Graviton (`t4g`/`db.t4g`) throughout, not x86 (`t3`/`db.t3`).** Confirmed current on-demand pricing (2026-07-13, us-east-1): `t4g.small` runs ~$0.0168/hr (~$12.26/mo), and Graviton instances are consistently priced roughly 10-20% below their x86 equivalents at the same size for better price/performance, per AWS's own published Graviton positioning. At this instance size, that gap is a genuine and free cost reduction against the $80/month ceiling — not a marginal or risky optimization.

Compatibility check before committing to this: both `ceiba-runtime` and `ceiba-control-plane` are pure Node.js/TypeScript services (Fastify and Next.js respectively) with no native x86-only binary dependencies identified in either `package.json`. Node.js, Docker, Caddy, and Amazon Linux 2023 all publish official arm64 builds. Postgres on RDS is fully supported on `db.t4g` instance classes. There is no known compatibility blocker to running the whole Phase 1 stack on arm64.

## Consequences

- `terraform/ec2.tf`'s AMI data source is pinned to `al2023-ami-*-arm64` (Amazon Linux 2023, arm64) to match the Graviton instance type — an x86 AMI on a `t4g` instance type would simply fail to launch.
- The Docker Compose plugin binary installed in `ec2.tf`'s `user_data` is fetched as the `docker-compose-linux-aarch64` release asset specifically, not the generic/x86 build.
- Once application containers exist (see this pass's flagged Dockerfile gap in the rollout runbook), their base images must be multi-arch or arm64-specific (e.g., `node:22-alpine` publishes arm64 variants natively — no action needed there, but this is worth confirming explicitly when those Dockerfiles are written, since it's an application-repo change outside this pass's mandate).
- If a future dependency turns out to require x86 (an uncommon native addon with no arm64 build, for example), the fix is switching that specific instance type back to `t3`/`db.t3` — not abandoning Graviton wholesale.

## Reversal criteria

Switch a specific instance type back to its x86 (`t3`/`db.t3`) equivalent only if a real dependency is confirmed to have no arm64 build and no viable arm64 alternative exists — not preemptively, and not wholesale. The 10-20% price/performance gap is real and free money left on the table for as long as arm64 compatibility holds, so the burden of proof is on finding an actual incompatibility, not on re-justifying Graviton.

## Source

`_workspace/context/ceiba_aws_deployment_strategy.md` §4 already chose Graviton; this ADR records the reasoning and adds the 2026-07-13 pricing/compatibility confirmation that backs it, per this pass's mandate to verify current pricing before finalizing.
