-- Optional metrics on the local activities log. Endurance sessions (run,
-- ride, swim, walk) now go to intervals.icu instead of this table; the
-- remaining local types (pilates, yoga, jump rope, ...) can carry a precise
-- duration, average heart rate and calories. All nullable and additive:
-- existing rows and older clients keep working unchanged.
ALTER TABLE activities ADD COLUMN duration_s INTEGER;
ALTER TABLE activities ADD COLUMN avg_hr INTEGER;
ALTER TABLE activities ADD COLUMN calories INTEGER;
