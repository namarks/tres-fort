# Private-group safety proposal

The owner approved this product/data policy on 2026-09-10, including the daily
inbox check and 24-hour response commitment, and requested a small implementation.
Approval does not establish production delivery or App Review approval. Live status belongs to
[plan.md](plan.md).

The existing app shares member-authored names, activity titles and notes in
private groups. Apple Guideline 1.2 calls for objectionable-content filtering,
reporting, blocking and reachable support. Leaving a group does not provide
those controls. Preserve private training history and existing group features.

## Approved member behavior

1. **Block a member:** from the member's group profile/settings row, confirm
   that the two accounts will stop seeing one another's shared profiles,
   activity details and contributions to member statistics in every common
   group. Apply the same boundary to REST and MCP. Personal history and other
   group members' access remain unchanged. The block persists across devices;
   the blocker can undo it in Profile. Show a neutral unavailable-member state
   wherever an existing selection becomes blocked. Do not notify the blocked
   person or promise that past views, exports or Claude conversations disappear.
2. **Report content or a member:** open an email draft to `nick@tresfort.app`
   with a concise category and reference identifiers. The member reviews and
   sends the message in their mail app; nothing is sent automatically. Do not
   automatically attach workout/health content, tokens or invite codes. Also
   offer blocking immediately. If mail is unavailable, show the support address
   and a copyable report reference.
3. **Filter shared text:** apply a maintained, conservative English
   objectionable-term filter to group-facing display names, group names,
   activity titles and notes. Apply it consistently to REST, MCP, invite pages
   and UI; imported/private originals remain unchanged. Preserve legitimate
   exercise names. Make filtered text neutral, not a disclosure of the original.
   Automated filtering is limited; reports provide human review for context
   and evasion rather than claiming the list detects every abusive phrase.
4. **Operator response:** check the support inbox at least daily and address
   actionable abuse reports within 24 hours. The operator can restrict an
   offending account from group sharing, with an audit trail and a reversible
   reason/status. Restriction affects group sharing, not the account's private
   workout records. Support correspondence follows the published support/privacy
   policy; do not create an additional report-content database in this slice.

## Data and implementation boundary

Store the blocker's ID, blocked account ID, creation timestamp and active state;
validate two distinct accounts sharing a group before creating a block. The
block's owner can revoke it. Account deletion removes associated blocks. Store
operator group-sharing restrictions separately from training rows, with
authorized operator-only writes, reason/status and audited updates. Existing
member, account-deletion, pagination and tenant-isolation tests must cover both
REST and MCP paths, including caches and reconnects.

This proposal adds no chat, public discovery, paid service or AI moderation.
Migration/deployment remains a later exact-source owner gate. The owner accepted the 24-hour response commitment. Use the existing Worker,
email and Profile screens; do not add a moderation service or report database.

Reference: [Apple Guideline 1.2](https://developer.apple.com/app-store/review/guidelines/#user-generated-content),
checked 2026-09-10.

## Implementation contract

Migration `0048` adds two small tables: directed member blocks (applied mutually
on reads) and reversible sharing restrictions. A single caller-aware member
query feeds rosters, REST/MCP feeds, statistics and activity series before
pagination. Filtering applies to shared projections, including invite names;
private source records and catalog exercise names stay intact. Restrictions
mask creator-authored group names and exclude the account from others' shared
projections. The affected person can still read their private training and own
activity.

Authenticated members manage their own blocks. Operator writes require the
explicitly configured `OWNER_APPLE_SUB`, never the oldest account or a group
creator. Profile's Group safety screen accepts the member ID from a report and
a bounded reason category; restriction and audit commit in one transaction.
No additional credentials, admin website or report-content storage is needed.
Account deletion cascades through blocks and restrictions. Exports include the
caller's own blocks and restriction, not the identities of incoming blockers.

iOS drops shared projections and rejects older in-flight responses when safety
settings change, on foreground reload and on group refresh. Opening the Group
tab within one foreground session is the exception: it keeps the projections
already on screen until fresh responses replace them, pruning groups the fresh
list omits and still rejecting older in-flight responses. Existing selections
show unavailable content once removed. No promise covers previously viewed,
exported or copied content. Production needs the additive migration before the
new Worker, then the compatible app. A Worker rollback that lacks these controls
would undo enforcement and is not an acceptable rollback after activation.
