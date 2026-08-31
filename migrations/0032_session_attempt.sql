-- Monotonic workout-attempt generation for the single (user,date) session
-- row. Discard keeps the current generation; an explicit revival increments
-- it so delayed ACKs from the prior attempt cannot overwrite newer state.
ALTER TABLE sessions ADD COLUMN attempt INTEGER NOT NULL DEFAULT 0;
