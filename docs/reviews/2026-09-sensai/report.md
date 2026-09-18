# SensAI interaction patterns: evidence for the Très Fort plans

Observed: 2026-09-18. Comparison baseline: Très Fort remote main
`b669d2a7cb36a348aeb7bfdf16f9e032295d547a`.

## Decision and ownership

The owner requested incorporation of the six recommendations into the existing
plans. This note retains evidence and rationale; each linked `plan.md` owns
status, dependencies, acceptance conditions and the next action.

| Recommendation | Canonical owner | Rationale |
|---|---|---|
| Unified Technique / History sheet | [Workout library P0.5(a)](../../plans/workout-library/plan.md) | Connect existing information at the current exercise; first priority. |
| Consistent exercise and swap filters | [Workout library P0.5(b)](../../plans/workout-library/plan.md) | Make replacements discoverable without knowing an exact name; first priority. |
| Contextual coaching requests | [BYO coach P5](../../plans/bring-your-own-ai-coach/plan.md) | Carry workout context into a concrete request, reviewed proposal and return journey. |
| Small preview thumbnails | [Workout library P0.5(c)](../../plans/workout-library/plan.md) | Recognize unfamiliar movements while preserving prescriptions and grouping. |
| Next few sessions | [Member activation P3](../../plans/member-activation-and-adherence/plan.md) | Orient strength alongside known endurance plans using the existing projection. |
| Actionable progress empty states | [Member activation P4](../../plans/member-activation-and-adherence/plan.md) | Explain missing data and offer the next useful action. |

## Observed competitor behavior

Inspection used the installed [SensAI](https://www.sensai.fit/) iOS app through
iPhone Mirroring during a trial. The installed version was not recorded; these
are observations of that installation on the stated date, not private-code or
backend findings.

- Workout preview: exercise thumbnails and an About / History sheet, including
  a first-set history empty state.
- Add Exercise: alphabetical search plus Muscles, Force and Difficulty filters;
  selecting a muscle narrowed visible results.
- Workout Smart Modify: a short text field with shortcuts for shortening,
  adding an exercise or adding volume. Exercise Smart Swap: contextual request
  shortcuts for busy equipment, discomfort, variety or an easier movement.
- Schedule: a prominent next-workout action and weekly strength/cardio/rest list.
- Progress: first-use momentum and streak cards with approachable explanatory
  copy. Populated trends were not inspected.

No AI request was submitted and no set was logged or workout completed. The
empty test session was removed with permission and its scheduled workout was
verified retained. AI quality, approval/rollback behavior, post-set rest,
completed-set correction, offline recovery and background inference were not
tested. Pointer/keyboard mirroring is not evidence of one-handed reach,
software-keyboard behavior, haptics or physical accessibility. Impact/effort
rankings are product judgments, not measured usability results.

## Existing Très Fort foundation

At the comparison baseline, the app already has a fixed primary set action,
compact rest, last-set correction, session-only swaps, grouped prescriptions,
alias-aware authoring filters, demonstrations, exercise history and progress.
Relevant sources are [TodayView](../../../ios/TresFort/TodayView.swift),
[ExerciseDemoSheet](../../../ios/TresFort/ExerciseDemoSheet.swift),
[ExerciseHistoryView](../../../ios/TresFort/ExerciseHistoryView.swift),
[ExercisePickerView](../../../ios/TresFort/ExercisePickerView.swift),
[WorkoutExerciseSwapSheet](../../../ios/TresFort/WorkoutExerciseSwapSheet.swift),
[WorkoutExercisePreview](../../../ios/TresFort/WorkoutExercisePreview.swift) and
[TrainingProgressView](../../../ios/TresFort/TrainingProgressView.swift).
These are repository capabilities, not evidence of an installed release.

Reuse these components and Très Fort's own assets. A large compulsory animation,
new analytics store, unvalidated difficulty filters or duplicate schedule would
not follow from the observed benefits. Imported activity remains distinct from
completed strength sessions. In-app AI placement does not establish on-device
inference, model/provider choice or token economics.

## Evaluation approach

Use the same bounded tasks before and after a proposed interaction: find the
workout, inspect an unfamiliar movement, change a prescription, replace busy
equipment and review the last result. Record steps, errors, context re-entry and
lost set/timer state using synthetic accounts. Evaluate normal and large text
and preserve group/load semantics. Report simulator and real-device observations
separately. The evidence supports small, testable improvements; it does not
establish that SensAI is a better executor or coach overall.
