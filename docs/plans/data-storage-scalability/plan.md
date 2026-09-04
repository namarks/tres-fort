# Data Storage Scalability

Slug: data-storage-scalability · Status: active · Updated: 2026-09-03 · Theme: platform

## Goal

Keep the single-D1 storage design working, and affordable, when the app has
hundreds of members instead of one. The schema and the two-class consistency
model (versioned plan tree + append-only logs) stay as they are; this
workstream fixes the access patterns that multiply with users times history.

Done means:

- a phone that already holds a member's history downloads only what changed
  since its last sync, including deletions, and the full reload remains a
  tested fallback rather than the default path;
- the hourly intervals.icu backstop writes a row only when the upstream
  activity actually changed, so `synced_at` is a real change cursor and a
  quiet hour costs zero row writes;
- every per-member read on the hot paths (state, profile, exercise history,
  Claude-connection check) is served by an index that starts with the member,
  proven by query plans checked in as a test;
- one member's failing intervals.icu connection cannot stop other members from
  syncing, and members already refreshed by the webhook are not re-polled by
  the cron; and
- the owner has recorded the Workers plan tier and a retention decision for
  the two unbounded growth tables (`audit_log` args and external `raw` JSON),
  with measured per-member cost numbers behind both.

## Phases

- [ ] **P0 — Measure before changing anything**
  - Owner confirms the Cloudflare Workers plan tier (Free or Paid) in the
    dashboard and records it in `decisions.md`. D1 has hard-enforced the Free
    daily caps since 2026-09-01, so on Free this plan is an outage-prevention
    plan and the cheapest immediate mitigation is the paid tier.
  - Log D1 `meta.rows_read` / `rows_written` per request for `GET /api/state`,
    `GET /api/me`, the `get_history` MCP tool, and per cron tick, as one
    structured console line each (Workers observability is already on).
  - Capture the owner account's baseline: rows read per foreground sync, rows
    written per cron tick, and current table row counts. These numbers are
    the before/after evidence for P1–P3 and the inputs to the P5 decision.
- [ ] **P1 — Sync only what changed (sets and sessions)**
  - Migration: add `set_logs.user_id` (backfilled from `sessions.user_id`)
    and `set_logs.updated_at` (backfilled from `COALESCE(deleted_at,
    logged_at)`), with cursor-leading indexes `set_logs(user_id, updated_at)`
    and `sessions(user_id, updated_at)`, so an empty poll reads only the delta
    instead of walking the member's lifetime sessions to find it. Every
    `UPDATE set_logs` path in `db.ts` (`patchSet`, discard, template detach
    on plan rebuild and slot delete) stamps `updated_at` with the server
    clock; `logSet` stamps both columns on insert.
  - Server: `getState` filters sets on `user_id = ? AND updated_at >
    sets_since` (no sessions join on the delta path) and, when
    `sets_since > 0`, includes soft-deleted rows as tombstones, matching the
    external_events contract already documented in that function. The
    `sets_since = 0` full reload keeps its current shape.
  - Cursor rule (write it down in the API doc): the client's next watermark is
    the previous response's `server_time` minus a fixed overlap (60 s); the
    client applies rows idempotently by id, so overlap re-delivery is
    harmless and device-clock skew cannot lose a set.
  - iOS: persist per-account watermarks, send them on every state pull, merge
    deltas and tombstones into the local cache, and keep the existing full
    reload for first sign-in, account change, or an invalid snapshot ticket.
    The post-outbox-drain reconciliation becomes a delta pull that still
    verifies every acknowledged set id came back.
  - Evidence: a state test proves a set soft-deleted after the watermark
    arrives incrementally as a tombstone; the P0 log shows rows read per
    foreground sync for the owner drop from lifetime-history size to the
    delta; the full-reload test still passes.
- [ ] **P2 — Reconcile only what changed (intervals.icu cache)**
  - Change the events and activities upserts to `ON CONFLICT DO UPDATE ...
    WHERE` any stored column differs from the incoming row, or the row is
    currently tombstoned. An unchanged activity produces zero writes and does
    not advance `synced_at`; a changed or resurrected one does. No new column.
  - Now that `synced_at` means "changed", switch the iOS `events_since` and
    `activities_since` cursors to the P1 watermark rule.
  - Evidence: a test runs the same sync twice and asserts the second pass
    reports zero rows written and unchanged `synced_at`; a test with one
    altered field asserts one row written; the P0 cron log shows a quiet hour
    at zero writes.
- [ ] **P3 — Filing-cabinet tabs (member-first indexes)**
  - Migration: `audit_log(user_id, actor, created_at)` so the profile's
    latest-MCP-action lookup seeks directly instead of walking a member's
    audit history when the newest MCP row is old or absent;
    `oauth_tokens(user_id)`; `notes(user_id, created_at)`; replace
    `ix_sets_ex_time` with `set_logs(user_id, exercise_id, logged_at)` (the
    `user_id` column lands in P1, so P3 runs after it) so exercise history
    seeks straight to the member's sets for that exercise instead of scanning
    every member's. Local `EXPLAIN QUERY PLAN` against the applied migrations
    plus these changes confirms each plan flips to the member-first index.
  - Add a small checked-in script that applies `migrations/` to a temporary
    SQLite file and asserts the query plan for each hot query names the
    expected index, so an index regression fails CI instead of showing up as
    latency months later.
- [ ] **P4 — A cron that finishes its route**
  - Per-member isolation: one thrown sync error is logged and the loop
    continues; bounded concurrency (about four members in flight) replaces the
    strict serial walk.
  - Skip rule: add `users.intervals_events_synced_at` and
    `users.intervals_activities_synced_at`, each stamped only by its own
    cache's successful sync (webhook, cron, or manual). The hourly cron polls
    a cache only when that cache's stamp is older than two cron intervals, so
    an activity webhook never marks the planned-events cache fresh and the
    cron's first job never suppresses its second. The webhook is the primary
    path, so a healthy account costs the cron nothing.
  - Rate limits: treat an intervals.icu 429 as `fetch_failed` for that member
    only, honor `Retry-After` when present, and leave the cache untouched.
  - Evidence: tests with an injected fetcher prove member B syncs when member
    A throws, a cache freshly synced by its own webhook is skipped while the
    other cache still polls, and a 429 leaves the cache intact; the P0 cron log shows external calls per tick bounded by the
    number of stale members, not the number of connected members.
- [ ] **P5 — Retention decision for the two unbounded tables**
  - Using P0 numbers, the owner decides retention for `audit_log` (for
    example keep `args` for twelve months, keep the row forever) and for the
    `raw` source JSON on `external_activities` / `external_events` (keep, trim
    to the stored columns, or move to R2). A recorded "keep everything, we are
    on Paid" decision completes this phase with no implementation.
  - If trimming is selected: a scheduled prune that runs inside the existing
    cron, bounded per tick, with a test that proves it never touches rows the
    audit trail contract needs (the `EXISTS (SELECT 1 FROM audit_log WHERE
    id = ?)` invite-redemption check is the known consumer).

## Execution frontier

- P0

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P1 | coordinates_with | plan:activity-integration-integrity#P2 | Both change how tombstones ride `/api/state`; land the cursor rule once and share it. |
| P2 | coordinates_with | plan:activity-integration-integrity#P2 | Both edit the intervals reconcile upsert; do not run concurrently. |
| P5 | gated_by | external:owner-retention-decision | Deleting or trimming audit and source data is an owner data-retention decision, not an inferred cleanup. |

## Next step

**Now (@owner):** Confirm the Workers plan tier in the Cloudflare dashboard, record it in `decisions.md`, and if it is Free decide whether to move to Paid now as the immediate mitigation while P1–P4 land.
**Now (@agent):** Complete P0 instrumentation and capture the owner baseline, then start P1 with the server migration and `getState` before the iOS client.

## Notes / open questions

- Findings behind this plan (2026-09-03, head 65153aa): iOS pulls
  `/api/state` with every cursor at 0 on every load and after every outbox
  drain; the hourly reconcile rewrites every in-window row unconditionally;
  `audit_log` has no index and exercise history uses an exercise-first index
  that scans across members; the cron walks members serially with no per-member
  try/catch and no 429 handling. Everything else in the storage design holds.
- Free-tier caps that matter if the account is still Free: 5M row reads/day,
  100k row writes/day, 50 external subrequests per cron tick, 10 ms CPU per
  request. Back-of-envelope: full-reload sync crosses the read cap at tens of
  active members with history; the hourly rewrite crosses the write cap at
  roughly forty connected intervals members; the subrequest cap lands at
  roughly twenty.
- Storage volume is not a near-term risk on either tier; the growth drivers
  are `audit_log.args` (up to 4 KB per MCP write) and `raw` JSON on external
  rows, which is why P5 is a decision phase rather than a build phase.
- Group stats and series run three sequential queries per member. This is
  fine at friends-and-family size and is deliberately out of scope; revisit
  only if a group exceeds a few dozen members.
- P1 does not add a generic sync framework, event sourcing, or a per-user
  change log. One mutable timestamp plus the existing tombstone pattern is
  enough; add more only if a focused fixture proves it is not.
- This plan does not authorize a production migration, a plan-tier purchase,
  or a TestFlight build. Each is a separate owner action.
