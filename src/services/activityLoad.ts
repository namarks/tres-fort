// Effective training load for external activities (migration 0060,
// docs/plans/endurance-training-load P1). training_load / intensity stay the
// provider's figures; effective_load / effective_intensity / load_method hold
// what Tres Fort shows, from src/trainingLoad.ts and the member's thresholds.
// A changed row advances synced_at so /api/state deltas deliver it. This
// service owns its SQL and never imports the db.ts facade.

import { selectLoad, type LoadMethod, type ThresholdSet } from '../trainingLoad';
import { listAthleteThresholds, thresholdsOn, type AthleteThreshold, type ThresholdSport } from './athleteThresholds';
import { heartRateThresholdFor } from '../sports';
import type { ExternalActivityRow } from '../types';

interface LoadRow {
  id: string;
  deleted_at: number | null;
  date: string;
  kind: string;
  /** Migration 0064; null on rows the backfill never saw. */
  sport: string | null;
  moving_time_sec: number | null;
  elapsed_time_sec: number | null;
  distance_m: number | null;
  average_hr: number | null;
  weighted_avg_watts: number | null;
  training_load: number | null;
  intensity: number | null;
  stream_np_w: number | null;
  stream_hr_rms: number | null;
  stream_hr_sec: number | null;
  /** The member's own rating (migration 0066). */
  effort: number | null;
  /** The rating that scores the row: its own, else one given to an Apple
   * Health, .fit or recorded copy since hidden as its duplicate. */
  effort_in: number | null;
  effective_load: number | null;
  effective_intensity: number | null;
  load_method: LoadMethod | null;
}

/** Which threshold set an activity kind uses; other kinds keep only a
 * provider's load. */
export function thresholdSportFor(kind: string): ThresholdSport | null {
  return kind === 'ride' ? 'ride' : kind === 'run' ? 'run' : null;
}

/** The thresholds that score an activity: a run's or ride's whole set, or for
 * another sport only the threshold heart rate of the set it borrows
 * (sport-activities P1), so its pace or power is never scored. */
export function thresholdSetFor(
  kind: string, sport: string | null | undefined, thresholds: readonly AthleteThreshold[], date: string,
): ThresholdSet {
  const own = thresholdSportFor(kind);
  if (own) return thresholdsOn(thresholds, own, date);
  const borrowed = heartRateThresholdFor(sport);
  if (!borrowed) return {};
  const hr = thresholdsOn(thresholds, borrowed, date).threshold_hr;
  return hr ? { threshold_hr: hr } : {};
}

type LoadInputRow = Omit<
  LoadRow,
  'id' | 'deleted_at' | 'effective_load' | 'effective_intensity' | 'load_method' | 'sport' | 'elapsed_time_sec' | 'effort' | 'effort_in'
> & { sport?: string | null; elapsed_time_sec?: number | null; effort?: number | null };

export function effectiveLoadFor(row: LoadInputRow, thresholds: readonly AthleteThreshold[]) {
  const set = thresholdSetFor(row.kind, row.sport, thresholds, row.date);
  return selectLoad(
    {
      moving_time_sec: row.moving_time_sec,
      distance_m: row.distance_m,
      average_hr: row.average_hr,
      weighted_avg_watts: row.weighted_avg_watts,
      provider_load: row.training_load,
      provider_intensity: row.intensity,
      stream_np_w: row.stream_np_w,
      hr_summary:
        row.stream_hr_rms !== null && row.stream_hr_sec !== null
          ? { rms_bpm: row.stream_hr_rms, seconds: row.stream_hr_sec }
          : null,
      elapsed_time_sec: row.elapsed_time_sec ?? null,
      effort: row.effort ?? null,
    },
    set,
  );
}

const BATCH = 50;
const MAX_ATTEMPTS = 3;

/** Changes whenever a threshold is added (total grows) or deleted (live
 * shrinks); rows are append-only, so a value never repeats. */
const thresholdFingerprintSql = (userParam: string) =>
  `SELECT COUNT(*) || ':' || COALESCE(SUM(deleted_at IS NULL), 0) FROM athlete_thresholds WHERE user_id = ${userParam}`;

/**
 * Recompute effective load for one member's live activities, optionally only
 * within [fromDate, toDate]. Apple Health, .fit and recorded-run rows hidden as duplicates
 * of another source's activity are kept current too, because dedup restores them
 * when that activity goes away, possibly outside any later refresh window;
 * their synced_at stays put, and the restore advances it.
 * Writes only rows whose result changed. Each write
 * is a compare-and-swap on the inputs it was computed from and on the
 * member's threshold set, so a calculation overtaken by a sync, a HealthKit
 * revision or a threshold change is never stored; the pass then retries with
 * fresh data. Returns the number of rows updated.
 *
 * A member's effort rating follows the workout across dedup: a live row with
 * no rating of its own takes the newest rating on a row hidden as its
 * duplicate (rated before another source's copy arrived), and keeps it, so
 * the app shows the rating its load came from. A hidden copy without one
 * takes its live winner's (rated before the copy arrived), so the rating
 * survives the copy being restored when the winner goes away. `setActivityEffort` rates a
 * row and its hidden copies together, so clearing it never brings it back.
 */
export async function refreshActivityLoads(
  db: D1Database,
  userId: string,
  window: { fromDate?: string; toDate?: string } = {},
  now = Date.now(),
): Promise<number> {
  let written = 0;
  for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
    const fingerprint = await db
      .prepare(`SELECT (${thresholdFingerprintSql('?1')}) AS fp`)
      .bind(userId)
      .first<{ fp: string }>();
    const [thresholds, rows] = await Promise.all([
      listAthleteThresholds(db, userId),
      db
        .prepare(
          `WITH rated AS (
             SELECT duplicate_of AS winner, effort,
                    ROW_NUMBER() OVER (PARTITION BY duplicate_of ORDER BY synced_at DESC, id) AS rn
               FROM external_activities
              WHERE user_id = ?1 AND duplicate_of IS NOT NULL AND effort IS NOT NULL
           )
           SELECT e.id, e.deleted_at, e.date, e.kind, e.sport, e.moving_time_sec, e.elapsed_time_sec, e.distance_m,
                  e.average_hr, e.weighted_avg_watts, e.training_load, e.intensity,
                  e.stream_np_w, e.stream_hr_rms, e.stream_hr_sec, e.effort,
                  CASE
                    WHEN e.effort IS NOT NULL THEN e.effort
                    WHEN e.deleted_at IS NULL THEN r.effort
                    ELSE w.effort
                  END AS effort_in,
                  e.effective_load, e.effective_intensity, e.load_method
             FROM external_activities e
             LEFT JOIN rated r ON r.winner = e.id AND r.rn = 1
             LEFT JOIN external_activities w
               ON w.id = e.duplicate_of AND w.user_id = e.user_id AND w.deleted_at IS NULL
            WHERE e.user_id = ?1
              AND (e.deleted_at IS NULL OR (e.source IN ('healthkit', 'fit', 'recording') AND e.duplicate_of IS NOT NULL))
              AND e.date >= ?2 AND e.date <= ?3`,
        )
        .bind(userId, window.fromDate ?? '0000-01-01', window.toDate ?? '9999-12-31')
        .all<LoadRow>(),
    ]);
    const updates: D1PreparedStatement[] = [];
    for (const row of rows.results) {
      const next = effectiveLoadFor({ ...row, effort: row.effort_in }, thresholds);
      const load = next?.load ?? null;
      const intensity = next?.intensity ?? null;
      const method = next?.method ?? null;
      if (
        row.effective_load === load && row.effective_intensity === intensity && row.load_method === method
        && row.effort === row.effort_in
      ) continue;
      updates.push(
        db
          .prepare(
            `UPDATE external_activities
                SET effective_load = ?3, effective_intensity = ?4, load_method = ?5, effort = ?24,
                    synced_at = CASE
                      WHEN deleted_at IS NOT NULL THEN synced_at
                      WHEN ?6 > synced_at THEN ?6 ELSE synced_at + 1
                    END
              WHERE id = ?1 AND user_id = ?2 AND deleted_at IS ?19
                AND date IS ?7 AND kind IS ?8 AND moving_time_sec IS ?9 AND distance_m IS ?10
                AND average_hr IS ?11 AND weighted_avg_watts IS ?12
                AND training_load IS ?13 AND intensity IS ?14
                AND stream_np_w IS ?20 AND stream_hr_rms IS ?21 AND stream_hr_sec IS ?22
                AND sport IS ?23 AND elapsed_time_sec IS ?25 AND effort IS ?26
                AND (?24 IS ?26
                  OR EXISTS (
                    SELECT 1 FROM external_activities d
                     WHERE d.user_id = ?2 AND d.duplicate_of = ?1 AND d.effort IS ?24)
                  OR EXISTS (
                    SELECT 1 FROM external_activities w
                     WHERE w.user_id = ?2 AND w.id = external_activities.duplicate_of
                       AND w.deleted_at IS NULL AND w.effort IS ?24))
                AND effective_load IS ?15 AND effective_intensity IS ?16 AND load_method IS ?17
                AND (${thresholdFingerprintSql('?2')}) IS ?18`,
          )
          .bind(
            row.id, userId, load, intensity, method, now,
            row.date, row.kind, row.moving_time_sec, row.distance_m,
            row.average_hr, row.weighted_avg_watts,
            row.training_load, row.intensity,
            row.effective_load, row.effective_intensity, row.load_method,
            fingerprint?.fp ?? null,
            row.deleted_at,
            row.stream_np_w, row.stream_hr_rms, row.stream_hr_sec,
            row.sport,
            row.effort_in, row.elapsed_time_sec, row.effort,
          ),
      );
    }
    let stale = 0;
    for (let i = 0; i < updates.length; i += BATCH) {
      const results = await db.batch(updates.slice(i, i + BATCH));
      for (const r of results) {
        const changes = r.meta.changes ?? 0;
        written += changes;
        if (changes === 0) stale += 1;
      }
    }
    if (stale === 0) break;
  }
  return written;
}

/**
 * Rate how hard a workout was, or clear the rating with null
 * (sport-activities P2). Only a live row the member can see is rated; the
 * rating is written to it and to the rows hidden as its duplicates, so it
 * survives a dedup change either way, and then the day's loads are
 * refreshed. A rating only scores a workout with no measured load; on one
 * with a load it is kept but unused. Null when the member has no such live
 * activity, else the row as it now stands.
 */
export async function setActivityEffort(
  db: D1Database,
  userId: string,
  activityId: string,
  effort: number | null,
  now = Date.now(),
): Promise<ExternalActivityRow | null> {
  const target = await db
    .prepare('SELECT id, date FROM external_activities WHERE id = ?1 AND user_id = ?2 AND deleted_at IS NULL')
    .bind(activityId, userId)
    .first<{ id: string; date: string }>();
  if (!target) return null;
  await db
    .prepare(
      `UPDATE external_activities
          SET effort = ?3,
              synced_at = CASE
                WHEN deleted_at IS NOT NULL THEN synced_at
                WHEN ?4 > synced_at THEN ?4 ELSE synced_at + 1
              END
        WHERE user_id = ?2 AND (id = ?1 OR duplicate_of = ?1) AND effort IS NOT ?3`,
    )
    .bind(target.id, userId, effort, now)
    .run();
  // A hidden copy can sit on a neighbouring civil date (another clock).
  const span = await db
    .prepare(
      `SELECT MIN(date) AS from_date, MAX(date) AS to_date FROM external_activities
        WHERE user_id = ?2 AND (id = ?1 OR duplicate_of = ?1)`,
    )
    .bind(target.id, userId)
    .first<{ from_date: string | null; to_date: string | null }>();
  await refreshActivityLoads(
    db, userId, { fromDate: span?.from_date ?? target.date, toDate: span?.to_date ?? target.date }, now,
  );
  return db
    .prepare('SELECT * FROM external_activities WHERE id = ?1 AND user_id = ?2')
    .bind(target.id, userId)
    .first<ExternalActivityRow>();
}
