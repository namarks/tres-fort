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

### Release (`release`)

- [First App Store submission](app-store-submission/plan.md) — **active**;
  prepare a verified 1.0 candidate, privacy requirements and review package for
  a free, US-only release. External release and publication gates remain explicit.

### Coaching (`coaching`)

Close the feedback loop between what an athlete experiences and what the coach
can understand and safely change.

[Completed coaching feedback loop](completed/coaching-feedback-loop/plan.md)
provides private feedback, visible/correctable plan changes and accurate training
context. [Physical iPhone feedback verification](completed/coaching-feedback-loop/device-verification.md)
remains a separately authorized release follow-up.

- [Bring your own AI coach](bring-your-own-ai-coach/plan.md) — **gated**;
  complete real-provider verification and consumer linking. P5 plans contextual
  workout/exercise requests, with delivery chosen after a measured prototype.

### Gym floor (`gym-floor`)

Let a person create and execute a workout confidently, whether or not they use
AI coaching.

- [Member activation and adherence](member-activation-and-adherence/plan.md) —
  **paused**; first-workout entry and starters are delivered. Reminders/widgets,
  compact upcoming sessions and actionable progress empty states remain future
  slices.
- [Workout library](workout-library/plan.md) — **active**; present
  reusable workouts as the primary object, let a member drop one onto any
  date, add tags and archive, and support a freestyle session that can be
  saved as a workout. The weekly routine becomes one optional use of the
  library. P0.5(a)/(b) implement unified exercise guidance/history and shared
  search/filter behavior; both shipped with the recent usability fixes in
  internal TestFlight 1.0 (43). P1 tags/archive is next; preview thumbnails
  remain planned pending activation.
- [Workouts and multi-session days](workouts-and-multi-session/plan.md) —
  **gated**; the `day_templates` to `workouts` rename is live server-side with
  a compatibility window, and every shipped client still writes the legacy
  vocabulary. The canonical-writing client rollout waits on owner authority and
  the deferred canonical-route checks; ordered sessions per date follow.
[Supersets and circuits](completed/supersets-and-circuits/plan.md) are retained
as completed repository history: shared coach/member authoring, alternating
round execution and recovery, separate transition/round rests, and compatible
client-cache refresh are delivered. Backend migration and app/Worker releases
require separate authority.

[Bodyweight training support](completed/bodyweight-training-support/plan.md) is
retained as completed repository history: holds/catalog, signed load,
variation replacement and comparable metrics are delivered. Worker/app release
requires separate owner authority.

[Gym runner depth](completed/gym-runner-depth/plan.md) is retained as completed
repository history: prescription fidelity, durable set corrections, loading
and timing aids, and persisted completion feedback are delivered. Migration,
Worker deployment and iOS distribution require separate owner authority.

### Connected training (`connected-training`)

Keep imported activity and private-group behavior correct before adding more
integration or social breadth.

- [Activity integration integrity](activity-integration-integrity/plan.md) —
  **paused** after P0 and P1 repository delivery: source identity/date integrity
  and immediate connect/reconnect activity sync with recovery actions. P2
  corrections/deletions is the next candidate; rollout remains deferred.
- [Group experience and governance](group-experience-and-governance/plan.md) —
  **planned**; deliver a correct feed, durable invites, lightweight reactions
  and notifications, and essential group controls.

### Member experience (`member-experience`)

Give a member honest, private views of their own body and training trends
without adding provider accounts, server collection or new data stores.

- [Progress and Apple Health weight](apple-health-weight/plan.md) — **gated**;
  the private weight view and Progress tab are merged and included in internal
  TestFlight build 42. Owner verification on a real iPhone with Health readings
  remains.

### Review-driven ordering

The [September app review](../reviews/2026-09-app-review/report.md) recommends
coach-access and prescription integrity, runner prescription fidelity, and
feedback before more authoring depth. Comparable metrics, accessible journeys
and repeatable iOS checks complete that foundation. Library P0 remains a small
independent presentation improvement; storage/wire rename, multiple sessions
and engagement features follow their existing decisions and demonstrated need.
This order does not activate planned work or replace canonical phase readiness.

### SensAI follow-up ordering

The [September 18 hands-on comparison](../reviews/2026-09-sensai/report.md)
selects six improvements within existing plans. Start with library P0.5(a)/(b):
shared exercise technique/history and consistent exercise/swap filtering. Next
consider P0.5(c) preview thumbnails and member-activation P3 upcoming sessions,
then P4 progress empty states. Evaluate BYO-coach P5(a)'s contextual request
prototype separately before choosing P5(b)'s delivery architecture.

The owner subsequently activated library P0.5(a), the shared Technique / History
sheet, ahead of tags/archive, and then P0.5(b) shared search/filter behavior.
P0.5(a)/(b) are merged and shipped in internal TestFlight 1.0 (43), with exact
source and Apple evidence in the release record. The other new slices remain planning
approval only; canonical frontiers and release gates remain authoritative. Already
delivered runner, swap, catalog, starter and progress capabilities are reused.

## Completed foundations

[App quality and maintainability](completed/app-quality-and-maintainability/plan.md)
provides reproducible current-iPhone CI, basic usability improvements, measured
history indexes and lossless large-cache persistence. Repository completion is
separate from production or app distribution.


[Training Data Trust](../initiatives/completed/training-data-trust.md) is
complete after reviewed service/TestFlight delivery and the coordinated live
canary. Its retained [prescription integrity](completed/prescription-integrity/plan.md),
[reversible plan management](completed/reversible-plan-management/plan.md), and
[coach access integrity](completed/coach-access-integrity/plan.md) contracts
support the current plans. The evidence distinguishes deterministic tests,
production activation, observed client paths and bounded legacy assessment.

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
