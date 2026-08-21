# ADR-0004: Production images built off-host and distributed through ECR

**Status:** accepted
**Date:** 2026-08-20 (retroactively documenting D-048, decided 2026-07-29)

## Context

`ceiba-runtime` and `ceiba-control-plane` both depend on the private sibling repo `ceiba-core-domain` via a `file:../ceiba-core-domain` path. Getting a runnable container onto the app host requires building an image from source somewhere. The two realistic options: build directly on the EC2 app host, or build off-host and pull a finished image from a registry.

The app host is a `t4g.small` — 2 vCPU, **2 GiB RAM**. A `next build` of the Control Plane on 2 GiB is a genuine OOM risk, and discovering that during a live deploy is the worst possible time. Building on the host also means the private `ceiba-core-domain` checkout, and a credential for it, would have to live on a production machine — purely to satisfy a build-time dependency, not a runtime one.

## Decision

**Images are built off-host (GitHub Actions CD, D-061) and pushed to private Amazon ECR repositories** (`terraform/ecr.tf`), which the EC2 host then pulls with pull-only IAM permissions. The host never builds an image and never holds application source.

**Alternative priced: GitHub Container Registry (GHCR) instead of ECR.** GHCR is free for private repos on GitHub — a real dollar saving over ECR's non-zero cost. It was rejected anyway: two ~93 MB images on ECR cost roughly **$0.02/month**, immaterial against the $80/month ceiling, while GHCR would require a second credential path onto the production host (a GitHub PAT or App token for `docker login ghcr.io`) alongside the AWS-native OIDC/IAM path already trusted for the SSM deploy step. ECR stays inside the same AWS IAM boundary the rest of the deploy already uses — no new credential type to rotate or leak, for a cost difference of two cents a month.

## Consequences

- `terraform/ecr.tf` creates two private repositories with `IMMUTABLE` tags, scan-on-push, and a lifecycle policy (untagged images expire after 1 day, keep the last 10 tagged) — an unbounded image history is how a $0.02 line item stops being one.
- The EC2 role is pull-only: `ecr:GetAuthorizationToken` (no resource-level support, its own statement) plus `BatchGetImage`/`GetDownloadUrlForLayer`/`BatchCheckLayerAvailability` scoped to the two repository ARNs. The host must never push.
- `IMMUTABLE` tags mean a retry after a partial failure needs a fresh tag or a reused already-pushed one (D-048's own CD workflow handles this via a "does this tag already exist" check before building) — a real operational wrinkle this decision accepts in exchange for never being able to silently overwrite a deployed image.

## Reversal criteria

Revisit if ECR's cost ever becomes non-trivial (it won't at this image count/size) or if a second registry becomes genuinely necessary for a reason unrelated to this decision (e.g. a future public image an external consumer needs to pull). Not revisited for cost reasons alone — the $0.02/month gap to GHCR will never be the deciding factor.

## Source

`_workspace/decisions.md` D-048 (2026-07-29) records the original decision and reasoning; this ADR formalizes it into the ADR format the README references and adds the GHCR cost comparison the original decision record didn't spell out as a priced alternative.
