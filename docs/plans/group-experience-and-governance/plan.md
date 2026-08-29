# Group Experience and Governance

Slug: group-experience-and-governance · Status: planned · Updated: 2026-08-29 · Theme: connected-training

## Goal

Make a small private training group trustworthy and useful: members can join
reliably, understand the activity feed, offer lightweight encouragement, and
correct membership or invite mistakes without turning Tres Fort into a social
network.

Done means:

- the feed is complete, correctly ordered, paginated without gaps or repeats,
  and clear about when a backdated workout occurred;
- each member can always see their own HealthKit activity while their sharing
  preference continues to govern what other members see;
- an invite survives link handoff and sign-in, has understandable
  active/expired/revoked states, and can be intentionally reused until expiry
  or revocation;
- members can use a small reaction set and receive a bounded, mutable set of
  group notifications; and
- owners can rename or delete a group, revoke invites, and remove a member,
  while any member can leave, with tenant boundaries covered by tests.

## Phases

- [ ] **P0 — Feed truth and usable history**
  - Order and page the feed with one stable composite cursor so equal
    timestamps, backfilled activities, and the next page produce no gaps or
    duplicates.
  - Display the workout's performed date and clearly label later-imported or
    backdated items rather than presenting import time as workout time.
  - Keep the viewing member's own HealthKit activities visible to them when
    group sharing is off, while continuing to hide those rows from other
    members.
  - Cover strength sessions, intervals.icu activities, HealthKit activities,
    soft deletion, and pagination in the existing group contracts.
- [ ] **P1 — Invites that survive the real join path**
  - In an installed app, preserve the invite through Universal Link handling,
    Apple sign-in, preview, confirmation, and idempotent join.
  - When the app is absent, keep the web page's clear install/reopen or manual
    code path; do not build deferred-deep-link infrastructure for this slice.
  - Let a group owner mint an expiring link that remains usable until explicitly
    revoked or expired; retain clear outcomes for invalid, revoked, expired,
    already-joined, and wrong-group cases.
  - Keep one owner/member model. Do not introduce organization roles or a
    general access-control builder.
- [ ] **P2 — Lightweight encouragement**
  - Add a fixed, small reaction set to completed workout and activity feed
    items, with one current reaction per member and safe retry behavior.
  - Notify only for new completed workouts and reactions, with an in-app mute;
    batch or suppress self-generated and duplicate notifications.
  - Exclude comments, direct messages, public profiles, follows, rankings, and
    algorithmic feed work.
- [ ] **P3 — Essential group controls**
  - Let the owner rename the group, revoke outstanding invites, remove a member,
    and delete the group; let any member leave.
  - Define and show the simple data outcome before group deletion or member
    removal. Personal workout history remains owned by the user and is not
    deleted with group membership.
  - Prove owner-only operations, member isolation, repeat requests, and the
    last-owner case without adding multi-admin workflows.

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P0 | coordinates_with | plan:activity-integration-integrity#P0 | Feed pagination, labels, and own-activity visibility can land independently; jointly verify the final cross-source feed result against its identity and civil-date rules. |

## Next step

**Now (@owner):** None — keep this plan `planned`; when activated, implement P0
before adding engagement features.

## Notes / open questions

- The intended product is a private training circle, not a generalized social
  graph. New roles, moderation systems, discovery, public content, and chat
  require separate evidence and promotion.
- Reuse the tenant and authorization fixes completed in
  [Server Mutation Integrity](../completed/server-mutation-integrity/plan.md);
  they are historical foundation rather than an unresolved dependency.
- Reuse the account-deletion ownership outcome completed in
  [Identity and Account Lifecycle](../completed/identity-account-lifecycle/plan.md):
  personal training data and membership are removed with the account, surviving
  groups transfer to their longest-tenured member, and empty groups are deleted.
- Notification implementation still follows the repository's ordinary
  credential and release gates; this plan does not grant permission to create
  production APNs credentials or send production notifications.
