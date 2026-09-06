# Supersets and Circuits

Slug: supersets-and-circuits · Status: planned · Updated: 2026-09-06 · Theme: gym-floor

## Goal

Let a workout prescribe a group of exercises performed in rotation, with rest
only after the round, so "10 push-ups, 10 squats, rest, repeat" is one
authored unit and the runner cues it that way. Done means a member or Claude
can group adjacent slots, the runner alternates through the group one set at
a time and rests after the last member, every set still logs against its own
slot, and an ungrouped workout behaves exactly as it does today.

## Why this is a model change

A slot (`template_exercises`) carries its own `order_index`, `target_sets`,
and `rest_seconds`, and nothing ties two slots together. The runner keeps one
`exerciseIndex`, performs every set of that slot, and calls `startRest` after
each one (`SyncModel.swift`). There is no superset, circuit, or grouping
concept in the schema, the service layer, the MCP tools, or either iOS
editor. A warm-up of alternating push-ups and squats therefore cannot be
expressed by anyone, and the closest workaround (two slots with
`rest_seconds = 0`) still performs all push-up sets before the first squat.

This plan is separate from the workout library and the multi-session work:
those decide which workouts exist and when they run; this decides how one
workout is sequenced inside the runner.

## Phases

- [ ] **P0 — Group model, serialization, and coach authoring**
  - Add three nullable columns to `template_exercises` in one additive
    migration: `group_id` (TEXT UUID), `group_rest_seconds` (INTEGER, rest
    after a full round), and `group_transition_seconds` (INTEGER, rest
    between members inside a round, normally `0`). Slots that share a
    `group_id` within one day form a group; the two rest values are group
    attributes stored on every member and validated equal. `rest_seconds`
    is never touched by grouping: it keeps its ordinary per-slot meaning,
    is ignored by the runner while a slot is grouped, and is intact again
    the moment the slot is ungrouped. No value is positional, so which
    member is last carries no stored meaning.
  - Cross-slot invariants, checked by one validator that every write path
    below calls: members are contiguous by `order_index`, share one
    `target_sets`, share the two group rest values, and number at least two.
    A write that would violate them is rejected with `group_conflict`; the
    one exception is removing a member, which normalizes a one-member group
    to `NULL`. Paths: `addTemplateExercise`, `updateExercise`
    (`order_index`), `deleteTemplateExercise`, `dedupeDayOrderIndexes`,
    `swapExercise`, `updatePlanTree`'s rebuild (which carries the three
    columns through the slot remap), and `deleteDayTemplate`. Reordering a
    grouped slot outside its group is rejected; moving the whole group is a
    reorder of all members in one call.
  - All group writes are atomic and go through one service operation:
    `setGroup(dayId, memberIds, { round_rest, transition_rest })` creates
    or rewrites a group (assigning a new id when none exists), and
    `clearGroup(groupId)` nulls the three columns on every member. Both
    validate, bump `plans.version` once, audit, and write a note. The
    single-slot routes and `update_exercise` reject the three group fields
    with `unknown_fields`, so no path can change one member in isolation.
    Expose `setGroup`/`clearGroup` as `PUT /api/days/{id}/groups` (audited
    `actor='ios'`) and as the MCP `group_exercises({day, exercises: [...],
    round_rest, transition_rest?})` and `ungroup_exercises` tools, thin
    wrappers over the same functions. `get_current_plan`,
    `get_today_workout`, and the coach brief render groups in A1/A2 notation
    with both rest values.
  - Released-client compatibility (see the shared rule in
    `workouts-and-multi-session`): a client that does not declare the
    `groups` capability receives the plan tree with the three group columns
    omitted and each member's `rest_seconds` replaced by the group's
    `group_rest_seconds`, so the current runner performs the members
    sequentially with the round rest after every set, which is today's
    behavior for an ordinary slot. Group-aware clients and MCP receive the
    stored values.
  - Tests: group round trip through `update_plan`; every invariant path
    above rejecting or normalizing; a client-view test for a non-group-aware
    request; and MCP authoring of the push-up/squat warm-up with
    `is_warmup = 1` on both members.
- [ ] **P1 — Round-based runner**
  - The runner iterates a group by rounds: after logging a set of a
    non-last member it cues `group_transition_seconds` (`0` means no cue)
    and advances to the next member; after logging the last member's set it
    cues `group_rest_seconds` and returns to the first member, until every
    member has reached `target_sets`. "Last" is derived from `order_index`
    at run time, never stored. `currentSetNumber` becomes the round number
    inside a group. Per-slot completion stays keyed on
    `template_exercise_id`, so history, PRs, and volume rollups are
    unchanged.
  - The rest overlay and Live Activity show "up next" as the next member,
    not the same exercise; timed members (a plank inside a circuit) reuse the
    existing timed-set path, and warm-up groups render inside the warm-up
    section with the existing tag.
  - Correcting or deleting a just-logged set inside a group keeps the runner
    on the right member and round; add this case to the runner recovery
    tests beside the existing background/resume coverage.
- [ ] **P2 — Editor support in iOS**
  - In `EditWorkoutSheet`, multi-select adjacent slots and choose "Group as
    superset"; a group renders as one card listing its members with the
    round rest and transition rest as two labeled fields; "Ungroup" calls
    `clearGroup`, and each member's own rest reappears unchanged. Reordering
    moves a group as a unit and refuses to split one, matching the server
    invariant.
  - A grouped slot's target sheet shows its ordinary rest as inactive while
    grouped, with the group's values shown on the group card, so nothing
    about the model is implied by position.
  - Verify a member can author the push-up/squat warm-up plus a working
    superset from the routine editor, run it in P1's runner, and see the
    same structure through `get_current_plan`.

## Execution frontier

- P0

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P0 | coordinates_with | plan:workouts-and-multi-session#P0 | Both add or rename columns on the same plan-tree tables; whichever lands second rebases onto the other's migration and serializer. |
| P0 | coordinates_with | plan:reversible-plan-management#P0 | Snapshots must serialize `group_id` or a revert silently ungroups a workout. |
| P1 | blocked_by | plan:supersets-and-circuits#P0 | The runner needs the field and its invariants before it can sequence rounds. |
| P1 | coordinates_with | plan:gym-runner-depth#P0 | Both change the runner's exercise flow and correction path; share the slice rather than fork the runner. |
| P1 | coordinates_with | plan:bodyweight-training-support#P1 | Both touch the runner's value-entry controls; serialize the shared surface. |
| P2 | coordinates_with | plan:workout-library#P0 | Both edit the routine and slot editors; do not run concurrently on the same iOS files. |

## Next step

**Now (@owner):** Decide the priority of P0 relative to `gym-runner-depth#P0`.
P0 is backend and MCP only, so Claude can author supersets before the runner
change ships; until P1 lands, iOS receives the compatibility view (group
columns omitted, round rest on every member), which is safe but not useful on
the gym floor.

## Notes / open questions

- Source: owner observation (2026-09-06) while authoring a plan manually: no
  way to stack exercises so a rotation replaces the rest between sets, e.g.
  a warm-up of 10 push-ups plus 10 squats then rest.
- Rejected: a separate `slot_groups` table. It would be a fourth plan-tree
  table with its own rebuild, snapshot, and remap paths; one nullable column
  on the slot table carries the same information.
- Rejected: treating `rest_seconds = 0` as an implicit "superset with the next
  slot". A genuinely zero-rest prescription and a superset would be
  indistinguishable, and the runner could not tell where a group ends.
- Reversed during review: the first draft encoded the round rest
  positionally as the last member's `rest_seconds` to avoid a new column.
  Four review findings (ungroup losing rests, membership edits shifting
  meaning, the runner cueing the wrong member's value, and released clients
  performing zero-rest sets) all traced to that one choice, so the group's
  rest values are now their own columns and `rest_seconds` is never
  repurposed. Redundant storage on every member is validated equal by the
  same validator that enforces contiguity; a separate `slot_groups` table
  was still rejected because it would add a third rebuild and remap path to
  `updatePlanTree` and to plan snapshots for two integers.
- Open: mixed set counts inside a group (3 rounds of A, 2 of B). The
  equal-sets invariant keeps the runner rule simple; relax it only if a
  member asks, since the plan tree can already express it by splitting the
  extra set into an ungrouped slot.
- Out of scope: clock-driven formats (AMRAP, EMOM, timed circuits). Record
  as a candidate; they need a workout-level timer the runner does not have.
- `sessions`, `set_logs`, and every analytics query are untouched. A set in
  a group is an ordinary set on its own slot.
