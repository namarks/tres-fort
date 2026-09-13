# Bring Your Own AI Coach

Slug: bring-your-own-ai-coach · Status: active · Updated: 2026-09-12 · Theme: coaching

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
- [ ] **P3 — Deliver a mobile install-and-authorize button**
  - Prepare a remote MCP plugin submission with accurate tool annotations,
    listing assets and deterministic positive/negative review cases.
  - Obtain owner publication authority, provider approval and an issued install
    URL before wiring a consumer Connect button.
  - Verify install, explicit account approval, coaching read/write, return to
    Très Fort and disconnect on iPhone; reduce connect-code copying as part of
    that account journey. Keep external subscriptions as the usage model.

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P2 | gated_by | external:owner-byo-coach-release | Production, iOS distribution and a real account connection need their own authority and owner-side credentials. |
| P3 | gated_by | external:owner-coach-plugin-publication | Publisher identity, public listing and provider submission require owner authority; provider approval must produce a real install URL. |

## Next step

**Now (@owner):** Confirm whether a one-time desktop setup is acceptable for the
first version, or whether it must wait for P3's fully mobile connection. The
question is pending after the request for a Connect button; keep PR #191 open
until that product choice is resolved. P2 still needs separate release authority
and owner-managed credentials for a real connection.

**Repository delivery gate (@agent):** Before merging PR #191, require fresh
independent review of its exact head, all relevant CI terminal-green, and no
blocking findings or unresolved threads. PR merge is not a production release.

## Notes / open questions

- Approved 2026-09-12: conversations remain in users' external AI apps. A future
  paid package may bundle in-app coaching and API usage if costs justify it.
  No provider key storage, model execution, billing, paid entitlement, pricing,
  is authorized or implemented here.
- Setup correction 2026-09-12: terminal commands are optional, collapsed under
  Advanced; the normal Codex path uses the desktop app's server form. This still
  requires entering a URL and is not an iPhone-only or one-button connection.
  P3 records the requested consumer flow. Public plugin distribution is separate
  from the existing direct desktop MCP connection and from future paid API usage.
- Verification: the final backend suite passed all 1,046 tests across 74 files.
  All 60 focused OAuth and client tests, TypeScript and website tests passed. iOS unit coverage:
  545 passed and one existing test skipped. All ten activation journeys passed
  across the full run and the two corrected lazy-row navigation reruns; the
  Codex setup screenshots were inspected. Local Codex reviews, including review
  of the command-free setup, found no actionable regressions. The revised setup
  UI journey also passed; fresh independent GitHub review and CI remain required
  before merge. PR checks carry final evidence.
- [PR #191](https://github.com/namarks/tres-fort/pull/191) carries this implementation;
  exact-head independent review and all CI remain required before merge.
- Start: verified remote main `90f968383629107bd7a95b37bd44da177f87305f`.
  Concurrent onboarding and App Store sessions require isolated work; keep shared
  entry-copy changes narrow and reconcile current main before merge.
- [Connection guide](../../COACH-CONNECTIONS.md) defines supported capabilities,
  rollout behavior and the real-account verification procedure. Synthetic protocol
  fixtures do not prove a specific installed Codex version or live model response.
