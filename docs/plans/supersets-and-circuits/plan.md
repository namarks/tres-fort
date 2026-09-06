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
  - Add `template_exercises.group_id` (nullable TEXT UUID) in one migration.
    Slots that share a `group_id` within the same day form one group.
    Invariants, enforced in the service layer and `update_plan`: members are
    contiguous by `order_index`, share one `target_sets`, and a group has at
    least two members. A single-member group is normalized to `NULL`.
  - Rest semantics without a second column: inside a group, a member's
    `rest_seconds` is the transition rest before the next member (default
    `0`), and the last member's `rest_seconds` is the round rest. Ungrouped
    slots keep today's meaning unchanged.
  - `update_plan`'s full-tree rebuild carries `group_id` through the slot
    remap the way it remaps day ids; `add_exercise`, `update_exercise`, and
    the REST slot routes accept and return it; `dedupeDayOrderIndexes` and
    the slot reorder paths keep groups contiguous or reject the move.
    `/api/state` carries the field in the plan tree.
  - One atomic grouping operation in the service layer, because the
    single-slot PATCH routes cannot build a group: the first PATCH would
    create a one-member group that P0 immediately normalizes back to `NULL`
    before the second member joins. `groupSlots(dayId, memberIds,
    roundRest)` validates contiguity and equal `target_sets`, assigns one
    new id, sets each member's transition rest to `0` and the round rest on
    the last member, and bumps `plans.version` once; `ungroupSlots(groupId)`
    is its inverse. Expose it as `PUT /api/days/{id}/groups` (audited as
    `actor='ios'`) and as the MCP `group_exercises({day, exercises: [...],
    rest_seconds})` tool, both thin wrappers over the same function.
    `update_exercise` still accepts `group_id` only to move a slot into an
    existing group or `null` to leave one; `get_current_plan`,
    `get_today_workout`, and the coach brief render groups in A1/A2 notation
    with the round rest. Each write audits and writes a note like any plan
    mutation.
  - Tests: group round trip through `update_plan`, contiguity and equal-sets
    rejection, delete-member normalization, and MCP authoring of the
    push-up/squat warm-up with `is_warmup = 1` on both members.
- [ ] **P1 — Round-based runner**
  - The runner iterates a group by rounds: after logging a set of member *i*,
    it advances to member *i+1* and cues that member's transition rest (`0`
    means no cue); after the last member it cues the round rest and returns
    to the first member, until every member has reached `target_sets`.
    `currentSetNumber` becomes the round number inside a group. Per-slot
    completion stays keyed on `template_exercise_id`, so history, PRs, and
    volume rollups are unchanged.
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
    round rest; "Ungroup" clears `group_id`. Reordering moves a group as a
    unit and refuses to split one.
  - The slot target sheet exposes transition rest for group members and
    round rest on the last member with those labels, so the convention from
    P0 is visible rather than implied.
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
change ships; a grouped workout degrades to today's sequential behavior until
P1 lands, which is safe but not useful on the gym floor.

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
- Rejected: a second `group_rest_seconds` column. The last-member convention
  keeps every existing column meaningful and needs no new editor field for
  ungrouped slots; P2 labels it explicitly so it is not hidden.
- Open: mixed set counts inside a group (3 rounds of A, 2 of B). The
  equal-sets invariant keeps the runner rule simple; relax it only if a
  member asks, since the plan tree can already express it by splitting the
  extra set into an ungrouped slot.
- Out of scope: clock-driven formats (AMRAP, EMOM, timed circuits). Record
  as a candidate; they need a workout-level timer the runner does not have.
- `sessions`, `set_logs`, and every analytics query are untouched. A set in
  a group is an ordinary set on its own slot.
