# tres-fort — Multisport Coaching Design

Companion to [`DESIGN.md`](DESIGN.md). Read that first — this doc assumes its
vocabulary (consistency classes, the versioned plan tree vs. the append-only
log, `projectCalendar`, the MCP-is-the-product framing) and only describes
what changes to support **holistic strength + endurance coaching**.

Status: **design / not yet built.** This is the spec to implement against.

> **Review outcome — 9-agent adversarial pressure-test. Verdict: KEEP-WITH-CHANGES.**
> A fresh-eyes, code-grounded review stress-tested §1. The ownership model holds —
> all three alternative architectures (tres-fort-owns-all, intervals-owns-all,
> no-bridge) were correctly rejected. But the review, plus a check of the
> athlete's actual situation, changes the **build order and several claims**.
> This block is authoritative where it conflicts with the body below.
>
> **Premise — confirmed, with a cost.** The athlete *has a watch but does not yet
> record to intervals.icu*, and *will adopt Claude to chat directly*. So the
> model is reachable, not free:
> - **M0 connection chain is prerequisite #1:** watch → (Garmin/Strava) →
>   intervals.icu → tres-fort OAuth must work end-to-end before any coaching
>   value exists. intervals.icu is built to ingest Garmin/Strava, so this is a
>   setup step, not a build — but nothing downstream matters until it is solid.
> - **Per-user Claude MCP moves onto the critical path** (previously deferred).
>   "Dad chats with Claude about HIS training" requires the `/mcp` bearer/OAuth to
>   resolve to *his* user, not the single owner (DESIGN.md §6 resolves to one).
> - **iOS, not chat, is his daily surface.** Even chatting directly, he won't open
>   a chat each morning for "what's today" — the composite calendar in the app is
>   his primary touchpoint, so it cannot hide behind the chat model.
>
> **Must-fix before the write bridge:**
> 1. **Resolve R1 as a go/no-go gate** — live-spike `POST /events` for a *run* and
>    a *swim* (only the `WeightTraining` shape is verified, `intervals.ts:470`);
>    capture a round-trip fixture; confirm prose `description` + deletion.
> 2. **Empirically verify the "unified load gauge"** — does a *planned*
>    `WeightTraining` event actually move intervals' CTL? `intervals.ts:388-394`
>    says there is no verified completed-activity write API. If it does not,
>    §1/§5.3/§7's gauge is false and tres-fort must own a combined load model.
>    ~10-minute check. And `get_fitness` (the read that would surface it) does not
>    exist yet — the gauge is described as a standing pillar but is unbuilt.
> 3. **Ship token-refresh + 401-disconnect — NOT built today.**
>    `intervalsAuth.ts:104` is `authorization_code` only; the stored
>    `refresh_token` is never exchanged; the sync collapses 401 into a generic
>    failure with no disconnect signal. A revoked/expired token silently freezes
>    the cache for weeks. Shipped bug, independent of multisport. **R3 is High.**
> 4. **`external_events` needs a provenance column.** It is a FROZEN CONTRACT
>    (`migrations/0006`) every reader treats as "origin = intervals." Write-through
>    creates rows whose origin is *tres-fort*; add a `source`/`origin` marker in
>    the cache (not just the new ledger) or `getGroupFeed` / `getRideConflicts` /
>    iOS mis-read a failed-push mirror as canonical.
> 5. **Composite days break `detectConflicts`** — `db.ts:4386` flags every
>    same-day endurance+lift as `clash`, i.e. every intended brick. Decide:
>    remove, or make it interference-rule-aware (intended brick vs. accidental
>    heavy-leg-before-key-run).
> 6. **Write-through keying/ordering** — key the mirror on the intervals event id
>    *returned by the POST* (`intervals:{userId}:{id}`), never the Claude marker,
>    or the next cron tombstones it (`db.ts:4004`/`4047`). intervals POST first;
>    mirror only on confirmed 2xx; sweep `pending` ledger rows.
>
> **Dropped: §6.4 rolling materialization** — it is the future-row-extruder §11
> forbids, and `sessions` has no soft-delete, so re-planning a materialized block
> has no clean teardown. Use the schedule projection + the shipped
> `set_planned_session` for genuinely-decided near days instead.
>
> **Resequenced build order: see the revised §10.**

---

## 0. Motivating case

A 75-year-old (Nick's dad) wants to finish a 70.3 triathlon in Salem, OR in
**July 2027** — a ~14-month, multi-discipline, periodized build where the
*primary* goal is endurance (swim/bike/run) and strength is a supporting
block. Today the app is a strength system with read-only cycling *awareness*;
it cannot prescribe, schedule, or periodize endurance work, and it has no
concept of trips, races, or phased training. This design closes that gap
**without turning tres-fort into a triathlon app** — endurance truth stays in
a system built for it (intervals.icu); tres-fort becomes the strength executor
**and** the holistic planning/awareness surface.

---

## 1. The mental model

**Claude is the brain. It connects to two stores and keeps one coherent plan.**

```
                         ┌──────────────────────────────┐
                         │            Claude            │
                         │   (the coach / the brain)    │
                         └───┬───────────────────────┬──┘
              writes strength │                       │ writes endurance
              reads strength  │                       │ reads endurance + load
                              ▼                       ▼
                    ┌───────────────────┐   ┌────────────────────┐
                    │     tres-fort     │   │   intervals.icu    │
                    │  strength truth   │◄──┤ endurance truth +  │
                    │  + holistic       │   │ unified load (CTL) │
                    │    calendar       │   │                    │
                    │  + iOS executor   │──►│ (strength load     │
                    └───────────────────┘   │  exported in)      │
                              ▲             └────────────────────┘
                              │ executes strength
                         iOS app / the user        (executes endurance on watch)
```

### Canonical ownership — one source of truth per data class

| Concern | Canonical owner | Notes |
|---|---|---|
| Planning / coaching intelligence | **Claude** (via MCP) | Backend stays AI-free per `DESIGN.md` §1 |
| Endurance plan, actuals, structured detail | **intervals.icu** | Multi-sport; the watch executes it; built for this |
| Strength plan, actuals, structured detail | **tres-fort** | First-class today; iOS is the gym executor |
| Unified aggregate load (Fitness/Fatigue/Form) | **intervals.icu** | Strength sRPE already exports there (§5.3) |
| Periodization intent, races, trips, stress model | **tres-fort** (plan `meta` JSON) | Authored truth; versioned; rides `/api/state` |
| The holistic weekly/most-of-plan calendar | **tres-fort — computed projection** | A *view*, not a stored table (§6) |

**Invariant.** Cardio flows into tres-fort **read-only** (the existing
reconciled cache, `DESIGN.md` §7). tres-fort never becomes a second *writable*
store of cardio truth. When Claude schedules endurance it **writes to
intervals** (§5), and the change syncs/write-throughs back. This is the single
rule that keeps the two-store design from rotting into a reconciliation mess.

---

## 2. What already exists (the runway)

The schema is ~⅔ wired for this. Built and verified in the current codebase:

| Capability | Where | State |
|---|---|---|
| Inbound sync of **all sports** (ride/run/swim/other), planned | `external_events` (`migrations/0006`), `kindOf()` ([`src/intervals.ts:66`](../src/intervals.ts)) | ✅ planned workouts w/ duration, load, intensity |
| Inbound sync of **all sports**, completed actuals | `external_activities` (`migrations/0015`) | ✅ distance, power, HR, TSS, IF |
| **Outbound** strength load → intervals | `session_load_exports` (`migrations/0008`), `pushLoad` ([`src/intervals.ts`](../src/intervals.ts)) | ✅ sRPE → `WeightTraining` WORKOUT, idempotent PUT |
| Per-user intervals auth | OAuth (`migrations/0022`) + API-key fallback (`0016`); cron loops per user ([`src/db.ts:268`](../src/db.ts)) | ✅ shipped (build 21) |
| Computed calendar (no weeks table) | `projectCalendar` ([`src/db.ts`](../src/db.ts)), iOS `CalendarProjection.swift`, contract `test/calendar.test.ts` | ✅ strength-only today |
| Future per-day overrides | `set_planned_session` / `skip_planned_session` → concrete `sessions` rows | ✅ one day at a time |
| Free-form non-strength log | `activities` (`migrations/0017`) | ✅ type + duration only |

**The bones are there.** What's missing is (a) a *write* path so Claude can
place endurance work, (b) durable *structure* for periodization/races/trips,
(c) a *holistic* projection that merges both disciplines, and (d) a planning
*model* that doesn't collapse to one load scalar. The rest of this doc.

---

## 3. Consistency classes for the new data

Everything new slots into an existing class from `DESIGN.md` §3 — no new
consistency strategy is invented:

| New data | Class | Storage | Version bump? |
|---|---|---|---|
| Periodization blocks, races, trips, stress model | **Versioned document** (like `meta.schedule`) | `plans.meta.*` JSON | **Yes** — authored plan intent, optimistic concurrency, audit + note |
| Claude-authored endurance workouts | **Server-owned reconciled cache** (mirror of intervals) | `external_events` (write-through, §5) | No (lives outside the plan tree) |
| Endurance-export idempotency refs | **Export ledger** (like `session_load_exports`) | `planned_event_exports` (new, §5.2) | No |
| Trip → day effects (rest days) | **Append-only log** | concrete `sessions` rows | No (per existing skip-day pattern) |

The design principle throughout: **store truth, derive views.** Authored facts
(a race date, a trip, a phase) are durable rows/JSON you update. Anything fully
regenerable from those facts (the expanded calendar, projected load, "what's
today") is **computed on read**, never materialized — except the deliberate,
bounded "rolling materialization" of §6.4.

---

## 4. Data model changes

All additive, idempotent, numbered migrations per `CLAUDE.md` conventions.
Reuse `plans.meta` JSON (already the home of `schedule`) for authored intent —
graduate any of these to a real table only if it becomes relational/queryable
enough to deserve one (noted per item).

### 4.1 `plans.meta.race` — the goal event(s)

```jsonc
"race": {
  "name": "Salem 70.3",
  "date": "2027-07-18",          // YYYY-MM-DD civil date (anchor; see §6.3)
  "discipline": "triathlon",
  "distance": "70.3",
  "priority": "A",               // A | B | C
  "location": "Salem, OR"
}
```
Array form (`races: [...]`) if B/C tune-up events appear. Graduate to a
`goal_events` table only if events gain per-event relations.

### 4.2 `plans.meta.periodization` — phase intent (NOT per-day rows)

```jsonc
"periodization": [
  { "phase": "base",  "start": "2026-06-01", "end": "2026-10-31",
    "focus": "aerobic volume + strength foundation",
    "weekly_load_target": 350, "strength_emphasis": "hypertrophy" },
  { "phase": "build", "start": "2026-11-01", "end": "2027-04-30",
    "focus": "bricks, threshold, race-specific",
    "weekly_load_target": 500, "strength_emphasis": "maintenance" },
  { "phase": "peak",  "start": "2027-05-01", "end": "2027-06-27", ... },
  { "phase": "taper", "start": "2027-06-28", "end": "2027-07-18",
    "strength_emphasis": "minimal" }
]
```
`phase ∈ base|build|peak|taper|race|recovery`. This is the **structure you
don't want Claude re-deriving every conversation** — but it is still *intent*,
not a materialized calendar. Graduate to a `plan_phases` table if blocks gain
relations (per-phase workout libraries, shared templates).

### 4.3 `plans.meta.trips` — availability / blackout ranges

```jsonc
"trips": [
  { "id": "uuid", "start": "2026-08-15", "end": "2026-08-25",
    "type": "travel",            // travel | rest | injury | other
    "can_train_light": true,     // pool/run access while away?
    "note": "Italy — running shoes only" }
]
```
A trip is **authored truth about availability**, so it is stored and editable —
this is the direct answer to "I need the system to know I'll be on vacation."
The *effect* (which days become rest) is **not** stored here; Claude
materializes it as rest `sessions` rows for the range and re-plans the
surrounding week (§6.2, §7). Versioned with the plan so it rides `/api/state`
and shows in the calendar immediately. Graduate to a `trips` table if trips
gain relations (recurring travel, per-group sharing).

### 4.4 `plans.meta.stress_model` — the planning load model (§7)

```jsonc
"stress_model": {
  "discipline_weights": {           // how a unit of each maps to systems
    "swim":     { "aerobic": 1.0, "neuromuscular": 0.1, "impact": 0.0 },
    "bike":     { "aerobic": 1.0, "neuromuscular": 0.2, "impact": 0.0 },
    "run":      { "aerobic": 1.0, "neuromuscular": 0.4, "impact": 1.0 },
    "strength": { "aerobic": 0.2, "neuromuscular": 1.0, "impact": 0.3 }
  },
  "interference_rules": [
    "heavy_lower_body >= 48h from key_run_or_brick",
    "no two high_neuromuscular days back-to-back"
  ],
  "age_modifiers": { "athlete_age": 75, "recovery_multiplier": 1.4,
                     "max_weekly_ramp_pct": 8, "high_intensity_per_week": 2 }
}
```
Legible, tunable, versioned. The numbers are **defaults to tune, not
physiology gospel** — the point is that the model exposes *dimensions and
rules* Claude reasons over, so planning never collapses to one scalar (§7).

### 4.5 `planned_event_exports` — endurance write idempotency ledger

New table, exact parallel to `session_load_exports` (`migrations/0008`):

```sql
CREATE TABLE IF NOT EXISTS planned_event_exports (
  local_id      TEXT PRIMARY KEY,   -- Claude-minted id for the planned workout
  intervals_ref TEXT,               -- intervals event id (null until first push)
  marker        TEXT NOT NULL,      -- deterministic external_id "tresfort:planned:{local_id}"
  status        TEXT NOT NULL,      -- ok | pending | skipped | disabled
  attempts      INTEGER NOT NULL DEFAULT 0,
  updated_at    INTEGER NOT NULL
);
```
Lets a re-issued "Saturday long ride" PUT-update the *same* intervals event
instead of duplicating — same idempotency story the strength export already
uses (`src/intervals.ts` `external_id` marker path).

---

## 5. The missing primitive: Claude → intervals endurance write

This is the **single highest-leverage piece.** Today Claude can read endurance
and write strength; it cannot place a swim or a ride. Everything else here is
plumbing around this.

### 5.1 New MCP tools

| Tool | Args | Effect |
|---|---|---|
| `schedule_endurance` | `{discipline: swim\|bike\|run, date, duration_min, target_load?, intensity?, title, description}` | Create a planned `/events` WORKOUT in intervals; write-through mirror into `external_events`; ledger row; audit + note |
| `update_endurance` | `{local_id, ...}` | PUT-update the same intervals event (idempotent via `intervals_ref`) |
| `cancel_endurance` | `{local_id}` | Delete/soft-cancel in intervals; tombstone the mirror |
| `set_endurance_schedule` | `{weekday → {discipline, duration, intensity} \| null}` | Convenience: recurring endurance pattern → expands to per-week `schedule_endurance` writes (intervals has no civil-weekday recurrence we rely on) |

`description` is **prose** in v1 (`"Swim 6×100 @ 2:30 w/ 20s rest, 200 easy"`).
A "have fun and finish" 75-year-old does not need Garmin-executable structured
steps; prose in the workout description is enough and an order of magnitude
less work. Structured-step DSL is a deferred non-goal (§11).

### 5.2 Write-through, not write-and-wait

`schedule_endurance` does **two** writes in one operation:
1. `POST /events` to intervals (the canonical store).
2. Upsert the resulting event into `external_events` immediately (the mirror),
   keyed `intervals:{external_id}` with `marker = tresfort:planned:{local_id}`.

So the holistic calendar is **instantly consistent** for anything Claude
schedules — no waiting for the 15-min cron. The cron (§8) then only matters for
changes that originate *outside* tres-fort. Generalize the existing export
client (`src/intervals.ts` `pushLoad`): same OAuth/Bearer header logic, same
idempotent-by-marker lookup, different `category/type` payload.

### 5.3 Unchanged: strength load still exports out

`session_load_exports` keeps pushing completed strength sRPE → intervals as a
`WeightTraining` activity. That's what lets intervals' Fitness/Fatigue/Form
include strength, making it the **unified aggregate** load store. Critically,
this export is a **reporting** concern only — the *planning* brain does not
consume that scalar back as gospel (§7).

---

## 6. The holistic calendar (still a projection)

The current calendar is single-activity-per-day (a lift template or rest),
computed by `projectCalendar`. Multisport changes two things: **days can hold
multiple activities** (a brick = bike + run; a lift + swim day), and **trips +
synced endurance are new inputs.** It stays *computed*, not stored.

### 6.1 Extended truth table (today-forward, per civil date)

Resolve each future day to a **composite** (a list of items + a status), not a
single winner:

```
day(date):
  trip = trips covering date
  if trip and not trip.can_train_light:  → { status: unavailable(trip.type), items: [] }

  items = []
  # strength
  real = sessions row for (user, date)            # explicit plan/skip
  if real and real.status != 'skip':  items += strength(real)
  elif not real and not trip:         items += strength(schedule[weekday(date)])   # rule, phase-aware §6.3
  # endurance (can coexist with strength — bricks, doubles)
  items += external_events for (user, date)        # Claude-authored or external, synced
  # result
  → { status: trip ? light(trip) : (items ? planned : rest), items }
```

Past (today-backward) is unchanged in spirit: real strength `sessions` +
completed `external_activities` (actuals) + logged `activities` — the union of
what actually happened.

### 6.2 Trips re-plan, they don't just blank days

Storing a trip is half the value; the brain reacting is the other half. On a
new/edited trip, Claude (not the backend): writes rest `sessions` rows across
the range, **moves** the week's key sessions (the long ride before departure,
the brick after return), adjusts load, and writes a note explaining it. The
projection then naturally reflects it. The trip object also lets Claude
*distinguish* travel-rest from a normal rest day when reasoning.

### 6.3 Phase-aware projection

"What's on a Saturday 3 months out" depends on **which phase** that date falls
in (a base-phase Saturday ride ≠ a build-phase Saturday brick). Two options;
the doc picks **(a)** for v1:

- **(a) Intent + near-term specifics (recommended).** Far-future days project
  from `schedule[weekday]` + the phase intent (the *kind* and rough load),
  deliberately unpinned. Specifics are filled in as each block approaches
  (§6.4). This matches how periodized coaching actually works — you don't pin
  October's Tuesday in May, and doing so would just be wrong by October.
- **(b) Phase-templated schedule.** `meta.schedule` becomes phase-keyed
  (`schedule.build['sat']`). More materialized structure; only worth it if
  users demand exact far-future specificity. Deferred.

### 6.4 Rolling near-term materialization — ~~proposed~~ **DROPPED (post-review)**

> Cut by the pressure-test. Committing future `sessions` + `external_events` rows
> is exactly the future-row-extruder §11 forbids, and `sessions` has **no
> soft-delete** — so re-planning a materialized block (the common case over 14
> months with travel and missed weeks) has no atomic teardown across
> `sessions` + mirrored `external_events` + the ledger + remote intervals events.
> It quietly breaks the "store truth, derive views" discipline the doc relies on.
>
> **Replacement:** for genuinely-decided near days, use the already-shipped
> `set_planned_session` (one concrete `sessions` row per decided day — the
> existing, tested override path); for everything else, the schedule projection
> (§6.1) already answers any date. No new materialization machinery.

### 6.5 iOS parity is now bigger

`projectCalendar` and `CalendarProjection.swift` must stay byte-for-byte (the
`test/calendar.test.ts` contract extends to the new truth table). **Two real
iOS changes:** (1) a day cell must render *multiple* items (strength +
endurance), and (2) endurance items are **read-only cards** — they show the
synced prose/metrics; execution happens on the watch. Keep the parity test as
the gate; add multisport fixtures (brick day, travel week, phase boundary).

---

## 7. Planning intelligence — multi-dimensional, not a load scalar

**Decision: the planner must never reduce training stress to one number.** A
single CTL/TSS figure treats 100 units of heavy squats and 100 units of Z2
spinning as interchangeable; they load different systems, recover on different
timelines, and *interfere* (concurrent strength+endurance), and running adds
impact that swim/bike don't. Two separate concerns, kept separate:

- **Aggregate / reporting** — intervals' Fitness/Fatigue/Form, fed by the
  strength export (§5.3). A coarse "is he globally overcooked" gauge. Useful,
  lossy, **not** the planning driver.
- **Planning** — Claude reasons over the `stress_model` (§4.4):
  - **Load by system, not one scalar:** aerobic / neuromuscular / impact
    dimensions per session (via `discipline_weights`).
  - **Interference-aware sequencing:** heavy lower-body ≥ ~48h from a key run
    or brick; no two high-neuromuscular days back-to-back; strength shifts
    hypertrophy → maintenance → minimal as the race nears (driven by
    `periodization[].strength_emphasis`).
  - **Age modifiers (75 yo):** more recovery, ≤2 true high-intensity
    sessions/week, conservative run-volume ramp (≤ ~8%/wk), joint-load caution,
    longer adaptation windows.
  - **Race logic:** bricks, peak, taper, all anchored to `meta.race.date`.

This is where tres-fort earns defensible IP — an **interference-aware,
age-aware concurrent-training planner** — rather than a TSS summer. The
`stress_model` is config (legible, tunable, versioned); the coach system prompt
references it so the reasoning is grounded in stored, inspectable rules.

---

## 8. Sync evolution (OAuth ≠ cadence)

Clarifying the recurring question: **OAuth is authentication, not sync
cadence.** It governs *whether* tres-fort may call intervals per user (shipped,
build 21, replacing the shared key). It does not change *how often* you poll.
The thing that would replace polling is **push (webhooks)** — already named as
the endgame in `wrangler.jsonc:36` ("interim measure pending intervals.icu
webhook"). Plan:

| Lever | Role | Status |
|---|---|---|
| **Write-through** (§5.2) | Claude-initiated changes are instantly mirrored | Primary — kills most latency without webhooks |
| **On-demand refresh** | Sync when iOS foregrounds / when Claude is asked to plan; `refresh_rides` already does this | Add foreground trigger |
| **15-min cron** | Backstop for externally-originated changes (watch-recorded actuals, edits in intervals' own UI) | Keep, lower urgency |
| **Webhooks** | True push for actuals | **Implemented** — `POST /webhooks/intervals` (`src/routes/webhooks.ts`). intervals.icu DOES expose outbound third-party webhooks via the Manage App page; the receiver reconciles the same idempotent caches the cron does, so it never replaces the cron — it just front-runs it. |

### 8.1 Webhook receiver (`POST /webhooks/intervals`) — shipped

intervals.icu POSTs a batch `{ secret, events: [{ athlete_id, type, … }] }`
whenever an athlete's data changes. The receiver:

- **Authenticates by body `secret`** (`== INTERVALS_WEBHOOK_SECRET`) — it is
  PUBLIC, NOT behind app-JWT / the MCP bearer. An unset secret makes it dormant
  (401s every request). An optional `INTERVALS_WEBHOOK_AUTH_HEADER` adds a
  second factor matching the page's "Webhook Authorization Header".
- **Always returns HTTP 200** on a valid secret (never 204 — intervals
  historically retried 204), with a tiny `{ ok: true }` body. Unknown
  athlete / type / empty batch are accepted gracefully.
- **Routes type → sync:** `CALENDAR_UPDATED` → `syncExternalEvents` +
  `syncExternalActivities`; `ACTIVITY_*` → `syncExternalActivities`;
  `WELLNESS_UPDATED` / `FITNESS_UPDATED` → accepted no-op (no fitness store
  yet — TODO). The work runs in `executionCtx.waitUntil` so the 200 returns
  fast.
- **Strava nuance:** intervals does NOT fire `ACTIVITY_*` for Strava-sourced
  activities — `CALENDAR_UPDATED` is the catch-all — so `CALENDAR_UPDATED`
  triggers BOTH syncs (the activities sync catches a Strava-routed completed
  ride).
- **Idempotent:** intervals can duplicate `CALENDAR_UPDATED` and delays
  `ACTIVITY_ANALYZED` ~60s. The (athlete, sync-kind) work is deduped per batch,
  and the underlying syncs are reconciled-cache writes — re-triggering is safe.

**Self-serve registration (Nick — one-time, on the intervals.icu side):**

1. Pick a strong secret and set it on the Worker:
   `wrangler secret put INTERVALS_WEBHOOK_SECRET` (paste the same value you'll
   enter on the page below).
2. On the intervals.icu **Manage App** page (`/oauth/client/431`), set the
   **Webhook URL** to `https://tres-fort.nmarkspdx.workers.dev/webhooks/intervals`
   and the **Webhook Secret** to the value from step 1.
3. Tick the event types: **CALENDAR_UPDATED**, **ACTIVITY_ANALYZED**,
   **WELLNESS_UPDATED**, **FITNESS_UPDATED** (the last two are accepted no-ops
   today but future-proof the registration).
4. (Optional) set a "Webhook Authorization Header" on the page and mirror it
   with `wrangler secret put INTERVALS_WEBHOOK_AUTH_HEADER`.

Once registered, the 15-min cron stays as a backstop but most actuals land in
seconds instead of up to 15 minutes.

**Token-expiry risk (R3).** `intervalsAuth.ts:92` notes refresh/expiry are
"not documented — tokens appear long-lived." If they *do* expire, the per-user
cron silently dies. Handle `401 → mark disconnected → prompt re-connect` in the
sync loop regardless of apparent immortality.

---

## 9. MCP surface additions (summary)

New write tools: `schedule_endurance`, `update_endurance`, `cancel_endurance`,
`set_endurance_schedule` (§5.1); `set_race`, `set_periodization`, `add_trip` /
`update_trip` / `remove_trip` (write `plans.meta.*`, versioned, audit + note).
New read surface: `get_today_workout` / `get_state` projections become
**composite** (strength + endurance + trip status per day); a `get_fitness`
read pulls intervals' Form/Fatigue for the aggregate gauge. Every write keeps
the `audit_log` + Claude-authored `notes` trail (`DESIGN.md` §5) — the
single-user substitute for per-tool scopes.

---

## 10. Milestones (with test gates) — revised post-review

Build order **corrected**: the endurance write bridge (old M1) is the riskiest,
least-verified, most-coupled primitive, so it moves **last**. Cheap, safe,
durable structure and the shipped-bug fix come first.

| # | Deliverable | Pass when |
|---|---|---|
| **M0** | Connection chain + premise spikes | Athlete's watch data lands in intervals.icu (via Garmin/Strava); intervals↔tres-fort OAuth round-trips; R1 run/swim `POST /events` fixture captured; CTL-from-strength-export empirically confirmed **or** the load model revised |
| **M1** | Intervals auth hardening (shipped-bug fix) | `grant_type=refresh_token` exchange implemented; `401 → mark disconnected + iOS reconnect prompt` in `syncExternal*`; no silent cache freeze. Independent of the rest — ship first |
| **M2** | Durable `meta.*` structure: `race`, `periodization`, `trips`, `stress_model` + `set_*` tools | Plan carries A-race/phases/trips/stress_model; versioned; rides `/api/state`; far-future day projects phase-appropriate intent; trip range → re-plan + note. No external-API risk |
| **M3** | Per-user Claude MCP | Dad's bearer/OAuth resolves to *his* `user_id`; his chat reads/writes only his data; owner-isolation tested |
| **M4** | Holistic composite calendar + iOS surface | `projectCalendar` returns multi-item days incl. a `source`/provenance marker; `detectConflicts` distinguishes an intended brick from a real clash; `test/calendar.test.ts` green with brick/travel/phase fixtures; iOS renders strength+endurance, endurance read-only |
| **M5** | Endurance write bridge: `schedule_endurance` + write-through + `planned_event_exports` | **Only after M0 #1–#2 settle.** "Put a 90-min Z2 ride Saturday" → intervals has it AND the mirror (keyed on the returned id) survives the next cron; re-issue PUT-updates, no dup; a failed POST never leaves a canonical-looking mirror |

**M0 may conclude the write bridge isn't worth building yet** — verbal
coordination off the reads (M2–M4) covers the dad's first mesocycle. Graduate to
M5 only when a real pain point justifies the API coupling.

---

## 11. Non-goals (explicitly out of scope)

- **Rebuilding intervals' execution.** No Garmin/watch sync, no structured-step
  workout DSL in v1 — prose descriptions only. Revisit only if a user needs
  on-watch guided intervals.
- **A second writable cardio store.** Endurance truth stays in intervals;
  tres-fort mirrors read-only. Never invert this.
- **A materialized weeks/calendar table.** The calendar is derived; only the
  bounded current-mesocycle materialization of §6.4 exists.
- **Multi-athlete tri coaching.** Designed per-user-clean, but the dad case is
  one athlete; group endurance feeds are a separate concern.
- **Backend periodization logic.** Phases/load are Claude's reasoning over
  stored intent; the backend faithfully stores and projects, it does not
  compute training science (`DESIGN.md` §2).

---

## 12. Open questions & risks

- **R0 — onboarding / connection chain (NEW, highest).** The athlete has a watch
  but is not on intervals.icu, and is not yet a Claude user. The
  watch→intervals→tres-fort + adopt-Claude chain is the true prerequisite;
  nothing downstream works until it is solid. *High — gates M0.*
- **R1 — intervals `POST /events` shape for run/swim AND the CTL round-trip.**
  Only the `WeightTraining` shape is verified (`intervals.ts:470`). Spike both
  before M5; confirm a *planned* event's `icu_training_load` actually feeds CTL.
  *Verify with intervals API docs / david@intervals.icu.* **High — gates M5.**
- **R2 — webhook availability.** If intervals exposes no outbound third-party
  webhook, write-through + on-demand pull is the ceiling (acceptable). *Med.*
- **R3 — intervals token refresh/expiry — NOT HANDLED (re-rated Low/Med → HIGH).**
  No `refresh_token` exchange exists; a 401 silently freezes the cache with no
  disconnect signal (`intervalsAuth.ts:104`, `syncExternal*`). Fix in M1. *High.*
- **R4 — composite-day iOS parity + provenance.** Richer truth table; the Swift
  re-impl and the new `external_events` `source` column must stay in parity.
  *Med — test-guarded.*
- **R5 — committed vs. projected legibility.** UI must distinguish pinned days
  from light projection (`CalendarCell.projected` already exists). *Low.*
- **R6 — load semantics (not integrity).** Exported strength shows in intervals'
  CTL *and* in `stress_model`; the planner must read them in their roles
  (aggregate gauge vs. per-system planning), not additively. Cache integrity is
  already handled by `isTresFortExport`. *Low/Med.*
- **R7 — per-user MCP (NEW).** "Dad chats directly" requires `/mcp` to resolve to
  his user, not the single owner (DESIGN.md §6). On the critical path at M3. *Med.*

---

## 13. One-paragraph summary

Keep intervals.icu as endurance truth and the unified load gauge; keep
tres-fort as strength truth, the holistic *projected* calendar, and the iOS
strength executor; keep Claude as the brain that writes strength into tres-fort
and endurance into intervals and reasons over the merge. The new build is one
write primitive (`schedule_endurance`, write-through), a composite calendar
projection, durable `meta.*` structure for races/phases/trips, and a
multi-dimensional stress model so planning never blindly follows a
lifting→load scalar. Everything stays inside the existing consistency classes:
store authored truth, derive the calendar.
