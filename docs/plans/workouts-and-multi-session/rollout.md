# Workout rename rollout

**Current cutover decision (2026-09-14):** the owner retired the sole installed
legacy client and explicitly authorized removing its runtime support. The prior
minimum-build/adoption-cycle gate no longer applies. Canonical requests work
against the already-serving adaptive Worker, so install the reviewed canonical
iOS build before deploying the canonical-only Worker. Both release actions need
separate release authority; repository changes do not execute either one.

The canonical-only Worker requires the already-applied migration 0045. Do not
reapply it. It has no SQL adapter, old workout routes/tools, or duplicate fields.
Keep immutable snapshot and durable cache/outbox readers. Refresh the connected
MCP client's tool list after cutover. Roll back application behavior to the
recorded adaptive Worker if separately authorized; never run the schema rollback
beneath a canonical-only Worker. See [the release record](plan.md#next-step).

The remainder records the historical A/B procedure for reproducibility. Commands
for retired bridge scripts refer to the old release source and are not part of
the current checkout. They are not pending steps.

This runbook describes P0's three-stage procedure; it is not the current
execution frontier. **The 2026-09-09 release has already deployed A and applied
B. Do not repeat either stage.** Read the [canonical release record and next
step](plan.md#next-step) before running any command below; it holds the exact
source, deployment/version IDs, migration result and approved verification
exception. The A/B commands are retained for historical reproducibility and
must not be treated as pending work.

Repository approval authorizes code, local verification, review and merge.
It does **not** itself authorize further production changes, rollback, or
TestFlight distribution. Record separately authorized release evidence and
the supported-client compatibility cycle in `plan.md`.

## Local rehearsal

```sh
npm ci
npm run typecheck
npm test
npm run ios:verify -- --runtime com.apple.CoreSimulator.SimRuntime.iOS-26-2 --device com.apple.CoreSimulator.SimDeviceType.iPhone-17
```

`test:workout-rollout` creates a temporary config/database with synthetic local
credentials, applies migrations through 0044, starts a local Worker, creates a
workout through the released route, applies 0045 with that Worker still running,
edits through the new route, runs the down-migration, and edits through the old
route. The identity survives and each successful edit advances the plan version
once. It shuts down its Worker and removes its temporary database on exit.
`test/workout_schema.test.ts` additionally covers foreign keys, retained set and
session-alias references, the attempt trigger, atomic-batch rollback, cache
expiry, and non-retryable failures. `test/workout_wire.test.ts` exercises both
client vocabularies against both schemas; snapshot tests restore immutable v1
history without rewriting its bytes.

## A — deploy the adaptive Worker before renaming storage

Executed for the 2026-09-09 release; see the canonical record above. Its live
REST authoring checks were deferred under the owner's explicit exception.
The following is the historical deployment procedure, not an instruction to
redeploy the already serving Worker.

After release authorization, work from the exact reviewed and verified source.
Inspect current deployment and pending migrations first:

```sh
npx wrangler deployments list
npx wrangler d1 migrations list tres-fort-db --remote
npx wrangler d1 execute tres-fort-db --remote --command 'PRAGMA table_info(sessions)'
```

The existing database must already contain migrations through 0044. If earlier
migrations are pending, stop and resolve their separate release requirements;
this runbook is not permission to apply them. Save the current deployment ID.
Run the preflight and then deploy **without applying 0045**:

```sh
npm run release:preflight
npm run deploy
npx wrangler deployments list
```

Prove the approved source is serving all traffic; no older non-adaptive version
may retain a traffic allocation. Using the owner's existing authenticated
clients, confirm active-plan/state reads, legacy `/api/days` authoring and new
`/api/workouts` authoring on an owner-approved disposable workout, plus both MCP
names. Do not print bearer tokens, copy credentials or use real history as test
data. Save value-free results. A deployment acknowledgement alone is insufficient
proof of the serving version or client behavior.

The first iOS build in this branch reads either vocabulary but deliberately
sends `/api/days` and `day_template_id`. Its Workouts UI can be distributed after
separate TestFlight authorization while the legacy wire contract remains live.

## B — rename the database under the adaptive Worker

Applied for the 2026-09-09 release; see the canonical record above. Live REST
authoring, date assignment and set/finish/discard checks were deferred to the
client rollout under the owner's explicit exception. Do not reapply 0045.

Only after A is verified, the production migration is separately authorized,
and the pending migration list contains **only 0045**, record a D1 Time Travel
bookmark using `npx wrangler d1 time-travel info tres-fort-db --json` in a private
release receipt. Then apply the rename directly:

```sh
npx wrangler d1 migrations apply tres-fort-db --remote
npx wrangler d1 execute tres-fort-db --remote --command 'PRAGMA table_info(sessions); PRAGMA foreign_key_check; SELECT name FROM sqlite_master WHERE name IN ("workouts","day_templates","ix_te_workout","ix_te_day")'
```

Expect `workout_id`, the `workouts` table and `ix_te_workout`, no old table/index,
and no foreign-key violations. Verify reads, new/legacy authoring, schedule
membership, a one-date assignment, and set/finish/discard attempt behavior through
approved client checks. Existing workout/slot/session IDs and all logged values
must remain intact. No schedule or plan version changes come from the migration.
The same adaptive Worker remains the supported rollback target.

After the dual-key Worker is proven live, prepare a **later** app build changing
`APIClient.workoutWireFormat`'s default from `.legacy` to `.canonical`, with the
request and UI suites rerun. That reviewed change and its TestFlight distribution
need their own recorded evidence. Never switch an app's outgoing shape merely
because its decoder accepts new fields.

For the deferred client-rollout verification, complete legacy-route checks on
an owner-approved disposable workout before distributing the first compatible
TestFlight build. Complete canonical-route checks before distributing the later
canonical-writing build. During each canary and for five minutes afterward,
observe request success/failure using value-free results; record the window and
findings in `plan.md`. A reproducible write failure, unhandled missing-table or
missing-column error, or foreign-key violation stops client distribution.
Keep the adaptive Worker serving while diagnosing; any production rollback
still requires the authority and procedure below. Do not infer a continuously
observed production cutover from local test coverage or point-in-time reads.

## C — canonical-only repository delivery

The owner's 2026-09-14 single-installation decision supersedes the earlier
observed-client-cycle requirement. Remove `workoutSchema.ts`, the temporary
release guard/rehearsal, deprecated wire aliases and old MCP registrations.
Normal release commands are restored for future separately authorized releases.
Tests cover canonical authoring, rejection of retired identity fields, preserved
migration references, immutable v1 snapshot restore, and durable iOS recovery.
Existing audit names and persisted-data decoders are retained. Deployment and
app-distribution evidence belongs in `plan.md`, not inferred from test results.

## Rollback

Before B, retain the adaptive Worker when rolling back application behavior:
it writes snapshot schema v2, which a pre-A Worker cannot restore. After B,
rolling back to a pre-A Worker also breaks all old physical SQL references.
Choose an approved adaptive source; do not select an arbitrary previous version.

If the schema rename itself must be reverted, obtain explicit production rollback
authority and keep the adaptive Worker serving while running:

```sh
npx wrangler d1 execute tres-fort-db --remote --file docs/plans/workouts-and-multi-session/rollback/0045_workouts.sql
npx wrangler d1 execute tres-fort-db --remote --command 'PRAGMA table_info(sessions); PRAGMA foreign_key_check'
```

The down-migration restores identifiers and the index, leaving identities,
versions, snapshots and history unchanged. Verify both client vocabularies again.
It deliberately does not edit `d1_migrations`; 0045 remains recorded as applied.
For a later reattempt, verify the legacy physical schema and apply the reviewed
forward SQL explicitly with `wrangler d1 execute ... --file
migrations/0045_workouts.sql` under separate authority, or add a reviewed recovery
migration. Do not blindly delete the migration ledger row or rerun the entire
migration history. A Time Travel restore can discard intervening writes and is
an independent destructive decision, not the routine rename rollback.

## Compatibility boundaries

- Service types, SQL and new snapshots use `workouts` / `workout_id`.
- The SQL adapter rewrites identifiers only, caches schema metadata for 60 seconds,
  and retries only a failed statement or failed atomic batch once after a proven
  schema change. It never retries network uncertainty or a whole service write.
- REST/MCP add deprecated aliases at the serialization boundary. Export schema v2
  also retains its historical `training.day_templates` collection. Opaque user
  text, metadata, audit arguments and snapshot documents are unchanged.
- Plan and session caches continue encoding the old vocabulary; durable set and
  terminal intents retain their original `dayTemplateID` key and attempt tokens.
- `template_exercises`, `template_exercise_id`, legacy error codes, `day_label`,
  and historical comparison kind/summary fields remain compatible. A civil
  calendar day and a reusable workout remain separate concepts.
- The schedule is still a weekday-to-workout-ID map. Unschedule clears only that
  workout's recurring entries; dated sessions and the workout remain. Delete
  uses the existing atomic deletion/history rules. Date assignment uses the
  existing attempt-CAS path and rejects past, active/completed and hard-blackout
  dates in the app. There is still one strength session per civil date.

The ordinary `npm run release` and `npm run db:migrate:remote` fail locally during
this window and point here. Their replacement is this explicit, authorized
sequence; neither command performs a remote operation while guarded.
