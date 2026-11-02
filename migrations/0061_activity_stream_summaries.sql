-- Detail-stream summaries for Apple Health workouts
-- (docs/plans/endurance-training-load P3). The app sends the heart-rate and
-- cycling-power samples recorded inside a workout; the Worker reduces them,
-- with src/trainingLoad.ts, to threshold-independent figures and keeps only
-- those, so a threshold change can rescore the workout without the samples:
--   stream_np_w      normalized power from a dense power stream
--   stream_hr_rms    root mean square heart rate over the covered seconds
--   stream_hr_sec    seconds the heart-rate stream covers
-- NULL means the source sent no stream dense enough to score.
ALTER TABLE external_activities ADD COLUMN stream_np_w REAL;
ALTER TABLE external_activities ADD COLUMN stream_hr_rms REAL;
ALTER TABLE external_activities ADD COLUMN stream_hr_sec INTEGER;
