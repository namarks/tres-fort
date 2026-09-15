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
  - Release the Worker and updated iOS build under explicit release authority.
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
    remains explicit and the connect-code form remains a fallback.
  - Codex receives a credential-free setup request with manual desktop/CLI
    fallbacks. Explain its computer requirement and Remote support. A hosted
    mobile install still requires the P4 provider-issued listing URL.
  - Local verification: 26 backend protocol/approval tests, 14 iOS unit tests,
    all three focused UI journeys, TypeScript and plan validation passed.
    Inspected synthetic Claude/Codex screenshots; local Codex review found no
    actionable regressions. Exact-head independent GitHub review and CI are
    required for the follow-up merge. Real-device provider handoff remains P2/P4.
- [ ] **P4 — Publish and verify the consumer Connect button**
  - Obtain owner release/submission authority, verified publisher identity,
    dedicated synthetic reviewer access and approved terms. Worldwide availability
    in provider-supported countries is selected; a terms draft is prepared for review.
  - Release/verify the website association, iOS app and Worker; submit the
    prepared remote MCP plugin and address provider review.
  - After provider approval/publication produces an actual install URL, wire
    that URL into the app and verify install, approval, coaching read/write,
    iOS sync and disconnect on iPhone. No placeholder install URL is shipped.

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P2 | gated_by | external:owner-byo-coach-release | Production, iOS distribution and a real account connection need their own authority and owner-side credentials. |
| P4 | gated_by | external:owner-coach-plugin-publication | Publisher identity, public listing and provider submission require owner authority; provider approval must produce a real install URL. |

## Next step

**Now (@owner):** Approve the staged app/website/Worker release and complete
provider identity, reviewer-access, terms and submission inputs for P2/P4.
The P3.1 follow-up is implemented and locally verified; its repository delivery
must pass the exact-head gate below. P3 landed in [PR #191](https://github.com/namarks/tres-fort/pull/191),
merged 2026-09-13 as `5312a32b05ed4375b754573fcbcbbd453d16b940`.
P2/P4 retain their release/publication gates. Claude's documented install link
does not require directory review; a phone-only Codex install still does.
Identity verification, synthetic reviewer access, terms approval and provider
attestations remain owner-managed inputs.

**Repository delivery gate (@agent):** Require fresh independent review of the
exact follow-up head, all relevant CI terminal-green, and no blocking findings
or unresolved threads. Merge is not a production or iOS release.

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
