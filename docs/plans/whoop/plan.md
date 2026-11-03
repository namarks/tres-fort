# WHOOP data in Tres Fort

Slug: whoop · Status: planned · Updated: 2026-11-03 · Theme: connected-training

## Goal

A member who wears a WHOOP sees their WHOOP-tracked workouts in Tres Fort
as the sport they were, once, with a load, and (if the owner chooses) their
daily recovery, heart-rate variability, resting heart rate and sleep beside
the plan, all in the app without an AI coach. Done means:

- a workout WHOOP tracked lands in Tres Fort once, even when a watch or the
  run recorder also recorded it, and gets a heart-rate load from the
  member's thresholds;
- WHOOP's own Strain is shown as WHOOP's figure, never treated as a Tres
  Fort load (it is a 0 to 21 scale, not one hour at threshold = 100); and
- recovery and sleep, if built, are private to the member, never in a group
  view, and missing days stay unknown.

## Evidence (2026-11-03)

Research only; WHOOP's developer site could not be read directly from the
cloud, so the facts below come from search summaries of WHOOP's own pages
and community reports, to be confirmed in the first phase that relies on
them.

**WHOOP's developer API (v2).**

- OAuth 2.0 authorization code with a client secret. Read scopes:
  `read:workout`, `read:recovery`, `read:sleep`, `read:cycles`,
  `read:profile`, `read:body_measurement`, plus `offline` to get a refresh
  token. Access tokens last an hour. Each refresh returns a new refresh
  token and invalidates the old one, so refreshes for one member must be
  serialized (two Worker requests refreshing at once lose the connection).
- Workout: id, start, end, timezone offset, `sport_name` (`sport_id` was
  retired 2025-09-01), score state, and a score with `strain`, average and
  max heart rate, kilojoules, percent recorded, distance and altitude when
  measured, and time in six heart-rate zones. No heart-rate stream and no
  GPS route.
- Recovery: recovery score, resting heart rate, HRV (rMSSD), SpO2 and skin
  temperature. Sleep: stage totals, performance, efficiency, respiratory
  rate (no per-minute stages). Cycle: the day's strain. Body measurement:
  height, weight, max heart rate.
- Webhooks for workout, sleep and recovery updates and deletions (not
  cycles or body measurements) carry only ids, so the Worker fetches the
  record after each one. They are signed: HMAC-SHA256 of the timestamp
  header plus the raw body with the app secret, base64. Delivery is retried
  about five times over an hour and is not guaranteed, so a periodic pull is
  still needed.
- Reported rate limits: 100 requests a minute and 10,000 a day per app.
- Access: building an app needs a WHOOP membership (the developer login is
  the WHOOP account). A new app works at once for up to 10 WHOOP members;
  more needs WHOOP's approval (app details, privacy policy, design
  guidelines, tested with at least one member). Many developers on WHOOP's
  community forum report approval requests unanswered for months in 2026.
- Terms: WHOOP's API terms forbid using WHOOP data to create, train,
  fine-tune or improve any AI or machine-learning model, forbid sublicensing
  and competing with WHOOP, and reportedly limit caching and selling data.
  They do not obviously cover a member's own AI app reading the member's
  data at their request through Tres Fort's coach tools; that needs WHOOP's
  answer before WHOOP data reaches the coach.

**Indirect routes.**

- Apple Health: WHOOP writes workouts, sleep (asleep and awake only), one
  resting heart rate a day and workout energy. It does not write HRV or its
  recovery score. Reports disagree on whether WHOOP's workouts carry heart
  rate. Tres Fort's Apple Health import already takes every workout from
  every app, so WHOOP workouts written there probably reach Tres Fort today
  as a coarse kind (often `other`) with no stream-based load; this needs a
  check with a real WHOOP wearer.
- intervals.icu: now has a built-in WHOOP connection for wellness (sleep,
  resting heart rate, HRV, recovery, respiration, SpO2), not workouts.
  Tres Fort's intervals.icu connection asks only for `ACTIVITY:WRITE,
  CALENDAR:WRITE` and reads no wellness, so this route would need a new
  scope, every member reconnecting, and an intervals.icu account.

**Tres Fort today.** No WHOOP code. External workouts land in
`external_activities` (Apple Health, intervals.icu, `.fit`, the recorder)
with one load engine (`src/trainingLoad.ts`), whose average-heart-rate
fallback can score a WHOOP workout from its average heart rate and the
member's threshold heart rate. There is no wellness, sleep or recovery
model anywhere in the schema. The only outbound OAuth connector is
intervals.icu (`src/routes/intervalsAuth.ts`), with credentials on the
`users` row.

## Phases

- [ ] **P0 — Check what a WHOOP wearer's data looks like**
  - With a member who wears a WHOOP (and has allowed it to write to Apple
    Health), look at their Apple Health export and at the Tres Fort rows it
    produced: which WHOOP workouts arrive, with what activity type, heart
    rate and energy, and how they line up with a watch or recorder copy of
    the same session (WHOOP's auto-detected start and end usually differ by
    minutes).
  - Record the findings here and decide whether P1 is enough or P2 is
    needed. No code.
- [ ] **P1 — WHOOP workouts through Apple Health**
  - Name WHOOP as the source of these rows, name the sport (with
    sport-activities P0 if that plan has merged), and read heart-rate
    samples for WHOOP workouts so they get a load.
  - Dedup a WHOOP workout against a watch, recorder, `.fit` or
    intervals.icu copy of the same session by overlapping time, not only
    the two-minute start match, keeping the richer copy.
  - Tests cover the overlap rule and the source naming.
- [ ] **P2 — Direct WHOOP connection for workouts**
  - Profile → Connections → WHOOP connects and disconnects in the app.
    Credentials live in their own table (not more `users` columns), the
    rotating refresh token is claimed with a compare-and-swap so concurrent
    refreshes cannot drop the connection, and disconnecting removes the
    stored WHOOP rows.
  - A signed webhook route (verify signature and timestamp, then fetch the
    record) plus the existing hourly cron as a backstop write workouts to
    `external_activities` with `source='whoop'`: sport, times, average and
    max heart rate, energy, distance when measured, heart-rate zone times
    and WHOOP's Strain kept as WHOOP's figure. Load comes from the engine's
    average-heart-rate method; nothing is invented when heart rate is
    missing.
  - Dedup ranks a WHOOP workout below intervals.icu, `.fit` and the
    recorder, and above or level with Apple Health, using P1's overlap rule.
  - Up to 10 members can connect before WHOOP approves the app.
- [ ] **P3 — Recovery and sleep (owner decision first)**
  - A new private daily record per member (migration): recovery score, HRV
    (rMSSD), resting heart rate, sleep duration and performance, from the
    WHOOP connection (and Apple Health sleep and resting heart rate for
    members without one, if the owner wants that floor).
  - Today shows the morning's recovery; Activity → Progress shows the
    trends. Never shown to the group; unknown days stay blank.
  - Reaches the coach brief only after WHOOP confirms the AI question in
    the notes.
- [ ] **P4 — WHOOP app approval past 10 members**
  - The owner submits the app for approval in WHOOP's developer dashboard
    with the privacy policy updated for WHOOP data.

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P0 | gated_by | external:owner-whoop-wearer | Needs a member who wears a WHOOP to share an export or try the import. |
| P1 | coordinates_with | plan:activity-integration-integrity | Changes cross-source dedup, which that plan owns. |
| P2 | gated_by | external:owner-whoop-developer-app | The app is registered under a WHOOP membership in WHOOP's developer dashboard, with its secret set by `wrangler secret put`. |
| P2 | coordinates_with | plan:endurance-training-load | WHOOP workouts are scored by the same load engine. |
| P3 | gated_by | external:owner-whoop-recovery-decision | Daily recovery and sleep is a new product area, not just an import. |
| P4 | gated_by | external:owner-whoop-developer-app | Approval is requested from the same developer app. |

## Next step

**Parked (owner, 2026-11-03):** the owner chose to keep this plan planned
and build nothing until someone using Tres Fort wears a WHOOP. When one
does, start at P0. The recommended route then is P0 and P1 (Apple Health,
no WHOOP approval needed), with P2 and P3 only if a member wants recovery
and HRV, which Apple Health does not carry.

## Notes / open questions

- AI use: WHOOP's terms forbid training models on WHOOP data. Tres Fort
  trains nothing, but its coach tools pass a member's data to the member's
  own AI app. Until WHOOP says that is allowed, WHOOP-sourced fields stay out
  of MCP tools and the coach brief, the same stance as the Garmin request.
  Every WHOOP feature works in the app without AI, so this costs no member
  feature.
- Group feed: WHOOP-sourced workouts follow the member's existing activity
  sharing choice only after the terms are checked for showing one member's
  data to others; until then they are private.
- WHOOP's heart-rate zones are its own (percent of max heart rate), not the
  member's threshold zones, so they are shown as WHOOP's zones and not used
  for load.
- Related plans: the sport-activities plan (PR #331, not yet merged) names
  sports and scores heart rate for every sport, which P1 reuses; Garmin's
  Starter request (endurance-training-load P5) would be a second direct
  connector, so P2's credentials table should not be WHOOP-specific.
- Production migration, Worker deployment, new secrets, new Apple Health
  permissions and client distribution each need the owner's separate
  go-ahead; a new data source changes the App Store privacy answers.
