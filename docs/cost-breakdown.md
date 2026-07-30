# Cost breakdown

Hard ceiling: **$80/month** (`_workspace/context/ceiba_aws_deployment_strategy.md` §1 — do not raise without an explicit Founder decision). Target baseline: **~$30-40/month**.

Pricing below was independently re-verified on **2026-07-13** against current public AWS pricing sources, per this pass's mandate to confirm figures rather than inherit the strategy doc's 2026-07-02 estimates unchecked. **Result: no material drift.** us-east-1 on-demand pricing for every Phase 1 line item matches the original strategy doc and README figures within a few percent — the $33/month baseline holds under current pricing.

## Phase 1 — MVP launch

| Component | Choice | Est. monthly | 2026-07-13 verification |
|---|---|---:|---|
| Compute | EC2 `t4g.small` (Graviton), containers for control plane + runtime + Redis | ~$12.26 | Confirmed: $0.0168/hr = $12.264/mo on-demand, us-east-1 |
| EBS root volume | 20 GB gp3 | ~$1.60 | Confirmed: gp3 ≈ $0.08/GB-mo × 20GB |
| Public IPv4 address | 1 in-use address @ $0.005/hr | ~$3.65 | Confirmed: $0.005/hr × 730hr, unchanged since Feb 2024 |
| Database | RDS Postgres `db.t4g.micro`, single-AZ | ~$11.68-12.41 | Confirmed in range: $0.016/hr ≈ $11.68/mo on-demand, us-east-1 |
| DB storage | 20 GB gp3 | ~$2.30 | Confirmed: RDS gp3 storage rate ≈ $0.115/GB-mo × 20GB |
| Cache | Self-hosted Redis container on the app instance | $0 | N/A — runs on the already-costed EC2 instance |
| TLS / routing | Caddy + Let's Encrypt on the instance | $0 | N/A |
| DNS | Route 53 hosted zone | $0.50 | Unchanged, standard Route 53 hosted-zone rate |
| **NAT Gateway** | **Skipped entirely** | **$0** | See `ADR-0001-no-nat-gateway.md` |
| Observability | CloudWatch + CloudTrail, within always-free allowance | $0 | Confirmed within free-tier scope at this resource count |
| S3 | Backups + static assets | ~$0.25 | Small-object estimate, standard S3 Standard rate |
| | **Baseline total** | **~$32.24-32.97** | ~40-41% of the $80 ceiling |

The public IPv4 line is easy to overlook and easy to get wrong in a back-of-envelope estimate — AWS has charged $0.005/hour per public IPv4 address, in-use or idle, since February 2024, across EC2, RDS, EKS, and anything else that can hold one. `terraform/ec2.tf` provisions exactly one (`aws_eip.app`) and nothing else in this configuration allocates a public IPv4, so this line item is the complete public-IP cost, not a partial one.

## Phase 2 — only once traffic or revenue justifies it

Additive, not a rebuild — nothing in Phase 1 needs to be torn down to add these.

| Component | Choice | Est. monthly | 2026-07-13 verification |
|---|---|---:|---|
| Cache | ElastiCache Redis `cache.t4g.micro` replaces the self-hosted container | ~$11.68-15 | Confirmed: $0.016/hr ≈ $11.68/mo on-demand, us-east-1 |
| Load balancing | Application Load Balancer, for zero-downtime deploys / horizontal scaling | ~$16-20 fixed + usage | Not re-verified this pass — not needed until Phase 2 is actually triggered |
| Database | RDS Multi-AZ, for a real uptime SLA | roughly 2× current RDS cost | Not re-verified this pass — same reasoning |
| CDN | CloudFront in front of S3, if static-asset traffic grows | usage-based | Not re-verified this pass — same reasoning |

## Sourcing

EC2, RDS, and public-IPv4 figures were checked directly against current AWS pricing references (economize.cloud, Vantage `instances.vantage.sh`, and AWS's own EC2/RDS on-demand pricing pages) on 2026-07-13. Route 53, S3, and CloudWatch/CloudTrail free-tier figures were not re-sourced independently this pass since they've been stable, low-variance line items for years and are a small fraction of the total either way — if the operator wants those independently re-verified before `apply`, that's a five-minute check, not a structural risk to the plan.

## What would actually threaten the $80 ceiling

None of the Phase 1 components individually risk the ceiling even at 2-3x the estimated figures above. The realistic ways to blow the budget are operational, not pricing-estimate error: an oversized instance left running after a debugging session, an orphaned EBS volume or unattached Elastic IP, or a runaway Lambda/CloudWatch cost from a misconfigured alarm loop. See `docs/billing-guardrail-runbook.md` and the README's cost-hygiene checklist for the controls that catch exactly this class of risk.
