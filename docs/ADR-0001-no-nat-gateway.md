# ADR-0001: No NAT Gateway

**Status:** accepted
**Date:** 2026-07-13

## Context

The Phase 1 network layout (`terraform/vpc.tf`) puts RDS Postgres in a private subnet, alongside ElastiCache Redis once Phase 2 replaces the self-hosted Redis container. The conventional AWS pattern for a private subnet is to route its outbound internet traffic through a NAT Gateway so private resources can still reach out (package updates, external API calls, etc.) without being directly reachable from the internet.

A NAT Gateway has a real, unavoidable fixed cost — roughly $33/month just for the gateway to exist, before a single byte of data passes through it (plus per-GB data processing charges on top). Against Ceiba's hard $80/month ceiling, that's over 40% of the entire budget spent on a resource that, in this specific topology, isn't doing any work.

## Decision

**Do not provision a NAT Gateway.** RDS (and Phase 2 ElastiCache) never need to *initiate* outbound connections to the internet — they only need to *accept* inbound connections from the EC2 app host's security group. A NAT Gateway solves a problem Ceiba's Phase 1/Phase 2 architecture doesn't have.

`terraform/vpc.tf`'s private subnet keeps the VPC's default (local-only) route table — no route to an internet gateway, no NAT Gateway route at all. `terraform/rds.tf`'s security group (`aws_security_group.rds`) only allows inbound `5432` from `aws_security_group.ec2`, with no outbound rule beyond what's structurally required.

## Consequences

- Saves roughly $33+/month against the $80 ceiling — the single largest fixed-cost lever available in this topology.
- If a future resource in the private subnet ever needs genuine outbound internet access (e.g., a scheduled job pulling from a third-party API that must run from a private-subnet host), that's a deliberate, separate decision requiring its own NAT Gateway (or NAT instance) — not something to silently add here.
- RDS/ElastiCache patching and minor-version upgrades are handled by AWS's managed-service control plane, not by the instances reaching out to the internet themselves, so this doesn't block routine maintenance.
- Database migrations and application traffic to RDS still work correctly because they originate *from* the EC2 host (which does have public subnet + internet gateway access) *to* RDS — that direction was never NAT's job.

## Source

`_workspace/context/ceiba_aws_deployment_strategy.md` §3, §4 — this ADR organizes reasoning already settled there; no new judgment call was required to write it.
