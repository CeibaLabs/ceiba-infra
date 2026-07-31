# Rollout runbook

A concrete, ordered checklist derived from `ceiba_aws_deployment_strategy.md` §7 and the README's original "Rollout" section, updated for what's actually landed in the app repos since the strategy doc was drafted (2026-07-02) — most notably D-041's account-subscription model and the now-6-migration Runtime schema history. Each step is marked **[AUTOMATED]** (this Terraform does it), **[MANUAL]** (an inherent one-time operator action, out of this repo's/agent's scope), or **[BLOCKED]** (can't proceed yet — cause noted).

Nothing in this checklist has been executed. `terraform apply` has not been run against a real account by this pass — see this pass's summary output for the explicit authorization boundary.

## 0. Pre-flight

1. **[MANUAL]** Confirm AWS account status: current credit balance and expiration date (Billing Console), root account MFA status, and default region. The strategy doc flags the account's ~February 2026 open date puts its credit window closing around August 2026 — confirm whether this deployment will run on remaining credits or standard on-demand billing before `apply`. Neither this agent nor Terraform can check this — it requires direct console access.
2. **[MANUAL]** Enable "Receive Billing Alerts" in Billing preferences (root/management account). See `docs/billing-guardrail-runbook.md` §1 — this is a prerequisite for the CloudWatch billing alarm to receive any data at all.
3. **[MANUAL]** Copy `terraform/terraform.tfvars.example` to `terraform/terraform.tfvars`, fill in `budget_alert_email` and confirm `aws_region`/`availability_zone`/`availability_zone_b` match the account's actual defaults from step 1. All three default to `us-east-1`/`us-east-1a`/`us-east-1b` — if you change the region, change **both** AZs with it, or `apply` fails on an AZ that doesn't exist in the chosen region.

## 1. Network and compute foundation

4. **[AUTOMATED]** `terraform apply` — VPC, public/private subnets, security groups (`vpc.tf`). No NAT Gateway (`ADR-0001-no-nat-gateway.md`). The plan creates **two** private subnets (`ceiba-private`, `ceiba-private-b`); the second is empty and exists only because AWS requires a DB subnet group to span two AZs even for a single-AZ instance. It is not a Multi-AZ upgrade and adds no cost.
5. **[AUTOMATED]** `terraform apply` — EC2 app host: Graviton `t4g.small`, Amazon Linux 2023 arm64, IAM instance profile (SSM-only access, no SSH keypair), Elastic IP, Docker + Docker Compose plugin installed via `user_data` (`ec2.tf`).
6. **[AUTOMATED]** `terraform apply` — IAM roles for the EC2 instance and the auto-shutdown Lambda (`iam.tf`), least-privilege throughout.
7. **[AUTOMATED]** `terraform apply` — RDS Postgres `db.t4g.micro`, private subnet, single-AZ, RDS-managed master credential via Secrets Manager (`rds.tf`).
8. **[AUTOMATED]** `terraform apply` — S3 backups bucket, CloudTrail (`s3-and-audit.tf`), AWS Budgets ($80 ceiling) and the CloudWatch billing alarm → SNS → Lambda auto-shutdown chain (`budgets.tf`, `cloudwatch-billing-alarm.tf`). See `docs/billing-guardrail-runbook.md` for the full guardrail behavior.

Steps 4-8 can reasonably be applied together as one `terraform apply` run, or split by resource group if the operator wants to review each in isolation — nothing here has an ordering dependency Terraform's own DAG doesn't already handle.

## 2. Application containers

9. **[DONE — 2026-07-28]** Production Dockerfiles now exist in both app repos: `ceiba-runtime/Dockerfile` (`7437ee0`) and `ceiba-control-plane/Dockerfile` (`cbda7a5`), both multi-stage, `node:22-alpine`, arm64 per `ADR-0002-graviton-instances.md`, both verified with real `docker buildx build --platform linux/arm64` runs *and* running containers reaching Docker health status `healthy`. Each resolves its sibling-repo `file:../ceiba-core-domain` dependency with Docker's named additional build context, so both must be built with `--build-context core-domain=../ceiba-core-domain` from the repo's own directory — a plain `docker build .` cannot see outside that directory and will fail.
10. **[MANUAL, once #9 unblocks]** Build both images for arm64 and push to the two private ECR repositories `terraform/ecr.tf` (this slice) provisions — `ceiba-runtime` and `ceiba-control-plane`, immutable tags, scan-on-push, a 10-tagged-image/1-day-untagged lifecycle policy. Authenticate Docker to ECR first (`aws ecr get-login-password --region <region> | docker login --username AWS --password-stdin <account-id>.dkr.ecr.<region>.amazonaws.com`), then from each app repo's own directory:

    ```
    docker buildx build --platform linux/arm64 \
      --build-context core-domain=../ceiba-core-domain \
      -t <ecr-url>:<tag> --push .
    ```

    `<ecr-url>` is `terraform output ecr_runtime_repository_url` / `ecr_control_plane_repository_url`. The named build context is required — a plain `docker build .` cannot see outside the repo's own directory and will fail (see step 9). **On an x86 machine this runs under QEMU emulation and takes on the order of 20+ minutes per image — that is expected, not a hang.** A future CD workflow would remove this manual step, but it's blocked on the same private-`ceiba-core-domain` checkout credential that blocks CI for the two app repos (see `_workspace/blockers.md` / the CI-workflows slice) — not something to solve here.
11. **[MANUAL, once #10 unblocks]** Copy `ceiba-infra/deploy/` to the app host (e.g. `scp` over an SSM port-forwarding session, or `aws s3 cp` via the backups bucket as a relay — no SSH needed either way, `iam.tf`'s SSM role already supports Session Manager). On the host: copy `deploy/.env.example` to `deploy/.env`, fill in the two ECR image references (with the tag just pushed in step 10) plus every credential from Secrets Manager per step 13 below and `deploy/.env.example`'s own mapping comment, set `CEIBA_APP_HOST=app.useceiba.com` / `CEIBA_API_HOST=api.useceiba.com` (D-049 — `ceiba-docs` is not part of this stack; it stays on Vercel), then `docker compose -f deploy/docker-compose.yml up -d`. `ec2.tf`'s `user_data` deliberately stops short of this step — see the comment at the top of that file.

## 3. Database and secrets

12. **[MANUAL]** Apply the full Runtime Prisma migration history against the new RDS instance: `20260506215751_init` through `20260712060755_drop_project_subscription` (6 migrations total, up from the single migration the strategy doc's drafting-date grounding assumed). Run `npx prisma migrate deploy` from the app host (or a one-off task with `DATABASE_URL` pointed at RDS) — **not** `migrate dev`. Per this pass's grounding: the destructive `drop_project_subscription` migration is unremarkable for a first-time production apply — a fresh database applying the full history in order simply never has that table exist in its final schema, matching D-041/D-043's "clean cutover" precedent.
13. **[MANUAL]** Populate the Secrets Manager placeholders `terraform/iam.tf` created (`aws_secretsmanager_secret.app`, output as `app_secret_arns`): `stripe-secret-key`, `stripe-webhook-secret`, `clerk-secret-key`, `clerk-publishable-key`, `resend-api-key`, `seed-starter-stripe-price-id`, `seed-pro-stripe-price-id`. None of these are set by Terraform — populate via `aws secretsmanager put-secret-value`, not the console clipboard, to avoid shell history leakage.
14. **[BLOCKED — tracked in `_workspace/blockers.md`]** Starter/Pro production Stripe price IDs must exist in Stripe (production mode, not test mode) before step 13's Stripe-related secrets are meaningful and before step 15's seed can run correctly. This is a Stripe Dashboard action for the operator — not something this agent or Terraform can do.
15. **[MANUAL, once #14 unblocks]** Run Runtime's `npm run db:seed:billing-plans` against production with `CEIBA_SEED_STARTER_STRIPE_PRICE_ID`/`CEIBA_SEED_PRO_STRIPE_PRICE_ID` set to the real production price IDs from step 14.
16. **[MANUAL, once the Control Plane's queued welcome-email slice lands — see `_workspace/next.md`]** Add `CLERK_WEBHOOK_SIGNING_SECRET` to the Secrets Manager placeholders once that slice ships; it doesn't exist as a requirement yet as of this pass and is not part of the current secret list in `iam.tf`.

## 4. DNS, TLS, and go-live

17. **[MANUAL]** Point `app.useceiba.com` and `docs.useceiba.com` at the Elastic IP (`terraform output app_public_ip`) via Route 53 / the domain registrar. This Terraform deliberately does not provision a Route 53 zone or records — DNS is an explicit operator action per this pass's scope boundary, not something to automate silently.
18. **[MANUAL, depends on #17]** Confirm Caddy issues valid Let's Encrypt certificates once DNS resolves — Let's Encrypt's HTTP-01/TLS-ALPN-01 challenge requires working public DNS first, so this cannot happen before step 17.
19. **[MANUAL]** Full end-to-end production smoke test (auth, project/key/policy CRUD, Stripe Checkout in production mode, `/rt/authorize`, usage tracking) before the Founder ship decision.
20. **[MANUAL, independent — not a deployment blocker]** First real `npm publish` for `@ceibalabs/ceiba-sdk` via the tag-triggered release pipeline (`ceiba-sdk-node/.github/workflows/release.yml`, landed but never fired). Sequenced here as a parallel readiness item, not a hard dependency of the AWS rollout — the SDK can publish independent of when production infrastructure goes live, though obviously docs/examples referencing a live API benefit from both being ready together.

## 5. Post-launch

21. **[MANUAL, monthly]** Run the cost-hygiene sweep from the README checklist (orphaned EBS volumes/snapshots, unattached Elastic IPs).
22. **[MANUAL, revisit trigger]** Phase 2 items (ElastiCache, ALB, Multi-AZ RDS, CloudFront) once traffic or revenue justify the added cost — see `docs/cost-breakdown.md` Phase 2 table.
