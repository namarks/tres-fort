# Data Storage Scalability

Slug: data-storage-scalability · Status: active · Updated: 2026-09-05 · Theme: platform

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
- an unexpected exception while syncing one member (a plain fetch failure
  already returns a value and the loop continues) cannot stop other members
  from syncing, and a cache already refreshed by the webhook is not re-polled
  by the cron; and
- the owner has recorded the Workers plan tier and a retention decision for
  the two unbounded growth tables (`audit_log` args and external `raw` JSON),
  with measured per-member cost numbers behind both.

## Phases

- [ ] **P0 — Measure before changing anything**
  - Owner confirms the Cloudflare Workers plan tier (Free or Paid) in the
    dashboard and records it in `decisions.md`. Done 2026-09-04: Free, with
    the dashboard's 24-hour row totals recorded as the daily baseline. D1 has hard-enforced the Free
    daily caps since 2026-09-01 (Cloudflare changelog,
    <https://developers.cloudflare.com/changelog/post/2026-09-01-d1-free-tier-limit-enforcement/>),
    so on Free this plan is an outage-prevention plan and the cheapest
    immediate mitigation is the paid tier. The measured natural cron also used
    32 ms CPU against Free's nominal 10 ms limit; its successful outcome
    reflects Cloudflare's documented flexibility for infrequent overages, not
    safe recurring headroom. On 2026-09-05 the owner chose to mitigate on Free;
    P0.5 records that independently executable slice.
  - Log D1 `meta.rows_read` / `rows_written` per request for `GET /api/state`,
    `GET /api/me`, the `get_history` MCP tool, and per cron tick, as one
    structured console line each (Workers observability is already on).
    `.first()` returns no `meta`, so the reads on these paths move to
    `.all()` / `.run()` or a read batch before the numbers are capturable.
    Implemented, reviewed, merged, and deployed without migrations on
    2026-09-04. The natural hourly cron baseline and a privacy-safe production
    table-census summary are recorded in `decisions.md`; representative
    authenticated owner REST and MCP traffic is the remaining per-path
    baseline.
  - Capture the owner account's baseline: rows read per foreground sync, rows
    written per cron tick, current table row counts, and the rows-written
    delta each proposed index adds on the highest-write tables (`set_logs`,
    `audit_log`), since D1 bills every index update as a row written. These
    numbers are the before/after evidence for P1–P3, the check that P3's
    index cost stays below P2's savings, and the inputs to the P5 decision.
    Local shadow-table evidence now measures the proposed final index delta:
    +1 row written per set insert/correction/soft-delete, +1 per audit insert,
    and +2 for a combined MCP set mutation plus its audit row. Production table
    census and the natural cron total are captured, with exact personal and
    auth-state counts intentionally omitted from the public repository; the
    three authenticated owner-path totals remain outstanding.
- [ ] **P0.5 — Fit the natural cron inside the Free CPU limit**
  - Owner decision 2026-09-05: **Mitigate on Free**. Keep the single hourly
    webhook-backstop trigger and optimize the activity reconcile; this authorizes
    local implementation and review of this slice, not a plan purchase,
    production deployment, migration, or manual production cron trigger.
  - Bound post-intervals HealthKit candidates to the completed-activity sync
    window plus one civil day on either side for two-minute cross-midnight
    matches. Look up intervals winners one additional civil day beyond that so
    a boundary duplicate is not restored while its adjacent-day winner is still
    live. Use the existing `external_activities(user_id, date)` index and a
    kind/time-ordered nearest-match lookup instead of the lifetime
    HealthKit-by-intervals nested scan. Enforce the existing official-client
    invariant that a non-null local-wall-clock timestamp encodes the same civil
    date before a HealthKit write reaches D1. Do not add an index or change the
    fetch window, webhook-primary behavior, cache ownership, or P2/P4 contracts.
  - Preserve exact matching behavior: same user and kind, live intervals rows,
    live or dedup-retired HealthKit rows, non-null local timestamps, inclusive
    two-minute tolerance, deterministic nearest winner, and restoration when
    the intervals winner disappears. HealthKit rows deleted for another reason
    remain untouched.
  - Evidence: focused tests cover retirement, restoration, source and kind
    isolation, inclusive tolerance, deterministic ties, window boundaries, and
    both midnight edges; a real-D1 fixture and query plan prove old history no
    longer contributes billed reads or matching work on the bounded cron path.
    After a separately authorized exact-source deployment, at least three
    natural hourly ticks must remain successful and below the Free 10 ms CPU
    limit before this phase is complete.
- [ ] **P1 — Sync only what changed (sets and sessions)**
  - Migration: add `set_logs.user_id` (NOT NULL, backfilled from
    `sessions.user_id`, with a parity assertion that every row matches its
    session's owner) and `set_logs.updated_at` (backfilled from
    `COALESCE(deleted_at, logged_at)`), with cursor-leading indexes
    `set_logs(user_id, updated_at)` and `sessions(user_id, updated_at)`, so
    an empty poll reads only the delta instead of walking the member's
    lifetime sessions to find it. Because releases apply migrations before
    code, migration `0034` stays additive and compatible with the old Worker:
    placeholder defaults plus a narrowly conditioned legacy-insert trigger
    fill the fields until the new Worker is active, while preserving the
    `set_logs` write-fence triggers installed by migration `0032`; do not
    rebuild the table. Because the production write fence is active, the
    migration acquires the existing singleton `workout_write_permit`
    immediately around its set-log backfill and removes it before completing;
    migration tests prove the permit cannot leak and the fence still rejects
    an unpermitted update afterward. `logSet`, the single insert path, stamps
    both columns; `patchSet` and discard stamp `updated_at` with the server
    clock. Plan rebuild remaps that change `sessions.day_template_id` also
    stamp the session cursor. Template-exercise remaps and detach-on-delete
    stamp affected set logs too: iOS completion is slot-aware, so the new or
    null slot id must arrive in the delta even though a plan edit may redeliver
    historical sets for that slot.
  - Server: `getState` filters sets on `user_id = ? AND updated_at >
    sets_since` (no sessions join on the delta path) and, when
    `sets_since > 0`, includes soft-deleted rows as tombstones, matching the
    external_events contract already documented in that function. The
    `sets_since = 0` full reload keeps its current shape.
  - Cursor rule (write it down in the API doc): the client's next watermark is
    the previous response's `server_time` minus a fixed overlap (60 s); the
    client applies rows idempotently by id, so overlap re-delivery is
    harmless and device-clock skew cannot lose a set.
  - iOS: persist per-account watermarks for every `/api/state` cursor,
    including `log_since` for the manual activity log (the app does not send
    it at all today), send them on every state pull, merge deltas and
    tombstones into the local cache, and keep the existing full
    reload for first sign-in, account change, or an invalid snapshot ticket.
    The post-outbox-drain reconciliation becomes a delta pull that still
    verifies every acknowledged set id came back.
  - Evidence: a state test proves a set soft-deleted after the watermark
    arrives incrementally as a tombstone; remapped and detached slot ids also
    arrive after the watermark; a migration test starts with the active write
    fence, proves the backfill completes with no permit left behind, and proves
    an unpermitted update still fails afterward; the P0 log shows rows read per
    foreground sync for the owner drop from lifetime-history size to the
    delta; the full-reload test still passes.
- [ ] **P2 — Reconcile only what changed (intervals.icu cache)**
  - Change the events and activities upserts to `ON CONFLICT DO UPDATE ...
    WHERE` any extracted column differs from the incoming row, or the row is
    currently tombstoned. `raw`, the whole upstream JSON with derived fields
    and no guaranteed key order, is excluded from the comparison and only
    rewritten when an extracted column changed. An unchanged activity
    produces zero writes and does not advance `synced_at`; a changed or
    resurrected one does. No new column.
  - Now that `synced_at` means "changed", switch the iOS `events_since` and
    `activities_since` cursors to the P1 watermark rule.
  - Evidence: a test runs the same sync twice and asserts the second pass
    reports zero rows written and unchanged `synced_at`; a test with one
    altered field asserts one row written; a test replays two real captured
    intervals.icu responses for the same window, not a static fixture, and
    asserts zero writes when only `raw` drifted; the P0 cron log shows a
    quiet hour at zero writes.
- [ ] **P3 — Filing-cabinet tabs (member-first indexes)**
  - Migration: `audit_log(user_id, actor, created_at)` so the profile's
    latest-MCP-action lookup seeks directly instead of walking a member's
    audit history when the newest MCP row is old or absent;
    `oauth_tokens(user_id)`; replace `ix_sets_ex_time` with
    `set_logs(user_id, exercise_id, logged_at)` (the `user_id` column lands
    in P1, so P3 runs after it) so exercise history seeks straight to the
    member's sets for that exercise instead of scanning every member's.
    `notes` gets no index: its only read is the account export.
  - `getHistory`, and any other exercise-scoped read, switches its member
    predicate from `s.user_id` to `sl.user_id` in the same change. Without
    that rewrite the planner ignores the new index and falls back to
    `ux_set_slot` (verified locally); with it, `EXPLAIN QUERY PLAN` against
    the applied migrations plus these changes flips every hot query to the
    member-first index.
  - Cost check: `set_logs` nets one more index (two added, one dropped) and
    `audit_log` gains one, each billed as a row written on every insert. P3
    ships only after the P0 delta shows that cost is below P2's savings. The
    unbounded `UPDATE set_logs ... WHERE template_exercise_id = ?` on plan
    rebuild is a full scan today; index it only if P0 shows plan edits are a
    measurable read cost.
  - Add a small checked-in script that applies `migrations/` to a temporary
    SQLite file and asserts the query plan for each hot query names the
    expected index, so an index regression fails CI instead of showing up as
    latency months later.
- [ ] **P4 — A cron that finishes its route**
  - Per-member isolation: a fetch failure already returns a value and the
    loop continues; the gap is an unexpected exception (for example a D1
    error), which today aborts every member after it. Catch and log per
    member; bounded concurrency (about four members in flight) replaces the
    strict serial walk.
  - Skip rule: add `users.intervals_events_synced_at` and
    `users.intervals_activities_synced_at`, each stamped only by its own
    cache's successful sync (webhook, cron, or manual). The hourly cron polls
    a cache only when that cache's stamp is older than two cron intervals, so
    an activity webhook never marks the planned-events cache fresh and the
    cron's first job never suppresses its second. The webhook is the primary
    path, so a healthy account costs the cron nothing.
  - Rate limits: a 429 already surfaces as `fetch_failed` and leaves the
    cache untouched. New: honor `Retry-After` when present and skip that
    member for the rest of the tick instead of retrying the second cache.
  - Evidence: tests with an injected fetcher prove member B syncs when member
    A's sync throws (not merely fails), a cache freshly synced by its own
    webhook is skipped while the other cache still polls, and a 429 with
    `Retry-After` skips the member's second cache without touching either; the P0 cron log shows external calls per tick bounded by the
    number of stale members, not the number of connected members.
- [ ] **P5 — Retention decision for the two unbounded tables**
  - Using P0 numbers, the owner decides retention for `audit_log` (for
    example keep `args` for twelve months, keep the row forever) and for the
    `raw` source JSON on `external_activities` / `external_events` (keep, trim
    to the stored columns, or move to R2). A recorded "keep everything, we are
    on Paid" decision completes this phase with no implementation.
  - If trimming is selected: a scheduled prune that runs inside the existing
    cron, bounded per tick, with a test that proves it never touches rows the
    audit trail contract needs. Known consumers: the invite-redemption
    `EXISTS (SELECT 1 FROM audit_log WHERE id = ?)` check, and
    `userHasTouchedIntervalsCreds`, which reads the `set_intervals_creds`
    audit row to tell an intentional disconnect from a never-configured
    account; pruning that row would silently re-enable the env credential
    fallback for a member who deliberately disconnected.

## Execution frontier

- P0
- P0.5

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P0.5 | coordinates_with | plan:activity-integration-integrity#P2 | Both exercise activity correction/deletion convergence and the existing intervals-to-HealthKit dedup regression boundary; preserve its semantics and do not edit the same reconcile path concurrently. |
| P1 | coordinates_with | plan:activity-integration-integrity#P2 | Both change how tombstones ride `/api/state`; land the cursor rule once and share it. |
| P2 | coordinates_with | plan:activity-integration-integrity#P2 | Both edit the intervals reconcile upsert; do not run concurrently. |
| P5 | gated_by | external:owner-retention-decision | Deleting or trimming audit and source data is an owner data-retention decision, not an inferred cleanup. |

## Next step

**Now (@owner):** Foreground the production iOS app and open Profile once, then use the OAuth-connected Claude coach to request bench history once; these two actions complete the three outstanding authenticated P0 traffic samples.
**Now (@agent):** Implement and review P0.5 locally while recording those P0 samples when they arrive. Stop before any production deployment, migration, manual production cron trigger, plan purchase, or TestFlight build.

## Notes / open questions

- Findings behind this plan (2026-09-03, head 65153aa; every claim
  re-verified against main at 3da1c5c during review): iOS pulls
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
  roughly twenty. These estimates ignore index write amplification, which
  is why P0 measures the per-index delta before P3 ships.
- Storage volume is not a near-term risk on either tier; the growth drivers
  are `audit_log.args` (the first 4,000 JavaScript UTF-16 code units of
  serialized arguments per MCP write) and `raw` JSON on external rows, which
  is why P5 is a decision phase rather than a build phase.
- Group stats and series run three sequential queries per member. This is
  fine at friends-and-family size and is deliberately out of scope; revisit
  only if a group exceeds a few dozen members.
- P1 does not add a generic sync framework, event sourcing, or a per-user
  change log. One mutable timestamp plus the existing tombstone pattern is
  enough; add more only if a focused fixture proves it is not.
- P1 rollout is server-first: migration plus Worker can precede iOS because
  released clients still send zero cursors. After incremental iOS cursors
  ship, the pre-P1 Worker is no longer a safe rollback target because it reads
  nonzero `sets_since` against immutable `logged_at` and can omit later
  tombstones; retain a P1-aware rollback version or forward-fix instead.
- Production still has unrelated migration
  `0033_gymnastic_strength_catalog.sql` pending. The next repository release
  would apply it before P1's `0034`; neither migration is authorized by this
  plan writeback. P0.5 is intentionally migration-free; a future separately
  authorized release of it must use deploy-only delivery rather than
  `npm run release`, so it does not implicitly apply `0033`.
- This plan does not authorize a production deployment, production migration,
  manual production cron trigger, plan-tier purchase, or TestFlight build.
  Each is a separate owner action.
