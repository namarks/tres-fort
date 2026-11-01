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

/**
 * Recompute effective load for one member's live activities, optionally only
 * within [fromDate, toDate]. Writes only rows whose result changed. Returns
 * the number of rows updated.
 */
export async function refreshActivityLoads(
  db: D1Database,
  userId: string,
  window: { fromDate?: string; toDate?: string } = {},
  now = Date.now(),
): Promise<number> {
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
            WHERE id = ?1 AND user_id = ?2 AND deleted_at IS NULL`,
        )
        .bind(row.id, userId, load, intensity, method, now),
    );
  }
  for (let i = 0; i < updates.length; i += BATCH) {
    await db.batch(updates.slice(i, i + BATCH));
  }
  return updates.length;
}
