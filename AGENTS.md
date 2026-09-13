# Tres Fort

Durable repository guidance for coding agents working in this repository.

## What this is

An AI-coached lifting system. The user chooses an external AI app (Codex,
Claude, or another compatible MCP client) to adapt the training plan; members can also author reusable workouts and workout dates in
the native iOS gym executor; a single
Cloudflare Worker + D1 database is the source of truth both sides read/write.
The backend contains **no AI** — it is pure data. Full rationale, schema, and
the API/MCP surface live in `docs/DESIGN.md` (read it before non-trivial
backend work).

## Repository planning

Engineering workstream plans are distinct from the workout plan stored in D1.
Current workstreams live at `docs/plans/<slug>/plan.md`; cross-plan initiatives
live at `docs/initiatives/<slug>.md`; and `.agents/resume.yaml` configures the
shared planning workflows. Only `plan.md` carries live phase status,
dependencies, execution frontier, and next step. Run the shared
`planning-conventions` compiler's `check` command after changing a plan,
initiative, index, or adapter.

## Commands

Backend (repo root):

```bash
npm test                       # vitest: integration tests vs real D1 in the Workers runtime
npm run test:watch
npx vitest run test/mcp.test.ts            # single file
npx vitest run -t "logs a set"             # single test by name
npm run typecheck              # tsc --noEmit
npm run dev                    # wrangler dev (local Worker + local D1)
npm run db:migrate:local       # apply migrations/ to local D1
npm run db:migrate:remote      # guarded during workout rename; see rollout.md
npm run deploy                 # deploy only, separate production authority required
npm run release                # guarded: use the staged workout rollout below
npm run test:workout-rollout    # local same-Worker rename and rollback rehearsal
npm run ios:testflight         # build, archive, export, upload to TestFlight
npm run beta:feedback          # mirror TestFlight beta feedback into GitHub issues
```

iOS (`ios/`):

```bash
cd ios && xcodegen generate    # regenerate TresFort.xcodeproj from project.yml — run after any project.yml change
open ios/TresFort.xcodeproj
```

Build/run with the **TresFort** scheme, never the widget-extension scheme.
The `.xcodeproj` is generated; treat `project.yml` as the source of truth.

## Workout rename compatibility

The logical model uses `workouts` / `workout_id`. During P0's compatibility
window, `workoutSchema.ts` adapts service SQL to either physical schema and
`workoutWire.ts` emits both new and deprecated fields. Old `/api/days` routes
and `add_day` / `update_day` MCP names remain aliases. New tools are
`add_workout`, `update_workout`, and `delete_workout`. The first compatible app
reads both formats and sends the old one. Use the [staged rollout](docs/plans/workouts-and-multi-session/rollout.md)
for production; never apply migration 0045 before the adaptive Worker is live.
Repository delivery does not prove production migration or client rollout.

## Architecture

**One Worker, route groups, one service layer.** `src/index.ts` mounts
`/auth`, `/auth/intervals` (intervals.icu OAuth connect), `/api` (iOS REST,
app-JWT), `/mcp` (external AI apps), OAuth discovery, `/webhooks` (intervals.icu push
receiver, `src/routes/webhooks.ts` — public, authenticated by a body
`secret` rather than app-JWT/MCP bearer), `/privacy` (App Store Connect
compliance page), and `/join/:code` + AASA (`src/routes/invites.ts` —
Universal Link group invites) under one Hono app. **All D1 access goes
through `src/db.ts`** — REST routes (`src/routes/`) and MCP tools
(`src/mcp/server.ts`) are thin wrappers over the same functions, so behavior
stays identical across clients. Add data logic in `db.ts`, not in route/tool
handlers. intervals.icu I/O is isolated in `src/intervals.ts` (injectable
fetcher, dormant when no credentials are set); an hourly cron
(`wrangler.jsonc` `triggers.crons`) re-syncs as a backstop for any
undelivered webhook — the webhook is the primary sync path, not the cron.
Apple Health (HealthKit) is a second, iOS-only activity source: the Worker
can never read HealthKit directly, so the app pushes idempotent workouts to
`POST /api/activities/healthkit` (`upsertHealthKitActivity` in `db.ts`),
landing in `external_activities` with `source='healthkit'`. A per-user
opt-in (`users.share_health_activities`, migration `0028`, flipped via
`PATCH /api/me/health-sharing`) gates whether a member's HealthKit rows are
visible to other group members in `get_group_feed`/group stats —
intervals-sourced rows are unaffected. See `docs/MULTISOURCE-INGESTION.md`.

**Two data classes, two consistency strategies** — this split is the core
design and dictates how you mutate things:

- *Versioned document* — the plan tree (`plans` / `workouts` /
  `template_exercises`). One monotonic `plans.version`, bumped on any plan
  mutation. The MCP `update_plan` tool takes an expected version and on
  mismatch returns a structured `{ conflict: true, current_version }` result
  inside a normal HTTP 200 `tools/call` response — **not** a 409 (the caller
  refetches and reapplies); `PATCH /api/workouts/:id`, `POST
  /api/workouts/:id/exercises` (add), `PATCH /api/workouts/:id/exercises/:teId`
  (edit), and `DELETE /api/workouts/:id/exercises/:teId` (remove, detaching
  historical `set_logs.template_exercise_id`) each patch a single-field
  allowlist or one slot through a write-time version claim. Legacy slot
  APIs retain their existing inputs without requiring an expected version;
  bounded retries re-read and validate fresh state before applying only
  supplied fields. These give the iOS app direct, non-Claude
  write access to a day's exercises (audited as `actor='ios'`), reusing the
  same `db.ts` functions MCP's `update_exercise` / `delete_exercise` call.
  `template_exercises.is_warmup` (migration `0026`) marks a slot a
  prescribed warm-up, excluded from working-set rollups; `cardio` is a
  `modality` for erg/treadmill/bike slots logged by duration via the same
  timed-set runner. Never mutate the plan tree without going through one of
  these paths. Migration `0040` adds full-document `plan_snapshots`. Shared
  writers commit mutation/order, version, audit, required MCP note and snapshot
  in one D1 batch using `preparePlanWriteStart` / `preparePlanWriteFinish`.
  Keep the SQL/TypeScript writable-document serializers in parity. Return a
  committed-version result; post-commit read failures must retain the successful
  acknowledgement. Restore requires the reviewed plan ID/version, validates
  prescriptions, rejects active workouts and creates a new version.
- *Append-only log* — `set_logs` / `notes` / `sessions`. The row `id` is a
  **client-generated UUID = idempotency key**; writes dedup on it and are
  safe to retry. Logged data is **soft-deleted** (`deleted_at`), never hard
  deleted.

`GET /api/state?since=&sets_since=` is the single sync pull: full plan tree
only when its version moved, sessions/sets as deltas.

**Client state.** `SyncModel` publishes in-memory arrays. Account-scoped JSON
snapshots, outboxes and runner checkpoints live in UserDefaults, with no
SwiftData or `@Query` path. `StateSnapshotStore` owns revision/ACK/tombstone
ordering; its live envelope checks current persisted bytes before reuse. Large
envelopes are losslessly compressed. If packing exceeds the platform limit,
every writer can advance a small durable ordering/invalidation marker while
retaining one process-local live envelope. A cold process must fetch fully;
explicit invalidation or external replacement also discards that live value.
`TrainingHistoryIndex` and requested summaries are disposable read models,
invalidated on every published session/set/catalog mutation. Keep these caches
out of write-authority decisions and preserve the calendar parity contract.

**Weekly schedule & calendar projection.** The recurring weekly pattern
(weekday → `workout_id`, `null` = rest) lives in `plans.meta.schedule`
JSON — *not* a table (consistent with the "no weeks tables" design). It is
part of the versioned document: `set_schedule` bumps `plans.version`, uses
optimistic concurrency, and writes audit+note like any plan mutation; it
rides `/api/state` inside the plan payload. One-off changes ("skip Thursday
this week") are concrete `sessions` rows via `set_planned_session` /
`skip_planned_session` — append-only, **no** version bump. The future
calendar is *computed, not stored*: `projectCalendar` in `db.ts` is the
authoritative projection (past = real sessions only; today+ = real session
wins, else schedule lookup, else rest). **iOS re-implements the identical
algorithm in `CalendarProjection.swift`** — the weekday rule (tz-free civil
date) and the truth table must stay byte-for-byte in parity across both;
`test/calendar.test.ts` is the contract. `update_plan` rebuilds day UUIDs
and remaps the schedule by day name/label; days removed in the rebuild have
their schedule entry cleared. For a date assignment, `expected_attempt=0`
means no row was observed; the first assignment and every changed workout/rest
choice advance `sessions.attempt`, while an identical retry is idempotent.

**Owner anchor + multi-tenant MCP.** There is always a distinguished **owner**:
the bootstrap row (`ensureOwnerUser`), which Sign in with Apple later *claims*
(`claimOrCreateOwner`) so MCP-seeded data and iOS share one `user_id`;
`OWNER_APPLE_SUB`, when set, pins the owner bootstrap identity and prevents
other identities from claiming the owner row. Sign-in remains open: other new
Apple identities receive ordinary accounts with no group memberships. Other
users exist too (group members), so "exactly one user row"
is **no longer** true. As of M3 (migration `0025`) the `/mcp` bearer resolves
to a *specific* user: the static token (`MCP_STATIC_TOKEN`) always maps to the
owner; an OAuth access token maps to the user it was bound to at
`/oauth/authorize` (pre-M3 tokens carry no `user_id` → owner, for back-compat).

**Auth.**
- `/api/*` — app JWT (HS256, `APP_JWT_SECRET`), issued by `/auth/apple` after
  verifying Apple's identity token against Apple JWKS. Middleware
  `requireAppJwt` sets `userId` on the Hono context.
- `/mcp` — dual: static bearer (`MCP_STATIC_TOKEN`, for Claude Code/curl)
  **and** OAuth 2.1 (claude.ai/desktop connectors). Both flow through
  `validateBearer` in `src/oauth.ts`. Static bearer → owner; OAuth token → the
  user bound at `/oauth/authorize` (the owner via `OWNER_AUTH_PASSPHRASE`, or
  any user via their personal MCP passphrase — PBKDF2, per-user salt — set
  through `POST /api/me/mcp-passphrase`; pre-M3 tokens → owner). The 401 always
  advertises RFC 9728 metadata so the OAuth path is non-breaking.
- `/auth/intervals` — OAuth 2.0 authorization-code connect flow for
  intervals.icu (`src/routes/intervalsAuth.ts`). CSRF is a single-use,
  expiring `state` param (server-minted, resolved back to the connecting
  user on callback); the code is exchanged server-side with the
  `client_secret` — **not** PKCE (no `code_challenge`/`code_verifier`).
  Stores per-user credentials in the `users` row; `src/intervals.ts` is
  dormant (returns `{ok:false, reason:'disabled'}`) when no credentials are
  set.
- `POST /auth/dev` exists **only** when `DEV_AUTH_SECRET` is set (local + the
  vitest config) — never enabled in production.

**Every accepted MCP mutation** records an `audit_log` row and (for plan changes) a
provider-neutral `notes` row (`author='coach'`; historical `claude` rows remain).
This visible/reversible trail is the
substitute for per-tool scopes (now recorded per user) — preserve it when
adding write tools. Plan tools use `atomicWrite` so dispatcher attribution is
not repeated after the service transaction. A no-op adjustment does not create
a version or snapshot. `adjust_today` changes recurring template targets;
omitting a day affects the whole plan.

**Coach grant lineage (migration `0041`).** Validated code exchange and refresh
rotation commit with one successor. Hashed consumed-refresh lineage detects
bound-client replay and revokes only that grant family. Profile disconnect
revokes caller-owned OAuth grants; changing a connect code does not. New grant
timestamps are epoch-ms, while legacy OAuth token expiry remains epoch-seconds.
Migration `0042` adds the approved 90-day refresh inactivity and 365-day absolute
lifetime policy, initially disabled. An explicit atomic activation starts both
clocks for existing authorized grants; successful refresh moves only inactivity.
Bearer validation and refresh enforce both deadlines. Activation retries cannot
restart clocks, and revoked/expired grants require new authorization. Static MCP
bearers and Apple/app sessions keep their separate lifecycles. See the
[coach contract](docs/plans/completed/coach-access-integrity/decisions.md) and
[release procedure](docs/plans/completed/coach-access-integrity/release.md).

**MCP transport** (`src/mcp/server.ts`): stateless JSON-RPC 2.0 over
Streamable HTTP, single `application/json` responses (no server-initiated
streams). Natural-language exercise arguments are run through an alias
resolver (`resolveExercise`) before hitting the catalog. Current tools:
`get_coach_brief`, `get_current_plan`, `get_plan_history`, `compare_plan_versions`, `restore_plan`,
`get_today_workout`, `get_current_session`,
`get_session_log`, `get_history`, `get_volume_trend`, `list_exercises`,
`get_upcoming_rides`, `get_recent_activities`, `get_group_feed`, `log_set`,
`correct_set`, `delete_set`, `log_activity`, `log_workout_complete`,
`discard_workout`, `add_note`,
`update_plan`, `update_exercise`, `swap_exercise`, `add_exercise`, `add_day`,
`update_day`, `delete_exercise`, `adjust_today`, `set_schedule`,
`set_planned_session`, `skip_planned_session`, `set_race`,
`set_periodization`, `add_trip`, `update_trip`, `remove_trip`,
`set_stress_model`, `refresh_rides`. Also exposes a
**resource** (`coach://state/current` — compact coaching brief readable at
chat start) and a **prompt** (`coach_brief`).

## Conventions

- Timestamps are **epoch-ms integers**; `sessions.date` is a device-local
  `YYYY-MM-DD` string (client owns the "today" boundary — do not convert to
  UTC).
- IDs are UUID strings (`crypto.randomUUID()`).
- Periodization is **not** in the schema. Deloads/waves/blocks are Claude
  editing `target_*` / the per-exercise `progression` JSON and writing a
  note. `progression.type` (linear|double|rpe|manual) is interpreted by
  Claude, not enforced by the backend.
- Secrets are never committed — set via `wrangler secret put`.
  `wrangler.jsonc` holds only non-sensitive config (D1 id, bundle id); the
  vitest config injects test values for all secrets.
- Tests run against a real D1 in the Workers runtime via
  `@cloudflare/vitest-pool-workers`; each suite applies `migrations/` with
  `applyD1Migrations(env.DB, env.TEST_MIGRATIONS)` and authenticates through
  `/auth/dev`. The test suites cover the full surface. Schema changes mean a
  new numbered file in `migrations/`.
