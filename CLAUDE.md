# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An AI-coached lifting system. Claude (via MCP) owns and adapts the training
plan through conversation; a native iOS app is the gym executor; a single
Cloudflare Worker + D1 database is the source of truth both sides read/write.
The backend contains **no AI** — it is pure data. Full rationale, schema, and
the API/MCP surface live in `docs/DESIGN.md` (read it before non-trivial
backend work).

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
npm run db:migrate:remote      # apply migrations/ to deployed D1
npm run deploy                 # wrangler deploy
npm run release                # db:migrate:remote && deploy (migration MUST run first
                               # — deploying code that SELECTs a new column before the
                               # column exists 500s every read)
```

iOS (`ios/`):

```bash
cd ios && xcodegen generate    # regenerate TresFort.xcodeproj from project.yml — run after any project.yml change
open ios/TresFort.xcodeproj
```

Build/run with the **TresFort** scheme, never the widget-extension scheme.
The `.xcodeproj` is generated; treat `project.yml` as the source of truth.

## Architecture

**One Worker, route groups, one service layer.** `src/index.ts` mounts
`/auth`, `/auth/intervals` (intervals.icu OAuth connect), `/api` (iOS REST,
app-JWT), `/mcp` (Claude), and OAuth discovery under one Hono app. **All D1
access goes through `src/db.ts`** — REST routes (`src/routes/`) and MCP tools
(`src/mcp/server.ts`) are thin wrappers over the same functions, so behavior
stays identical across clients. Add data logic in `db.ts`, not in route/tool
handlers. intervals.icu I/O is isolated in `src/intervals.ts` (injectable
fetcher, dormant when no credentials are set).

**Two data classes, two consistency strategies** — this split is the core
design and dictates how you mutate things:

- *Versioned document* — the plan tree (`plans` / `day_templates` /
  `template_exercises`). One monotonic `plans.version`, bumped on any plan
  mutation. Writes use optimistic concurrency: `update_plan` /
  `PATCH /api/day_templates` take an expected version and 409 on mismatch
  (the caller refetches and reapplies). Never mutate the plan tree without
  going through the versioned path.
- *Append-only log* — `set_logs` / `notes` / `sessions`. The row `id` is a
  **client-generated UUID = idempotency key**; writes dedup on it and are
  safe to retry. Logged data is **soft-deleted** (`deleted_at`), never hard
  deleted.

`GET /api/state?since=&sets_since=` is the single sync pull: full plan tree
only when its version moved, sessions/sets as deltas.

**Weekly schedule & calendar projection.** The recurring weekly pattern
(weekday → `day_template_id`, `null` = rest) lives in `plans.meta.schedule`
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
their schedule entry cleared.

**Owner anchor + multi-tenant MCP.** There is always a distinguished **owner**:
the bootstrap row (`ensureOwnerUser`), which Sign in with Apple later *claims*
(`claimOrCreateOwner`) so MCP-seeded data and iOS share one `user_id`;
`OWNER_APPLE_SUB`, when set, locks sign-in to that Apple `sub` and disables
row-claiming. Other users exist too (group members), so "exactly one user row"
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

**Every MCP write** records an `audit_log` row and (for plan changes) a
Claude-authored `notes` row. This visible/reversible trail is the
substitute for per-tool scopes (now recorded per user) — preserve it when
adding write tools.

**MCP transport** (`src/mcp/server.ts`): stateless JSON-RPC 2.0 over
Streamable HTTP, single `application/json` responses (no server-initiated
streams). Natural-language exercise arguments are run through an alias
resolver (`resolveExercise`) before hitting the catalog. Current tools:
`get_current_plan`, `get_today_workout`, `get_current_session`,
`get_session_log`, `get_history`, `get_volume_trend`, `list_exercises`,
`get_upcoming_rides`, `get_recent_activities`, `get_group_feed`, `log_set`,
`delete_set`, `log_activity`, `log_workout_complete`, `add_note`,
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
  `/auth/dev`. 31 test suites cover the full surface. Schema changes mean a
  new numbered file in `migrations/`.
