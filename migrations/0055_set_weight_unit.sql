-- Per-set load unit. A set's weight is in this unit; clients send it with
-- every logged set (iOS since #223) and it never derives from the catalog
-- exercise unit. Every existing row was logged in lb, which the default
-- records without a data-rewriting UPDATE (set_logs write-fence triggers
-- guard updates, and ADD COLUMN fires none).
--
-- Release note: the production database already has set_logs.weight_unit
-- from a migration that is not in this repository. Do not apply this file
-- there as-is (ALTER would fail with "duplicate column name"); reconcile it
-- per the release procedure instead. Elsewhere, apply it before a Worker that
-- writes weight_unit serves traffic.
ALTER TABLE set_logs ADD COLUMN weight_unit TEXT NOT NULL DEFAULT 'lb'
  CHECK (weight_unit IN ('lb', 'kg'));
