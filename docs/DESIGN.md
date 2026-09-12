# tres-fort — Design Doc

> Claude is the coach. It adapts the shared plan through conversation; members
> can also author reusable workouts and workout dates directly in iOS.
> You execute and log in a native iOS app. A Cloudflare backend is the
> single source of truth that both Claude (via MCP) and the app read/write.

Status: **IMPLEMENTED** — all milestones (a–i) shipped; intervals.icu
integration, groups/invites (M1/M2), and multisport (endurance) coaching
added post-milestone.
Date: 2026-07-30 · Owner: Nick · Apple Developer Program: **Active** ·
Claude surface: all (auth designed OAuth-capable with static-bearer fallback).

Project name `tres-fort` (originally scaffolded as `lift-coach`).

---

## 1. Architecture

```
            ┌───────────────────────────────────────────┐
            │        Cloudflare Worker (ONE worker)      │
            │                                            │
  Claude ──►│  /mcp     MCP (Streamable HTTP)            │
 (any chat) │           OAuth 2.1  OR  static bearer  ───┤──► D1 (SQLite)
            │                                            │   plans / templates
  iOS app ─►│  /api/*   REST, app-JWT (Sign in w/ Apple) │   sessions / sets
 (SwiftUI)  │                                            │   notes / audit
            │  shared service layer + D1 binding         │
            └───────────────────────────────────────────┘
```

Both clients hit the same service layer over the same D1 database. The plan
is a versioned document; sets/notes/sessions are an append-only event log.
That split is what makes two-writer sync simple (§7).

---

## 2. Stack evaluation — what's right, what I'm pushing back on

| Decision | Verdict |
|---|---|
| Cloudflare Workers + D1 as source of truth | ✅ Correct. SQLite semantics and MCP-from-Worker remain the natural fit. The account moved to Workers Paid on 2026-09-05 after a natural hourly cron exceeded Free's CPU target; the delta and no-op work still reduce latency and usage. |
| CloudKit rejected for source of truth | ✅ Agree. Claude needs first-class writes from outside Apple's ecosystem; CloudKit S2S is awkward and Apple-bound. The current client uses account-scoped JSON snapshots and in-memory presentation; SwiftData was an early proposal. |
| **Two separate Workers (REST + MCP)** | ⚠️ **Pushing back → one Worker, two route groups** (`/api/*`, `/mcp`). They share the D1 binding, schema, domain model, and service layer. Splitting doubles deploy/secret/observability surface for zero isolation benefit in a single-user system. Splitting later is a routing change, not a rewrite. |
| MCP auth = "bearer token in connector settings" | ⚠️ **Refining.** Fine for Claude Code; claude.ai/desktop custom connectors expect OAuth. Plan: implement a lightweight Cloudflare OAuth provider **and** accept a static bearer. Every surface works; CLI/curl testing stays trivial. (§6) |
| Original SwiftData sync proposal | Superseded by account-scoped snapshots and durable client-UUID outboxes in UserDefaults; current ordering and retry behavior are described in §7. |
| Rich plan schema for periodization | ⚠️ **Right-sizing.** Periodization stays **out of rigid columns**. Progression/deload/mesocycle live in a per-exercise `progression` JSON + Claude-written notes. Claude is the periodization engine; the schema just faithfully stores and versions its decisions. |

Net new spend: **$5/month + usage** for Workers Paid — Apple Developer is
already covered and the domain is owned.

---

## 3. D1 schema

Epoch-ms integers for timestamps. `id` is a UUID string. Plan-tree tables
(`plans`, `workouts`, `template_exercises`) are the versioned document;
`set_logs`/`notes`/`sessions` are the append-only log.

This excerpt shows the post-rollout logical application schema. Migration
`0034` physically adds `set_logs.user_id DEFAULT ''`,
`set_logs.updated_at DEFAULT 0`, and `activities.updated_at DEFAULT 0` so the
previous Worker remains compatible between migration and deploy; D1-clock
backfills and narrow compatibility triggers ensure application-visible rows do
not retain those placeholders.

```sql
CREATE TABLE users (
  id            TEXT PRIMARY KEY,
  apple_sub     TEXT UNIQUE NOT NULL,      -- Apple stable subject
  email         TEXT,
  display_name  TEXT,
  created_at    INTEGER NOT NULL
);

CREATE TABLE exercises (                    -- catalog
  id                TEXT PRIMARY KEY,
  name              TEXT NOT NULL,
  primary_muscle    TEXT NOT NULL,          -- 'quads','chest','back',...  (volume grouping)
  secondary_muscles TEXT,                   -- JSON array
  modality          TEXT,                   -- 'barbell'|'dumbbell'|'machine'|'bw'
  unit              TEXT NOT NULL DEFAULT 'lb',
  aliases           TEXT,                   -- JSON array: ["squat","back squat"] (MCP name resolver)
  created_at        INTEGER NOT NULL
);

CREATE TABLE plans (
  id          TEXT PRIMARY KEY,
  user_id     TEXT NOT NULL REFERENCES users(id),
  name        TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'active',   -- 'active'|'archived' (one active/user)
  version     INTEGER NOT NULL DEFAULT 1,       -- bumped on ANY plan-tree mutation; sync cursor + optimistic concurrency
  meta        TEXT,                             -- JSON: mesocycle notes, deload scheme, default unit
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);

CREATE TABLE workouts (
  id          TEXT PRIMARY KEY,
  plan_id     TEXT NOT NULL REFERENCES plans(id),
  name        TEXT NOT NULL,                    -- "Lower A"
  day_label   TEXT,                             -- "A","Push","Wed"
  order_index INTEGER NOT NULL,
  notes       TEXT,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);

CREATE TABLE template_exercises (
  id               TEXT PRIMARY KEY,
  workout_id  TEXT NOT NULL REFERENCES workouts(id),
  exercise_id      TEXT NOT NULL REFERENCES exercises(id),
  order_index      INTEGER NOT NULL,
  target_sets      INTEGER NOT NULL,
  target_reps      INTEGER NOT NULL,            -- bottom of range
  target_reps_max  INTEGER,                     -- top of range (double progression); NULL = fixed
  target_rpe       REAL,
  rest_seconds     INTEGER NOT NULL DEFAULT 120,
  group_id         TEXT,                        -- migration 0044; caller-generated UUID shared by adjacent members
  group_rest_seconds INTEGER,                   -- rest after a round; ordinary rest_seconds stays intact
  group_transition_seconds INTEGER,             -- rest between members, normally 0
  target_weight    REAL,                        -- current working weight; Claude advances this
  progression      TEXT,                        -- JSON, see below
  cues             TEXT,                        -- form-cue reminders Claude sets
  is_warmup        INTEGER NOT NULL DEFAULT 0,  -- 1 = prescribed warm-up slot (erg, mobility); migration 0026
  created_at       INTEGER NOT NULL,
  updated_at       INTEGER NOT NULL
);
-- progression JSON example:
-- {"type":"double","increment":5,"unit":"lb",
--  "rule":"top_set_reps >= target_reps_max for 2 consecutive sessions"}
-- type ∈ linear|double|rpe|manual — interpreted by Claude, not enforced by backend.

CREATE TABLE sessions (
  id                TEXT PRIMARY KEY,
  user_id           TEXT NOT NULL REFERENCES users(id),
  plan_id           TEXT NOT NULL REFERENCES plans(id),
  workout_id   TEXT REFERENCES workouts(id),   -- NULL = unpinned (status/schedule decide rest)
  date              TEXT NOT NULL,                        -- 'YYYY-MM-DD' device-local
  status            TEXT NOT NULL DEFAULT 'planned',      -- planned|in_progress|completed|skipped
  started_at        INTEGER,
  completed_at      INTEGER,
  perceived_fatigue INTEGER,                               -- optional 1–10
  runner_targets   TEXT,                                  -- migration 0043; starting target snapshot
  notes             TEXT,
  created_at        INTEGER NOT NULL,
  updated_at        INTEGER NOT NULL
);

-- Migration 0029 reconciles legacy duplicate (user_id,date) rows. A client
-- may still hold a deleted duplicate id while that migration rolls out, so
-- mutation endpoints resolve it through this durable, tenant-checked alias.
CREATE TABLE session_aliases (
  alias_session_id     TEXT PRIMARY KEY,
  canonical_session_id TEXT NOT NULL REFERENCES sessions(id)
);

CREATE TABLE set_logs (
  id                   TEXT PRIMARY KEY,        -- CLIENT-generated UUID = idempotency key
  user_id              TEXT NOT NULL,           -- denormalized owner for member-first delta reads (migration 0034)
  session_id           TEXT NOT NULL REFERENCES sessions(id),
  exercise_id          TEXT NOT NULL REFERENCES exercises(id),
  template_exercise_id TEXT REFERENCES template_exercises(id),  -- link to plan slot
  set_index            INTEGER NOT NULL,
  weight               REAL NOT NULL,
  reps                 INTEGER NOT NULL,
  rpe                  REAL,
  is_warmup            INTEGER NOT NULL DEFAULT 0,
  notes                TEXT,
  logged_at            INTEGER NOT NULL,
  updated_at           INTEGER NOT NULL,        -- server-owned mutable sync cursor
  source               TEXT NOT NULL,           -- 'ios'|'mcp'
  deleted_at           INTEGER                  -- soft delete (never hard-delete logged data)
);

CREATE TABLE notes (                            -- Claude's coaching reasoning, durable
  id         TEXT PRIMARY KEY,
  user_id    TEXT NOT NULL REFERENCES users(id),
  scope      TEXT NOT NULL,                     -- plan|session|exercise|general
  ref_id     TEXT,
  author     TEXT NOT NULL,                     -- claude|nick
  body       TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE audit_log (                        -- every MCP write, for trust/undo
  id         TEXT PRIMARY KEY,
  user_id    TEXT NOT NULL,
  actor      TEXT NOT NULL,                     -- mcp|ios
  tool       TEXT NOT NULL,
  args       TEXT,                              -- JSON
  result     TEXT,
  created_at INTEGER NOT NULL
);

CREATE INDEX ix_sets_session ON set_logs(session_id);
CREATE INDEX ix_sets_user_updated ON set_logs(user_id, updated_at);
CREATE INDEX ix_sets_user_ex_time ON set_logs(user_id, exercise_id, logged_at);
CREATE INDEX ix_sessions_user_updated ON sessions(user_id, updated_at);
CREATE INDEX ix_audit_user_actor_created ON audit_log(user_id, actor, created_at);
-- oauth_tokens is defined by the OAuth migrations and omitted above.
CREATE INDEX ix_oauth_tokens_user ON oauth_tokens(user_id);
CREATE UNIQUE INDEX ux_session_user_date ON sessions(user_id, date);
CREATE INDEX ix_te_workout ON template_exercises(workout_id, order_index);
```

Migration `0034` also creates
`ix_activities_user_updated ON activities(user_id, updated_at)`; the manual
activities table is outside this abbreviated schema excerpt.

Migration `0035` adds `external_events(user_id, synced_at)` and
`external_activities(user_id, synced_at)` cursor indexes. They keep empty P2
external-cache deltas member-first and constant-cost; each real mutation pays
one additional indexed row write, while a conditional no-op pays none.

Migration `0036` replaces the cross-member exercise/time index with
`set_logs(user_id, exercise_id, logged_at)` and adds member-first indexes for
the profile's `audit_log(user_id, actor, created_at)` and
`oauth_tokens(user_id)` lookups. Exercise reads still require the joined
session to have the same `user_id`, preserving that authoritative ownership
check while the denormalized set owner drives the index seek.

Periodization note: no `mesocycles`/`weeks` tables. Deloads, wave loading,
and block changes are Claude editing `target_*`/`progression` and writing a
`notes` row. That's the flexible-without-overengineered line.

---

## 4. REST API (iOS, `Authorization: Bearer <appJWT>`)

| Method · Path | Purpose |
|---|---|
| `POST /auth/apple` | Body `{identityToken, authorizationCode?, fullName?}` → `{jwt, user}`. Verifies Apple JWT and resolves the caller. When the native client supplies Apple's single-use code, the route reserves that caller against concurrent deletion, exchanges the code, verifies the returned `id_token` has the same Apple subject, and stores only the caller-scoped refresh token before issuing the app JWT. Storage retains the exact reservation until a second acknowledgement, so a D1 commit whose response is lost can still become sticky revocation uncertainty. Code omission remains compatible with older clients. |
| `GET /api/state?since=<planVersion>&sets_since=<epochMs>&events_since=<epochMs>&activities_since=<epochMs>&log_since=<epochMs>` | **The sync pull.** Returns `{plan: tree|null, plan_version, plan_groups_version?, external_sync_cursors_version, sessions[], sets[], external_events[], external_activities[], activities[], server_time}`. `plan` is null when `version <= since`; otherwise the full small tree. A zero collection cursor requests a complete current snapshot; an active cursor returns changes plus tombstones. P2 Workers return `external_sync_cursors_version: 2`; compatible clients activate the external cursors only for version 2 or later. `server_time` is captured at request start. Called on launch/foreground/post-write. |
| `GET /api/today` | Today's session (created from today's template if absent) + its sets + per-exercise last-time actuals + suggested weight. |
| `POST /api/sessions` | `{date, workout_id?}` → create/start session. |
| `PATCH /api/sessions/{id}` | `{status?, perceived_fatigue?, notes?}` plus the existing attempt guard. A completed acknowledgement includes an optional persisted `summary`; a summary failure cannot revoke completion. |
| `GET /api/sessions/{id}/summary` | Owner-scoped persisted work, comparable records, and differences from starting targets. Discarded or unowned sessions return 404. |
| `POST /api/sessions/{id}/sets` | Idempotent on body `id`. `{id, exercise_id, set_index, weight, reps, rpe?, is_warmup?, notes?, logged_at}` with existing slot/timed/attempt context and optional `prescription: {plan_id, version, day_id}` from the plan shown at the tap. |
| `PATCH /api/sets/{id}` | Edit / soft-delete a set. Runner corrections supply all of `expected_session_id`, `expected_attempt`, `expected_updated_at`; stale competing changes return 409. Guarded success returns the flat set row plus its authoritative `session`. Legacy callers retain the flat row response. |
| `GET /api/history?exercise_id=&from=&to=` | Set history + comparisons by exercise/mode/external load; conventional rep Epley only. |
| `GET /api/volume?muscle=&from=&to=` | External-load volume grouped by unit, logged working sets (legacy `hard_sets` alias), primary-muscle attribution and recorded-effort coverage per week bucket. |
| `GET /api/me/export` | Download the signed caller's portable account and training-data snapshot as a non-cacheable JSON attachment. Excludes credentials, tokens, invite capabilities, and other members' private data. |
| `DELETE /api/me` | Permanently delete the signed caller after explicit in-app confirmation and recent Apple authentication. A UUID-bound intent serializes provider revocation and local deletion; a durable receipt makes a lost success response safe to acknowledge. The response reports `apple_revocation: revoked|manual_required`; provider failure, legacy accounts without a stored token, or an uncertain exchange never retain local data and instead trigger the manual Apple Account handoff. |
| `PUT /api/plan/active` | Idempotently ensure an active plan for manual authoring. Returns the existing winner on retry/concurrent coach creation and never archives it; explicit plan replacement archives and inserts atomically so the two creation paths cannot violate the one-active-plan invariant. |
| `POST /api/workouts` | Add a workout day; omitted `order_index` appends densely. The first-day flow pins both `expected_plan_id` and `expected_version` to the plan returned by `PUT /api/plan/active`; app and MCP adds use the same atomic plan-version writer. |
| `PATCH /api/workouts/{id}` | `{name?, day_label?, order_index?, notes?, expected_version?}` — rename/reorder a day through the same atomic plan-version writer as MCP. |
| `DELETE /api/workouts/{id}?expected_version=` | Remove a day and scrub its recurring assignments. Completed history is detached, direct or same-plan schedule-resolved planned sessions become explicit rest, and removal is rejected while that day has a direct, same-plan schedule-resolved, or locally running workout. |
| `POST /api/workouts/{id}/exercises` | Add an exercise slot (incl. `is_warmup`, `target_duration_s`). |
| `PATCH /api/workouts/{id}/exercises/{teId}` | Edit one slot in place (targets / rest / warm-up flag / order). |
| `POST /api/workouts/{id}/exercises/{teId}/swap` | `{to_exercise, expected_version}` — replace the exact caller-owned active slot, preserving its saved prescription, position, warm-up flag, and identity. Invalid carried targets return 400; a stale plan version returns 409. Historical sets retain their original exercise and values. |
| `POST /api/sessions/{id}/exercises/{teId}/swap` | `{to_exercise, expected_attempt, expected_version, expected_revision}` — replace one exercise for the observed session attempt. Persist original and replacement slot snapshots in `sessions.exercise_swaps`; preserve the recurring plan, existing sets and group position. Only the same rep/timed measure is accepted. Clear exercise-specific load, cues and progression; the runner seeds the replacement from its own comparable history. |
| `DELETE /api/workouts/{id}/exercises/{teId}` | Remove a slot; detaches (NULLs) historical `set_logs.template_exercise_id`. |
| `PUT /api/workouts/{id}/groups` | `{group_id, exercises:[slot IDs], expected_version, round_rest, transition_rest?, target_sets?, order_index?}` creates or rewrites a group; optional `order_index` moves the complete block. Send `exercises:[]` with only `group_id` and `expected_version` to ungroup. Uses the same atomic, audited service as MCP. An exact acknowledged retry returns the original result before stale-version rejection, without reapplying a superseded grouping. |
| `PUT /api/plan/schedule` | Replace the recurring weekday → day/rest map with optimistic concurrency on both `expected_plan_id` and `expected_version`. |
| `POST /api/calendar/{date}/move` | Move one projected or unstarted workout to an empty date. The request pins the workout, active plan/version, both observed attempts and a caller UUID. Source rest, destination assignment and audit receipt commit atomically. Both attempts advance; an identical retry returns its original acknowledgement. A concurrent change to either date or the weekly schedule rejects the whole move. |
| `PUT /api/calendar/{date}` | Assign one concrete date to a day (`workout_id`) or rest (`null`) without changing the recurring schedule or plan version. `expected_attempt=0` represents no observed assignment; the first assignment and every changed choice advance the session attempt, while an identical retry is idempotent. Started/completed sessions cannot be reassigned, and iOS also fences the mutation against a locally running workout before its first set creates the server session or a hard travel blackout. |

Canonical routes use `/api/workouts`; `/api/days` remains an alias for one
TestFlight compatibility cycle. Plan responses carry `workouts` plus deprecated
`days`; workout references carry `workout_id` plus `day_template_id`. Requests
accept either and reject conflicting dual fields. MCP registers `add_workout`,
`update_workout` and `delete_workout`, retaining `add_day` and `update_day` during
the cycle. Export schema v2 preserves `training.day_templates` alongside
`training.workouts`. Snapshot schema v2 uses `workouts`; immutable v1 documents
remain readable/restorable without rewriting history. The first iOS build reads
both vocabularies and sends the old one. See the [server-first rollout](plans/workouts-and-multi-session/rollout.md)
for the physical-schema transition and the later outgoing-client switch.

In-app manual authoring uses the same `plans` / `workouts` /
`template_exercises` tree and `plans.meta.schedule` that MCP uses. The Workouts
screen creates and orders days, edits exercise prescriptions, and maps weekdays;
the calendar writes only concrete `sessions` exceptions. These REST endpoints
are thin wrappers over the shared service layer and audit as `actor='ios'`.
Every recurring plan-tree write bumps `plans.version`; one-date exceptions do
not.

Plan writes share runtime prescription validation and a D1 transaction that
commits the mutation, order normalization, version, audit and full-document
snapshot together, plus the coaching note for MCP plan writes. Legacy slot
patches retain their existing input shape: they retry a bounded version
conflict against fresh state and validate the merged prescription. Explicitly versioned edits return
a conflict for the caller to review. See the
[prescription contract](plans/completed/prescription-integrity/decisions.md).

Supersets and circuits have at least two contiguous members in one day, sharing
one set count and both group rest values. Group fields, set count and ordering
are group-owned; single-slot writes cannot change them while grouped. Removing
a member dissolves a remaining singleton. The common validator also covers
rebuilds, swaps, recurring adjustments and snapshot restore. Grouping leaves
ordinary `rest_seconds` intact, and snapshots preserve all three nullable fields.
Clients declare `groups` in `X-TresFort-Capabilities` to receive stored plan
values. Group-capable state responses advertise `plan_groups_version: 1` so
an upgraded app can distinguish a full canonical plan from its old sequential
cache even when the plan version has not changed. Without the request capability,
state/active-plan reads and the embedded restore plan omit
group fields and project round rest onto every member's ordinary rest. MCP
receives canonical values with A1/A2 annotations and both rests in coach reads.
See the [grouping contract](plans/completed/supersets-and-circuits/decisions.md) for the
versioned write and retry details.

Migration `0040` adds `plan_snapshots`. A legacy plan's first accepted edit
captures its actual previous version and the resulting version; earlier history
is not reconstructed. Snapshots contain writable plan fields, schedule and
metadata, without catalog enrichment. History and comparison resolve exercise
names from the catalog when read. `GET /api/plan/history` lists versions;
`GET /api/plan/history/:version/compare?to_version=current` compares a selected
version with a pinned target. `POST /api/plan/history/:version/restore` requires
`expected_plan_id` and `expected_version`, restores as a new version, and rejects
stale/foreign history or an active workout. Logged set values remain history;
restore does not resurrect detached historical references. Account export schema
version 2 includes snapshots, and account deletion removes them. See the
[snapshot contract and release boundary](plans/completed/reversible-plan-management/decisions.md).

---

### Workout-only exercise substitutions

Migration `0050_session_exercise_swaps.sql` adds nullable `sessions.exercise_swaps`
JSON with an attempt, monotonic swap revision and per-slot original/replacement
snapshots plus the movements performed for that slot. The session attempt and
plan version are checked at the write boundary; the session update and iOS audit
commit in one protected D1 batch. A stale picker returns 409. The recurring plan
version and historical set rows do not change. Swaps ride ordinary session deltas,
account export and local snapshot/acknowledgement ordering. An envelope from an
older attempt is inactive after restart, reassignment or calendar movement.

The runner projects a replacement only while its original slot still matches the
current prescription. It counts accepted and pending sets for the explicitly
approved movements against that one slot, preserving progress across a mid-round
swap without conflating duplicate movement slots. Each new set keeps the actual
exercise ID; history and summary continue to use the persisted set values.
The picker is searchable, ranks the same primary muscle first and states its
workout-only scope. Finish/stop an active timed set before swapping. Saving a swap
requires connectivity; ordinary set logging retains its existing offline queue.
A saved substitution can resume even before the first set is logged.

Release requires separate authority: apply migration 0050, deploy the reviewed
Worker, verify its session-swap route and only then distribute the iOS build.
Retain the existing workout rename compatibility gates. No production or app
release is implied by repository delivery.

## 5. MCP server — the product

Transport: remote MCP over Streamable HTTP at `/mcp`. Thin wrappers over the
same service layer as REST. All natural-language exercise args run through an
alias resolver (case-insensitive + `exercises.aliases`).

**Resource (auto-loaded at chat start)** — `coach://state/current`: compact
JSON+markdown brief = active plan summary, today's planned workout, last
completed session's key lifts, recent fatigue notes, trailing 7/28-day
volume. Also exposed as prompt template `coach_brief`. This is what keeps
Claude context-aware with zero tool calls.

**Read tools**
- `get_current_plan()` → full plan tree (templates, slots, progression, cues).
- `get_today_workout()` → resolved today session: targets + last actuals + suggested working weight.
- `get_current_session()` → in-progress session + sets so far.
- `get_session_log({date?, recent_n?})` — includes the same persisted completion
  summary used by iOS; no independent coach-side PR calculation.
- `get_history({exercise, range?:"30d|90d|all", limit?})`
- `get_volume_trend({muscle_group, range?:"8w|12w|6mo", bucket?:"week"})`
- `get_plan_history({limit?, before_version?})` and
  `compare_plan_versions({from_version, to_version?})` expose shared app/coach history.

**Write tools**
- `log_set({exercise, weight, reps, rpe?, is_warmup?, session_date?, notes?})` → auto-creates session, appends, returns running summary.
- `log_workout_complete({session_date?, perceived_fatigue?, notes?})`
- `discard_workout({session_id, expected_attempt})` → discard the explicitly
  selected owned session attempt and soft-delete its logged sets through the
  same service as the app. Requires an explicit user request; never defaults
  to today, creates a session, or substitutes completion. A stale attempt is
  rejected, and an identical retry adds no second discard audit.
- `add_note({scope, ref_id?, body})`
- `update_plan({name?, meta?, days, expected_version?})` → transactional upsert; a version mismatch returns structured `{conflict:true,current_version}` data in a normal JSON-RPC HTTP 200 response (Claude refetches + reapplies). The version is required when the current tree contains groups or the request explicitly supplies group fields, including nulls.
- `update_exercise({target, patch})` → one slot (`target` = template_exercise_id or {day, exercise}).
- `group_exercises({day, group_id, expected_version, exercises, round_rest, transition_rest?, target_sets?, order_index?})` → create/rewrite or move a group atomically. Use a caller-generated UUID and slot IDs for durable retries; unambiguous exercise names/aliases are also accepted.
- `ungroup_exercises({group_id, expected_version})` → clear every member's group fields while preserving ordinary rests, through the same version and exact-retry boundary.
- `swap_exercise({day, from_exercise, to_exercise})` — always preserves saved targets; validates them against the destination modality. The formerly ignored `carry_targets` option is no longer advertised.
- `add_exercise({day, exercise, target_sets, target_reps, target_reps_max?, rest_seconds?, target_rpe?, progression?, order_index?})`
- `add_day({name, day_label, order_index?, exercises?})`  ← "add a deadlift day"
- `adjust_today({intent:"deload|reduce_volume|reduce_intensity", magnitude?, day_label?})`
  changes recurring workout targets persistently; omitting a day affects the
  whole plan. Results name affected workouts, before/after changes and no-ops.
- `restore_plan({plan_id, snapshot_version, expected_version, reason?})` restores
  a reviewed snapshot as a new version with an atomic audit and coaching note.

Every accepted mutation writes `audit_log` and (for plan changes) a `notes` row, so
you can always see and undo what Claude did.

---

## 6. Auth — the hard one

Same identity (you), **two credentials**, one `user_id`. Different threat
models, lifecycles, and revocation paths → decoupled on purpose.

**iOS → Worker JWT (Sign in with Apple)**
1. App: `ASAuthorizationAppleIDProvider` → `identityToken` (Apple-signed JWT), a single-use authorization code, a local credential identifier, and name (first auth only). The client requires and forwards the code without persisting it.
2. `POST /auth/apple`. Worker: fetch/cache Apple JWKS, verify signature + `iss=appleid.apple.com` + `aud=<bundle id>` + `exp`; extract `sub`; resolve or create the corresponding user (with `OWNER_APPLE_SUB` anchoring the distinguished owner when configured). For a supplied code, a durable caller-bound reservation closes the D1 → Apple → D1 race; the Worker exchanges the code and re-verifies the returned subject. Token storage and reservation acknowledgement are separate D1 phases: storage retains the exact reservation, acknowledgement clears it, and any ambiguous store can therefore be marked as sticky uncertainty before deletion proceeds.
3. Only after that exchange finishes, the Worker issues an app JWT (HS256, `APP_JWT_SECRET`, `sub=user_id`, ~60-day exp, original `auth_time`) → app stores it in **Keychain**. Authentication responses contain only the public user projection.
4. Refresh: near expiry, the app exchanges a still-valid bearer for another ~60-day JWT that preserves `auth_time`, capped at a 180-day absolute session lifetime. Expiry, revocation, or that ceiling requires Sign in with Apple again. Initial account deletion additionally requires an Apple authentication no more than five minutes old, claims a key-bound intent before provider I/O, and blocks ordinary app/MCP/OAuth credentials until local deletion commits. A known caller refresh token is revoked through Apple; missing configuration/token, provider failure, or prior exchange uncertainty completes local deletion with `manual_required` instead.

**MCP → dual acceptance on `/mcp`** (resolves your "one token? scopes? rate limits?")
- (a) **OAuth 2.1** for claude.ai/desktop custom connectors — a minimal in-Worker provider (`src/oauth.ts`). The `/oauth/authorize` step is gated by a passphrase: the **owner** uses `OWNER_AUTH_PASSPHRASE`, any other user a personal MCP passphrase (PBKDF2-SHA256, per-user salt) set via `POST /api/me/mcp-passphrase`. On match it binds that `user_id` into the auth code and issues short-lived access tokens (also carrying the `user_id`) the Worker validates.
- (b) **Static bearer** for Claude Code / curl / milestone-b testing — `Authorization: Bearer <MCP_STATIC_TOKEN>` (Worker secret).
- **Resolution (M3, migration `0025`).** Static bearer → the owner. OAuth token → the user it was bound to at `/oauth/authorize`. Tokens issued before M3 carry no `user_id` and resolve to the owner (back-compat), so already-connected claude.ai sessions keep working as the owner without re-auth.
- **Atomic coach grants (migration `0041`).** Validated authorization-code
  consumption and refresh rotation each commit with their sole successor.
  Consumed refresh hashes retain grant-family lineage; bound-client replay
  revokes the surviving successor of that family. Profile lists and disconnects
  caller-owned grants without changing workout data. Changing a connect code
  affects future authorization; it does not disconnect existing grants.
  Migration `0042` adds an initially disabled policy: 90 elapsed days without
  successful refresh and a 365-day absolute maximum. Explicit atomic activation
  starts both clocks for existing authorized grants. New authorizations start
  their own clocks; renewal slides only inactivity and never revives an expired
  or revoked grant. Access tokens remain capped at 30 days and must also satisfy
  the grant deadlines. Static bearers and Apple/app sessions remain separate.
  A lost successful exchange response requires
  reauthorization. See the [coach contract](plans/completed/coach-access-integrity/decisions.md).
- **No per-tool scopes.** Per connected user there is one principal → scopes would add complexity with little security gain at this scale. The trust substitute is the per-user `audit_log` + Claude-written notes (visible, reversible).
- **Rate limit:** soft cap (~600 req/min) via a Cloudflare rate-limit rule on `/mcp` or a KV counter — a runaway-loop guard, not a security boundary. Optional-but-recommended for v1.

Risk R1: claude.ai/desktop connector auth specifics may differ at build
time. Mitigation: the static-bearer path is a guaranteed fallback; verify
the OAuth path empirically at milestone (b) before polishing it.

---

## Coaching context

The compact MCP resource/prompt and iOS Coaching context view use private
session/set logs, the exercise catalog and authored plan metadata. Recent means
up to seven non-discarded sessions through the member's civil today; a separate
last-completed projection preserves feedback even beyond that window. Both
session paths use the same semantic projector, tested with shared Swift/TS
fixtures. Schedule, race, periodization, trips and freeform stress settings stay
authored data; the Worker does not interpret them. The resource names its
cached endurance sources and keeps missing measures explicit.

Logged working-set counts are literal non-warm-up rows, with primary-muscle
attribution only and recorded RPE coverage. External-load volume uses positive
rep loads with side/implement multipliers and keeps units separate; unavailable
volume is absent and the legacy scalar is null for mixed units. Neither count
is measured stimulus, complete muscle volume, bodyweight system load or readiness.
Legacy `hard_sets` is only an alias, not an effort threshold.

## 7. Sync — the other hard one

**Core insight: two data classes, two strategies.**

1. **Append-only log** (`set_logs`, `notes`, `sessions`): writes carry a
   **client-generated UUID** → idempotent. Two writers just produce two
   events; server dedups on `id`. No merge possible, none needed. iOS keeps
   an **outbox** of unsynced sets; flushes on connectivity; retries are safe
   because POST is idempotent. This kills the offline-data-loss path.

2. **Versioned document** (plan tree): edited by Claude or the member in iOS. Single
   per-user monotonic `plans.version` + optimistic concurrency. Replacing a plan,
   or ensuring one only when no active plan exists after archived history,
   allocates a version greater than every prior plan for that user. Returning an
   existing active plan does not change it, and replacement never moves the sync
   cursor backward.
   MCP `update_plan` takes `expected_version`; a mismatch is a structured
   `{conflict:true,current_version}` result in a normal JSON-RPC response so
   Claude refetches and reapplies. App day and schedule writes use the same
   atomic version check; on HTTP 409 the app refetches instead of silently
   overwriting the coach or another member screen.

**Flow:** app on launch/foreground/post-write calls
`GET /api/state` with the account's plan version and every collection cursor.
The first request, an account change, a missing/invalidated/undecodable
snapshot, or legacy cached rows without comparable server cursors sends zero
and performs a complete reload. A superseded request ticket is simply dropped.
Otherwise the app sends active `sets_since` and `log_since` watermarks. It also
sends active `events_since` and `activities_since` watermarks only when the
last accepted response advertised `external_sync_cursors_version >= 2`; an
absent or lower capability keeps both external cursors at zero. A changed plan
returns the full small tree. Set/session, external-cache, and manual-activity
deltas merge by stable id, including tombstones; complete reloads replace their
collections. The app declares `groups` and certifies the stored plan only from
a current live full-tree response with `plan_groups_version >= 1` (or explicit
no-plan version zero). A legacy plan cache forces only the plan cursor to zero;
other collection cursors survive. ACKs and cached wire flags cannot create this
certificate, and a durable oversized-cache invalidation marker cannot retain it.

Grouped slots rotate by rounds using acknowledged plus durable queued set UUIDs,
excluding failed intents. The displayed round is separate from the physical
per-slot set number used to bind a tap or timed hold. A newly queued set cues
round rest when it completes the derived round, including a repaired round with
uneven member counts; otherwise it cues transition rest, where zero skips the
cue. Rest and Live Activity point to the resulting next member. Selection
revisions preserve newer manual focus across older pending deletions and cold
recovery. Repairs deferred by a timed hold survive process termination, and a
later manual choice cancels them durably. Acknowledgements never restart a rest
timer.
The workout editor selects adjacent slots and moves each group as one card,
with rounds, round rest and transition rest edited together. Ordinary slot rest
stays intact and inactive until ungrouping.

Runner inputs keep an intentional draft only while its slot and prescription
still match. An explicit load/RPE/rep/duration target takes precedence over
history; last-time context is separate and distinguishes slots, warm-ups and
rep versus timed execution. A correction is a durable, account-scoped intent
against the original set UUID, session attempt and observed row revision.
Pending deletes leave the original visible. Retry after a lost acknowledgement
accepts an already-applied desired state; a competing revision requires review.
Deletion and last-live-set session demotion share one atomic write batch.

Migration `0043` adds nullable `sessions.runner_targets`. At the first accepted
set, the app's tap-time plan id/version/day resolves through owner-scoped,
immutable `plan_snapshots`; missing history stays unavailable. Older callers
capture the current selected day in the same write batch as their first set.
An empty completion can snapshot its pinned day. Started legacy sessions are
not backfilled, and explicit restart clears the snapshot. Later plan edits
cannot rewrite the starting targets; detached historical slots are reported as
unavailable for comparison instead of missed work.

`getWorkoutSummary` reads persisted session, set and prior-best rows in one D1
batch. It reuses the shared metric cohorts: records require a previous lower
rep/hold result at the same exercise, load and execution mode; an initial
baseline is not a PR. Warm-ups and tombstones do not contribute to working
volume or records. iOS renders this projection in completion and history;
`get_session_log` and `log_workout_complete` expose it to the coach. Queued
finishes remain pending, and summary refresh failure never resends an
acknowledged completion. Corrections invalidate the app summary cache.

Every mutable log cursor is server-owned. The response captures `server_time`
before reading any collection, and the client persists the next active
watermark as `server_time - 60 seconds`. A write that commits after its
collection was read is therefore newer than the response watermark, while the
fixed overlap makes boundary and same-millisecond races harmless. Replayed
rows upsert idempotently by UUID. `set_logs.updated_at` advances on correction,
discard, slot remap/detach, and soft deletion; `sessions.updated_at` advances on
every client-visible session change; manual `activities.updated_at` advances
on insert and soft deletion. Client-authored `logged_at` remains event data and
is never a sync cursor.

Connecting by API key or OAuth immediately reconciles the member's last 90 days
of completed Intervals activity, using their stored timezone for the window.
The credential acknowledgement returns before the import, which runs in
`waitUntil` with a bounded provider deadline. iOS briefly observes its status,
then offers retry if still pending; observation never repeats credentials or
starts a competing provider request. The acknowledgement includes the previous
successful-sync watermark so an identical-credential reconnect waits for a newer
import rather than treating old freshness as completion. `GET /api/me` exposes
the current credential generation, whether initial activity sync is pending, and its last
successful timestamp. `POST /api/me/integrations/intervals/sync` accepts only
`expected_generation` for the authenticated member and cannot import with a
replacement connection. Provider rejection follows the existing credential
recovery path; disconnect and auth failure retain the activity cache.

Migration `0047` cancels pending OAuth states when the credential generation
changes. Each state stores the generation read when creation began, and its
insertion claims that generation; consumption preserves it for the conditional
token write. A disconnect during state insertion or token exchange cannot
reconnect the member. Unbound states minted by an older Worker require a fresh
connect attempt after the new Worker is deployed. Apply this additive migration
before a later authorized Worker release;
repository delivery does not apply it in production. The iOS connection screens
use server status, reject late operation/profile responses, and refresh shared
activity state after a successful import. A saved local connection is historical
context and cannot override a current disconnected or reconnect-required state.

The intervals.icu event and activity caches use change-aware upserts. An
existing row updates only when a normalized, extracted field differs or the
row is being resurrected; an unchanged provider result performs no write and
does not advance `synced_at`. The stored raw provider JSON is intentionally
excluded from equality because key order and non-modeled fields may drift; it
is refreshed only alongside a real extracted-field change. A reconcile
tombstone advances `synced_at`, so incremental clients receive removals.
HealthKit same-UUID retries follow the same extracted-field rule because they
share the activity cursor: an unchanged retry preserves any dedup tombstone and
provenance, while a real revision updates and then runs the existing dedup pass.
Migration `0046` keeps `start_date_utc_ms` separate from the existing civil-clock
ordering proxy. HealthKit uses its recorded timezone when available and retains
the first stored civil date and instant on same-UUID retries, including after
travel. Without source timezone metadata, the first observed civil day is kept;
the historical timezone is unknown. Intervals keeps its provider-local date and
stores an absolute instant only from an explicitly zoned timestamp; a corrected
local start without a new instant clears the old instant.

A HealthKit strength row is retired in favor of `session:<UUID>` only when one
completed native session for the same user has recorded absolute start and end
times both within two minutes. Missing or ambiguous timing stays visible. The
HealthKit upsert and native completion/discard transactions reconcile that pair
atomically. Discard restores the observed HealthKit row, or repoints it to an
existing Intervals winner. The existing Intervals/HealthKit reconciliation keeps
its source fence and precedence outside native matches. This does not establish
identity between native and Intervals rows; three-source collapse is unsupported.
Every real tombstone, resurrection, dedup retirement, repoint, or restoration
advances the cursor strictly, including when the Worker clock has not advanced.
Each provider HTTP 200 is parsed atomically before cache mutation: intentionally
filtered rows remain ignored, while a missing or malformed planned-event
category discriminator, malformed relevant id/local timestamp, or non-record
array member fails the complete fetch and leaves cached rows unchanged.
Reconciliation passes the seen-id collection as one JSON-bound value expanded
through `json_each`; the constant five-bind statement avoids D1's
100-bound-parameter ceiling and materializes the membership list once.

Local set writes synchronously persist an account/attempt-bound outbox intent
before POST. Pending progress is presented separately from acknowledged sets;
accepted responses advance the newest account snapshot before removing the
intent. Transient failures retain that intent for bounded backoff and retry.
Post-outbox reconciliation
uses the same delta pull. A successful POST acknowledgement is the mutation
boundary: if a genuinely new or newer ACK is absent from the following delta,
the app retains it, retires the durable intent, reports success, clears cursors
for a complete reload, and shows sync uncertainty separately. An old deduped
UUID may be absent without uncertainty when the pre-POST snapshot already has
an equal or newer server row. Raw set tombstones stay in the account snapshot
long enough to order them against delayed acknowledgements, then presentation
filters them. Account-scoped request tickets prevent a response reserved for
one sign-in or older account revision from committing into another.

The manual-activity collection also carries a local cursor-capability bit. An
absent or null legacy `activities` key remains compatible but keeps
`log_since=0`; a valid non-null collection supplies capability, even when empty;
and malformed present activity data fails the response so state and cursor
cannot advance past an undecoded row.

**P1/P2 rollout:** have the combined Worker artifact ready, apply pending
migrations in order (`0033`, additive `0034`, then index-only `0035`), deploy
that Worker immediately, and only then distribute incremental iOS. If the
deploy fails after the migrations commit, roll forward with the prepared
Worker rather than attempting a migration rollback. Old iOS clients remain
compatible because they send zero cursors. Once an incremental client ships,
the pre-P1 Worker is not a safe rollback: its immutable set cursor can omit
later tombstones. Retain a P1-aware rollback version or forward-fix instead. If
the server later rolls back to a P1-aware pre-P2 version, the missing P2
capability returns external-cache collections to complete reloads.

**Conflict reality check:** the only true two-writer race is "Claude edits
the plan while you're mid-workout." Set logs reference `exercise_id` /
`template_exercise_id`, **not positional indices**, so a plan edit cannot
corrupt in-flight logs. Worst case: today's targets change under you mid-set
— which is exactly the desired behavior for "Claude, I'm beat, adjust." The
app shows a subtle "plan updated by coach" banner on the next state pull.

No CRDTs, no OT. Append-only events + versioned document + LWW on tiny app
edits = right-sized.

---

## 8. Live Activity (rest timer)

- Widget Extension target. Shared `ActivityAttributes` (`RestTimer`:
  static `exerciseName`, `setNumber`; `ContentState`: `endDate`, `isPaused`)
  in a file that's a member of both app and widget targets.
- On set logged → `Activity.request` with `endDate = now + rest_seconds`.
- Lock screen / Dynamic Island render `Text(timerInterval:countsDown:true)`
  → iOS animates the countdown with **zero updates, zero APNs, zero server**.
- Controls via `LiveActivityIntent`: Stop/Skip ends the Activity (+ advances
  set); "+30s" mutates `ContentState.endDate`.
- End on next set or `staleDate`; set `staleDate` so it self-cleans.
- `Info.plist`: `NSSupportsLiveActivities = YES`. **No push entitlement in
  v1** (local updates only). Server-driven rest (Claude triggers remotely) =
  deferred; would add an ActivityKit push token + APNs.
- Xcode setup walked through at milestone (g): File ▸ New ▸ Target ▸ Widget
  Extension; embed in app; deployment iOS 17+; automatic signing inherits
  your team. Entitlements explained inline then.

---

## 9. iOS app

SwiftUI, iOS 17+. The main-actor `SyncModel` publishes in-memory presentation
arrays and coordinates networking, account epochs, attempt-bound writes and
reconciliation. `StateSnapshotStore` persists an account-scoped JSON envelope in
UserDefaults; separate stores own the catalog, outboxes and runner checkpoint.
There is no SwiftData store, `SyncService` actor or `@Query` path.

`TrainingHistoryIndex` is a disposable pure read model for session/date/exercise
lookups and history metrics. Changes to published sessions, sets or catalog
invalidate it and the requested summary caches. Calendar truth-table rules stay
in `CalendarProjection`. Exercise rows are lazy and calculate only their latest
session summary. The snapshot store retains one live envelope, guarded by
defaults identity, user ID and equality with the current persisted bytes.
Revisions, account/attempt guards and tombstone ordering remain authoritative.
Large snapshot envelopes use a lossless LZFSE wrapper. If a packed value still
exceeds the observed 4 MiB platform boundary, all store writes persist a small
ordering/invalidation marker and retain the latest validated rows in that one
process-local envelope. Reads and mutation ACKs can therefore advance together
without trusting an older model fallback. No delta cursor claims those rows
survived relaunch. A cold process sees only the marker and reloads fully;
explicit invalidation or external replacement discards the live envelope too.
Legacy JSON still decodes. A failed ordering write preserves its durable intent.
No server history is trimmed.
Serialization remains synchronous on the main actor and proportional to retained
history; incremental network pulls do not make it constant-cost. See the
[measured client evidence](plans/completed/app-quality-and-maintainability/evidence/p2/README.md)
for datasets, budgets and memory tradeoffs.

- **Today:** compact scheduled/completed card with named workout details,
  explicit Start/Continue, Choose a workout, Create a workout, and Log an
  activity actions. Choose opens the shared library; Create saves a named
  library entry before opening its editor. Completed records open separately.
  The active runner retains its exercise list, big weight/reps steppers, log-set button, rest
  timer overlay + Live Activity trigger + **audio cue when rest ends** (RestCue:
  chime/haptic/speech, headphone-aware), last-time chips per exercise. Per-set
  completion keys on `template_exercise_id` (the slot), not `exercise_id`, so the
  same movement in two slots / out-of-order logging never mis-completes.
- **Edit workout:** in-app add/remove/reorder/replace of exercises + warm-ups
  (`EditWorkoutSheet`), editing the active plan's library workout via the REST
  editor endpoints. Members and Claude share the versioned prescription; this is the executor
  letting you tweak the session in front of you.
- **Calendar:** past and future dates, explicit date assignment/removal/move,
  and separate routes to the repeating weekly schedule and exercise progress
  (Swift Charts trend and last-session preview). A move requires the compatible
  Worker before distributing this client; repository delivery does not deploy it.
  Date notes and fatigue stay on their original dates when the assignment moves.
- **Workouts:** keep reusable workouts with weekday badges or "On demand".
  Open named details before editing prescriptions or using a workout on a date.
  Plan changes and recent-change review live in this library. Unschedule clears recurring weekdays only; Delete workout retains
  the existing history-preserving deletion semantics. Calendar exceptions use
  the shared attempt-CAS writer and leave the weekly schedule unchanged.
- **Profile:** Training overview lives in the Coach section alongside coach setup.
- **Auth:** Sign in with Apple → Keychain JWT; 401 → re-auth.
- **No in-app chat** (by design — you chat in the Claude app; this reflects state).
- UI per the React artifact (dark scoreboard, condensed display type, mono
  numerics, big tap targets) → SF Pro Display Heavy + SF Mono, or licensed
  Bebas Neue. Spec, not a port. **Artifact not yet attached** — needed before
  milestone (h); earlier milestones don't depend on it.

---

## 10. Deploy

**Backend:** `wrangler d1 create tres-fort-db`; migrations in `/migrations`
via `wrangler d1 migrations apply`. Secrets via `wrangler secret put`:
`APP_JWT_SECRET`, `MCP_STATIC_TOKEN`, `APPLE_BUNDLE_ID`, `OWNER_APPLE_SUB`,
OAuth signing material. `wrangler deploy`. Start on `*.workers.dev`; add
`lift.<yourdomain>` via Cloudflare route at TestFlight time. One Worker, two
routers (`/api/*` app-JWT, `/mcp` OAuth/bearer).

**iOS:** Xcode, automatic signing (your active team), capability: Sign in
with Apple. Archive ▸ Distribute ▸ TestFlight (internal, just you). Widget
target embedded for Live Activity.

---

## 11. Milestones (your a–i, with test gates)

| # | Deliverable | Pass when |
|---|---|---|
| a | Worker + D1 + schema deployed, REST + auth, integration tests | `curl` w/ app-JWT does full CRUD; SIWA verify path unit-tested; tests green in CI |
| b | MCP read tools + `coach://state/current` resource | From a separate Claude chat: "what's my plan / how's bench trending" returns real D1 data; static-bearer verified, OAuth path verified or fallback confirmed |
| c | MCP write tools | In chat: log a set, `swap_exercise`, `adjust_today` → D1 mutated, `version` bumped, audit + note written |
| d | iOS scaffold + Sign in with Apple end-to-end | App signs in on device, gets app-JWT, authenticated `/api/state` succeeds |
| e | Today screen: read plan, log sets, rest overlay | Log a set on device → server has it → visible in a Claude chat |
| f | History + trends | Per-exercise chart + last-session preview from real data |
| g | Live Activity rest timer | Lock-screen countdown after a set; Stop/+30s work; self-cleans |
| h | UI polish to artifact | Side-by-side matches artifact intent (needs artifact) |
| i | TestFlight build | Installs on your device from TestFlight |

After each: summary of what changed / what's testable / what's next / what's open.

---

## 12. Open questions & risks

- **R1** claude.ai/desktop connector auth specifics — verify at (b); static bearer is the guaranteed fallback. *Low.*
- **R2** SIWA name returned only on first authorization — captured in `/auth/apple`. *Handled.*
- **R3** "Today" timezone — `sessions.date` is device-local `YYYY-MM-DD`; Worker trusts client local date (no UTC boundary bug). *Handled by design.*
- **R4** Exercise-name matching for MCP — alias resolver + `exercises.aliases`. *Handled by design.*
- **R5** React artifact not yet provided — only blocks milestone (h). *Track.*

## 13. Cost

| Item | Cost |
|---|---|
| Apple Developer Program | $99/yr — **already active** ✅ |
| Cloudflare Workers + D1 | $5/month + usage (Workers Paid; active 2026-09-05) |
| Domain | already owned |
| **New spend** | **$5/month + usage** |
