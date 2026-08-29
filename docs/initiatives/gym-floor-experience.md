# Gym-Floor Experience

Slug: gym-floor-experience · Status: planned · Updated: 2026-08-28

## Objective

Let a member get from sign-in to a well-executed workout with or without AI:
create and schedule a routine manually, run it efficiently in the gym, and
return for the next scheduled session.

## Scope

- plan:manual-workout-authoring
- plan:member-activation-and-adherence
- plan:gym-runner-depth

## Priority policy

1. Complete the smallest manual create-to-Today slice before adding date-level
   exceptions, starter-plan variants, or advanced runner aids.
2. Entry-path fixes and runner improvements may proceed in parallel when they
   do not overlap the same iOS surface; member-plan dependencies remain
   authoritative.
3. Treat reminder, plate-math, warm-up, and progress features as bounded slices
   of the existing product, not foundations for new platforms.

## Completion condition

A new member can preserve invite or coach intent, manually create and schedule
a workout when desired, complete and correct that workout in the runner, and
receive a useful reminder for the next session. Claude can read and edit the
same plan, but no step requires AI.

## Stop rules

- Only the optional starter-plan choice requires a product decision. Do not
  gate manual authoring, ordinary onboarding, or runner improvements on it.
