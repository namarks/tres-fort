# Reliability and Service Boundaries

Slug: reliability-and-service-boundaries · Status: active · Updated: 2026-09-14 · Theme: platform

## Goal

Deliver the owner's requested follow-up to PR #201: consistent workout edits,
clear service and recovery ownership, dependable local checks, operational
performance evidence, and a safe path out of temporary workout compatibility.

## Phases

- [x] **P0 — Consistent workout edits and verification**
  - Return actionable conflicts from add, patch, swap and delete; preserve
    successful wire shapes, legacy bounded retries and atomic attribution.
  - Make the default test entry point run the supported backend shards and
    report missing prerequisites before expensive work.
- [ ] **P1 — Cohesive service and recovery boundaries**
  - Extract backend OAuth grant lifecycle and provider reconciliation behind
    the public service facade, preserving ownership and transaction semantics.
  - Extract pure runner recovery decisions and account-bound artifact ownership;
    test relaunch, delayed acknowledgements and remote terminal precedence.
  - End final-set rest; support bounded offline workout recovery/start with
    durable intent, exact attempt checks and visible conflict recovery.
- [x] **P2 — Measurement and canonical cutover**
  - Extend value-free operational measurements to coaching reads and workout
    writes; preserve existing query budgets and iOS performance probes.
  - Use canonical iOS requests and remove runtime legacy routes, tools, output
    aliases and SQL adaptation; retain readers required by existing stored data.
- [ ] **P3 — Verify and publish the complete change**
  - Run local backend shards, typechecking, plan validation and synthetic probes;
    obtain iOS build/unit/UI evidence from the repository CI.
  - Publish a reviewable PR, complete review, and record deployment/app-distribution follow-ups.

## Execution frontier

- P3

## Dependencies

No external compatibility-cycle gate remains. On 2026-09-14 the owner stated
that the old client has only one installation (their own) and explicitly directed
its support to be removed. The already-recorded migration 0045 satisfies the
physical schema prerequisite; release and app distribution remain separate work.

## Next step

**Now (@agent):** Complete iOS CI and review of [PR #202](https://github.com/namarks/tres-fort/pull/202).
All 1,098 backend tests across 81 files pass locally in the three supported
shards. Typecheck, plan graph and 25 Python verification-command checks pass
locally; the Ruby submission checks pass in CI. The 24
extracted service function bodies match their predecessors after removing the
SQL adapter and formatting differences. P1 awaits iOS build/unit/UI evidence;
P3 remains open for final review and merge. Release is separate.

The first iOS run built successfully and exercised 608 unit tests plus 12 smoke
journeys. It exposed premature offline consumption of deferred group repairs;
those receipts, pending corrections and terminal intents now retain live
validation. The remaining final-rest expectations were updated. The final CI
run must verify these corrections and the added attempt/date/UUID regressions.

The scope includes canonical routes/tools/fields, native D1 without SQL adapters,
structured slot conflicts and reviewed-version iOS editing, internal OAuth and
Intervals services, pure runner recovery, final-set rest, certified offline
start/resume, reproducible test shards, and value-free operational measurements.
Existing immutable snapshot and cache/outbox readers remain data-preservation
code. No production migration, deployment or TestFlight distribution is part of
this repository delivery.
