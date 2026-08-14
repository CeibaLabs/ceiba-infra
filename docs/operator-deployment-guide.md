# Operator deployment guide — first real AWS deploy

This is the front door. It takes you from "I have an AWS account" to "the product is live on AWS,"
including the identity setup that has to happen before `terraform apply` can run at all. It does not
duplicate `rollout-runbook.md`, `billing-guardrail-runbook.md`, or the ADRs — it links to them at the
right moment and only repeats a step in full when the honesty/safety requirements below call for it.

**Nothing described here has ever been run against a real AWS account.** Every prior pass on this repo
was deliberately code-only: the Terraform is `terraform validate`-clean and a dummy-credential
`terraform plan` resolves structurally, but no `apply` has happened, no VPC/EC2/RDS/ECR exists, and
nothing is live. This guide is what turns that from a draft into reality, and it is written so a
competent engineer who has never used AWS Identity Center can follow it without guessing at console
labels.

**Read this before anything else:** the [promotion gate](#10-then-and-only-then-promote-the-landing-site)
at the end. Deploying the AWS stack does **not** automatically mean the landing site goes live — that
is a separate, explicitly gated decision that belongs to David alone.

---

## 1. Prerequisites

Verify each of these locally before touching AWS:

- **Root account MFA is enabled.** You cannot proceed past [Phase 3](#3-identity-setup-d-051) safely
  without this — root is used twice in this whole guide, and both uses assume MFA is already on. If
  it isn't, enable it now: sign in as root, go to IAM → root user MFA setup (console-only; AWS does
  not expose an API to enable root MFA from the CLI, for obvious security reasons), register an
  authenticator app or hardware key.
- **AWS CLI v2 installed.** Check with:
  ```
  aws --version
  ```
  Any `aws-cli/2.x` output is fine. (Verified working locally at authoring time: `aws-cli/2.33.12`.)
- **Terraform `>= 1.7.0`** — this is `providers.tf`'s own `required_version` constraint, not a
  guess. Check with:
  ```
  terraform version
  ```
  (Verified working locally at authoring time: `Terraform v1.15.8`, which satisfies the constraint.)
- **Docker with `buildx`.** Check with:
  ```
  docker buildx version
  ```
  You'll need this in [Phase 5](#5-images-to-ecr) regardless of which machine you deploy from — the
  app images are built locally and pushed, never built on the EC2 host (D-048).

**You are done with this phase when:** all three version checks above return output, and root MFA is
confirmed on (check the IAM console's "Security credentials" summary for the root user, or ask
whoever set up the account).

---

## 2. Account pre-flight

This maps directly to `rollout-runbook.md` [steps 1-2](rollout-runbook.md#0-pre-flight) — full detail
there, not repeated here. In short: confirm the account's current credit balance and expiration date
in the Billing Console, confirm the default region, and enable **"Receive Billing Alerts"** in Billing
preferences (root-only — see `billing-guardrail-runbook.md` §1, and see [Phase 3](#3-identity-setup-d-051)
below for why this is one of exactly two things root does in this whole process).

One thing worth stating plainly rather than leaving to the runbook alone: the original AWS deployment
strategy (`_workspace/context/ceiba_aws_deployment_strategy.md` §2) flagged that this account's ~Feb
2026 opening date put its promotional-credit window closing around August 2026. That window is at or
past its edge as of this guide being written — **do not assume credits remain.** Check the actual
number in the Billing Console before you `apply` anything, and if the credits are gone, that's fine —
`cost-breakdown.md` was priced against standard on-demand rates throughout, not against credits.

**You are done with this phase when:** you know the actual credit balance (even if it's zero),
"Receive Billing Alerts" is confirmed on, and you know which region you're deploying into.

---

## 3. Identity setup (D-051)

**This is the part most guides get wrong by defaulting to root or to a permanent access key. Neither
is what this project does.**

### The decision, in one sentence

You deploy as a **non-root** principal obtained through **AWS IAM Identity Center**, using an
`AdministratorAccess` permission set scoped to this one account, authenticated via `aws sso login` so
your working credentials are short-lived rather than sitting on disk indefinitely. Root is used for
exactly two things in this entire guide — enabling Identity Center (this phase) and enabling "Receive
Billing Alerts" ([Phase 2](#2-account-pre-flight)) — and never again after that.

**Why not a hand-written least-privilege deploy policy instead?** This was considered and deliberately
rejected (D-051). This Terraform creates VPC/EC2/RDS resources, IAM roles, and inline policies — a
principal that can create and attach IAM roles can already escalate to admin regardless of what a
hand-written policy says, and the realistic failure mode of a hand-rolled policy is a **half-applied
stack** that dies partway through `apply` on a missing action. `AdministratorAccess` for the human
running `apply`, combined with the already-scoped runtime IAM in `terraform/iam.tf` (the EC2 role can
only read specific secrets, one S3 prefix, and pull from two ECR repos — see that file directly), is
the actual security model here: broad for the person at the keyboard, narrow for the code that runs
unattended. If you think this tradeoff is wrong for this project, say so to David — do not quietly
implement a different policy.

### Primary path: IAM Identity Center

1. **Enable IAM Identity Center** (root, console-only — there is no CLI command that bootstraps
   Identity Center itself for the first time in an account). Sign in as root, navigate to the IAM
   Identity Center service, and enable it. AWS will walk you through choosing an identity source; for
   a single-operator account, the default "Identity Center directory" (no external IdP) is the
   simplest choice. Exact console labels may differ from what's described here — this is a
   console-only flow and AWS changes that UI over time; the destination is "IAM Identity Center is
   enabled and has an identity source."
2. **Create a user for yourself** in that identity source (console), and **create a permission set**
   named something like `AdministratorAccess` using AWS's own managed `AdministratorAccess` policy as
   its base — Identity Center ships this as a one-click option, you do not need to write it.
3. **Assign yourself to the Ceiba account** with that permission set (console: Identity Center →
   AWS accounts → select the Ceiba account → Assign users or groups → your user → the permission set
   from step 2).
4. **Configure the CLI to use it:**
   ```
   aws configure sso --profile ceiba-deploy
   ```
   This prompts interactively for your Identity Center start URL and region (both shown on the
   Identity Center dashboard), then your account and permission set — pick the one from step 3. It
   writes a profile to `~/.aws/config`; nothing is written to `~/.aws/credentials` because Identity
   Center credentials aren't long-lived.
5. **Log in:**
   ```
   aws sso login --profile ceiba-deploy
   ```
   This opens a browser for you to authenticate, then caches a short-lived token locally.
6. **Verify you're not root:**
   ```
   aws sts get-caller-identity --profile ceiba-deploy
   ```
   **This command is this section's done-check.** A correct result shows an `Arn` containing
   `assumed-role/AWSReservedSSO_AdministratorAccess_...` (or similar Identity-Center-generated role
   name) — **not** `arn:aws:iam::<account-id>:root`. If you see `:root` in the output, stop: you're
   still authenticated as root and something above didn't take effect.

Every command in the rest of this guide that touches AWS should be run with `AWS_PROFILE=ceiba-deploy`
set (or `--profile ceiba-deploy` appended), including `terraform apply` itself — see
[Phase 4](#4-configure-and-apply) for why Terraform needs no config change to pick this up.

### Fallback path — only if Identity Center genuinely cannot be enabled

Some organizations restrict who can enable Identity Center, or a account may have constraints this
guide can't anticipate. If Identity Center is not an option:

1. **Create a standalone IAM user** (as root or as an existing admin):
   ```
   aws iam create-user --user-name ceiba-deploy
   ```
2. **Attach `AdministratorAccess`** (the same managed policy Identity Center would have used):
   ```
   aws iam attach-user-policy --user-name ceiba-deploy \
     --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
   ```
3. **Enforce MFA on this user** before generating any key — console: IAM → Users → `ceiba-deploy` →
   Security credentials → Assign MFA device. There is an `aws iam enable-mfa-device` CLI command, but
   it requires the MFA device's serial number and two consecutive TOTP codes as arguments, which means
   registering the device (scanning the QR code) has to happen in the console first regardless — so
   just do the whole thing in the console for this one step.
4. **Create an access key:**
   ```
   aws iam create-access-key --user-name ceiba-deploy
   ```
   This is the one and only place in this guide a long-lived credential appears. Store it in
   `~/.aws/credentials` under a `[ceiba-deploy]` profile, not in any file this repo tracks.

**This path's credentials do not expire on their own.** Once the deploy window closes — the stack is
up and you've moved on from active `terraform apply` work — **rotate or delete this access key.**
Leaving an `AdministratorAccess` key sitting on a laptop indefinitely is the exact risk the primary
path exists to avoid.

**You are done with this phase when:** `aws sts get-caller-identity --profile ceiba-deploy` (or your
chosen profile name) returns a non-root ARN.

---

## 4. Configure and apply

```
cd ceiba-infra/terraform
cp terraform.tfvars.example terraform.tfvars
```

Fill in `terraform.tfvars`:

- **`budget_alert_email`** — has no default in `variables.tf`, deliberately, so the stack can't be
  silently applied without a real address wired into the $80/month billing guardrail. Required.
- **`aws_region`, `availability_zone`, `availability_zone_b`** — confirm these three agree with each
  other and with the region you settled on in [Phase 2](#2-account-pre-flight). Defaults are
  `us-east-1` / `us-east-1a` / `us-east-1b`. If you change the region, change **both** AZ variables
  with it — `availability_zone_b` exists only because AWS requires an RDS DB subnet group to span two
  Availability Zones even for a single-AZ instance (see `docs/rollout-runbook.md` step 4 and
  `terraform/rds.tf`'s own comment), and an AZ name from the wrong region will fail `apply`, not
  `plan`.
- Everything else has a sensible Phase 1 default already (`variables.tf`) — leave it unless you have
  a specific reason to change it.

Then:

```
export AWS_PROFILE=ceiba-deploy   # or whatever profile name you chose in Phase 3
terraform init
terraform plan
```

**This is the first time anything in this whole process actually talks to the AWS API.**
`terraform validate` (already run and passing, repeatedly, across every prior pass on this repo) only
ever checked Terraform's own schema — it has no idea whether your account, region, or AZs are real.
`terraform plan` is the first real contact.

### What a correct plan looks like

Counted directly from the current `.tf` files (not from a live plan — this pass has no AWS
credentials to run one against): **approximately 45 resources to add**, all as `+ create`, **zero**
`~ update` or `- destroy` — this is a brand-new local state file with nothing in it yet, so anything
other than pure creates means something is wrong (most likely: `terraform.tfstate` isn't actually
empty, e.g. you're re-running in a directory where a partial apply already happened).

The count of 45 breaks down as roughly 39 distinct resource blocks, with
`aws_secretsmanager_secret.app` alone expanding to 7 (one per name in `iam.tf`'s
`local.app_secret_names` — `stripe-secret-key`, `stripe-webhook-secret`, `clerk-secret-key`,
`clerk-publishable-key`, `resend-api-key`, `seed-starter-stripe-price-id`,
`seed-pro-stripe-price-id`).

Resources worth actually reading in the plan output, not just skimming past:

- `aws_instance.app` — the EC2 host. Confirm `instance_type = "t4g.small"` and that the AMI ID
  resolves (a blank/null AMI here means `data.aws_ami.al2023_arm64` found nothing, which would mean
  the region has no matching AMI — unlikely but worth a glance).
- `aws_db_instance.ceiba` — confirm `instance_class = "db.t4g.micro"` and `multi_az = false`.
- `aws_ecr_repository.runtime` / `.control_plane` — two, `image_tag_mutability = "IMMUTABLE"`.
- `aws_budgets_budget.ceiba_monthly` — confirm `limit_amount = "80"`. If your `.tfvars` typo'd this,
  this is where you'd catch it before it matters.
- `aws_cloudwatch_metric_alarm.billing` — confirm it's provisioned via the `aws.billing` alias
  (`providers.tf`), i.e. it targets `us-east-1` regardless of what region you're deploying the rest of
  the stack into.

If the plan looks right:

```
terraform apply
```

Type `yes` when prompted, after reading the plan — Terraform will show you the exact same plan again
immediately before asking. This step **creates real, billable AWS resources.** Referencing
`docs/cost-breakdown.md`: the Phase 1 baseline this apply produces costs approximately **$33/month**,
well inside the $80 ceiling, but it is real spend starting the moment `apply` completes, not a
simulation.

**You are done with this phase when:** `terraform apply` completes with `Apply complete! Resources:
45 added, 0 changed, 0 destroyed.` (or close to it — exact count may drift slightly as this repo
evolves; the point is creates-only, no changes, no destroys).

---

## 5. Images to ECR

Concrete, copy-pasteable — region is fixed at `ca-central-1` throughout, per your `terraform.tfvars`.

**Get your account ID once, reuse it everywhere below** (do not hand-type it):

```
ACCOUNT_ID=$(aws sts get-caller-identity --profile ceiba-deploy --query Account --output text)
echo $ACCOUNT_ID
```

**Authenticate Docker to the two ECR repos `terraform apply` just created:**

```
aws ecr get-login-password --region ca-central-1 --profile ceiba-deploy | \
  docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.ca-central-1.amazonaws.com
```

**Pick a tag.** A git SHA is the least ambiguous choice — it ties the image directly back to the exact
source it was built from:

```
RUNTIME_TAG=$(git -C ceiba-runtime rev-parse --short HEAD)
CP_TAG=$(git -C ceiba-control-plane rev-parse --short HEAD)
```

**Build and push both images.** Run each from that repo's own directory — the named build context is
required, a plain `docker build .` cannot see outside the repo and will fail:

```
cd ceiba-runtime
docker buildx build --platform linux/arm64 \
  --build-context core-domain=../ceiba-core-domain \
  -t ${ACCOUNT_ID}.dkr.ecr.ca-central-1.amazonaws.com/ceiba-runtime:${RUNTIME_TAG} \
  --push .
cd ..

cd ceiba-control-plane
docker buildx build --platform linux/arm64 \
  --build-context core-domain=../ceiba-core-domain \
  -t ${ACCOUNT_ID}.dkr.ecr.ca-central-1.amazonaws.com/ceiba-control-plane:${CP_TAG} \
  --push .
cd ..
```

**On an x86 machine, each build runs under QEMU emulation.** This was verified directly during the
deploy-stack pass on this repo: the Control Plane image's `next build` step alone took **14.5 minutes**
of real wall-clock compute under emulation, with the whole build (`npm install` included) taking on the
order of 20-30 minutes. **That is expected, not a hang** — if the build goes quiet for ten-plus minutes
during `next build` or a large `npm install`, that's normal QEMU-emulation behavior. On an actual arm64
machine (Apple Silicon, an arm64 EC2 instance) this runs natively and is dramatically faster.

**Write down `${RUNTIME_TAG}` and `${CP_TAG}`** — you need them again in Phase 6 for `deploy/.env`.

**You are done with this phase when:**
```
aws ecr describe-images --repository-name ceiba-runtime --region ca-central-1 --profile ceiba-deploy
aws ecr describe-images --repository-name ceiba-control-plane --region ca-central-1 --profile ceiba-deploy
```
each list exactly the tag you just pushed.

---

## 6. Bring the stack up

`rollout-runbook.md` lists secrets population as step 13, after bringing the stack up (step 11).
**Do it in the opposite order below** — the host needs the secrets to exist before it can fetch them
into `deploy/.env`, so populate first, then bring the stack up.

### 6a. Populate the Secrets Manager placeholders (step 13)

Run this from your own machine (`--profile ceiba-deploy`), once you have each real value in hand from
its respective dashboard (Stripe, Clerk, Resend):

```
aws secretsmanager put-secret-value --region ca-central-1 --profile ceiba-deploy \
  --secret-id ceiba/stripe-secret-key --secret-string 'sk_live_...'
aws secretsmanager put-secret-value --region ca-central-1 --profile ceiba-deploy \
  --secret-id ceiba/stripe-webhook-secret --secret-string 'whsec_...'
aws secretsmanager put-secret-value --region ca-central-1 --profile ceiba-deploy \
  --secret-id ceiba/clerk-secret-key --secret-string 'sk_...'
aws secretsmanager put-secret-value --region ca-central-1 --profile ceiba-deploy \
  --secret-id ceiba/clerk-publishable-key --secret-string 'pk_...'
aws secretsmanager put-secret-value --region ca-central-1 --profile ceiba-deploy \
  --secret-id ceiba/resend-api-key --secret-string 're_...'
```

`seed-starter-stripe-price-id` / `seed-pro-stripe-price-id` are populated in [Phase 7](#7-database),
once those price IDs exist (step 14). Don't type real secret values directly on a shared terminal's
command line if you can avoid it — prefer `--secret-string file://path/to/value.txt` reading from a
file you delete after, if that's easier for you to handle safely.

### 6b. Get the stack's own files onto the host

There's no SSH and no scp target — access is SSM Session Manager only. The cleanest path uses the S3
backups bucket as a relay, since the EC2 role already has read/write on it (`terraform/iam.tf`):

```
BUCKET=$(terraform -chdir=terraform output -raw backups_bucket_name)
tar czf /tmp/ceiba-deploy.tar.gz -C ceiba-infra deploy
aws s3 cp /tmp/ceiba-deploy.tar.gz s3://${BUCKET}/bootstrap/ceiba-deploy.tar.gz \
  --region ca-central-1 --profile ceiba-deploy
```

Open a session on the host:

```
INSTANCE_ID=$(terraform -chdir=terraform output -raw app_instance_id)
aws ssm start-session --target ${INSTANCE_ID} --region ca-central-1 --profile ceiba-deploy
```

Everything from here runs **inside that SSM session, on the host** — and the host's own EC2 instance
role (already attached, no extra credential setup needed there) is what authenticates every `aws`
call below, automatically, via instance metadata:

```
sudo su - ec2-user
mkdir -p ~/ceiba && cd ~/ceiba
aws s3 cp s3://<bucket-name-from-above>/bootstrap/ceiba-deploy.tar.gz . --region ca-central-1
tar xzf ceiba-deploy.tar.gz && cd deploy
cp .env.example .env
```

### 6c. Fill `deploy/.env` on the host

Image references — the tags you wrote down at the end of Phase 5:

```
sed -i "s|^CONTROL_PLANE_IMAGE=.*|CONTROL_PLANE_IMAGE=${ACCOUNT_ID}.dkr.ecr.ca-central-1.amazonaws.com/ceiba-control-plane:${CP_TAG}|" .env
sed -i "s|^RUNTIME_IMAGE=.*|RUNTIME_IMAGE=${ACCOUNT_ID}.dkr.ecr.ca-central-1.amazonaws.com/ceiba-runtime:${RUNTIME_TAG}|" .env
```

(`${ACCOUNT_ID}`/`${RUNTIME_TAG}`/`${CP_TAG}` won't be set in this fresh host shell — either re-derive
`ACCOUNT_ID` with the same `aws sts get-caller-identity` command from Phase 5, or just hand-substitute
the values you wrote down.)

Hosts and ACME email:

```
sed -i "s|^CEIBA_APP_HOST=.*|CEIBA_APP_HOST=app.useceiba.com|" .env
sed -i "s|^CEIBA_API_HOST=.*|CEIBA_API_HOST=api.useceiba.com|" .env
sed -i "s|^CEIBA_ACME_EMAIL=.*|CEIBA_ACME_EMAIL=you@example.com|" .env
```

**`DATABASE_URL`** — this is the one value that isn't a flat secret string; the RDS-managed master
credential is a JSON blob (`{"username":"...","password":"...",...}`, per AWS's documented shape for
`manage_master_user_password`). `jq` may not be preinstalled on Amazon Linux 2023; install it if
needed:

```
sudo dnf install -y jq
RDS_SECRET_ARN=$(aws secretsmanager list-secrets --region ca-central-1 \
  --query "SecretList[?starts_with(Name, 'rds!db-')].ARN | [0]" --output text)
RDS_SECRET=$(aws secretsmanager get-secret-value --region ca-central-1 --secret-id "$RDS_SECRET_ARN" --query SecretString --output text)
DB_USER=$(echo "$RDS_SECRET" | jq -r .username)
DB_PASS=$(echo "$RDS_SECRET" | jq -r .password)
RDS_ENDPOINT=$(terraform -chdir=/path/to/ceiba-infra/terraform output -raw rds_endpoint)   # host:port — run this on your own machine and hand-carry the value, terraform isn't on the host
sed -i "s|^DATABASE_URL=.*|DATABASE_URL=postgresql://${DB_USER}:${DB_PASS}@${RDS_ENDPOINT}/ceiba|" .env
```
The `list-secrets` filter above is the general pattern AWS uses for RDS-managed secret names
(`rds!db-<id>`) — **not independently verified against a live secret in this pass**, since it requires
a real RDS instance to exist. If it returns nothing, use `terraform output rds_master_user_secret_arn`
directly instead (that output exists precisely for this).

Every remaining credential, pulled straight from Secrets Manager on the host (never typed, never
transiting your own laptop):

```
for pair in \
  "STRIPE_SECRET_KEY:ceiba/stripe-secret-key" \
  "STRIPE_WEBHOOK_SECRET:ceiba/stripe-webhook-secret" \
  "CLERK_SECRET_KEY:ceiba/clerk-secret-key" \
  "NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY:ceiba/clerk-publishable-key" \
  "RESEND_API_KEY:ceiba/resend-api-key"; do
  VAR="${pair%%:*}"; SECRET="${pair##*:}"
  VALUE=$(aws secretsmanager get-secret-value --region ca-central-1 --secret-id "$SECRET" --query SecretString --output text)
  sed -i "s|^${VAR}=.*|${VAR}=${VALUE}|" .env
done
```

`CLERK_WEBHOOK_SIGNING_SECRET` and `CEIBA_RECEIPT_FROM_EMAIL`/`CEIBA_RECEIPT_REPLY_TO` aren't in
`terraform/iam.tf`'s secret list yet ([Phase 7](#7-database) note, and `rollout-runbook.md` step 16) —
leave them blank for now unless you have real values already.

### 6d. Bring it up

```
docker compose -f docker-compose.yml up -d
docker compose -f docker-compose.yml ps
```

**You are done with this phase when:** `control-plane` and `runtime` both show `healthy`, not merely
`running` — verified as a real, meaningful distinction during local testing of this exact stack: an
unhealthy Control Plane container (missing Clerk credentials) still shows `Up`, just not `healthy`. If
`caddy` is stuck at `Created` rather than `Up`, that means one of the two app containers never reached
`healthy` — check `docker compose logs control-plane` / `docker compose logs runtime` before assuming
Caddy itself is the problem.

---

## 7. Database

**Real constraint worth stating plainly, confirmed by reading `ceiba-runtime/package.json` directly:
the `prisma` CLI is a devDependency, and the production Dockerfile's final stage runs
`npm install --omit=dev`.** The deployed Runtime *container* has `@prisma/client` (needed to run) but
not the `prisma` CLI (needed to migrate). `docker compose exec runtime npx prisma migrate deploy` will
not work. Migrations and the seed script both need to run from **your own machine**, where the full
`ceiba-runtime` checkout and its devDependencies already exist.

RDS sits in a private subnet — your laptop can't reach it directly. Tunnel to it through the EC2 host
via SSM port forwarding (no bastion, no SSH, no security-group change needed — the EC2 role already
has network access to RDS on 5432):

```
INSTANCE_ID=$(terraform -chdir=terraform output -raw app_instance_id)
RDS_ENDPOINT=$(terraform -chdir=terraform output -raw rds_endpoint)   # "host:port"
RDS_HOST=${RDS_ENDPOINT%%:*}

aws ssm start-session --target ${INSTANCE_ID} --region ca-central-1 --profile ceiba-deploy \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"${RDS_HOST}\"],\"portNumber\":[\"5432\"],\"localPortNumber\":[\"15432\"]}"
```

**Not independently verified against a live account in this pass** (requires a real EC2 instance and
RDS endpoint to exist) — `AWS-StartPortForwardingSessionToRemoteHost` is AWS's standard public SSM
document for exactly this bastion-less-tunnel-through-an-instance pattern; confirm the session opens
and reports `Waiting for connections...` before trusting it. Leave this running in its own terminal.

**In a second terminal**, from inside your `ceiba-runtime` checkout, using the same DB credentials you
already resolved in [Phase 6c](#6c-fill-deployenv-on-the-host) (`DB_USER`/`DB_PASS` — re-run that same
`get-secret-value` lookup here if this is a different shell session):

**Step 12 — apply the full 6-migration history** (`20260506215751_init` through
`20260712060755_drop_project_subscription`) — **`migrate deploy`, never `migrate dev`:**

```
cd ceiba-runtime
DATABASE_URL="postgresql://${DB_USER}:${DB_PASS}@localhost:15432/ceiba" npx prisma migrate deploy
```

**Step 14, blocked as of this writing** (`_workspace/blockers.md`): Starter/Pro production Stripe
price IDs must exist in **production-mode** Stripe (not test mode) before step 15 can write anything
meaningful. That's a Stripe Dashboard action — confirm both price IDs exist before continuing. Once you
have them, also populate their Secrets Manager placeholders (deferred from
[Phase 6a](#6a-populate-the-secrets-manager-placeholders-step-13)):

```
aws secretsmanager put-secret-value --region ca-central-1 --profile ceiba-deploy \
  --secret-id ceiba/seed-starter-stripe-price-id --secret-string 'price_...'
aws secretsmanager put-secret-value --region ca-central-1 --profile ceiba-deploy \
  --secret-id ceiba/seed-pro-stripe-price-id --secret-string 'price_...'
```

**Step 15 — seed the billing-plan catalog**, same tunnel, same terminal:

```
DATABASE_URL="postgresql://${DB_USER}:${DB_PASS}@localhost:15432/ceiba" \
CEIBA_SEED_STARTER_STRIPE_PRICE_ID='price_...' \
CEIBA_SEED_PRO_STRIPE_PRICE_ID='price_...' \
npm run db:seed:billing-plans
```

**You are done with this phase when:** `npx prisma migrate deploy` reports all 6 migrations applied
with no errors, and the seed script confirms Free/Starter/Pro rows exist with real (not null)
production Stripe price IDs on Starter and Pro. Close the SSM port-forward session once both commands
finish — no reason to leave a tunnel to production RDS open.

---

## 8. DNS and TLS

Point **`app.useceiba.com`** and **`api.useceiba.com`** at the Elastic IP:

```
terraform output app_public_ip
```

Create an A record for each hostname at that IP, via Route 53 or whatever registrar/DNS provider
currently manages `useceiba.com` (this Terraform deliberately provisions no Route 53 zone or records —
DNS stays an explicit, manual operator action, never automated silently).

**`docs.useceiba.com` is not part of this step.** D-049 settled the Runtime's public hostname as
`api.useceiba.com` and confirmed `ceiba-docs` is not in this AWS stack at all (no Dockerfile, not in
`deploy/docker-compose.yml`) — it's recommended to live on Vercel instead, same as the landing site.
See the [promotion gate](#10-then-and-only-then-promote-the-landing-site) below for why this matters
for launch readiness even though it's outside this AWS deploy.

**Flag for whoever reviews this guide:** `rollout-runbook.md` step 17, as currently written, still
says to point `app.` and `docs.` at the Elastic IP — that's stale. D-049's own "Consequence" section
says explicitly that step 17 needed updating to `app.` and `api.`, and that correction was never
applied. This guide states the correct current answer (`app.` + `api.`) directly rather than
propagating the stale instruction, but the runbook itself still needs a follow-up fix — see this
pass's report.

Once DNS resolves (propagation is typically minutes, occasionally longer depending on your
registrar/TTL), verify it before assuming Caddy can get certificates:

```
dig +short app.useceiba.com
dig +short api.useceiba.com
```

Both should return the Elastic IP from `terraform output app_public_ip`. Then confirm Caddy actually
issued valid Let's Encrypt certificates — Caddy's automatic HTTPS needs working public DNS *first*
(Let's Encrypt's HTTP-01/TLS-ALPN-01 challenge is how it proves you control the domain):

```
curl -sSI https://app.useceiba.com/login
curl -sSI https://api.useceiba.com/health
```

A valid response (not a TLS handshake error, not a certificate warning) confirms Caddy completed
issuance. If `curl` reports a certificate problem here, DNS may not have finished propagating yet, or
Caddy hasn't retried issuance since DNS became valid — give it a few minutes and re-check before
assuming something is actually broken.

**You are done with this phase when:** both `curl` commands above return a real HTTPS response with no
certificate error.

---

## 9. Verify the deployment

A concrete smoke list, in order:

1. `curl https://api.useceiba.com/health` returns `{"ok":true}`.
2. `curl https://app.useceiba.com/login` renders (HTTP 200, real HTML — this exact check, against the
   local build of this exact image, was verified during the deploy-stack pass on this repo, so a
   failure here on the real deployment points at configuration, not a broken image).
3. Sign up for a new account through the Control Plane UI and confirm it completes.
4. Create a project from the new account and confirm it appears — this is the first real write to
   production RDS through the full application stack, not just a migration.

**You are done with this phase when:** all four pass. Only after this should you consider the AWS
deployment itself "live and working" — everything after this point is about the landing site, not the
product infrastructure.

---

## Independent readiness: first `npm publish` (step 20)

Not a deployment blocker, not sequenced against anything above — this can happen before, during, or
after the AWS deploy. Included here because it's a real "manual task down the road" like everything
else in this guide.

`ceiba-sdk-node/.github/workflows/release.yml` is tag-triggered (`push: tags: "v*.*.*"`) and has never
fired (`git tag` returns nothing on that repo as of this writing). Two things to check **before** the
first real tag push, confirmed by reading that workflow file directly:

1. **`package.json`'s version** is currently `0.0.1`. The workflow publishes whatever
   `package.json` says, regardless of what you name the git tag — there's no cross-check between them.
   Decide the real first-release version and set `package.json` accordingly before tagging (a product
   decision, not a technical one — not made for you here).
2. **npm trusted publishing (OIDC) requires npmjs.com-side registration first.** The workflow's publish
   step relies on `@ceibalabs/ceiba-sdk`'s npmjs.com package having a "Trusted Publisher" registered
   against this exact repo (`CeibaLabs/ceiba-sdk-node`) and this exact workflow file path
   (`.github/workflows/release.yml`). If that registration hasn't been done on npmjs.com yet (a
   separate, npm-side console action — nothing to do with AWS), the tag push will trigger the workflow
   but the publish step will fail with an auth error. The workflow's own comments document a
   token-based fallback (`NPM_TOKEN` secret) if you'd rather not set up trusted publishing first, but
   that fallback is not currently wired as an active step — see the workflow file's trailing comment
   block if you need it.

Once both are settled:

```
cd ceiba-sdk-node
git tag v0.0.1        # match whatever version you set in package.json
git push origin v0.0.1
```

**You are done when:** the `SDK Release` workflow run on GitHub Actions shows the publish step green,
and `npm view @ceibalabs/ceiba-sdk version` (from any machine, no auth needed for a public package)
returns the version you just tagged.

---

## 10. Then, and only then, promote the landing site

**Read this whole section before running anything in it.** Getting this wrong is the most likely
mistake in this entire guide, not because it's technically hard, but because it's easy to treat as a
routine last step once the AWS deploy itself works. It isn't routine.

### Why this is a gate, not a step

On 2026-07-20, `ceiba-landing-site/main` was promoted from `dev` and then **deliberately rolled back
the same day** at David's explicit request — he judged the same-day promotion "too sudden" and asked
that future changes to `main` (the live site) wait until everything is genuinely lined up on `dev`
first (`_workspace/daily-log.md`, 2026-07-20 entries; `_workspace/blockers.md`). **That standing
instruction has not been superseded: David is the only one who decides when this promotion runs.**
This guide gives you the commands; it does not give you authorization to run them unprompted.

### The precondition this AWS deploy does not solve

The launch site on `ceiba-landing-site/dev` (confirmed directly in `src/lib/site.ts` and the
components that reference it) has:

- a hero CTA "Open Control Plane" → `https://app.useceiba.com`
- a hero CTA "Read the quickstart" → `https://docs.useceiba.com/quickstart`
- plan-card "Subscribe" buttons → `https://app.useceiba.com/checkout/starter` and `/pro`

Everything in Phases 1-9 above makes `app.` and `api.` real. **`docs.useceiba.com` is not part of the
AWS stack** (see [Phase 8](#8-dns-and-tls)) — `ceiba-docs` has no Dockerfile and isn't in the compose
stack. It needs its own host, and Vercel is the recommendation (alongside the landing site, which
already serves `useceiba.com` from Vercel — confirmed directly: `useceiba.com` resolves to
`76.76.21.21`). **Until `docs.useceiba.com` resolves somewhere real, promoting `dev` ships a homepage
whose "Read the quickstart" CTA is dead**, even though the AWS deploy itself is completely finished and
correct.

### Promotion checklist

Before running the commands below, confirm every one of these:

- [ ] Phase 9's four-item smoke list passed against the real production URLs, not `localhost`.
- [ ] `docs.useceiba.com` resolves and serves the real docs site (Vercel or otherwise) — not a 404,
      not a placeholder.
- [ ] `app.useceiba.com/checkout/starter` and `/pro` genuinely open Stripe Checkout in **production**
      mode (this depends on [Phase 7](#7-database)'s production Stripe price IDs already being seeded).
- [ ] **David has explicitly said to promote.** Not implied, not inferred from the above all being
      green — asked and answered.

### The promotion itself

Once every box above is checked and David has said to proceed:

```
git checkout main
git merge dev
git push
```

At the time this guide was written, `main` is an exact ancestor of `dev` (`git merge-base main dev`
equals `main`'s current tip), so this merge is a clean fast-forward with no conflicts to resolve. If
work has landed directly on `main` since this guide was written, that may no longer hold — check
`git log main..dev` and `git log dev..main` before merging if you're not sure, rather than assuming
this stays a fast-forward forever.

**You are done when:** `useceiba.com` serves the promoted content live — verify with a direct `curl`
of the production URL and check the response headers for a plausible age/deploy freshness, not just a
visual glance in a browser tab that might be serving a cached copy. The 2026-07-20 rollback's own
investigation found that Vercel's edge cache can make "did it actually redeploy" genuinely ambiguous
from the CLI alone (`_workspace/blockers.md`) — if the live site doesn't visibly reflect the promotion
within a few minutes, don't assume it worked; check the Vercel dashboard directly rather than keep
polling indefinitely.

---

## Post-launch (steps 21-22)

Not one-time — these are ongoing, recurring operator tasks once the stack is live. Both are already in
the README's cost-hygiene checklist and `cost-breakdown.md`; restated here as concrete recurring
commands since "down the road" tasks are exactly what this guide is for.

**Step 21 — monthly cost-hygiene sweep.** Orphaned EBS volumes and unattached Elastic IPs are the most
common source of a bill with nothing running behind it:

```
aws ec2 describe-volumes --region ca-central-1 --profile ceiba-deploy \
  --filters Name=status,Values=available --query "Volumes[].VolumeId"
aws ec2 describe-addresses --region ca-central-1 --profile ceiba-deploy \
  --query "Addresses[?AssociationId==null].PublicIp"
```

Either command returning anything means there's a resource billing you with nothing using it — the
`aws_eip.app` this stack creates should always show as associated; if it ever appears in the second
command's output, something detached it.

**Step 22 — Phase 2 revisit trigger.** Not a command, a judgment call: revisit ElastiCache, an ALB,
Multi-AZ RDS, or CloudFront (`docs/cost-breakdown.md` Phase 2 table) only once real traffic or revenue
numbers justify the added cost — not preemptively. Nothing in Phases 1-10 above needs any of these to
work correctly at MVP scale.

---

## What this guide could not verify

Listed explicitly, per this pass's own honesty requirement, so a review pass knows exactly where to
look rather than trusting silence as confirmation:

- **The actual IAM Identity Center console flow** (Phase 3, steps 1-3) — described from AWS's
  documented product behavior, not run against a real account by this pass. Console labels may have
  shifted since; the destination described (Identity Center enabled, a user + `AdministratorAccess`
  permission set, assigned to this account) is the part that should stay stable even if exact button
  names drift.
- **The exact `terraform apply` resource count (45)** — computed by counting `resource`/`for_each`
  blocks in the current `.tf` files, not from a live plan run against a real account (this pass has no
  AWS credentials). Treat it as "approximately this many, all creates," not an exact guarantee — it
  will also drift naturally as this repo's Terraform evolves after this guide is written.
- **DNS propagation timing** in Phase 8 — "typically minutes" is a general statement about DNS, not
  measured against this specific account/registrar.
- **Whether `main` is still a clean fast-forward target for `dev`** at the actual moment someone reads
  this guide (Phase 10) — verified true at authoring time; explicitly caveated as something to
  re-check, not assumed permanent.
- **`aws ssm start-session --document-name AWS-StartPortForwardingSessionToRemoteHost`** (Phase 7) —
  this is AWS's standard, long-published public SSM document for tunneling through an instance to a
  resource it can reach (like RDS), but this pass has no live EC2 instance to actually open a session
  against and confirm the exact parameter shape works end-to-end. Confirm the session reports
  `Waiting for connections...` before trusting the tunnel.
- **The RDS-managed master secret's naming pattern** (`rds!db-...`, Phase 6c) — this is AWS's
  documented convention for `manage_master_user_password`-created secrets, not confirmed against a
  real secret in this account. `terraform output rds_master_user_secret_arn` is the reliable
  fallback if the `list-secrets` filter comes back empty.
- **The S3-relay approach for getting `deploy/` onto the host** (Phase 6b) — a reasonable use of
  infrastructure this stack already provisions (the EC2 role's existing read/write on the backups
  bucket), but not the only way to do it, and not tested against a real bucket/instance by this pass.

Everything else referenced by exact name — `terraform output` names, Secrets Manager secret names,
`rollout-runbook.md` step numbers, file paths — was checked directly against the current state of this
repo while writing this guide, not recalled from memory or assumed from the prompt that requested it.
