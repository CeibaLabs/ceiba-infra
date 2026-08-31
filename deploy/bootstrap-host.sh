#!/usr/bin/env bash
#
# Rebuild deploy/.env on the app host from Secrets Manager, then bring the
# stack up. Run this on the EC2 host, as ec2-user, from this directory.
#
#   ./bootstrap-host.sh                 # rebuild .env and start the stack
#   ./bootstrap-host.sh --env-only      # rebuild .env, don't touch containers
#   ./bootstrap-host.sh --check         # print what WOULD be written, change nothing
#
# WHY THIS EXISTS
# ---------------
# On 2026-08-17 an unrelated `terraform apply` replaced aws_instance.app and
# destroyed deploy/.env with it. Several variables in that file existed
# NOWHERE else - not in Secrets Manager, not in Terraform, not in git - and
# every one of them fails SILENTLY when missing (a webhook stops verifying,
# analytics stops recording, receipt email stops sending; nothing crashes).
# The host was then repaired by hand, which is not a recovery procedure.
#
# This script is the recovery procedure. Everything it needs lives in
# Secrets Manager, read via the instance role - so a replacement host can be
# brought back to a serving state without an operator remembering anything.
#
# CREDENTIAL POSTURE
# ------------------
# DATABASE_URL is built from ceiba/production/app-database (the ceiba_app
# role), NEVER from the RDS-managed master secret. That distinction is the
# entire point of the credential separation work:
#
#   ceiba_app  -> long-running containers. Cannot create or drop schema.
#   master     -> migrations and admin only, operator-invoked, never in .env.
#
# The master credential also rotates on AWS's 7-day schedule. Anything that
# bakes it into .env breaks roughly weekly, silently, at rotation time.
# If you are editing this script to read `rds!db-*`, stop: that is the bug
# this file was written to prevent.

set -euo pipefail

REGION="${CEIBA_REGION:-ca-central-1}"
ENV_FILE="${CEIBA_ENV_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.env}"
APP_DB_SECRET="${CEIBA_APP_DB_SECRET:-ceiba/production/app-database}"

MODE="deploy"
case "${1:-}" in
  --env-only) MODE="env-only" ;;
  --check)    MODE="check" ;;
  "")         ;;
  *) echo "unknown argument: $1" >&2; exit 64 ;;
esac

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "  $*"; }

for bin in aws jq python3 docker; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin is required but not installed. On AL2023: sudo dnf install -y $bin"
done

# --- Secrets Manager -> shell -------------------------------------------

# Flat string secrets. Left side is the .env key, right side the secret name.
# Keep this list in sync with local.app_secret_names in terraform/iam.tf:
# a name here that does not exist there is a secret nothing creates, and a
# name there that is missing here is a secret nothing consumes.
FLAT_SECRETS=(
  "STRIPE_SECRET_KEY:ceiba/stripe-secret-key"
  "STRIPE_WEBHOOK_SECRET:ceiba/stripe-webhook-secret"
  "CLERK_SECRET_KEY:ceiba/clerk-secret-key"
  "NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY:ceiba/clerk-publishable-key"
  "CLERK_WEBHOOK_SIGNING_SECRET:ceiba/clerk-webhook-signing-secret"
  "RESEND_API_KEY:ceiba/resend-api-key"
  "CEIBA_RECEIPT_FROM_EMAIL:ceiba/receipt-from-email"
  "CEIBA_RECEIPT_REPLY_TO:ceiba/receipt-reply-to"
  "NEXT_PUBLIC_POSTHOG_KEY:ceiba/posthog-key"
  "NEXT_PUBLIC_POSTHOG_HOST:ceiba/posthog-host"
  "CEIBA_SEED_STARTER_STRIPE_PRICE_ID:ceiba/seed-starter-stripe-price-id"
  "CEIBA_SEED_PRO_STRIPE_PRICE_ID:ceiba/seed-pro-stripe-price-id"
)

fetch_secret() {
  aws secretsmanager get-secret-value \
    --region "$REGION" --secret-id "$1" \
    --query SecretString --output text 2>/dev/null || return 1
}

urlencode() {
  python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

echo "==> Reading application database credential ($APP_DB_SECRET)"
APP_DB_JSON="$(fetch_secret "$APP_DB_SECRET")" \
  || die "cannot read $APP_DB_SECRET. Check the instance role has GetSecretValue on it (terraform/iam.tf, local.app_secret_names)."

# Expected shape, matching AWS's own convention for database secrets:
#   {"username":"ceiba_app","password":"...","host":"...","port":5432,"dbname":"ceiba"}
DB_USER="$(jq -r '.username // empty' <<<"$APP_DB_JSON")"
DB_PASS="$(jq -r '.password // empty' <<<"$APP_DB_JSON")"
DB_HOST="$(jq -r '.host     // empty' <<<"$APP_DB_JSON")"
DB_PORT="$(jq -r '.port     // 5432'  <<<"$APP_DB_JSON")"
DB_NAME="$(jq -r '.dbname   // "ceiba"' <<<"$APP_DB_JSON")"

[ -n "$DB_USER" ] || die "$APP_DB_SECRET has no .username"
[ -n "$DB_PASS" ] || die "$APP_DB_SECRET has no .password"
[ -n "$DB_HOST" ] || die "$APP_DB_SECRET has no .host - add it, so a rebuilt host needs no operator input"

# Refuse to build a runtime URL from the master role. The master account is
# for migrations only; if it ends up in .env it will break at the next
# 7-day rotation, and it hands every container permission to drop the schema.
case "$DB_USER" in
  postgres|ceibaadmin|rdsadmin|master|admin)
    die "$APP_DB_SECRET holds the MASTER user '$DB_USER'. .env must carry the ceiba_app role. Refusing." ;;
esac

# The generated password can contain @ : / % - all reserved in a URL's
# userinfo section. An unencoded password was a real production outage on
# 2026-08-17 (PrismaClientInitializationError on both containers).
DATABASE_URL="postgresql://$(urlencode "$DB_USER"):$(urlencode "$DB_PASS")@${DB_HOST}:${DB_PORT}/${DB_NAME}"

echo "==> Reading application secrets"
# Plain indexed arrays, not an associative array: bash 3.2 (still the
# default on macOS) has no `declare -A`, and this script should run the same
# way from a laptop as it does on the host.
RESOLVED=()
MISSING=()
for pair in "${FLAT_SECRETS[@]}"; do
  key="${pair%%:*}"; name="${pair##*:}"
  if value="$(fetch_secret "$name")" && [ -n "$value" ]; then
    RESOLVED+=("${key}=${value}")
    note "ok       $key"
  else
    # Still emit the key, empty. A present-but-blank variable is far easier
    # to spot on the host than a line that simply isn't there.
    RESOLVED+=("${key}=")
    MISSING+=("$key <- $name")
    note "MISSING  $key  ($name)"
  fi
done

if [ "${#MISSING[@]}" -gt 0 ]; then
  echo
  echo "WARNING: ${#MISSING[@]} secret(s) unavailable. Each of these fails SILENTLY at runtime:"
  printf '  - %s\n' "${MISSING[@]}"
  echo "Create them with: aws secretsmanager put-secret-value --region $REGION --secret-id <name> --secret-string '<value>'"
  echo "(run that from your laptop - the instance role is deliberately read-only on Secrets Manager)"
  echo
fi

# --- Non-secret configuration -------------------------------------------

CONTROL_PLANE_IMAGE="${CONTROL_PLANE_IMAGE:-}"
RUNTIME_IMAGE="${RUNTIME_IMAGE:-}"

# Reuse the images the host is already running, so a .env rebuild never
# silently rolls the deployed version back to some default.
if [ -z "$CONTROL_PLANE_IMAGE" ] && [ -f "$ENV_FILE" ]; then
  CONTROL_PLANE_IMAGE="$(grep -E '^CONTROL_PLANE_IMAGE=' "$ENV_FILE" | cut -d= -f2- || true)"
fi
if [ -z "$RUNTIME_IMAGE" ] && [ -f "$ENV_FILE" ]; then
  RUNTIME_IMAGE="$(grep -E '^RUNTIME_IMAGE=' "$ENV_FILE" | cut -d= -f2- || true)"
fi
[ -n "$CONTROL_PLANE_IMAGE" ] || die "CONTROL_PLANE_IMAGE unknown. Pass it in the environment: CONTROL_PLANE_IMAGE=<ecr-url>:<tag> $0"
[ -n "$RUNTIME_IMAGE" ]       || die "RUNTIME_IMAGE unknown. Pass it in the environment: RUNTIME_IMAGE=<ecr-url>:<tag> $0"

CEIBA_APP_HOST="${CEIBA_APP_HOST:-app.useceiba.com}"
CEIBA_API_HOST="${CEIBA_API_HOST:-api.useceiba.com}"
CEIBA_ACME_EMAIL="${CEIBA_ACME_EMAIL:-}"
[ -n "$CEIBA_ACME_EMAIL" ] || die "CEIBA_ACME_EMAIL unset. Caddy needs it to issue certificates."

if [ "$MODE" = "check" ]; then
  echo
  echo "==> --check: would write $ENV_FILE with"
  note "DATABASE_URL     postgresql://${DB_USER}:***@${DB_HOST}:${DB_PORT}/${DB_NAME}"
  note "resolved         $(( ${#FLAT_SECRETS[@]} - ${#MISSING[@]} )) of ${#FLAT_SECRETS[@]} secret(s), ${#MISSING[@]} missing"
  note "images           ${CONTROL_PLANE_IMAGE##*/} / ${RUNTIME_IMAGE##*/}"
  echo "Nothing written."
  exit 0
fi

# --- Write .env ----------------------------------------------------------

if [ -f "$ENV_FILE" ]; then
  backup="${ENV_FILE}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  cp -p "$ENV_FILE" "$backup"
  echo "==> Backed up existing .env to ${backup##*/}"
fi

umask 077
tmp="$(mktemp "${ENV_FILE}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

{
  echo "# Generated by bootstrap-host.sh at $(date -u +%Y-%m-%dT%H:%M:%SZ). Do not edit by hand:"
  echo "# re-run the script instead, so the next host rebuild produces the same file."
  echo
  echo "CONTROL_PLANE_IMAGE=${CONTROL_PLANE_IMAGE}"
  echo "RUNTIME_IMAGE=${RUNTIME_IMAGE}"
  echo "CEIBA_APP_HOST=${CEIBA_APP_HOST}"
  echo "CEIBA_API_HOST=${CEIBA_API_HOST}"
  echo "CEIBA_ACME_EMAIL=${CEIBA_ACME_EMAIL}"
  echo
  echo "# ceiba_app role - NOT the RDS master. See the header of this script."
  echo "DATABASE_URL=${DATABASE_URL}"
  echo
  echo "REDIS_URL=redis://redis:6379"
  echo "LOG_LEVEL=info"
  echo
  echo "NEXT_PUBLIC_CLERK_SIGN_IN_URL=/login"
  echo "NEXT_PUBLIC_CLERK_SIGN_UP_URL=/sign-up"
  echo "NEXT_PUBLIC_CLERK_SIGN_IN_FALLBACK_REDIRECT_URL=/"
  echo "NEXT_PUBLIC_CLERK_SIGN_UP_FALLBACK_REDIRECT_URL=/"
  echo "CEIBA_PUBLIC_APP_URL=https://${CEIBA_APP_HOST}"
  echo
  printf '%s\n' "${RESOLVED[@]}"
} > "$tmp"

chmod 600 "$tmp"
mv "$tmp" "$ENV_FILE"
trap - EXIT
echo "==> Wrote $ENV_FILE (mode 600)"

if [ "$MODE" = "env-only" ]; then
  echo "==> --env-only: stack untouched."
  exit 0
fi

# --- Bring the stack up --------------------------------------------------

cd "$(dirname "$ENV_FILE")"

echo "==> Logging in to ECR"
registry="${RUNTIME_IMAGE%%/*}"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$registry"

echo "==> Pulling images"
docker compose pull

echo "==> Starting stack"
docker compose up -d

echo "==> Waiting for readiness"
ok=0
for i in $(seq 1 30); do
  if curl -fsS --max-time 10 "https://${CEIBA_API_HOST}/ready" 2>/dev/null | grep -q '"ok":true'; then
    ok=1; break
  fi
  echo "  [$i/30] not ready yet"
  sleep 10
done

if [ "$ok" -ne 1 ]; then
  echo "ERROR: https://${CEIBA_API_HOST}/ready did not report ok within 5 minutes." >&2
  echo "Recent logs:" >&2
  docker compose logs --tail 50 runtime control-plane >&2 || true
  exit 1
fi

curl -fsS --max-time 10 "https://${CEIBA_APP_HOST}/api/ready" | grep -q '"ok":true' \
  || die "control-plane readiness (https://${CEIBA_APP_HOST}/api/ready) did not report ok"

echo
echo "==> Host is serving. Both readiness endpoints report ok."
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "    NOTE: ${#MISSING[@]} secret(s) still missing - see the warning above."
fi
exit 0
