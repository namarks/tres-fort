# Member Activation and Adherence

Slug: member-activation-and-adherence · Status: planned · Updated: 2026-08-28 · Theme: gym-floor

## Goal

Help a newly signed-in or invited member reach a real first workout and return
for the next one without requiring Claude. Done means entry intent survives
authentication, the no-plan state offers honest manual and coach-assisted
paths, and lightweight schedule-based reminders bring the member back to the
correct workout.

## Phases

- [ ] **P0 — Reach the first workout**
  - Preserve invite and Coach Connect intent through sign-in, then return the
    member to the intended group or setup action instead of a generic home
    screen.
  - Replace the dead-end no-plan state with two first-class choices: build a
    workout manually or connect a coach. Explain what each path does and allow
    either one to be completed later.
  - Verify the invite, manual, and coach-connected paths through focused
    end-to-end walkthroughs from entry to first completed workout; fix concrete
    breaks without adding an activation analytics system.
- [ ] **P1 — Return for the next workout**
  - Offer opt-in local reminders derived from the existing recurring schedule
    and deep-link each reminder to the correct Today workout.
  - Add a compact Today widget using the same projection and refresh it after
    schedule, skip, completion, or sign-out changes.
  - Keep notification timing and copy editable in app settings; do not require
    a new server notification system for the initial adherence loop.
- [ ] **P2 — Recommend the starter path from evidence**
  - Use direct member feedback and observed walkthroughs of the manual and
    coach-connected paths to recommend whether a built-in starter plan would
    materially improve activation; gathering this evidence requires no starter
    policy decision.
  - Tune reminders and onboarding copy from concrete member feedback rather
    than add a generalized analytics, growth, or messaging platform.
  - [ ] **(a) Implement the decided starter path**
    - After the product decision, either seed an approved starter through
      `manual-workout-authoring` and the same versioned plan tree, or record the
      decision not to offer one and retain the manual and coach choices.

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P0 | coordinates_with | plan:manual-workout-authoring#P0 | The no-plan surface links to the manual builder, while invite and Coach Connect continuity can proceed independently. |
| P2(a) | gated_by | external:starter-plan-policy | Implementing or explicitly declining the starter path requires the product decision; evidence and recommendation do not. |

## Next step

**Now (@owner):** Activate P0 when the member entry path should enter the
backlog. P2 evidence and recommendation remain ungated; only P2(a) waits on the
starter-plan product decision.

## Notes / open questions

- P0 does not require a user to choose between AI and manual control forever.
  Both paths converge on the same active plan and can be used later.
- The initial adherence loop is local and schedule-driven. Social campaigns,
  generalized push automation, and predictive churn scoring are out of scope.
