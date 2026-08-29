# Identity and Account Lifecycle

Slug: identity-account-lifecycle · Status: gated · Updated: 2026-08-29 · Theme: training-trust

## Goal

Keep a returning user authenticated without destroying their queued training or
HealthKit state, while giving every user a direct way to export and delete their
own account data. Completion means expiry, same-user reauthentication, Apple
credential revocation, export, and confirmed deletion have focused backend and
iOS verification.

## Phases

- [x] **P0 — Independent identity foundations**
  - [x] **(a) Renewable sessions and per-user account scoping**
    - Implement the smallest renewable app-session path compatible with the
      current JWT and Sign in with Apple design, renewing before the fixed expiry
      and recovering the same user after an authorization failure.
    - Separate same-user reauthentication from an account switch. Own the shared
      per-user account namespace and switch semantics so feature-owned outboxes
      and HealthKit state survive reauthentication without crossing accounts.
    - Cover expiry, renewal, offline renewal failure, same-user recovery, and
      account switching without introducing a general session platform.
  - [x] **(b) In-app account deletion**
    - Add an authenticated `DELETE /api/me` service path that removes the
      caller's personal training data, external credentials, tokens, and
      memberships under the current ownership model without touching another
      user's data.
    - Add a plainly worded, explicit confirmation flow in Profile and sign the
      deleted user out only after the server acknowledges deletion.
    - Verify cascade behavior with seeded test users; never exercise deletion
      against a real owner account during development or CI.
- [ ] **P1 — Portability and credential recovery**
  - [ ] **(a) Authorized downloadable account export**
    - Add the authenticated transport and Profile download/share flow only after
      explicit authorization for the sensitive account-and-training-data egress.
    - Keep the existing caller-scoped service projection dormant until then; its
      focused test already proves caller isolation and secret exclusion.
  - [x] **(b) Apple credential recovery and profile-name repair**
    - Detect revoked Sign in with Apple credentials and present a recoverable
      sign-in state that retains the account namespace and queued training data.
    - Let a user repair the profile name that Apple supplies only on first
      authorization, updating and auditing only the authenticated caller.
    - Store the credential identifier supplied locally by Sign in with Apple;
      do not add a backend identity-data egress solely to migrate older installs.

## Execution frontier

- P1(a)

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P1(a) | gated_by | external:account-export-network-authorization | A downloadable JSON export exposes sensitive account and training data over an authenticated network surface and requires explicit authorization before the route or iOS share flow is added. |

## Next step

**Now (@owner):** Explicitly authorize or decline the authenticated downloadable
account-and-training-data export. If authorized, @agent completes P1(a), repeats
exact-head verification, and closes the plan.

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
- P0(b) uses one transactional D1 batch to revoke the caller's credentials and
  tokens, remove their complete training-data graph and memberships, transfer
  surviving groups to the longest-tenured remaining member, and delete empty
  groups. Owner deletion writes a one-way identity tombstone in that same batch
  so static MCP cannot recreate the owner or promote another member. The iOS
  client clears only the acknowledged account's local namespace after success;
  a failed request preserves the session and queued writes for retry.
- P1(b) stores Apple's credential identifier from the local Sign in with Apple
  result and checks it on launch/foreground. Revoked, missing, or transferred
  credentials clear only the bearer and explain same-account reauthentication;
  provider-check failures are soft. Existing installs without the scoped local
  identifier begin these checks after their next Apple sign-in rather than
  receiving the sensitive provider identifier through a new backend response.
- Profile-name repair trims and validates a 1–80 UTF-16-unit value, updates only
  the authenticated user, and audits the changed field without copying the name
  into audit arguments.
- Verification at this milestone: the full Workers suite passes 395/395, the
  TypeScript compiler and plan compiler pass, iOS device sources compile, the
  simulator module and XCTest source typecheck, and the standalone production
  AuthModel harness passes Apple revocation/provider-unavailable behavior. This
  host still has no installed iOS simulator runtime, so XCTest execution remains
  unavailable locally.
