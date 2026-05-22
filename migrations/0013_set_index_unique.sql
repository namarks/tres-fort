-- #7 — make duplicate set_index inside one session impossible.
--
-- MCP and iOS each computed set_index independently, so the same logical
-- slot could be written twice (e.g. two set_index=3 squat sets, one mcp +
-- one ios, in session d71a2136). That inflates set counts and breaks
-- top-set / volume math.
--
-- Step 1: densely renumber LIVE sets to 1..n within each
-- (session_id, exercise_id, is_warmup) group, ordered by their current
-- set_index then logged_at. This both removes existing collisions and
-- normalizes indices without dropping any row. Soft-deleted rows are left
-- as-is (they're excluded from the index below).
WITH renum AS (
  SELECT id,
         ROW_NUMBER() OVER (
           PARTITION BY session_id, exercise_id, is_warmup
           ORDER BY set_index, logged_at, id
         ) AS new_idx
  FROM set_logs
  WHERE deleted_at IS NULL
)
UPDATE set_logs
SET set_index = (SELECT new_idx FROM renum WHERE renum.id = set_logs.id)
WHERE id IN (SELECT id FROM renum);

-- Step 2: enforce uniqueness going forward. Partial (WHERE deleted_at IS
-- NULL) so soft-deleted rows never block a future real set at the same
-- slot. is_warmup is in the key because a warmup and a working set legitimately
-- share set_index 1 for the same exercise.
CREATE UNIQUE INDEX ux_set_slot
  ON set_logs(session_id, exercise_id, set_index, is_warmup)
  WHERE deleted_at IS NULL;
