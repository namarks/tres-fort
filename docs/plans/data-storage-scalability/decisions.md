# Data Storage Scalability — decisions and recorded evidence

Supporting material for [`plan.md`](plan.md). This file records owner
decisions and measured baselines; it carries no live checklist.

## 2026-09-04 — Workers plan tier: Free

Confirmed by the owner on the Cloudflare dashboard Workers plans page
("Current plan" under Free). Account id is the one in `wrangler.jsonc`.

Free-tier limits that bind this plan (dashboard, same page):

| Limit | Free | Paid ($5 / month + usage) |
|---|---|---|
| D1 rows read | 5,000,000 / day | $0.001 / million rows |
| D1 rows written | 100,000 / day | $1.00 / million rows |
| D1 stored data | 5 GB | $0.20 / GB-month |
| CPU time per invocation | 10 ms | 5 min |
| Subrequests per request (cron tick included) | 50 | 10,000 |
| Requests | 100,000 / day | $0.30 / million |

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
