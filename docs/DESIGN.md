# tres-fort — Design Doc

> Claude is the coach. It owns the plan and adapts it through conversation.
> You execute and log in a native iOS app. A Cloudflare backend is the
> single source of truth that both Claude (via MCP) and the app read/write.

Status: **IMPLEMENTED** — all milestones (a–i) shipped; intervals.icu
integration, groups/invites (M1/M2), and multisport (endurance) coaching
added post-milestone.
Date: 2026-05-18 · Owner: Nick · Apple Developer Program: **Active** ·
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
| Cloudflare Workers + D1 as source of truth | ✅ Correct. SQLite semantics, free tier covers a single user ~1000×, MCP-from-Worker is the natural fit. |
| CloudKit rejected for source of truth | ✅ Agree. Claude needs first-class writes from outside Apple's ecosystem; CloudKit S2S is awkward and Apple-bound. SwiftData as **local cache only** is right. |
| **Two separate Workers (REST + MCP)** | ⚠️ **Pushing back → one Worker, two route groups** (`/api/*`, `/mcp`). They share the D1 binding, schema, domain model, and service layer. Splitting doubles deploy/secret/observability surface for zero isolation benefit in a single-user system. Splitting later is a routing change, not a rewrite. |
| MCP auth = "bearer token in connector settings" | ⚠️ **Refining.** Fine for Claude Code; claude.ai/desktop custom connectors expect OAuth. Plan: implement a lightweight Cloudflare OAuth provider **and** accept a static bearer. Every surface works; CLI/curl testing stays trivial. (§6) |
| SwiftData "sync on open + on write" | ⚠️ **Refining.** Add an outbox + client-generated set IDs so a set logged on flaky gym wifi is never lost. Cheap; removes the only real data-loss path. (§7) |
| Rich plan schema for periodization | ⚠️ **Right-sizing.** Periodization stays **out of rigid columns**. Progression/deload/mesocycle live in a per-exercise `progression` JSON + Claude-written notes. Claude is the periodization engine; the schema just faithfully stores and versions its decisions. |

Net new spend: **$0** — Apple Developer already covered; Cloudflare free tier; domain owned.

---

## 3. D1 schema

Epoch-ms integers for timestamps. `id` is a UUID string. Plan-tree tables
(`plans`, `day_templates`, `template_exercises`) are the versioned document;
`set_logs`/`notes`/`sessions` are the append-only log.

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

CREATE TABLE day_templates (
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
  day_template_id  TEXT NOT NULL REFERENCES day_templates(id),
  exercise_id      TEXT NOT NULL REFERENCES exercises(id),
  order_index      INTEGER NOT NULL,
  target_sets      INTEGER NOT NULL,
  target_reps      INTEGER NOT NULL,            -- bottom of range
  target_reps_max  INTEGER,                     -- top of range (double progression); NULL = fixed
  target_rpe       REAL,
  rest_seconds     INTEGER NOT NULL DEFAULT 120,
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
  day_template_id   TEXT REFERENCES day_templates(id),   -- NULL = ad-hoc
  date              TEXT NOT NULL,                        -- 'YYYY-MM-DD' device-local
  status            TEXT NOT NULL DEFAULT 'planned',      -- planned|in_progress|completed|skipped
  started_at        INTEGER,
  completed_at      INTEGER,
  perceived_fatigue INTEGER,                               -- optional 1–10
  notes             TEXT,
  created_at        INTEGER NOT NULL,
  updated_at        INTEGER NOT NULL
);

CREATE TABLE set_logs (
  id                   TEXT PRIMARY KEY,        -- CLIENT-generated UUID = idempotency key
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
CREATE INDEX ix_sets_ex_time ON set_logs(exercise_id, logged_at);
CREATE INDEX ix_sessions_user_date ON sessions(user_id, date);
CREATE INDEX ix_te_day ON template_exercises(day_template_id, order_index);
```

Periodization note: no `mesocycles`/`weeks` tables. Deloads, wave loading,
and block changes are Claude editing `target_*`/`progression` and writing a
`notes` row. That's the flexible-without-overengineered line.

---

## 4. REST API (iOS, `Authorization: Bearer <appJWT>`)

| Method · Path | Purpose |
|---|---|
| `POST /auth/apple` | Body `{identityToken, authorizationCode, fullName?}` → `{jwt, user}`. Verifies Apple JWT, allowlists owner sub, issues app JWT. |
| `GET /api/state?since=<planVersion>&sets_since=<epochMs>` | **The sync pull.** Returns `{plan: tree|null, sessions[], sets[], server_time}`. `plan` is null when `version <= since`; otherwise the full small tree. sessions/sets are deltas. Called on launch/foreground/post-write. |
| `GET /api/today` | Today's session (created from today's template if absent) + its sets + per-exercise last-time actuals + suggested weight. |
| `POST /api/sessions` | `{date, day_template_id?}` → create/start session. |
| `PATCH /api/sessions/{id}` | `{status?, perceived_fatigue?, notes?}`. |
| `POST /api/sessions/{id}/sets` | Idempotent on body `id`. `{id, exercise_id, set_index, weight, reps, rpe?, is_warmup?, notes?, logged_at}`. |
| `PATCH /api/sets/{id}` | Edit / soft-delete a set. |
| `GET /api/history?exercise_id=&from=&to=` | Set history + est-1RM (Epley) + top set/session. |
| `GET /api/volume?muscle=&from=&to=` | Tonnage & hard sets per week bucket. |
| `PATCH /api/days/{id}` | `{name?, day_label?, order_index?, notes?}` — inline day rename/reorder. |
| `POST /api/days/{id}/exercises` | Add an exercise slot (incl. `is_warmup`, `target_duration_s`). |
| `PATCH /api/days/{id}/exercises/{teId}` | Edit one slot in place (targets / rest / warm-up flag / order). |
| `DELETE /api/days/{id}/exercises/{teId}` | Remove a slot; detaches (NULLs) historical `set_logs.template_exercise_id`. |

In-app workout editing (add/remove/reorder exercises + warm-ups, migration
0026) goes through the three `/api/days/{id}/exercises…` routes — thin wrappers
over the same `updateExercise`/`deleteTemplateExercise` the MCP tools use,
audited as `actor='ios'`. Any write touching the plan tree bumps
`plans.version`.

---

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
- `get_session_log({date?, recent_n?})`
- `get_history({exercise, range?:"30d|90d|all", limit?})`
- `get_volume_trend({muscle_group, range?:"8w|12w|6mo", bucket?:"week"})`

**Write tools**
- `log_set({exercise, weight, reps, rpe?, is_warmup?, session_date?, notes?})` → auto-creates session, appends, returns running summary.
- `log_workout_complete({session_date?, perceived_fatigue?, notes?})`
- `add_note({scope, ref_id?, body})`
- `update_plan({plan:<full tree>, expected_version?})` → transactional upsert; optimistic concurrency, 409 on version mismatch (Claude refetches + reapplies).
- `update_exercise({target, patch})` → one slot (`target` = template_exercise_id or {day, exercise}).
- `swap_exercise({day, from_exercise, to_exercise, carry_targets?})`
- `add_exercise({day, exercise, target_sets, target_reps, target_reps_max?, rest_seconds?, target_rpe?, progression?, order_index?})`
- `add_day({name, day_label, order_index?, exercises?})`  ← "add a deadlift day"
- `adjust_today({intent:"deload|reduce_volume|reduce_intensity", magnitude?})` ← one-shot for "I'm beat, adjust"; sugar over update + auto-note.

Every write tool writes `audit_log` and (for plan changes) a `notes` row, so
you can always see and undo what Claude did.

---

## 6. Auth — the hard one

Same identity (you), **two credentials**, one `user_id`. Different threat
models, lifecycles, and revocation paths → decoupled on purpose.

**iOS → Worker JWT (Sign in with Apple)**
1. App: `ASAuthorizationAppleIDProvider` → `identityToken` (Apple-signed JWT) + `authorizationCode` + name (first auth only).
2. `POST /auth/apple`. Worker: fetch/cache Apple JWKS, verify signature + `iss=appleid.apple.com` + `aud=<bundle id>` + `exp`; extract `sub`; **allowlist your sub** (`OWNER_APPLE_SUB` secret) so nobody else can create an account; upsert `users`.
3. Worker issues app JWT (HS256, `APP_JWT_SECRET`, `sub=user_id`, ~60-day exp) → app stores in **Keychain**.
4. Refresh: near expiry, app silently re-runs SIWA → new JWT. No refresh-token store in v1.

**MCP → dual acceptance on `/mcp`** (resolves your "one token? scopes? rate limits?")
- (a) **OAuth 2.1** for claude.ai/desktop custom connectors — a minimal in-Worker provider (`src/oauth.ts`). The `/oauth/authorize` step is gated by a passphrase: the **owner** uses `OWNER_AUTH_PASSPHRASE`, any other user a personal MCP passphrase (PBKDF2-SHA256, per-user salt) set via `POST /api/me/mcp-passphrase`. On match it binds that `user_id` into the auth code and issues short-lived access tokens (also carrying the `user_id`) the Worker validates.
- (b) **Static bearer** for Claude Code / curl / milestone-b testing — `Authorization: Bearer <MCP_STATIC_TOKEN>` (Worker secret).
- **Resolution (M3, migration `0025`).** Static bearer → the owner. OAuth token → the user it was bound to at `/oauth/authorize`. Tokens issued before M3 carry no `user_id` and resolve to the owner (back-compat), so already-connected claude.ai sessions keep working as the owner without re-auth.
- **No per-tool scopes.** Per connected user there is one principal → scopes would add complexity with little security gain at this scale. The trust substitute is the per-user `audit_log` + Claude-written notes (visible, reversible).
- **Rate limit:** soft cap (~600 req/min) via a Cloudflare rate-limit rule on `/mcp` or a KV counter — a runaway-loop guard, not a security boundary. Optional-but-recommended for v1.

Risk R1: claude.ai/desktop connector auth specifics may differ at build
time. Mitigation: the static-bearer path is a guaranteed fallback; verify
the OAuth path empirically at milestone (b) before polishing it.

---

## 7. Sync — the other hard one

**Core insight: two data classes, two strategies.**

1. **Append-only log** (`set_logs`, `notes`, `sessions`): writes carry a
   **client-generated UUID** → idempotent. Two writers just produce two
   events; server dedups on `id`. No merge possible, none needed. iOS keeps
   an **outbox** of unsynced sets; flushes on connectivity; retries are safe
   because POST is idempotent. This kills the offline-data-loss path.

2. **Versioned document** (plan tree): edited almost only by Claude. Single
   monotonic `plans.version` + optimistic concurrency. `update_plan` takes
   `expected_version`; mismatch → 409 → Claude refetches and reapplies
   (Claude handles this well). The app's rare writes (rename/reorder) use
   the same check; on 409 it just refetches — no user-facing merge UI,
   because app-side plan edits are tiny and infrequent.

**Flow:** app on launch/foreground/post-write calls
`GET /api/state?since=<lastPlanVersion>&sets_since=<watermark>`. Plan changed
→ full tree returned, **full replace** into SwiftData (safe: server is truth,
tree is small). Sessions/sets returned as deltas. App stores new watermarks.
Local writes are optimistic (write SwiftData + enqueue outbox + POST;
reconcile on success, retry-with-backoff on failure).

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

SwiftUI, iOS 17+, SwiftData as a cache mirroring the server tree. A
`SyncService` actor owns networking + reconcile; views use `@Query`.

- **Today:** exercise list, big weight/reps steppers, log-set button, rest
  timer overlay + Live Activity trigger + **audio cue when rest ends** (RestCue:
  chime/haptic/speech, headphone-aware), last-time chips per exercise. Per-set
  completion keys on `template_exercise_id` (the slot), not `exercise_id`, so the
  same movement in two slots / out-of-order logging never mis-completes.
- **Edit workout:** in-app add/remove/reorder of exercises + warm-ups
  (`EditWorkoutSheet`), editing the active plan's day template via the REST
  editor endpoints. Claude still owns programming/analysis; this is the executor
  letting you tweak the session in front of you.
- **History:** per-exercise Swift Charts trend, last-session preview.
- **Plan:** read-mostly tree; inline rename/reorder (PATCH) + the editor above.
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
| Cloudflare Workers + D1 | $0 (free tier, single user) |
| Domain | already owned |
| **New spend** | **$0** |
