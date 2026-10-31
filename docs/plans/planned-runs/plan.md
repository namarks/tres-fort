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

- [ ] **P0 — Runs in the plan document**
  - Define the step format:
    - Ordered steps, each a warm-up, work, recovery or cool-down step.
    - Each step ends after a duration or a distance.
    - Each step has an optional target: a pace range (seconds per km) or a
      heart rate range (bpm).
    - Repeat groups cover intervals.
  - Store the steps on a run slot of a plan workout. Use a new numbered
    migration and an outdoor Run catalog exercise with the `cardio`
    modality.
  - Validate the steps on every write: bounded count and nesting, positive
    durations and distances, and target ranges where min ≤ max.
  - The steps travel with the versioned plan:
    - `plans.version` changes when they change.
    - They appear in snapshots and restore, and in `/api/state`.
    - The SQL and TypeScript writable-document serializers stay in parity.
  - The MCP tools that add and update exercises, and `update_plan`, accept and
    return steps. Accepted writes are audited and noted like other plan edits.
  - Record the MULTISPORT §11 exception for planned run steps.
- [ ] **P1 — Planned runs in the app**
  - Today, the week strip and the workout view show a planned run's steps
    and targets. Starting it opens the run recorder with that plan.
  - Weight and rep editing doesn't apply to run slots. The iOS editor shows
    them read-only until a later phase adds step editing.
- [ ] **P2 — Follow the plan while recording**
  - The recorder moves through the steps by time or distance. It shows the
    current step, its target range and what's left in it. The member can
    skip a step.
  - The uploaded run's name says which planned run it was. A run started
    without a plan works as it does now.
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
| P2 | blocked_by | plan:run-recorder#P3 | Steps and cues build on a recorder whose accuracy has been checked on a real device. |
| P2 | coordinates_with | plan:run-recorder#P4 | Both change the recorder's screen and its pause handling. |
| P4 | gated_by | external:owner-planned-runs-device-verification | Real runs on the owner's iPhone need an authorized TestFlight build. |

## Next step

**Now (@agent):** Write the step format and its validation (P0), with the
migration, serializer parity and MCP tool changes, as one PR.

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
