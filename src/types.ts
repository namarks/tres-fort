export interface Env {
  DB: D1Database;
  APPLE_BUNDLE_ID: string;
  APP_JWT_SECRET: string;
  MCP_STATIC_TOKEN?: string;
  /** Allowlisted Apple `sub`. If set, only this user may sign in. */
  OWNER_APPLE_SUB?: string;
  /** If set, enables POST /auth/dev for local + integration tests. */
  DEV_AUTH_SECRET?: string;
  /** Consent gate for the OAuth /authorize step (claude.ai/desktop). */
  OWNER_AUTH_PASSPHRASE?: string;
  /**
   * intervals.icu API key (a `wrangler secret put` secret — NEVER committed).
   * The cycling-awareness feature is DORMANT (a clean no-op, no error) when
   * this is unset.
   */
  INTERVALS_ICU_API_KEY?: string;
  /** intervals.icu athlete id (non-sensitive — lives in wrangler.jsonc vars). */
  INTERVALS_ICU_ATHLETE_ID?: string;
}

export type HonoEnv = {
  Bindings: Env;
  Variables: { userId: string };
};

export interface User {
  id: string;
  apple_sub: string;
  email: string | null;
  display_name: string | null;
  created_at: number;
  /** Device-reported IANA timezone (e.g. America/Los_Angeles); null until first sync. */
  timezone: string | null;
}

export interface PlanRow {
  id: string;
  user_id: string;
  name: string;
  status: string;
  version: number;
  meta: string | null;
  created_at: number;
  updated_at: number;
}

export interface DayTemplateRow {
  id: string;
  plan_id: string;
  name: string;
  day_label: string | null;
  order_index: number;
  notes: string | null;
  created_at: number;
  updated_at: number;
}

export interface TemplateExerciseRow {
  id: string;
  day_template_id: string;
  exercise_id: string;
  order_index: number;
  target_sets: number;
  target_reps: number;
  target_reps_max: number | null;
  target_rpe: number | null;
  rest_seconds: number;
  target_weight: number | null;
  /** Planned hold/duration in seconds for timed slots (planks, Cat-Cow,
   *  etc.). NULL → conventional weight-and-reps slot. Mirror of
   *  set_logs.duration_s (the *logged* counterpart). Added in 0010. */
  target_duration_s: number | null;
  progression: string | null;
  cues: string | null;
  created_at: number;
  updated_at: number;
}

export interface SessionRow {
  id: string;
  user_id: string;
  plan_id: string;
  day_template_id: string | null;
  date: string;
  status: string;
  started_at: number | null;
  completed_at: number | null;
  perceived_fatigue: number | null;
  notes: string | null;
  created_at: number;
  updated_at: number;
}

export interface SetLogRow {
  id: string;
  session_id: string;
  exercise_id: string;
  template_exercise_id: string | null;
  set_index: number;
  weight: number;
  reps: number;
  rpe: number | null;
  is_warmup: number;
  notes: string | null;
  logged_at: number;
  source: string;
  duration_s: number | null;
  deleted_at: number | null;
}

export interface EnrichedTemplateExercise extends TemplateExerciseRow {
  exercise_name: string;
  exercise_unit: string;
  exercise_muscle: string;
  exercise_modality: string;
  /** 'bilateral' | 'unilateral'. Unilateral exercises log reps per-side. */
  exercise_laterality: string;
  /** 'total' | 'per_hand'. per_hand → weight is one dumbbell, shown "X each hand". */
  exercise_load_mode: string;
}

export interface PlanTree extends PlanRow {
  days: (DayTemplateRow & { exercises: EnrichedTemplateExercise[] })[];
}

// ---- external events (frozen contract — see migrations/0006) -------------

/**
 * Server-owned reconciled cache of planned endurance events (intervals.icu).
 * NOT versioned plan tree, NOT the append-only log. Soft-deleted only.
 */
export interface ExternalEventRow {
  id: string; // "intervals:{external_id}"
  user_id: string;
  source: string; // 'intervals'
  external_id: string;
  date: string; // YYYY-MM-DD from start_date_local, verbatim
  kind: string; // ride|run|swim|other
  title: string | null;
  description: string | null;
  planned_duration_sec: number | null;
  training_load: number | null;
  intensity: number | null;
  raw: string | null;
  synced_at: number; // epoch-ms
  deleted_at: number | null;
}

/** A normalized planned event as returned by the intervals.icu fetcher. */
export interface PlannedEvent {
  external_id: string;
  date: string; // start_date_local YYYY-MM-DD verbatim
  kind: string; // ride|run|swim|other
  title: string | null;
  description: string | null;
  planned_duration_sec: number | null;
  training_load: number | null;
  intensity: number | null;
  raw: string; // source JSON for this event
}

// ---- completed activities (frozen contract — see migrations/0015) ---------

/**
 * Server-owned reconciled cache of COMPLETED endurance activities pulled
 * from intervals.icu (the actuals: duration, power, HR, distance, TSS).
 * Parallel to ExternalEventRow but a SEPARATE consistency class: completed
 * (past) actuals, never the planned (future) conflict-awareness feed.
 * Soft-deleted only; a sync never bumps plans.version.
 */
export interface ExternalActivityRow {
  id: string; // "intervals:activity:{external_id}"
  user_id: string;
  source: string; // 'intervals'
  external_id: string;
  date: string; // YYYY-MM-DD from start_date_local, verbatim
  kind: string; // ride|run|swim|other
  name: string | null;
  moving_time_sec: number | null;
  elapsed_time_sec: number | null;
  distance_m: number | null;
  average_watts: number | null;
  weighted_avg_watts: number | null; // normalized power
  average_hr: number | null;
  max_hr: number | null;
  training_load: number | null; // TSS-like
  intensity: number | null; // IF
  calories: number | null;
  elevation_gain_m: number | null;
  raw: string | null;
  synced_at: number; // epoch-ms
  deleted_at: number | null;
}

/** A normalized completed activity as returned by the intervals.icu fetcher. */
export interface CompletedActivity {
  external_id: string;
  date: string; // start_date_local YYYY-MM-DD verbatim
  kind: string; // ride|run|swim|other
  name: string | null;
  moving_time_sec: number | null;
  elapsed_time_sec: number | null;
  distance_m: number | null;
  average_watts: number | null;
  weighted_avg_watts: number | null;
  average_hr: number | null;
  max_hr: number | null;
  training_load: number | null;
  intensity: number | null;
  calories: number | null;
  elevation_gain_m: number | null;
  raw: string; // source JSON for this activity
}

/** Per-date conflict between lift sessions/projections and external events. */
export interface DayConflict {
  date: string;
  conflicts: string[]; // external_event ids
  severity: 'clash' | 'heavy-next-day';
}

// ---- weekly schedule (frozen contract — see migrations/0005) -------------

export type Weekday = 'mon' | 'tue' | 'wed' | 'thu' | 'fri' | 'sat' | 'sun';

/** Weekday-keyed recurring pattern. Value = day_template_id, or null = rest. */
export type ScheduleWeek = Record<Weekday, string | null>;

export interface WeeklySchedule {
  version: number;
  week: ScheduleWeek;
}

/** Canonical weekday order, indexable by the calendar-derived day index. */
export const WEEKDAYS: readonly Weekday[] = [
  'mon',
  'tue',
  'wed',
  'thu',
  'fri',
  'sat',
  'sun',
];

/** Parsed shape of plans.meta. Schedule is always present after migration. */
export interface PlanMeta {
  schedule: WeeklySchedule;
  [k: string]: unknown;
}

function emptyWeek(): ScheduleWeek {
  return { mon: null, tue: null, wed: null, thu: null, fri: null, sat: null, sun: null };
}

export function emptySchedule(): WeeklySchedule {
  return { version: 1, week: emptyWeek() };
}

/**
 * The ONLY place plan.meta is parsed. Never hand-parse meta elsewhere.
 * Tolerates null / invalid JSON / missing or malformed schedule and always
 * returns a well-formed PlanMeta with a complete weekday map.
 */
export function parsePlanMeta(raw: string | null): PlanMeta {
  let obj: Record<string, unknown> = {};
  if (raw != null) {
    try {
      const p = JSON.parse(raw);
      if (p && typeof p === 'object' && !Array.isArray(p)) {
        obj = p as Record<string, unknown>;
      }
    } catch {
      // fall through to defaults
    }
  }
  const sched = obj.schedule as Partial<WeeklySchedule> | undefined;
  const week = emptyWeek();
  if (sched && typeof sched === 'object' && sched.week && typeof sched.week === 'object') {
    for (const d of WEEKDAYS) {
      const v = (sched.week as Record<string, unknown>)[d];
      week[d] = typeof v === 'string' && v.length > 0 ? v : null;
    }
  }
  return {
    ...obj,
    schedule: {
      version: typeof sched?.version === 'number' ? sched.version : 1,
      week,
    },
  };
}

/** Serialize meta back, with the schedule slotted in (preserving other keys). */
export function serializePlanMeta(meta: PlanMeta, schedule: WeeklySchedule): string {
  return JSON.stringify({ ...meta, schedule });
}
