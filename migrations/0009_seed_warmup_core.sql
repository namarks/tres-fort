-- 0009_seed_warmup_core.sql
-- Adds the warmup / core / activation primitives that an agent-facing
-- bug report flagged as missing — exercises that an LLM coach would
-- reach for when programming a real session but that 0007's
-- barbell-and-machine curation explicitly excluded ("Excluded:
-- band/ball/foam-only, kettlebell flows"). The 0007 curation made
-- sense for the deadlift-and-bench core; this migration covers the
-- mobility / activation / accessory primitives that turn a barbell
-- logger into a real coaching surface.
--
-- New entries (all bw / band / kettlebell — non-overlapping with the
-- existing barbell/dumbbell/machine catalog). Modality strings 'band'
-- and 'kettlebell' are new but the column is free-text and downstream
-- iOS handles unknown modalities generically (no UI special-casing).
-- created_at = 0 (epoch): seed rows are timeless. INSERT OR IGNORE
-- keeps re-runs a no-op. Aliases cover the hyphenated / abbreviated
-- spellings the bug report explicitly hit (KB Deadlift, Scap Pull-
-- Apart, Chest-Supported Row, etc.).

INSERT OR IGNORE INTO exercises
  (id, name, primary_muscle, secondary_muscles, modality, unit, aliases, created_at)
VALUES
  ('ex_kb_deadlift',         'Kettlebell Deadlift',     'hamstrings', '["glutes", "back"]',           'kettlebell', 'lb', '["kettlebell deadlift", "kb deadlift", "kb dl", "kettlebell rdl"]', 0),
  ('ex_kb_swing',            'Kettlebell Swing',        'hamstrings', '["glutes", "back", "core"]',   'kettlebell', 'lb', '["kettlebell swing", "kb swing", "swing", "russian swing", "hardstyle swing"]', 0),
  ('ex_bird_dog',            'Bird Dog',                'core',       '["glutes", "back"]',           'bw',         'lb', '["bird dog", "bird-dog", "birddog", "quadruped bird dog"]', 0),
  ('ex_cat_cow',             'Cat-Cow',                 'core',       '["back"]',                     'bw',         'lb', '["cat cow", "cat-cow", "cat camel"]', 0),
  -- ex_dead_bug already exists in 0007; intentionally omitted here.
  ('ex_banded_pull_apart',   'Banded Pull-Apart',       'back',       '["shoulders"]',                'band',       'lb', '["banded pull-apart", "banded pull apart", "pull-apart", "pull apart", "scap pull-apart", "scap pull apart", "scapular pull-apart"]', 0),
  ('ex_banded_glute_bridge', 'Banded Glute Bridge',     'glutes',     '["hamstrings"]',               'band',       'lb', '["banded glute bridge", "mini band glute bridge"]', 0),
  ('ex_chest_supported_row', 'Chest-Supported Row',     'back',       '["biceps", "shoulders"]',      'machine',    'lb', '["chest-supported row", "chest supported row", "chest supported db row", "supported row"]', 0);
