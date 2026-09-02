# Identity and Account Lifecycle

Slug: identity-account-lifecycle · Status: gated · Updated: 2026-09-01 · Theme: training-trust

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
- [x] **P1 — Portability and credential recovery**
  - [x] **(a) Authorized downloadable account export**
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
- [ ] **P2 — Exact-head repair and provider authorization revocation**
  - [x] **(a) Lifecycle integrity and destructive-auth repair**
    - Make exports one transactional D1 snapshot and make invite redemption
      atomic with its membership and audit writes.
    - Require recent authentication for an initial account deletion while
      preserving receipt-backed retries, and clear the correct local account
      after deletion completed on another device.
    - Bind legacy local state before bearer validation, tolerate same-account
      token renewal for in-flight activity/export work, and make bootstrap
      owner claiming compare-and-swap safe.
    - Return only the public user projection from authentication so database
      credentials and passphrase hashes cannot leak in a sign-in response.
    - Give the user a truthful manual Apple-grant revocation handoff whenever
      provider revocation cannot be confirmed.
  - [x] **(b) Programmatic Sign in with Apple token revocation**
    - Transmit and validate Apple's single-use authorization code, retain only
      the caller-scoped refresh token needed for revocation, and revoke it when
      the user deletes the account.
    - Preserve local-data deletion when Apple is unavailable, return a durable
      revocation outcome for receipt retries, and keep the manual handoff as the
      fail-safe for existing accounts without a stored token.
  - [ ] **(c) Owner-provisioned live exchange proof and revocation-risk acceptance**
    - Deploy the combined Worker only under explicit proof/deployment authority,
      then verify a genuine Apple authorization-code exchange non-destructively
      by reauthenticating the owner with owner-managed client-signing credentials
      before any app release or production closeout.
    - Never delete the owner account or revoke its Apple grant to satisfy this
      proof. The owner accepts the residual risk that the first real account
      deletion will be the first live exercise of Apple's revocation endpoint;
      deterministic provider coverage and the manual-revocation handoff remain
      the release evidence for that deletion-time branch.
    - Coordinate the shared Worker/migration release with the completed workout
      write cutover: this branch deploys migrations 0030–0032 together, so a
      narrow identity-only or workout-only authorization is insufficient.

## Execution frontier

- P2(c)

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P2(c) | gated_by | external:apple-sign-in-revocation-credentials | The owner must provision the Apple Team ID, key ID, and private signing key directly through the deployment secret surface. |
| P2(c) | gated_by | external:deployment-authorization | Live provider proof requires separately authorized deployment; merge alone is not production authority. |
| P2(c) | gated_by | external:workout-write-cutover-authorization | The shared release also applies migration 0032 and deploys the workout compatibility Worker; the workout fence cutover must be explicitly authorized in the same coordinated release window. |

## Next step

**Now (@owner):** Provision the Apple Team ID, key ID, and private signing key
directly through the deployment secret surface, then explicitly authorize one
coordinated release window covering the controlled P2(c) live exchange proof,
the combined Worker deployment, and the workout write cutover. On this branch,
`npm run release` applies pending migrations `0030`, `0031`, and `0032` before
deploying their combined Worker; neither a narrow identity authorization nor a
narrow workout authorization permits that command. Within the authorized
window, deploy first and reauthenticate the owner to prove the live Apple
authorization-code exchange against that Worker without calling
`DELETE /api/me` or revoking the owner's Apple grant. If the exchange succeeds,
confirm the workout fence is still disabled; only separately named production
authority may activate it, and TestFlight/App Store distribution remains a
separate gate.
Do not send credentials to an agent, apply any of those migrations, activate the
workout database fence, delete a real account, merge, deploy, or distribute an
app under the completed P2(b) implementation authority or this risk acceptance.

## Notes / open questions

- Source: the August 2026 functionality review at commit `91fd622`; the confirmed
  root issue is the fixed JWT expiry plus an over-broad `AuthModel.invalidate()`.
- P0(a) now uses rolling app-JWT renewal with a preserved authentication time
  and a 180-day absolute session ceiling, plus account-scoped activity,
  intervals.icu, and HealthKit state. Focused backend tests, direct iOS source
  typechecking, and a standalone behavioral harness cover expiry, renewal,
  offline failure, same-user recovery, and account switching. A persisted bearer
  is accepted only when its JWT subject matches the account namespace (older
  installs migrate a missing pointer from that subject), and foreground work is
  pinned to the account that initiated it. Sync, group, and HealthKit models
  also capture that account and never borrow a replacement account's bearer or
  apply a stale 401 to a renewed/switched session. While deletion is pending,
  only AuthModel can retain the bearer for a receipt retry; feature models are
  denied access, and post-await persistence guards prevent an in-flight task
  from recreating cleared outbox, intervals, or HealthKit state. At that P0
  checkpoint the host lacked an installed simulator runtime; the later combined
  exact-head runtime proof is recorded in the current verification note below.
- Runtime account deletion remains destructive and must always require the
  authenticated user's explicit in-app confirmation. Development and CI must
  exercise only seeded users.
- P0(b) uses one transactional D1 batch to revoke the caller's credentials and
  tokens, remove their complete training-data graph and memberships, transfer
  surviving groups to the longest-tenured remaining member, and delete empty
  groups. Owner deletion writes a one-way identity tombstone in that same batch
  so static MCP cannot recreate the owner or promote another member. A durable,
  key-bound deletion receipt makes a lost success response safe to retry, while
  database triggers reject late writes and OAuth grants for a deleted principal.
  Owner bootstrap mutations are conditional on tombstone absence in the same
  SQLite statement. The owner-marked receipt remains durable if an administrator
  removes the identity tombstone, so recovery also requires an explicit
  replacement `OWNER_APPLE_SUB` or deliberately inserted bootstrap sentinel;
  a surviving member is never promoted by fallback. The iOS client clears only
  the initiating account's local namespace after success—even if the user
  switched accounts while waiting—and preserves the session, deletion key, and
  retry-capable bearer after a lost response. A signature-verified expired
  bearer is accepted only for the exact deletion endpoint and only when its
  subject plus the high-entropy key match an already-claimed intent or committed
  receipt; it cannot initiate deletion or access another feature. An authoritative deletion
  401 abandons an unrecognized retry key and transitions to ordinary
  reauthentication. A receipt-mismatch 404 after explicit deletion confirmation
  means another device already deleted the account, so iOS clears only that
  account's scoped local state and signs it out if it is still current.
- P1(b) stores Apple's credential identifier from the local Sign in with Apple
  result and checks it on launch/foreground. Revoked, missing, or transferred
  credentials are handled without crossing account namespaces: revoked or
  missing credentials clear only the bearer and explain same-account
  reauthentication, while a transferred-team identity preserves the current
  bearer because it requires Apple's server-side transfer migration rather than
  an ordinary sign-in that could create an empty account. Provider-check
  failures are soft. Existing installs without the scoped local identifier begin
  these checks after their next Apple sign-in rather than receiving the
  sensitive provider identifier through a new backend response.
- Profile-name repair trims and validates a 1–80 UTF-16-unit value, updates only
  the authenticated user, and audits the changed field without copying the name
  into audit arguments. iOS invalidates in-flight identity projections and
  reloads group summaries, feeds, stats, and activity caches after the update so
  the old effective name cannot survive in another group surface. Hydrated
  create, join, and per-group-name mutation responses carry the same generation
  guard and reconcile from the server if a global-name update overtakes them.
- The portability projection includes only catalog exercises referenced
  by the caller's templates or logged sets, including their names, units,
  modalities, muscles, and aliases, so its exercise identifiers remain
  independently interpretable without exposing unrelated catalog rows.
  Invite capabilities are omitted from new audit rows and stripped from
  historical invite-audit arguments before export.
- P1(a) exposes that projection only at authenticated `GET /api/me/export`; the
  bearer subject is the sole principal, the JSON attachment is non-cacheable,
  and the Profile action saves through the system Files picker without creating
  a public link or app-managed third-party transfer. A response is discarded if
  the app changes accounts while it is downloading, while same-account token
  renewal remains safe; ordinary feature access stays disabled while account
  deletion is pending.
- The exact-head review after the prior closeout found four additional integrity
  faults and two security gaps. P2(a) now makes the export read transactionally,
  closes deletion/invite and bootstrap-claim races, requires a five-minute
  destructive-auth freshness window, repairs cross-device cleanup and legacy
  migration ownership, and prevents same-account renewal from dropping pending
  activity or export work. The post-deletion flow also tells users how to revoke
  the Apple grant manually when the server cannot confirm it. Programmatic Apple
  token exchange/revocation is complete under deterministic injected-provider
  coverage; no Apple private signing material is committed or handled by agents.
- P2(b) reserves each supplied authorization-code exchange against concurrent
  deletion, re-verifies Apple's returned subject, and stores only the caller's
  refresh token. Storage retains the exact reservation until a second
  acknowledgement; even a D1 commit whose result is lost can therefore be
  marked sticky before deletion proceeds. Exchange uncertainty remains sticky
  across later sign-ins: a fresh exchange blocks deletion, while an ambiguous
  or stale exchange forces `manual_required` so deletion cannot claim that only
  an older grant was revoked. `DELETE /api/me` claims its UUID-digest intent
  before provider I/O, blocks app/MCP/OAuth credentials and already-authenticated
  invite redemption, persists the first `revoked` or
  `manual_required` outcome, and copies it into the receipt before transactional
  local deletion. A matching retry skips Apple; a live different-key collision
  returns 409 rather than the deletion-specific
  `{"error":"account_not_found"}` response iOS alone treats as cross-device
  completion; the Worker's generic `{"error":"not_found"}` fallback preserves
  local data and the retry credential. Provider failure never retains local
  data. No live Apple request, owner credential handling, remote/production
  migration application, real-account deletion, merge, or deployment was run.
- On 2026-09-01 the owner waived destructive live deletion/revocation proof
  against a dedicated Apple test account and accepted the residual risk that the
  first real account deletion will be the first live exercise of `/auth/revoke`.
  Release still requires a successful non-destructive authorization-code
  exchange by reauthenticating the owner, plus the deterministic provider tests
  and manual-revocation fallback already implemented. Never delete the owner or
  revoke the owner's Apple grant to satisfy this proof. This decision grants no
  deployment, workout-fence activation, or TestFlight/App Store authority.
- At the initial P2(b) gate, the full Workers suite passed 434/434 and the
  TypeScript, plan, iOS production-source, app-module, and XCTest-source
  compilers passed. The current combined code tree has since passed the full
  Workers/D1 suite (482/482), TypeScript and plan validation, and the complete
  iOS simulator suite (147/147) on an iPhone 17 Pro simulator running iOS
  26.3.1. That runtime proof includes stale renewal, stale Apple-credential
  callback, account-switch-during-deletion, in-flight deletion/outbox cleanup,
  durable owner recovery, lost-response retry/bearer, and
  account-switch-during-export coverage. The non-destructive live Apple exchange
  proof remains gated and was not run; destructive live revocation proof was
  waived under the explicitly accepted residual risk above.
- Delivery review of commit `48e1d05e5fa5915b34e4d58b4bcba42b96cbe942`
  found that successful group reads were still tied to exact bearer equality,
  so an in-flight response could be discarded when the same account renewed its
  app JWT. The follow-up treats successful group and state reads plus exact-id
  activity-outbox finalization as same-account scoped, while retaining exact
  bearer equality for 401 invalidation and mutation/scalar response mirroring.
  Activity-outbox persistence now reloads before each exact-id mutation so an
  older same-user model cannot replace a newer model's queue after
  reauthentication. Six focused session and identity regressions cover
  successful reads, stale-bearer 401 handling, outbox
  finalization, and the two-model queue race; the complete 147-test simulator
  suite passes on the repaired tree.
