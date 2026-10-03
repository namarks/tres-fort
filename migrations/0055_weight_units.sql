-- Per-slot and per-set load units. A slot's target_weight is in its
-- target_weight_unit and a set's weight is in its weight_unit; neither ever
-- derives from the catalog exercise unit. Every existing row was authored and
-- logged in lb, which the defaults record without a data-rewriting UPDATE
-- (set_logs write-fence triggers guard updates, and ADD COLUMN fires none).
--
-- Release note: the production database already has both columns from
-- migrations that are not in this repository. Do not apply this file there
-- as-is (ALTER would fail with "duplicate column name"); reconcile it per
-- docs/plans/workouts-and-multi-session/weight-unit-release.md. Elsewhere,
-- apply it before a Worker that reads or writes either column serves traffic.
ALTER TABLE template_exercises ADD COLUMN target_weight_unit TEXT NOT NULL DEFAULT 'lb'
  CHECK (target_weight_unit IN ('lb', 'kg'));
ALTER TABLE set_logs ADD COLUMN weight_unit TEXT NOT NULL DEFAULT 'lb'
  CHECK (weight_unit IN ('lb', 'kg'));
