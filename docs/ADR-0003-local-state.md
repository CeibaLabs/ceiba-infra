# ADR-0003: Local Terraform state (for now)

**Status:** accepted, revisit trigger defined
**Date:** 2026-07-13

## Context

Terraform needs somewhere to persist its state file. The two realistic options at this stage are local state (a `.tfstate` file on the operator's own machine, gitignored) or remote state (an S3 bucket plus DynamoDB table for locking, itself provisioned as infrastructure).

Ceiba is a solo-operator project (`_workspace/AGENTS.md` §7, §18) with no CI system currently authorized to run `terraform apply` — `.github/workflows/terraform-plan.yml` runs `plan` only, on PRs, precisely so no automated actor can apply real infrastructure changes.

## Decision

**Use local Terraform state for now.** `terraform/providers.tf` has no `backend` block, so state defaults to `terraform.tfstate` in the `terraform/` working directory — which is `.gitignore`d (never committed, since it can contain sensitive values in plaintext, e.g. resource ARNs and, depending on provider behavior, some attribute values).

This is explicitly *not* a permanent architectural stance — it's the right-sized choice for exactly one operator applying from exactly one machine, and it's stated here deliberately rather than left as a silent gap, per the README's own "Status" section.

## Consequences

- **Single point of failure:** if the operator's machine is lost without a backup of the state file, Terraform loses track of what it manages. Real AWS resources would still exist, but `terraform plan`/`apply` would no longer reconcile against them correctly without a manual `terraform import` recovery.
- **No locking:** local state has no concurrent-write protection. This is a non-issue today (one operator) and becomes a real risk the moment a second person, or a CI-driven `apply`, enters the picture.
- **Revisit trigger (explicit, not vague):** migrate to a remote backend (S3 bucket with versioning + server-side encryption, plus a DynamoDB table for state locking) at the *first* of these:
  - a second operator/agent needs to run `terraform apply`,
  - `terraform-plan.yml` (or a future `terraform-apply.yml`) needs to run `apply` from CI, or
  - the operator wants state survivability independent of their own machine, as a standalone hardening step.
- Until that trigger, back up `terraform.tfstate` manually (e.g., copy alongside the existing homelab backup discipline) rather than relying on git, since it's intentionally not tracked.

## Source

Called out directly in the `ceiba-infra` README's original "Status" section (`> Terraform state is currently local... remote state ... is the natural next step`) — this ADR formalizes that already-stated position into the ADR format the README references, per this pass's mandate; no new judgment call was required.
