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
    catalog replay test. Update both exact row-count assertions
    (`test/catalog.test.ts` and `test/catalog_v2.test.ts`, 254 today) and
    re-check the alias-uniqueness and alias-determinism tests in both files:
    `ex_dips` already owns the plain dip aliases and `ex_superman` carries
    "back extension bw".
  - Let the iOS configure-exercise screen mark any exercise as a timed hold
    and prescribe a rep range, using the existing `target_duration_s` and
    `target_reps_max` slot fields; the REST editor route and MCP already
    accept both. The runner already declares per-set `is_timed` when it logs
    (migration `0024`) and the per-set value labels consume it, but the
    history duration chart still gates on catalog modality, so a
    duration-pinned hold on a `bw` exercise needs that chart re-keyed to
    `is_timed` in the same slice.
  - Close out the timed auto-log report. Open issues #71 and #92 are
    re-mirrors of the same TestFlight submission as #55, which `9a533e8`
    fixed with `finishTimedSetAuto`; the residual gap is that the runner's
    countdown task is cancelled when the view disappears while `timedActive`
    stays true. Cover the backgrounded and view-dismissed cases, close the
    two duplicates, and fix whichever mirror filed them: the in-repo
    `beta:feedback` script writes a different label and dedupe marker than
    these issues carry, so the re-filing came from a mirror outside this
    repository. Planks, L-sits, and hangs are the timed slots a bodyweight
    plan leans on.
- [ ] **P1 — Added load, assistance, and honest metrics**
  - Define `weight` on a `bw` or `timed` slot or set as added load: positive
    for a belt or vest, negative for band or machine assistance, zero for
    strict bodyweight. Write the convention into the `log_set` and
    `add_exercise` tool descriptions so Claude and iOS agree; no schema
    change. Today iOS hides the weight control and pins the logged weight to
    zero whenever the catalog modality is `bw`, the timed runner hard-codes
    weight zero when it commits a hold, and `adjustWeight` / `setWeight`
    clamp at zero, so the clamp must be lifted for these slots before a
    negative value can be entered.
  - Show an added-load / assist control in the runner for bodyweight and
    timed exercises, defaulting to zero, and render "BW+45 × 5", "BW−30 × 8",
    "BW × 8", and "45s" consistently in Today, history, the day agenda, and
    the group feed. The group feed's server DTO must start carrying
    `is_timed` and `duration_s`; today it renders every set as weight × reps.
  - Report rep-based metrics for bodyweight exercises (best set, total reps
    per session) and best hold for timed exercises; show estimated 1RM only
    when added load is positive. Keep tonnage undefined for zero-load work
    rather than reporting zero or inventing a body mass, and exclude
    negative-load (assisted) sets from tonnage rather than letting them
    subtract from it. Today the Epley top-set and tonnage rollups compute to
    zero for every bodyweight set.
  - Cover the convention with backend tests on the history and volume
    rollups and with iOS rendering tests for the three value forms.
- [ ] **P2 — Progress by variation in the app**
  - Expose the existing swap-exercise service over the authenticated REST
    editor path and add a "Replace with…" action in the iOS editor that keeps
    the slot's targets, order, and warm-up flag. The service currently
    ignores the `carry_targets` flag the MCP tool advertises and always
    carries targets; honor it or remove it as part of the exposure rather
    than propagating an inert parameter.
  - Record the swap in the same audit trail and version bump as other plan
    edits so Claude can see that the member advanced a progression.

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P0 | coordinates_with | plan:manual-workout-authoring#P0 | Both edit the iOS configure-exercise screen; build one shared editor rather than two. |
| P1 | coordinates_with | plan:gym-runner-depth#P0 | Both change the runner's value-entry controls; serialize the shared surface. |
| P1 | feeds | plan:coaching-feedback-loop#P2 | Rep-based and hold-based history gives the coach usable bodyweight progress signals; it does not block coaching work. |

## Next step

**Now (@owner):** Activate P0 and sequence it with
`manual-workout-authoring#P0` on the shared editor so the first manual
bodyweight routine can be prescribed with holds and rep ranges.
P1 and P2 wait for P0 evidence, not for a product decision.

## Notes / open questions

- Source: [research/calisthenics-readiness-review-2026-09.md](research/calisthenics-readiness-review-2026-09.md),
  a static review at commit `c71e3f9` plus the corrections from the
  exact-head review of this plan. Its line references drift; verify against
  current code before acting.
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
