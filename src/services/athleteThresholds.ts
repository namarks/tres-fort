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
  /** Where the member says the value came from: typed in, or a suggestion
   * from their intervals.icu settings they confirmed. */
  source?: 'member' | 'intervals';
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
  const { id, sport, metric, value, effective_date, source } = body;
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
  if (source !== undefined && source !== 'member' && source !== 'intervals') fields.push('source');
  for (const key of Object.keys(body)) {
    if (!['id', 'sport', 'metric', 'value', 'effective_date', 'source'].includes(key)) fields.push(key);
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
      source: (source as 'member' | 'intervals' | undefined) ?? 'member',
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
    && row.value === input.value && row.effective_date === input.effective_date && row.source === source
    && row.deleted_at === null;
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

// ---- Suggestions from intervals.icu (P7) --------------------------------
//
// Every activity intervals.icu sends carries the sport settings it was scored
// with: `icu_ftp` (watts), `lthr` (bpm) and `threshold_pace` (metres per
// second, the unit of the activity's own `pace`; intervals.icu doesn't
// document it). The newest synced run and ride therefore say what the member's
// intervals.icu settings are, with no extra request and no extra OAuth scope.
// They are only suggestions: nothing is saved until the member confirms one.

export interface ThresholdSuggestion {
  sport: ThresholdSport;
  metric: ThresholdMetric;
  value: number;
  /** The date of the workout the value was read from. */
  as_of: string;
}

export interface IntervalsSettingsRow {
  kind: string;
  date: string;
  icu_ftp: unknown;
  lthr: unknown;
  threshold_pace: unknown;
}

/** The sport settings in a stored activity's JSON, as one comparable SQL
 * value. The activity sync rewrites a row's `raw` when this changes, so a
 * setting corrected in intervals.icu reaches the suggestions. */
export function thresholdSettingsSQL(raw: string): string {
  return `(CASE WHEN json_valid(${raw}) THEN json_array(json_extract(${raw}, '$.icu_ftp'), `
    + `json_extract(${raw}, '$.lthr'), json_extract(${raw}, '$.threshold_pace')) END)`;
}

/** A stored threshold value from an intervals.icu field, or null when the
 * field is missing or outside the accepted range. */
export function intervalsThresholdValue(metric: ThresholdMetric, raw: unknown): number | null {
  if (typeof raw !== 'number' || !Number.isFinite(raw) || raw <= 0) return null;
  const value = metric === 'threshold_pace_s_per_km' ? Math.round(1000 / raw) : Math.round(raw);
  const [lo, hi] = THRESHOLD_RANGES[metric];
  return value >= lo && value <= hi ? value : null;
}

const FIELD_FOR: Record<ThresholdMetric, keyof IntervalsSettingsRow> = {
  ftp_w: 'icu_ftp',
  threshold_hr: 'lthr',
  threshold_pace_s_per_km: 'threshold_pace',
};

/**
 * One suggestion per sport and metric, from the newest activity that carries
 * it (`rows` newest first). A value is suggested only when it is newer than
 * everything the member has entered for that metric and differs from the
 * value in effect on its date, so a value the member set later is never
 * second-guessed and an accepted suggestion goes away.
 */
export function thresholdSuggestions(rows: readonly IntervalsSettingsRow[], thresholds: readonly AthleteThreshold[]): ThresholdSuggestion[] {
  const out: ThresholdSuggestion[] = [];
  for (const sport of THRESHOLD_SPORTS) {
    for (const metric of THRESHOLD_METRICS[sport]) {
      let found: { value: number; date: string } | null = null;
      for (const row of rows) {
        if (row.kind !== sport || !isCivilDate(row.date)) continue;
        const value = intervalsThresholdValue(metric, row[FIELD_FOR[metric]]);
        if (value !== null) { found = { value, date: row.date }; break; }
      }
      if (!found) continue;
      const mine = thresholds.filter(t => t.sport === sport && t.metric === metric);
      if (mine.some(t => t.effective_date > found.date)) continue;
      if (thresholdOn(thresholds, sport, metric, found.date) === found.value) continue;
      out.push({ sport, metric, value: found.value, as_of: found.date });
    }
  }
  return out;
}

/** Suggestions from the member's synced intervals.icu runs and rides. */
export async function getThresholdSuggestions(db: D1Database, userId: string): Promise<ThresholdSuggestion[]> {
  const { results } = await db
    .prepare(
      `SELECT kind, date,
              json_extract(raw, '$.icu_ftp') AS icu_ftp,
              json_extract(raw, '$.lthr') AS lthr,
              json_extract(raw, '$.threshold_pace') AS threshold_pace
         FROM external_activities
        WHERE user_id = ?1 AND source = 'intervals' AND deleted_at IS NULL
          AND kind IN ('ride', 'run') AND raw IS NOT NULL AND json_valid(raw)
        ORDER BY date DESC, start_date_local_ms DESC, id DESC
        LIMIT 200`,
    )
    .bind(userId)
    .all<IntervalsSettingsRow>();
  return thresholdSuggestions(results, await listAthleteThresholds(db, userId));
}
