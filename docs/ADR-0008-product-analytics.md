# ADR-0008: Product analytics scope — landing site + Control Plane (Option B)

**Status:** accepted, Option C explicitly deferred
**Date:** 2026-08-24

## A note on scope, before the rest of this document

Every ADR before this one in this series documents infrastructure — networking, compute,
deployment, state. This one documents instrumentation added to two of Ceiba's applications: the
public marketing site and the authenticated Control Plane console. It's included here anyway,
because David asked for the ADR series to stay unified rather than starting a second series for a
single document, and because the reasoning — what to measure, what not to, and why — is exactly
the kind of decision this series already exists to record. Nothing below describes application
business logic in any depth beyond what's needed to explain the instrumentation itself.

## Context

Before this work, Ceiba had no product analytics running anywhere. `posthog-js` had been added to
the landing site earlier, wired up with a consent banner and an accurate Privacy Policy disclosure,
but no analytics key was ever configured in production — so none of it was active, and nothing had
ever been collected. Separately, an earlier assessment claimed the funnel from the marketing site
to the Control Plane console was **cross-domain**, and concluded from that that only click-through
could ever be measured, not signup or activation. That assessment was wrong (see below), and it
made the achievable scope look smaller than it actually is.

The concrete cost of measuring nothing: a paid-acquisition test had been proposed and was blocked,
because there was no way to tell whether a click ever became a signed-up user, let alone an active
one. Fixing that required deciding what to measure, and deliberately, what not to.

## Decision

**Instrument the marketing site and the Control Plane console (Option B).** Track three funnel
stages — a "Start for Free" click on the marketing site, signup completion, and first project
creation — with one identity stitched across all three via a shared cookie and an explicit
`identify()` call at signup.

**Explicitly defer instrumenting the Runtime authorization path (Option C)**, which would extend
the funnel to "first successful API call." Three reasons, together, not any one alone:

- Runtime's authorization endpoint is the hottest path in the product — every protected API request
  a customer's downstream caller makes goes through it. Adding analytics capture there means adding
  work to a path that is deliberately kept narrow and fast today.
- Event volume there is a different order of magnitude from anything on the other two stages, and
  event volume is what a usage-based analytics vendor bills on.
- Runtime authorizes a *project*, not a person. Attributing an authorize call back to the account
  that owns the project requires a lookup that the authorize path doesn't do today, and adding one
  means either a database read on every request or a design where identity is stitched later,
  outside the hot path. Neither is a decision to make casually or bundle into the same change as the
  first two stages.

Option C is a real follow-on once Option B's taxonomy has actually proven itself with real data —
not dropped, just sequenced after.

## The cross-subdomain finding

The marketing site and the Control Plane console are **different subdomains of the same
registrable domain**, not different domains. That distinction matters because the analytics
library's own cross-subdomain cookie logic depends on it: it derives the last two labels of the
current hostname and checks them against a small blocklist of generic multi-tenant hosting domains.
The shared domain here isn't on that list, so the identity cookie is written at the domain level and
is readable across both subdomains without any extra plumbing — no query parameters, no manual
aliasing.

This was verified by reading the installed analytics library's own compiled source directly, not by
trusting its documentation or an earlier summary of it — and it is the correction to the earlier
"cross-domain" claim. The distinction is easy to get wrong by ear and expensive to get wrong in a
design: cross-domain would have needed a real identity-bridging mechanism; cross-subdomain needs
almost none.

One piece of this still needs a live check once the service is actually configured with a real key
in production: that the cookie genuinely does carry the identity across in practice, not just in the
library's source. That verification is recorded as still open in this project's own working notes,
not asserted as done here.

## The client/server split

Not every funnel stage happens in a browser. The first stage (the marketing-site click) and the
second (signup) both do — a visitor's browser is present the whole time, and the analytics library
already running there can capture both. The third stage, project creation, happens inside a server
action with no client-side round trip required to complete it. The chosen approach captures it from
the client anyway, on the action's own success path, reusing the browser's already-established
identity rather than adding a second, server-side analytics client for one event. That is a
deliberate trade: it is simpler and avoids a second SDK, at the cost of only firing if the browser
that submitted the request is still there to observe the result — which, for a modal that shows the
result inline, it always is.

The deferred fourth stage (first successful Runtime authorization) has no client-side path at all —
the caller is a customer's own backend service, not a browser. Instrumenting it, whenever that
happens, means a server-side analytics client and a different identity story: no cookie, no browser
distinct ID, just whatever the request itself carries.

## The consent posture

The marketing site's analytics remain exactly as they were: off by default, gated behind an
Accept/Decline banner, documented in the Privacy Policy. That does not change.

The Control Plane console does **not** get a consent banner of its own. The reasoning: a cookie
banner in front of an already-authenticated console, in front of a customer who is actively paying
for the service, is a real UX cost for a surface where the analytics in question is product-usage
telemetry about someone using a service they hold an account with — not anonymous visitor tracking.
The two are commonly treated under different legal bases, and that is the position taken here. It is
a judgment call, not a technical inevitability, and it was made deliberately rather than defaulted
into.

One consequence of the identity-linking design is worth naming plainly: because the identity cookie
is shared across both subdomains, a visitor's consent choice on the marketing site can, in
principle, carry into their later Control Plane session in either direction — someone who declined
on the marketing site could arrive at the console still opted out of analytics there too; someone
who accepted could arrive already opted in to a surface they were never separately asked about.
Given the Control Plane's analytics run on a different legal basis in the first place (not
consent-gated), this interaction is less consequential than it would be if both surfaces relied on
the same consent mechanism — but it is a real interaction between two independently-reasoned
decisions, and it is called out here rather than left implicit. The Privacy Policy was updated in
the same change that added this instrumentation, not afterward, specifically so it would never
describe less than what is actually being collected.

## Consequences

**Real costs, not just benefits:**

- **A dependency on a named third-party processor.** The Privacy Policy now names the analytics
  vendor directly — the one deliberate exception to this project's general rule against naming
  vendors in customer-facing copy, made because a privacy disclosure that doesn't say who is
  processing the data isn't a real disclosure.
- **An event taxonomy that is expensive to rename.** Once real data accumulates against event and
  property names, renaming them fragments historical data rather than cleanly correcting it. The
  taxonomy was proposed and reviewed before any instrumentation was written, specifically to reduce
  the odds of needing that kind of rename later.
- **The funnel still stops short of activation.** Signup and project creation are necessary
  precursors to a customer's API actually being protected, but neither one *is* that. Whether the
  product is actually being used only becomes measurable once Option C lands.
- **A second SDK, deferred but not eliminated.** Instrumenting Runtime later means introducing a
  server-side analytics client into a service that has never had one, with its own lifecycle
  (explicit flush rather than fire-and-forget) and its own identity model.
- **Two config keys this instrumentation currently relies on that this document deliberately does
  not name values for.** Nothing is collected in any environment until they're set; this ADR
  describes the design, not the operational rollout.

## What would trigger revisiting this

- **Instrumenting Runtime (Option C)** once the three-stage funnel in Option B has real data behind
  it and the taxonomy has held up — not on a fixed timeline, on evidence that B is telling the
  intended story.
- **The Control Plane's no-banner consent posture**, if the product later handles data or customers
  under a jurisdiction or contract where product-usage telemetry needs its own explicit consent
  rather than resting on the "already-authenticated account" reasoning above.
- **The one-project-vs-two-projects choice** inside the analytics vendor's own dashboard, if the
  marketing site and Control Plane ever need genuinely separate data governance — that would mean
  deliberately giving up the single cross-subdomain funnel this whole design exists to create.
- **The event taxonomy itself**, if a stage needs splitting or a property turns out to hide more
  than it reveals — expensive to do, but the taxonomy was never meant to be permanent, only
  deliberate.
