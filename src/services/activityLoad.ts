// Effective training load for external activities (migration 0060,
// docs/plans/endurance-training-load P1). training_load / intensity stay the
// provider's figures; effective_load / effective_intensity / load_method hold
// what Tres Fort shows, from src/trainingLoad.ts and the member's thresholds.
// A changed row advances synced_at so /api/state deltas deliver it. This
// service owns its SQL and never imports the db.ts facade.

import { selectLoad, type LoadMethod, type ThresholdSet } from '../trainingLoad';
import { listAthleteThresholds, thresholdsOn, type AthleteThreshold, type ThresholdSport } from './athleteThresholds';

interface LoadRow {
  id: string;
  date: string;
  kind: string;
  moving_time_sec: number | null;
  distance_m: number | null;
  average_hr: number | null;
  weighted_avg_watts: number | null;
  training_load: number | null;
  intensity: number | null;
  effective_load: number | null;
  effective_intensity: number | null;
  load_method: LoadMethod | null;
}

/** Which threshold set an activity kind uses; other kinds keep only a
 * provider's load. */
export function thresholdSportFor(kind: string): ThresholdSport | null {
  return kind === 'ride' ? 'ride' : kind === 'run' ? 'run' : null;
}

export function effectiveLoadFor(row: Omit<LoadRow, 'id' | 'effective_load' | 'effective_intensity' | 'load_method'>, thresholds: readonly AthleteThreshold[]) {
  const sport = thresholdSportFor(row.kind);
  const set: ThresholdSet = sport ? thresholdsOn(thresholds, sport, row.date) : {};
  return selectLoad(
    {
      moving_time_sec: row.moving_time_sec,
      distance_m: row.distance_m,
      average_hr: row.average_hr,
      weighted_avg_watts: row.weighted_avg_watts,
      provider_load: row.training_load,
      provider_intensity: row.intensity,
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
 * within [fromDate, toDate]. Writes only rows whose result changed. Each write
 * is a compare-and-swap on the inputs it was computed from and on the
 * member's threshold set, so a calculation overtaken by a sync, a HealthKit
 * revision or a threshold change is never stored; the pass then retries with
 * fresh data. Returns the number of rows updated.
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
          `SELECT id, date, kind, moving_time_sec, distance_m, average_hr, weighted_avg_watts,
                  training_load, intensity, effective_load, effective_intensity, load_method
             FROM external_activities
            WHERE user_id = ?1 AND deleted_at IS NULL
              AND date >= ?2 AND date <= ?3`,
        )
        .bind(userId, window.fromDate ?? '0000-01-01', window.toDate ?? '9999-12-31')
        .all<LoadRow>(),
    ]);
    const updates: D1PreparedStatement[] = [];
    for (const row of rows.results) {
      const next = effectiveLoadFor(row, thresholds);
      const load = next?.load ?? null;
      const intensity = next?.intensity ?? null;
      const method = next?.method ?? null;
      if (row.effective_load === load && row.effective_intensity === intensity && row.load_method === method) continue;
      updates.push(
        db
          .prepare(
            `UPDATE external_activities
                SET effective_load = ?3, effective_intensity = ?4, load_method = ?5,
                    synced_at = CASE WHEN ?6 > synced_at THEN ?6 ELSE synced_at + 1 END
              WHERE id = ?1 AND user_id = ?2 AND deleted_at IS NULL
                AND date IS ?7 AND kind IS ?8 AND moving_time_sec IS ?9 AND distance_m IS ?10
                AND average_hr IS ?11 AND weighted_avg_watts IS ?12
                AND training_load IS ?13 AND intensity IS ?14
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
