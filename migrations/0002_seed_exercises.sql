-- Seed exercise catalog. Stable IDs (ex_*). aliases drives the MCP
-- natural-language resolver ("squat" -> Back Squat). created_at = 0 (epoch);
-- seed rows are timeless.
INSERT INTO exercises (id, name, primary_muscle, secondary_muscles, modality, unit, aliases, created_at) VALUES
 ('ex_back_squat',   'Back Squat',        'quads',       '["glutes","core"]',        'barbell',  'lb', '["squat","back squat","bb squat"]', 0),
 ('ex_front_squat',  'Front Squat',       'quads',       '["glutes","core"]',        'barbell',  'lb', '["front squat"]', 0),
 ('ex_deadlift',     'Conventional Deadlift','hamstrings','["glutes","back"]',       'barbell',  'lb', '["deadlift","dl","conventional deadlift"]', 0),
 ('ex_rdl',          'Romanian Deadlift', 'hamstrings',  '["glutes","back"]',        'barbell',  'lb', '["rdl","romanian deadlift","romanian"]', 0),
 ('ex_bench',        'Bench Press',       'chest',       '["triceps","front delts"]','barbell',  'lb', '["bench","bench press","bp","flat bench"]', 0),
 ('ex_incline_bench','Incline Bench Press','chest',      '["triceps","front delts"]','barbell',  'lb', '["incline","incline bench"]', 0),
 ('ex_ohp',          'Overhead Press',    'shoulders',   '["triceps"]',              'barbell',  'lb', '["ohp","overhead press","press","military press"]', 0),
 ('ex_barbell_row',  'Barbell Row',       'back',        '["biceps","rear delts"]',  'barbell',  'lb', '["row","barbell row","bb row","pendlay row"]', 0),
 ('ex_pullup',       'Pull-Up',           'back',        '["biceps"]',               'bw',       'lb', '["pullup","pull-up","pull up","chin up"]', 0),
 ('ex_db_press',     'Dumbbell Bench Press','chest',     '["triceps","front delts"]','dumbbell', 'lb', '["db press","dumbbell bench","db bench"]', 0),
 ('ex_lat_pulldown', 'Lat Pulldown',      'back',        '["biceps"]',               'machine',  'lb', '["pulldown","lat pulldown"]', 0),
 ('ex_leg_press',    'Leg Press',         'quads',       '["glutes"]',               'machine',  'lb', '["leg press"]', 0);
