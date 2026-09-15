# Bring Your Own AI Coach

Slug: bring-your-own-ai-coach · Status: gated · Updated: 2026-09-14 · Theme: coaching

## Goal

Members can coach in their chosen external AI app, starting with Codex and
preserving Claude, while Très Fort remains the source of truth for training.
The free offering uses members' own supported AI accounts or subscriptions.
Repository delivery and actual provider connection/release evidence remain distinct.

## Phases

- [x] **P0 — Make the external coaching contract portable**
  - Neutral setup, consent, profile and new-note attribution; preserve historical
    notes, legacy API compatibility, account isolation and existing OAuth grants.
  - Expose the coaching brief as a tool alongside its resource and prompt.
  - Guide Codex, Claude and generic compatible apps without promising universal
    model/client support or accepting provider API keys.
- [x] **P1 — Verify the coaching and compatibility behavior**
  - Exercise synthetic OAuth client flows, coaching reads/writes, stale-version
    conflicts, refresh/disconnect, API rollout compatibility, and iOS setup.
  - Local Codex review completed after the callback and disclosure fixes.
    Repository merge still requires the delivery gate below.
- [ ] **P2 — Release and verify a real Codex connection**
  - Worker and iOS 1.0 (42) released under explicit owner authority on
    2026-09-14 Pacific; [release receipt](../app-store-submission/release-42.md)
    records exact source, production traffic and internal TestFlight availability.
  - Owner completes Codex sign-in using their own code, verifies a read and one
    reversible plan change in iOS, then disconnects/reconnects.
- [x] **P3 — Prepare mobile account approval and the plugin**
  - Approved 2026-09-12: implement the iPhone connection direction. Desktop
    manual configuration remains an advanced fallback; the product-choice hold
    is resolved.
  - Prepare the remote MCP package, listing assets, annotations and five
    positive/three negative review cases in `plugins/tres-fort/`.
  - Implement explicit signed-in app approval via a verified website Universal
    Link, with expiring one-use requests, PKCE-bound callbacks and account fences.
  - Local checks: 1,057 backend tests; 551 iOS unit tests passed and one
    existing skip; mobile consent UI journey; Chrome 152 form redirect/PKCE
    round trip (IPv4/IPv6, initial consent and retry, JavaScript disabled);
    eight focused iOS session/approval tests after the renewal fix; plugin,
    site, TypeScript and plan validation. Local review found
    a Chromium CSP redirect regression and an understated legacy logging hint;
    both are fixed with behavioral regression coverage. Unfinished approvals
    remain cancellable from Profile even before a token exists.
    Final local review and exact-head GitHub review/CI remain merge gates.
  - CI scope correction: the former smoke list had expanded to 56 of 77 UI
    methods; one shard spent 18 minutes on UI tests and another hit the job
    timeout. Following the owner's cost/latency concern, PRs keep all unit tests
    plus twelve explicit core journeys on two runners. Nightly/manual runs
    retain the full suite on three runners. Active logs survive forced
    cancellation; assertions and the 30-minute limit remain unchanged.
    [Verification policy](../../IOS-VERIFICATION.md) records the selection.
  - Integrated current App Store attribution/reviewer changes: dedicated plugin
    review uses an ordinary synthetic member, not the retired shared sample
    identity. Focused verification passed 111 backend tests, 14 iOS unit tests
    and two approval/sign-in UI journeys, plus the verifier/scope and plan checks.
- [x] **P3.1 — Simplify linking for Claude and Codex**
  - Approved 2026-09-14: present both provider choices with setup actions before
    optional code generation. Default to Claude's available mobile web flow.
  - Claude uses its documented prefilled install link; native account approval
    remains explicit and the connect-code form remains a fallback. Successful
    browser handoff dismisses setup so returned approval can present immediately.
    Press and hold the connect button to copy the prefilled link for Safari.
    Incoming approval also replaces open or restored setup after a copied link.
    Profile, Today and onboarding share the same setup presentation.
  - Codex receives a credential-free setup request with manual desktop/CLI
    fallbacks. Explain its computer requirement and Remote support. A hosted
    mobile install still requires the P4 provider-issued listing URL.
  - Verification covers 26 backend protocol/approval tests, 14 iOS unit tests,
    five focused UI journeys (provider handoff, open/restored setup return,
    code fallback, approval and connected-member continuation), TypeScript and
    plan validation.
    Inspected synthetic Claude/Codex screenshots. Review follow-ups cover the
    browser-return presentation, connected-status journey and family quickstart.
    [PR #207](https://github.com/namarks/tres-fort/pull/207) merged as
    `5df9208fc01219f298866ee4528cda533b86d33d` after exact-head independent
    review and all eight checks passed. The merged-source CI also passed.
    Real-device provider handoff remains P2/P4.
- [ ] **P4 — Publish and verify the consumer Connect button**
  - Obtain owner plugin submission/publication authority, verified publisher identity,
    dedicated synthetic reviewer access and approved terms. Worldwide availability
    in provider-supported countries is selected; a terms draft is prepared for review.
  - Website association, iOS app and Worker release are recorded in the
    build 42 receipt; submit the prepared remote MCP plugin after the named
    owner inputs and address provider review.
  - After provider approval/publication produces an actual install URL, wire
    that URL into the app and verify install, approval, coaching read/write,
    iOS sync and disconnect on iPhone. No placeholder install URL is shipped.

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P2 | gated_by | external:owner-byo-coach-device-verification | Production and internal TestFlight release are complete; the real-provider connection requires the owner's signed-in iPhone and AI account. |
| P4 | gated_by | external:owner-coach-plugin-publication | Publisher identity, public listing and provider submission require owner authority; provider approval must produce a real install URL. |

## Next step

**Now (@owner):** Install TestFlight 1.0 (42) and complete the real-provider
connection, coaching read, reversible edit, iOS sync and disconnect/reconnect
checks. Claude's install link and native approval are released, but their full
physical-iPhone round trip has not been verified. Codex's direct connection still
uses the desktop setup; a phone-only hosted install requires P4 publication.

**Release complete (2026-09-14 Pacific):** The owner authorized the latest
production and TestFlight release. Worker version
`92adb0e0-28bd-4952-81ad-b09029f75ac9` serves the reviewed source at 100% traffic;
Apple reports build 42 VALID, IN_BETA_TESTING and assigned to internal Testers.
The website already matched the release and all migrations were already applied.
See the [exact release receipt](../app-store-submission/release-42.md). Public
checks do not prove authenticated training behavior or a physical-device handoff.

**Plugin publication remains gated:** Complete publisher identity, dedicated
synthetic reviewer access, terms approval and explicit submission/publication
authority. This release did not submit a plugin or publish the draft terms.
Claude's documented install link does not require directory review; a phone-only
Codex install still does. P3 landed in [PR #191](https://github.com/namarks/tres-fort/pull/191);
P3.1 landed in [PR #207](https://github.com/namarks/tres-fort/pull/207).

## Notes / open questions

- Approved 2026-09-12: conversations remain in users' external AI apps. A future
  paid package may bundle in-app coaching and API usage if costs justify it.
  No provider key storage, model execution, billing, paid entitlement, pricing,
  is authorized or implemented here.
- Setup correction 2026-09-12: terminal commands are optional, collapsed under
  Advanced; the normal Codex path uses the desktop app's server form. This still
  requires entering a URL and is not an iPhone-only or one-button connection.
  P3/P4 record the requested consumer flow. Public plugin distribution is separate
  from the existing direct desktop MCP connection and from future paid API usage.
- Verification: the final backend suite passed all 1,046 tests across 74 files.
  All 60 focused OAuth and client tests, TypeScript and website tests passed. iOS unit coverage:
  545 passed and one existing test skipped. All ten activation journeys passed
  across the full run and the two corrected lazy-row navigation reruns; the
  Codex setup screenshots were inspected. Local Codex reviews, including review
  of the command-free setup, found no actionable regressions. The revised setup
  UI journey also passed; fresh independent GitHub review and CI remain required
  before merge. PR checks carry final evidence.
- [PR #191](https://github.com/namarks/tres-fort/pull/191) carries the merged P3
  foundation. Its checks retain the final repository-delivery evidence.
- Start: verified remote main `90f968383629107bd7a95b37bd44da177f87305f`.
  Concurrent onboarding and App Store sessions require isolated work; keep shared
  entry-copy changes narrow and reconcile current main before merge.
- [Connection guide](../../COACH-CONNECTIONS.md) defines supported capabilities,
  rollout behavior and the real-account verification procedure. Synthetic protocol
  fixtures do not prove a specific installed Codex version or live model response.
