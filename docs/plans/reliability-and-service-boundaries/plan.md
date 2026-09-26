# Reliability and Service Boundaries

Slug: reliability-and-service-boundaries · Status: active · Updated: 2026-09-26 · Theme: platform

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

**Now (@agent):** Complete fresh iOS CI and exact-head review of
[PR #202](https://github.com/namarks/tres-fort/pull/202) after reconciling it with
main at `a7b3f4d`. Preserve main's archive/tags and freestyle behavior, canonical
contract validation, release gate, and recorded migration evidence. Reviewed
versions now take precedence over removed workout/slot lookups on REST and MCP;
regressions cover all four slot edits without durable writes on conflict.

The September 14 head passed backend and native CI (610 unit tests and 12 smoke
journeys). That evidence does not certify this reconciled head. Current local
checks cover the three Workers/D1 shards, typecheck, plan graph, website tests,
and test-command behavior. The default wrapper correctly reports the missing
`sqlite3` prerequisite in this container; CI must supply query-plan, upload, and
native build/unit/UI evidence. The 24 extracted service function bodies retain
main's behavior; one extraction drops an unused destructured field. P1 and P3
remain open until current native CI and review are green.

The scope includes structured slot conflicts and reviewed-version iOS editing,
internal OAuth and Intervals services, pure runner recovery, final-set rest,
certified offline start/resume, reproducible test shards, and value-free
operational measurements. Main already owns the canonical runtime cutover.
Existing immutable snapshot and cache/outbox readers remain data-preservation
code. No production migration, deployment or TestFlight distribution is part of
this repository delivery.
