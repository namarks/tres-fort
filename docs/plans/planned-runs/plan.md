# Planned runs with pace and heart rate targets

Slug: planned-runs · Status: planned · Updated: 2026-10-31 · Theme: connected-training

## Goal

The coach can plan a run with steps and targets (for example a 10-minute
warm-up, 4 × 800 m at 4:10/km with 2-minute jogs, and a cool-down, or 40
minutes in heart rate zone 2). The member sees today's planned run in the app,
starts it in the run recorder, and hears where they are: each step as it
starts, and whether they are on, above or below the target pace or heart
rate. The planned run lives in intervals.icu, so the same workout can also run
on a Garmin, and the recorded run is uploaded there as usual.

## Phases

- [ ] **P0 — Prove a planned run round-trips through intervals.icu**
  - Write one planned Run as an intervals.icu `WORKOUT` event, with steps in
    intervals.icu's own workout text (durations or distances, with pace or
    heart rate targets), against the owner's account.
  - Confirm intervals.icu parses it into structured steps (`workout_doc`)
    with targets resolved from the member's pace and heart rate settings, and
    that it reaches the Forerunner through Garmin Connect.
  - Record the request and response shapes this plan relies on. MULTISPORT
    R1 still lists the run `POST /events` shape as unverified.
- [ ] **P1 — The coach plans runs**
  - An MCP tool writes, changes and removes planned runs on the member's
    intervals.icu calendar, with a `tresfort:planned:` marker, and mirrors
    each one into `external_events` straight away. That follows MULTISPORT
    §5.2's write-through design, and the existing hourly sync and webhook
    pick up edits made in intervals.icu.
  - Every accepted write records an audit row and a coach note like other
    MCP mutations. Provider failure is an error with no local copy.
- [ ] **P2 — Follow a planned run in the recorder**
  - The Worker serves today's planned runs with their parsed steps. The
    Today screen shows the planned run, and the recorder can start it.
  - The recorder steps through the plan by time or distance, shows the
    current step, its target range and what's left in it, and moves on by
    itself. The member can skip a step. A run started without a plan works
    as it does now.
- [ ] **P3 — Spoken cues**
  - Announce each step as it starts ("800 meters at 4:10 per kilometer").
  - Say when pace or heart rate leaves the target range ("Speed up",
    "Ease off", "Heart rate high") and when it returns. Use a smoothed value
    and a short delay before speaking, so GPS noise doesn't chatter, and
    don't repeat a cue within about 30 seconds.
  - The cues use the existing split speaker and its mute control, with the
    phone locked too.
- [ ] **P4 — Verify on the owner's iPhone**
  - Run at least one interval session and one heart rate run from a
    coach-planned workout. Check step timing, the cues' timing and
    usefulness, and that the uploaded run lines up with the planned steps in
    intervals.icu.

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P0 | gated_by | external:owner-planned-runs-scope | MULTISPORT §11 rules out structured workout steps; the owner must approve this exception and the plan's activation. |
| P2 | blocked_by | plan:run-recorder#P3 | Steps and cues build on a recorder whose accuracy has been checked on a real device. |
| P2 | coordinates_with | plan:run-recorder#P4 | Both change the recorder's screen and pause handling. |

## Next step

**Now (@owner):** Decide whether planned runs live in intervals.icu (this
plan's design) and approve the MULTISPORT §11 exception for structured run
steps, then activate the plan. P0 is a small spike against the owner's
intervals.icu account.

## Notes / open questions

- Asked for by the owner on 2026-10-30 after the first recorded run: plan
  run types by pace or heart rate, with audio cues for on or off pace.
- Why intervals.icu: MULTISPORT §11 keeps endurance truth in intervals.icu
  and forbids a second writable cardio store, and intervals.icu already
  turns workout text into structured steps with targets and sends them to
  Garmin. Tres Fort reads its parsed steps rather than inventing its own
  step format, so a planned run can be followed on the iPhone or the watch.
- Targets come from the member's intervals.icu settings (threshold pace,
  heart rate zones). A member without them set needs absolute targets
  (min/km, bpm) in the workout text; P0 checks both.
- Out of scope: treadmill runs, which have no GPS pace (cues by heart rate
  could still work), and watch-side execution beyond what Garmin already
  does with the synced workout.
