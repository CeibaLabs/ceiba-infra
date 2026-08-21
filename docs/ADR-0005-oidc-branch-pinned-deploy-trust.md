# ADR-0005: GitHub Actions authenticates to AWS via branch-pinned OIDC, not stored access keys

**Status:** accepted
**Date:** 2026-08-20 (retroactively documenting `terraform/github-oidc.tf`, decided 2026-08-15)

## Context

`ceiba-runtime` and `ceiba-control-plane`'s CD workflows need AWS credentials to push to ECR and run `ssm:SendCommand` against the app host. The conventional, simplest-looking option is a long-lived IAM user access key pair stored as a GitHub Actions secret in each repo.

## Decision

**GitHub Actions authenticates via OIDC federation** (`aws_iam_openid_connect_provider.github_actions`) — short-lived, per-run credentials minted by AWS, no access key stored anywhere. Two roles, not one, because they have different blast radii: `ceiba-github-plan` (read-only, `ceiba-infra`'s own `terraform-plan.yml`) and `ceiba-github-deploy` (ECR push + SSM `SendCommand`, the two app repos' CD).

**Both roles' trust policies are pinned to an exact `sub` claim, not a `repo:OWNER/REPO:*` wildcard** — the plan role to `repo:CeibaLabs/ceiba-infra:pull_request` exactly (matching that workflow's real trigger), the deploy role to `repo:CeibaLabs/ceiba-runtime:ref:refs/heads/<cd_deploy_branch>` and the equivalent for `ceiba-control-plane`. A looser wildcard would let a push to *any* branch in either app repo assume a role that can push production images and run shell commands on the live host — not just the one branch CD actually deploys from.

**Alternative priced: a long-lived IAM user with access keys in repo secrets.** Zero AWS cost either way — IAM roles and OIDC providers carry no charge. The real cost is risk, not dollars: a leaked long-lived key is valid until someone notices and manually rotates it; an OIDC-minted token expires in about an hour and is generated fresh per workflow run. This mirrors D-051's identical reasoning for the human deploy principal (IAM Identity Center over a long-lived IAM user) — the same argument applies to the machine principal.

## Consequences

- No AWS access key exists in either app repo's secrets, confirmed by design — nothing to leak from a compromised Actions log or a misconfigured `echo`.
- The `sub`-claim trust condition is the single most fragile part of this setup: a workflow retrigger mechanism, a branch rename, or a GitHub-side change to how `sub` is computed for a given trigger type can silently break authentication. `cd.yml` prints the token's actual `sub`/`aud` before assuming the role specifically so a break here is a one-glance diagnosis, not a mystery `AccessDenied`.
- Changing which branch triggers CD means changing `var.cd_deploy_branch`, not loosening the trust policy — the whole point of the pinned condition is that widening it is a deliberate, visible Terraform diff, not a side effect of a workflow-file edit.

## Reversal criteria

None anticipated under normal operation — this is a security posture with no ongoing cost tradeoff to reconsider. The only realistic trigger is GitHub Actions OIDC federation itself becoming unavailable or unsupported, in which case the fallback is a scoped IAM user with mandatory key rotation, matching D-051's own documented fallback path for the human principal.

## Source

`_workspace/decisions.md` D-053 and the OIDC design in `_workspace/daily-log.md`'s 2026-08-15 entry record the original reasoning; this ADR formalizes it into the ADR format the README references.
