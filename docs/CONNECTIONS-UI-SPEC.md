# iOS spec: Connections UI (multi-source)

Implementation spec for the connections settings surface. Companion to
`docs/MULTISOURCE-INGESTION.md` (architecture) and the mockups reviewed in
session. Goal: replace the intervals-only `IntervalsSettingsView` with a
guided, multi-source **Connections** screen that recommends intervals.icu as
the primary connection while keeping zero-account options one tap away.

> **Build environment:** HealthKit returns nothing on the simulator — the
> Apple Health path must be built and verified on a **physical device** with
> real Health data. Everything else (intervals, layout, copy) builds on the sim.

---

## 1. Scope — what's live vs. placeholder

| Source | Connect mechanism | Backend status | UI in v1 |
|---|---|---|---|
| **intervals.icu** | OAuth (or API key) — existing | Live (shipped) | **Live, recommended hero** |
| **Apple Health** | On-device HealthKit → push | Ingest endpoint live (PR #80); group-feed gating TODO | **Live** (this build) |
| **Garmin** | OAuth server connector | Not built — program enterprise-only + suspended | **"Coming soon"** row, disabled |
| **Polar** | OAuth server connector | Not built — Phase 2 | **"Coming soon"** row, disabled |
| **Wahoo** | OAuth server connector | Not built — Phase 3, approval-gated | **"Coming soon"** row, disabled |

**Do not ship live Connect buttons for Garmin/Polar/Wahoo** — their backends
don't exist. Render them as disabled "Coming soon" rows so the information
architecture is visible without misleading users. Gate them behind a single
`ConnectionsFeature.comingSoonSources` constant so they flip to live per phase.

---

## 2. Information architecture

```
ConnectionsView (list)              ← replaces IntervalsSettingsView as the entry
 ├─ Recommended:  intervals.icu  → IntervalsDetailView   (existing logic, +opt-in)
 ├─ Direct:       Apple Health   → AppleHealthDetailView  (new)
 │                Garmin         → ComingSoonDetailView
 │                Polar          → ComingSoonDetailView
 │                Wahoo          → ComingSoonDetailView
 ├─ Merge note (info callout)
 └─ Strava caveat (warning callout)
```

Suggested files (new group `ios/TresFort/Connections/`):
- `ConnectionsView.swift` — the list (this spec, §3)
- `IntervalsDetailView.swift` — move/rename existing `IntervalsSettingsView`
  body here, add the group-feed opt-in toggle (§5)
- `AppleHealthDetailView.swift` — new (§5)
- `HealthKitSync.swift` — the HealthKit reader + push service (§6)
- `ComingSoonDetailView.swift` — generic placeholder (§5)

Keep the existing entry point working: whatever currently pushes
`IntervalsSettingsView` should push `ConnectionsView` instead.

---

## 3. Screen: ConnectionsView (the list)

Sections, top to bottom. All copy is final (sentence case, no Title Case).

**Nav title:** `Connections`

**Header subtitle (below title):**
> Connect where your workouts are recorded, so your coach can see your cardio and balance it against your lifting.

**Section "Recommended" — intervals.icu hero card** (accent border, badge):
- Icon: `chart.line.uptrend.xyaxis` (SF Symbol)
- Title: `intervals.icu`  · Badge: `Recommended`
- Subtitle: `One hub for Garmin, Zwift, Polar & Wahoo — with the richest training data`
- Primary button: `Connect intervals.icu` → pushes `IntervalsDetailView`
  (or, if already connected, the card shows the connected summary — see states §4)
- Helper link (below button): `New to intervals.icu? Set up your device` →
  pushes the setup-helper flow (separate spec; for v1 may deep-link to
  `https://intervals.icu` via `IntervalsOAuth`/Safari until the guided flow exists)

**Section "Or connect directly — no extra account":** grouped list rows:
- **Apple Health** — icon `heart`, subtitle `Simplest — your iPhone & Apple Watch, no new account` → `AppleHealthDetailView`
- **Garmin** — icon `applewatch`, subtitle `If you record on a Garmin watch or bike computer` — disabled, trailing `Coming soon`
- **Polar** — icon `waveform.path.ecg`, subtitle `If you train with a Polar watch` — disabled, trailing `Coming soon`
- **Wahoo** — icon `bicycle`, subtitle `If you use a Wahoo bike computer` — disabled, trailing `Coming soon`

**Info callout (merge):**
> Connect more than one? We automatically merge duplicate workouts — you won't see the same ride twice.

(This is the UX surface for the cross-source dedup deferred in PR #80; copy and
backend dedup must ship together — don't show this promise before dedup exists.)

**Warning callout (Strava):**
> Using Strava? Strava-synced activities arrive without details. Connect intervals.icu or your device directly instead.

---

## 4. States (per source)

Each source row / hero renders one of:

| State | Trigger | Display |
|---|---|---|
| **Not connected** | no creds / not authorized | subtitle = the decision-aid copy; action = Connect |
| **Connecting** | OAuth sheet / HK auth in flight | spinner on the button |
| **Connected** | see source-specific truth below | green check + `Connected` + status line |
| **Syncing / synced** | last successful sync known | `synced 2h ago` (relative) |
| **Needs attention** | auth error / no data found | amber line, e.g. `Reconnect needed` or `No workouts found yet` |
| **Coming soon** | placeholder sources | disabled row, trailing `Coming soon` |

**Connected truth by source:**
- **intervals.icu** — server truth: `GET /api/me` → `me.intervals.connected`,
  `athlete_id`; reconnect-needed when the server reports an auth error
  (`intervals_auth_error_at`). Already wired via `groupModel.me` /
  `groupModel.intervalsConnection`.
- **Apple Health** — **on-device, and Apple deliberately hides READ-permission
  status** (`authorizationStatus(for:)` is unreliable for reads, to avoid
  leaking that the user declined). So do NOT trust the auth status enum for
  "connected." Instead track locally: a `UserDefaults` flag set once the user
  completes the authorization sheet, plus `healthkitLastSyncedAt`. Show
  `Connected` after the user opts in; show `No workouts found yet` if the first
  sync returns zero samples (the honest signal that either there's no data or
  read was denied).

---

## 5. Detail screens

### IntervalsDetailView (move existing logic + add toggle)
Reuse the current `IntervalsSettingsView` body verbatim (OAuth button, API-key
form, athlete ID, disconnect, the "find your API key" footer). **Add** at the
bottom, only when connected:
- Toggle: `Show my activities in the group feed` — bound to the per-user
  group-feed opt-in (§7). intervals' terms permit cross-user display, so this
  may default **on** for intervals (unlike the others).

### AppleHealthDetailView (new)
- **Connect**: `Connect Apple Health` button → `HealthKitSync.requestAuthorization()`
  → on completion, kick a first sync, set the local connected flag.
- **Status**: `Connected` + `Last synced <relative>` (from `healthkitLastSyncedAt`),
  or `No workouts found yet` if zero.
- **Group-feed toggle**: `Show my activities in the group feed` — **default off**
  (App Store Guideline 5.1.3 wants explicit opt-in for sharing health data to
  other people). Writes the per-user opt-in (§7).
- **Disconnect**: `Stop syncing Apple Health` — clears the local flag, disables
  background delivery, stops future pushes. (Already-pushed rows remain unless
  you also call a purge — see §7 follow-ups.) Copy note: Health permissions
  themselves are revoked in iOS Settings → Privacy → Health, not in-app; show a
  one-liner saying so.
- **Footer copy:**
  > Très Fort reads completed workouts (type, duration, heart rate, distance) from Apple Health. It never writes to Health, and your health data is only shared with your group if you turn that on above.

### ComingSoonDetailView (generic)
Title = source name, body:
> Direct <Source> connection is coming soon. For now, connect <Source> to intervals.icu and connect intervals.icu above — your <Source> workouts will flow through with full detail.

---

## 6. Apple Health (HealthKit) integration

### Project config (`ios/project.yml` → regenerate with `xcodegen generate`)
- Add HealthKit entitlement: `com.apple.developer.healthkit` = true.
- Add background delivery entitlement: `com.apple.developer.healthkit.background-delivery` = true.
- **Do NOT** add `com.apple.developer.healthkit.access` (that's clinical health
  records — not needed; flagged in the feasibility verify).
- Info.plist: `NSHealthShareUsageDescription` =
  `Très Fort reads your completed workouts so your coach can balance your cardio against your lifting.`
  (No `NSHealthUpdateUsageDescription` — we never write to Health.)
- Build with the **TresFort** scheme; the `.xcodeproj` is generated, so edit
  `project.yml` only, then `cd ios && xcodegen generate`.

### Read types to request
- `HKObjectType.workoutType()`
- `HKQuantityType(.heartRate)`, `(.activeEnergyBurned)`,
  `(.distanceWalkingRunning)`, `(.distanceCycling)`, `(.distanceSwimming)`,
  and (iOS 17+) `(.cyclingPower)` for `average_watts`.

### Reading workouts
- **Anchored incremental sync:** `HKAnchoredObjectQuery` over `workoutType()`
  with a persisted `HKQueryAnchor` (store in `UserDefaults` as Data). First
  connect = full backfill (nil anchor); subsequent = delta. Run on launch and
  on `.foreground`.
- **Near-real-time (optional):** `HKObserverQuery` +
  `enableBackgroundDelivery(for: .workoutType(), frequency: .immediate)`.
  Treat anchored foreground sync as the source of truth; background delivery is
  opportunistic (it doesn't fire when the app is force-quit).
- **Per-workout enrichment** (the totals are NOT on `HKWorkout` directly; the
  old `totalEnergyBurned`/`totalDistance` are **deprecated since iOS 18**):
  - energy/distance → `workout.statistics(for:)` with the right quantity type.
  - avg/max HR → a separate `HKStatisticsQuery`/sample query on `heartRate`
    predicated to `[workout.startDate, workout.endDate]`
    (`HKQuery.predicateForSamples`).
  - elevation → `workout.metadata[HKMetadataKeyElevationAscended]` if present.
- **Deletions:** `HKAnchoredObjectQuery` also returns deleted objects. v1 may
  ignore these; a future `DELETE`/soft-delete push closes the loop (see §7).

### `HKWorkoutActivityType` → `kind` (must mirror the backend kinds)
Backend kinds (PR #79 / glyph maps): `ride run swim walk hike row ski yoga
elliptical strength other`. Map:
- `.running` → `run` · `.cycling` → `ride` · `.swimming` → `swim`
- `.walking` → `walk` · `.hiking` → `hike` · `.rowing` → `row`
- `.downhillSkiing`, `.crossCountrySkiing`, `.snowboarding` → `ski`
- `.yoga` → `yoga` · `.elliptical` → `elliptical`
- `.traditionalStrengthTraining`, `.functionalStrengthTraining` → `strength`
- everything else → `other`

### Push payload → `POST /api/activities/healthkit` (endpoint shipped in PR #80)
One POST per workout. Idempotent on `id`; safe to re-push (outbox retry / a
re-anchored sync re-seeing a workout updates in place, never duplicates).

```json
{
  "id": "<HKWorkout.uuid, lowercased>",          // = idempotency key (UUID)
  "date": "2026-06-18",                           // device-local YYYY-MM-DD of start, verbatim
  "start_date_local_ms": 1750243200000,           // start epoch ms (ordering)
  "kind": "run",                                  // lowercase, mapped above
  "name": "Outdoor Run",                          // workout display name or null
  "moving_time_sec": 1800,
  "elapsed_time_sec": 1850,
  "distance_m": 5000,
  "average_watts": null,                          // cycling power only (iOS 17+)
  "average_hr": 145,
  "max_hr": 168,
  "calories": 320,
  "elevation_gain_m": 60,
  "raw": null                                     // optional source JSON
}
```
- `id` must satisfy the server's UUID regex — `HKWorkout.uuid.uuidString`
  is uppercase; lowercasing is cleanest (the regex is case-insensitive, so
  either works).
- `training_load` is intentionally **not** sent and stays null server-side
  (no per-user HR anchor to derive hrTSS — see §7).
- Route the POST through the existing iOS API client + auth (app JWT). Reuse
  the outbox/retry pattern used for `POST /api/activities` so a failed push
  retries safely.

### Sync surface (no work needed)
Pushed rows land in `external_activities` and flow to the app through the
existing `GET /api/state?activities_since=` watermark and the
`ExternalActivity` decode (`Models.swift`) — the app already renders them in the
calendar/feed. No new sync plumbing.

---

## 7. Backend dependencies (what iOS needs that may not exist yet)

| Need | Status | Notes |
|---|---|---|
| `POST /api/activities/healthkit` | **Shipped (PR #80)** | iOS codes against this |
| intervals connect/status | **Shipped** | `GET /api/me`, `/auth/intervals`, `PATCH /api/me/integrations/intervals` |
| Sync surface for pushed rows | **Shipped** | `/api/state` + `ExternalActivity` |
| **Group-feed opt-in flag + gating** | **TODO** | New per-user (per-source) flag + `PATCH /api/me` field + feed query gating. Both detail toggles (§5) write this. The merge/feed copy depends on it. |
| **Per-source status in `GET /api/me`** | **Partial** | Today exposes intervals only. Apple Health "connected/last-synced" is a *local* fact (track client-side); a server mirror is optional, not required for v1. |
| **Cross-source dedup** | **TODO** | Columns exist (`canonical`/`duplicate_of`, migration 0027); logic deferred. Gates the merge callout copy. |
| **HealthKit deletion push** | **TODO (later)** | A `DELETE`/soft-delete endpoint so removing a workout in Health removes it here. v1 can skip. |
| **Per-user HR anchor → hrTSS** | **TODO (later)** | A max-HR/LTHR setting unlocks computed `training_load` for HealthKit rows; until then coach reads avg HR + duration. |

---

## 8. Copy reference (all user-facing strings, in one place)

- Nav title: `Connections`
- Header: `Connect where your workouts are recorded, so your coach can see your cardio and balance it against your lifting.`
- Recommended section header: `Recommended`
- intervals card subtitle: `One hub for Garmin, Zwift, Polar & Wahoo — with the richest training data`
- intervals connect button: `Connect intervals.icu`
- intervals helper link: `New to intervals.icu? Set up your device`
- Direct section header: `Or connect directly — no extra account`
- Apple Health subtitle: `Simplest — your iPhone & Apple Watch, no new account`
- Garmin subtitle: `If you record on a Garmin watch or bike computer`
- Polar subtitle: `If you train with a Polar watch`
- Wahoo subtitle: `If you use a Wahoo bike computer`
- Coming-soon trailing label: `Coming soon`
- Merge callout: `Connect more than one? We automatically merge duplicate workouts — you won't see the same ride twice.`
- Strava callout: `Using Strava? Strava-synced activities arrive without details. Connect intervals.icu or your device directly instead.`
- Group-feed toggle: `Show my activities in the group feed`
- Apple Health connect button: `Connect Apple Health`
- Apple Health footer: `Très Fort reads completed workouts (type, duration, heart rate, distance) from Apple Health. It never writes to Health, and your health data is only shared with your group if you turn that on above.`
- Apple Health "no data": `No workouts found yet`
- Apple Health disconnect: `Stop syncing Apple Health`
- Coming-soon body: `Direct <Source> connection is coming soon. For now, connect <Source> to intervals.icu and connect intervals.icu above — your <Source> workouts will flow through with full detail.`

---

## 9. Build order (iOS)
1. `ConnectionsView` list + move `IntervalsSettingsView` → `IntervalsDetailView`
   (intervals stays fully working; pure restructure). Verify on sim.
2. `project.yml` HealthKit capabilities + `xcodegen generate`; usage string.
3. `HealthKitSync` (auth + anchored read + enrich + push). **Verify on device.**
4. `AppleHealthDetailView` wiring + local connected/last-synced state.
5. Group-feed opt-in toggles — land with the backend flag + gating (§7).
6. Coming-soon rows behind a constant; flip per phase as Polar/Wahoo ship.
