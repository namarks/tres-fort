# Planned runs with pace and heart rate targets

Slug: planned-runs · Status: active · Updated: 2026-11-07 · Theme: connected-training

## Goal

The coach or the member can plan a run with steps and targets, such as a
10-minute warm-up, then 4 × 800 m at 4:10/km with 2-minute jogs, then a
cool-down. A simpler plan might be 40 minutes in heart rate zone 2. The run
is part of the Tres Fort plan, next to the lifting days, and it is scheduled
the same way. The member sees today's run in the app and starts it in the run
recorder. The app
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
  - Not covered: a recorded run doesn't mark the planned workout done (P7
    adds this), and the iPad runner and partner workouts show run slots as
    before.
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
- [x] **P3 — Spoken cues**
  - Each step is announced as it starts, including the first and a skipped
    one: "Step 2 of 10. Rep 1 of 4. 800 meters at 6:34 to 6:50 per mile."
    The end of the plan says "Plan complete."
  - `RunTargetCoach` says when pace or heart rate leaves the step's target
    ("Speed up", "Ease off", "Heart rate high. Ease off", "Heart rate low.
    Pick it up") and when it's back ("On pace", "Heart rate on target").
  - Pace is the recorder's 30-second current pace, used only while GPS
    delivered a point in the last 10 seconds; heart rate is the 15-second
    average. Leaving the range needs a margin (5 s/km, 2 bpm) and returning
    needs none. Readings from a step's first 30 seconds don't count, so the
    pace window holds only that step. A change must hold 10 seconds, and a
    gap in readings starts the hold again. Cues are at least 30 seconds
    apart, counting the step announcement. Staying on target says nothing.
  - Cues use the split speaker and its mute control, so they duck music and
    work with the phone locked. The start screen's toggle reads "Announce
    each mile, step and target" for a planned run.
  - The thresholds are first guesses to tune in P4.
- [ ] **P4 — Verify on the owner's iPhone**
  - Run at least one interval session and one heart rate run that the coach
    planned.
  - Check step timing and how useful and well-timed the cues are. Check that
    the uploaded run in intervals.icu lines up with the plan.
  - Progress: the first heart rate run was on 2026-11-01 (0.5 mi warm-up,
    then 3 mi at 147–153 bpm): 3.29 mi, 25:37 moving, average 150 bpm. It
    found the gaps P7 closes. An interval session is still to do.
- [x] **P5 — Plan runs in the app**
  - The owner's rule (2026-11-01): every feature must be usable in the app
    without an AI coach. Until P5, only the coach could write steps.
  - In the workout editor, tapping an outdoor run opens "Plan run" instead
    of the sets and loads form. A member adds steps and repeat groups, moves
    or removes them, and sets how many times a repeat runs.
  - Each step has a kind (warm-up, work, recovery, cool-down) and ends after
    a time or a distance. A distance can be typed in m, km or mi. The step
    can carry a pace range, typed as m:ss in the recorder's unit and stored
    per kilometer, or a heart rate range.
  - The editor checks the server's limits before saving (`RunPlanLimits`
    mirrors `RUN_STEP_LIMITS`) and names the problem. It saves through the
    existing slot PATCH with the reviewed plan version, so the server still
    validates, audits (`actor='ios'`) and bumps the plan version. "Remove
    all steps" saves `null`, which leaves a plain run.
  - Steps in a format this app can't read can only be removed, so editing
    never drops them silently.
  - Adding "Outdoor Run" from the exercise list says to tap it afterwards to
    plan steps.

- [x] **P6 — Steps laid out like a running watch**
  - The owner asked on 2026-11-02, after opening the first planned run,
    for steps laid out the way Garmin and other apps show a structured
    workout. Before this, steps read as plain lines such as "805 m
    warm-up" and "3 mi".
  - Wherever a planned run's steps show (workout details and preview,
    Today, the recorder's start screen), the total comes first ("TOTAL
    3.5 mi", or "26 min + 3.2 km"). Each step is then a row with a colored
    bar and its type (Warm up, Run, Recover, Cool down), its distance or
    time, and its target ("Heart rate 145–158 bpm", "Pace 8:03–8:51 /mi" or
    "No target"). A repeat is an outlined "REPEAT 4×" block holding its
    steps.
  - In miles, a distance under a kilometer that is within a meter of a
    tenth or a quarter mile reads in miles ("0.5 mi", spoken "0.5
    miles"). Track distances such as 400 m and 800 m still read in meters.
    One-line summaries (the week strip and the step banner) keep their
    format.
- [x] **P7 — Finish a planned run**
  - The owner's first planned run (2026-11-01) stayed open on Today, its
    record read "0 working sets" and "Outdoor Run 0/1 sets", and the
    recorder only talked about intervals.icu.
  - Saving a run started from a planned slot logs that slot as one timed set
    of the run's moving time (`SyncModel.logRecordedRun`), the way a timed
    set is logged in the runner. Inside a started workout the runner moves
    on; a workout that is only that run starts and finishes, so Today shows
    "RUN COMPLETE" with the run's distance, time and heart rate. The
    recorder says the workout is marked done. The run's checkpoint keeps
    the slot, so a run recovered after the app was stopped still marks it.
  - A finished run workout's record shows the run instead of set counts:
    distance, moving time, pace, heart rate and load, each against the plan
    where it has one (planned distance or time, and a pace or heart rate
    target shared by every targeted step). The planned steps follow. The run
    is the day's run named after the workout, else its longest run, and it
    leaves the list of other activities. The day's title drops "+ RUN" for
    the workout's own run, and a recorded run settles its slot in "Compare
    with starting targets".
  - intervals.icu is optional for recorded runs. Without a connection the
    Worker answers 409 `intervals_not_connected`; a run Apple Health saved
    with its route and any strap readings then leaves this iPhone's queue
    and the recorder says so. A run Apple Health didn't save in full stays
    queued, since this iPhone holds the only full copy.

- [x] **P8 — Make a planned run from the week**
  - Before P8 a member made a planned run in five steps: New workout, pick
    Outdoor Run, open the workout, tap the run, then plan it. The editor
    itself (P5) was there; getting to it was the gap.
  - Tapping a weekday on the Plan tab offers "New run" beside "New activity"
    and "New workout". The member names it ("Easy run", "Intervals", "Tempo
    run", "Long run", or "Run" when left blank) and "Plan it every Monday"
    saves a workout holding one outdoor run, puts it on that weekday and
    opens the P5 step editor on it. "Not now" leaves a plain run on the
    weekday to plan later.
  - The workout is created with the reviewed plan version and kept on a
    retry, like a new activity, so a lost reply can't make a second one.
    The editor saves against the version it opened with. A name already
    used by a run reuses that run; a name used by a workout that isn't a
    run is refused. A run reads "Run" in the weekday's list.
  - No server change: the existing workout create, schedule and slot routes
    do the work and keep their audit (`actor='ios'`) and version checks.

- [x] **P9 — Laps for each step** (in the repository)
  - The owner, after an interval run on 2026-11-07: walking to cool down at
    the end made the run's average pace look slow, hiding how hard the
    intervals were. The post-run summary stays as it is; each step belongs
    on the run's detail, like a watch's lap list on Strava.
  - While recording, the plan's progress keeps where each step started and
    ended in moving seconds and meters (`RunPlanProgress.laps`), including
    a skipped step, in the run's checkpoint. A checkpoint from an older
    build has no marks and its run gets no laps rather than a partial list.
  - `RunLaps` turns the marks into laps: each step run, skipped or stopped
    in, and the stretch after the plan finished as its own last lap, with
    the run's own totals closing it so the laps add up to the run. Each
    lap's average and maximum heart rate come from the readings taken while
    it ran, pauses left out.
  - The upload carries them twice. `POST /api/activities/recordings` takes
    an optional `laps` field (JSON, `src/runLaps.ts`): each lap's step,
    kind, repeat round, planned time or distance, target, start, moving
    time, distance, heart rate and how it ended. Migration 0069 keeps them
    in `activity_laps`, once per recording (a retry fills missing laps,
    never replaces them). The TCX file has one lap per step (intensity
    Resting for a recovery), so intervals.icu shows each interval too. A
    step that ends mid-track starts the next lap's track on the same point,
    and `parseTcx` joins such tracks, so the route, its chart clock and the
    stored heart rate run straight across a step change while a pause still
    breaks them.
  - `GET /api/activities/:id/route` serves the laps with the recording
    (`laps`, null otherwise), also behind its intervals.icu copy. The app's
    run card in a day and a planned run's record, and the web day panel,
    list them under the run: "Run 2/4", "400 m · 1:33 · 6:14 /mi · 168
    bpm", and the step's target with on target, faster or slower (above or
    below for heart rate), "Skipped" or "Ended early", and "After the plan"
    for the rest.
  - Private like routes: group views and the coach never read them. The
    account export includes them; deleting the run or the account removes
    them.
  - Not covered: laps of runs the app didn't record (intervals.icu reads
    a watch's laps; Tres Fort could read them live like its route), splits
    per mile or kilometer for a run without a plan, and laps for the coach.

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P9 | coordinates_with | plan:run-recorder | The laps change the recorder's checkpoint, upload and TCX file. |
| P9 | gated_by | external:owner-release-approval | Migration 0069 must be applied before the API that writes laps, and the app needs a TestFlight build, each on the owner's written go-ahead. |
| P3 | coordinates_with | plan:run-recorder#P3 | Spoken cues are tuned on the same real runs that check the recorder. The owner chose on 2026-10-31 to build P2 before those runs. |
| P2 | coordinates_with | plan:run-recorder#P4 | Both change the recorder's screen and its pause handling. |
| P4 | gated_by | external:owner-planned-runs-device-verification | Real runs on the owner's iPhone, on TestFlight build 60. |

## Next step

**Now (@owner):** Run an interval session (P4); the first heart rate run
is done. P8 reaches the phone with the next TestFlight build after it
merges; it needs no Worker deploy or migration. P9 (laps) needs, each on
the owner's written go-ahead, migration 0069 applied before an API deploy,
a `tres-fort-web` deploy and a TestFlight build; then the next interval
run shows its laps.
Run-recorder P3's real runs can use the same build.

Released on 2026-10-31 with the owner's go-ahead: migration 0058 was applied
in production before the Worker deploy of main 97856cf, and TestFlight beta
build 59 was built from the same commit. No production row carries steps
yet, so the first planned run is the first real write. TestFlight beta
build 60 (2026-11-01, main 2832d0c) adds P5; it needed no Worker deploy or
migration, since P5 saves through the existing slot route.

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
- P3: `RunTargetCoachTests` covers the margins, settling, holding, a gap
  in readings, stale GPS, the 30-second gap between cues, back-on-target and heart rate cues, a new step starting
  fresh, and the spoken step wording in miles and kilometers.
  `RunRecorderTests` covers a planned run speaking its first and next
  steps, one heart rate cue, and the end of the plan.
- P6: `RunPlanTests` covers the total with repeats counted, the step type,
  amount and target titles, the repeat title, and short distances in miles
  versus track distances in meters, written and spoken.
- P7: `PlannedRunRecordTests` covers finding the workout's run, the
  distance, time, pace and heart rate rows against the plan, pace verdicts,
  plans without a shared target, and Today's one-line run summary.
  `SetOutboxTests` covers a recorded run logging its slot and finishing a
  run-only workout, and refusing another day, a workout not started and a
  run with no time. `RunRecorderTests` covers marking the workout done,
  including after recovery, a plain or refused run marking nothing, and
  the intervals.icu not-connected cases, including a route Health dropped. `RunRecordingTests` covers the uploader letting go
  only of runs Apple Health saved.
- P8: `WorkoutMetadataTests` covers the run's default name, telling a
  run from a workout or activity, reusing a run by name and refusing a
  name another workout has, and the weekday's "Run" label.
  `WeeklyScheduleJourneyTests` (nightly UI suite) makes a run from Monday,
  plans a repeat in the step editor and sees it on the weekday.
- P9: `test/run_laps.test.ts` covers the lap format and its refusals,
  `parseTcx` joining a track split on a shared point while a pause stays a
  break, keeping laps with a recording and serving them with its route to
  its member only, a retry filling but never replacing them, refusing
  malformed laps before keeping anything, the export, and deleting them
  with the run; `account_deletion.test.ts` covers the account.
  `RunLapsTests` covers the step marks, laps with their own heart rate
  and the stretch after the plan, a run stopped mid-step, no laps without
  a plan or from an older checkpoint, moving and clock time around a
  pause, the upload field, the TCX laps and shared points, and the rows
  on the run's detail with their verdicts. `web/test/runLaps.test.ts`
  covers the web's rows.
- P5: `RunPlanEditingTests` covers saving steps in the plan's format and
  reading them back, the draft's add, move, edit and remove operations,
  repeat defaults, the server's limits and each step problem, and pace and
  distance entry in miles and kilometers. `SetOutboxTests` covers saving
  steps and clearing them through the slot route with the reviewed version.

## Notes / open questions

- Asked for by the owner on 2026-10-30 after the first recorded run: plan
  run types by pace or heart rate, with spoken cues for on or off pace.
- Storage decision (owner, 2026-10-31): planned runs live in the Tres Fort
  plan, not as intervals.icu calendar events. The alternative would have
  synced the workout to the Garmin, and the owner chose not to take it. This
  is an exception to MULTISPORT §11's "no structured-step workout DSL".
  Completed runs still go to intervals.icu when it is connected, so §11's
  single store for endurance results holds there. Without a connection
  (P7), Apple Health keeps the run and Tres Fort reads it through the
  Apple Health import.
- Targets are absolute (min/km, bpm) in P0. Zones relative to threshold pace
  or maximum heart rate need the member's values stored somewhere; that's
  left open.
- Treadmill runs have no GPS pace. Heart rate cues could still work there,
  but they are out of scope until outdoor runs work.
