-- Per-set duration logging + timed exercises (plank, holds).
-- duration_s = seconds the set took (work time for timed; start→log
-- elapsed for weighted). NULL for older rows.
ALTER TABLE set_logs ADD COLUMN duration_s INTEGER;

-- Timed exercises: modality 'timed', unit 'sec'. The plan's target_reps
-- carries the prescribed hold in seconds (e.g. 3×45s plank => target_sets
-- 3, target_reps 45).
INSERT INTO exercises (id, name, primary_muscle, secondary_muscles, modality, unit, aliases, created_at) VALUES
 ('ex_plank',      'Plank',          'core', '["shoulders"]', 'timed', 'sec', '["plank","front plank","rkc plank"]', 0),
 ('ex_side_plank', 'Side Plank',     'core', '["obliques"]',  'timed', 'sec', '["side plank"]', 0),
 ('ex_hollow',     'Hollow Hold',    'core', '[]',            'timed', 'sec', '["hollow hold","hollow body"]', 0),
 ('ex_dead_hang',  'Dead Hang',      'back', '["grip"]',      'timed', 'sec', '["dead hang","bar hang"]', 0),
 ('ex_wall_sit',   'Wall Sit',       'quads','[]',            'timed', 'sec', '["wall sit"]', 0);
