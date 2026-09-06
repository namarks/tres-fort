# docs/plans — Engineering Workstream Plans

This directory is the repository-local source of truth for the current state of
multi-phase engineering work. These plans are distinct from the workout plans
stored in D1 and edited through the product API.

The shared `/resume`, `/backlog`, and `planning-conventions` workflows read this
directory using [`.agents/resume.yaml`](../../.agents/resume.yaml). One current
workstream has exactly one bundle here, and only its `plan.md` owns live phase
state, dependencies, execution frontier, and next step.

## The contract

- Current work lives at `docs/plans/<slug>/plan.md`.
- Optional implementation material lives beside it as `spec.md`,
  `decisions.md`, `runbook.md`, `research/`, or `archive/`. Supporting files do
  not carry parallel live checklists.
- Update phase checkboxes, `Updated:`, and `## Next step` when verified evidence
  changes the workstream state. A merge alone is not deployment, observation,
  or external-closeout evidence.
- Move verified finished bundles to `docs/plans/completed/<slug>/` with
  `Status: done` and `Archived: completed`.
- Move deliberately discontinued bundles to `docs/plans/abandoned/<slug>/`
  with `Status: abandoned`, `Archived: abandoned`, the reason, and any
  successor.
- Completed and abandoned histories never enter the current backlog or an
  active initiative.

## Plan shape

Create `docs/plans/<slug>/plan.md` with this structure:

```markdown
# <Workstream title>

Slug: <slug> · Status: <status> · Updated: <YYYY-MM-DD> · Theme: <theme>

## Goal

<The observable completion outcome.>

## Phases

- [ ] **P0 — <First verifiable slice>**
- [ ] **P1 — <Later slice>**

## Execution frontier

- P0

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P1 | blocked_by | plan:<other-slug>#P0 | <Why the prerequisite is hard.> |

## Next step

**Now (@agent):** Complete P0 and record its verification evidence.

## Notes / open questions

- <Material ambiguity, boundary, or evidence requirement.>
```

Use `active`, `gated`, `paused`, or `planned` for current plans. `active` is
eligible when its dependencies are ready; `gated` names unresolved evidence or
authority; `paused` is deliberately inactive; `planned` requires explicit
activation. `done` is only a closeout transition before moving the bundle to
`completed/`.

Every top-level phase is a bold checkbox with a stable ID. Without an
`## Execution frontier`, the first incomplete top-level phase is current. Add a
frontier only when exact nested phases or multiple independent phases are
simultaneously runnable.

Dependency targets are `plan:<slug>`, `plan:<slug>#<phase>`,
`candidate:<slug>`, `candidate:<slug>#<milestone>`, or
`external:<stable-id>`. Use `blocked_by` and `gated_by` for hard readiness
edges, `coordinates_with` for shared surfaces that must not run concurrently,
and `feeds` for informational direction.

## The roadmap — current plans by theme

Plans marked **active** are current execution frontiers. Other current plans
show their exact **gated**, **paused**, or **planned** state and are not eligible
until their named authority, evidence, or activation condition is satisfied.

### Training trust (`training-trust`)

Make every workout and plan mutation authorized, validated, durable, and
recoverable before adding product depth.

- [Reversible plan management](reversible-plan-management/plan.md) —
  **planned**; make coach and manual plan changes inspectable and reversible.

### Coaching (`coaching`)

Close the feedback loop between what an athlete experiences and what the coach
can understand and safely change.

- [Coaching feedback loop](coaching-feedback-loop/plan.md) — **planned**;
  capture useful session feedback and show the resulting coaching rationale.

### Gym floor (`gym-floor`)

Let a person create and execute a workout confidently, whether or not they use
AI coaching.

- [Gym runner depth](gym-runner-depth/plan.md) — **planned**; improve the
  in-workout reference, correction, loading, timer, and completion experience.
- [Member activation and adherence](member-activation-and-adherence/plan.md) —
  **planned**; make onboarding, coach connection, invite continuation, and
  lightweight reminders coherent.
- [Workout library](workout-library/plan.md) — **planned**; present
  reusable workouts as the primary object, let a member drop one onto any
  date, add tags and archive, and support a freestyle session that can be
  saved as a workout. The weekly routine becomes one optional use of the
  library.
- [Workouts and multi-session days](workouts-and-multi-session/plan.md) —
  **planned**; rename `day_templates` to `workouts` end to end with a
  compatibility window, then allow an ordered list of sessions per date so a
  member can record two strength workouts in one day without changing any
  single-session guarantee.
- [Supersets and circuits](supersets-and-circuits/plan.md) — **planned**;
  let adjacent slots form a group the runner performs in rotation with rest
  only after the round, authored by the member or Claude, without changing
  how sets log or roll up.
- [Bodyweight training support](bodyweight-training-support/plan.md) —
  **planned**; make holds, rep ranges, added load, assistance, and rep-based
  history first-class for calisthenics and bodyweight-first members, and seed
  the missing gymnastic-strength movements.

### Connected training (`connected-training`)

Keep imported activity and private-group behavior correct before adding more
integration or social breadth.

- [Activity integration integrity](activity-integration-integrity/plan.md) —
  **planned**; reconcile source identity, civil dates, connection state,
  corrections, and deletions.
- [Group experience and governance](group-experience-and-governance/plan.md) —
  **planned**; deliver a correct feed, durable invites, lightweight reactions
  and notifications, and essential group controls.

### Platform (`platform`)

Keep the shared backend cheap, fast, and correct as membership grows, without
changing the product data model.

- [Data storage scalability](data-storage-scalability/plan.md) —
  **active**; make sync incremental, make the intervals reconcile write only
  on change, add member-first indexes, and make the cron resilient before
  member count turns the free-tier caps into outages.

## Adding a workstream

Create a plan only when a multi-step workstream has a real owner, observable
completion evidence, and a safe next action. Keep unselected ideas in their
existing design or issue system rather than seeding dormant plans that will
rot. After creating or changing a plan or initiative, run the shared
`planning-conventions` compiler's `check` command from the repository root.

Cross-plan missions live in [`docs/initiatives`](../initiatives/README.md).
An initiative selects and orders canonical plan nodes; it never copies their
status or phase checkboxes.

The following remain candidates or design references, not current plans:

- **Apple Watch app** — promote only when wrist-native execution has a concrete
  outcome beyond the current iPhone runner and Live Activity.
- **Custom exercises** — promote when catalog gaps create observed workout
  failures that aliases or the existing catalog cannot solve. The
  gymnastic-strength seed in `bodyweight-training-support#P0` is the first
  answer to catalog gaps; promote only for movements a seed cannot anticipate.
- **Bodyweight tracking** — promote with a specific coaching or progression
  decision that needs the data, not as an isolated metric store. The one
  identified need is true tonnage for weighted or assisted bodyweight work;
  the rep-based metrics in `bodyweight-training-support#P1` cover the coaching
  decision without it, so it stays deferred.
- **M5 endurance write bridge** — retain the conditional design in
  [`MULTISPORT.md`](../MULTISPORT.md) and its
  [M0 spike](../MULTISPORT-M0-spike.md); do not activate planned-endurance
  writes until the existing provider and product-value gates are satisfied.
