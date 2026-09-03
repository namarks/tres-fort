# Bodyweight Training Support

Slug: bodyweight-training-support · Status: planned · Updated: 2026-09-02 · Theme: gym-floor

## Goal

Let a calisthenics or bodyweight-first member prescribe, run, progress, and
review their training with the same fidelity a barbell lifter gets, with or
without Claude. Done means holds, rep ranges, added load, and assistance are
first-class on bodyweight slots; history and volume report numbers that mean
something for zero-load work; and the catalog covers the standard
gymnastic-strength movements.

## Phases

- [ ] **P0 — Holds, rep ranges, and the missing catalog rows**
  - Seed the catalog with the gymnastic-strength staples that are absent:
    ring dip, ring row, ring push-up, ring support hold, bar and ring
    muscle-up, L-sit, tuck and full front lever, back lever, tuck planche and
    planche lean, handstand hold, wall walk, crow pose, skin the cat, dragon
    flag, typewriter pull-up, eccentric pull-up, back extension, reverse
    hyper, and gymnastic bridge. Use `timed`/`sec` for static holds and
    `bw`/`lb` for rep work, add spoken-name aliases for the resolver, and
    follow the additive `INSERT OR IGNORE` pattern of migration `0021` with a
    catalog replay test.
  - Let the iOS configure-exercise screen mark any exercise as a timed hold
    and prescribe a rep range, using the existing `target_duration_s` and
    `target_reps_max` slot fields; the REST editor route and MCP already
    accept both, and per-set `is_timed` (migration `0024`) already renders a
    duration-pinned hold correctly everywhere.
  - Re-verify the open TestFlight report that the hold countdown does not
    auto-log at the end of a timed set, and fix it if it reproduces; planks,
    L-sits, and hangs are the timed slots a bodyweight plan leans on.
- [ ] **P1 — Added load, assistance, and honest metrics**
  - Define `weight` on a bodyweight-modality slot or set as added load:
    positive for a belt or vest, negative for band or machine assistance,
    zero for strict bodyweight. Write the convention into the `log_set` and
    `add_exercise` tool descriptions so Claude and iOS agree; no schema
    change. Today iOS hides the weight control and pins the logged weight to
    zero whenever the catalog modality is `bw`.
  - Show an added-load / assist control in the runner for bodyweight
    exercises, defaulting to zero, and render "BW+45 × 5", "BW−30 × 8", and
    "BW × 8" consistently in Today, history, the day agenda, and the group
    feed.
  - Report rep-based metrics for bodyweight exercises (best set, total reps
    per session) and best hold for timed exercises; show estimated 1RM only
    when added load is positive. Keep tonnage undefined for zero-load work
    rather than reporting zero or inventing a body mass. Today the Epley
    top-set and tonnage rollups compute to zero for every bodyweight set.
  - Cover the convention with backend tests on the history and volume
    rollups and with iOS rendering tests for the three value forms.
- [ ] **P2 — Progress by variation in the app**
  - Expose the existing swap-exercise service over the authenticated REST
    editor path and add a "Replace with…" action in the iOS editor that keeps
    the slot's targets, order, and warm-up flag.
  - Record the swap in the same audit trail and version bump as other plan
    edits so Claude can see that the member advanced a progression.

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P0 | coordinates_with | plan:manual-workout-authoring#P0 | Both edit the iOS configure-exercise screen; land one shared editor rather than two. |
| P1 | coordinates_with | plan:gym-runner-depth#P0 | Both change the runner's value-entry controls; serialize the shared surface. |
| P1 | feeds | plan:coaching-feedback-loop#P2 | Rep-based and hold-based history gives the coach usable bodyweight progress signals; it does not block coaching work. |

## Next step

**Now (@owner):** Activate P0 alongside `manual-workout-authoring#P0` so the
first manual bodyweight routine can be prescribed with holds and rep ranges.
P1 and P2 wait for P0 evidence, not for a product decision.

## Notes / open questions

- Source: the September 2026 calisthenics readiness review at commit
  `c71e3f9`. Its line references drift; verify against current code before
  acting.
- Body-mass tracking is deliberately out of scope. True tonnage for weighted
  or assisted bodyweight work is the one need it would serve; rep-based
  metrics cover the coaching decision without it, so the roadmap candidate
  stays deferred.
- A stored progression family (knee push-up → push-up → archer → one-arm) is
  a schema decision. P2's swap plus rep ranges is the bounded alternative;
  promote the family model only if members outgrow it.
- Circuits, supersets, AMRAP, and EMOM are not representable in the flat slot
  list and are not in scope. Document the interim convention (reps is the
  minimum, reps-max unset, cue "AMRAP") in the tool descriptions during P1.
- Custom exercises stay a candidate; the P0 seed is the first answer to
  catalog gaps.
