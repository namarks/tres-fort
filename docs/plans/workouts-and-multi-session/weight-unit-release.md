# Per-set weight unit release

Repository delivery does not authorize a production migration or Worker release.

Migration `0055_set_weight_unit.sql` adds `set_logs.weight_unit` (`lb` | `kg`,
default `lb`). `POST /api/sessions/:id/sets` stores the unit the client sends
(iOS sends it with every set) and omitted units read `lb`. Coach context,
metric cohorts and workout-summary previous bests compare loads per unit.

## Production reconciliation

The production Worker is ahead of this repository: its sets already carry
`weight_unit`, its slots carry `target_weight_unit`, and its MCP `log_set`,
`correct_set`, `add_exercise` and `update_exercise` accept units. Those columns
came from migrations this repository does not contain.

1. Under release authority, read the ledger and physical schema:
   `npx wrangler d1 migrations list tres-fort-db --remote` and
   `PRAGMA table_info(set_logs)`.
2. Do not apply 0055 to a database that already has `weight_unit`: the ALTER
   fails with "duplicate column name". If the existing column is `TEXT NOT NULL`
   defaulting to `lb` and holds only `lb`/`kg`, reconcile the ledger entry under
   a separately reviewed step. If it differs, stop for a reviewed plan.
3. Do not deploy this repository's Worker to production until the repository
   also carries production's slot units and MCP unit arguments; deploying it
   now would remove them.

## Other databases

Apply 0055 before a Worker that writes `weight_unit` serves traffic, because the
set insert names the column. Existing rows read `lb`, which is how they were
logged. The migration rewrites no rows, so `set_logs` write-fence triggers do not
fire.

## Recovery

The change is additive. Once `kg` rows exist, keep a Worker that reads the
unit and fix forward; do not drop the column as routine rollback.
