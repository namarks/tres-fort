# lift-coach

An AI-coached lifting system. **Claude is the coach** — it owns and adapts your
training plan through conversation (via MCP). A **native iOS app** is the gym
executor: you run the workout and log sets there. A **Cloudflare Worker + D1**
is the single source of truth that both Claude and the app read and write.

The app deliberately has no in-app chat and is read-mostly for the plan. You
talk to Claude (in the Claude app, desktop, or Claude Code) to build, adjust,
and analyze training; the app just reflects the current plan and logs work.

```
   Claude (any chat)          iOS app (SwiftUI)
        │  MCP                      │  REST + Sign in with Apple
        ▼                           ▼
        └────────► Cloudflare Worker + D1 ◄────────┘
                   (single source of truth)
```

> Full design rationale, schema, and API/MCP surface: [`docs/DESIGN.md`](docs/DESIGN.md).

## Three parts

### 1. Backend — Cloudflare Worker + D1
One Worker (Hono) over a D1 (SQLite) database. Tables: users, exercises,
plans, day_templates, template_exercises, sessions, set_logs, notes,
audit_log, oauth_*. Plan tree is a **versioned document** (optimistic
concurrency); sets/notes are an **append-only event log** (client-UUID
idempotent, offline-safe) — so two writers never need merge logic.

- REST API for the iOS app (`/api/*`), authenticated with a Worker-issued
  app JWT.
- `GET /api/state` is the single sync pull (versioned plan + session/set
  deltas).

### 2. MCP server — how Claude reads/writes
A Streamable-HTTP MCP server at `/mcp` exposing the same service layer:

- **Read:** `get_current_plan`, `get_today_workout`, `get_current_session`,
  `get_session_log`, `get_history`, `get_volume_trend`
- **Write:** `log_set`, `log_workout_complete`, `add_note`, `update_plan`
  (transactional, `expected_version` → 409 on conflict), `update_exercise`,
  `swap_exercise`, `add_exercise`, `add_day`, `adjust_today`
- **Resource:** `coach://state/current` — a compact brief Claude can read at
  chat start. Plus a `coach_brief` prompt.

Every write records an `audit_log` row and a Claude-authored note (the
single-user substitute for per-tool scopes).

**Auth (dual):**
- **Static bearer** — trivial for Claude Code / curl.
- **OAuth 2.1** (RFC 9728 / 8414 / 7591, PKCE, refresh, single-user
  passphrase consent) — for claude.ai / Claude desktop custom connectors.

### 3. iOS app — the gym executor
SwiftUI, iOS 17+, XcodeGen-managed. A guided **workout runner**:

- Sign in with Apple → app JWT.
- Overview → **START** → one exercise at a time: progress bar, jump pills
  (reorder on the fly when a rack's taken), inline steppers, auto-advance.
- Full-screen rest overlay; **Live Activity** rest timer on the Lock Screen
  / Dynamic Island (local, no push).
- Whole-workout stopwatch + per-set duration; **timed exercises** (planks/
  holds) become a START SET countdown that auto-logs.
- History tab with Swift Charts (estimated-1RM and set-duration trends).
- Type set in Bebas Neue + JetBrains Mono.

## Layout

```
src/                TypeScript Worker (Hono): REST + MCP + OAuth
migrations/          D1 schema + seed
test/                vitest integration tests (real D1 in Workers runtime)
ios/                 XcodeGen project (app + Live Activity widget extension)
docs/DESIGN.md       system design doc
```

## Backend: develop & deploy

```bash
npm install
npm test                              # 25 integration tests vs real D1
npm run typecheck

npx wrangler d1 create lift-coach-db  # first time; paste id into wrangler.jsonc
npx wrangler d1 migrations apply lift-coach-db --remote
# secrets (set once, write-only):
npx wrangler secret put APP_JWT_SECRET
npx wrangler secret put MCP_STATIC_TOKEN
npx wrangler secret put OWNER_APPLE_SUB        # lock to your Apple `sub`
npx wrangler secret put OWNER_AUTH_PASSPHRASE  # OAuth consent gate
npx wrangler deploy
```

No secrets are committed; they live only as Cloudflare Worker secrets.
`wrangler.jsonc` carries non-sensitive config (D1 id, bundle id).

## Connect Claude to the MCP server

**Claude Code (static bearer):**

```bash
claude mcp add --transport http --scope user lift-coach \
  https://<your-worker>.workers.dev/mcp \
  --header "Authorization: Bearer <MCP_STATIC_TOKEN>"
```

**Claude desktop / claude.ai:** add a custom connector pointing at
`https://<your-worker>.workers.dev/mcp`; it auto-discovers OAuth — enter the
owner passphrase once on the consent screen.

Then, in any chat: *"build me an upper/lower plan"*, *"swap RDL for good
mornings Wednesday"*, *"I'm beat today, drop the volume"*, *"how's bench
trending?"*.

## iOS: build

```bash
cd ios
xcodegen generate          # regenerate LiftCoach.xcodeproj from project.yml
open LiftCoach.xcodeproj
```

Use the **LiftCoach** scheme (never the widget-extension scheme). Automatic
signing is preconfigured; set your own `DEVELOPMENT_TEAM` and
`PRODUCT_BUNDLE_IDENTIFIER` in `ios/project.yml` if you fork. Distribution is
TestFlight (internal).

## Status

All design milestones (a–i) built: backend + D1, MCP read/write tools, iOS
Sign in with Apple, guided runner, History/charts, Live Activity, font
polish, and a TestFlight-ready signed archive.

## License

Personal project. Bundled fonts (Bebas Neue, JetBrains Mono) are SIL Open
Font License.
