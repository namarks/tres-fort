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
    safe recurring headroom. On 2026-09-05 the owner first chose to mitigate on
    Free, then upgraded the account to Workers Paid after the optimized natural
    tick still measured 18 ms. The dashboard now identifies Paid as the current
    plan; `decisions.md` records both steps and the exact evidence.
  - Log D1 `meta.rows_read` / `rows_written` per request for `GET /api/state`,
    `GET /api/me`, the `get_history` MCP tool, and per cron tick, as one
    structured console line each (Workers observability is already on).
    `.first()` returns no `meta`, so the reads on these paths move to
    `.all()` / `.run()` or a read batch before the numbers are capturable.
    Implemented, reviewed, merged, and deployed without migrations on
    2026-09-04. The natural hourly cron baseline and a privacy-safe production
    table-census summary are recorded in `decisions.md`. The representative
    authenticated owner REST and MCP paths were not sampled before P1 shipped,
    so that historical per-path baseline cannot now be recreated without an
    unsafe rollback. Capture classified post-release full-reload and incremental
    sync samples plus `/api/me` and `get_history`; the owner must accept that
    replacement evidence before P0 closes.
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
- [x] **P0.5 — Resolve the natural-cron CPU capacity gate**
  - Initial owner decision 2026-09-05: **Mitigate on Free**. Keep the single
    hourly webhook-backstop trigger and optimize the activity reconcile without
    changing its fetch window, trigger, or storage contract.
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
    Done 2026-09-05: implementation, full-suite verification, Wrangler dry-run,
    independent exact-head review, merge, and an exact-source deploy-only release
    passed; no migration or trigger change was part of the release. The first
    natural hourly tick on that source completed successfully with 18 ms CPU,
    4,519 ms wall time, 53 D1 queries, 291 rows read, and 64 rows written. The
    validation stopped because 18 ms missed the Free target instead of treating
    a successful outcome as headroom. The owner then upgraded to Workers Paid,
    whose hourly-cron CPU allowance resolves this capacity gate while retaining
    the measured optimization.
- [ ] **P1 — Sync only what changed (sets, sessions, and manual activities)**
  - Migration: add `set_logs.user_id` (NOT NULL, backfilled from
    `sessions.user_id`, with a parity assertion that every row matches its
    session's owner) and server-owned `set_logs.updated_at`. Backfill the mutable
    cursor from D1's clock rather than client-authored `logged_at` or
    `deleted_at`. Add the same server-owned cursor to the manual `activities`
    log. Cursor-leading indexes on `set_logs(user_id, updated_at)`,
    `sessions(user_id, updated_at)`, and `activities(user_id, updated_at)` make
    empty polls seek the member's delta rather than walk lifetime history.
    Because releases apply migrations before code, migration `0034` stays
    additive and compatible with the old Worker: placeholder defaults plus
    narrowly conditioned insert/update/delete compatibility triggers populate
    or advance cursors only for the legacy statement shapes. The narrow triggers
    remain safe after rollout because new writes supply or advance the cursor and
    bypass their conditions. Preserve the `set_logs` write fence installed by
    migration `0032`; acquire its singleton `workout_write_permit` only around
    the protected backfill and remove it before the migration completes. Tests
    prove the permit cannot leak and the fence still rejects an unpermitted
    update afterward.
  - Writers: `logSet` stamps ownership and cursor atomically; set correction,
    discard, plan-slot remap, slot deletion, and day deletion advance
    `set_logs.updated_at` monotonically, even for same-millisecond changes. Every
    visible session mutation advances `sessions.updated_at`. Manual activity
    insert and soft-delete advance `activities.updated_at` monotonically.
    Replacement plan creation, and ensure-active only when it must recreate a
    plan after archived history, allocate a version greater than every prior
    plan for that user. Returning an existing active plan leaves it unchanged;
    replacing or recreating one never moves the plan cursor backward or repeats
    it.
  - Server: `getState` filters sets on `user_id = ? AND updated_at >
    sets_since` (no sessions join on the delta path) and, when
    `sets_since > 0`, includes soft-deleted rows as tombstones, matching the
    manual-activity contract. The `sets_since = 0` and `log_since = 0` paths
    remain complete reloads. Capture `server_time` at request start, before the
    collection reads, so a write that commits after its collection was read
    necessarily falls beyond the response watermark and cannot be skipped.
  - Cursor rule (also documented in the API contract): the client's next active
    watermark is the response's request-start `server_time` minus a fixed 60 s
    overlap. Rows merge idempotently by id, so overlap redelivery is harmless
    and device clock skew cannot lose a mutation. P1 activates only plan,
    set/session, and manual-activity cursors; `events_since` and
    `activities_since` remain zero until P2 makes their cache timestamps true
    change cursors.
  - iOS: persist every `/api/state` watermark per account and send all cursor
    parameters on every pull. Atomically merge deltas and tombstones with the
    account-scoped request ticket, retain raw set tombstones long enough to
    order them against delayed outbox acknowledgements, and keep a complete
    reload for first sign-in, account change, legacy/incomparable cached rows,
    or a missing, invalidated, or undecodable snapshot. A superseded request
    ticket is discarded rather than forcing a reload. Post-outbox reconciliation
    uses a delta pull. An old deduped UUID may be absent only when the pre-POST
    snapshot already contains an equal or newer server row. If a genuinely new
    or newer acknowledged row is absent, retain the authoritative ACK, retire
    the durable intent, report the mutation as successful, clear cursors for a
    full reload, and surface sync uncertainty separately. Session/set ACKs are
    ordered by attempt/status and then strict server timestamp so a stale
    response cannot overwrite a newer snapshot. Manual activities treat an
    absent/null legacy collection as non-capable (`log_since` stays zero), a
    valid non-null collection as the capability signal, and malformed present
    data as a response failure that cannot advance the cursor.
  - Evidence: a state test proves a set soft-deleted after the watermark
    arrives incrementally as a tombstone; remapped and detached slot ids also
    arrive after the watermark; a migration test starts with the active write
    fence, proves the backfill completes with no permit left behind, and proves
    an unpermitted update still fails afterward; request-interleaving,
    backdated/future event time, same-millisecond, legacy-write, and 1,005-row
    regressions preserve every delta; replacement plan versions stay monotonic;
    and full-reload plus outbox-recovery tests still pass. Query plans use the
    member-first cursor indexes, empty delta seeks read at most two billed rows,
    and each added set/activity cursor index costs one extra billed row per
    indexed mutation. iOS regressions also prove that an incomplete
    post-acknowledgement delta cannot turn a committed write into apparent
    failure or lose a manual-activity cursor. Done locally 2026-09-05: the
    backend suite passed 43 files / 548 tests, TypeScript passed, and the iOS
    simulator suite passed 267 tests. Repository delivery completed the same
    day: PR #124's exact reviewed head `cf6cb83` passed required CI, its
    squash-merge commit `647a9f6` has the identical tree, and post-merge main
    CI passed. Production delivery completed 2026-09-05 from exact merged
    source `079f035`: migrations `0033`, `0034`, and `0035` applied in order,
    Worker version `1cc13fec-3eab-4f95-a0fb-e9d6a1303f52` received 100% of
    traffic with schema/fence/health checks green, and exact-source TestFlight
    build `0.1.0 (31)` reached Apple's terminal `VALID` state. The historical
    pre-P1 authenticated per-path sample was not retained and cannot be
    recreated safely after incremental iOS shipped. Classified post-release
    full-reload/incremental samples and owner acceptance of that replacement
    evidence remain outstanding.
- [ ] **P2 — Reconcile only what changed (intervals.icu cache)**
  - Change the events and activities upserts to `ON CONFLICT DO UPDATE ...
    WHERE` any extracted column differs from the incoming row, or the row is
    currently tombstoned. `raw`, the whole upstream JSON with derived fields
    and no guaranteed key order, is excluded from the comparison and only
    rewritten when an extracted column changed. An unchanged activity
    produces zero writes and does not advance `synced_at`; a changed or
    resurrected one does. No new column.
  - Treat each successful provider response as one atomic cache input. Rows
    that are intentionally outside the cache contract remain filtered, but a
    missing or malformed category discriminator, malformed relevant id or local
    timestamp, or any non-record array member, fails the complete response
    before D1 mutation. The prior cache remains byte-for-byte unchanged instead
    of partially updating valid rows and then tombstoning entries omitted by
    the parser.
  - Reconcile provider membership with one JSON-bound id set expanded by
    SQLite `json_each`, not one placeholder per fetched row. This keeps the
    tombstone statement at five bound parameters and below D1's 100-parameter
    ceiling even when an ordinary provider window contains hundreds of rows.
  - Because `activities_since` spans every source in `external_activities`, an
    identical HealthKit UUID retry must also be a true no-op. Preserve a
    dedup-retired HealthKit row's tombstone and provenance on an unchanged
    retry; a real extracted-field change may refresh it before the existing
    dedup pass restores the correct canonical state. Raw-only drift is not a
    change on this path either.
  - Migration `0035` adds `external_events(user_id, synced_at)` and
    `external_activities(user_id, synced_at)` so an empty incremental poll
    seeks into the member's cursor range instead of scanning that member's
    date cache. Each index costs one additional billed row write on a real
    mutation; that cost must remain below the quiet-hour writes eliminated by
    change-aware reconcile.
  - Now that `synced_at` means "changed", switch the iOS `events_since` and
    `activities_since` cursors to the P1 watermark rule. P2 Workers advertise
    the response-only capability `external_sync_cursors_version: 2`; the app
    activates both cursors only at version 2 or later and keeps them at zero
    when the capability is absent or lower, preserving mixed-version and
    rollback safety without a database migration.
  - Evidence: a test runs the same sync twice and asserts the second pass
    reports zero rows written and unchanged `synced_at`; a test with one
    altered field asserts one logical row mutation and the expected billed
    write amplification for the base row plus its two indexes; a test replays
    two real captured intervals.icu responses for the same window, not a
    static fixture, and asserts zero writes when only `raw` drifted;
    same-source and dedup-retired HealthKit retries are no-ops; dedup retire,
    repoint, and restore transitions advance `synced_at` strictly even at the
    same clock millisecond; query-plan and billed-read tests prove both empty
    external deltas seek through their member-first cursor indexes; malformed
    mixed responses leave the existing cache unchanged; 120-row windows
    reconcile without crossing tenant or source scope; the membership
    subquery is materialized once rather than correlated per cache row; and
    the P0 cron log shows a quiet hour at zero writes.
  - Local pre-delivery evidence on 2026-09-05: 106 focused cache tests and the
    full backend suite (44 files / 600 tests) passed, TypeScript passed, and the
    full iOS simulator suite passed 273 tests. Synthetic paired responses prove
    the raw-only-drift behavior for both provider endpoints without claiming to
    be production captures. Exact source `fa4f13b` was held before any
    production mutation when the lockfile audit found the public OAuth routes
    reached Hono's pre-4.12.34 default-CORS ReDoS. The focused 4.12.34 repair,
    attack-shaped coverage, production audit, full backend suite, TypeScript,
    Wrangler dry-run, planning validation, independent exact-head review, and
    repository delivery then passed on merged source `079f035`.
    Production migrations `0033`-`0035` and the exact Worker were released on
    2026-09-05. The first natural quiet tick on the new Worker completed with
    53 D1 queries, 325 rows read, **zero rows written**, 26 ms CPU, 4,392 ms
    wall time, and no exception. Exact-source TestFlight build `0.1.0 (31)` is
    terminal `VALID`. Only the separately authorized sanitized real-response
    replay remains outstanding for P2.
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
- P1
- P2

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P0.5 | coordinates_with | plan:activity-integration-integrity#P2 | Both exercise activity correction/deletion convergence and the existing intervals-to-HealthKit dedup regression boundary; preserve its semantics and do not edit the same reconcile path concurrently. |
| P1 | coordinates_with | plan:activity-integration-integrity#P2 | Both change how tombstones ride `/api/state`; land the cursor rule once and share it. |
| P2 | coordinates_with | plan:activity-integration-integrity#P2 | Both edit the intervals reconcile upsert; do not run concurrently. |
| P5 | gated_by | external:owner-retention-decision | Deleting or trimming audit and source data is an owner data-retention decision, not an inferred cleanup. |

## Next step

**Now (@agent):** Release delivery is complete from exact merged source
`079f035`: migrations `0033`-`0035`, Worker version
`1cc13fec-3eab-4f95-a0fb-e9d6a1303f52`, the natural zero-write tick, and
terminal-valid TestFlight build `0.1.0 (31)` all have retained provenance.
Capture the authorized sanitized real-provider replay without retrieving or
copying provider credentials, and capture one representative post-release
authenticated sample each for full-reload and incremental `/api/state`, Profile
`/api/me`, and OAuth coach `get_history`. The pre-release authenticated
per-path baseline was not retained and cannot be recreated safely; ask the
owner whether these post-release samples are accepted as its replacement.
These owner-device/connected-account interactions and that evidence decision
are the remaining P0-P2 gate. Do not manually trigger production cron, change
the plan tier, or infer P3/P5 product decisions from scheduler order.

**Owner input, only when requested:** If the agent cannot exercise the physical
production app, foreground build 31 for a classified state sync, open Profile
once, then use the OAuth-connected Claude coach to request bench history once.
Confirm whether the classified post-release full-reload/incremental evidence is
an acceptable replacement for the historical pre-P1 per-path sample that was
not retained. These actions and decision complete the outstanding authenticated
P0/P1 evidence but do not affect the completed production release.

## Notes / open questions

- Findings behind this plan (2026-09-03, head 65153aa; every claim
  re-verified against main at 3da1c5c during review): iOS pulls
  `/api/state` with every cursor at 0 on every load and after every outbox
  drain; the hourly reconcile rewrites every in-window row unconditionally;
  `audit_log` has no index and exercise history uses an exercise-first index
  that scans across members; the cron walks members serially with no per-member
  try/catch and no 429 handling. Everything else in the storage design holds.
- Historical Free-tier caps that motivated the work: 5M row reads/day,
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
- Production historically had unrelated migration
  `0033_gymnastic_strength_catalog.sql` pending after the P0.5 deploy-only
  release. The owner authorized the combined release on 2026-09-05; `0033`
  applied before P1's `0034`, then P2's `0035`, followed immediately by the
  freshly reviewed merged Worker. The ledger now has no pending migration.
- Apply `0034` only with the P1 Worker ready to deploy immediately. If Worker
  deployment fails after the migration commits, roll forward with the P1-aware
  Worker rather than attempting a migration rollback. For the entire gap, the
  retained legacy set-update trigger can make old-Worker discard audit field
  `sets_discarded` overcount changed rows because D1 includes trigger writes in
  `meta.changes`. Cursor and data semantics remain correct; the new Worker
  counts authoritative `RETURNING` rows instead. This bounded rolling-release
  limitation is accepted and does not justify disabling the compatibility
  trigger.
- The owner separately authorized and completed the Workers Paid purchase on
  2026-09-05, then authorized the combined P1/P2 migrations, exact Worker
  deployment, sanitized provider evidence, authenticated traffic samples, and
  post-server-validation TestFlight upload. This does not authorize another
  plan-tier change, a manual production cron trigger, or retrieving/copying
  owner-managed provider credentials; those boundaries remain in force.
