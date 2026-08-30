# Training Data Trust

Slug: training-data-trust · Status: active · Updated: 2026-08-30

## Objective

Make training and plan mutations trustworthy at the points where the deep
functionality review found real loss or corruption: server writes stay scoped
and deterministic, gym-floor intents survive interruption, authentication does
not erase local data, and plan changes can be inspected and restored.

## Scope

- plan:identity-account-lifecycle
- plan:workout-write-reliability
- plan:reversible-plan-management

## Priority policy

1. Run the P0 slices of the remaining active plans in parallel when their files and
   migration surfaces do not overlap; serialize only real collisions.
2. Fix the confirmed data-loss, cross-user, invalid-write, and destructive-auth
   paths before adjacent cleanup. Each slice carries its own focused regression
   proof instead of waiting for a portfolio-wide audit.
3. Activate reversible-plan-management after the active P0 risk is controlled;
   do not hold smaller trust fixes for a generalized undo system.

## Completion condition

Server mutation integrity is complete. The three current member plans reach
their stated outcomes: Apple-backed account deletion revokes provider
authorization, offline workout intents recover without duplication, and AI or
manual plan edits share a readable snapshot-and-revert history.

## Stop rules

- Stop before any TestFlight/App Store release, production migration, or deletion
  of a real account without the authority specific to that action.
- Do not expand a verified finding into a blanket security audit, generic sync
  platform, event-sourced plan model, or unrelated product cleanup.
- Stop when no selected node is ready or canonical state has drifted.
