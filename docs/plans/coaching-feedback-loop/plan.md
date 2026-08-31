# Coaching Feedback Loop

Slug: coaching-feedback-loop · Status: planned · Updated: 2026-08-28 · Theme: coaching

## Goal

Close the loop between training and coaching: a member can record concise,
useful feedback after a workout; the coach can read it alongside the actual
session; and the member can see what changed in response. Done means feedback
and plan-change context travel through the existing Tres Fort data and MCP
surfaces without adding AI to the Worker or creating a second coaching record.

## Phases

- [ ] **P0 — Workout feedback reaches the coach**
  - Add an optional, quick finish flow for perceived fatigue and a short note;
    pain can be described in the note, and completing a workout must not
    require a questionnaire.
  - Persist those existing session fields and expose them through the relevant
    history, current-state, and coaching-brief reads so the next coaching
    conversation receives the member's words and the recorded workout without
    a schema change.
  - Verify one end-to-end path from iOS capture to MCP read, including an edit
    made before the session is finalized.
- [ ] **P1 — Coaching changes are visible and correctable**
  - Show recent plan changes in iOS with actor, time, concise rationale, and the
    affected day or exercise, using the canonical audit, note, and plan-history
    records rather than a parallel notification feed.
  - Let a member revisit dismissed changes and reach the correction or revert
    path owned by `reversible-plan-management`.
  - Keep manual and AI-authored edits equally visible; actor labels explain who
    changed the plan without giving either path a different data model.
- [ ] **P2 — Coaching uses the whole training context**
  - Include the existing schedule, recent feedback, races, periodization,
    trips, and stress settings in one compact coaching context where relevant.
  - Correct misleading trend labels and pair simple load or volume trends with
    the feedback that explains them; retain raw session history as the source.
  - Verify that iOS and MCP describe the same recent sessions and plan state.

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P1 | coordinates_with | plan:reversible-plan-management#P2 | Reuse one plan-history projection for visibility and reversion rather than building a second change feed. |

## Next step

**Now (@owner):** Activate P0 when member-to-coach feedback should enter the
executable backlog; it does not require the later change-history work to start.

## Notes / open questions

- The first slice captures only feedback a coach can act on. Readiness scores,
  questionnaires, automated recommendations, and model-generated diagnoses are
  outside this workstream unless real usage demonstrates a need.
- Per-set RPE remains part of ordinary set logging and later runner refinement;
  P0 does not add a separate session-RPE field.
- The Worker remains deterministic data infrastructure. Claude interprets the
  feedback in conversation; the backend stores and returns it.
- Reuse the durable terminal session-write path completed in
  [Workout Write Reliability](../completed/workout-write-reliability/plan.md);
  it is historical foundation rather than an unresolved dependency.
