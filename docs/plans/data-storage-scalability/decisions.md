# Data Storage Scalability — decisions and recorded evidence

Supporting material for [`plan.md`](plan.md). This file records owner
decisions and measured baselines; it carries no live checklist.

## 2026-09-04 — Workers plan tier: Free

Confirmed by the owner on the Cloudflare dashboard Workers plans page
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

**Tier-or-mitigation decision: immediate owner gate.** The D1 row totals below
show headroom at one member, but the later per-invocation evidence recorded a
32 ms cron tick against Free's nominal 10 ms CPU limit. Cloudflare documents
limited runtime flexibility for infrequent overages, which explains why this
invocation could succeed; it does not make repeated overages safe. Before
relying on the hourly backstop or inviting more members, the owner must either
move to Paid or authorize and prioritize a focused cron CPU mitigation. This
record does not authorize a purchase.

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
measured data. What P0 still owes is the per-request breakdown
(`meta.rows_read` per `/api/state`, `/api/me`, `get_history`, and per cron
tick) so P1–P3 can show before/after per path; the dashboard gives daily
totals only.

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
