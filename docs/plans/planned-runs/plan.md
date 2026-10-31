# Planned runs with pace and heart rate targets

Slug: planned-runs · Status: active · Updated: 2026-10-31 · Theme: connected-training

## Goal

The coach can plan a run with steps and targets, such as a 10-minute warm-up,
then 4 × 800 m at 4:10/km with 2-minute jogs, then a cool-down. A simpler
plan might be 40 minutes in heart rate zone 2. The run is part of the Tres
Fort plan, next to the lifting days, and it is scheduled the same way. The
member sees today's run in the app and starts it in the run recorder. The app
announces each step as it starts and says whether the member is on, above or
below the target pace or heart rate. The recorded run still uploads to
intervals.icu, which stays the store of completed runs.

## Phases

- [x] **P0 — Runs in the plan document**
  - The step format lives in `src/runSteps.ts`:
    - An ordered array of steps and repeat groups. A step is
      `{kind, duration_s | distance_m, target?}`, with `kind` one of
      `warmup`, `work`, `recovery` or `cooldown`, and exactly one of a
      whole-second duration or a distance in meters.
    - A target is a pace range `{type: "pace", fastest_s_per_km,
      slowest_s_per_km}` (120 to 1200 s/km) or a heart rate range
      `{type: "heart_rate", min_bpm, max_bpm}` (40 to 230 bpm), with the
      lower bound no higher than the upper one.
    - A repeat group is `{repeat, steps}`: 1 to 50 repeats of 1 to 10 plain
      steps. Groups don't nest. A plan holds at most 50 items and 200 steps
      once repeats are expanded. Unknown keys are rejected.
  - Migration 0058 adds the nullable `template_exercises.run_steps` column
    and the `ex_outdoor_run` catalog row ("Outdoor Run", `cardio`, `min`).
    The bare "run" and "jog" stay on Treadmill, because aliases never take
    an existing phrase.
  - `validateExercisePrescription`, which every slot writer calls, validates
    the steps from a caller's array or the stored text and names the exact
    field, such as `run_steps.1.steps.0.target`. Only the outdoor run can
    carry steps, so swapping a run that has steps to another exercise is
    rejected until they're cleared. The column stores canonical JSON text.
  - The steps travel with the versioned plan like `progression`:
    - Adding, patching and clearing them bumps `plans.version`.
    - `update_plan` keeps the matched slot's steps when a rebuilt slot omits
      them, and `null` clears them.
    - The SQL and TypeScript snapshot serializers both write `run_steps` as
      the slot's last key. Older snapshots read as having no steps and compare
      unchanged. Restore writes the steps back. Plan reads and `/api/state`
      return them as JSON text.
  - `add_exercise`, `update_exercise` and `update_plan` accept steps, and
    their descriptions document the format. The REST add and patch routes
    accept them too, through the same functions. Accepted writes are audited
    and noted like other plan edits.
  - MULTISPORT §11 records the exception for planned run steps.
  - Not covered: partner workouts copy slots without steps, and the runner's
    per-set target snapshot doesn't include them. Neither path records
    runs.
- [x] **P1 — Planned runs in the app**
  - The app reads `run_steps` from `/api/state` (`RunPlan.swift`). Steps it
    can't read, such as a format a newer server adds, show the slot as a
    plain run instead of failing the plan.
  - Steps read in the recorder's miles-or-kilometers choice: "10 min
    warm-up", "800 m at 4:05–4:15 /km", "40 min at 130–145 bpm". Repeats show
    as a count with their steps indented under it.
  - Today shows the steps of a workout that is only a run, and its button
    starts the run recorder with that plan instead of a lifting session. The
    week strip marks a run day with a running icon and its steps, and the
    workout view lists them.
  - In a mixed workout the runner shows the planned run and a Start run
    button that opens the recorder. Where recording isn't supported (iPad,
    the App Store build, before iOS 26) the run slot keeps its timed
    controls.
  - The recorder's start screen shows the plan it was opened with. A run
    started from the toolbar has no plan, and a run already recording
    keeps the plan it started with.
  - The workout editor shows a run's steps read-only: it doesn't open the
    sets and load editor, and a run with steps can't be replaced. Removing
    the slot still works.
  - Not covered: a recorded run doesn't mark the planned workout done, and
    the iPad runner and partner workouts show run slots as before.
- [x] **P2 — Follow the plan while recording**
  - A run started from a planned slot keeps its steps in the run's
    checkpoint (`RecordedRun.plan`), so a recovered run picks up at the same
    step. `RunPlanProgress` unrolls repeats and ends a step when its moving
    time or distance is done. Paused time doesn't count. A step that ends
    between two updates ends where steady running between them would have
    crossed it, in time and distance, so a late update doesn't shorten or
    stretch the next step. When a late GPS batch dates an auto-pause back
    to the fix where the runner stopped, a step that only ended in the
    time the pause removes starts again. A skip is never undone.
  - While recording, a banner above the map or large numbers shows the
    step and repeat ("STEP 3 OF 10 · REP 2 OF 4"), its target, what's left
    and the next step, with a Skip button. After the last step it says the
    plan is done and the run keeps recording.
  - The uploaded run is named after the planned workout. A run started
    without a plan, or from a slot without steps it can read, works as
    before.
  - The plan moves on with each distance, route or heart rate update and
    once a second, so a timed step ends on time.
  - Not covered: the Lock Screen still shows only time, distance and pace.
    Spoken step and target cues are P3.
- [ ] **P3 — Spoken cues**
  - Announce each step as it starts ("800 meters at 4:10 per kilometer").
  - Say when pace or heart rate leaves the target range ("Speed up",
    "Ease off", "Heart rate high") and when it returns.
  - Cue from a smoothed value after a short delay, so GPS noise doesn't
    chatter. Don't repeat a cue within about 30 seconds.
  - Cues use the split speaker and its mute control, and work with the phone
    locked.
- [ ] **P4 — Verify on the owner's iPhone**
  - Run at least one interval session and one heart rate run that the coach
    planned.
  - Check step timing and how useful and well-timed the cues are. Check that
    the uploaded run in intervals.icu lines up with the plan.

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P3 | coordinates_with | plan:run-recorder#P3 | Spoken cues are tuned on the same real runs that check the recorder. The owner chose on 2026-10-31 to build P2 before those runs. |
| P2 | coordinates_with | plan:run-recorder#P4 | Both change the recorder's screen and its pause handling. |
| P4 | gated_by | external:owner-planned-runs-device-verification | Real runs on the owner's iPhone need an authorized TestFlight build. |

## Next step

**Now (@agent):** P3, spoken step and on/off-target cues.

To try P1 and P2 on a phone, the owner authorizes migration 0058, the
Worker deploy and a TestFlight build; run-recorder P3's real runs can use
the same build.

P0's migration 0058 must be applied before a Worker that reads or writes
`run_steps` serves traffic. Applying it and deploying need separate
authority.

## Verification evidence

- P0: `test/run_steps.test.ts` covers the step format and its field paths,
  the catalog row and its aliases, MCP and REST add, patch and clear with the
  audit row and note, the run-only rule including swap, `update_plan`
  inheritance and clearing, snapshot parity in both serializers, a pre-0058
  snapshot comparing unchanged, and restore.
- P1: `ios/TresFortTests/RunPlanTests.swift` covers reading steps, repeats
  and both targets, rejecting text the app can't read, the step, summary,
  pace (per km and per mile), distance and duration wording, run slot
  labels and the shared unit preference.
- P2: `RunPlanProgressTests` covers unrolling repeats, timed and distance
  steps, steps ended between two updates (including several at once), skipping, the end of the plan,
  what's left in miles or kilometers, and the checkpoint with and without a
  plan. `RunRecorderTests` covers a planned run moving through its steps,
  paused time not counting, a backdated auto-pause undoing a step but not a
  skip, skipping, the uploaded name, a slot without
  steps, and recovery at the saved step.

## Notes / open questions

- Asked for by the owner on 2026-10-30 after the first recorded run: plan
  run types by pace or heart rate, with spoken cues for on or off pace.
- Storage decision (owner, 2026-10-31): planned runs live in the Tres Fort
  plan, not as intervals.icu calendar events. The alternative would have
  synced the workout to the Garmin, and the owner chose not to take it. This
  is an exception to MULTISPORT §11's "no structured-step workout DSL".
  Completed runs still go only to intervals.icu, so §11's single store for
  endurance results holds.
- Targets are absolute (min/km, bpm) in P0. Zones relative to threshold pace
  or maximum heart rate need the member's values stored somewhere; that's
  left open.
- Treadmill runs have no GPS pace. Heart rate cues could still work there,
  but they are out of scope until outdoor runs work.
