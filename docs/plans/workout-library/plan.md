# Workout Library

Slug: workout-library · Status: gated · Updated: 2026-09-19 · Theme: gym-floor

## Goal

Let a member keep a library of reusable workouts that exist independently of
any weekly routine, drop one onto any date (today or future) in one gesture,
and run a genuinely unplanned session when life or travel breaks the pattern.
The recurring weekly schedule becomes one optional way to use the library, not
the frame every workout must fit into. Exercise guidance, history and replacement
discovery should remain close to the workout without interrupting set entry.

## Library model

The shared versioned plan tree supplies the library. The coordinated rename
changes its vocabulary without creating a second workout store:

- `workouts` are reusable workouts. Nothing about a row ties it to a
  weekday; `plans.meta.schedule` is a separate weekday → `workout_id`
  map, and a day with no schedule entry is already valid and runnable
  (manual-workout-authoring P0 verified "an unscheduled day remains available
  in the routine but does not appear in Today by itself").
- One-date assignment already exists: `PUT /api/calendar/{date}` /
  `set_planned_session` binds any day template to a concrete date without
  touching the schedule or the plan version. Today's rest-day "Start a
  workout" CTA and the "train a different day" override reuse the same path.
- `projectCalendar` already prefers a real session over the schedule, so a
  library workout dropped on a scheduled day simply wins for that date.

The original gaps were product framing and three capabilities it exposes:

1. **The UI named everything "Routine."** The prior `RoutineView` add flow says
   "adds a reusable workout to your routine", deletion says "recurring
   weekdays using this workout become rest days", and a workout with no
   weekday has no visible identity of its own. A member reads this as "every
   workout must be a routine day."
2. **No library metadata.** A member with a hotel workout, a 20-minute
   bodyweight session, and three gym days has no way to tag, group, or retire
   workouts. The only exit is delete, which is framed around the schedule.
3. **No true one-off session.** A session with `workout_id = NULL` today
   is not "freestyle": `deleteWorkout`'s scope predicate and the runner
   both resolve a null-template session through the weekly schedule. There is
   no way to walk into a gym, log whatever the equipment allows, and
   optionally save what you did as a new library workout.

The design stays on the versioned plan tree and the append-only session log.
No second editor, no per-session template copies, no weeks table.

## Phases

- [x] **P0 — Present the library as the primary object**
  - Rename the routine surface to **Workouts**. Each workout card shows its
    own identity plus a schedule badge ("Mon · Thu" or "On demand"). The
    schedule becomes a section of that screen, not its frame.
  - Split the destructive action: **Unschedule** clears weekday entries only
    (existing `PUT /api/plan/schedule`); **Delete workout** keeps the current
    `DELETE /api/workouts/{id}` semantics and copy. The add flow stops implying
    that a new workout must be scheduled.
  - Make "put this workout on a date" a first-class calendar gesture for any
    today-or-future date that is not inside a `can_train_light=false` trip,
    reusing the existing `PUT /api/calendar/{date}` attempt-CAS path and the
    agenda picker. Hard-blackout dates keep their current behavior: the iOS
    guard rejects the assignment and the projection suppresses a planned
    session there. Lifting that is a projection-parity change and is out of
    P0. Verify a library workout dropped on a scheduled weekday shows as that
    date's workout in Today, the calendar, and `get_today_workout`, and that
    the recurring schedule is unchanged.
  - No schema or Worker change. Update `docs/DESIGN.md` §4 and §9 wording so
    "day template" is described as a library workout that the schedule may
    reference.
- [x] **P0.1 — Today and Calendar navigation**
  - Owner-approved design: Today has a compact scheduled/completed workout
    card, explicit View workout, Start/Continue workout, Choose a workout,
    Create a workout, and Log an activity actions. Remove the duplicate
    top-right Workouts entry and the idle plus/overflow menus.
  - The library opens a named workout before starting or editing it. Editors
    name their exact saved workout and distinguish saved prescriptions from
    completed records. Plan changes lives in the library; Training overview
    lives in Profile's Coach section. Keep runner recovery, feedback, timers,
    terminal actions, and the full completed record reachable.
  - Rename History to Calendar, retain exercise progress, and make date
    assignment/replacement/removal explicit. Keep weekly scheduling separate;
    moving a workout must preserve both dates under concurrent writes.
  - Create-from-Today opens a named saved-workout creator and editor, explicitly
    described as a library write. The preview's one-off creation and optional
    saving require a separate product decision and P2 compatibility work; the
    implementation question remains open in the design task.
  - Verify synthetic iOS journeys for every new route, ambiguous/null workout
    identity, compact completion, date scope, and preservation of recorded sets.
  - Delivered a receipt-backed atomic move endpoint without a migration. Both
    date attempts advance together; concurrent changes reject the whole move.
    Date notes/fatigue, weekly scheduling, and completed records are preserved.
    Acknowledged writes retain success when refresh fails; creation recovers
    through a read-only refresh and failed finishes retain the discard path.
  - Local evidence: the iOS smoke suite completed 499 unit tests (one skipped)
    and 28 UI journeys without failures. Focused navigation journeys additionally
    cover removal without a saved-workout identity, unresolved real-session
    records, first-workout creation recovery, and both terminal recovery paths.
    All 70 backend test files passed; the final calendar/dual-schema subset
    passed 112 tests. Typecheck, plan graph and verification-script checks passed.
    Final independent local review found no actionable regressions.
  - Follow-up browsing repair (2026-09-10): the workout label, blank space,
    padding and disclosure chevron open named details; secondary actions have
    a 44-point target. Swipe left reveals Delete with full-swipe execution
    disabled, then a named Delete/Cancel alert confirms removal. The shared
    mutation and active-workout guards remain in place. Library UI journeys
    originally ran in PR smoke coverage; detailed row/cancellation variants now
    run in the periodic full suite under the [verification policy](../../IOS-VERIFICATION.md). This
    follow-up shipped in the owner-authorized TestFlight 1.0 (38) distribution.
  - Owner-approved action cleanup (2026-09-11): Profile keeps name editing and
    one Account route; export, sign-out and account deletion live inside Account.
    The runner keeps the current set action and values above the tab bar while
    inputs scroll. Workout editing separates normal rows from explicit reorder
    and grouping modes. Exercise removal and set deletion require named alerts
    with Cancel. Early finish distinguishes Keep working, Save feedback & finish,
    and finishing without new feedback. Removing a required set replaces the
    unavailable final Finish action with Review exercises; returning selects
    unresolved work and checkpoints the runner. Completed slots show their
    completion state instead of an extra Log action. Regression journeys exercise
    actual taps through rest, reordering, deletion, and both finish choices.
    These client changes shipped in [TestFlight 1.0 (38)](../app-store-submission/release-38.md),
    verified VALID and available to internal Testers. Physical-device follow-up
    remains unverified.
- [ ] **P0.2 — Substitute unavailable equipment during a workout**
  - [x] **(a) Session-scoped swap implementation**
    - Add an in-runner, searchable Swap exercise picker for the current workout.
      Retain completed-set identities, set progress and superset membership;
      show replacement-specific load and demo information. An active timed set
      must finish or stop first. Keep the reusable workout unchanged.
    - Store original/replacement slot snapshots and a swap revision on the
      existing session, scoped to its attempt. Use plan-version and session CAS,
      protected atomic audit, ordinary session deltas and account persistence.
      Reopening before the first set must preserve the choice; stale pickers and
      later attempts cannot inherit an old change. Same rep/timed measure only.
    - Verified real-D1 writes, restart/isolation/conflicts, iOS recovery,
      replacement logging, and the visible picker journey. Local verification:
      1,020 backend tests; 520 iOS unit tests (one existing skip, no failures);
      swap, timer-navigation and superset UI journeys. The owner authorized
      publication, independent review and merge after passing CI on 2026-09-12.
      The pull request from `feat/in-workout-exercise-swap` carries exact-head
      review and CI evidence. Production migration, deployment and app release
      remain outside this repository delivery.
  - [ ] **(b) Authorized Worker release and verification**
    - Migration 0050 was applied once with explicit owner approval on 2026-09-12;
      ledger and nullable `sessions.exercise_swaps` TEXT-column readback passed.
      The separately approved pinned Worker was deployed on 2026-09-12 Pacific
      time; provider source attribution and public checks passed. Authenticated
      session-swap and workout-name compatibility checks remain unperformed;
      neither public health nor Apple processing proves those behaviors.
  - [x] **(c) Authorized client distribution**
    - The owner separately approved signing, validation and upload of build 40.
      Xcode uploaded the pinned archive; Apple verified VALID processing and
      internal Testers availability. The existing App Manager credential now
      permits selecting build 40 for App Review. P0.2(b) live verification remains
      open. Follow the coordinated App Store release record for submission;
      public release remains manual.

- [x] **P0.3(a) — Exercise-first creation and lookup (repository)**
  - Owner priority on 2026-09-13: improve creation and exercise discovery before
    library tags/archive. Today, Calendar, onboarding, and Add workout open exercise
    selection immediately. Keep selection local until Save; naming is optional
    on the following review screen with an unused `Workout N` default.
  - Reuse one picker for creation, Add exercise, and Add warm-up. Keep search
    visible, match names, catalog aliases, muscle and equipment, and compose it
    with All / Upper body / Lower body / Core filters derived from the catalog's
    primary muscle. These are exercise filters, separate from P1 workout tags.
  - Preserve selection order across queries and filters. Preview initial targets;
    continue into the existing prescription editor after creation. Rep exercises
    start at 3 × 8, holds at 3 × 45 seconds, cardio at five minutes, with zero
    load pending member selection and manual progression.
  - Extend `POST /api/workouts` and its released `/api/days` alias with optional
    `exercise_ids` (1–50 unique catalog IDs). Require observed plan ID/version
    for this path. Validate the complete list before one atomic workout/slot/
    version/audit/snapshot write; an uncertain retry keeps its captured request.
    Existing name-only clients remain compatible. No schema migration.
  - Verify search/filter composition, cancellation without writes, unnamed
    creation, slot order, rejected/concurrent requests, lost responses and
    acknowledged-save/failed-refresh recovery on the real model and D1.
- [x] **P0.3(b) — Release exercise-first creation**
  - After repository review and CI pass, obtain owner release authority for the
    compatible Worker, then an iOS build containing P0.3(a). No migration is
    introduced here. The server must accept `exercise_ids` before distributing
    this client; do not fall back to sequential or empty-workout writes.
  - Retain exact deployed source and client distribution evidence separately.
    The later owner-authorized [build 42 release](../app-store-submission/release-42.md)
    includes PR #198 in both Worker and client source `5df9208`. The September 18
    readback confirms that same Worker at 100% traffic and build 42 VALID in
    internal Testers. This reconciles the stale release checkbox; it does not
    establish physical-device acceptance or new App Review authority.
- [x] **P0.4 — Streamline observed iOS workflows**
  - [x] **(a) Implement and verify the observed usability fixes**
    - Owner-approved after a hands-on simulator audit of `12dd49c`: put load
      and reps ahead of secondary controls, retain visible circuit membership,
      remember compact rest, and correct the exact last logged set from rest.
    - Use one Workouts entry for browsing and creation on scheduled/completed
      Today; retain direct creation for an empty library. Keep date-specific
      selection explicit and Start/Schedule pinned in workout details. Place
      date actions beside the date heading with a verified 44-point touch target.
    - Weekly scheduling uses explicit Cancel/Save, protects dirty drafts,
      submits the loaded plan identity/version, and retains failed/conflicted
      drafts for member-reviewed retry. Early finish starts with a summary;
      voice, notes and fatigue appear on request. Existing saved feedback and
      recorded sets keep their existing write and recovery paths.
    - Connections lists available sources, moves device-routing help into a
      disclosure, and distinguishes Apple Health opt-in from Intervals status.
      RPE semantics, new onboarding behavior and additional providers remain
      outside this observed-fix slice.
    - Local verification: 610 iOS unit tests completed with one existing skip
      and no failures. All 43 distinct targeted UI journeys passed after fixes,
      covering timer/navigation, circuit/load and kg entry, exact last-set
      correction, accessibility-size rest/logging, schedule conflicts/retry,
      calendar moves/removal and the 44-point menu edge, finish feedback and
      Intervals connections. Runner, pinned workout actions, early finish and
      calendar screenshots were inspected. Independent local review found no
      remaining blocking issue. [PR #209](https://github.com/namarks/tres-fort/pull/209)
      merged on 2026-09-17 after current-head hosted review and required CI.
      [PR #210](https://github.com/namarks/tres-fort/pull/210) followed with
      stacked Today actions, full-width exercise names and a compact rest that
      keeps next-set values and exact last-set correction at accessibility text
      sizes. Manual physical-device and VoiceOver behavior remain unverified.
  - [x] **(b) Distribute the verified client changes**
    - The September 18 follow-up authorizes internal TestFlight distribution
      after P0.5(b) merges, including the recent UI fixes and P0.5(a) sheet.
      Carry the exact reviewed source and Apple processing/beta evidence into
      the App Store release record. Worker deployment and App Review/public
      release remain separately authorized.
    - Distribution: [TestFlight 1.0 (43)](../app-store-submission/release-43.md) shipped from
      reviewed merged source `28dd647`, containing PRs #209, #210, #213 and #214.
      Apple confirmed VALID, IN_BETA_TESTING and internal Testers assignment on
      September 18 Pacific. No backend deployment was needed; App Review still
      selects build 40. Physical-device and VoiceOver acceptance remain open.

- [ ] **P0.5 — Connect exercise guidance and discovery**
  - Planning approved after the [September 18 SensAI inspection](../../reviews/2026-09-sensai/report.md).
    The owner activated (a) on 2026-09-18, ahead of P1 tags/archive.
    P0.5(a) merged in [PR #213](https://github.com/namarks/tres-fort/pull/213).
    The owner activated (b) on 2026-09-18, then authorized a combined internal
    TestFlight build with (a) and the recent UI fixes after review and merge.
    Slice (c) remains planned and requires activation; App Review and public
    release remain outside this approval.
  - [x] **(a) One exercise sheet for technique and history**
    - Reuse the existing demo and exercise-history data in a shared Technique /
      History sheet opened from workout preview, runner and catalog pickers.
      History starts with the last comparable performance and offers the full
      history; empty, unavailable and loading states stay distinct.
    - Preserve per-hand/per-side explanations, signed assistance and rep/timed
      semantics. Opening/dismissing the sheet must retain the current exercise,
      set, unsaved input, rest deadline and active timed-set state. Picker info
      must not accidentally select or swap an exercise.
    - Verify unfamiliar and familiar exercises from all entry points, a swapped
      exercise's own history, normal/large text and return during rest or a timed
      set. Reuse existing data paths; no new analytics store or mandatory runner
      animation is needed.
    - Repository implementation reuses the demo, cached history cohorts and full
      exercise-history view. Comparable summaries use completed sessions with
      the same rep/hold mode and prescribed load; current, discarded, deleted
      and warm-up records cannot become a prior comparable performance.
    - Local verification passed six focused unit tests and ten UI journeys,
      covering preview, runner, create, add, warm-up and swap entry points,
      preserved selection/query/filter state, draft values, rest and active
      timers. Existing creation and swap smoke journeys also passed. Largest
      system-text journeys cover the sheet and return to selection; search
      submission dismisses the keyboard so information remains reachable. The
      pull request from `codex/exercise-guidance-history` carries the independent
      current-head review and required CI evidence. Client distribution remains
      separate from this repository slice.
  - [x] **(b) Consistent search and filters for creation, addition and swaps**
    - Share alias-aware search and All / Upper body / Lower body / Core filters
      across create, add, warm-up and session-swap pickers. Retain search/filter
      state when opening details or returning from a selection review.
    - Keep matching-muscle ordering and the swap path's rep/timed compatibility
      restriction. Offer equipment filtering only after checking catalog
      coverage and defining unknown/mixed-equipment behavior; never silently
      hide unknown entries. Force/difficulty filters require a separate trusted
      metadata contract and are outside this slice.
    - Verify finding an unavailable-machine replacement without its exact name,
      composing alias search with filters, clearing an empty result and canceling
      without writes. Confirmation names the affected exercise and says this
      session only; the library editor separately names its reusable-workout scope.
      Completed sets, group membership, replacement load, attempt/version checks
      and swap recovery retain the delivered P0.2(a) contract.
    - The session picker now uses the same search/filter component as create,
      add and warm-up. Selected replacement and information-sheet state survive
      filtering; confirmation names both exercises and states the session scope.
      Add/warm-up configuration names the saved workout. The catalog has names,
      aliases, muscle and modality but no separate equipment taxonomy; equipment
      remains searchable through those fields without an inferred exclusion filter.
    - Seven search-policy tests and nine targeted UI journeys passed, including
      alias/filter composition, empty-result reset, info and review returns,
      cancellation without writes, and logging after a swap with prior sets and
      plan version preserved. The four new journeys passed a repeat at normal
      text size. Largest-system-text creation/review and complete swap journeys
      also passed; normal and largest-text swap screenshots were inspected.
      Local independent review found no actionable issue.
      [PR #214](https://github.com/namarks/tres-fort/pull/214) merged after
      current-head review and all eight CI checks passed, including 625 iOS unit
      tests (one existing skip) and all 12 smoke journeys. P0.4(b) records its
      completed internal TestFlight distribution.
  - [ ] **(c) Small exercise visuals in workout previews**
    - Reuse Très Fort's own demonstration assets as lightweight thumbnails in
      the shared workout preview. Keep exercise names, targets and circuit or
      superset membership readable; missing art gets a stable fallback.
    - Verify recognition and equipment discovery with unfamiliar movements,
      long names, large text, Reduce Motion and a long grouped workout. Keep
      scrolling responsive and preserve text accessibility; visuals must not
      push the prescription or primary workout action out of reach.

- [x] **P1 — Library metadata: tags and archive**
  - Reuse prescription-integrity's validated atomic writer contract for every
    new metadata mutation, including conflicts and audit. P0 presentation work
    remains independent of this backend prerequisite.
  - Add `workouts.tags` (JSON array of short strings such as `travel`,
    `quick`, `bodyweight`, `hotel`) and `workouts.archived_at`
    (nullable epoch-ms) in one migration. Both are plan-tree fields: every
    write goes through the existing atomic plan-version writer, bumps
    `plans.version`, and audits as the calling actor.
  - Archiving hides a workout from pickers and Today while preserving every
    completed or in-progress `sessions.workout_id` and
    `set_logs.template_exercise_id` reference. In the same write it clears
    the workout's weekday entries and resolves its future dated assignments
    the way `deleteWorkout` already does: a `planned` session pointing
    at the workout becomes explicit rest with its attempt advanced, because
    `projectCalendar` gives a real session precedence over the schedule and
    would otherwise keep showing the archived workout. Archiving is rejected
    while the workout has an in-progress session, matching delete.
  - Every assignment resolver rejects an archived workout, not only the
    updated pickers: `setPlanSchedule`, `setPlannedSession`,
    `getWorkoutInPlan` as used by `POST /api/sessions` and
    `PUT /api/calendar/{date}`, and the MCP day-ref lookup all treat
    `archived_at IS NOT NULL` as unknown. Otherwise an older iOS build that
    ignores the field, or any caller still holding the id, can reassign it
    and the resulting real session wins projection and restores it in
    Today. Add a test that each path returns the same not-found result for
    an archived id.
    `update_plan`'s rebuild must carry both fields through the day remap.
  - Expose both fields through `get_current_plan`, `add_day`, `update_day`,
    and `PATCH /api/workouts/{id}`; `/api/state` carries them in the plan tree.
  - When a date falls inside a `plans.meta.trips` range, the calendar and
    Today pickers surface `travel`-tagged workouts first. This is ordering,
    not a rule engine.
  - Released-client compatibility (shared rule in
    `workouts-and-multi-session`): archived workouts stay in the plan tree
    for every client so completed history still renders its workout name;
    a client without the `archive` capability simply sees them in its
    pickers, and the resolver rule above turns any attempt to assign one
    into `unknown_day`, which the released app already handles as a
    permanent client error.
  - Extend `test/calendar.test.ts` so an archived workout referenced by the
    schedule projects as rest on both backend and iOS
    (`CalendarProjection.swift` already treats a dangling id as rest; make
    the archived case explicit and keep the two in parity).
- [ ] **P2 — Freestyle session and "save as workout"**
  - [x] **(a) Implement and verify repository delivery**
    - Migration 0054, durable freestyle starts, slotless set logging, account-
      scoped runner recovery and reviewed atomic save are implemented. The
      save receipt, plan/source CAS and attempt advance make retries safe;
      new workouts remain unscheduled. REST compatibility preserves old-client
      deletion invalidations and completed history; MCP unscheduled logging
      creates freestyle sessions.
    - Verification: 1,179 backend tests across three shards, including 28
      freestyle cases; 636 iOS unit tests with one existing skip; rep and timed
      start/add/finish/save UI journeys, including largest system text. Query
      plans, TypeScript, plan graph and same-Worker rename/rollback rehearsal
      pass. PR review and CI retain exact-head delivery evidence.
  - [ ] **(b) Release migration, Worker and matching client**
    - Follow [freestyle release ordering](freestyle-release.md) after separate
      owner authorization. Include the pending P1 metadata migration/release;
      repository delivery does not establish production or TestFlight state.
  - Add an explicit `sessions.kind` (`'planned' | 'freestyle'`, default
    `'planned'`) so a freestyle session with `workout_id = NULL` never
    resolves through the weekly schedule. Update the scope predicate in
    `deleteWorkout`, the runner's template inference, and
    `projectCalendar` (a freestyle session is a real session and wins for its
    date; it renders with its logged exercises rather than a template name).
    Released-client compatibility: the current runner infers a template from
    the schedule for any null-template session, so a client without the
    `freestyle` capability receives freestyle sessions only once they are
    completed (as history with their sets) and never as Today's session;
    an in-progress freestyle session is represented only by a redacted discarded
    row plus prior-set tombstones to invalidate cached planned attempts. Per the shared
    rule, invisible means fenced: while a date holds a live (`planned` or
    `in_progress`) freestyle session, `POST /api/sessions`,
    `PUT /api/calendar/{date}`, `PATCH /api/sessions/{id}` status changes,
    and the MCP session-by-date resolvers return `session_kind_conflict`
    (409) to a non-`freestyle` client rather than reusing the null-template
    row and pinning it to a workout, which the current date-scoped
    `getOrCreateSession` would otherwise do.
  - The runner starts a freestyle session from the rest-day CTA and from the
    calendar for today. Exercises are added from the catalog as you go; the
    prescription shown is the member's last comparable actuals for that
    exercise (existing history query), not a stored target. Sets log through
    the same idempotent `POST /api/sessions/{id}/sets` with
    `template_exercise_id = NULL`.
  - **Save as workout** converts a completed freestyle session into a library
    workout: one atomic `POST /api/sessions/{id}/save-workout` call through
    the shared versioned plan writer, with member-reviewed slots derived from
    compatible exercise, execution-mode and external-load cohorts in
    first-logged order. `target_sets` is the cohort's working-set count.
    A timed cohort defaults duration to its median observed duration, rounded
    to a valid positive integer number of seconds and shown for review, with no
    rep target; a rep cohort defaults reps to its median observed reps, rounded
    to a valid integer and shown for review. Load comes from that same cohort,
    never the maximum from incompatible sets. Cardio follows the timed branch.
    Separate mixed cohorts into slots or require an explicit member target
    selection before saving; do not merge them by exercise identity alone.
    Warm-up sets are excluded from the derivation. The
    new workout is unscheduled and, on the same write, the session is
    re-pointed at it so history attaches to the library entry. The re-point
    is an assignment change, so the same write advances `sessions.attempt`
    under the existing rule that every changed workout choice advances the
    generation; a delayed set intent carrying the old attempt is rejected
    instead of landing on the saved workout's history. The client supplies
    the new workout's id, so a retry after a lost response returns the same
    workout and the already-advanced attempt instead of creating a second
    workout or bumping again. This is a plan-tree write and audits normally.
  - Before saving, show an editable derived prescription with its provenance.
    Do not silently combine median reps from one load/assistance condition with
    the highest weight from a different set and present that pair as performed
    or recommended. Mixed timed/rep, assistance/strict/added-load and variation
    cases must remain separate or require an explicit target selection. Pass
    the chosen prescription through the same runtime validator as other writes.
  - MCP: `log_set` on a date with no session creates a freestyle session
    when the date has no scheduled workout, instead of a null-template
    planned session, and the coach brief names it as such.

## Execution frontier

- P2(b)

## Dependencies

[Completed Gym Runner Depth](../completed/gym-runner-depth/plan.md) supplies
the shared prescription controls, durable corrections and runner presentation.
Reuse that delivered path when changing the runner.

P1 metadata and P2 save-as-workout reuse the completed [validated atomic writer](../completed/prescription-integrity/decisions.md), including prescription creation and session reassignment. P1 extended [canonical snapshots](../completed/reversible-plan-management/decisions.md) to retain `tags` and `archived_at`, including legacy snapshot reads and full-plan rebuilds.

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P0 | blocked_by | plan:workouts-and-multi-session#P0(a) | The selected goal establishes canonical workout terminology and compatible clients before the library UI. Production rollout and compatibility cleanup do not block this repository slice. |
| P0 | coordinates_with | plan:member-activation-and-adherence#P0 | Both edit the no-plan and Today entry surfaces; do not run concurrently on the same iOS files. |
| P0.3(a) | coordinates_with | plan:member-activation-and-adherence#P0 | Both use first-workout entry and the shared exercise catalog. |
| P0.5(c) | gated_by | external:owner-sensai-followup-implementation | Preview thumbnails remain planned pending activation. |
| P0.5 | coordinates_with | plan:member-activation-and-adherence#P3 | Preview and upcoming-session entry share Today and workout detail routes. |
| P2(b) | gated_by | external:owner-freestyle-production-release | Migration, Worker deployment and matching client distribution need owner release authority. |
| P1 | coordinates_with | plan:workouts-and-multi-session#P0 | Both touch `workouts` columns and serializers; whichever lands second rebases onto the other's migration. |


Freestyle sessions and save-as-workout will supply more logged evidence to the
[completed coaching context](../completed/coaching-feedback-loop/plan.md).

## Next step

**Now (@owner):** P2(a) repository implementation is complete. Authorize the
ordered P1/P2 migration, Worker and matching-client release in
[freestyle-release.md](freestyle-release.md) when ready. Verify the live migration
ledger and Worker identity before choosing the exact release bundle; repository
merge does not establish production or TestFlight delivery. Preview thumbnails
still require separate activation; wider onboarding and RPE semantics remain
separate.

**P1 repository evidence (September 19):** Migration 0053, atomic REST/MCP
metadata writes, snapshot/rebuild preservation and archive assignment fences
are implemented. The iOS library supports tag editing/filtering, Active and
Archived views, confirmed archive and explicit restore; trip choices prioritize
travel labels. Archived workouts remain available to history. Regression checks
cover version conflicts, transaction rollback, archive/start races, legacy
aliases, calendar parity, restoration after UUID rebuilds and saved runner
invalidation. All three backend test shards passed; the local same-Worker
rename/rollback compatibility rehearsal passed. The focused library UI journey
covers tag filtering, cancel, archive and restore.

**P1 release (@owner):** Follow the [metadata release order](metadata-release.md):
migration 0053 after 0045, then compatible Worker, then iOS distribution.
Repository completion does not establish production migration, deployment or
TestFlight availability. A pre-metadata Worker is unsafe to restore after
metadata writes because its rebuild/snapshots omit the fields.

**Client distribution:** [TestFlight 1.0 (43)](../app-store-submission/release-43.md)
contains the usability and accessibility fixes in PRs #209/#210 plus the shared
exercise information and discovery in PRs #213/#214. The exact reviewed merged
source is `28dd647`; Apple confirmed VALID processing and internal Testers
assignment on September 18 Pacific. App Review still selects build 40. Device
installation, physical acceptance and VoiceOver behavior are not established by
beta availability.

**Exercise-first release:** P0.3(b) shipped in the owner-authorized build 42
release. The September 18 production readback and source ancestry confirm its
compatible Worker and internal client distribution. No Worker, migration,
runtime configuration or backend dependency differs between that release and
that build-43 client slice, so that combined beta needed no production deployment.
App Review changes remain separate.

P0.3(a) implementation and local verification are complete. All 1,101 backend
tests passed across the repository's three CI shards (78 files); the focused
D1 creation suite covers nine cases. Four focused iOS unit tests and twelve
distinct UI journeys passed, including unnamed multi-selection and onboarding
through first-workout completion. Final picker/review screenshots were visually
checked on iPhone 17 / iOS 26.2. Local independent review found no remaining
actionable regressions. [PR #198](https://github.com/namarks/tres-fort/pull/198)
merged on 2026-09-13 after exact-head review and required CI.

The combined local backend process timed out in a multi-case validation test
and later in an unchanged swap test. The new independent validation cases were
split without changing timeouts. The unchanged swap suite passed in isolation,
and complete coverage passed using the existing CI shards with fresh runtimes;
no checks or assertions were removed.

**Release coordination:** P0.2(b)/(c) remains owned by the
[App Store release record](../app-store-submission/plan.md#next-step). Its live
Worker, Apple processing, signing and submission evidence must be reconciled
there rather than inferred from repository completion here. The release task's
build 40 handoff is separate from P0.3 and must not silently change source.
P1 metadata repository delivery and P2 freestyle remain separate from that release.

The navigation design was approved in task
`01a08dee-930f-7763-9202-29872c440f26`. [PR #178](https://github.com/namarks/tres-fort/pull/178)
passed final independent review and all required CI. The last documented internal
navigation release is [TestFlight 1.0 (38)](../app-store-submission/release-38.md), released from
`0ac5d46b5a245c674fbc10727117b264a38db580` after the browsing and action fixes in
PRs #182 and #183. Apple confirmed VALID processing and internal Testers
membership. The compatible calendar-move Worker was deployed for the preceding
[build 37 release](../app-store-submission/release-37.md); build 38's backend
source is unchanged and required no backend deployment. The current release
record retains the signed-package evidence and remaining physical-device limits.

**Client verification (@owner):** Legacy-route REST checks and the live workout
canary remain explicitly owner-deferred, not passed. The existing exception
permits the completed internal distribution; do not reintroduce those checks
as a pending upload gate. Library P0 is merged and verified in
[PR #161](https://github.com/namarks/tres-fort/pull/161). The Workouts surface
includes schedule badges, separate Unschedule and Delete workout actions,
and a today-or-future date picker using the shared
assignment guard and attempt-CAS writer. The first build keeps released outgoing
request shapes and has shipped during the rename's compatibility window.
The compatibility Worker and migration 0045 are now released. The
[canonical rollout status](../workouts-and-multi-session/plan.md#next-step) records
the production evidence and the owner-approved deferral of live REST authoring,
date-assignment and session-write checks to the client rollout. Canonical-route
checks must pass before the later canonical-writing build is distributed.
Follow the [staged rollout](../workouts-and-multi-session/rollout.md).

Local/CI validation: [PR #161 CI](https://github.com/namarks/tres-fort/actions/runs/34371920505)
passed 404 iOS unit tests and 23 UI journeys; the full backend
suite passed 897 tests, including both physical schemas and old/new wire
contracts.
Those tests verified that Unschedule retains the workout and dated session while clearing its recurring
entries. The library-date assignment appears in Today and the coach's current
workout response without changing the recurring plan. P1 now supplies tags/archive. Freestyle (P2) and multiple sessions per date
remain unimplemented and outside the completed goal's scope.

## Notes / open questions

- The September 18 follow-up selects P0.5(a)/(b) as the first SensAI-inspired
  implementation candidates, followed by P0.5(c). The owner subsequently
  activated P0.5(a), then P0.5(b), ahead of P1, and authorized their combined
  internal TestFlight distribution with the recent UI fixes. P0.5(c), production
  deployment and App Review/public-release authority remain separate decisions. The evidence
  note distinguishes observed competitor behavior from untested coaching quality.

- Source: owner observation (2026-09-05) that everything in the app is framed
  around the routine or block day, which is too rigid for travel and ad-hoc
  adjustment. The backend already treats days as reusable and the schedule as
  optional; the gap is presentation plus tags, archive, and freestyle.
- Rejected: a second workout table beside the old `day_templates` store. It would fork
  the versioned tree, force every editor and MCP tool to handle two shapes,
  and break `set_logs.template_exercise_id` history for one of them.
  The renamed `workouts` table is the same library.
- P0.2 updates the earlier one-off-edit decision in response to the owner's
  2026-09-12 unavailable-machine request: the active runner substitutes a single
  slot for that session attempt. It stores slot snapshots on the session,
  without creating library workout copies. The library editor still edits the
  reusable prescription; freestyle (P2) remains separate.
- Open: whether `archived_at` should also apply to `template_exercises`
  (retire a slot without detaching history). Defer until a member asks;
  delete-with-detach exists today.
- Open: freestyle sessions and group feeds. A freestyle session has no
  template name for `get_group_feed`; show "Freestyle · N exercises" and
  revisit with `group-experience-and-governance`.
- Naming and one-session-per-date are both real constraints this plan works
  within: `day_templates` was the historical name for a reusable workout,
  and `ux_session_user_date` (migration `0029`) forbids two strength sessions
  on one civil date. Both are addressed by
  [Workouts and multi-session days](../workouts-and-multi-session/plan.md);
  The coordinated P0 delivery uses canonical workout terms while retaining
  the released aliases for the server-first rollout and compatibility cycle.
- `sessions.kind` is fixed within an attempt. The existing one-row-per-date
  model reuses empty planned/skipped dates and discarded sessions; an explicit
  start may change kind only while advancing the observed attempt and only
  when no live sets remain. Live/completed sessions cannot change kind. This
  preserves the `(user_id, date)` rule and rejects old queued set intents.
- Saving uses a dedicated transaction endpoint because ordinary `add_day`
  cannot atomically validate the reviewed source, repoint the session and
  advance its attempt. It reuses the same plan version claim, prescription
  validation, audit and snapshot writer. Migration 0054 retains an account-
  scoped save receipt for exact retries, export and account deletion.
