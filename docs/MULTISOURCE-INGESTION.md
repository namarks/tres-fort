# DESIGN: Direct Multi-Source Activity Ingestion

**Status:** Proposal + in-progress build · **Scope:** backend (Worker + D1) + iOS · **Companion to:** `docs/DESIGN.md`

> ## Implementation status (kept current as we build)
>
> - **Phase 0 — multi-source substrate: ✅ DONE & tested.** Migration `0027`
>   adds dedup columns (`canonical`, `duplicate_of`); the intervals reconcile
>   soft-delete + count are **source-scoped to `'intervals'`** (`src/db.ts`
>   `syncExternalActivities`) so a push/pull from any other source is never
>   tombstoned. Regression guard in `test/intervals.test.ts`
>   ("MULTI-SOURCE GUARD"). Intervals behaviour byte-for-byte unchanged.
> - **Phase 1 — Apple Health, backend half: ✅ DONE & tested.** `POST
>   /api/activities/healthkit` (`src/routes/api.ts`) + `upsertHealthKitActivity`
>   (`src/db.ts`): client-UUID-idempotent push into `external_activities` with
>   `source='healthkit'`. `training_load` left NULL (no per-user HR anchor to
>   derive hrTSS — not fabricated). Tests in `test/healthkit.test.ts`.
> - **Phase 1 — remaining:** (a) **group-feed opt-in gating** so HealthKit
>   activities aren't shown cross-user without consent (Open Decision #5 —
>   opt-in granularity); (b) **cross-source dedup** logic using the `0027`
>   columns (Open Decisions #3/#4); (c) **iOS HealthKit** capability + sync
>   service + push + settings UI — Swift that needs an Xcode + physical-device
>   build to verify (HealthKit returns nothing on the simulator).
> - **Scoping note vs §4 below:** the OAuth/`providers.ts` generalization is
>   **deferred to Phase 2 (Polar)**, where a real second OAuth provider shapes
>   the abstraction — building it now with only intervals would be speculative
>   generality on the critical sync path. Phase 0 here is the data-layer
>   substrate (source-scoping + dedup columns), which is all Phase 1 needs.

## 1. Executive summary

Today the only external-activity source is intervals.icu, isolated behind `src/intervals.ts` and reconciled into the `external_activities` cache by `syncExternalActivities` (`src/db.ts:5078`). That forces every endurance athlete who wants ride/run data in their coaching context to maintain an intervals.icu account. This design adds **direct** ingestion from the athlete's actual data source so intervals.icu becomes optional — one adapter among several, not the only door.

The honest finding up front: **there is no single clean answer**, because the providers split into three architecturally different classes:

- **Direct server OAuth connectors** (Polar, Wahoo) — a Worker route can hold a per-user token and pull/receive activities server-side, exactly mirroring the intervals.icu pattern. These are buildable today, modulo a developer-program review.
- **iOS-on-device-only** (Apple Health / HealthKit) — no server API exists at all; the Cloudflare Worker can *never* reach this data. The iOS app is the only reader and must push to the backend.
- **Not directly connectable** (Zwift, Google Fit / Health Connect, Garmin-direct-today) — gated, suspended, deprecated, or Android-only. For these the realistic path remains the intermediary (intervals.icu) we already have.

The schema is already multi-source-ready: `external_activities.source` exists (migration `0015`) but is hardcoded to `'intervals'` everywhere, and the PK was re-keyed to embed `user_id` (migration `0019`) precisely because provider activity IDs collide across athletes. The work is to **generalize the code to match the schema**, add a per-provider adapter seam, a generic outbound-OAuth framework, an iOS HealthKit push path, and — critically — a **cross-provider dedup** strategy so the same ride arriving from two connected sources doesn't double-count.

### Feasibility verdict table

| Provider | Verdict | Where it runs | Auth | Delivery | Training-load data | Effort | Approval lead time |
|---|---|---|---|---|---|---|---|
| **intervals.icu** | **Shipped** (keep) | Worker | OAuth 2.0 (no PKCE) + API key | Poll + webhook | hrTSS computed by intervals | — | none |
| **Polar AccessLink** | **Build-now server connector** | Worker | OAuth 2.0 auth-code (client_secret, **not** PKCE), non-expiring tokens | EXERCISE webhook (HMAC-SHA256) + poll | Native `training_load` per exercise | M | self-serve instant; possible user-cap → commercial talk |
| **Wahoo Cloud API** | **Build-now server connector (gated)** | Worker | OAuth 2.0 auth-code confidential client (+ refresh, 2h tokens) | `workout_summary` webhook + poll | TSS cycling-power only; **we compute hrTSS** | M | self-serve register, **manual prod approval** (no published SLA) |
| **Apple Health / HealthKit** | **iOS-on-device only** | iOS app | On-device per-type consent; app-JWT to our backend | On-device anchored sync + opportunistic background | **No** native load; we compute hrTSS from HR+duration | M | none (App Review + usage string only) |
| **Garmin Connect** | **Needs-approval, not actionable now** | Worker (if approved) | OAuth 2.0 + PKCE | Webhook push (full summary) | **Native TSS** for cycling-power | L | **Enterprise-only + program suspended to new applicants (2026)** |
| **Zwift** | **Not directly connectable** | n/a | Partner-gated Training API | n/a (partner only) | downstream-computed | — | partner approval; hobby apps refused |
| **Google Fit / Health Connect** | **Not possible** | n/a | Fit REST closed since 2024-05-01; Health Connect = Android on-device only | n/a | n/a | XL (net-new Android app) | n/a |

Be explicit with stakeholders: **Zwift, Apple Health, and Google Fit are NOT direct server OAuth connectors.** Apple Health is reachable only through the iOS app; Zwift and Google Fit are not reachable at all for an app of this type without an intermediary.

---

## 2. Unified, provider-agnostic ingestion architecture

The design principle is unchanged from `CLAUDE.md`: **all D1 access goes through `src/db.ts`; route handlers and MCP tools are thin wrappers.** We keep one normalized model and one reconciled cache, and we add a thin per-provider adapter layer below `db.ts`.

### 2.1 Normalized activity model (reuse what exists)

We do **not** invent a new table or DTO. Every source normalizes to the existing `CompletedActivity` DTO (`src/types.ts:294`) and lands in the existing `external_activities` cache. That DTO already carries the load-bearing fields: `external_id`, `date` (device-local civil `YYYY-MM-DD`, sliced verbatim — **no tz math**), `start_date_local_ms` (ordering only), `kind`, `name`, durations, distance, power, HR, `training_load`, `intensity`, calories, elevation, `raw`. iOS already decodes `ExternalActivity` verbatim (`ios/TresFort/Models.swift:313`, frozen per migration `0015`) and `GET /api/state` returns it on the `activities_since` watermark. **Reusing `external_activities` means zero sync-surface change** — no new cursor, no new iOS Decodable, no `projectCalendar` change.

Two schema generalizations are required (one new migration, `0027`):

1. **`source` becomes meaningful, not literal.** It already exists; we start writing real provider keys (`intervals` | `polar` | `wahoo` | `healthkit` | …).
2. **The reconcile must become source-scoped.** This is the central gotcha (see §2.6). The soft-delete reconcile (`src/db.ts:5248`) is currently scoped to `user_id` + window only. With two sources writing for one user, each sync would tombstone the other's rows. The `WHERE` clause for the "unseen → soft-delete" step **must add `AND source = ?`**.

The PK already embeds `user_id` (migration `0019`); for multi-source we also fold the provider into the conflict key so two providers' identical `external_id`s never collide. The id-generation in `syncExternalActivities` (`src/db.ts:5187`) currently embeds `userId`; generalize it to `\`${source}:${userId}:${external_id}\``.

### 2.2 Per-provider adapter modules (isolated the way `src/intervals.ts` is)

`src/intervals.ts` is the template: an isolated module with an **injectable fetcher**, dormant when no credentials are set. Each new provider gets a sibling module exposing the same shape:

```
src/intervals.ts   (exists)  — intervals.icu adapter
src/polar.ts       (new)     — Polar AccessLink adapter
src/wahoo.ts       (new)     — Wahoo Cloud API adapter
src/providers.ts   (new)     — the adapter registry + interface
```

The adapter interface, distilled from the existing intervals seam (`fetchCompletedActivities` at `src/intervals.ts:232`, `kindOf` at `:66`, `isTresFortExport` at `:361`):

```ts
interface ActivityProvider {
  key: 'intervals' | 'polar' | 'wahoo';
  // Pull window of completed activities → normalized DTO[]
  fetchCompletedActivities(creds, deps): Promise<ActivityFetchResult>;
  // Coarse type map → ride|run|swim|other  (per-provider kindOf)
  kindOf(rawType: unknown): string;
  // Skip our own exported lift rows so the cache stays endurance-only
  isTresFortExport(raw: unknown): boolean;
  // OAuth descriptor (see 2.3) — null for non-OAuth providers
  oauth: ProviderOAuthConfig | null;
}
```

`isTresFortExport` matters per-provider: the `liftcoach:session:` export marker is a **frozen wire format** (do not rename), and each adapter must keep excluding our own exported lift rows to avoid the self-conflict loop.

`syncExternalActivities` (`src/db.ts:5078`) is generalized to take a provider key, look up the adapter in the registry, load that provider's creds (replacing the hardcoded `getUserIntervalsCreds` at `src/db.ts:398` with a per-provider cred loader), and write rows with the right `source`. The auth-recovery wrapper `fetchIntervalsWithAuthRecovery` (`src/db.ts:4787`) becomes per-provider because refresh semantics differ (intervals/Polar tokens are long-lived; Wahoo refreshes 2h tokens — see §2.7).

### 2.3 Generic outbound OAuth connect framework

**Reuse the `intervalsAuth.ts` pattern, not `src/oauth.ts`.** This is a load-bearing distinction: `src/oauth.ts` is the *inbound* OAuth 2.1 AS that authenticates Claude/MCP *into* this Worker (`validateBearer` at `src/oauth.ts:33`) — wrong direction. The *outbound* connect flow lives in `src/routes/intervalsAuth.ts` and is already provider-generic in shape: server-minted single-use CSRF `state` (`createIntervalsOAuthState` at `src/db.ts:605`, 10-min TTL), `DELETE RETURNING` consume on callback (`consumeIntervalsOAuthState` at `src/db.ts:629`), server-side code exchange with `client_secret`, per-user cred storage, audit, deep-link return to `tresfort://`.

Only five things are provider-specific: scopes, authorize/token URLs, client id/secret env vars, the cred-write target, and (for some) PKCE. Generalize into one router:

```
src/routes/providerAuth.ts   (new, replaces intervalsAuth.ts over time)
  GET  /auth/:provider/start      → mint CSRF state, redirect to authorize URL (+ PKCE if provider needs it)
  GET  /auth/:provider/callback   → consume state, exchange code, store creds, audit, deep-link back
```

The CSRF state table (`intervals_oauth_states`) generalizes to a `provider` column or a new `provider_oauth_states` table. `createIntervalsOAuthState`/`consumeIntervalsOAuthState` are reused as-is (they're already generic plumbing).

**Credential storage — move off the `users` row to a `provider_connections` table.** Today creds live in `users` columns (`intervals_oauth_access_token`, etc., migrations `0022`/`0023`) and `setUserIntervalsCreds` (`src/db.ts:541`) / `setUserIntervalsOAuth` (`src/db.ts:576`) each *null the other scheme's columns*, baked-in to one intervals connection per user. Cramming N providers into the `users` row repeats that mistake N times. Migration `0027` adds:

```sql
provider_connections (
  user_id, provider,                 -- composite key
  access_token, refresh_token, expires_at,
  provider_user_id,                  -- athlete_id / wahoo user.id / polar user
  scopes, webhook_secret,
  auth_error_at,                     -- generalizes intervals_auth_error_at
  connected_at, raw_meta
)
```

intervals.icu keeps its existing `users` columns for back-compat (the existing path must not break — §3); new providers write to `provider_connections`. A later migration can backfill intervals into the table and retire the columns.

### 2.4 Webhook-vs-poll on a Worker (no always-on server)

The Worker is stateless and "always off," so **webhook push is strongly preferred** over polling. Both supported providers push:

- **Polar:** subscribe to the `EXERCISE` event; payload is `{event, user_id, entity_id, timestamp, url}` with **HMAC-SHA256** signature — the Worker validates the signature, then GETs the exercise URL. Caveat: a Polar webhook **auto-deactivates after 7 consecutive days of failed delivery**, and there is a mandatory `POST /v3/users` register-user step after OAuth before any data request succeeds.
- **Wahoo:** single app-level webhook URL receives `workout_summary` POSTs; **payload is self-contained** (no follow-up GET). Requires the `offline_data` scope so events fire when the app is closed; verify the echoed `webhook_token` shared secret and reject POSTs missing it. Retry ladder 30min → 4h → 24h → 72h.

Implementation mirrors the existing webhook receiver (`src/routes/webhooks.ts:127`, the intervals webhook). Add routes under the same file or a sibling:

```
POST /webhooks/polar    → verify HMAC, GET exercise, normalize, upsert (source='polar')
POST /webhooks/wahoo    → verify webhook_token, normalize from payload, upsert (source='wahoo')
```

**Poll is the safety net, not the primary.** A Cron Trigger (existing fan-out at `src/index.ts:64`) does two jobs: (1) backfill on connect (one unbounded-ish pull through `GET /v3/exercises` / `GET /v1/workouts`), and (2) periodic reconcile so a Worker outage or Polar's 7-day auto-deactivation doesn't silently stop ingestion. The cron fan-out iterates connected providers per user and calls the generalized `syncExternalActivities(provider, …)`.

### 2.5 iOS HealthKit → backend push path

HealthKit has **no server API** — the Worker can never read it. The iOS app is the only reader, and it pushes to the backend using the existing app-JWT auth (`/auth/apple` → `requireAppJwt`). The push endpoint parallels the existing generic-log endpoint `POST /api/activities` (`src/routes/api.ts:374` → `logActivity` at `src/db.ts:2324`), which is already client-UUID-idempotent.

iOS work (greenfield — no HealthKit references exist today):

1. Add the **HealthKit capability** and `com.apple.developer.healthkit.background-delivery` entitlement in `ios/project.yml`; regenerate via `cd ios && xcodegen generate`. Add `NSHealthShareUsageDescription` describing coaching use (mandatory or App Review rejects). **Drop** the `healthkit.access` entitlement — that's clinical-only and not needed.
2. A HealthKit sync service: anchored `HKAnchoredObjectQuery` over `.workoutType()` on launch/foreground — **full backfill on first connect** (HealthKit retains years of history), incremental by stored anchor after. Enrich each `HKWorkout` via `statistics(for:)` for energy/distance (the old `totalEnergyBurned`/`totalDistance` initializer properties are **deprecated as of iOS 18** — use `statistics(for:)`), and a time-predicated `heartRate` `HKSampleQuery` for avg/max HR (HR is not a workout property).
3. `HKObserverQuery` + `enableBackgroundDelivery` for opportunistic near-real-time — but treat **anchored foreground sync as the source of truth**; background delivery is documented-but-flaky and does not fire when the app is force-quit.
4. POST each workout with a **client-generated stable UUID** as the idempotency key (mirror the append-only/dedup pattern already used for `set_logs`).

**Backend write target — this is a design fork (Open Decision #2).** HealthKit pushes are *append-style* (the device says "here's a workout"), but `external_activities` is a *server-owned reconciled cache* that **soft-deletes rows it didn't see** in the last sync. If HealthKit rows are written into `external_activities`, the next Polar/Wahoo/intervals reconcile would tombstone them as "not seen." Three options:

- **(a) Source-scoped reconcile + write to `external_activities` with `source='healthkit'`.** Requires the §2.6 source-scoped `WHERE`, and the HealthKit "sync" must itself reconcile its own source (which is fine — the iOS app does a full anchored pass). Keeps one read path, one calendar projection. **Recommended.**
- (b) Write HealthKit pushes to the append-only `activities` table (`ActivityRow`, `src/types.ts:324`) instead. Avoids reconcile entirely but splits the read path and excludes HealthKit from `getRecentActivities`/`projectCalendar` unless those are taught to union both tables.
- (c) A dedicated `healthkit_activities` table with its own cursor/array/Decodable — most isolation, most surface change.

Option (a) is cleanest *iff* we commit to making the reconcile source-scoped, which we need anyway for Polar+Wahoo+intervals coexistence.

### 2.6 Cross-provider dedup (the problem intervals solved for us)

This is the heart of the design. The same Saturday ride can arrive from Wahoo (the head unit), Polar (the watch), HealthKit (Apple Watch), **and** intervals.icu (which itself ingested from one of those). Without dedup the athlete's training load triples and the coach's volume trend is garbage.

There are **two distinct dedup problems**:

**(A) Within one source — already solved.** Each adapter's reconcile is source-scoped (§2.1): UPSERT on `(source, user_id, external_id)`, soft-delete unseen-in-window rows **scoped by `source`**. This must change from the current user+window-only `WHERE` (`src/db.ts:5248`) — add `AND source = ?` — or two sources tombstone each other. This is non-negotiable for any multi-source write into `external_activities`.

**(B) Across sources — new.** Two different `source` rows describe the *same physical activity*. We cannot rely on `external_id` (different per provider). Instead, compute a **dedup key** from intrinsic activity properties and pick one canonical row per key:

- **Dedup key:** `(user_id, date, kind, round(start_date_local_ms / 60s), round(duration_sec / 60s))`. Same civil date, same coarse kind, start within ~1–2 min, duration within ~1–2 min ⇒ same activity. (`start_date_local_ms` is ordering-only/UTC — usable for cross-source matching even though `date` is the civil-date display field.)
- **Canonical-source precedence** when a key has multiple rows, ranked by data richness from the findings: **Garmin (native TSS) > Wahoo/Polar (native load / full fields) > HealthKit (we compute hrTSS) > intervals.icu (may itself be a re-import / Strava stub).** The richest source wins; losers are marked as duplicates, not deleted.
- **Where it runs:** a `dedupeActivities(userId)` pass in `db.ts` invoked after any reconcile/push, writing a `canonical` boolean (or `duplicate_of` pointer) on `external_activities`. Reads that feed coaching — `getRecentActivities` (`src/db.ts:5276` → MCP `get_recent_activities` at `src/mcp/server.ts:1176`), `get_volume_trend`, and `projectCalendar` (`src/db.ts:4372`) — filter to `canonical = 1`. iOS still receives all rows (so it can show provenance) but renders the canonical one; or, simpler, the server hides non-canonical from the sync payload entirely (Open Decision #3).
- **The intervals precedent:** intervals.icu already de-stubs and reconciles Strava-vs-direct duplicates upstream — that's *why* relying on it was painless. Going direct means we inherit that responsibility. The dedup pass IS that inherited responsibility, made explicit.

A new column for `canonical`/`duplicate_of` is part of migration `0027`. This is additive to the frozen `ExternalActivity` contract (new optional field, decoded defensively per `Models.swift:441`).

---

## 3. Coexistence with — and eventual replacement of — intervals.icu

**Do not break intervals.** It is shipped, has live users, and is the *only* viable path for Zwift and Garmin data (both reach the user via intervals today). The migration is strictly additive:

1. **intervals becomes one adapter among many.** Refactor `src/intervals.ts` to satisfy the `ActivityProvider` interface in `src/providers.ts`; register it under key `'intervals'`. Behavior is identical — same tests (`test/calendar.test.ts` parity contract unchanged, `external_activities` shape frozen).
2. **Credential back-compat.** intervals keeps its `users`-row columns initially; the per-provider cred loader returns those for `provider='intervals'` and reads `provider_connections` for everyone else. No forced migration of existing intervals tokens on day one.
3. **Reconcile source-scoping is the enabling change.** The moment a second source writes `external_activities`, the reconcile `WHERE` must be source-scoped (§2.6 A). This is the one change that touches the existing intervals path's behavior — and it's invisible while intervals is the only source (`source='intervals'` everywhere), so it can ship ahead of any new provider with no functional change.
4. **Eventual replacement, not removal.** For an athlete who connects Polar/Wahoo/HealthKit directly, intervals becomes redundant *for ingestion* — but it stays valuable as the Zwift/Garmin intermediary. The end state: intervals is the *fallback* aggregator, direct connectors are the default. We never delete the intervals adapter; we demote it in dedup precedence (§2.6 B) so a direct Wahoo row beats the same ride re-imported via intervals.

---

## 4. Phased build plan (feasibility × coaching value)

Guiding insight from the brief: **HR + duration is enough to compute training load** (hrTSS). A provider that delivers HR is coaching-valuable even with no pace/distance. That makes HealthKit and Polar high-value despite HealthKit lacking any native load metric.

### Phase 0 — Generalize the seam (no new provider)
Ship the provider-agnostic substrate with intervals as the sole adapter, so nothing user-facing changes but everything is ready.
- Migration `0027`: `source`-aware reconcile, `provider_connections` table, dedup column.
- Refactor `src/intervals.ts` → `ActivityProvider`; add `src/providers.ts` registry.
- Source-scope the reconcile `WHERE` (`src/db.ts:5248`) and the id-keying (`src/db.ts:5187`).
- Generalize `syncExternalActivities` and `fetchIntervalsWithAuthRecovery` to take a provider key.
- Generic `src/routes/providerAuth.ts` (intervals routed through it, identical behavior).
- **Exit criterion:** all 32 existing test suites green; intervals path byte-for-byte unchanged.

### Phase 1 — Apple Health / HealthKit (marquee no-intervals path)
Lowest external friction: no OAuth server, no partner approval, no vendor — entirely inside our own iOS app + backend. Highest reach (every iPhone athlete). Delivers HR + duration → hrTSS, plus full backfill on first connect.
- iOS HealthKit capability + sync service + push (§2.5).
- Backend `POST /api/activities/healthkit` upserting `external_activities` with `source='healthkit'` (Open Decision #2 picks the table).
- Backend hrTSS computation for `training_load`/`intensity` (HealthKit has no native load).
- Cross-provider dedup pass (§2.6) lands here, because HealthKit + intervals is the first real two-source case.
- Gate any group-feed surfacing of HealthKit activities behind explicit per-user opt-in (§6).

### Phase 2 — Polar AccessLink (cleanest direct-server connector)
Self-serve, instant credentials; native `training_load`; EXERCISE webhooks fit the always-off Worker better than intervals' polling. First true server-side direct connector → proves the OAuth framework end-to-end.
- `src/polar.ts` adapter; `/auth/polar/*` via `providerAuth.ts`; mandatory `POST /v3/users` register step.
- `POST /webhooks/polar` (HMAC-SHA256 verify) + Cron poll fallback (the 7-day auto-deactivation safety net).
- Disconnect/purge path (ToS s3.3 requires token deletion on revoke).

### Phase 3 — Wahoo Cloud API (gated, but architecturally identical)
Same server-side shape as Polar; self-contained `workout_summary` webhook. Gated on **manual production approval** — start the application in Phase 0/1 (§5) so it's approved by the time code is ready. We compute hrTSS for non-power activities (Wahoo's only TSS is cycling-power).
- `src/wahoo.ts` adapter; `/auth/wahoo/*`; `POST /webhooks/wahoo` (webhook_token verify); refresh-token rotation (2h tokens, 10-token/user cap from Jan 2026, 60-day unrevoked-token deletion — persist+refresh **one** token per user).

### Deferred / not built
- **Garmin direct** — revisit only if the program reopens AND tres-fort is a registered legal entity (enterprise-only + suspended + commercial-permission clause + the MCP-feeds-Claude 5.2(o) question). Until then, Garmin users sync Garmin→intervals for free.
- **Zwift direct** — partner-gated, hobby apps refused; Zwift→intervals stays the path.
- **Google Fit / Health Connect** — dropped (Fit REST closed since 2024-05-01; Health Connect is Android on-device only with no iOS/server path; would be a net-new Android app, XL).

---

## 5. Approval-gate actions to kick off NOW (lead time)

These have external lead time and block later phases, so start them at Phase 0 regardless of code progress:

1. **Wahoo developer registration** — register a **sandbox** app at `developers.wahooligan.com` immediately (instant). Then email `partnerships@wahoofitness.com` / `wahooapi@wahoofitness.com` to get **production approval** for a multi-user AI-coaching + social-feed use case. There is **no published SLA**, and the use case touches three flags Wahoo's terms call out (competitive-use vs SYSTM, cross-user display, caching) — so the email must be honest and is the long pole for Phase 3. Sandbox rate limits (25/5min) are too low for real use until promoted.
2. **Polar** — self-issue `client_id`/`client_secret` at `admin.polaraccesslink.com` (instant, free). **Email `b2bhelpdesk@polar.com` now** to confirm (a) whether a self-serve user cap triggers a commercial agreement at our target scale, and (b) that cross-user group-feed display is acceptable under API Agreement s3.1.1/s2.2. Both are gating answers for the group-feed half of Phase 2.
3. **Apple** — no partner gate, but confirm `NSHealthShareUsageDescription` copy and the HealthKit privacy-nutrition-label entries before the next TestFlight build, since they're submission-time App Review items.
4. **Garmin (watch-only, no action to build)** — note for the record that the program is enterprise-only and suspended; do not apply unless/until tres-fort is a legal entity and the program reopens.

---

## 6. ToS risks — the Strava lesson, generalized

The recurring landmine across **every** provider is **cross-user display in the group feed** (`get_group_feed`, `src/mcp/server.ts`): showing user A's provider-sourced activity to user B. Strava flatly prohibits this; the others permit it only conditionally. Treat group-feed visibility of *any* externally-sourced activity as **off by default, behind an explicit per-user opt-in**, with provenance recorded.

| Provider | Cross-user (group feed) | Other binding constraints |
|---|---|---|
| **Apple Health** | Permitted **with explicit per-user in-app consent** under the health-management carve-out (App Store Guideline 5.1.3) — **not** a Strava-style ban. Must never flow to ads/analytics SDKs. No iCloud storage of HealthKit data (irrelevant to D1, our own service). | Mandatory usage string; degrade gracefully when HR read is denied (Apple hides read-denial). |
| **Polar** | **Gray area** — s3.1.1 forbids distributing Data without explicit Member permission; s2.2 forbids transfer to third parties. Gate behind opt-in **and confirm with Polar in writing** before shipping the feed. | s3.3: delete token (and arguably cached rows) on disconnect/revoke. Competing-service clause s2.2 — sanity-check an AI coach vs Polar Flow. |
| **Wahoo** | **Hard constraint, two clauses.** Consent-gated display clause **plus** a broader "may not disclose Wahoo Data to any third party" clause. Get cross-user display approved **in writing** in the partnership email — do not self-interpret the consent carve-out against the broader clause. | Aggregation/caching restriction (tension with `external_activities` + raw-JSON store) — get the "as expressly permitted" carve-out in writing. 48h purge on Wahoo request + prompt end-user-deletion → wire a `wahoo user_id`-keyed delete path into account deletion. No-modification-of-displayed-data, mandatory attribution logos, no charging end users for API access. |
| **Garmin** (if ever) | **Conditional, not granted** — permitted only inside our own app, with per-user consent + Garmin attribution, judged at Garmin's sole discretion. Plus the unresolved **5.2(o) MCP-feeds-Claude question** (piping Garmin data to a third-party LLM service may need written approval). | n/a until program reopens. |
| **intervals.icu** | Permissive terms (perpetual commercial license, no explicit user-to-user restriction) — but **Garmin-sourced** activities surfaced via intervals carry a Garmin-attribution obligation, and intervals already strips Strava data (those arrive as stubs). | Existing path, already live. |

Concrete backend implications: (1) `external_activities` needs a per-row "may surface in group feed" flag derived from the user's per-provider opt-in; (2) account deletion and per-provider disconnect must **purge** the provider's tokens (and, for Wahoo, cached rows within 48h); (3) attribution/logo UI is iOS work wherever Wahoo (and Garmin) data is displayed.

---

## 7. Open decisions for Nick

1. **Provider priority after HealthKit.** Plan sequences HealthKit → Polar → Wahoo. Polar is self-serve and architecturally cleanest; Wahoo needs manual approval with no SLA. Confirm HealthKit-first (broadest reach, zero external dependency), or pull Polar forward if the endurance cohort skews Polar.
2. **HealthKit write target** (§2.5): (a) `external_activities` with source-scoped reconcile [recommended — one read path], (b) the append-only `activities` table [no reconcile, but splits reads], or (c) a dedicated `healthkit_activities` table [most isolation, most sync-surface change]. Picking (a) commits us to the source-scoped reconcile, which we want regardless.
3. **Dedup visibility in sync** (§2.6 B): does the server (a) send *all* source rows to iOS and let the app render only the canonical one (shows provenance, "also from Polar"), or (b) hide non-canonical rows from the `/api/state` payload entirely (simpler client, loses provenance)? Affects whether the `ExternalActivity` contract gains a `canonical`/`duplicate_of` field.
4. **Dedup match tolerance** (§2.6 B): start/duration rounding window — 1 min is tight (misses paused-vs-elapsed differences), 2–3 min is safe but could merge back-to-back intervals sessions. Recommend 2 min start + duration-within-10% with a same-kind guard; confirm or tune.
5. **Group-feed opt-in granularity** (§6): one global "share my activities" toggle, or per-provider opt-in (needed if we want to honor, e.g., Wahoo's stricter written terms differently from HealthKit's). Per-provider is safer for ToS but more UI.
6. **Commercial-status trigger.** Polar (possible user cap) and Wahoo ("no charging end users for API access," competitive-use) both have clauses that bite if tres-fort monetizes. Decide now whether tres-fort intends to stay free/personal (keeps these self-serve) or commercialize (forces commercial-agreement conversations and may reopen the Garmin enterprise question).
7. **Retire intervals `users`-row creds?** Keep intervals creds on the `users` row indefinitely for back-compat, or schedule a follow-up migration to backfill them into `provider_connections` and drop the columns (cleaner, but a forced token migration for live users).

---

### Key file references (for the implementer)
- Adapter seam: `src/intervals.ts:232` (`fetchCompletedActivities`), `:66` (`kindOf`), `:361` (`isTresFortExport`)
- Reconcile/cache: `src/db.ts:5078` (`syncExternalActivities`), `:5187` (id-keying — generalize), `:5248` (soft-delete `WHERE` — **must source-scope**), `:4787` (`fetchIntervalsWithAuthRecovery` — per-provider refresh)
- Cred storage: `src/db.ts:398` (`getUserIntervalsCreds`), `:541`/`:576` (setters that null the other scheme), → new `provider_connections`
- Outbound OAuth (reuse): `src/routes/intervalsAuth.ts`; CSRF helpers `src/db.ts:605`/`:629`. **Not** `src/oauth.ts` (inbound AS).
- Webhooks: `src/routes/webhooks.ts:127`; cron fan-out `src/index.ts:64`; route mount `src/index.ts:25`
- iOS push template: `src/routes/api.ts:374` (`POST /api/activities`) → `src/db.ts:2324` (`logActivity`)
- Reads to filter on `canonical`: `src/db.ts:5276` (`getRecentActivities`) → `src/mcp/server.ts:1176`; `projectCalendar` `src/db.ts:4372`
- Frozen contracts: `src/types.ts:294` (`CompletedActivity`), `ios/TresFort/Models.swift:313` (`ExternalActivity`, `:441` defensive decode), `test/calendar.test.ts` (parity)
- New migration: `migrations/0027_multi_source_activities.sql` (after `0026`); run via `npm run release` (migrate-remote **before** deploy)