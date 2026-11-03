-- Migration 0064: what each imported workout actually was.
--
-- `external_activities.sport` names the sport (soccer, tennis, a swim) beside
-- the coarse `kind`, which stays as it is because cross-source dedup matches
-- on kind and start time. Importers set it from now on (src/sports.ts); this
-- backfills existing rows from the provider JSON each row kept: Apple Health's
-- activity type number and intervals.icu's `type`. Anything else falls back
-- to the kind when it names a sport, else 'other'. The two lookup tables are
-- copies of src/sports.ts (pinned by test/sports.test.ts) and are dropped at
-- the end.
--
-- Live rows get a new synced_at so /api/state deltas deliver the sport to
-- installed apps. Apple Health workouts have no name of their own and older
-- apps called every other sport "Workout"; those take the sport's name.

ALTER TABLE external_activities ADD COLUMN sport TEXT;

CREATE TABLE sport_backfill_0064 (
  source TEXT NOT NULL,
  key TEXT NOT NULL,
  sport TEXT NOT NULL,
  PRIMARY KEY (source, key)
);

INSERT INTO sport_backfill_0064 (source, key, sport) VALUES
  ('healthkit', '1', 'american_football'),
  ('healthkit', '4', 'badminton'),
  ('healthkit', '5', 'baseball'),
  ('healthkit', '6', 'basketball'),
  ('healthkit', '8', 'boxing'),
  ('healthkit', '9', 'climbing'),
  ('healthkit', '10', 'cricket'),
  ('healthkit', '11', 'cross_training'),
  ('healthkit', '13', 'ride'),
  ('healthkit', '14', 'dance'),
  ('healthkit', '16', 'elliptical'),
  ('healthkit', '20', 'strength'),
  ('healthkit', '21', 'golf'),
  ('healthkit', '23', 'handball'),
  ('healthkit', '24', 'hike'),
  ('healthkit', '25', 'hockey'),
  ('healthkit', '27', 'lacrosse'),
  ('healthkit', '28', 'martial_arts'),
  ('healthkit', '31', 'paddling'),
  ('healthkit', '34', 'racquetball'),
  ('healthkit', '35', 'row'),
  ('healthkit', '36', 'rugby'),
  ('healthkit', '37', 'run'),
  ('healthkit', '38', 'sailing'),
  ('healthkit', '39', 'skating'),
  ('healthkit', '41', 'soccer'),
  ('healthkit', '42', 'softball'),
  ('healthkit', '43', 'squash'),
  ('healthkit', '44', 'stairs'),
  ('healthkit', '45', 'surfing'),
  ('healthkit', '46', 'swim'),
  ('healthkit', '47', 'table_tennis'),
  ('healthkit', '48', 'tennis'),
  ('healthkit', '50', 'strength'),
  ('healthkit', '51', 'volleyball'),
  ('healthkit', '52', 'walk'),
  ('healthkit', '57', 'yoga'),
  ('healthkit', '58', 'barre'),
  ('healthkit', '59', 'core'),
  ('healthkit', '60', 'cross_country_ski'),
  ('healthkit', '61', 'downhill_ski'),
  ('healthkit', '62', 'flexibility'),
  ('healthkit', '63', 'hiit'),
  ('healthkit', '64', 'jump_rope'),
  ('healthkit', '65', 'boxing'),
  ('healthkit', '66', 'pilates'),
  ('healthkit', '67', 'snowboard'),
  ('healthkit', '68', 'stairs'),
  ('healthkit', '73', 'cardio'),
  ('healthkit', '75', 'disc_sports'),
  ('healthkit', '77', 'dance'),
  ('healthkit', '78', 'dance'),
  ('healthkit', '79', 'pickleball'),
  ('intervals', 'Ride', 'ride'),
  ('intervals', 'VirtualRide', 'ride'),
  ('intervals', 'GravelRide', 'ride'),
  ('intervals', 'MountainBikeRide', 'ride'),
  ('intervals', 'EBikeRide', 'ride'),
  ('intervals', 'EMountainBikeRide', 'ride'),
  ('intervals', 'Velomobile', 'ride'),
  ('intervals', 'Handcycle', 'ride'),
  ('intervals', 'TrackRide', 'ride'),
  ('intervals', 'Run', 'run'),
  ('intervals', 'TrailRun', 'run'),
  ('intervals', 'VirtualRun', 'run'),
  ('intervals', 'Swim', 'swim'),
  ('intervals', 'OpenWaterSwim', 'swim'),
  ('intervals', 'Walk', 'walk'),
  ('intervals', 'Hike', 'hike'),
  ('intervals', 'Rowing', 'row'),
  ('intervals', 'VirtualRow', 'row'),
  ('intervals', 'Elliptical', 'elliptical'),
  ('intervals', 'StairStepper', 'stairs'),
  ('intervals', 'WeightTraining', 'strength'),
  ('intervals', 'HighIntensityIntervalTraining', 'hiit'),
  ('intervals', 'Crossfit', 'cross_training'),
  ('intervals', 'Yoga', 'yoga'),
  ('intervals', 'Pilates', 'pilates'),
  ('intervals', 'RockClimbing', 'climbing'),
  ('intervals', 'Soccer', 'soccer'),
  ('intervals', 'Basketball', 'basketball'),
  ('intervals', 'Volleyball', 'volleyball'),
  ('intervals', 'Rugby', 'rugby'),
  ('intervals', 'Hockey', 'hockey'),
  ('intervals', 'Cricket', 'cricket'),
  ('intervals', 'Baseball', 'baseball'),
  ('intervals', 'Softball', 'softball'),
  ('intervals', 'Tennis', 'tennis'),
  ('intervals', 'Pickleball', 'pickleball'),
  ('intervals', 'Padel', 'padel'),
  ('intervals', 'Squash', 'squash'),
  ('intervals', 'Racquetball', 'racquetball'),
  ('intervals', 'Badminton', 'badminton'),
  ('intervals', 'TableTennis', 'table_tennis'),
  ('intervals', 'Golf', 'golf'),
  ('intervals', 'Dance', 'dance'),
  ('intervals', 'Boxing', 'boxing'),
  ('intervals', 'IceSkate', 'skating'),
  ('intervals', 'InlineSkate', 'skating'),
  ('intervals', 'AlpineSki', 'downhill_ski'),
  ('intervals', 'BackcountrySki', 'downhill_ski'),
  ('intervals', 'NordicSki', 'cross_country_ski'),
  ('intervals', 'RollerSki', 'cross_country_ski'),
  ('intervals', 'Snowboard', 'snowboard'),
  ('intervals', 'Canoeing', 'paddling'),
  ('intervals', 'Kayaking', 'paddling'),
  ('intervals', 'StandUpPaddling', 'paddling'),
  ('intervals', 'Surfing', 'surfing'),
  ('intervals', 'Kitesurf', 'surfing'),
  ('intervals', 'Windsurf', 'surfing'),
  ('intervals', 'Sail', 'sailing'),
  ('intervals', 'Workout', 'other');

CREATE TABLE sport_labels_0064 (
  sport TEXT PRIMARY KEY,
  label TEXT NOT NULL
);

INSERT INTO sport_labels_0064 (sport, label) VALUES
  ('run', 'Run'),
  ('ride', 'Ride'),
  ('swim', 'Swim'),
  ('walk', 'Walk'),
  ('hike', 'Hike'),
  ('row', 'Row'),
  ('elliptical', 'Elliptical'),
  ('stairs', 'Stair stepper'),
  ('cardio', 'Cardio'),
  ('hiit', 'HIIT'),
  ('cross_training', 'Cross training'),
  ('strength', 'Strength'),
  ('core', 'Core'),
  ('yoga', 'Yoga'),
  ('pilates', 'Pilates'),
  ('barre', 'Barre'),
  ('flexibility', 'Stretching'),
  ('dance', 'Dance'),
  ('boxing', 'Boxing'),
  ('martial_arts', 'Martial arts'),
  ('climbing', 'Climbing'),
  ('soccer', 'Soccer'),
  ('basketball', 'Basketball'),
  ('volleyball', 'Volleyball'),
  ('american_football', 'Football'),
  ('rugby', 'Rugby'),
  ('hockey', 'Hockey'),
  ('lacrosse', 'Lacrosse'),
  ('handball', 'Handball'),
  ('baseball', 'Baseball'),
  ('softball', 'Softball'),
  ('cricket', 'Cricket'),
  ('disc_sports', 'Ultimate'),
  ('tennis', 'Tennis'),
  ('pickleball', 'Pickleball'),
  ('padel', 'Padel'),
  ('squash', 'Squash'),
  ('racquetball', 'Racquetball'),
  ('badminton', 'Badminton'),
  ('table_tennis', 'Table tennis'),
  ('golf', 'Golf'),
  ('skating', 'Skating'),
  ('downhill_ski', 'Skiing'),
  ('cross_country_ski', 'Cross-country ski'),
  ('snowboard', 'Snowboard'),
  ('paddling', 'Paddling'),
  ('surfing', 'Surfing'),
  ('sailing', 'Sailing'),
  ('jump_rope', 'Jump rope'),
  ('other', 'Other');

UPDATE external_activities
   SET sport = COALESCE(
         (SELECT m.sport FROM sport_backfill_0064 AS m
           WHERE m.source = external_activities.source
             AND m.key = CASE
               WHEN NOT json_valid(external_activities.raw) THEN NULL
               WHEN external_activities.source = 'healthkit'
                 AND json_type(external_activities.raw, '$.hk_activity_type') = 'integer'
                 THEN CAST(json_extract(external_activities.raw, '$.hk_activity_type') AS TEXT)
               WHEN external_activities.source = 'intervals'
                 AND json_type(external_activities.raw, '$.type') = 'text'
                 THEN json_extract(external_activities.raw, '$.type')
             END),
         CASE WHEN external_activities.source = 'healthkit'
               AND json_valid(external_activities.raw)
               AND json_type(external_activities.raw, '$.hk_activity_type') = 'integer'
              THEN 'other' END,
         (SELECT l.sport FROM sport_labels_0064 AS l WHERE l.sport = external_activities.kind),
         'other'),
       synced_at = CASE
         WHEN deleted_at IS NULL
           THEN MAX(synced_at + 1, CAST(strftime('%s', 'now') AS INTEGER) * 1000)
         ELSE synced_at
       END;

UPDATE external_activities
   SET name = (SELECT l.label FROM sport_labels_0064 AS l WHERE l.sport = external_activities.sport)
 WHERE source = 'healthkit'
   AND (name IS NULL OR name = 'Workout')
   AND sport IS NOT NULL
   AND sport <> 'other';

DROP TABLE sport_backfill_0064;
DROP TABLE sport_labels_0064;
