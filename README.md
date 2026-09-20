# tres-fort

An AI-coached lifting system. **Bring your own AI coach** — connect Codex, Claude,
or another compatible AI app to adapt your training plan through MCP. A **native iOS app** is the gym
executor: you run the workout and log sets there. A **Cloudflare Worker + D1**
is the single source of truth that both your AI coach and the app read and write.

The app has no in-app chat. Members can create routines, edit workouts and
assign workout/rest dates directly; your AI coach can also build, adjust and analyze
training through MCP. Both clients use the same versioned plan writers.

```
   Your AI app               iOS app (SwiftUI)
        │  MCP                      │  REST + Sign in with Apple
        ▼                           ▼
        └────────► Cloudflare Worker + D1 ◄────────┘
                   (single source of truth)
```

> Full design rationale, schema, and API/MCP surface: [`docs/DESIGN.md`](docs/DESIGN.md).

## Three parts

### 1. Backend — Cloudflare Worker + D1
One Worker (Hono) over a D1 (SQLite) database. Tables: users, exercises,
plans, workouts, template_exercises, sessions, set_logs, notes,
audit_log, oauth_*, intervals_oauth_states, groups, group_members,
group_invites, external_activities, activities, external_events,
session_load_exports. Plan tree is a **versioned document** (optimistic
concurrency); sets/notes are an **append-only event log** (client-UUID
idempotent, offline-safe). Corrections and session attempts have explicit
concurrency guards; sync merges deltas and tombstones by stable ID.

- REST API for the iOS app (`/api/*`), authenticated with a Worker-issued
  app JWT.
- `GET /api/state` is the single sync pull (versioned plan + session/set
  deltas).

### 2. MCP server — how AI apps read/write
A Streamable-HTTP MCP server at `/mcp` exposing the same service layer:

- **Read:** `get_coach_brief`, `get_current_plan`, `get_today_workout`, `get_current_session`,
  `get_session_log`, `get_history`, `get_volume_trend`, `list_exercises`,
  `get_upcoming_rides`, `get_recent_activities`, `get_group_feed`
- **Write:** `log_set`, `correct_set`, `delete_set`, `log_activity`, `log_workout_complete`,
  `discard_workout` (explicit session ID and expected attempt; soft-deletes its sets),
  `add_note`, `update_plan` (transactional, `expected_version` → structured
  `{conflict, current_version}` result on mismatch), `update_exercise`,
  `swap_exercise`, `add_exercise`, `add_workout`,
  `update_workout`, `delete_workout`, `delete_exercise`, `adjust_today`, `set_schedule`,
  `set_planned_session`, `skip_planned_session`, `set_race`,
  `set_periodization`, `add_trip`, `update_trip`, `remove_trip`,
  `set_stress_model`, `refresh_rides`
- **Resource:** `coach://state/current` — a compact brief clients can read at
  chat start. Plus a `coach_brief` prompt.

Writes record an `audit_log` trail; plan changes also record a coaching note.
`discard_workout` uses the shared discard audit and an identical retry adds no
second entry. These records preserve per-user attribution across clients.

**Auth (dual):**
- **Static bearer** — operator-only access; never distributed to members.
- **OAuth 2.1** (RFC 9728 / 8414 / 7591, PKCE, refresh, per-user
  passphrase consent) — for Codex, Claude, and other compatible remote MCP clients.

### 3. iOS app — the gym executor
SwiftUI, iOS 17+, XcodeGen-managed. A guided **workout runner**:

- Sign in with Apple → app JWT.
- Overview → **START** → one exercise at a time: progress bar, jump pills
  (reorder on the fly when a rack's taken), inline steppers, auto-advance.
- Full-screen rest overlay; **Live Activity** rest timer on the Lock Screen
  / Dynamic Island (local, no push); a chime + haptic + spoken cue when rest
  ends (headphones-friendly, default on).
- **Edit workout** sheet (from Today or the runner's overflow menu): add /
  remove / reorder exercises and warm-ups in place — writes straight to the
  same versioned plan tree your coach edits.
- Whole-workout stopwatch + per-set duration; **timed exercises** (planks/
  holds) become a START SET countdown that auto-logs.
- Account-scoped JSON snapshots and durable outboxes in UserDefaults provide
  cached browsing and safe retries. SyncModel publishes in-memory state; it
  does not use SwiftData. Disposable indexes accelerate history queries.
- History tab with Swift Charts (estimated-1RM and set-duration trends).
- Type set in Bebas Neue + JetBrains Mono.

## Layout

```
src/                TypeScript Worker (Hono): REST + MCP + OAuth
migrations/          D1 schema + seed
test/                vitest integration tests (real D1 in Workers runtime)
ios/                 XcodeGen project (app + Live Activity widget extension)
docs/DESIGN.md       system design doc
docs/plans/          canonical engineering workstream plans
docs/initiatives/    cross-plan initiatives (plans of plans)
```

## Backend: develop & deploy

```bash
npm install
npm test                              # integration tests vs real D1 (31 suites)
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

## Connect your AI coach

Open the iOS app → **Profile → Coach → Set up your AI coach**. Choose Codex,
Claude, or Other compatible app, review the data-sharing disclosure, and generate
a personal connect code. Enter that code only on the Très Fort consent page.
Every member uses their own account; no operator secret or group membership is needed.

For Codex, add the server through the desktop app's **Settings → Plugins → Add →
Add MCP server** form (older versions use **Settings → MCP servers**). Choose
**Streamable HTTP**, enter the URL shown in setup, save and authenticate.
Terminal commands are optional under **Advanced**. This desktop connection does
not install a hosted plugin for ChatGPT on iPhone or the web; a full mobile
install-and-authorize button requires publishing the integration in the provider's
directory. See the connection guide for that delivery path.

Claude setup uses its custom-connector settings. Other apps must support remote
Streamable HTTP MCP, OAuth discovery, Dynamic Client Registration, PKCE S256,
and refresh tokens. A model name or API key alone is not a connection.
[Connection guide and compatibility checks](docs/COACH-CONNECTIONS.md).

Start a conversation with “Use Très Fort to load my coaching brief.” The coach
reads the same plan and history as the app. Ask explicitly for changes; logging
sets in iOS does not authorize the coach to duplicate those logs.

### Product and usage model

The free product lets members bring their own supported AI accounts or subscriptions.
Conversations and model execution stay in their chosen app, under that app's
availability, billing and usage limits. Très Fort supplies authenticated data tools
and pays its own infrastructure costs; it does not supply model API credits.
A future paid package could include in-app coaching and API usage if economics
support it. No in-app model runner, provider key storage, pricing, or billing is
implemented or enabled by this version.

### Connection lifecycle

Multiple AI apps can connect to one member's plan. Profile reports aggregate coach
access. **Disconnect all AI apps** revokes that member's OAuth connections,
while preserving training records and other members' connections. Rotating the
connect code does not revoke existing grants. Removing the connection cannot
remove information already retrieved into an AI conversation.

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
- **Groups & invites** — friend/family containers with invite-code sign-up,
  Universal Link `/join/:code` invite cards (rich preview + AASA, falls back
  to in-app manual code entry); group activity feed (`get_group_feed`)
  visible to Claude.
- **Multisport (endurance) coaching** — one adaptive plan spans strength +
  endurance: race goals (`set_race`), periodization phases
  (`set_periodization`), travel/rest/injury blackouts (`add_trip`), and a
  multi-dimensional stress model (`set_stress_model`) so training load is
  never collapsed to a single number. See `docs/MULTISPORT.md`.
- **Apple Health (HealthKit) direct connector** — a second activity source
  alongside intervals.icu: since the Worker can never read HealthKit itself,
  the iOS app pushes workouts to `POST /api/activities/healthkit`, cached
  into `external_activities` with `source='healthkit'`. A per-user opt-in
  gates whether these rows are visible to other group members. See
  `docs/MULTISOURCE-INGESTION.md`.

## License

Personal project. Bundled fonts (Bebas Neue, JetBrains Mono) are SIL Open
Font License — see `ios/TresFort/Fonts/OFL-*.txt`.

### Reproducible iOS verification

See [iOS verification](docs/IOS-VERIFICATION.md) for the unsigned simulator command,
synthetic UI fixtures, retained evidence, and required CI checks.
