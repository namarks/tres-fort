# Weight unit release

Repository delivery does not authorize a production migration or Worker release.

Migration `0055_weight_units.sql` adds `template_exercises.target_weight_unit`
and `set_logs.weight_unit` (`lb` | `kg`, `NOT NULL DEFAULT 'lb'`, checked).

- Slots: REST and MCP slot writers (`add_exercise`, `update_exercise`,
  `update_plan`, freestyle save, restore) store the unit. An `update_plan`
  rebuild that omits it keeps the replaced slot's unit; a new slot defaults to
  `lb`. Plan snapshots carry it, and older snapshots read `lb`. Runner target
  snapshots record it, and target comparisons use it.
- Sets: `POST /api/sessions/:id/sets` stores the unit iOS sends, and an omitted
  unit means `lb`. MCP `log_set` without a unit inherits the session workout's
  slot unit (`lb` with no slot). `correct_set` and `PATCH /api/sets/:id` can
  change it.
- Reads: coach context, cohorts, volume trend and group feed keep units
  separate. Workout-summary previous bests match the same physical load across
  units: 24 kg against 53 lb, but not 20 kg against 45 lb.

## Production reconciliation

Production already serves slot and set units, and its MCP `log_set`,
`correct_set`, `add_exercise`, `update_exercise` and `update_plan` accept them.
Its columns came from migrations this repository does not contain. With this
change the repository carries the same contract, so deploying it no longer
removes the feature. Its only additions are the behaviors listed above.

1. Under release authority, read the ledger and the physical schema:
   `npx wrangler d1 migrations list tres-fort-db --remote`,
   `PRAGMA table_info(template_exercises)`, `PRAGMA table_info(set_logs)` and
   both tables' `sql` in `sqlite_master`.
2. Do not apply 0055 to a database that already has either column; the ALTER
   fails with "duplicate column name". If both columns are `TEXT NOT NULL`,
   default to `lb`, and hold only `lb`/`kg`
   (`SELECT DISTINCT target_weight_unit FROM template_exercises`,
   `SELECT DISTINCT weight_unit FROM set_logs`), record 0055 as applied in
   `d1_migrations` under a separately reviewed step. If either differs, stop
   for a reviewed plan.
3. Then deploy the Worker under the separate production authority. Older plan
   and runner snapshots without a unit read `lb`.

## Other databases

Apply 0055 before a Worker that reads or writes either column serves traffic,
because slot and set inserts name them. Existing rows read `lb`, which is how
they were authored and logged. The migration rewrites no rows, so the
`set_logs` write-fence triggers do not fire.

## Recovery

The change is additive. Once `kg` rows exist, keep a Worker that reads the
units and fix forward; do not drop the columns as routine rollback.
