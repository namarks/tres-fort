# Identity and Account Lifecycle

Slug: identity-account-lifecycle · Status: active · Updated: 2026-08-28 · Theme: training-trust

## Goal

Keep a returning user authenticated without destroying their queued training or
HealthKit state, while giving every user a direct way to export and delete their
own account data. Completion means expiry, same-user reauthentication, Apple
credential revocation, export, and confirmed deletion have focused backend and
iOS verification.

## Phases

- [ ] **P0 — Renewable sessions without destructive reauthentication**
  - Implement the smallest renewable app-session path compatible with the
    current JWT and Sign in with Apple design, renewing before the fixed expiry
    and recovering the same user after an authorization failure.
  - Separate same-user reauthentication from an account switch. Key local
    outboxes and HealthKit state by user so reauthentication preserves them and
    a real switch cannot inherit them.
  - Cover expiry, renewal, offline renewal failure, same-user recovery, and
    account switching without introducing a general session platform.
- [ ] **P1 — In-app account deletion**
  - Add an authenticated `DELETE /api/me` service path that removes the caller's
    personal training data, external credentials, tokens, and memberships under
    the current ownership model without touching another user's data.
  - Add a plainly worded, explicit confirmation flow in Profile and sign the
    deleted user out only after the server acknowledges deletion.
  - Verify cascade behavior with seeded test users; never exercise deletion
    against a real owner account during development or CI.
- [ ] **P2 — Portability and credential recovery**
  - Add a user-scoped export assembled from the authoritative training state and
    make it downloadable from Profile.
  - Detect revoked Sign in with Apple credentials and present a recoverable
    sign-in state; let a user repair the profile name that Apple supplies only on
    first authorization.
  - Verify exports contain only the caller's data and revoked credentials do not
    leave the app appearing connected.

## Execution frontier

- P0

## Next step

**Now (@agent):** Complete P0 with focused auth and state-preservation tests,
then verify the iOS client renews without clearing the current user's local data.

## Notes / open questions

- Source: the August 2026 functionality review at commit `91fd622`; the confirmed
  root issue is the fixed JWT expiry plus an over-broad `AuthModel.invalidate()`.
- Runtime account deletion remains destructive and must always require the
  authenticated user's explicit confirmation. Routine implementation, seeded
  tests, and review do not need an owner gate.
