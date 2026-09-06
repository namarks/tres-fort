# Data Storage Scalability — decisions and recorded evidence

Supporting material for [`plan.md`](plan.md). This file records owner
decisions and measured baselines; it carries no live checklist.

## 2026-09-06 — Privacy-safe post-release authenticated traffic samples

A production tail captured only the structured D1 usage lines already emitted
by exact Worker version `1cc13fec-3eab-4f95-a0fb-e9d6a1303f52`. Every sampled
request completed with HTTP 200:

| Client and path | Representative samples | D1 queries | Rows read | Rows written |
|---|---:|---:|---:|---:|
| TestFlight build 31 incremental `GET /api/state` | 3 identical | 8 each | 11 each | 0 each |
| TestFlight build 31 `GET /api/me` | 1 | 6 | 96 | 0 |
| OAuth MCP `get_history` via `POST /mcp` | 1 | 6 | 29 | 0 |

No request headers, IP addresses, request bodies, query values, account
identifiers, credentials, or returned workout history were retained. In
particular, this evidence records only route classification, HTTP outcome, and
aggregate D1 counters; it does not retain any personal history values.

The build-31 activation's safe one-shot full reload had already been consumed
before this tail was available. A read-only source audit found no existing UI
control that resets sync state non-destructively, so no full-reload sample was
captured. The owner must decide whether to capture it from a never-launched
build-31 device or another future safe trigger, or amend the replacement
evidence to omit it. The owner must also separately accept or reject the
overall post-release sample set as a substitute for the irrecoverable pre-P1
per-path baseline. P0 and P1 therefore remain incomplete.

P2 is unchanged: the owner must still choose between a later privacy-safe
capture containing a real provider row and amended acceptance of the existing
authenticated empty-window evidence plus synthetic raw-only-drift regressions.
P2 remains incomplete, and the workstream remains gated.

## 2026-09-05 — P1/P2 production release and TestFlight build 31

The authorized combined release used freshly fetched `origin/main` commit
`079f0359c898935c68513db74bba384bce260c0c`, tree
`fec23bff1cb94a83d55eb297a64dac458b2a16f9`. That tree is identical to the
independently reviewed security-fix head. The complete exact-source preflight
passed a zero-finding production dependency audit, TypeScript, 44 backend files
and 604 tests, and Wrangler dry-run. A pre-mutation D1 Time Travel bookmark was
retained as `000019ba-00000000-000050de-ee07a97da682b08adbefe37f03c2b1f9`.

Live prechecks proved that exactly migrations `0033`, `0034`, and `0035` were
pending and that the workout write fence was enabled with zero permits. They
applied successfully in that order. The exact Worker then deployed with source
and tree annotations plus tag `data-storage-scalability-079f035` as version
`1cc13fec-3eab-4f95-a0fb-e9d6a1303f52`, deployment
`73dbf38c-d517-435a-a57d-11e41d256a7f`, at 100% traffic. Post-release checks
proved no pending migration, zero invalid set/activity cursor rows, the fence
still enabled with zero permits, and a healthy public endpoint.

The first natural hourly trigger on that exact version completed at 19:00 PDT
with outcome `ok`, no exceptions, 53 D1 queries, 325 rows read, **zero rows
written**, 26 ms CPU, and 4,392 ms wall time. This is the retained P2 quiet-hour
comparison against the P0 baseline; no manual production cron was triggered.

After server validation, the same source archived and exported TresFort
`0.1.0 (31)` using Xcode 26.3 and XcodeGen 2.45.3. Apple accepted delivery
`33f6300a-4567-4273-9e2e-b0fd0edd3599` and its build-status endpoint returned
terminal `VALID`. The exported IPA SHA-256 is
`2621ff71444a314d31abdd331ba67714c23d73e4ad0294ae9c75a33365795758`;
the app and widget CDHashes are `0bf7e03851ceb6b3a88470312bf6ab49766bc2d4`
and `c924bbcbe6fed6da526e4ce439ac09fb6f131152`, both for team
`8BA2RY6RCA`. The app and widget dSYM UUIDs are
`43CDB421-CA70-3EF5-B4F3-543A876B9CB3` and
`737737EE-85C5-3DB6-B270-DD50C1AB31E6`.

An initial build-30 attempt was rejected before ingestion because Apple
reported 30 as already uploaded. That response established 31 as the next
valid number. It also exposed that Xcode 26.3 `altool` can print a terminal
upload error while returning success to the shell, so the release helper's
unconditional final message was not trustworthy. The helper now streams and
captures `altool` output, propagates command failures, rejects textual failure,
and requires an affirmative success marker before reporting an upload. A
five-case stubbed harness covers zero-exit rejection, normal success with the
delivery UUID preserved, nonzero exit propagation, and ambiguous output. The
rejected attempt created no new build.

During the release-evidence work, a Wrangler debug log exposed the prior
Cloudflare OAuth session's refresh grant. `npx wrangler logout` sent Wrangler's
revocation request and cleared the local authentication state; a subsequent
`wrangler whoami` reported that Wrangler was unauthenticated and required
login. Wrangler 4.92.0 does not verify the revocation response before reporting
success, so local logout alone did not prove provider-side invalidation. The
Cloudflare dashboard's Connected Applications page still listed exactly one
Wrangler authorization with a Revoke action. With owner authorization, that
row was revoked through its Wrangler-specific confirmation dialog; afterward
the dialog closed and neither the Wrangler row nor any Revoke action remained.
This independently verifies provider-side authorization removal. No credential
content was retained. This records supporting release security hygiene only:
it is not a storage phase, storage evidence, or a completion claim. The owner
must complete a fresh Wrangler login before production traffic sampling.

The authenticated owner paths were not sampled before P1 shipped. That
historical per-path baseline cannot now be recreated without rolling back to a
Worker that is unsafe after incremental iOS cursors. The 2026-09-06 classified
post-release capture now covers incremental `/api/state`, `/api/me`, and OAuth
`get_history`; the full-reload sample and the owner's explicit acceptance of
the overall substitution remain outstanding before P0/P1 close.

An authorized privacy-preserving in-page intervals.icu capture used only the
logged-in web-session routes. The event window 2026-09-05 through 2026-12-04,
the activity window 2026-06-07 through 2026-09-05, and a wider activity window
2025-09-05 through 2026-09-05 each returned HTTP 200 with an empty array. The
browser used its page-local session URL to make those requests, but no cookie,
token value, athlete identifier, name, or event/activity content left the page
context, entered tool output, or was copied or retained. Because the provider
returned no rows, the capture cannot yield two versions of the same row whose
only change is ignored raw data. It is not relabeled as the required
real-response replay, no fixture is fabricated, and P2 remains open.

Remaining evidence is therefore narrow: the missing full-reload sample or an
owner-approved amendment, owner acceptance of the overall post-release path
sample set, and the provider gate. The latter requires either a later privacy-preserving
capture after a real event/activity is available, or an explicit owner decision
to amend acceptance to the authenticated empty-window evidence plus the existing
synthetic raw-only-drift regressions. Neither alternative changes storage scope
implicitly, and neither may expose owner credentials or personal response
content.

## 2026-09-05 — Production release paused for Hono CORS security update

The owner authorized the combined P1/P2 production migration, Worker, and
subsequent iOS rollout. Exact merged source `fa4f13b` passed the release
preflight (TypeScript, all 44 backend files / 600 tests, and Wrangler dry-run),
and live prechecks confirmed only migrations `0033`–`0035` pending, the workout
write fence enabled with no permit, and a retained D1 Time Travel bookmark.
No migration or deployment began.

The lockfile audit then found `hono@4.12.19` affected by
[GHSA-8j4g-w8fx-2239](https://github.com/advisories/GHSA-8j4g-w8fx-2239).
The vulnerable default CORS preflight parser is reachable on the public OAuth
discovery, registration, and token routes, so this is a release blocker rather
than an unrelated advisory. The smallest compatible repair is Hono `4.12.34`,
the first patched release. Production remains held until that focused update
passes a zero-production-finding audit, attack-shaped OAuth preflight coverage,
the full backend/typecheck/dry-run gates, independent exact-head review, and
repository delivery. The eventual production source must be the new merged
head; authorization does not permit deploying the now-superseded `fa4f13b`.

The focused repair raises the declared Hono range to `^4.12.34` and locks the
installed package to `4.12.34`; it changes no application code. Three route-level
OAuth preflight checks exercise the public routes with a request-header payload
containing one 16,384-character whitespace run without a comma delimiter and
confirm the expected wildcard/no-credentials response. A deterministic
middleware regression also verifies that the attack-shaped payload does not
invoke the exact vulnerable `\\s*,\\s*` splitter; the same probe observes that
invocation with Hono 4.12.19 but not 4.12.34. Local evidence passed the production
dependency audit with zero findings, all 44 backend files / 604 tests,
TypeScript, the Wrangler dry-run, planning validation, and diff hygiene.
Repository delivery and a fresh exact-source production preflight remain the
next gates.

## 2026-09-05 — Workers plan tier: Paid

After the deployed cron optimization still measured 18 ms CPU on its first
natural hourly tick, the owner authorized the Workers Paid purchase. The
Cloudflare checkout confirmed the subscription active, and the account's
Workers plans page then showed **Paid** as the current plan at **$5 / month +
usage**. The saved payment method and account identity are deliberately not
copied into the repository.

The subscription includes 10 million Workers requests and 30 million CPU-ms
per month before usage charges. For this workstream, the decisive capacity
change is the hourly-cron CPU allowance: Paid permits up to 15 minutes rather
than Free's nominal 10 ms. The observed 18 ms tick therefore no longer risks
the Free runtime ceiling. D1's Paid included allowances also replace the hard
Free daily row caps with monthly included usage, but this does not make the P1
delta-sync or P2 no-op reconcile work optional: those changes still reduce
latency, write amplification, and avoidable spend as membership grows.

This tier change resolves the P0.5 capacity gate only. It does not decide P5
retention, authorize production migration `0034`, authorize the P1 Worker or
iOS rollout, or authorize future plan changes.

## 2026-09-04 — Workers plan tier: Free

Historical baseline confirmed by the owner on the Cloudflare dashboard Workers plans page
("Current plan" under Free). Account id is the one in `wrangler.jsonc`.

Free-tier limits that bind this plan, with current Paid allowances, rates,
and CPU limits from Cloudflare's official [D1 pricing](https://developers.cloudflare.com/d1/platform/pricing/),
[Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/),
and [Workers limits](https://developers.cloudflare.com/workers/platform/limits/)
pages, read 2026-09-04:

| Limit | Free | Paid ($5 / month + usage) |
|---|---|---|
| D1 rows read | 5,000,000 / day | First 25 billion / month included; then $0.001 / million rows |
| D1 rows written | 100,000 / day | First 50 million / month included; then $1.00 / million rows |
| D1 stored data | 5 GB total | First 5 GB included; then $0.75 / GB-month |
| CPU time per HTTP request | 10 ms | 30 s default; configurable to 5 min |
| CPU time per hourly cron trigger | 10 ms | 15 min |
| CPU time billing | — | First 30 million CPU-ms / month included; then $0.02 / million CPU-ms |
| Subrequests per request (cron tick included) | 50 | 10,000 |
| Requests | 100,000 / day | First 10 million / month included; then $0.30 / million |

D1 has hard-enforced the free-tier daily row limits since 2026-09-01
(<https://developers.cloudflare.com/changelog/post/2026-09-01-d1-free-tier-limit-enforcement/>).

**Initial tier-or-mitigation decision: mitigate on Free (2026-09-05).** The D1 row
totals below show headroom at one member, but the later per-invocation evidence
recorded a 32 ms cron tick against Free's nominal 10 ms CPU limit. Cloudflare
documents limited runtime flexibility for infrequent overages, which explains
why this invocation could succeed; it does not make repeated overages safe.
The owner authorized a focused local cron CPU mitigation while remaining on
Free. The owner later separately authorized the Paid purchase after the
optimized natural tick still missed the Free target; the section above records
the current tier. Neither decision authorizes the P1 production migration,
Worker deployment, or iOS distribution.

## 2026-09-05 — P0.5 production release and natural-tick result

The reviewed mitigation was merged in PR #123 as commit
`dc04db76326cd502063d94d3ee44428b8ae0f213` (tree
`0ffb6099b4253111cf172678fafb8b5a2b4f1641`) and delivered with a deploy-only
release. Production routed 100% of traffic to Worker version
`4f0b3ab1-af0e-4235-884d-927658458b94`; the health endpoint returned HTTP 200
with `ok=true`. No migration was applied, the hourly schedule remained in
place, and `0033_gymnastic_strength_catalog.sql` remained the only pending
migration.

The next natural hourly tick ran on that exact Worker version and completed
with `outcome=ok`: 53 D1 queries, 291 rows read, 64 rows written, 18 ms CPU,
and 4,519 ms wall time. Compared with the 32 ms / 2,560-row-read P0 baseline,
the bounded reconcile removed the intended historical scan and reduced CPU,
but it did not meet Free's strict `<10 ms` acceptance threshold. Validation
therefore stopped after the first tick and the monitor was paused; successful
execution was not treated as evidence of recurring Free-tier headroom.

The subsequent Paid upgrade resolves the runtime-capacity outcome without
erasing the failed Free acceptance result. The row and CPU reduction remain
the before/after evidence for the mitigation; P2 still owns eliminating quiet
hour writes.

## 2026-09-05 — Free-plan mitigation evidence

The selected local change bounds the cron's post-intervals HealthKit candidate
scan to the affected activity window plus one civil day at each edge, and looks
up possible intervals winners one further day out so restoration stays correct
across both boundaries. It retains the public full-history reconciliation path,
uses the existing `external_activities(user_id, date)` index, and replaces the
lifetime nested match loop with per-kind time-ordered lookup. It adds no trigger,
index, migration, or production configuration.

Both official writers derive `date` and `start_date_local_ms` from the same
local civil timestamp. A value-free production aggregate confirmed zero stored
rows violate that invariant; the query made zero writes. The local change also
rejects future non-null HealthKit timestamps whose encoded civil date disagrees
before they reach D1, so the bounded date lookup does not rely on an unchecked
API assumption.

A production-shaped real-D1 fixture with 120 old rows from each source measured
the bounded dedupe at 2 queries, 4 rows read, and 0 rows written, versus 2
queries, 484 rows read, and 0 rows written for the retained full-history mode.
The focused activity-sync shape used 6 queries, 10 rows read, and 1 row written.
This is deterministic local cost evidence, not proof of production CPU. The
separately authorized release later supplied that evidence: the first natural
tick improved but failed the Free CPU threshold, as recorded above.

The final local source passed all 41 test files / 537 tests, TypeScript,
planning validation, diff hygiene, a Wrangler dry-run, and independent
exact-head review. The production release and natural-tick outcome are recorded
above.

## 2026-09-05 — P1 local implementation and rollout contract

The local P1 slice keeps D1 and the existing two-class consistency model. It
adds migration `0034_set_log_delta_cursors.sql`, backend delta reads and cursor
writers, and iOS per-account cursor persistence and merge behavior. It does not
add a generic change log, background sync service, event store, or new provider.

Migration `0034` is additive because repository releases migrate before they
deploy code. It adds denormalized `set_logs.user_id`, server-owned mutable
`set_logs.updated_at` and `activities.updated_at`, plus member-first cursor
indexes for sets, sessions, and manual activities. Existing rows receive a D1
clock value rather than a client event timestamp. The protected set backfill
holds migration `0032`'s singleton workout-write permit only around its UPDATE,
then executable assertions prove ownership parity, a positive cursor, no leaked
permit, and a still-enforced write fence.

Narrow compatibility triggers cover only the old Worker's omitted-column and
unchanged-cursor statement shapes during a migration-first rollout. New code
supplies or advances the cursor and bypasses them. They also preserve a safe
rollback window before incremental iOS ships. Apply `0034` only when the P1
Worker is ready to deploy immediately; if that deployment fails, roll forward
with the P1-aware Worker rather than trying to reverse the migration. For the
entire migration-to-Worker-deploy gap, an old-Worker session discard can
overcount its audit `sets_discarded` value because D1 `meta.changes` includes
the trigger's internal cursor write. Data, tombstones, and cursors remain
correct. The P1 Worker counts the authoritative `RETURNING` rows instead; this
bounded observability defect is accepted rather than weakening rolling-release
compatibility.

The server captures each `/api/state` response watermark before collection
reads. Active cursors use that request-start time minus a 60-second overlap;
rows merge idempotently by id, so a concurrent write falls into the next pull
and overlap redelivery is harmless. Plan versions now increase across plan
replacement as well as in-place edits. P1 activates incremental plan,
set/session, and manual-activity sync only. The app persists and sends the
external event/activity cursor fields but holds both at zero until P2 makes
their `synced_at` values advance only on real provider changes.

The iOS snapshot and watermarks commit atomically behind an account-scoped
request ticket. First sign-in, account change, corrupt/invalid cached state, or
legacy rows without comparable cursors force a complete reload. Raw set
tombstones survive long enough to order against delayed outbox acknowledgements;
stale or equal-time acknowledgements cannot overwrite a newer attempt/status or
strictly newer server row. A successful set POST is the mutation boundary. An
incomplete following delta retains the ACK, retires the durable intent, reports
success, clears cursors for a complete reload, and surfaces sync uncertainty
instead of inviting a duplicate tap. Omission is accepted without uncertainty
only when the pre-POST snapshot already contains an equal or newer server row.

Manual activities preserve a separate cursor-capability bit through local
snapshot encoding. A legacy absent/null collection decodes as empty but leaves
`log_since=0`; a valid non-null collection supplies capability; a malformed
present collection fails decoding, so neither state nor cursor can commit.

Local evidence covers a request-interleaving watermark race; backdated,
future-dated, tombstoned, and 1,005-row manual-activity deltas; every legacy
write shape; same-millisecond cursor advancement; and monotonic plan
replacement. Query plans name the member-first indexes, empty set/session/
activity seeks read at most two billed rows, and the added activity or set
cursor index costs one additional billed row per indexed mutation. All 43
backend test files / 548 tests passed, TypeScript passed, all 267 iOS simulator
tests passed, and diff hygiene passed. The P1 production migration/Worker
release, production before/after traffic, and iOS distribution remain separate
delivery evidence and are not authorized by this record.

Repository delivery completed on 2026-09-05 through PR #124. Required CI and
independent review passed on exact head `cf6cb83`; squash merge `647a9f6` has
the same tree, and post-merge main CI passed. No deployment, database migration,
or TestFlight distribution ran as part of that delivery.

P2 uses an explicit rolling-protocol capability rather than inferring safety
from the external arrays, which older Workers already emit. A P2 Worker adds
top-level `external_sync_cursors_version: 2` to `/api/state`; compatible iOS
builds activate both `events_since` and `activities_since` only when the value
is at least 2. An absent or lower value holds both at zero, so a mixed-version
rollout or server rollback returns to complete external-cache reloads.

## 2026-09-05 — P2 local change-cursor implementation

P2 makes `synced_at` a true change cursor across both external cache tables.
Intervals event and activity upserts compare every normalized stored field with
null-safe equality, ignore raw provider JSON as a change signal, and update raw
only alongside an extracted-field change. Unchanged and raw-only-different
responses therefore perform zero writes and leave both raw and the cursor
unchanged. Corrections, tombstones, resurrection, and cross-source dedup state
changes advance the cursor strictly even if the Worker clock has not advanced.

A provider HTTP 200 is accepted or rejected as one cache input. Deliberately
filtered rows are ignored before their irrelevant fields are validated, but a
missing or malformed planned-event category discriminator, malformed relevant
id or local civil timestamp, or a non-record array member returns a parse
failure before any D1 statement runs. This prevents a partially parsed response
from updating its valid rows and tombstoning previously cached rows that the
parser skipped. The local timestamp parser accepts the provider's zone-free
seconds form plus one-to-three fractional digits, validates the civil calendar
rather than relying on JavaScript date normalization, and rejects zone suffixes
on a field whose contract is local time.

The reconcile tombstone statement passes all seen provider ids as one JSON
value and expands it with SQLite `json_each`. Its bind count is constant instead
of growing with the response, so a normal window cannot cross D1's 100-bound-
parameter ceiling. Query-plan evidence requires the list subquery to be
materialized rather than correlated, while 120-row integration cases prove the
event and activity paths still respect tenant and source boundaries.

Because `activities_since` covers all sources, HealthKit same-UUID retries use
the same change-only rule. An unchanged retry preserves a dedup-retired row's
tombstone, canonical bit, and winner provenance; a real extracted revision
updates the row before the existing deterministic dedup pass restores the
correct state.

Migration `0035` adds member-first cursor indexes on both external tables. It
does not backfill application data, but index creation writes entries for every
existing row once. Afterward, a real cache-row mutation bills three rows in the
measured schema (base row, existing member/date index, and new member/cursor
index), while a no-op bills zero. Empty external delta queries name the new
indexes and read at most two billed rows in the local real-D1 tests.

Local evidence passed 106 focused cache tests, all 44 backend files / 600 tests,
TypeScript, and all 273 iOS simulator tests. The raw-drift regressions use two
distinct synthetic response shapes per provider endpoint; they prove the code
path but are not relabeled as real captures. No authorized sanitized pair of
same-window intervals.icu responses exists in the repository, so that replay
remains a live evidence gate alongside the post-release quiet-hour log.

Production rollout remains server-first: have the combined P1/P2 Worker ready,
apply pending migrations `0033`, `0034`, then additive `0035`, deploy the Worker
that advertises cursor version 2 immediately, and distribute incremental iOS
only afterward. If the Worker deploy fails after the migrations commit, roll
forward with the prepared Worker rather than attempting to reverse an index or
cursor migration. None of those production or distribution actions is
authorized by this local record.

## 2026-09-04 — D1 daily baseline (P0, dashboard aggregate)

Source: D1 → `tres-fort-db` → Overview, "Last 24 hours", region WNAM, read
2026-09-04 late morning PDT. One member (the owner) with Claude coaching and
intervals.icu connected; the prior day also carried review and test traffic,
so this is a heavy day, not a typical one (rows read were up 120% on the day
before, which puts a quieter day near 77k).

| Metric | 24 h value | Free cap | Share of cap |
|---|---|---|---|
| Rows read | 170,000 | 5,000,000 / day | 3.4% |
| Rows written | 2,000 | 100,000 / day | 2.0% |
| Storage used | 1.35 MB | 5 GB | 0.03% |
| Total queries | 3,120 (2,310 read, 811 write) | — | — |
| Tables | 29 | — | — |
| Query latency p50 | 0.28 ms | — | — |

Shape of the traffic, from the charts:

- Write queries arrive in a flat comb of about 30 per hour, around the
  clock. That is the hourly intervals.icu reconcile (`syncExternalEvents` +
  `syncExternalActivities`) rewriting the 90-day window whether or not
  anything changed. It accounts for most of the 811 write queries and most
  of the 2k rows written. P2 removes it for quiet hours.
- Read queries are spiky: bursts of several hundred queries when the app
  syncs or a review session runs, near zero otherwise. The bursts are the
  full-reload `/api/state` pulls P1 replaces.

Linear extrapolation from this single heavy member (an upper bound, since
lighter members read less):

| Cap | Members at the owner's usage before the cap binds |
|---|---|
| Rows read (5M / day) | ≈ 29 active members |
| Rows written (100k / day) | ≈ 50 members with intervals.icu connected |
| Cron subrequests (50 / tick) | ≈ 20 members with intervals.icu connected |

The plan's back-of-envelope figures (tens, forty, twenty) hold against the
measured data. The cron per-invocation baseline is now recorded below. What P0
still owes is the three representative authenticated foreground samples:
`meta.rows_read` for `/api/state`, `/api/me`, and `get_history`, so P1–P3 can
show before/after per path; the dashboard gives daily totals only.

## 2026-09-04 — P0 local instrumentation and index-cost evidence

The workstream branch adds a request-scoped D1 usage observer for the four P0
paths. Each invocation emits one structured Workers Logs object with only:

- `event=d1_usage`;
- `operation` (`GET /api/state`, `GET /api/me`, `MCP get_history`, or
  `cron tick`);
- `outcome`, `query_count`, `rows_read`, and `rows_written`.

The REST totals include app-auth middleware queries, the MCP total includes
bearer resolution, and the cron total covers both cache jobs. No user id,
credential, request arguments, URL, audit args, or external source JSON is
logged. The local Workers-runtime coverage is
`test/d1_observability.test.ts`; the full suite passed with 41 files and 525
tests, and TypeScript plus diff hygiene passed. Exact-head review and CI remain
delivery gates rather than evidence already claimed here.

`test/d1_index_cost.test.ts` uses paired local shadow tables and real D1
`meta.rows_written` counters to isolate the final P1/P3 index cost. It models
adding `set_logs(user_id, updated_at)`, replacing
`set_logs(exercise_id, logged_at)` with
`set_logs(user_id, exercise_id, logged_at)`, preserving the session and live
slot indexes, and adding `audit_log(user_id, actor, created_at)`.

| Mutation | `set_logs` current → proposed | `audit_log` current → proposed | Combined MCP write |
|---|---:|---:|---:|
| Insert | 5 → 6 (+1) | 2 → 3 (+1) | 7 → 9 (+2) |
| Correction | 1 → 2 (+1) | 2 → 3 (+1) | 3 → 5 (+2) |
| Soft-delete | 1 → 2 (+1) | 2 → 3 (+1) | 3 → 5 (+2) |

These are controlled index-amplification measurements, not owner-production
traffic. They exclude surrounding session transitions, write-fence work, and
other route queries. P3 still needs the production P2 savings comparison
before its indexes may ship.

## 2026-09-04 — P0 production release and measured baseline

The reviewed instrumentation-only source was merged as commit
`bc09faf1415ba9cd3b39c1af6f3a713f42f58a93` (tree
`123c2c4c050cc3e2696e2c61bda8988ebac71724`) in PR #120. Exact-source
preflight passed 41 test files / 525 tests, TypeScript, and a Wrangler dry-run.
Production was then changed with `wrangler deploy` only, not the repository's
`release` command, because `release` also applies migrations. The deployment
sent 100% of traffic to version `b537eaeb-2aaa-47ba-bb1f-1c7b44413f3b`;
`GET /health` returned HTTP 200 with `ok=true`. The migration list was unchanged
after deployment and still had only `0033_gymnastic_strength_catalog.sql`
pending, proving this release did not apply a D1 migration.

Read-only production D1 queries captured exact global and owner-attributed
table counts without returning account identifiers. Both aggregate reads made
zero writes, and the database size was about 1.35 MB. The exact counts are not
copied into this public repository because they expose personal training and
activity volume plus authentication/security state. The cost-relevant scale
is sufficient here: external activity rows are in the low thousands; set-log
rows are in the low hundreds; audit rows, sessions, notes, and manual
activities are each below one hundred. This confirms that storage volume is
small today while the unbounded external and audit tables remain the growth
drivers P5 must address.

A separate aggregate predicate also proved that exactly one distinct plan
owner and exactly one distinct MCP actor joined to the same account, without
returning an identifier. Its owner-scoped counts were bounded by the global
census. The proof query made zero writes. Exact personal and auth-state counts
remain private evidence rather than publishable plan content.

The natural 19:00 PDT hourly cron completed on the deployed version with
`outcome=ok`: 52 D1 queries, 2,560 rows read, and 62 rows written. The Worker
invocation used 32 ms CPU and 4,095 ms wall time. Both the live tail and the
durable Workers Logs event agreed on these counters and the exact script
version. This is the P0 before-measurement for P2's quiet-hour comparison; it
is not yet a quiet-hour zero-write result. It is also above Free's 10 ms CPU
limit. Cloudflare says the runtime has some flexibility for infrequent
overages, so one `ok` outcome is not evidence of safe headroom; consistent
overages can be terminated. The owner tier-or-mitigation gate above is
therefore immediate rather than a future ten-member threshold.

Workers Logs also proved that structured production ingestion works by
capturing two unauthenticated diagnostic probes with zero D1 queries. They are
excluded from the owner baseline. P0 still needs one representative
authenticated foreground `/api/state`, one authenticated Profile `/api/me`,
and one OAuth MCP `get_history` invocation. No additional deployment,
migration, index creation, TestFlight build, credential transfer, or manual
cron trigger is required to collect them.
