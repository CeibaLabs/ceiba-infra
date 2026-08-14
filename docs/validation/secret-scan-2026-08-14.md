# Validation — pre-publication secret scan

**Date:** 2026-08-14
**Subject:** `github.com/CeibaLabs/ceiba-infra`, full history
**Commit at time of scan:** `900ac2a`
**Reason:** this repository was private while production infrastructure was built and applied. Before making it public, its entire history had to be cleared — not just its current tree.

## Objective

Establish that no credential, key, account identifier, or personal datum is recoverable from any commit in the published history.

**Why history and not just `HEAD`:** deleting a secret in a later commit does not remove it from the repository. Anyone who clones a public repo gets every blob ever committed. A scan of the working tree proves nothing about what a `git log -p` would reveal.

## Method

All three scans were run against a **fresh clone of the real remote**, not the local working copy. That distinction turned out to matter — see "What this surfaced."

```bash
git clone https://github.com/CeibaLabs/ceiba-infra.git /tmp/infra-public-check

# 1. gitleaks — rule-based detection across full history
docker run --rm -v "/tmp/infra-public-check:/repo" \
  zricethezav/gitleaks:latest detect -s /repo

# 2. trufflehog — credential detection with live verification
docker run --rm -v "/tmp/infra-public-check:/repo" \
  trufflesecurity/trufflehog:latest git file:///repo --only-verified

# 3. manual grep over every patch in history
git log -p --all | grep -inE \
  "AKIA|aws_secret|password|private_key|BEGIN RSA|BEGIN OPENSSH|token|api[_-]?key|\.pem|arn:aws:iam::[0-9]{12}"
```

## Results

| Scan | Coverage | Result |
|---|---|---|
| gitleaks | 7 commits, 228.46 KB | **no leaks found** |
| trufflehog | 63 chunks, 229,384 bytes | **0 verified, 0 unverified secrets** |
| Manual grep | Every patch, all refs | 31 matches, **all reviewed, all benign** |

The 31 grep matches are variable names, Secrets Manager *secret names*, documentation prose, and placeholders — `RESEND_API_KEY=` with no value, `re_...` and `sk_live_...` as literal ellipses in example commands, `.password` as a `jq` field selector, and the standard `docker login --password-stdin` ECR line. The pattern matched the vocabulary of secrets, which is what it is designed to do; none of the matches is a value.

Separately confirmed by direct enumeration of every blob in the remote:

- No `*.tfstate`, `*.tfvars`, or `.env` file was **ever** added in any commit.
- No 12-digit AWS account ID appears anywhere. Ten 12-digit strings were flagged and individually traced to floating-point path coordinates inside `diagrams/aws-deployment-architecture.svg`.
- No ARN carrying an account field, and no live AWS resource identifier (`i-`, `vpc-`, `subnet-`, `sg-`, `eipalloc-`).

## What this surfaced

1. **Two real disclosures existed in the local branch history and had to be redacted before landing** — a personal email address written into the deployment guide's ACME step, and a live security group ID quoted in a `vpc.tf` comment. Neither is a credential; both are gratuitous.

   **Neither ever reached the remote.** Because every feature branch in this repository is squash-merged, the intermediate commits that carried them were never pushed. Verified by enumerating every blob in the fresh clone and searching for both strings: zero hits. A merge-commit workflow would have published both. This was luck arising from a convention, not from foresight, and it is worth naming as such.

2. **Scanning the local repository would have produced a false positive.** `git fsck` shows the pre-redaction commits still present locally as unreachable objects. A scan of the working directory would have flagged content that no reader could ever obtain. Cloning the remote is the only way to scan what is actually published.

3. **The README's Status section still described the infrastructure as "draft… not yet applied. Nothing live anywhere"** while it was serving production traffic. Not a security finding, but it would have been the first thing a reader saw, and it was false. Corrected in `900ac2a`.

## Conclusion

`ceiba-infra` is cleared for public release. Three independent methods agree, run against the artifact that will actually be published.

## Not tested

- **Commit author metadata.** `git log` exposes the author name and email on every commit. This is inherent to git and unchanged by any scan; it is a deliberate acceptance, not a gap.
- **The diagram binaries.** `diagrams/*.png` was not decoded and inspected for embedded text or EXIF. The SVG's text content was reviewed and is generic architecture labelling.
- **Third-party exposure.** This scan covers the repository only. It does not verify that a secret was never pasted into an issue, a PR comment, or a CI log.
- **Future commits.** This is a point-in-time result at `900ac2a`. Nothing in the repository currently prevents a future commit from introducing a secret — a pre-commit `gitleaks` hook is the obvious next control and does not exist yet.
