-- A user can have only one session for a device-local calendar date.
--
-- Older clients could race through the read-then-insert session path and leave
-- more than one row for (user_id, date). Reconcile those rows before installing
-- the invariant. The canonical session is the row current lookup already
-- returns: earliest created_at, with id as the stable tie-breaker.

-- Moving sets can temporarily collide with the existing live-slot invariant.
-- Rebuild that index after the affected groups have been combined and densely
-- renumbered.
DROP INDEX IF EXISTS ux_set_slot;

-- Move every live set from duplicate session groups to the canonical session.
-- Only a target (session, exercise, warmup) group that actually receives a set
-- is renumbered; unaffected groups retain their existing set_index values.
WITH session_map AS (
  SELECT
    id AS source_session_id,
    FIRST_VALUE(id) OVER (
      PARTITION BY user_id, date
      ORDER BY created_at, id
    ) AS target_session_id,
    COUNT(*) OVER (PARTITION BY user_id, date) AS session_count
  FROM sessions
),
mapped_live_sets AS (
  SELECT
    sl.id,
    sm.target_session_id,
    ROW_NUMBER() OVER (
      PARTITION BY sm.target_session_id, sl.exercise_id, sl.is_warmup
      ORDER BY sl.set_index, sl.logged_at, sl.id
    ) AS new_set_index,
    MAX(
      CASE WHEN sl.session_id <> sm.target_session_id THEN 1 ELSE 0 END
    ) OVER (
      PARTITION BY sm.target_session_id, sl.exercise_id, sl.is_warmup
    ) AS group_receives_set
  FROM set_logs AS sl
  JOIN session_map AS sm ON sm.source_session_id = sl.session_id
  WHERE sl.deleted_at IS NULL
    AND sm.session_count > 1
)
UPDATE set_logs
SET
  session_id = (
    SELECT target_session_id
    FROM mapped_live_sets
    WHERE mapped_live_sets.id = set_logs.id
  ),
  set_index = (
    SELECT new_set_index
    FROM mapped_live_sets
    WHERE mapped_live_sets.id = set_logs.id
  )
WHERE id IN (
  SELECT id
  FROM mapped_live_sets
  WHERE group_receives_set = 1
);

-- Soft-deleted sets are historical rows. Preserve and reparent them, but leave
-- their set_index untouched because the live-slot index intentionally excludes
-- them.
WITH session_map AS (
  SELECT
    id AS source_session_id,
    FIRST_VALUE(id) OVER (
      PARTITION BY user_id, date
      ORDER BY created_at, id
    ) AS target_session_id,
    COUNT(*) OVER (PARTITION BY user_id, date) AS session_count
  FROM sessions
)
UPDATE set_logs
SET session_id = (
  SELECT target_session_id
  FROM session_map
  WHERE session_map.source_session_id = set_logs.session_id
)
WHERE deleted_at IS NOT NULL
  AND session_id IN (
    SELECT source_session_id
    FROM session_map
    WHERE session_count > 1
      AND source_session_id <> target_session_id
  );

-- session_load_exports is keyed by session_id, so a duplicate group may have
-- several ledgers but its canonical session can retain only one. Rank every
-- ledger regardless of which session currently owns it: a usable intervals
-- reference first, then status=ok, newest update, stable id. If the canonical
-- row is present but worse, copy the best payload onto it before deleting the
-- redundant rows. This prevents an unusable canonical ledger from shadowing a
-- usable loser ledger.
WITH session_map AS (
  SELECT
    id AS source_session_id,
    FIRST_VALUE(id) OVER (
      PARTITION BY user_id, date
      ORDER BY created_at, id
    ) AS target_session_id,
    COUNT(*) OVER (PARTITION BY user_id, date) AS session_count
  FROM sessions
),
ranked_exports AS (
  SELECT
    sle.session_id AS source_session_id,
    sm.target_session_id,
    sle.intervals_ref,
    sle.load,
    sle.status,
    sle.attempts,
    sle.updated_at,
    ROW_NUMBER() OVER (
      PARTITION BY sm.target_session_id
      ORDER BY
        CASE WHEN sle.intervals_ref IS NOT NULL THEN 1 ELSE 0 END DESC,
        CASE WHEN sle.status = 'ok' THEN 1 ELSE 0 END DESC,
        sle.updated_at DESC,
        sle.session_id
    ) AS preference_rank
  FROM session_load_exports AS sle
  JOIN session_map AS sm ON sm.source_session_id = sle.session_id
  WHERE sm.session_count > 1
)
UPDATE session_load_exports
SET
  intervals_ref = (
    SELECT intervals_ref
    FROM ranked_exports
    WHERE ranked_exports.target_session_id = session_load_exports.session_id
      AND preference_rank = 1
  ),
  load = (
    SELECT load
    FROM ranked_exports
    WHERE ranked_exports.target_session_id = session_load_exports.session_id
      AND preference_rank = 1
  ),
  status = (
    SELECT status
    FROM ranked_exports
    WHERE ranked_exports.target_session_id = session_load_exports.session_id
      AND preference_rank = 1
  ),
  attempts = (
    SELECT attempts
    FROM ranked_exports
    WHERE ranked_exports.target_session_id = session_load_exports.session_id
      AND preference_rank = 1
  ),
  updated_at = (
    SELECT updated_at
    FROM ranked_exports
    WHERE ranked_exports.target_session_id = session_load_exports.session_id
      AND preference_rank = 1
  )
WHERE session_id IN (
  SELECT target_session_id
  FROM ranked_exports
  WHERE preference_rank = 1
    AND source_session_id <> target_session_id
);

-- If the canonical session had no ledger at all, move the ranked winner onto
-- it. Groups handled by the copy above now have a canonical row and are skipped.
WITH session_map AS (
  SELECT
    id AS source_session_id,
    FIRST_VALUE(id) OVER (
      PARTITION BY user_id, date
      ORDER BY created_at, id
    ) AS target_session_id,
    COUNT(*) OVER (PARTITION BY user_id, date) AS session_count
  FROM sessions
),
ranked_exports AS (
  SELECT
    sle.session_id AS source_session_id,
    sm.target_session_id,
    ROW_NUMBER() OVER (
      PARTITION BY sm.target_session_id
      ORDER BY
        CASE WHEN sle.intervals_ref IS NOT NULL THEN 1 ELSE 0 END DESC,
        CASE WHEN sle.status = 'ok' THEN 1 ELSE 0 END DESC,
        sle.updated_at DESC,
        sle.session_id
    ) AS preference_rank
  FROM session_load_exports AS sle
  JOIN session_map AS sm ON sm.source_session_id = sle.session_id
  WHERE sm.session_count > 1
)
UPDATE session_load_exports
SET session_id = (
  SELECT target_session_id
  FROM ranked_exports
  WHERE ranked_exports.source_session_id = session_load_exports.session_id
)
WHERE session_id IN (
  SELECT source_session_id
  FROM ranked_exports
  WHERE preference_rank = 1
    AND source_session_id <> target_session_id
    AND NOT EXISTS (
      SELECT 1
      FROM session_load_exports AS canonical_export
      WHERE canonical_export.session_id = ranked_exports.target_session_id
    )
);

-- Remove every remaining loser ledger. The row moved above now has the target
-- session_id and is therefore not selected here.
WITH session_map AS (
  SELECT
    id AS source_session_id,
    FIRST_VALUE(id) OVER (
      PARTITION BY user_id, date
      ORDER BY created_at, id
    ) AS target_session_id,
    COUNT(*) OVER (PARTITION BY user_id, date) AS session_count
  FROM sessions
)
DELETE FROM session_load_exports
WHERE session_id IN (
  SELECT source_session_id
  FROM session_map
  WHERE session_count > 1
    AND source_session_id <> target_session_id
);

-- Dependencies are now attached to the canonical row, so the empty duplicate
-- session shells can be removed safely.
WITH session_map AS (
  SELECT
    id AS source_session_id,
    FIRST_VALUE(id) OVER (
      PARTITION BY user_id, date
      ORDER BY created_at, id
    ) AS target_session_id,
    COUNT(*) OVER (PARTITION BY user_id, date) AS session_count
  FROM sessions
)
DELETE FROM sessions
WHERE id IN (
  SELECT source_session_id
  FROM session_map
  WHERE session_count > 1
    AND source_session_id <> target_session_id
);

CREATE UNIQUE INDEX ux_set_slot
  ON set_logs(session_id, exercise_id, set_index, is_warmup)
  WHERE deleted_at IS NULL;

CREATE UNIQUE INDEX ux_session_user_date
  ON sessions(user_id, date);
