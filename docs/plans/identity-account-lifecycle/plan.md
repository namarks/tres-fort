# Identity and Account Lifecycle

Slug: identity-account-lifecycle · Status: gated · Updated: 2026-08-29 · Theme: training-trust

## Goal

Keep a returning user authenticated without destroying their queued training or
HealthKit state, while giving every user a direct way to export and delete their
own account data. Completion means expiry, same-user reauthentication, Apple
credential revocation, export, and confirmed deletion have focused backend and
iOS verification.

## Phases

- [ ] **P0 — Independent identity foundations**
  - [x] **(a) Renewable sessions and per-user account scoping**
    - Implement the smallest renewable app-session path compatible with the
      current JWT and Sign in with Apple design, renewing before the fixed expiry
      and recovering the same user after an authorization failure.
    - Separate same-user reauthentication from an account switch. Own the shared
      per-user account namespace and switch semantics so feature-owned outboxes
      and HealthKit state survive reauthentication without crossing accounts.
    - Cover expiry, renewal, offline renewal failure, same-user recovery, and
      account switching without introducing a general session platform.
  - [ ] **(b) In-app account deletion**
    - Add an authenticated `DELETE /api/me` service path that removes the
      caller's personal training data, external credentials, tokens, and
      memberships under the current ownership model without touching another
      user's data.
    - Add a plainly worded, explicit confirmation flow in Profile and sign the
      deleted user out only after the server acknowledges deletion.
    - Verify cascade behavior with seeded test users; never exercise deletion
      against a real owner account during development or CI.
- [ ] **P1 — Portability and credential recovery**
  - Add a user-scoped export assembled from the authoritative training state and
    make it downloadable from Profile.
  - Detect revoked Sign in with Apple credentials and present a recoverable
    sign-in state; let a user repair the profile name that Apple supplies only on
    first authorization.
  - Verify exports contain only the caller's data and revoked credentials do not
    leave the app appearing connected.

## Execution frontier

- P0(b)

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P0(b) | gated_by | external:account-deletion-implementation-authorization | Creating a broad irreversible account-deletion service path requires explicit owner authorization; owner-anchor recreation and surviving-group ownership also need explicit semantics. |

## Next step

**Now (@owner):** Explicitly authorize the destructive account-deletion service
path and decide whether owner deletion leaves a tombstone that blocks automatic
MCP re-bootstrap, plus how surviving groups transfer `created_by`.

## Notes / open questions

- Source: the August 2026 functionality review at commit `91fd622`; the confirmed
  root issue is the fixed JWT expiry plus an over-broad `AuthModel.invalidate()`.
- P0(a) now uses rolling app-JWT renewal plus account-scoped activity,
  intervals.icu, and HealthKit state. Focused backend tests, direct iOS source
  typechecking, and a standalone behavioral harness cover expiry, renewal,
  offline failure, same-user recovery, and account switching; this host has no
  installed iOS simulator runtime, so the checked-in XCTest target could not run
  through `xcodebuild` here.
- Runtime account deletion remains destructive and must always require the
  authenticated user's explicit in-app confirmation. Development and CI must
  exercise only seeded users.
- `ensureOwnerUser` currently recreates a missing owner whenever the static MCP
  bearer is used, so deleting the owner row without a persistent suppression
  rule would silently recreate the account. `groups.created_by` is also a
  non-null user reference, so a creator's deletion must either transfer each
  surviving group or deliberately block until ownership changes.
