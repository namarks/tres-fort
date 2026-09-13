# Gym Runner Depth

Slug: gym-runner-depth · Status: done · Updated: 2026-09-07 · Theme: gym-floor · Archived: completed

## Goal

Make the active-workout runner fast, clear, and easy to correct on the gym
floor. Done means the member can see the intended work and relevant prior
result, log or fix a set with minimal friction, use straightforward loading
and timing aids, and finish with an accurate summary.

## Phases

- [x] **P0 — Intent and corrections at a glance**
  - Show the prescribed target, cues, and last comparable session beside the
    active exercise without turning the runner into a history dashboard.
  - Give explicit current prescriptions precedence over historical defaults;
    keep an intentional current-session edit during safe recovery. Display
    prescribed load/RPE/cues and separately labeled last-time values. Compare
    history deliberately by warm-up/working class, slot context and timed/rep
    mode. A previous 185 lb working squat must not seed a prescribed 45 lb
    warm-up or silently override a new 135 lb deload. Cover duplicate movement
    slots, changed prescriptions and rep-to-hold transitions.
  - Make weight, reps, RPE, and timed values easy to adjust before logging and
    allow a just-logged set to be corrected or deleted without leaving the
    workout or losing runner position and rest state.
  - Preserve the original set UUID, slot, account and attempt through correction
    and offline retry. Carry optional RPE in the durable set envelope. The
    ready-to-finish screen must still allow review/correction of the final set;
    local auto-advance must not remove the only correction path.
  - Surface a failed delete/edit next to the action, leave unacknowledged
    deletions intact, and separate pending intent from acknowledged mutation
    with stale refresh. Verify offline, rejection, delayed ACK and final-set
    correction without duplicate creates or lost rest/runner position.
  - Verify the normal log, correction, background, and resume path against the
    same server records shown in session history.
- [x] **P1 — Practical loading and timing aids**
  - Add a simple barbell plate breakdown for the chosen target and an editable,
    deterministic warm-up ramp; do not build an equipment optimizer or an
    AI-generated warm-up system.
  - Make rest and timed-set cues legible and controllable when the app is
    foregrounded, backgrounded, or locked, reusing the existing cue and Live
    Activity implementation.
  - Repair weight-entry and timer interactions that cause extra taps or hide
    the value being recorded.
- [x] **P2 — Useful completion feedback**
  - Present an immediate summary of completed work, personal records, and
    missed or changed targets using the final persisted session.
  - Carry the summary into history and the coaching feedback flow without
    inventing a second PR, volume, or completion calculation.
  - Use comparable load/assistance/timed cohorts from bodyweight P3 for PR
    claims. Mark a locally queued summary as pending until the server
    acknowledges it, preserving successful completion if only refresh fails.

## Completion evidence

P0–P2 are delivered together in the implementation PR. The runner honors
prescriptions, retains intentional drafts, and queues revision-guarded
corrections against original set identities. Final review keeps the last set
editable. Loading aids are deterministic and editable; rest/timed controls
reuse notifications and Live Activities with ownership tokens. Completion,
history and MCP consume one persisted summary, with tap-time plan provenance
and comparable Bodyweight P3 metrics. See [the delivery contract](decisions.md).

Local verification passed TypeScript, all 768 Worker tests across 56 files,
all 310 iOS tests on the base including PR #149, and the plan compiler. Simulator render inspection covered the active
runner, final review, loading guide and persisted summary. The PR records
terminal CI for the exact reviewed head. The checked phases and archive land
atomically with that implementation; production and app distribution are
separate.

## Completed-workout presentation refinement (September 2026)

Completed history opens with at most four readable stats: recorded session
elapsed time when available, server-owned external-load volume for a single
known unit, working sets, and reps or logged timed work. Pure bodyweight and
assisted work do not gain an invented body-mass or system-load estimate.
Session timestamps survive decoding, cache encoding and session alias handling;
missing timestamps omit duration rather than infer it from logging gaps.

The redundant exercise/cohort recap is removed. Personal records expand from a
compact count, one set-by-set log sits under Workout details, and the optional
starting-target comparison follows that log. Accessibility text uses one stat
per row. Synthetic fixtures cover the summary and disclosures, with metric and
session-cache regression checks. Exact-source verification and review are
recorded in the implementation PR. This refinement changes iOS only and still
requires distribution in a separately authorized app release.

## Delivered relationships

P0 carries the completed [prescription and recurring-adjustment contract](../prescription-integrity/decisions.md)
into the input controls. P2 supplies the persisted summary for
[coaching feedback P2](../coaching-feedback-loop/plan.md), without activating
that separate workstream.

## Next step

Repository delivery is complete. Under separate owner release authority,
apply pending migrations through `0043_runner_targets.sql`, deploy the reviewed
Worker, then distribute the iOS build. The new app requires the guarded
correction acknowledgement and summary endpoints. Physical-device foreground,
background and locked timer/sound smoke checks precede distribution; simulator
verification is not evidence of production activation.

## Notes / open questions

- [Completed bodyweight support](../bodyweight-training-support/plan.md)
  supplies variation replacement and comparable metrics. Reuse the shared
  `BodyweightProgress.json` contract for bodyweight PR/hold claims; this is a
  delivered repository foundation, not an unresolved dependency.

- The [September app review](../../../reviews/2026-09-app-review/report.md)
  confirmed prescription seeding and missing failure presentation in source.
  Accessibility and fixture walkthroughs have a cross-app owner in
  app-quality-and-maintainability; they are not a separate runner implementation.

- Apple Watch execution, custom exercises, advanced readiness scoring, and
  automatic programming are outside this plan.
- Added-load and assistance controls for bodyweight exercises and rep-based
  history belong to
  [Bodyweight training support](../bodyweight-training-support/plan.md); P1
  here stays barbell loading aids. P0 reuses the delivered value-entry controls.
- Reuse the durable set-intent, checkpoint, and recovery boundary completed in
  [Workout Write Reliability](../workout-write-reliability/plan.md);
  it is historical foundation rather than an unresolved dependency.
- Each phase should batch a coherent gym task. Individual steppers, labels,
  cues, or PR badges are acceptance details, not separate workstreams.
