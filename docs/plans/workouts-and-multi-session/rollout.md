# Canonical workout contract release

Read [the canonical plan](plan.md) for status and authorization. The owner
retired legacy-client support on 2026-09-19. No observed compatibility cycle,
minimum legacy build or old-route canary is a prerequisite for repository cleanup.
Production deployment, migration and TestFlight distribution still require
separate authority. Repository merge is not release evidence.

## Runtime requirement

The current Worker issues SQL against `workouts` and `workout_id` directly.
Migration 0045 must already be applied; it cannot run against the old physical
schema. REST uses `/api/workouts`, responses use `workouts` / `workout_id`, and
MCP uses `add_workout`, `update_workout` and `delete_workout`. Retired routes and
tool names are absent; retired request fields fail before mutation. iOS sends
only canonical paths and fields.

A/B (adaptive Worker then migration 0045) completed on 2026-09-09. Their exact
historical evidence and verification exceptions are retained in `plan.md`.
Do not repeat those stages. The old same-Worker rename/rollback harness depended
on the removed SQL adapter. `npm run test:workout-rollout` now exercises the
actual migration with existing history and the canonical REST/MCP contract.
The prior harness remains reproducible from its reviewed historical source.

## Local verification

```sh
npm ci
npm run typecheck
npm run plans:check
npm test
npm run test:workout-rollout
npm run ios:verify -- --runtime com.apple.CoreSimulator.SimRuntime.iOS-26-2 --device com.apple.CoreSimulator.SimDeviceType.iPhone-17
```

Migration tests retain workout/slot/session/set identities and values, session
aliases, historical audit arguments, foreign-key integrity, version counts,
attempt triggers and D1 batch rollback. Contract tests cover canonical authoring,
date assignment/move, export, and rejection of retired inputs without mutation.
Snapshot tests restore immutable v1 documents without rewriting their bytes.
iOS tests cover canonical requests plus reading old caches and queued intents.

## Authorized release

Work from the exact reviewed and verified source. Inspect the current deployment,
pending migrations and physical schema under the release's authority:

```sh
npx wrangler deployments list
npx wrangler d1 migrations list tres-fort-db --remote
npx wrangler d1 execute tres-fort-db --remote --command 'PRAGMA table_info(sessions); PRAGMA table_info(template_exercises); PRAGMA foreign_key_check; SELECT name FROM sqlite_master WHERE name IN ("workouts","day_templates","ix_te_workout","ix_te_day")'
```

Require both `workout_id` columns, `workouts`, `ix_te_workout`, no old table/index
and no foreign-key violations. A ledger entry alone does not prove the physical
schema: the historical down-migration did not edit `d1_migrations`. If the old
schema is present, stop; recovery needs a separately reviewed migration plan.

Account for every pending migration and release gate at the chosen source,
including [workout metadata](../workout-library/metadata-release.md) and
[freestyle sessions](../workout-library/freestyle-release.md). This rename cleanup
adds no migration and does not authorize those feature releases. The generic
`npm run release` and `npm run db:migrate:remote` remain fail-closed and point to
these procedures. Use each approved feature runbook's ordered steps; do not
infer permission to apply the entire pending migration set.

After the reviewed source's migration requirements are satisfied, run its
release preflight and separately authorized Worker deployment. Record serving
version/source and traffic allocation. Verify canonical plan/state reads,
workout create/edit/delete, date assignment and set/finish/discard behavior on
owner-approved disposable data using existing authenticated clients. Do not
print bearer tokens or copy secrets. During the canary and for five minutes
afterward, record value-free request success/failure. A reproducible write error,
missing-table/column error or foreign-key violation stops distribution.

Distribute the canonical-writing iOS build only after the serving backend
supports its full feature contract. Record its exact source, build, Apple
processing status and intended tester assignment separately. Older clients are
unsupported; no legacy-client observation period is required. The prior build35
canary waiver remains historical and does not claim these new checks passed.

## Data and rollback boundaries

Historical `audit_log.tool` values, serialized audit arguments and immutable v1
plan snapshots are retained. New exports use schema v3 with one
`training.workouts` collection. New plan/session caches encode canonical names;
old caches remain readable. Durable set/terminal intent keys and attempt tokens
keep their persisted contract so queued history is not discarded.

Keep migration 0045 applied when rolling back application behavior. Select a
reviewed Worker compatible with every currently applied migration, snapshot
schema and session kind. Do not select an arbitrary old adaptive build merely
because it supports the rename. Production rollback itself requires authority.

`rollback/0045_workouts.sql` is retained as historical recovery material, **not
a supported rollback with the current Worker**. Never run it while this Worker
serves traffic. Reverting the physical schema would require a separately reviewed
recovery plan and a compatible adaptive Worker first. A D1 Time Travel restore
can discard intervening writes and is an independent destructive decision.
