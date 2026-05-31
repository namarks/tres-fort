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
  /**
   * intervals.icu OAuth client id (non-sensitive — lives in wrangler.jsonc
   * vars). Issued by david@intervals.icu for the registered app. When unset,
   * the OAuth "Connect with intervals.icu" flow is dormant (the start route
   * 503s) and only the per-user API-key path is available.
   */
  INTERVALS_OAUTH_CLIENT_ID?: string;
  /**
   * intervals.icu OAuth client secret (a `wrangler secret put` secret — NEVER
   * committed). Used server-side in the /auth/intervals/callback code→token
   * exchange. Paired with INTERVALS_OAUTH_CLIENT_ID.
   */
  INTERVALS_OAUTH_CLIENT_SECRET?: string;
  /**
   * Optional canonical OAuth redirect URI. When set, used verbatim by BOTH
   * /auth/intervals/start and /callback so a multi-hostname/proxy deployment
   * can't derive mismatched origins (intervals.icu rejects a redirect_uri
   * mismatch). Unset → derived from the request origin (fine single-host).
   */
  INTERVALS_OAUTH_REDIRECT_URI?: string;
  /**
   * R2 bucket fronting exercise demo images (free-exercise-db frames,
   * public domain). Optional so vitest envs without an R2 binding still
   * type-check; the demo route 404s gracefully when unset.
   */
  DEMOS?: R2Bucket;
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
  /**
   * Per-user intervals.icu API key (M1 multi-user foundation, 0016). Each
   * user owns their own intervals.icu credentials; sync* loops per user.
   * NULL → that user's cycling-awareness is dormant (no fetch, no error).
   */
  intervals_api_key: string | null;
  /**
   * Per-user intervals.icu athlete id. Shared across BOTH auth schemes:
   * the API-key path stores it directly; the OAuth callback stores the
   * `athlete.id` returned by the token exchange into this same column. So
   * `intervals_athlete_id != null` is the canonical "intervals connected"
   * signal regardless of which auth backs it.
   */
  intervals_athlete_id: string | null;
  /**
   * Per-user intervals.icu OAuth bearer token (0022). When set, intervals
   * I/O uses `Authorization: Bearer <token>` and `intervals_api_key` is
   * cleared. NULL → this user authenticates via the API key (or is dormant).
   */
  intervals_oauth_access_token: string | null;
  /** OAuth refresh token, if the token response provided one (else NULL). */
  intervals_oauth_refresh_token: string | null;
  /** OAuth access-token expiry (epoch-ms), if known; NULL = no known expiry. */
  intervals_oauth_expires_at: number | null;
  /**
   * Epoch-ms when a sync last got 401/403 from intervals.icu and could not
   * refresh — the credential is dead (expired/revoked). NULL = healthy. Set
   * by the sync (markIntervalsAuthError), cleared on any (re)connect. Drives
   * the env-seed/fallback back-off and the `needs_reauth` profile flag (0023).
   */
  intervals_auth_error_at: number | null;
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
  /** 1 = a deliberate timed hold (render as "Ns"); 0 = a rep set. Stored
   *  per-set because duration_s alone is unreliable (legacy rep sets carry an
   *  incidental wall-clock duration). Added in migration 0024. */
  is_timed: number;
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
  /** free-exercise-db slug (e.g. "Barbell_Squat") iOS uses to look up demo
   * frames in the bundled asset catalog (foundational lifts) or fetch from
   * the Worker-fronted R2 bucket. Null when no upstream demo exists
   * (planks, holds, band/quadruped primitives) — sheet falls back to cues. */
  exercise_demo_slug: string | null;
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
  /** start_date_local parsed to epoch-ms (treated as UTC for ordering only). */
  start_date_local_ms: number | null;
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
  /** start_date_local parsed to epoch-ms (treated as UTC for ordering only). */
  start_date_local_ms: number | null;
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

// ---- user-authored generic activities (see migrations/0017) --------------

/**
 * Generic activity log: Pilates classes, jump rope, yoga, walks, anything
 * outside strength sessions (set_logs) and intervals.icu actuals
 * (external_activities). Append-only log class — `id` is the client-
 * generated UUID idempotency key, rows are soft-deleted only, writes never
 * bump plans.version. Powers the group/family accountability feed (M4).
 */
export interface ActivityRow {
  id: string;
  user_id: string;
  date: string;            // 'YYYY-MM-DD' device-local, verbatim
  type: string;            // lower-case freeform: pilates|cardio|yoga|walk|other|...
  title: string | null;
  duration_minutes: number | null;
  notes: string | null;
  logged_at: number;       // epoch ms; also the delta-sync cursor
  source: string;          // 'ios' | 'mcp'
  deleted_at: number | null;
}

// ---- groups + invites (see migrations/0018) ------------------------------

/**
 * A friends/family group. The creator is auto-added as a member at
 * creation time (see `createGroup` in src/db.ts). Orphan groups (last
 * member left) are allowed — cleanup is deferred. Group writes do NOT
 * bump plans.version (groups live outside the versioned plan document).
 */
export interface Group {
  id: string;
  name: string;
  created_by: string;       // user_id of the creator
  created_at: number;       // epoch ms
}

/**
 * A row in `group_members`. `display_name` is a per-group nickname
 * override — NULL means "use users.display_name" (resolved at read time
 * in listGroupsForUser / GET /api/groups/:id).
 */
export interface GroupMember {
  group_id: string;
  user_id: string;
  display_name: string | null;
  joined_at: number;
}

/** A member with the *resolved* display name baked in (override or fallback). */
export interface ResolvedGroupMember extends GroupMember {
  /** Per-group override if set, else the user's global display_name. */
  effective_display_name: string | null;
}

/**
 * A single-use group invite. `code` is the 6-char human-shareable key
 * (32-char no-ambiguous alphabet — A-Z minus I/L/O, 2-9). `expires_at`
 * NULL = never expires; default at creation is +30 days. `used_at` /
 * `used_by` are NULL until the code is redeemed; once set, the code is
 * dead and any further redemption attempt is rejected with `used`.
 */
export interface GroupInvite {
  code: string;
  group_id: string;
  created_by: string;
  created_at: number;
  expires_at: number | null;
  used_at: number | null;
  used_by: string | null;
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
