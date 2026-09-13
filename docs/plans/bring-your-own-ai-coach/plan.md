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
- [ ] **P1 — Verify and deliver the repository change**
  - Exercise synthetic OAuth client flows, coaching reads/writes, stale-version
    conflicts, refresh/disconnect, API rollout compatibility, and iOS setup.
  - Pass local review, exact-head independent GitHub review and all relevant CI.
- [ ] **P2 — Release and verify a real Codex connection**
  - Release the Worker and updated iOS build under explicit release authority.
  - Owner completes Codex sign-in using their own code, verifies a read and one
    reversible plan change in iOS, then disconnects/reconnects.

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P2 | gated_by | external:owner-byo-coach-release | Production, iOS distribution and a real account connection need their own authority and owner-side credentials. |

## Next step

**Now (@agent):** Finish the two coach-setup UI reruns after correcting lazy-row
scrolling in the tests, then obtain exact-head GitHub review and CI before merging P1.

## Notes / open questions

- Approved 2026-09-12: conversations remain in users' external AI apps. A future
  paid package may bundle in-app coaching and API usage if costs justify it.
  No provider key storage, model execution, billing, paid entitlement, pricing,
  or automatic provider connection is authorized or implemented here.
- Verification: all 1,028 backend tests across 74 files, TypeScript, website tests
  and plan validation passed. iOS unit coverage: 545 passed and one existing test
  skipped. Eight of ten activation journeys passed; two coach-setup journeys
  needed the test helper to scroll before asserting lazy Form-row existence and
  are rerunning. Local Codex review found no actionable regressions.
- [PR #191](https://github.com/namarks/tres-fort/pull/191) carries this implementation;
  exact-head independent review and all CI remain required before merge.
- Start: verified remote main `90f968383629107bd7a95b37bd44da177f87305f`.
  Concurrent onboarding and App Store sessions require isolated work; keep shared
  entry-copy changes narrow and reconcile current main before merge.
- [Connection guide](../../COACH-CONNECTIONS.md) defines supported capabilities,
  rollout behavior and the real-account verification procedure. Synthetic protocol
  fixtures do not prove a specific installed Codex version or live model response.
