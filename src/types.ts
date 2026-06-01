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
   * Shared secret for the intervals.icu push webhook (`POST /webhooks/intervals`,
   * a `wrangler secret put` secret — NEVER committed). MUST equal the
   * "Webhook Secret" configured on the intervals.icu Manage App page. Every
   * delivery carries this in its JSON body; the receiver matches it to
   * authenticate. UNSET → the webhook receiver is dormant (it 401s every
   * request) and the 15-min polling cron remains the only sync path.
   */
  INTERVALS_WEBHOOK_SECRET?: string;
  /**
   * Optional second factor for the webhook (a `wrangler secret put` secret).
   * The Manage App page can set a "Webhook Authorization Header"; when this is
   * configured, the receiver ALSO requires the request's `Authorization`
   * header to match it verbatim. UNSET → only the body secret is checked.
   */
  INTERVALS_WEBHOOK_AUTH_HEADER?: string;
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

/**
 * Per-date conflict between lift sessions/projections and external events.
 *
 * Severities (least → most concerning), interference-aware per MULTISPORT.md
 * §6.1/§7 — NOT "any same-day pairing is a clash":
 *   - 'brick'          — a benign, intended same-day pairing: a strength day
 *     alongside an EASY/short endurance session (sub-`isHard` threshold). This
 *     is the deliberate brick/double, NOT a problem. Informational only.
 *   - 'heavy-next-day' — a lift the civil day BEFORE a hard endurance session
 *     (training_load >= 150 OR planned_duration_sec >= 9000). Unchanged.
 *   - 'clash'          — a real interference: a strength day SAME-DAY as a
 *     KEY/long (hard) endurance session. The case worth flagging.
 */
export interface DayConflict {
  date: string;
  conflicts: string[]; // external_event ids
  severity: 'brick' | 'clash' | 'heavy-next-day';
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

// ---- multisport plan meta (authored intent — see docs/MULTISPORT.md §4) ----
// race / periodization / trips / stress_model all live in plans.meta JSON
// ALONGSIDE `schedule`: versioned document, optimistic concurrency, audit+note
// on write (DESIGN.md §3). They are AUTHORED TRUTH the coach reasons over, NOT a
// materialized calendar — the projection DERIVES days from them (store truth,
// derive views). The backend stores and projects; it never computes training
// science. Absent fields are simply omitted from the JSON. M2 authors them via
// the `set_*` tools; M4's calendar projection READS them.

export type RacePriority = 'A' | 'B' | 'C';

/** The goal event the plan builds toward. §4.1. */
export interface RaceGoal {
  name: string;
  date: string; // YYYY-MM-DD civil date (the periodization anchor)
  discipline: string; // triathlon | running | cycling | ...
  distance?: string; // "70.3", "marathon", ...
  priority?: RacePriority;
  location?: string;
}

export type TrainingPhase =
  | 'base'
  | 'build'
  | 'peak'
  | 'taper'
  | 'race'
  | 'recovery';

/** One periodization block — phase INTENT, not per-day rows. §4.2. */
export interface PeriodizationPhase {
  phase: TrainingPhase;
  start: string; // YYYY-MM-DD
  end: string; // YYYY-MM-DD
  focus?: string;
  weekly_load_target?: number;
  strength_emphasis?: string; // hypertrophy | maintenance | minimal | ...
}

export type TripType = 'travel' | 'rest' | 'injury' | 'other';

/** An availability / blackout range. §4.3. The EFFECT (which days become rest)
 * is NOT stored here — the coach re-plans via set_planned_session/skip. */
export interface Trip {
  id: string; // uuid
  start: string; // YYYY-MM-DD
  end: string; // YYYY-MM-DD
  type: TripType;
  /** Pool/run access while away? Defaults true; only an explicit false marks
   *  the range `unavailable` in the calendar projection (M4). */
  can_train_light?: boolean;
  note?: string;
}

/** The planning load model. §4.4. Intentionally LOOSE — the coach reasons over
 * these dimensions/rules; the backend only stores them, never interprets. */
export interface StressModel {
  discipline_weights?: Record<string, Record<string, number>>;
  interference_rules?: string[];
  age_modifiers?: Record<string, number>;
  [k: string]: unknown;
}

/** Parsed shape of plans.meta. Schedule is always present after migration;
 * the multisport fields are optional (omitted until authored). */
export interface PlanMeta {
  schedule: WeeklySchedule;
  race?: RaceGoal;
  periodization?: PeriodizationPhase[];
  trips?: Trip[];
  stress_model?: StressModel;
  [k: string]: unknown;
}

function emptyWeek(): ScheduleWeek {
  return { mon: null, tue: null, wed: null, thu: null, fri: null, sat: null, sun: null };
}

export function emptySchedule(): WeeklySchedule {
  return { version: 1, week: emptyWeek() };
}

const isStr = (v: unknown): v is string => typeof v === 'string' && v.length > 0;
const YMD = /^\d{4}-\d{2}-\d{2}$/;

// Envelope-validators for the authored-intent meta fields. Each drops a
// malformed entry rather than throwing (same tolerance as the schedule parse)
// and returns `undefined` when there is nothing valid, so JSON.stringify omits
// the key. Known fields are coerced; freeform content passes through.
function normalizeRace(v: unknown): RaceGoal | undefined {
  if (!v || typeof v !== 'object' || Array.isArray(v)) return undefined;
  const r = v as Record<string, unknown>;
  if (!isStr(r.name) || !isStr(r.date) || !isStr(r.discipline)) return undefined;
  const out: RaceGoal = { name: r.name, date: r.date, discipline: r.discipline };
  if (isStr(r.distance)) out.distance = r.distance;
  if (r.priority === 'A' || r.priority === 'B' || r.priority === 'C') out.priority = r.priority;
  if (isStr(r.location)) out.location = r.location;
  return out;
}

const TRAINING_PHASES = new Set(['base', 'build', 'peak', 'taper', 'race', 'recovery']);
function normalizePeriodization(v: unknown): PeriodizationPhase[] | undefined {
  if (!Array.isArray(v)) return undefined;
  const phases: PeriodizationPhase[] = [];
  for (const item of v) {
    if (!item || typeof item !== 'object') continue;
    const p = item as Record<string, unknown>;
    if (!TRAINING_PHASES.has(p.phase as string) || !isStr(p.start) || !isStr(p.end)) continue;
    const phase: PeriodizationPhase = {
      phase: p.phase as TrainingPhase,
      start: p.start,
      end: p.end,
    };
    if (isStr(p.focus)) phase.focus = p.focus;
    if (typeof p.weekly_load_target === 'number') phase.weekly_load_target = p.weekly_load_target;
    if (isStr(p.strength_emphasis)) phase.strength_emphasis = p.strength_emphasis;
    phases.push(phase);
  }
  return phases.length ? phases : undefined;
}

const TRIP_TYPES = new Set(['travel', 'rest', 'injury', 'other']);
function normalizeTrips(v: unknown): Trip[] | undefined {
  if (!Array.isArray(v)) return undefined;
  const trips: Trip[] = [];
  for (const item of v) {
    if (!item || typeof item !== 'object') continue;
    const t = item as Record<string, unknown>;
    if (!isStr(t.id) || !isStr(t.start) || !isStr(t.end)) continue;
    if (!YMD.test(t.start) || !YMD.test(t.end)) continue; // drop malformed dates
    const trip: Trip = {
      id: t.id,
      start: t.start,
      end: t.end,
      type: TRIP_TYPES.has(t.type as string) ? (t.type as TripType) : 'other',
    };
    // Default true: only an explicit `false` marks the range unavailable in
    // the M4 calendar projection (the conservative "they may still train" read).
    trip.can_train_light = t.can_train_light === false ? false : true;
    if (isStr(t.note)) trip.note = t.note;
    trips.push(trip);
  }
  return trips.length ? trips : undefined;
}

function normalizeStressModel(v: unknown): StressModel | undefined {
  if (!v || typeof v !== 'object' || Array.isArray(v)) return undefined;
  return v as StressModel; // freeform — the coach owns the semantics
}


/**
 * The ONLY place plan.meta is parsed. Never hand-parse meta elsewhere.
 * Tolerates null / invalid JSON / missing or malformed schedule and always
 * returns a well-formed PlanMeta with a complete weekday map. The authored
 * multisport fields are envelope-validated and omitted when absent/malformed.
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
    race: normalizeRace(obj.race),
    periodization: normalizePeriodization(obj.periodization),
    trips: normalizeTrips(obj.trips),
    stress_model: normalizeStressModel(obj.stress_model),
  };
}

/** Serialize meta back, with the schedule slotted in (preserving other keys). */
export function serializePlanMeta(meta: PlanMeta, schedule: WeeklySchedule): string {
  return JSON.stringify({ ...meta, schedule });
}
