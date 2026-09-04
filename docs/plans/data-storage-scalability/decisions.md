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

**Upgrade decision: open.** The measured headroom below shows no immediate
risk at one member. The owner decides whether to move to Paid now or before
inviting roughly ten more members.

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

The remaining P0 baseline requires an explicitly authorized
instrumentation-only Worker deploy, representative owner app and OAuth MCP
traffic, at least one natural hourly cron tick, and read-only Workers Logs plus
production table-count evidence. It requires no D1 migration, production index
creation, TestFlight build, credential transfer, or manual cron trigger.
