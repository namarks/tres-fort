// Athlete thresholds (migration 0059, docs/plans/endurance-training-load).
// Append-only history per member: a row means "from this civil date on, this
// sport's metric is this value". The client UUID is the idempotency key;
// corrections soft-delete and add a new row. This service owns its SQL and
// never imports the db.ts facade.

import type { ThresholdSet } from '../trainingLoad';

export const THRESHOLD_SPORTS = ['ride', 'run'] as const;
export type ThresholdSport = (typeof THRESHOLD_SPORTS)[number];
export type ThresholdMetric = 'ftp_w' | 'threshold_hr' | 'threshold_pace_s_per_km';
export type ThresholdSource = 'member' | 'coach' | 'intervals';

/** Which metrics each sport carries, and the accepted value range for each. */
export const THRESHOLD_METRICS: Record<ThresholdSport, readonly ThresholdMetric[]> = {
  ride: ['ftp_w', 'threshold_hr'],
  run: ['threshold_hr', 'threshold_pace_s_per_km'],
};
export const THRESHOLD_RANGES: Record<ThresholdMetric, readonly [number, number]> = {
  ftp_w: [30, 2000],
  threshold_hr: [60, 230],
  // 2:00 to 20:00 per kilometre.
  threshold_pace_s_per_km: [120, 1200],
};

export interface AthleteThreshold {
  id: string;
  sport: ThresholdSport;
  metric: ThresholdMetric;
  value: number;
  effective_date: string;
  source: ThresholdSource;
  created_at: number;
}

export interface ThresholdInput {
  id: string;
  sport: ThresholdSport;
  metric: ThresholdMetric;
  value: number;
  effective_date: string;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isCivilDate(value: unknown): value is string {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const d = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === value;
}

/** Validate an untrusted body; returns the invalid field names, or the input. */
export function parseThresholdInput(body: Record<string, unknown>): { ok: true; input: ThresholdInput } | { ok: false; fields: string[] } {
  const fields: string[] = [];
  const { id, sport, metric, value, effective_date } = body;
  if (typeof id !== 'string' || !UUID.test(id)) fields.push('id');
  const sportOk = typeof sport === 'string' && (THRESHOLD_SPORTS as readonly string[]).includes(sport);
  if (!sportOk) fields.push('sport');
  const metricOk = sportOk && typeof metric === 'string'
    && (THRESHOLD_METRICS[sport as ThresholdSport] as readonly string[]).includes(metric);
  if (!metricOk) fields.push('metric');
  if (metricOk) {
    const [lo, hi] = THRESHOLD_RANGES[metric as ThresholdMetric];
    if (typeof value !== 'number' || !Number.isFinite(value) || value < lo || value > hi) fields.push('value');
  } else if (typeof value !== 'number' || !Number.isFinite(value)) {
    fields.push('value');
  }
  if (!isCivilDate(effective_date)) fields.push('effective_date');
  for (const key of Object.keys(body)) {
    if (!['id', 'sport', 'metric', 'value', 'effective_date'].includes(key)) fields.push(key);
  }
  if (fields.length) return { ok: false, fields };
  return {
    ok: true,
    input: {
      id: (id as string).toLowerCase(),
      sport: sport as ThresholdSport,
      metric: metric as ThresholdMetric,
      value: value as number,
      effective_date: effective_date as string,
    },
  };
}

/**
 * The value in effect on `date`: the latest row on or before it (newest
 * created wins a same-day tie). Before the first row, the earliest row applies,
 * so setting a threshold today also gives older workouts a load.
 */
export function thresholdOn(rows: readonly AthleteThreshold[], sport: ThresholdSport, metric: ThresholdMetric, date: string): number | null {
  const mine = rows
    .filter(r => r.sport === sport && r.metric === metric)
    .sort((a, b) => a.effective_date.localeCompare(b.effective_date) || a.created_at - b.created_at);
  if (!mine.length) return null;
  let found: AthleteThreshold | null = null;
  for (const r of mine) if (r.effective_date <= date) found = r;
  return (found ?? mine[0])?.value ?? null;
}

/** Every metric of a sport in effect on `date`. */
export function thresholdsOn(rows: readonly AthleteThreshold[], sport: ThresholdSport, date: string): ThresholdSet {
  const set: ThresholdSet = {};
  for (const metric of THRESHOLD_METRICS[sport]) set[metric] = thresholdOn(rows, sport, metric, date);
  return set;
}

/** Live (not deleted) thresholds for one member, oldest first. */
export async function listAthleteThresholds(db: D1Database, userId: string): Promise<AthleteThreshold[]> {
  const { results } = await db
    .prepare(
      `SELECT id, sport, metric, value, effective_date, source, created_at
         FROM athlete_thresholds
        WHERE user_id = ?1 AND deleted_at IS NULL
        ORDER BY sport, metric, effective_date, created_at, id`,
    )
    .bind(userId)
    .all<AthleteThreshold>();
  return results;
}

export interface ThresholdsView {
  thresholds: AthleteThreshold[];
  /** In effect on `as_of` (the latest value when no date was given). */
  current: Record<ThresholdSport, ThresholdSet>;
  as_of: string | null;
}

export async function getAthleteThresholds(db: D1Database, userId: string, asOf: string | null): Promise<ThresholdsView> {
  const thresholds = await listAthleteThresholds(db, userId);
  const date = asOf ?? '9999-12-31';
  return {
    thresholds,
    current: { ride: thresholdsOn(thresholds, 'ride', date), run: thresholdsOn(thresholds, 'run', date) },
    as_of: asOf,
  };
}

export type AddThresholdResult =
  | { ok: true; threshold: AthleteThreshold; deduplicated: boolean }
  | { ok: false; error: 'id_conflict' };

/** Insert one threshold row. A retry with the same id and payload returns the
 * stored row; the same id with a different payload or owner is a conflict. */
export async function addAthleteThreshold(db: D1Database, userId: string, input: ThresholdInput, source: ThresholdSource, now = Date.now()): Promise<AddThresholdResult> {
  const inserted = await db
    .prepare(
      `INSERT INTO athlete_thresholds (id, user_id, sport, metric, value, effective_date, source, created_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
       ON CONFLICT(id) DO NOTHING`,
    )
    .bind(input.id, userId, input.sport, input.metric, input.value, input.effective_date, source, now)
    .run();
  const row = await db
    .prepare(
      `SELECT id, user_id, sport, metric, value, effective_date, source, created_at, deleted_at
         FROM athlete_thresholds WHERE id = ?1`,
    )
    .bind(input.id)
    .first<AthleteThreshold & { user_id: string; deleted_at: number | null }>();
  if (!row) return { ok: false, error: 'id_conflict' };
  const same = row.user_id === userId && row.sport === input.sport && row.metric === input.metric
    && row.value === input.value && row.effective_date === input.effective_date && row.deleted_at === null;
  if (!same) return { ok: false, error: 'id_conflict' };
  const { user_id: _u, deleted_at: _d, ...threshold } = row;
  return { ok: true, threshold, deduplicated: (inserted.meta.changes ?? 0) === 0 };
}

/** Soft-delete one of the member's thresholds. Deleting an already deleted
 * row succeeds again; another member's row, or no row, is not found. */
export async function deleteAthleteThreshold(db: D1Database, userId: string, id: string, now = Date.now()): Promise<{ ok: true } | { ok: false; error: 'not_found' }> {
  const key = id.toLowerCase();
  await db
    .prepare('UPDATE athlete_thresholds SET deleted_at = ?3 WHERE id = ?1 AND user_id = ?2 AND deleted_at IS NULL')
    .bind(key, userId, now)
    .run();
  const row = await db
    .prepare('SELECT 1 AS found FROM athlete_thresholds WHERE id = ?1 AND user_id = ?2')
    .bind(key, userId)
    .first<{ found: number }>();
  return row ? { ok: true } : { ok: false, error: 'not_found' };
}
