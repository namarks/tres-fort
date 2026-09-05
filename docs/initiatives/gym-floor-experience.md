# Gym-Floor Experience

Slug: gym-floor-experience · Status: planned · Updated: 2026-09-05

## Objective

Let a member get from sign-in to a well-executed workout with or without AI,
whether they train with a barbell or their own body: reach the manual routine
builder that now exists, run the routine efficiently in the gym, and return for
the next scheduled session.

## Scope

- plan:bodyweight-training-support
- plan:member-activation-and-adherence
- plan:gym-runner-depth
- plan:workout-library#P0

## Priority policy

1. Treat completed manual authoring as the shared foundation; prioritize the
   remaining entry, bodyweight-progression, runner, and adherence gaps by their
   own plan frontiers.
2. Entry-path fixes and runner improvements may proceed in parallel when they
   do not overlap the same iOS surface; member-plan dependencies remain
   authoritative.
3. Treat reminder, plate-math, warm-up, and progress features as bounded slices
   of the existing product, not foundations for new platforms.
4. Keep bodyweight progression and runner changes on the shared routine editor
   and plan tree delivered by manual authoring; do not fork a second editor or
   client-only workout model.

## Completion condition

A new member can preserve invite or coach intent, manually create and schedule
a workout when desired, complete and correct that workout in the runner, and
receive a useful reminder for the next session. A bodyweight-first member gets
the same path: holds and rep ranges are prescribable, added load and assistance
are loggable, and history reports numbers that mean something for zero-load
work. Claude can read and edit the same plan, but no step requires AI.

## Stop rules

- Only the optional starter-plan choice requires a product decision. Do not
  gate manual authoring, ordinary onboarding, or runner improvements on it.
