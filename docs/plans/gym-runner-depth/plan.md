# Gym Runner Depth

Slug: gym-runner-depth · Status: planned · Updated: 2026-09-02 · Theme: gym-floor

## Goal

Make the active-workout runner fast, clear, and easy to correct on the gym
floor. Done means the member can see the intended work and relevant prior
result, log or fix a set with minimal friction, use straightforward loading
and timing aids, and finish with an accurate summary.

## Phases

- [ ] **P0 — Intent and corrections at a glance**
  - Show the prescribed target, cues, and last comparable session beside the
    active exercise without turning the runner into a history dashboard.
  - Make weight, reps, RPE, and timed values easy to adjust before logging and
    allow a just-logged set to be corrected or deleted without leaving the
    workout or losing runner position and rest state.
  - Verify the normal log, correction, background, and resume path against the
    same server records shown in session history.
- [ ] **P1 — Practical loading and timing aids**
  - Add a simple barbell plate breakdown for the chosen target and an editable,
    deterministic warm-up ramp; do not build an equipment optimizer or an
    AI-generated warm-up system.
  - Make rest and timed-set cues legible and controllable when the app is
    foregrounded, backgrounded, or locked, reusing the existing cue and Live
    Activity implementation.
  - Repair weight-entry and timer interactions that cause extra taps or hide
    the value being recorded.
- [ ] **P2 — Useful completion feedback**
  - Present an immediate summary of completed work, personal records, and
    missed or changed targets using the final persisted session.
  - Carry the summary into history and the coaching feedback flow without
    inventing a second PR, volume, or completion calculation.

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P2 | feeds | plan:coaching-feedback-loop#P2 | The persisted completion summary provides context for coaching; it does not block runner delivery. |

## Next step

**Now (@owner):** Activate P0 as one focused runner slice, coordinating with
set-write work when both touch the same code rather than waiting for every
reliability phase to finish.

## Notes / open questions

- Apple Watch execution, custom exercises, advanced readiness scoring, and
  automatic programming are outside this plan.
- Added-load and assistance controls for bodyweight exercises and rep-based
  history belong to
  [Bodyweight training support](../bodyweight-training-support/plan.md); P1
  here stays barbell loading aids. That plan coordinates with P0 on the
  runner's value-entry controls.
- Reuse the durable set-intent, checkpoint, and recovery boundary completed in
  [Workout Write Reliability](../completed/workout-write-reliability/plan.md);
  it is historical foundation rather than an unresolved dependency.
- Each phase should batch a coherent gym task. Individual steppers, labels,
  cues, or PR badges are acceptance details, not separate workstreams.
