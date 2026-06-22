# tres-fort

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
audit_log, oauth_*, intervals_oauth_states, groups, group_members,
group_invites, external_activities, activities, external_events,
session_load_exports. Plan tree is a **versioned document** (optimistic
concurrency); sets/notes are an **append-only event log** (client-UUID
idempotent, offline-safe) — so two writers never need merge logic.

- REST API for the iOS app (`/api/*`), authenticated with a Worker-issued
  app JWT.
- `GET /api/state` is the single sync pull (versioned plan + session/set
  deltas).

### 2. MCP server — how Claude reads/writes
A Streamable-HTTP MCP server at `/mcp` exposing the same service layer:

- **Read:** `get_current_plan`, `get_today_workout`, `get_current_session`,
  `get_session_log`, `get_history`, `get_volume_trend`, `list_exercises`,
  `get_upcoming_rides`, `get_recent_activities`, `get_group_feed`
- **Write:** `log_set`, `delete_set`, `log_activity`, `log_workout_complete`,
  `add_note`, `update_plan` (transactional, `expected_version` → 409 on
  conflict), `update_exercise`, `swap_exercise`, `add_exercise`, `add_day`,
  `update_day`, `delete_exercise`, `adjust_today`, `set_schedule`,
  `set_planned_session`, `skip_planned_session`, `set_race`,
  `set_periodization`, `add_trip`, `update_trip`, `remove_trip`,
  `set_stress_model`, `refresh_rides`
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
npm test                              # integration tests vs real D1 (34 suites)
npm run typecheck

npx wrangler d1 create tres-fort-db  # first time; paste id into wrangler.jsonc
npx wrangler d1 migrations apply tres-fort-db --remote
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

This is what makes Claude your coach. Pick the path for how you use Claude.
The two credentials below are **Cloudflare Worker secrets you set during
deploy** (`MCP_STATIC_TOKEN`, `OWNER_AUTH_PASSPHRASE`) — keep them in a
password manager; they are never stored in this repo.

### Option A — Claude desktop / claude.ai / Claude mobile (OAuth)

Custom connectors are added on **claude.ai (web) or the Claude desktop
app**. Once added they're tied to your account and usable from the **Claude
mobile app** too. Requires a paid Claude plan (Pro/Max); custom connectors
aren't on the free tier.

1. **Settings → Connectors → Add custom connector.**
2. **Name:** anything (e.g. `Très Fort`).
3. **URL:** `https://<your-worker>.workers.dev/mcp`
4. **Leave the Advanced fields (OAuth Client ID / Secret) blank** — the
   server supports Dynamic Client Registration (RFC 7591), so Claude
   registers itself automatically. Click **Add**.
5. Claude discovers the OAuth endpoints and opens a **consent screen**
   titled "Connect tres-fort" with an **Owner passphrase** field.
6. Enter your `OWNER_AUTH_PASSPHRASE` → **Authorize**. The connector now
   shows as **Connected** (single-user gate — only someone with the
   passphrase can ever link a client).
7. In a new chat, make sure the connector is enabled, and ask
   *"what's my current plan?"* — it should call `get_current_plan` and
   read your live database.

> The OAuth flow uses PKCE + refresh tokens, all served by the Worker
> itself (no third-party auth provider). Tokens are stored in your D1.

### Option B — Claude Code (static bearer)

```bash
claude mcp add --transport http --scope user tres-fort \
  https://<your-worker>.workers.dev/mcp \
  --header "Authorization: Bearer <MCP_STATIC_TOKEN>"
```

Restart Claude Code, then in a fresh session ask *"what's my plan?"*.

### Cost

Talking to Claude with this connector is **normal Claude usage on your
subscription plan** — MCP tool calls are just tool-use inside a chat. The
backend contains **no AI** (the Worker is pure data), so the pay-per-token
Anthropic API is never involved. Cloudflare Workers + D1 stay within the
free tier at single-user scale.

### Using it

Once connected, in any chat: *"build me a 4-day upper/lower, double
progression on the main lifts"*, *"swap RDL for good mornings Wednesday"*,
*"add a deadlift day"*, *"I'm beat today, drop the volume"*, *"how's bench
trending?"*. Claude reads/writes your plan and history live via the tools;
you execute and log in the iOS app. Both sides share one database.

## iOS: build

```bash
cd ios
xcodegen generate          # regenerate TresFort.xcodeproj from project.yml
open TresFort.xcodeproj
```

Use the **TresFort** scheme (never the widget-extension scheme). Automatic
signing is preconfigured; set your own `DEVELOPMENT_TEAM` and
`PRODUCT_BUNDLE_IDENTIFIER` in `ios/project.yml` if you fork. Distribution is
TestFlight (internal).

## Status

All design milestones (a–i) built: backend + D1, MCP read/write tools, iOS
Sign in with Apple, guided runner, History/charts, Live Activity, font
polish, and a TestFlight-ready signed archive.

Post-milestone additions:
- **intervals.icu integration** — per-user credentials (API key or OAuth),
  ride/activity sync (`/auth/intervals` OAuth flow, webhook-driven via
  `external_events`), upcoming-ride awareness baked into workout planning.
- **Groups & invites** — friend/family containers with invite-code sign-up;
  group activity feed (`get_group_feed`) visible to Claude.
- **Multisport (endurance) coaching** — one adaptive plan spans strength +
  endurance: race goals (`set_race`), periodization phases
  (`set_periodization`), travel/rest/injury blackouts (`add_trip`), and a
  multi-dimensional stress model (`set_stress_model`) so training load is
  never collapsed to a single number. See `docs/MULTISPORT.md`.

## License

Personal project. Bundled fonts (Bebas Neue, JetBrains Mono) are SIL Open
Font License.
