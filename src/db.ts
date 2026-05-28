// Service layer: all D1 access goes through here so REST (now) and MCP
// (milestone b) share identical behavior. Timestamps are epoch-ms integers.
import type {
  ActivityRow,
  DayConflict,
  DayTemplateRow,
  EnrichedTemplateExercise,
  Env,
  ExternalActivityRow,
  ExternalEventRow,
  PlanMeta,
  PlanRow,
  PlanTree,
  ScheduleWeek,
  SessionRow,
  SetLogRow,
  TemplateExerciseRow,
  User,
  Weekday,
  WeeklySchedule,
} from './types';
import { WEEKDAYS, parsePlanMeta, serializePlanMeta } from './types';
import {
  fetchCompletedActivities,
  fetchPlannedEvents,
  pushStrengthActivity,
  type ActivityFetchDeps,
  type FetchDeps,
  type Fetcher,
} from './intervals';

const now = () => Date.now();
const uuid = () => crypto.randomUUID();

// ---- users ---------------------------------------------------------------

export async function upsertUser(
  db: D1Database,
  appleSub: string,
  email: string | null,
  displayName: string | null,
): Promise<User> {
  const existing = await db
    .prepare('SELECT * FROM users WHERE apple_sub = ?1')
    .bind(appleSub)
    .first<User>();
  if (existing) {
    if (displayName && !existing.display_name) {
      await db
        .prepare('UPDATE users SET display_name = ?2 WHERE id = ?1')
        .bind(existing.id, displayName)
        .run();
      existing.display_name = displayName;
    }
    return existing;
  }
  const user: User = {
    id: uuid(),
    apple_sub: appleSub,
    email,
    display_name: displayName,
    created_at: now(),
    timezone: null,
    intervals_api_key: null,
    intervals_athlete_id: null,
  };
  await db
    .prepare(
      'INSERT INTO users (id, apple_sub, email, display_name, created_at) VALUES (?1,?2,?3,?4,?5)',
    )
    .bind(user.id, user.apple_sub, user.email, user.display_name, user.created_at)
    .run();
  return user;
}

/**
 * Sign in with Apple owner resolution. Single-user invariant: there is
 * exactly one user row. If this Apple sub is unseen and the only existing
 * user is a bootstrap row (e.g. the MCP-created 'mcp-owner'), *claim* that
 * row — rebinding it to the real Apple identity — so MCP-seeded data and
 * iOS stay on one user_id. Otherwise create the first user.
 */
export async function claimOrCreateOwner(
  db: D1Database,
  appleSub: string,
  email: string | null,
  displayName: string | null,
  ownerSubLocked: boolean,
): Promise<User> {
  const byApple = await db
    .prepare('SELECT * FROM users WHERE apple_sub = ?1')
    .bind(appleSub)
    .first<User>();
  if (byApple) return byApple;

  if (!ownerSubLocked) {
    const all = await db.prepare('SELECT * FROM users').all<User>();
    if (all.results.length === 1) {
      const row = all.results[0]!;
      await db
        .prepare('UPDATE users SET apple_sub = ?2, email = ?3, display_name = ?4 WHERE id = ?1')
        .bind(row.id, appleSub, email ?? row.email, displayName ?? row.display_name)
        .run();
      return { ...row, apple_sub: appleSub, email: email ?? row.email, display_name: displayName ?? row.display_name };
    }
  }
  return upsertUser(db, appleSub, email, displayName);
}

/**
 * Resolve the single owner user for MCP calls. The MCP principal is "Claude
 * acting as the owner", not an end-user login — so it maps to the one user
 * row. If none exists yet (iOS app not built), bootstrap it so Claude can
 * start building a plan in chat before milestone (d).
 */
export async function ensureOwnerUser(
  db: D1Database,
  ownerAppleSub: string | undefined,
): Promise<User> {
  const existing = await db
    .prepare('SELECT * FROM users ORDER BY created_at LIMIT 1')
    .first<User>();
  if (existing) return existing;
  return upsertUser(db, ownerAppleSub ?? 'mcp-owner', null, 'Owner');
}

/** True if `tz` is a valid IANA timezone the runtime accepts. */
export function isValidTimezone(tz: string): boolean {
  try {
    new Intl.DateTimeFormat('en-CA', { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}

/**
 * Civil date (YYYY-MM-DD) "now" in the given IANA timezone. Falls back to
 * UTC when tz is null/invalid (the pre-0012 behavior). Uses formatToParts
 * to assemble the date locale-independently — never parses a formatted
 * string.
 */
export function todayInTz(tz: string | null | undefined): string {
  if (!tz || !isValidTimezone(tz)) {
    return new Date().toISOString().slice(0, 10);
  }
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: tz,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(new Date());
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? '';
  return `${get('year')}-${get('month')}-${get('day')}`;
}

/** The owner's stored IANA timezone, or null if none recorded yet. */
export async function getUserTimezone(
  db: D1Database,
  userId: string,
): Promise<string | null> {
  const row = await db
    .prepare('SELECT timezone FROM users WHERE id = ?1')
    .bind(userId)
    .first<{ timezone: string | null }>();
  return row?.timezone ?? null;
}

/**
 * Record the device's current IANA timezone on the user row when it differs
 * from what's stored. The iOS app reports it on each sync, so "today" on the
 * MCP side follows the user across time zones. Invalid/empty values are
 * ignored. Returns the effective stored value.
 */
export async function setUserTimezoneIfChanged(
  db: D1Database,
  userId: string,
  tz: string | null | undefined,
): Promise<void> {
  if (!tz || !isValidTimezone(tz)) return;
  const current = await getUserTimezone(db, userId);
  if (current === tz) return;
  await db.prepare('UPDATE users SET timezone = ?2 WHERE id = ?1').bind(userId, tz).run();
}

// ---- intervals.icu credentials (per-user; M1 multi-user foundation) ------

/** A user paired with their intervals.icu credentials (both required). */
export interface IntervalsUserCreds {
  user_id: string;
  api_key: string;
  athlete_id: string;
}

/**
 * Enumerate users who have BOTH intervals.icu credentials populated. Used by
 * sync* in src/index.ts (cron) and refresh_rides (MCP) to loop per user
 * — each user's events/activities tag to their own user_id, so a second
 * Apple sign-in can connect a separate intervals.icu athlete without
 * clobbering the owner's data.
 */
export async function listUsersWithIntervalsCreds(
  db: D1Database,
): Promise<IntervalsUserCreds[]> {
  const r = await db
    .prepare(
      `SELECT id, intervals_api_key, intervals_athlete_id
         FROM users
        WHERE intervals_api_key IS NOT NULL
          AND intervals_athlete_id IS NOT NULL`,
    )
    .all<{ id: string; intervals_api_key: string; intervals_athlete_id: string }>();
  return r.results.map((row) => ({
    user_id: row.id,
    api_key: row.intervals_api_key,
    athlete_id: row.intervals_athlete_id,
  }));
}

/** Read one user's intervals.icu credentials (nulls if either is unset). */
export async function getUserIntervalsCreds(
  db: D1Database,
  userId: string,
): Promise<{ api_key: string | null; athlete_id: string | null }> {
  const r = await db
    .prepare(
      `SELECT intervals_api_key AS api_key, intervals_athlete_id AS athlete_id
         FROM users WHERE id = ?1`,
    )
    .bind(userId)
    .first<{ api_key: string | null; athlete_id: string | null }>();
  return { api_key: r?.api_key ?? null, athlete_id: r?.athlete_id ?? null };
}

/**
 * Env → DB transition path. If NO user has intervals.icu credentials set
 * and the legacy Worker secrets are present, seed the OWNER user row
 * (the first row by created_at) from env exactly once. Idempotent: returns
 * the resulting per-user creds list, which on subsequent calls is just the
 * already-populated row.
 *
 * Rationale: a static SQL migration cannot read `wrangler secret`-managed
 * env vars, so 0016 added nullable columns and this code path does the
 * one-shot copy on the next sync after deploy. Calling this before each
 * sync is cheap (one SELECT + at most one UPDATE on first invocation).
 */
export async function seedOwnerIntervalsCredsFromEnv(
  db: D1Database,
  apiKey: string | null | undefined,
  athleteId: string | null | undefined,
): Promise<IntervalsUserCreds[]> {
  const existing = await listUsersWithIntervalsCreds(db);
  if (existing.length > 0) return existing;
  if (!apiKey || !athleteId) return existing;
  const owner = await db
    .prepare('SELECT id FROM users ORDER BY created_at LIMIT 1')
    .first<{ id: string }>();
  if (!owner) return existing;
  await db
    .prepare(
      `UPDATE users
          SET intervals_api_key = ?2,
              intervals_athlete_id = ?3
        WHERE id = ?1
          AND intervals_api_key IS NULL
          AND intervals_athlete_id IS NULL`,
    )
    .bind(owner.id, apiKey, athleteId)
    .run();
  return listUsersWithIntervalsCreds(db);
}

/**
 * Set/clear a user's intervals.icu credentials. Both columns move together
 * — passing null on EITHER clears the pair (disconnect). Returns the
 * resulting connection state. Audit is the caller's responsibility (the
 * REST handler writes an audit row tagged actor='ios').
 */
export async function setUserIntervalsCreds(
  db: D1Database,
  userId: string,
  apiKey: string | null,
  athleteId: string | null,
): Promise<{ connected: boolean }> {
  const connect = !!(apiKey && athleteId);
  await db
    .prepare(
      `UPDATE users
          SET intervals_api_key = ?2,
              intervals_athlete_id = ?3
        WHERE id = ?1`,
    )
    .bind(userId, connect ? apiKey : null, connect ? athleteId : null)
    .run();
  return { connected: connect };
}

// ---- plan tree -----------------------------------------------------------

export async function getActivePlan(
  db: D1Database,
  userId: string,
): Promise<PlanRow | null> {
  return db
    .prepare("SELECT * FROM plans WHERE user_id = ?1 AND status = 'active'")
    .bind(userId)
    .first<PlanRow>();
}

export async function getPlanTree(
  db: D1Database,
  userId: string,
): Promise<PlanTree | null> {
  const plan = await getActivePlan(db, userId);
  if (!plan) return null;
  const days = await db
    .prepare('SELECT * FROM day_templates WHERE plan_id = ?1 ORDER BY order_index, created_at, id')
    .bind(plan.id)
    .all<DayTemplateRow>();
  const dayIds = days.results.map((d) => d.id);
  let exercises: EnrichedTemplateExercise[] = [];
  if (dayIds.length) {
    const placeholders = dayIds.map((_, i) => `?${i + 1}`).join(',');
    const res = await db
      .prepare(
        `SELECT te.*, e.name AS exercise_name, e.unit AS exercise_unit,
                e.primary_muscle AS exercise_muscle, e.modality AS exercise_modality,
                e.laterality AS exercise_laterality, e.load_mode AS exercise_load_mode
         FROM template_exercises te
         JOIN exercises e ON e.id = te.exercise_id
         WHERE te.day_template_id IN (${placeholders}) ORDER BY te.order_index, te.created_at, te.id`,
      )
      .bind(...dayIds)
      .all<EnrichedTemplateExercise>();
    exercises = res.results;
  }
  return {
    ...plan,
    days: days.results.map((d) => ({
      ...d,
      exercises: exercises.filter((e) => e.day_template_id === d.id),
    })),
  };
}

export async function createPlan(
  db: D1Database,
  userId: string,
  name: string,
  meta: unknown = null,
): Promise<PlanRow> {
  const ts = now();
  const plan: PlanRow = {
    id: uuid(),
    user_id: userId,
    name,
    status: 'active',
    version: 1,
    meta: meta == null ? null : JSON.stringify(meta),
    created_at: ts,
    updated_at: ts,
  };
  // Archive any currently-active plan to honor the one-active-plan invariant.
  await db
    .prepare("UPDATE plans SET status = 'archived', updated_at = ?2 WHERE user_id = ?1 AND status = 'active'")
    .bind(userId, ts)
    .run();
  await db
    .prepare(
      'INSERT INTO plans (id,user_id,name,status,version,meta,created_at,updated_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8)',
    )
    .bind(plan.id, plan.user_id, plan.name, plan.status, plan.version, plan.meta, plan.created_at, plan.updated_at)
    .run();
  return plan;
}

/** Bump the plan version + updated_at. Called by every plan-tree mutation. */
export async function bumpPlanVersion(db: D1Database, planId: string): Promise<number> {
  const row = await db
    .prepare('UPDATE plans SET version = version + 1, updated_at = ?2 WHERE id = ?1 RETURNING version')
    .bind(planId, now())
    .first<{ version: number }>();
  return row?.version ?? 0;
}

export async function addDayTemplate(
  db: D1Database,
  planId: string,
  name: string,
  dayLabel: string | null,
  orderIndex: number,
): Promise<DayTemplateRow> {
  const ts = now();
  const row: DayTemplateRow = {
    id: uuid(),
    plan_id: planId,
    name,
    day_label: dayLabel,
    order_index: orderIndex,
    notes: null,
    created_at: ts,
    updated_at: ts,
  };
  await db
    .prepare(
      'INSERT INTO day_templates (id,plan_id,name,day_label,order_index,notes,created_at,updated_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8)',
    )
    .bind(row.id, row.plan_id, row.name, row.day_label, row.order_index, row.notes, row.created_at, row.updated_at)
    .run();
  await bumpPlanVersion(db, planId);
  return row;
}

/** Allowlist of patch keys accepted by `patchDayTemplate`. Unknown keys
 *  surface as `{ error: 'unknown_fields', fields }` — same diagnosability
 *  contract as updateExercise. */
const DAY_TEMPLATE_PATCH_KEYS = new Set<string>([
  'name',
  'day_label',
  'order_index',
  'notes',
]);

export async function patchDayTemplate(
  db: D1Database,
  planId: string,
  dayId: string,
  patch: {
    name?: string;
    day_label?: string | null;
    order_index?: number;
    notes?: string | null;
  },
): Promise<DayTemplateRow | { error: 'unknown_fields'; fields: string[] } | null> {
  const existing = await db
    .prepare('SELECT * FROM day_templates WHERE id = ?1 AND plan_id = ?2')
    .bind(dayId, planId)
    .first<DayTemplateRow>();
  if (!existing) return null;
  const unknown = Object.keys(patch).filter((k) => !DAY_TEMPLATE_PATCH_KEYS.has(k));
  if (unknown.length > 0) return { error: 'unknown_fields', fields: unknown };
  const merged = {
    name: patch.name ?? existing.name,
    day_label: patch.day_label === undefined ? existing.day_label : patch.day_label,
    order_index: patch.order_index ?? existing.order_index,
    notes: patch.notes === undefined ? existing.notes : patch.notes,
  };
  await db
    .prepare('UPDATE day_templates SET name=?2, day_label=?3, order_index=?4, notes=?5, updated_at=?6 WHERE id=?1')
    .bind(dayId, merged.name, merged.day_label, merged.order_index, merged.notes, now())
    .run();
  await bumpPlanVersion(db, planId);
  return { ...existing, ...merged, updated_at: now() };
}

/**
 * Next `order_index` for an append to a day — max existing + 1, or 0 if
 * the day has no exercises yet. Callers should use this when no explicit
 * order_index is given, instead of defaulting to a sentinel like 99
 * (which silently stranded every after-creation `add_exercise` at the
 * bottom; agent-facing P0 in the bug report).
 */
export async function nextExerciseOrderIndex(
  db: D1Database,
  dayTemplateId: string,
): Promise<number> {
  const row = await db
    .prepare('SELECT COALESCE(MAX(order_index), -1) AS m FROM template_exercises WHERE day_template_id = ?1')
    .bind(dayTemplateId)
    .first<{ m: number }>();
  return (row?.m ?? -1) + 1;
}

/**
 * Collapse duplicate `order_index` values within one day to a dense,
 * deterministic 0..n-1 sequence. No-op when indices are already unique, so
 * it's cheap to call defensively after any write that takes an explicit
 * order_index (add_exercise / update_exercise). Returns true if it rewrote.
 *
 * `preferId` is the slot the caller just placed at an explicit index. To
 * honor that destination exactly (in BOTH directions — moving up or down),
 * we rebuild the order by removing that slot, densely ordering the rest by
 * (order_index, created_at, id), then re-inserting the slot at its requested
 * index (clamped). A tiebreak alone is insufficient: it works for upward
 * moves but a downward move (e.g. 0 → 2) would land one short after the
 * dense pass.
 */
export async function dedupeDayOrderIndexes(
  db: D1Database,
  dayTemplateId: string,
  preferId?: string,
): Promise<boolean> {
  const rows = await db
    .prepare(
      'SELECT id, order_index FROM template_exercises WHERE day_template_id = ?1 ORDER BY order_index, created_at, id',
    )
    .bind(dayTemplateId)
    .all<{ id: string; order_index: number }>();
  const list = rows.results;
  const hasDup = new Set(list.map((r) => r.order_index)).size !== list.length;
  if (!hasDup) return false;

  let ordered: { id: string; order_index: number }[];
  const moved = preferId ? list.find((r) => r.id === preferId) : undefined;
  if (moved) {
    // Requested destination = the index the caller just set on this slot.
    // Drop it, then splice it back at that position so siblings shift around
    // it — landing the moved slot exactly there for up- and down-moves alike.
    const others = list.filter((r) => r.id !== moved.id);
    const target = Math.max(0, Math.min(moved.order_index, others.length));
    ordered = [...others.slice(0, target), moved, ...others.slice(target)];
  } else {
    ordered = list;
  }

  const ts = now();
  for (let i = 0; i < ordered.length; i++) {
    if (ordered[i]!.order_index !== i) {
      await db
        .prepare('UPDATE template_exercises SET order_index = ?2, updated_at = ?3 WHERE id = ?1')
        .bind(ordered[i]!.id, i, ts)
        .run();
    }
  }
  return true;
}

/** Sibling of `nextExerciseOrderIndex` for `day_templates` — append a new
 *  day densely instead of the old 99 sentinel that `add_day` used. */
export async function nextDayOrderIndex(
  db: D1Database,
  planId: string,
): Promise<number> {
  const row = await db
    .prepare('SELECT COALESCE(MAX(order_index), -1) AS m FROM day_templates WHERE plan_id = ?1')
    .bind(planId)
    .first<{ m: number }>();
  return (row?.m ?? -1) + 1;
}

export async function addTemplateExercise(
  db: D1Database,
  planId: string,
  input: Omit<TemplateExerciseRow, 'id' | 'created_at' | 'updated_at'>,
): Promise<TemplateExerciseRow> {
  const ts = now();
  const row: TemplateExerciseRow = { ...input, id: uuid(), created_at: ts, updated_at: ts };
  await db
    .prepare(
      `INSERT INTO template_exercises
       (id,day_template_id,exercise_id,order_index,target_sets,target_reps,target_reps_max,target_rpe,rest_seconds,target_weight,target_duration_s,progression,cues,created_at,updated_at)
       VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15)`,
    )
    .bind(
      row.id, row.day_template_id, row.exercise_id, row.order_index, row.target_sets,
      row.target_reps, row.target_reps_max, row.target_rpe, row.rest_seconds,
      row.target_weight, row.target_duration_s, row.progression, row.cues, row.created_at, row.updated_at,
    )
    .run();
  // An explicit order_index can collide with a sibling; densify so the day
  // never holds duplicate indices (non-deterministic display otherwise).
  if (await dedupeDayOrderIndexes(db, row.day_template_id, row.id)) {
    const fresh = await db
      .prepare('SELECT order_index FROM template_exercises WHERE id = ?1')
      .bind(row.id)
      .first<{ order_index: number }>();
    if (fresh) row.order_index = fresh.order_index;
  }
  await bumpPlanVersion(db, planId);
  return row;
}

// ---- exercise resolver ---------------------------------------------------

/**
 * Discoverable exercise catalog read for agents — closes the agent-facing
 * "exercise vocabulary is closed and undiscoverable" P1 in the bug report.
 * Optional filters: case-insensitive substring `query` (matches `name`),
 * exact `muscle` (matches `primary_muscle`), exact `modality`. Returns a
 * compact projection ordered by name.
 */
export async function getExercises(
  db: D1Database,
  filters: { query?: string; muscle?: string; modality?: string } = {},
): Promise<
  {
    id: string;
    name: string;
    primary_muscle: string;
    modality: string;
    unit: string;
    laterality: string;
    load_mode: string;
  }[]
> {
  const where: string[] = [];
  const binds: (string | number)[] = [];
  if (filters.query && filters.query.trim() !== '') {
    binds.push(`%${filters.query.trim().toLowerCase()}%`);
    where.push(`lower(name) LIKE ?${binds.length}`);
  }
  if (filters.muscle && filters.muscle.trim() !== '') {
    binds.push(filters.muscle.trim().toLowerCase());
    where.push(`lower(primary_muscle) = ?${binds.length}`);
  }
  if (filters.modality && filters.modality.trim() !== '') {
    binds.push(filters.modality.trim().toLowerCase());
    where.push(`lower(modality) = ?${binds.length}`);
  }
  const sql =
    'SELECT id, name, primary_muscle, modality, unit, laterality, load_mode FROM exercises' +
    (where.length ? ' WHERE ' + where.join(' AND ') : '') +
    ' ORDER BY name';
  const stmt = db.prepare(sql);
  const bound = binds.length === 0 ? stmt : stmt.bind(...binds);
  const r = await bound.all<{
    id: string;
    name: string;
    primary_muscle: string;
    modality: string;
    unit: string;
    laterality: string;
    load_mode: string;
  }>();
  return r.results;
}

/** Resolve an id, exact name, or alias to an exercise row. */
export async function resolveExercise(db: D1Database, nameOrId: string) {
  const q = nameOrId.trim().toLowerCase();
  return db
    .prepare(
      'SELECT * FROM exercises WHERE id = ?1 OR lower(name) = ?2 OR lower(aliases) LIKE ?3 LIMIT 1',
    )
    .bind(nameOrId, q, `%"${q}"%`)
    .first();
}

// ---- sessions + sets -----------------------------------------------------

export async function getOrCreateSession(
  db: D1Database,
  userId: string,
  planId: string,
  date: string,
  dayTemplateId: string | null,
): Promise<SessionRow> {
  const existing = await db
    .prepare('SELECT * FROM sessions WHERE user_id = ?1 AND date = ?2 ORDER BY created_at LIMIT 1')
    .bind(userId, date)
    .first<SessionRow>();
  if (existing && existing.status !== 'discarded') return existing;
  if (existing) {
    // The (user,date) row exists but was DISCARDED. "Discarded" means
    // "this never happened" — so a fresh get/start for the same date must
    // RESURRECT it to a clean planned state rather than hand back the
    // tombstone (which would leave the day un-startable: the start path
    // only promotes 'planned'→'in_progress'). We keep the same row id
    // (the (user,date) idempotency key) but wipe it back to pristine. Its
    // old set_logs stay soft-deleted (they belong to the thrown-away
    // attempt); new work logs fresh rows.
    const ts = now();
    const revived: SessionRow = {
      ...existing,
      day_template_id: dayTemplateId,
      status: 'planned',
      started_at: null,
      completed_at: null,
      perceived_fatigue: null,
      notes: null,
      updated_at: ts,
    };
    await db
      .prepare(
        'UPDATE sessions SET day_template_id=?2, status=?3, started_at=?4, completed_at=?5, perceived_fatigue=?6, notes=?7, updated_at=?8 WHERE id=?1',
      )
      .bind(revived.id, revived.day_template_id, revived.status, null, null, null, null, ts)
      .run();
    return revived;
  }
  const ts = now();
  const s: SessionRow = {
    id: uuid(),
    user_id: userId,
    plan_id: planId,
    day_template_id: dayTemplateId,
    date,
    status: 'planned',
    started_at: null,
    completed_at: null,
    perceived_fatigue: null,
    notes: null,
    created_at: ts,
    updated_at: ts,
  };
  await db
    .prepare(
      'INSERT INTO sessions (id,user_id,plan_id,day_template_id,date,status,started_at,completed_at,perceived_fatigue,notes,created_at,updated_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)',
    )
    .bind(s.id, s.user_id, s.plan_id, s.day_template_id, s.date, s.status, s.started_at, s.completed_at, s.perceived_fatigue, s.notes, s.created_at, s.updated_at)
    .run();
  return s;
}

export async function patchSession(
  db: D1Database,
  userId: string,
  sessionId: string,
  // `status` is `unknown`: the PATCH body is NOT runtime-validated, so a
  // client can send a number/null/bool/object/array here. Typing it
  // honestly forces the type-guard below.
  patch: { status?: unknown; perceived_fatigue?: number; notes?: string },
): Promise<
  | SessionRow
  | null
  | { error: 'session_already_started'; status: 'in_progress' | 'completed' }
  | { error: 'invalid_status'; status: unknown }
> {
  const s = await db
    .prepare('SELECT * FROM sessions WHERE id = ?1 AND user_id = ?2')
    .bind(sessionId, userId)
    .first<SessionRow>();
  if (!s) return null;
  // Type-guard BEFORE normalizing: a present-but-non-string `status`
  // (e.g. {"status":123|null|true|{}|[]}) must be treated exactly like an
  // invalid status — return the invalid_status arm (→ HTTP 400), never
  // call .trim() on a non-string (that was a 500-causing regression),
  // never persist, never reach the burial guard. Key absent / undefined
  // → field-only patch, unchanged. Only a string proceeds to normalize.
  if (patch.status !== undefined && typeof patch.status !== 'string') {
    return { error: 'invalid_status', status: patch.status };
  }
  // Normalize the incoming status ONCE (trim + lowercase) so casing /
  // whitespace cannot bypass the skipped-guard ({"status":"  SKIPPED "})
  // and so the value compared here is the value persisted below — a
  // non-canonical status can never silently corrupt the row.
  const normalizedStatus =
    patch.status === undefined ? undefined : patch.status.trim().toLowerCase();
  // Validate against the closed status set BEFORE the burial guard and
  // BEFORE any write: an unknown status (e.g. "junk") is rejected, never
  // persisted. A field-only patch (no `status` key) skips this entirely.
  // This is app-layer validation (no DB CHECK / migration) and is what
  // makes the "can never silently corrupt the row" guarantee true.
  if (
    normalizedStatus !== undefined &&
    normalizedStatus !== 'planned' &&
    normalizedStatus !== 'in_progress' &&
    normalizedStatus !== 'completed' &&
    normalizedStatus !== 'skipped'
  ) {
    return { error: 'invalid_status', status: normalizedStatus };
  }
  // History-integrity guard (REST sibling of FIX2's skipPlannedSession
  // guard): a `skipped` patch must not bury a started/finished workout.
  // Setting an in_progress/completed session to 'skipped' would render it
  // skipped on the calendar/agenda and hide its logged set_logs. Reject
  // and leave the row + its sets untouched — same rejection shape as
  // skipPlannedSession. Other status transitions and non-status patches
  // are unchanged.
  if (
    normalizedStatus === 'skipped' &&
    (s.status === 'in_progress' || s.status === 'completed')
  ) {
    return {
      error: 'session_already_started',
      status: s.status as 'in_progress' | 'completed',
    };
  }
  const status = normalizedStatus ?? s.status;
  const fatigue = patch.perceived_fatigue ?? s.perceived_fatigue;
  const notes = patch.notes ?? s.notes;
  const completedAt = status === 'completed' ? s.completed_at ?? now() : s.completed_at;
  const startedAt = status === 'in_progress' ? s.started_at ?? now() : s.started_at;
  await db
    .prepare('UPDATE sessions SET status=?2, perceived_fatigue=?3, notes=?4, started_at=?5, completed_at=?6, updated_at=?7 WHERE id=?1')
    .bind(sessionId, status, fatigue, notes, startedAt, completedAt, now())
    .run();
  return { ...s, status, perceived_fatigue: fatigue, notes, started_at: startedAt, completed_at: completedAt };
}

/**
 * Discard a session — the sanctioned escape hatch for "I started/ended a
 * workout I didn't really do." This is the ONE place allowed to override
 * the history-integrity burial guard in patchSession/skipPlannedSession,
 * and it earns that by being EXPLICIT and non-silent: it soft-deletes the
 * session's set_logs (so logged work is intentionally thrown away, never
 * hidden) and marks the session 'discarded'. A discarded session VANISHES
 * from the calendar projection (see projectCalendar's discarded carve-out)
 * and its now-soft-deleted sets drop out of history/volume/e1RM (those
 * already filter deleted_at IS NULL) and out of ride-conflict lift dates
 * (derived from the projection). The only session-row reads needing an
 * explicit `status != 'discarded'` filter are getRecentSessions and
 * getSessionByDate (the MCP coach reads) — both already carry it.
 *
 * Idempotent AND side-effect-free on repeat: an already-discarded session
 * short-circuits before any write (no redundant audit row). Reversible-
 * by-restart:
 * getOrCreateSession resurrects a discarded (user,date) row to a pristine
 * 'planned' state, so discarding never wedges a date.
 *
 * Returns null if no such session for this user (caller → 404).
 */
export async function discardSession(
  db: D1Database,
  userId: string,
  sessionId: string,
): Promise<SessionRow | null> {
  const s = await db
    .prepare('SELECT * FROM sessions WHERE id = ?1 AND user_id = ?2')
    .bind(sessionId, userId)
    .first<SessionRow>();
  if (!s) return null;
  // Already discarded → true no-op: skip the (no-op) UPDATEs AND the audit
  // write, so a double-tap / retry can't inflate audit_log (which feeds
  // Claude's coaching context).
  if (s.status === 'discarded') return s;
  const ts = now();
  const live = await db
    .prepare('SELECT COUNT(*) AS n FROM set_logs WHERE session_id = ?1 AND deleted_at IS NULL')
    .bind(sessionId)
    .first<{ n: number }>();
  const discardedSets = live?.n ?? 0;
  await db
    .prepare('UPDATE set_logs SET deleted_at = ?2 WHERE session_id = ?1 AND deleted_at IS NULL')
    .bind(sessionId, ts)
    .run();
  await db
    .prepare("UPDATE sessions SET status = 'discarded', updated_at = ?2 WHERE id = ?1")
    .bind(sessionId, ts)
    .run();
  await writeAudit(
    db,
    userId,
    'discard_session',
    { session_id: sessionId, date: s.date, prior_status: s.status, sets_discarded: discardedSets },
    `discarded:${discardedSets}_sets`,
  );
  return { ...s, status: 'discarded', updated_at: ts };
}

/** Idempotent on the client-generated `id` (offline-safe; retries are no-ops). */
export async function logSet(
  db: D1Database,
  userId: string,
  input: {
    id: string;
    session_id: string;
    exercise_id: string;
    template_exercise_id?: string | null;
    set_index: number;
    weight: number;
    reps: number;
    rpe?: number | null;
    is_warmup?: boolean;
    notes?: string | null;
    logged_at?: number;
    duration_s?: number | null;
    source: 'ios' | 'mcp';
  },
): Promise<{ set: SetLogRow; deduped: boolean }> {
  // Guard: the session must belong to this user.
  const sess = await db
    .prepare('SELECT id FROM sessions WHERE id = ?1 AND user_id = ?2')
    .bind(input.session_id, userId)
    .first();
  if (!sess) throw new Error('session_not_found');

  const existing = await db
    .prepare('SELECT * FROM set_logs WHERE id = ?1')
    .bind(input.id)
    .first<SetLogRow>();
  if (existing) return { set: existing, deduped: true };

  // Collision-safe set_index. MCP and iOS each compute set_index
  // independently, so two writers could pick the same index for the same
  // (session, exercise, is_warmup) — the bug that produced two set_index=3
  // squat sets. Renumber on collision: keep the provided index unless a live
  // row already holds it, in which case bump to max+1. The partial unique
  // index ux_set_slot (migration 0013) is the hard backstop for races.
  const isWarmupInt = input.is_warmup ? 1 : 0;
  let setIndex = input.set_index;
  const clash = await db
    .prepare(
      `SELECT 1 FROM set_logs
       WHERE session_id = ?1 AND exercise_id = ?2 AND set_index = ?3
         AND is_warmup = ?4 AND deleted_at IS NULL LIMIT 1`,
    )
    .bind(input.session_id, input.exercise_id, setIndex, isWarmupInt)
    .first();
  if (clash) {
    const max = await db
      .prepare(
        `SELECT COALESCE(MAX(set_index), 0) AS m FROM set_logs
         WHERE session_id = ?1 AND exercise_id = ?2 AND is_warmup = ?3
           AND deleted_at IS NULL`,
      )
      .bind(input.session_id, input.exercise_id, isWarmupInt)
      .first<{ m: number }>();
    setIndex = (max?.m ?? 0) + 1;
  }

  const row: SetLogRow = {
    id: input.id,
    session_id: input.session_id,
    exercise_id: input.exercise_id,
    template_exercise_id: input.template_exercise_id ?? null,
    set_index: setIndex,
    weight: input.weight,
    reps: input.reps,
    rpe: input.rpe ?? null,
    is_warmup: isWarmupInt,
    notes: input.notes ?? null,
    logged_at: input.logged_at ?? now(),
    source: input.source,
    duration_s: input.duration_s ?? null,
    deleted_at: null,
  };
  // The pre-check above resolves the common collision, but two concurrent
  // writers can both pass it and then race on the INSERT — only the unique
  // index ux_set_slot catches that. Honor the "renumber, don't reject"
  // contract: on a slot-unique violation, recompute max+1 and retry rather
  // than letting one writer's set be dropped. ON CONFLICT(id) DO NOTHING
  // still covers a concurrent same-id retry (idempotency).
  const insert = () =>
    db
      .prepare(
        `INSERT INTO set_logs
         (id,session_id,exercise_id,template_exercise_id,set_index,weight,reps,rpe,is_warmup,notes,logged_at,source,duration_s,deleted_at)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,NULL)
         ON CONFLICT(id) DO NOTHING`,
      )
      .bind(
        row.id, row.session_id, row.exercise_id, row.template_exercise_id, row.set_index,
        row.weight, row.reps, row.rpe, row.is_warmup, row.notes, row.logged_at, row.source,
        row.duration_s,
      )
      .run();
  for (let attempt = 0; ; attempt++) {
    try {
      await insert();
      break;
    } catch (e) {
      const msg = String((e as Error)?.message ?? '');
      const slotConflict = /unique constraint failed/i.test(msg) && /set_index/i.test(msg);
      if (!slotConflict || attempt >= 5) throw e;
      const max = await db
        .prepare(
          `SELECT COALESCE(MAX(set_index), 0) AS m FROM set_logs
           WHERE session_id = ?1 AND exercise_id = ?2 AND is_warmup = ?3
             AND deleted_at IS NULL`,
        )
        .bind(input.session_id, input.exercise_id, isWarmupInt)
        .first<{ m: number }>();
      row.set_index = (max?.m ?? 0) + 1;
    }
  }
  // Logging a set implicitly starts the session. A 'discarded' row is
  // also revived here (defense-in-depth: getOrCreateSession already
  // resurrects on the get path, but logging work into a discarded session
  // must never leave the new set stranded under an invisible/vanished
  // row). started_at resets off the COALESCE for a revived discard so the
  // sRPE duration reflects the new attempt, not the thrown-away one.
  await db
    .prepare("UPDATE sessions SET status = CASE WHEN status IN ('planned','discarded') THEN 'in_progress' ELSE status END, started_at = CASE WHEN status='discarded' THEN ?2 ELSE COALESCE(started_at, ?2) END, updated_at = ?2 WHERE id = ?1")
    .bind(input.session_id, now())
    .run();
  return { set: row, deduped: false };
}

/**
 * Most recent live set across ALL sources for (user, exercise, weight, reps,
 * is_warmup) within a sliding window (default 120s). Used by the MCP log_set
 * path to refuse phantom dupes when iOS just logged the same work; REST
 * writes from iOS are not gated by this (their idempotency is the row UUID).
 */
export async function findRecentMatchingSet(
  db: D1Database,
  userId: string,
  args: {
    exercise_id: string;
    weight: number;
    reps: number;
    is_warmup: boolean;
    within_ms?: number;
  },
): Promise<SetLogRow | null> {
  const since = now() - (args.within_ms ?? 120_000);
  const row = await db
    .prepare(
      `SELECT sl.* FROM set_logs sl
       JOIN sessions s ON s.id = sl.session_id
       WHERE s.user_id = ?1
         AND sl.exercise_id = ?2
         AND sl.weight = ?3
         AND sl.reps = ?4
         AND sl.is_warmup = ?5
         AND sl.deleted_at IS NULL
         AND sl.logged_at >= ?6
       ORDER BY sl.logged_at DESC LIMIT 1`,
    )
    .bind(userId, args.exercise_id, args.weight, args.reps, args.is_warmup ? 1 : 0, since)
    .first<SetLogRow>();
  return row ?? null;
}

export async function patchSet(
  db: D1Database,
  userId: string,
  setId: string,
  patch: { weight?: number; reps?: number; rpe?: number | null; notes?: string | null; deleted?: boolean },
): Promise<SetLogRow | null> {
  const row = await db
    .prepare(
      `SELECT sl.* FROM set_logs sl JOIN sessions s ON s.id = sl.session_id
       WHERE sl.id = ?1 AND s.user_id = ?2`,
    )
    .bind(setId, userId)
    .first<SetLogRow>();
  if (!row) return null;
  const weight = patch.weight ?? row.weight;
  const reps = patch.reps ?? row.reps;
  const rpe = patch.rpe === undefined ? row.rpe : patch.rpe;
  const notes = patch.notes === undefined ? row.notes : patch.notes;
  // WARNING: this soft-delete is INVISIBLE to an incremental `sets_since`
  // client — the getState sets query gates on the immutable `logged_at`,
  // not deleted_at (see the WARNING on that query). Only safe while the
  // iOS client full-reloads; needs a mutable updated_at cursor (follow-up).
  const deletedAt = patch.deleted ? row.deleted_at ?? now() : patch.deleted === false ? null : row.deleted_at;
  // Undelete collision: the partial unique index ux_set_slot only covers
  // live rows, so reviving a soft-deleted set whose slot was reused while it
  // was gone would violate the constraint (→ 500). Renumber the revived row
  // to max+1 before clearing deleted_at — same "renumber, don't reject"
  // contract logSet uses.
  let setIndex = row.set_index;
  const isUndelete = row.deleted_at !== null && deletedAt === null;
  if (isUndelete) {
    const clash = await db
      .prepare(
        `SELECT 1 FROM set_logs
         WHERE session_id = ?1 AND exercise_id = ?2 AND set_index = ?3
           AND is_warmup = ?4 AND deleted_at IS NULL AND id != ?5 LIMIT 1`,
      )
      .bind(row.session_id, row.exercise_id, setIndex, row.is_warmup, setId)
      .first();
    if (clash) {
      const max = await db
        .prepare(
          `SELECT COALESCE(MAX(set_index), 0) AS m FROM set_logs
           WHERE session_id = ?1 AND exercise_id = ?2 AND is_warmup = ?3
             AND deleted_at IS NULL`,
        )
        .bind(row.session_id, row.exercise_id, row.is_warmup)
        .first<{ m: number }>();
      setIndex = (max?.m ?? 0) + 1;
    }
  }
  // The clash pre-check above narrows the common case, but a concurrent
  // undelete/logSet can still race onto the same slot and trip ux_set_slot.
  // Retry-renumber on conflict (same contract as logSet) so an undelete is
  // never a 500. Non-undelete patches keep their set_index, so they never
  // conflict and the loop runs once.
  for (let attempt = 0; ; attempt++) {
    try {
      await db
        .prepare('UPDATE set_logs SET weight=?2, reps=?3, rpe=?4, notes=?5, deleted_at=?6, set_index=?7 WHERE id=?1')
        .bind(setId, weight, reps, rpe, notes, deletedAt, setIndex)
        .run();
      break;
    } catch (e) {
      const msg = String((e as Error)?.message ?? '');
      const slotConflict = /unique constraint failed/i.test(msg) && /set_index/i.test(msg);
      if (!slotConflict || attempt >= 5) throw e;
      const max = await db
        .prepare(
          `SELECT COALESCE(MAX(set_index), 0) AS m FROM set_logs
           WHERE session_id = ?1 AND exercise_id = ?2 AND is_warmup = ?3
             AND deleted_at IS NULL`,
        )
        .bind(row.session_id, row.exercise_id, row.is_warmup)
        .first<{ m: number }>();
      setIndex = (max?.m ?? 0) + 1;
    }
  }
  // Phantom-session guard. Logging a set promotes a session 'planned' ->
  // 'in_progress' (see logSet). Deleting the LAST live set must do the
  // inverse: an 'in_progress' session with zero live sets records no work,
  // yet without this it lingers as a stale "in progress" row that the
  // calendar/agenda (and MCP get_today_workout) still surface. Revert it to
  // 'planned' and clear started_at so EVERY client — app, REST, MCP — agrees
  // the day is simply the upcoming workout again. Fires only on a real
  // live->deleted transition (undeletes / field-only edits never touch
  // status), and only for 'in_progress' (a 'completed' session is NOT
  // auto-un-completed — that's a deliberate terminal state).
  const isDelete = row.deleted_at === null && deletedAt !== null;
  if (isDelete) {
    const remaining = await db
      .prepare('SELECT COUNT(*) AS c FROM set_logs WHERE session_id = ?1 AND deleted_at IS NULL')
      .bind(row.session_id)
      .first<{ c: number }>();
    if ((remaining?.c ?? 0) === 0) {
      await db
        .prepare(
          "UPDATE sessions SET status = 'planned', started_at = NULL, updated_at = ?2 WHERE id = ?1 AND status = 'in_progress'",
        )
        .bind(row.session_id, now())
        .run();
    }
  }
  return { ...row, weight, reps, rpe, notes, deleted_at: deletedAt, set_index: setIndex };
}

// ---- read models ---------------------------------------------------------

export async function getState(
  db: D1Database,
  userId: string,
  sincePlanVersion: number,
  setsSince: number,
  eventsSince = 0,
  activitiesSince = 0,
  logSince = 0,
) {
  const plan = await getActivePlan(db, userId);
  const baseTree =
    plan && plan.version > sincePlanVersion ? await getPlanTree(db, userId) : null;
  // The weekly schedule rides the existing plan-tree sync: it is only
  // returned when the tree is (i.e. when plans.version advanced past the
  // client cursor). Parsed via the single meta accessor so iOS never
  // hand-parses meta. Null when nothing changed — no new endpoint.
  const tree = baseTree
    ? { ...baseTree, schedule: parsePlanMeta(baseTree.meta).schedule }
    : null;
  const sessions = await db
    .prepare('SELECT * FROM sessions WHERE user_id = ?1 AND updated_at > ?2 ORDER BY date')
    .bind(userId, setsSince)
    .all<SessionRow>();
  // WARNING: `logged_at` is an IMMUTABLE incremental cursor — a set
  // soft-deleted (deleted_at set) AFTER a client's watermark passed its
  // logged_at is NEVER delivered incrementally (FIX3-class tombstone gap,
  // like external_events). Only safe because the current iOS client
  // full-reloads (sets_since=0). An incremental client needs a mutable
  // set_logs `updated_at` cursor — tracked follow-up; see patchSet.
  const sets = await db
    .prepare(
      `SELECT sl.* FROM set_logs sl JOIN sessions s ON s.id = sl.session_id
       WHERE s.user_id = ?1 AND sl.logged_at > ?2 ORDER BY sl.logged_at`,
    )
    .bind(userId, setsSince)
    .all<SetLogRow>();
  // external_events ride a SEPARATE watermark (synced_at epoch-ms). This is
  // a server-owned reconciled cache: NOT gated on plans.version and a ride
  // sync NEVER bumps it. TWO explicit modes (iOS must match):
  //
  //  - FULL RELOAD  (events_since absent OR 0): return the full CURRENT set
  //    of NON-deleted external_events. The full-reload path does a full
  //    replace (DESIGN §7, same as since=0/sets_since=0) so the server must
  //    NOT hand it tombstones — there is nothing to reconcile them against.
  //  - INCREMENTAL  (events_since > 0): return every row touched since the
  //    cursor INCLUDING soft-deleted ones (deleted_at set), so a syncing
  //    client learns about removals and drops them — exactly the set_logs
  //    delta+tombstone pattern.
  const events =
    eventsSince > 0
      ? await db
          .prepare(
            'SELECT * FROM external_events WHERE user_id = ?1 AND synced_at > ?2 ORDER BY synced_at',
          )
          .bind(userId, eventsSince)
          .all<ExternalEventRow>()
      : await db
          .prepare(
            'SELECT * FROM external_events WHERE user_id = ?1 AND deleted_at IS NULL ORDER BY synced_at',
          )
          .bind(userId)
          .all<ExternalEventRow>();
  // external_activities ride their OWN watermark (activities_since), exactly
  // like external_events: a separate server-owned reconciled cache (COMPLETED
  // endurance actuals), never gated on plans.version. Same two modes:
  //  - FULL RELOAD  (activities_since absent/0): full current non-deleted set
  //    (full replace on the client — no tombstones to reconcile).
  //  - INCREMENTAL  (activities_since > 0): every row touched since the cursor
  //    INCLUDING soft-deleted ones, so a syncing client learns about removals.
  const activities =
    activitiesSince > 0
      ? await db
          .prepare(
            'SELECT * FROM external_activities WHERE user_id = ?1 AND synced_at > ?2 ORDER BY synced_at',
          )
          .bind(userId, activitiesSince)
          .all<ExternalActivityRow>()
      : await db
          .prepare(
            'SELECT * FROM external_activities WHERE user_id = ?1 AND deleted_at IS NULL ORDER BY date',
          )
          .bind(userId)
          .all<ExternalActivityRow>();
  // Generic activity log (M3 — `activities` table). Append-only,
  // user-authored. Same delta-sync pattern as set_logs / external_events:
  //  - FULL RELOAD  (log_since absent/0): full current non-deleted set.
  //  - INCREMENTAL  (log_since > 0): every row touched since the cursor
  //    INCLUDING soft-deleted ones, so a syncing client learns about
  //    removals. Uses `logged_at` as the cursor for inserts and
  //    `deleted_at` to surface tombstones past the cursor (see
  //    listActivitiesForUser for the delta-sync contract).
  const userActivities =
    logSince > 0
      ? await listActivitiesForUser(db, userId, logSince)
      : (
          await db
            .prepare(
              'SELECT * FROM activities WHERE user_id = ?1 AND deleted_at IS NULL ORDER BY logged_at',
            )
            .bind(userId)
            .all<ActivityRow>()
        ).results;
  return {
    plan: tree,
    plan_version: plan?.version ?? 0,
    sessions: sessions.results,
    sets: sets.results,
    external_events: events.results,
    external_activities: activities.results,
    activities: userActivities,
    server_time: now(),
  };
}

export async function getInProgressSession(
  db: D1Database,
  userId: string,
): Promise<SessionRow | null> {
  return db
    .prepare(
      "SELECT * FROM sessions WHERE user_id = ?1 AND status = 'in_progress' ORDER BY updated_at DESC LIMIT 1",
    )
    .bind(userId)
    .first<SessionRow>();
}

export async function getSetsForSession(db: D1Database, sessionId: string) {
  const r = await db
    .prepare(
      'SELECT * FROM set_logs WHERE session_id = ?1 AND deleted_at IS NULL ORDER BY logged_at',
    )
    .bind(sessionId)
    .all<SetLogRow>();
  return r.results;
}

export async function getRecentSessions(
  db: D1Database,
  userId: string,
  n: number,
): Promise<SessionRow[]> {
  // Exclude 'discarded' — a thrown-away session is not "recent training"
  // and must not surface as last_session in the coach brief / today
  // context. (Visual calendar surfaces vanish it via the projection;
  // set-based reads via deleted_at. This is the one session-list read
  // that needs an explicit filter.)
  const r = await db
    .prepare("SELECT * FROM sessions WHERE user_id = ?1 AND status != 'discarded' ORDER BY date DESC LIMIT ?2")
    .bind(userId, n)
    .all<SessionRow>();
  return r.results;
}

/**
 * Most recent COMPLETED session, optionally excluding a date (usually
 * today). Coaching context wants "the last real training session" — a
 * skipped/planned row in between (status != 'completed') should not obscure
 * it. Distinct from getRecentSessions, which returns the latest row of any
 * non-discarded status.
 */
export async function getLastCompletedSession(
  db: D1Database,
  userId: string,
  excludeDate?: string,
): Promise<SessionRow | null> {
  return db
    .prepare(
      "SELECT * FROM sessions WHERE user_id = ?1 AND status = 'completed' AND date != ?2 ORDER BY date DESC LIMIT 1",
    )
    .bind(userId, excludeDate ?? '')
    .first<SessionRow>();
}

export async function getSessionByDate(
  db: D1Database,
  userId: string,
  date: string,
): Promise<SessionRow | null> {
  // Excludes 'discarded': a thrown-away session must read as "no session
  // on this date" for the MCP coach reads that call this (get_today_workout,
  // get_session_log) — same vanish semantics the calendar projection
  // applies. Revival/discard never route through here (getOrCreateSession
  // has its own query; discardSession takes a session id), so filtering is
  // safe.
  return db
    .prepare("SELECT * FROM sessions WHERE user_id = ?1 AND date = ?2 AND status != 'discarded' ORDER BY created_at LIMIT 1")
    .bind(userId, date)
    .first<SessionRow>();
}

// ---- notes + audit -------------------------------------------------------

export async function writeNote(
  db: D1Database,
  userId: string,
  scope: string,
  refId: string | null,
  author: 'claude' | 'nick',
  body: string,
): Promise<void> {
  await db
    .prepare(
      'INSERT INTO notes (id,user_id,scope,ref_id,author,body,created_at) VALUES (?1,?2,?3,?4,?5,?6,?7)',
    )
    .bind(uuid(), userId, scope, refId, author, body, now())
    .run();
}

export async function writeAudit(
  db: D1Database,
  userId: string,
  tool: string,
  args: unknown,
  result: string,
  actor: string = 'mcp',
): Promise<void> {
  await db
    .prepare(
      'INSERT INTO audit_log (id,user_id,actor,tool,args,result,created_at) VALUES (?1,?2,?3,?4,?5,?6,?7)',
    )
    .bind(uuid(), userId, actor, tool, JSON.stringify(args).slice(0, 4000), result.slice(0, 500), now())
    .run();
}

// ---- generic activity log (M3 — append-only, user-authored) --------------
//
// The "everything else" bucket alongside strength sessions (set_logs) and
// intervals.icu actuals (external_activities). Same consistency model as
// set_logs:
//   - `id` is the CLIENT-generated UUID idempotency key (iOS outbox safe-
//     retries land on ON CONFLICT(id) DO NOTHING). MCP-source rows mint the
//     id server-side because Claude doesn't retry like the iOS outbox.
//   - Rows are SOFT-deleted only (deleted_at) — preserve history.
//   - Writes do NOT bump plans.version.

export interface ActivityInput {
  id: string;
  date: string;
  type: string;
  title?: string | null;
  duration_minutes?: number | null;
  notes?: string | null;
  logged_at?: number;
}

/**
 * Idempotent on the client-generated `id`. A retry of the same id is a
 * no-op (returns the existing row). The user_id is stamped from the
 * authenticated caller, never trusted from the client body.
 */
export async function logActivity(
  db: D1Database,
  userId: string,
  input: ActivityInput,
  source: 'ios' | 'mcp',
): Promise<ActivityRow> {
  const loggedAt = input.logged_at ?? now();
  await db
    .prepare(
      `INSERT INTO activities
         (id,user_id,date,type,title,duration_minutes,notes,logged_at,source,deleted_at)
       VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,NULL)
       ON CONFLICT(id) DO NOTHING`,
    )
    .bind(
      input.id,
      userId,
      input.date,
      input.type,
      input.title ?? null,
      input.duration_minutes ?? null,
      input.notes ?? null,
      loggedAt,
      source,
    )
    .run();
  // Re-select so retries return the *original* persisted row (preserving the
  // original logged_at/title/etc.), not the fresh-looking input.
  const row = await db
    .prepare('SELECT * FROM activities WHERE id = ?1 AND user_id = ?2')
    .bind(input.id, userId)
    .first<ActivityRow>();
  if (!row) {
    // Either the user_id mismatched (an id collision across users — should
    // be impossible for UUIDs, but we surface it rather than silently
    // returning a stale row from another user) or the insert failed
    // mysteriously. Either way the caller needs to see this.
    throw new Error('activity_insert_failed');
  }
  return row;
}

/**
 * Soft-delete by id, scoped to the caller's user. Returns true on success,
 * false if the row doesn't exist or belongs to another user — REST surfaces
 * both as 404 (don't leak existence of other users' rows). Idempotent:
 * deleting an already-deleted row returns false (the row still exists but
 * the second call is a no-op delete).
 */
export async function softDeleteActivity(
  db: D1Database,
  userId: string,
  activityId: string,
): Promise<boolean> {
  const ts = now();
  const r = await db
    .prepare(
      `UPDATE activities SET deleted_at = ?3
       WHERE id = ?1 AND user_id = ?2 AND deleted_at IS NULL`,
    )
    .bind(activityId, userId, ts)
    .run();
  // D1 exposes meta.changes; fall back to 0 if absent.
  const changes = (r as { meta?: { changes?: number } }).meta?.changes ?? 0;
  return changes > 0;
}

/**
 * Delta-sync read for /api/state. Returns every row TOUCHED since the
 * cursor — both fresh inserts (logged_at > since) AND tombstones
 * (deleted_at > since), so a syncing client can apply removals. Same
 * pattern as the set_logs sync described in DESIGN.md §7. Ordered by
 * logged_at so the client can advance its watermark monotonically.
 */
export async function listActivitiesForUser(
  db: D1Database,
  userId: string,
  sinceMs: number,
  limit?: number,
): Promise<ActivityRow[]> {
  const cap = typeof limit === 'number' && limit > 0 ? Math.min(limit, 1000) : 1000;
  const rows = await db
    .prepare(
      `SELECT * FROM activities
       WHERE user_id = ?1
         AND (logged_at > ?2 OR (deleted_at IS NOT NULL AND deleted_at > ?2))
       ORDER BY logged_at
       LIMIT ?3`,
    )
    .bind(userId, sinceMs, cap)
    .all<ActivityRow>();
  return rows.results;
}

// ---- plan-tree mutations (MCP write tools) -------------------------------

interface ExerciseInput {
  exercise: string;
  order_index?: number;
  target_sets: number;
  target_reps: number;
  target_reps_max?: number | null;
  target_rpe?: number | null;
  rest_seconds?: number;
  target_weight?: number | null;
  /** Planned hold seconds for timed slots (mirrors set_logs.duration_s).
   *  NULL/omitted → conventional reps slot. */
  target_duration_s?: number | null;
  progression?: unknown;
  cues?: string | null;
}

async function resolveOrThrow(db: D1Database, name: string): Promise<string> {
  const ex = await resolveExercise(db, name);
  if (!ex) throw new Error(`unknown_exercise:${name}`);
  return (ex as { id: string }).id;
}

/**
 * Transactional full-plan upsert with optimistic concurrency. If
 * expectedVersion is given and stale, returns a conflict (Claude refetches
 * and reapplies — DESIGN.md §7). Replaces the day/exercise tree atomically.
 */
export async function updatePlanTree(
  db: D1Database,
  userId: string,
  input: {
    name?: string;
    meta?: unknown;
    expected_version?: number | null;
    days: {
      day_label?: string | null;
      name: string;
      order_index?: number;
      notes?: string | null;
      exercises?: ExerciseInput[];
    }[];
  },
): Promise<
  | { conflict: true; current_version: number }
  | { conflict: false; plan: PlanTree }
  | { error: 'unknown_exercise'; queries: string[]; query: string }
> {
  let plan = await getActivePlan(db, userId);
  if (!plan) plan = await createPlan(db, userId, input.name ?? 'My Plan', input.meta ?? null);
  if (
    input.expected_version != null &&
    input.expected_version !== plan.version
  ) {
    return { conflict: true, current_version: plan.version };
  }

  // Resolve every exercise name up front, collecting EVERY unresolved
  // name into `queries` instead of aborting on the first miss — a 16-
  // exercise plan with two typos previously took two round trips
  // (fail-fix-retry-fail-fix-retry). Now the agent fixes them in one
  // pass. `query` is kept (= first unknown) for back-compat with the
  // structured shape introduced in PR #12. Use list_exercises to
  // discover valid catalog names.
  const resolved = new Map<string, string>();
  const unknown: string[] = [];
  const seenUnknown = new Set<string>();
  for (const d of input.days) {
    for (const e of d.exercises ?? []) {
      if (typeof e.exercise !== 'string' || e.exercise.trim() === '') {
        if (!seenUnknown.has('<missing>')) {
          seenUnknown.add('<missing>');
          unknown.push('<missing>');
        }
        continue;
      }
      if (resolved.has(e.exercise) || seenUnknown.has(e.exercise)) continue;
      const ex = await resolveExercise(db, e.exercise);
      if (!ex) {
        seenUnknown.add(e.exercise);
        unknown.push(e.exercise);
        continue;
      }
      resolved.set(e.exercise, (ex as { id: string }).id);
    }
  }
  if (unknown.length > 0) {
    return { error: 'unknown_exercise', queries: unknown, query: unknown[0]! };
  }

  // Capture the OLD day identity (id → name/label) before the rebuild so we
  // can re-point surviving schedule weekdays at the NEW day id whose
  // name/label matches. Without this, every update_plan (e.g. "add a
  // deadlift day") would silently wipe the entire weekly schedule because
  // rebuilt days get fresh UUIDs.
  const oldDays = await db
    .prepare('SELECT id, name, day_label FROM day_templates WHERE plan_id = ?1')
    .bind(plan.id)
    .all<{ id: string; name: string; day_label: string | null }>();
  const oldById = new Map<string, { name: string; day_label: string | null }>();
  for (const od of oldDays.results) {
    oldById.set(od.id, { name: od.name, day_label: od.day_label });
  }

  const ts = now();
  // Generate new day ids up-front so the schedule remap can reference them.
  const newDayIds = input.days.map(() => uuid());
  // Match old→new day identity by day_label first (the stable handle), then
  // by name. First writer wins on a duplicate (schedule holds one id/slot).
  const newIdByLabel = new Map<string, string>();
  const newIdByName = new Map<string, string>();
  input.days.forEach((d, i) => {
    const id = newDayIds[i]!;
    if (d.day_label != null) {
      const lk = d.day_label.toLowerCase();
      if (!newIdByLabel.has(lk)) newIdByLabel.set(lk, id);
    }
    const nk = d.name.toLowerCase();
    if (!newIdByName.has(nk)) newIdByName.set(nk, id);
  });

  // FK-safe rebuild: sessions.day_template_id and set_logs.template_exercise_id
  // reference rows we're about to DELETE. With no ON DELETE clause on those
  // FKs (schema 0001), a strict-FK delete fails the moment any real session
  // or logged set points at a day_template/template_exercise that's being
  // rebuilt — the agent-facing bug report's P0. The fix is a pre-DELETE
  // REMAP: for every old → new (matched by day_label/name, then by
  // exercise_id within the matched day), repoint the referencing rows at
  // the NEW id; for genuinely-removed old rows, NULL out the reference
  // (history preserved, plan-tree pointer detached). All in the same D1
  // batch so it's atomic with the rebuild.

  // Pre-generate new template_exercise ids so the remap can target them
  // (the old code uuid()'d inline during INSERT — replaced below). Keyed
  // by (newDayId, exercise_id); a duplicate-within-day collapses to the
  // first occurrence's id for remap purposes (the inserted rows still get
  // distinct ids per occurrence — see the inserter below).
  const newTeIdByDayAndEx = new Map<string, string>();
  const teIdPerExerciseOccurrence: string[][] = input.days.map((d) =>
    (d.exercises ?? []).map(() => uuid()),
  );
  input.days.forEach((d, di) => {
    const dayId = newDayIds[di]!;
    (d.exercises ?? []).forEach((e, ei) => {
      const exId = resolved.get(e.exercise)!;
      const key = `${dayId}:${exId}`;
      if (!newTeIdByDayAndEx.has(key)) {
        newTeIdByDayAndEx.set(key, teIdPerExerciseOccurrence[di]![ei]!);
      }
    });
  });

  // Build old → new remaps (null = removed; reference must NULL out).
  const oldToNewDay = new Map<string, string | null>();
  for (const od of oldDays.results) {
    const lk = od.day_label?.toLowerCase();
    const nk = od.name.toLowerCase();
    const newId = (lk != null ? newIdByLabel.get(lk) : undefined) ?? newIdByName.get(nk) ?? null;
    oldToNewDay.set(od.id, newId);
  }
  const oldTeRows = await db
    .prepare(
      `SELECT te.id, te.day_template_id, te.exercise_id
         FROM template_exercises te
         JOIN day_templates d ON d.id = te.day_template_id
        WHERE d.plan_id = ?1`,
    )
    .bind(plan.id)
    .all<{ id: string; day_template_id: string; exercise_id: string }>();
  const oldToNewTe = new Map<string, string | null>();
  for (const ot of oldTeRows.results) {
    const newDayId = oldToNewDay.get(ot.day_template_id) ?? null;
    if (newDayId == null) {
      oldToNewTe.set(ot.id, null);
    } else {
      const newTeId = newTeIdByDayAndEx.get(`${newDayId}:${ot.exercise_id}`) ?? null;
      oldToNewTe.set(ot.id, newTeId);
    }
  }

  // FK-safe order: INSERT new rows FIRST (so the remap can point at real
  // parents), then UPDATE refs old→new (or NULL for removed), then DELETE
  // the now-orphaned old rows by EXPLICIT id (not by plan_id sweep —
  // that'd catch the freshly-inserted new rows too). The original DELETE-
  // before-INSERT order failed FK the moment any real session or set_log
  // referenced a row being deleted.
  const stmts: D1PreparedStatement[] = [];
  // 1) INSERT new day_templates (parents) — coexist with old by id.
  input.days.forEach((d, di) => {
    const dayId = newDayIds[di]!;
    stmts.push(
      db
        .prepare(
          'INSERT INTO day_templates (id,plan_id,name,day_label,order_index,notes,created_at,updated_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8)',
        )
        .bind(dayId, plan!.id, d.name, d.day_label ?? null, d.order_index ?? di, d.notes ?? null, ts, ts),
    );
  });
  // 2) INSERT new template_exercises (children of step 1's parents).
  input.days.forEach((d, di) => {
    const dayId = newDayIds[di]!;
    (d.exercises ?? []).forEach((e, ei) => {
      stmts.push(
        db
          .prepare(
            `INSERT INTO template_exercises
             (id,day_template_id,exercise_id,order_index,target_sets,target_reps,target_reps_max,target_rpe,rest_seconds,target_weight,target_duration_s,progression,cues,created_at,updated_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15)`,
          )
          .bind(
            teIdPerExerciseOccurrence[di]![ei]!, dayId, resolved.get(e.exercise)!, e.order_index ?? ei, e.target_sets,
            e.target_reps, e.target_reps_max ?? null, e.target_rpe ?? null, e.rest_seconds ?? 120,
            e.target_weight ?? null, e.target_duration_s ?? null,
            e.progression == null ? null : JSON.stringify(e.progression),
            e.cues ?? null, ts, ts,
          ),
      );
    });
  });
  // 3) Remap session.day_template_id: old → new (surviving) or NULL.
  for (const [oldDayId, newDayId] of oldToNewDay.entries()) {
    if (newDayId != null) {
      stmts.push(
        db
          .prepare('UPDATE sessions SET day_template_id = ?2 WHERE day_template_id = ?1')
          .bind(oldDayId, newDayId),
      );
    } else {
      stmts.push(
        db
          .prepare('UPDATE sessions SET day_template_id = NULL WHERE day_template_id = ?1')
          .bind(oldDayId),
      );
    }
  }
  // 4) Remap set_logs.template_exercise_id (same scheme).
  for (const [oldTeId, newTeId] of oldToNewTe.entries()) {
    if (newTeId != null) {
      stmts.push(
        db
          .prepare('UPDATE set_logs SET template_exercise_id = ?2 WHERE template_exercise_id = ?1')
          .bind(oldTeId, newTeId),
      );
    } else {
      stmts.push(
        db
          .prepare('UPDATE set_logs SET template_exercise_id = NULL WHERE template_exercise_id = ?1')
          .bind(oldTeId),
      );
    }
  }
  // 5) DELETE old template_exercises by EXPLICIT id (avoid catching the
  //    freshly-inserted new rows that now share plan_id). Children first.
  for (const ot of oldTeRows.results) {
    stmts.push(db.prepare('DELETE FROM template_exercises WHERE id = ?1').bind(ot.id));
  }
  // 6) DELETE old day_templates by EXPLICIT id. Parents last.
  for (const od of oldDays.results) {
    stmts.push(db.prepare('DELETE FROM day_templates WHERE id = ?1').bind(od.id));
  }
  // The full tree is rebuilt with fresh day UUIDs. Re-point each schedule
  // weekday at the NEW day whose name/label matches the OLD day it pointed
  // at; weekdays whose day genuinely no longer exists (no matching new day)
  // are cleared. Same batch ⇒ shares the single version bump. Never lose
  // the schedule key.
  // baseMeta ALWAYS starts from the EXISTING persisted plan.meta so the
  // user's recurring schedule survives a metadata-only update_plan. An
  // incoming `meta` is MERGED over it (incoming keys win). The existing
  // meta.schedule is PRESERVED unless the incoming meta explicitly carries
  // its own `schedule` key — only then does that replace it (and it still
  // rides the day-name/label remap below). Passing NO meta is unchanged.
  const existingMeta = parsePlanMeta(plan.meta);
  const incomingMetaRaw =
    input.meta !== undefined &&
    input.meta !== null &&
    typeof input.meta === 'object' &&
    !Array.isArray(input.meta)
      ? (input.meta as Record<string, unknown>)
      : undefined;
  const incomingHasSchedule =
    incomingMetaRaw !== undefined &&
    Object.prototype.hasOwnProperty.call(incomingMetaRaw, 'schedule');
  // Merge: existing meta is the base; incoming non-schedule keys overlay it.
  // The schedule is decided explicitly below so a schedule-less incoming
  // meta cannot erase the persisted one.
  const mergedMeta: PlanMeta = parsePlanMeta(
    JSON.stringify({
      ...existingMeta,
      ...(input.meta === undefined ? {} : input.meta ?? {}),
      schedule: incomingHasSchedule
        ? (incomingMetaRaw as Record<string, unknown>).schedule
        : existingMeta.schedule,
    }),
  );
  const baseMeta = mergedMeta;
  const remappedWeek = { ...baseMeta.schedule.week };
  for (const wd of WEEKDAYS) {
    const oldId = remappedWeek[wd];
    if (oldId == null) continue;
    const old = oldById.get(oldId);
    let newId: string | undefined;
    if (old) {
      if (old.day_label != null) newId = newIdByLabel.get(old.day_label.toLowerCase());
      if (!newId) newId = newIdByName.get(old.name.toLowerCase());
    }
    remappedWeek[wd] = newId ?? null;
  }
  const remappedSchedule: WeeklySchedule = {
    version: baseMeta.schedule.version,
    week: remappedWeek,
  };
  stmts.push(
    db
      .prepare(
        'UPDATE plans SET name = ?2, meta = ?3, version = version + 1, updated_at = ?4 WHERE id = ?1',
      )
      .bind(
        plan.id,
        input.name ?? plan.name,
        serializePlanMeta(baseMeta, remappedSchedule),
        ts,
      ),
  );
  await db.batch(stmts);
  return { conflict: false, plan: (await getPlanTree(db, userId))! };
}

/** Find a template_exercise slot by id, or by (day + exercise name/id). */
async function findSlot(
  db: D1Database,
  userId: string,
  ref: { template_exercise_id?: string; day?: string; exercise?: string },
): Promise<TemplateExerciseRow | null> {
  if (ref.template_exercise_id) {
    return db
      .prepare(
        `SELECT te.* FROM template_exercises te
         JOIN day_templates d ON d.id = te.day_template_id
         JOIN plans p ON p.id = d.plan_id
         WHERE te.id = ?1 AND p.user_id = ?2`,
      )
      .bind(ref.template_exercise_id, userId)
      .first<TemplateExerciseRow>();
  }
  if (!ref.day || !ref.exercise) return null;
  const exId = await resolveOrThrow(db, ref.exercise);
  return db
    .prepare(
      `SELECT te.* FROM template_exercises te
       JOIN day_templates d ON d.id = te.day_template_id
       JOIN plans p ON p.id = d.plan_id
       WHERE p.user_id = ?1 AND te.exercise_id = ?2 AND p.status = 'active'
         AND (d.day_label = ?3 OR d.name = ?3)`,
    )
    .bind(userId, exId, ref.day)
    .first<TemplateExerciseRow>();
}

/** Allowlist of patch keys accepted by `updateExercise`. Any unknown key
 *  in the incoming patch returns an explicit `unknown_fields` error
 *  instead of being silently dropped (the agent-facing diagnosability bug
 *  — `orderIndex` camelCase had returned 200 OK with no change). */
const TEMPLATE_EXERCISE_PATCH_KEYS = new Set<string>([
  'target_sets',
  'target_reps',
  'target_reps_max',
  'target_rpe',
  'rest_seconds',
  'target_weight',
  'target_duration_s',
  'cues',
  'progression',
  'order_index',
]);

export async function updateExercise(
  db: D1Database,
  userId: string,
  ref: { template_exercise_id?: string; day?: string; exercise?: string },
  patch: Partial<
    Pick<
      TemplateExerciseRow,
      | 'target_sets'
      | 'target_reps'
      | 'target_reps_max'
      | 'target_rpe'
      | 'rest_seconds'
      | 'target_weight'
      | 'target_duration_s'
      | 'cues'
      | 'order_index'
    >
  > & { progression?: unknown },
): Promise<TemplateExerciseRow | { error: 'unknown_fields'; fields: string[] } | null> {
  // Slot lookup first so a wrong ref returns the more actionable
  // `slot_not_found` (via null) before unknown_fields. A double-mistake
  // call gets the higher-priority diagnostic.
  const slot = await findSlot(db, userId, ref);
  if (!slot) return null;
  const unknown = Object.keys(patch).filter((k) => !TEMPLATE_EXERCISE_PATCH_KEYS.has(k));
  if (unknown.length > 0) return { error: 'unknown_fields', fields: unknown };
  const m: TemplateExerciseRow = {
    ...slot,
    target_sets: patch.target_sets ?? slot.target_sets,
    target_reps: patch.target_reps ?? slot.target_reps,
    target_reps_max:
      patch.target_reps_max === undefined ? slot.target_reps_max : patch.target_reps_max,
    target_rpe: patch.target_rpe === undefined ? slot.target_rpe : patch.target_rpe,
    rest_seconds: patch.rest_seconds ?? slot.rest_seconds,
    target_weight:
      patch.target_weight === undefined ? slot.target_weight : patch.target_weight,
    target_duration_s:
      patch.target_duration_s === undefined ? slot.target_duration_s : patch.target_duration_s,
    cues: patch.cues === undefined ? slot.cues : patch.cues,
    order_index: patch.order_index === undefined ? slot.order_index : patch.order_index,
    progression:
      patch.progression === undefined
        ? slot.progression
        : patch.progression == null
          ? null
          : JSON.stringify(patch.progression),
    updated_at: now(),
  };
  await db
    .prepare(
      `UPDATE template_exercises SET target_sets=?2,target_reps=?3,target_reps_max=?4,
       target_rpe=?5,rest_seconds=?6,target_weight=?7,target_duration_s=?8,cues=?9,progression=?10,order_index=?11,updated_at=?12
       WHERE id=?1`,
    )
    .bind(
      slot.id, m.target_sets, m.target_reps, m.target_reps_max, m.target_rpe,
      m.rest_seconds, m.target_weight, m.target_duration_s, m.cues, m.progression, m.order_index, m.updated_at,
    )
    .run();
  // Patching order_index can collide with a sibling; densify the day so the
  // result has unique 0..n-1 indices honoring the requested position.
  if (patch.order_index !== undefined && (await dedupeDayOrderIndexes(db, slot.day_template_id, slot.id))) {
    const fresh = await db
      .prepare('SELECT order_index FROM template_exercises WHERE id = ?1')
      .bind(slot.id)
      .first<{ order_index: number }>();
    if (fresh) m.order_index = fresh.order_index;
  }
  await bumpPlanVersionByDay(db, slot.day_template_id);
  return m;
}

/**
 * Delete an exercise slot from a day. Resolves the slot by id or by
 * `(day, exercise)` — same ref shape as updateExercise. NULLs any
 * `set_logs.template_exercise_id` that pointed at this slot so historical
 * sets are detached (not deleted — they stay queryable by exercise_id).
 * Bumps the plan version (it's a plan-tree mutation). Returns the deleted
 * row or null when no slot matches.
 */
export async function deleteTemplateExercise(
  db: D1Database,
  userId: string,
  ref: { template_exercise_id?: string; day?: string; exercise?: string },
): Promise<TemplateExerciseRow | null> {
  const slot = await findSlot(db, userId, ref);
  if (!slot) return null;
  await db
    .batch([
      db
        .prepare('UPDATE set_logs SET template_exercise_id = NULL WHERE template_exercise_id = ?1')
        .bind(slot.id),
      db.prepare('DELETE FROM template_exercises WHERE id = ?1').bind(slot.id),
    ]);
  await bumpPlanVersionByDay(db, slot.day_template_id);
  return slot;
}

export async function swapExercise(
  db: D1Database,
  userId: string,
  ref: { day: string; from_exercise: string; to_exercise: string; carry_targets?: boolean },
): Promise<TemplateExerciseRow | null> {
  const slot = await findSlot(db, userId, { day: ref.day, exercise: ref.from_exercise });
  if (!slot) return null;
  const toId = await resolveOrThrow(db, ref.to_exercise);
  await db
    .prepare('UPDATE template_exercises SET exercise_id=?2, updated_at=?3 WHERE id=?1')
    .bind(slot.id, toId, now())
    .run();
  await bumpPlanVersionByDay(db, slot.day_template_id);
  return { ...slot, exercise_id: toId, updated_at: now() };
}

async function bumpPlanVersionByDay(db: D1Database, dayTemplateId: string): Promise<void> {
  const row = await db
    .prepare('SELECT plan_id FROM day_templates WHERE id = ?1')
    .bind(dayTemplateId)
    .first<{ plan_id: string }>();
  if (row) await bumpPlanVersion(db, row.plan_id);
}

export async function logWorkoutComplete(
  db: D1Database,
  userId: string,
  date: string,
  perceivedFatigue: number | null,
  notes: string | null,
): Promise<SessionRow | null> {
  const plan = await getActivePlan(db, userId);
  if (!plan) return null;
  const session = await getOrCreateSession(db, userId, plan.id, date, null);
  const r = await patchSession(db, userId, session.id, {
    status: 'completed',
    perceived_fatigue: perceivedFatigue ?? undefined,
    notes: notes ?? undefined,
  });
  // logWorkoutComplete ALWAYS passes status:'completed', which is a valid
  // status and never the skipped-burial case — so neither patchSession
  // rejection arm ('invalid_status' / 'session_already_started') is
  // reachable here. Fail LOUD rather than silently return null if that
  // ever changes (e.g. the guard's scope is widened beyond 'skipped').
  if (r && 'error' in r) {
    throw new Error(
      `unreachable: patchSession returned ${r.error} on the status:'completed' path — guard scope changed`,
    );
  }
  return r;
}

// ---- one-way lifting-load export to intervals.icu (Option C) ------------
//
// This whole block is its OWN concern: a best-effort, decoupled, one-way
// EXPORT. It never bumps plans.version, never touches the plan tree or the
// append-only log, and an intervals.icu failure must never fail/block/throw
// into log_workout_complete.

/**
 * sRPE-load calibration knob: `load = round(sessionRPE * durationMin * K)`.
 *
 * This is a TUNABLE calibration constant, NOT a correctness value — it only
 * scales the absolute number to sit on a TSS-comparable axis in
 * intervals.icu. Adjust it to taste; nothing in this codebase depends on
 * its exact value.
 */
export const SRPE_LOAD_K = 0.2;

/** Session-RPE fallback when neither perceived_fatigue nor set RPE exist.
 *  Documented ESTIMATE: a "moderately hard" session on the 1-10 scale. */
export const SRPE_FALLBACK_RPE = 7;

/** Duration is clamped to this minute window before the load formula. */
export const SRPE_MIN_MINUTES = 20;
export const SRPE_MAX_MINUTES = 180;

export interface SessionLoad {
  /** Final integer load to push as icu_training_load. */
  load: number;
  /** Resolved session-RPE (1-10) and which source produced it. */
  sessionRpe: number;
  rpeSource: 'perceived_fatigue' | 'weighted_set_rpe' | 'fallback';
  /** Clamped duration in minutes / raw seconds (for the activity payload). */
  durationMin: number;
  durationSec: number;
}

/**
 * PURE sRPE load model (no I/O). Locked design:
 *   load = round(sessionRPE * durationMin * K)
 *
 * sessionRPE priority:
 *   1. session.perceived_fatigue (1-10) if set
 *   2. else load-weighted mean of NON-warmup set RPE
 *      (weight = weight*reps; sets without RPE are excluded)
 *   3. else SRPE_FALLBACK_RPE (documented estimate)
 *
 * duration = (completed_at - started_at) → minutes, clamped to
 * [SRPE_MIN_MINUTES, SRPE_MAX_MINUTES]. If started/completed are missing
 * the duration is treated as 0 then clamped up to the floor.
 *
 * Returns `null` when the session has NO non-warmup sets → caller SKIPS
 * the export entirely (a no-op, NOT a load of 0).
 */
export function computeSessionLoad(
  session: Pick<SessionRow, 'perceived_fatigue' | 'started_at' | 'completed_at'>,
  sets: Pick<SetLogRow, 'weight' | 'reps' | 'rpe' | 'is_warmup' | 'deleted_at'>[],
): SessionLoad | null {
  const working = sets.filter((s) => !s.is_warmup && s.deleted_at == null);
  // No non-warmup work → nothing to export. Skip, do not push load 0.
  if (working.length === 0) return null;

  let sessionRpe: number;
  let rpeSource: SessionLoad['rpeSource'];
  if (
    session.perceived_fatigue != null &&
    Number.isFinite(session.perceived_fatigue)
  ) {
    sessionRpe = session.perceived_fatigue;
    rpeSource = 'perceived_fatigue';
  } else {
    // Load-weighted mean of non-warmup set RPE; weight = weight*reps.
    let wSum = 0;
    let wRpe = 0;
    for (const s of working) {
      if (s.rpe == null || !Number.isFinite(s.rpe)) continue;
      const w = Math.max(0, s.weight) * Math.max(0, s.reps);
      // A bodyweight/zero-volume set still counts (min weight 1) so its
      // RPE is not silently dropped.
      const ww = w > 0 ? w : 1;
      wSum += ww;
      wRpe += ww * s.rpe;
    }
    if (wSum > 0) {
      sessionRpe = wRpe / wSum;
      rpeSource = 'weighted_set_rpe';
    } else {
      sessionRpe = SRPE_FALLBACK_RPE;
      rpeSource = 'fallback';
    }
  }

  const rawMs =
    session.started_at != null && session.completed_at != null
      ? session.completed_at - session.started_at
      : 0;
  const rawMin = rawMs > 0 ? rawMs / 60_000 : 0;
  const durationMin = Math.min(
    SRPE_MAX_MINUTES,
    Math.max(SRPE_MIN_MINUTES, rawMin),
  );

  const load = Math.round(sessionRpe * durationMin * SRPE_LOAD_K);
  return {
    load,
    sessionRpe,
    rpeSource,
    durationMin,
    durationSec: Math.round(durationMin * 60),
  };
}

interface LoadExportRow {
  session_id: string;
  intervals_ref: string | null;
  load: number | null;
  status: string;
  attempts: number;
  updated_at: number;
}

export interface ExportDeps {
  /** Injected in tests so the suite never hits the network. */
  fetcher?: Fetcher;
  timeoutMs?: number;
  /**
   * Override the in-flight staleness window (ms). Defaults to
   * IN_FLIGHT_STALE_MS. Tests set this (e.g. 0) to deterministically
   * exercise the crashed-in_flight reclaim path without sleeping 15 min;
   * production never sets it.
   */
  staleMs?: number;
}

/**
 * An `in_flight` ledger row older than this (epoch-ms age) is treated as a
 * crashed/abandoned export and is eligible for cron retry, so a process
 * that died mid-push cannot wedge a session forever. 15 min comfortably
 * exceeds the export's worst-case wall time (a couple of ~10s intervals
 * round-trips) while still recovering quickly.
 */
export const IN_FLIGHT_STALE_MS = 15 * 60_000;

/**
 * Best-effort, one-way push of a completed session's sRPE load into
 * intervals.icu.
 *
 * GUARANTEES (architecture, non-negotiable):
 *  - NEVER bumps plans.version; NEVER touches the plan tree / sessions /
 *    set_logs. Only writes its own `session_load_exports` row + audit_log.
 *  - Idempotent, keyed by session_id: re-running for the same session
 *    UPSERTs the SAME row and (via the stored intervals_ref) UPDATEs the
 *    SAME intervals.icu activity — never a duplicate.
 *  - This function does not throw for an intervals failure (returns a
 *    status). Callers in the sacred log_workout_complete path additionally
 *    wrap it so even an unexpected throw cannot propagate.
 *
 * Returns the resolved status; 'skipped' means no non-warmup work (no-op).
 */
export async function exportSessionLoad(
  db: D1Database,
  env: Env,
  userId: string,
  sessionId: string,
  deps: ExportDeps = {},
): Promise<{ status: 'ok' | 'pending' | 'skipped' | 'disabled'; load?: number }> {
  const session = await db
    .prepare('SELECT * FROM sessions WHERE id = ?1 AND user_id = ?2')
    .bind(sessionId, userId)
    .first<SessionRow>();
  if (!session) return { status: 'skipped' };

  const sets = await getSetsForSession(db, sessionId);
  const computed = computeSessionLoad(session, sets);

  // No non-warmup work → skip export ENTIRELY (no row write, no push).
  if (!computed) {
    await writeAudit(db, userId, 'export_session_load', { session_id: sessionId }, 'skipped:no_working_sets');
    return { status: 'skipped' };
  }

  // Non-null aliases (TS can't carry the `session`/`computed` guards above
  // into the nested putUpdateKnownRef closure defined later).
  const sessionRow = session;
  const computedLoad = computed;

  // Per-user intervals.icu credentials (M1). Fall back to legacy env vars so
  // a not-yet-migrated owner row still exports; the first sync after deploy
  // seeds the columns from env via seedOwnerIntervalsCredsFromEnv.
  const userCreds = await getUserIntervalsCreds(db, userId);
  const apiKey = userCreds.api_key ?? env.INTERVALS_ICU_API_KEY;
  const athleteId = userCreds.athlete_id ?? env.INTERVALS_ICU_ATHLETE_ID;

  // Day name for a friendly activity title.
  let dayName = 'Lifting';
  if (session.day_template_id) {
    const dt = await db
      .prepare('SELECT name, day_label FROM day_templates WHERE id = ?1')
      .bind(session.day_template_id)
      .first<{ name: string; day_label: string | null }>();
    if (dt) dayName = dt.day_label || dt.name || dayName;
  }
  const name = `Lift: ${dayName}`;

  // ---- PER-SESSION SINGLE-FLIGHT (concurrency guard) -------------------
  //
  // The offline-first iOS client can fire two log_workout_complete requests
  // for the SAME session concurrently (retry-on-timeout while the first is
  // still in-flight) → two waitUntil exports racing. Without serialization
  // both read prior=null, both GET (neither sees the other yet), both POST
  // → a duplicate intervals.icu event with NO cleanup path. The D1 PK
  // dedupes the ledger ROW but not the remote calls.
  //
  // The ledger row is the mutex. Two atomic claim attempts BEFORE any
  // network I/O; `meta.changes === 1` on either ⇒ this caller won and is
  // the ONLY one allowed to GET/POST/PUT-create this session's event:
  //  (a) INSERT a fresh `in_flight` sentinel (first-ever export); or
  //  (b) transition an existing RETRYABLE row (pending / disabled /
  //      STALE in_flight from a crashed run) to `in_flight`.
  // A live in_flight owned by a concurrent export, or a terminal `ok`,
  // matches neither → this caller defers (no remote create).
  const claimTs = now();
  const ins = await db
    .prepare(
      `INSERT INTO session_load_exports
         (session_id,intervals_ref,load,status,attempts,updated_at)
       VALUES (?1,NULL,?2,'in_flight',0,?3)
       ON CONFLICT(session_id) DO NOTHING`,
    )
    .bind(sessionId, computed.load, claimTs)
    .run();
  let wonClaim = ins.meta.changes === 1;
  if (!wonClaim) {
    const staleBefore = claimTs - (deps.staleMs ?? IN_FLIGHT_STALE_MS);
    const take = await db
      .prepare(
        `UPDATE session_load_exports
           SET status='in_flight', updated_at=?2
         WHERE session_id=?1
           AND ( status IN ('pending','disabled')
                 OR (status='in_flight' AND updated_at < ?3) )`,
      )
      .bind(sessionId, claimTs, staleBefore)
      .run();
    wonClaim = take.meta.changes === 1;
  }

  // Read the (now-guaranteed) row to learn any prior ref / terminal state.
  const prior = await db
    .prepare('SELECT * FROM session_load_exports WHERE session_id = ?1')
    .bind(sessionId)
    .first<LoadExportRow>();

  // Idempotent PUT-update against a KNOWN remote ref. Used by BOTH the
  // non-winner deferred-update path and the post-completion changed-load
  // re-export path. A known ref makes pushStrengthActivity go straight to
  // PUT — no GET, no POST — so concurrent callers issuing this against the
  // SAME ref are idempotent and cannot create a duplicate remote event. On
  // success it UPSERTs load/updated_at/status='ok' and writes an audit row
  // (reason supplied by the caller so the audit trail still distinguishes
  // the two callers). It NEVER downgrades the row on failure — the caller
  // decides the (non-downgrading) return value. Returns whether the remote
  // PUT succeeded so the caller can shape its own status/load result.
  async function putUpdateKnownRef(
    ref: string,
    okReason: string,
  ): Promise<{ ok: true } | { ok: false; reason: string }> {
    const upd = await pushStrengthActivity(
      apiKey,
      athleteId,
      {
        date: sessionRow.date,
        name,
        loadTss: computedLoad.load,
        durationSec: computedLoad.durationSec,
        sessionId,
        ref,
      },
      { fetcher: deps.fetcher, timeoutMs: deps.timeoutMs },
    );
    if (upd.ok) {
      const ts2 = now();
      await db
        .prepare(
          `UPDATE session_load_exports
             SET intervals_ref=?2, load=?3, status='ok', updated_at=?4
           WHERE session_id=?1`,
        )
        .bind(sessionId, upd.ref, computedLoad.load, ts2)
        .run();
      await writeAudit(
        db,
        userId,
        'export_session_load',
        { session_id: sessionId, load: computedLoad.load },
        `ok:ref=${upd.ref}:${okReason}`,
      );
      return { ok: true };
    }
    return { ok: false, reason: upd.reason };
  }

  if (!wonClaim) {
    // We did NOT claim — another export already owns this session, OR a
    // terminal row exists. We must NOT create a remote event (that is the
    // exact concurrent-duplicate window).
    if (prior?.status === 'ok') {
      // Already exported successfully. `computed.load` is recomputed on
      // EVERY call, so a post-completion correction (re-running
      // log_workout_complete after editing perceived_fatigue / sets / RPE)
      // shows up here as a changed load. Unconditionally early-returning
      // would strand that correction locally — the remote activity would
      // keep the stale load, contradicting the 0008 FROZEN CONTRACT.
      if (computed.load === prior.load) {
        // Inputs unchanged → genuine no-op. Do NOT hit intervals.icu on
        // benign re-calls (idempotent re-export of an ok session).
        return { status: 'ok', load: prior.load };
      }
      if (prior.intervals_ref) {
        // Load changed AND we know the remote ref → idempotently
        // PUT-update the SAME activity (no GET, no POST ⇒ duplicate-free
        // even if two corrections race: concurrent PUTs to the same known
        // ref converge). This is what makes "re-completing with a changed
        // load updates the same activity" actually true.
        const r = await putUpdateKnownRef(prior.intervals_ref, 'reexport_load_changed');
        if (r.ok) return { status: 'ok', load: computed.load };
        // PUT failed — do NOT downgrade the good `ok` row. The stored
        // remote value is still the last good one; a future correction (or
        // the user re-running completion) will retry. P2 ok-not-downgraded
        // recovery guard is preserved.
        await writeAudit(
          db,
          userId,
          'export_session_load',
          { session_id: sessionId },
          `ok:reexport_update_failed:${r.reason}`,
        );
        return { status: 'ok', load: prior.load ?? computed.load };
      }
      // Defensive / unreachable: a terminal `ok` row ALWAYS carries an
      // intervals_ref (a row only becomes `ok` after a push that stored
      // the ref). An `ok` row with a changed load and NO ref therefore
      // should never occur. Handle it like the PUT-failure case above:
      // do NOT downgrade `ok` → that would violate the ok-not-downgraded
      // invariant, and the cron's pending/in_flight selector NEVER picks
      // an `ok` row, so a "defer to pending" here would neither persist
      // nor get reconciled — it would silently drop the correction while
      // re-entering this branch (and re-auditing) on every later call.
      // Keep the row `ok`, return the stored last-good load. Write the
      // anomaly audit AT MOST ONCE per session so this (unreachable) state
      // cannot spam audit_log unbounded across repeated calls.
      const priorAnomaly = await db
        .prepare(
          `SELECT 1 FROM audit_log
             WHERE tool='export_session_load'
               AND result='anomaly:ok_changed_load_no_ref'
               AND args LIKE ?1
             LIMIT 1`,
        )
        .bind(`%${sessionId}%`)
        .first<{ 1: number }>();
      if (!priorAnomaly) {
        await writeAudit(
          db,
          userId,
          'export_session_load',
          { session_id: sessionId, load: computed.load },
          'anomaly:ok_changed_load_no_ref',
        );
      }
      return { status: 'ok', load: prior.load ?? computed.load };
    } else if (prior?.intervals_ref) {
      // A remote event already exists → it is safe & duplicate-free to
      // PUT-update that EXACT ref (known id ⇒ pushStrengthActivity goes
      // straight to PUT, no GET, no POST). This refreshes load without a
      // duplicate even if we lost the claim race.
      const r = await putUpdateKnownRef(prior.intervals_ref, 'deferred_update');
      if (r.ok) return { status: 'ok', load: computed.load };
      // Update failed — leave whatever the in-flight owner / cron will
      // reconcile; do not downgrade a possibly-good row.
      await writeAudit(db, userId, 'export_session_load', { session_id: sessionId }, `deferred:update_failed:${r.reason}`);
      return { status: 'pending', load: computed.load };
    } else {
      // Another export is in flight with no ref yet (or row is pending) —
      // defer entirely. The in-flight owner finishes it; if that owner
      // crashed, the cron retries the stale in_flight row.
      await writeAudit(db, userId, 'export_session_load', { session_id: sessionId }, 'deferred:in_flight');
      return { status: 'pending', load: computed.load };
    }
  }

  // --- This caller WON the claim: it alone performs the create/push. ---
  const push = await pushStrengthActivity(
    apiKey,
    athleteId,
    {
      date: session.date, // device-local civil date VERBATIM
      name,
      loadTss: computed.load,
      durationSec: computed.durationSec,
      sessionId, // drives the deterministic remote idempotency marker
      ref: prior?.intervals_ref ?? null,
    },
    { fetcher: deps.fetcher, timeoutMs: deps.timeoutMs },
  );

  const ts = now();
  // prior.attempts is 0 for a fresh sentinel, or the prior count for a
  // reclaimed retryable row (claim transitions didn't bump it). Count this.
  const attempts = (prior?.attempts ?? 0) + 1;

  if (push.ok) {
    // UPSERT keyed by session_id — same intervals_ref, never a duplicate.
    await db
      .prepare(
        `INSERT INTO session_load_exports
           (session_id,intervals_ref,load,status,attempts,updated_at)
         VALUES (?1,?2,?3,'ok',?4,?5)
         ON CONFLICT(session_id) DO UPDATE SET
           intervals_ref=excluded.intervals_ref,
           load=excluded.load,
           status='ok',
           attempts=excluded.attempts,
           updated_at=excluded.updated_at`,
      )
      .bind(sessionId, push.ref, computed.load, attempts, ts)
      .run();
    await writeAudit(
      db,
      userId,
      'export_session_load',
      { session_id: sessionId, load: computed.load },
      `ok:ref=${push.ref}`,
    );
    return { status: 'ok', load: computed.load };
  }

  if (push.reason === 'disabled') {
    // Feature dormant — record nothing pushable, do not mark pending.
    await db
      .prepare(
        `INSERT INTO session_load_exports
           (session_id,intervals_ref,load,status,attempts,updated_at)
         VALUES (?1,?2,?3,'disabled',?4,?5)
         ON CONFLICT(session_id) DO UPDATE SET
           load=excluded.load,
           status='disabled',
           attempts=excluded.attempts,
           updated_at=excluded.updated_at`,
      )
      .bind(sessionId, prior?.intervals_ref ?? null, computed.load, attempts, ts)
      .run();
    await writeAudit(db, userId, 'export_session_load', { session_id: sessionId }, 'disabled');
    return { status: 'disabled' };
  }

  // Transient failure (http/timeout/parse) → leave PENDING for cron retry.
  await db
    .prepare(
      `INSERT INTO session_load_exports
         (session_id,intervals_ref,load,status,attempts,updated_at)
       VALUES (?1,?2,?3,'pending',?4,?5)
       ON CONFLICT(session_id) DO UPDATE SET
         intervals_ref=COALESCE(session_load_exports.intervals_ref,excluded.intervals_ref),
         load=excluded.load,
         status='pending',
         attempts=excluded.attempts,
         updated_at=excluded.updated_at`,
    )
    .bind(sessionId, prior?.intervals_ref ?? null, computed.load, attempts, ts)
    .run();
  await writeAudit(
    db,
    userId,
    'export_session_load',
    { session_id: sessionId, load: computed.load },
    `pending:${push.reason}${'status' in push && push.status ? `:${push.status}` : ''}`,
  );
  return { status: 'pending', load: computed.load };
}

/**
 * BEST-EFFORT export hook for the sacred log_workout_complete path. Wraps
 * exportSessionLoad so that ANY failure — including an unexpected throw —
 * cannot fail, block, or propagate into workout completion / set logging.
 * Resolves silently regardless; the cron retries anything left pending.
 */
export async function tryExportSessionLoad(
  db: D1Database,
  env: Env,
  userId: string,
  sessionId: string,
  deps: ExportDeps = {},
): Promise<void> {
  try {
    await exportSessionLoad(db, env, userId, sessionId, deps);
  } catch (e) {
    // The export must NEVER throw into the caller. Best-effort: record a
    // pending row (so the cron retries) and swallow. Even this recovery is
    // guarded so a DB hiccup here still cannot propagate.
    try {
      // Status guard: if the ok UPSERT already committed and a LATER step
      // (e.g. writeAudit) threw, the row is terminal `ok` with a real
      // intervals_ref — must NOT be downgraded to `pending` (that would
      // cause a needless ok→pending→ok cron round-trip). Only re-queue a
      // non-terminal row. intervals_ref is still never touched on conflict.
      await db
        .prepare(
          `INSERT INTO session_load_exports (session_id,intervals_ref,load,status,attempts,updated_at)
           VALUES (?1,NULL,NULL,'pending',
             COALESCE((SELECT attempts FROM session_load_exports WHERE session_id=?1),0)+1,?2)
           ON CONFLICT(session_id) DO UPDATE SET
             status = CASE WHEN status='ok' THEN 'ok' ELSE 'pending' END,
             updated_at = excluded.updated_at`,
        )
        .bind(sessionId, now())
        .run();
    } catch {
      /* swallow — completion must succeed no matter what */
    }
    console.error('tryExportSessionLoad swallowed', e);
  }
}

/**
 * Cron retry: re-attempt every still-`pending` export PLUS any STALE
 * `in_flight` row (older than IN_FLIGHT_STALE_MS — a crashed export that
 * never reached a terminal state, so it can't wedge a session forever).
 * Idempotent — each retry routes back through exportSessionLoad, whose
 * single-flight reclaim transitions the stale/pending row to in_flight and
 * the marker lookup / known ref guarantees the same intervals activity is
 * UPDATEd (never a duplicate). A failing retry stays 'pending'. Never
 * throws.
 */
export async function retryPendingLoadExports(
  db: D1Database,
  env: Env,
  deps: ExportDeps = {},
): Promise<{ retried: number; ok: number; stillPending: number }> {
  const out = { retried: 0, ok: 0, stillPending: 0 };
  let rows: { session_id: string }[];
  try {
    const staleBefore = now() - (deps.staleMs ?? IN_FLIGHT_STALE_MS);
    const r = await db
      .prepare(
        `SELECT session_id FROM session_load_exports
          WHERE status = 'pending'
             OR (status = 'in_flight' AND updated_at < ?1)`,
      )
      .bind(staleBefore)
      .all<{ session_id: string }>();
    rows = r.results;
  } catch (e) {
    console.error('retryPendingLoadExports list failed', e);
    return out;
  }
  for (const { session_id } of rows) {
    out.retried++;
    try {
      const owner = await db
        .prepare('SELECT user_id FROM sessions WHERE id = ?1')
        .bind(session_id)
        .first<{ user_id: string }>();
      if (!owner) continue;
      const res = await exportSessionLoad(db, env, owner.user_id, session_id, deps);
      if (res.status === 'ok') out.ok++;
      else if (res.status === 'pending') out.stillPending++;
    } catch (e) {
      out.stillPending++;
      console.error('retryPendingLoadExports item failed', e);
    }
  }
  return out;
}

/** "I'm beat — adjust." Scales target day(s) and records the reasoning. */
export async function adjustToday(
  db: D1Database,
  userId: string,
  intent: 'deload' | 'reduce_volume' | 'reduce_intensity',
  magnitude: 'light' | 'moderate' | 'heavy' = 'moderate',
  dayLabel?: string,
): Promise<{ plan: PlanTree | null; changes: string[] }> {
  const tree = await getPlanTree(db, userId);
  if (!tree) return { plan: null, changes: [] };
  const setF = { light: 0.8, moderate: 0.65, heavy: 0.5 }[magnitude];
  const wtF = { light: 0.95, moderate: 0.9, heavy: 0.85 }[magnitude];
  const days = dayLabel
    ? tree.days.filter((d) => d.day_label === dayLabel || d.name === dayLabel)
    : tree.days;
  const changes: string[] = [];
  const stmts: D1PreparedStatement[] = [];
  const ts = now();
  for (const d of days) {
    for (const te of d.exercises) {
      if (intent === 'reduce_intensity') {
        if (te.target_weight == null) continue;
        const w = Math.round((te.target_weight * wtF) / 5) * 5;
        stmts.push(
          db
            .prepare('UPDATE template_exercises SET target_weight=?2, updated_at=?3 WHERE id=?1')
            .bind(te.id, w, ts),
        );
        changes.push(`${d.day_label ?? d.name}/${te.exercise_id}: weight ${te.target_weight}→${w}`);
      } else {
        const s = Math.max(1, Math.round(te.target_sets * setF));
        stmts.push(
          db
            .prepare('UPDATE template_exercises SET target_sets=?2, updated_at=?3 WHERE id=?1')
            .bind(te.id, s, ts),
        );
        changes.push(`${d.day_label ?? d.name}/${te.exercise_id}: sets ${te.target_sets}→${s}`);
      }
    }
  }
  if (stmts.length) {
    stmts.push(
      db
        .prepare('UPDATE plans SET version = version + 1, updated_at = ?2 WHERE id = ?1')
        .bind(tree.id, ts),
    );
    await db.batch(stmts);
  }
  return { plan: await getPlanTree(db, userId), changes };
}

const epley = (w: number, r: number) => Math.round(w * (1 + r / 30) * 10) / 10;

export async function getHistory(
  db: D1Database,
  userId: string,
  exerciseId: string,
  from: number,
  to: number,
) {
  const sets = await db
    .prepare(
      `SELECT sl.*, s.date as session_date FROM set_logs sl
       JOIN sessions s ON s.id = sl.session_id
       WHERE s.user_id = ?1 AND sl.exercise_id = ?2 AND sl.deleted_at IS NULL
         AND sl.is_warmup = 0 AND sl.logged_at BETWEEN ?3 AND ?4
       ORDER BY sl.logged_at`,
    )
    .bind(userId, exerciseId, from, to)
    .all<SetLogRow & { session_date: string }>();
  // Top working set per session + Epley est-1RM.
  const bySession = new Map<string, { date: string; top: SetLogRow; est_1rm: number }>();
  for (const s of sets.results) {
    const e = epley(s.weight, s.reps);
    const cur = bySession.get(s.session_date);
    if (!cur || e > cur.est_1rm) {
      bySession.set(s.session_date, { date: s.session_date, top: s, est_1rm: e });
    }
  }
  return {
    exercise_id: exerciseId,
    sets: sets.results,
    by_session: [...bySession.values()].sort((a, b) => a.date.localeCompare(b.date)),
  };
}

export async function getVolume(
  db: D1Database,
  userId: string,
  muscle: string,
  from: number,
  to: number,
) {
  // Unilateral sets log reps per-side, so a 45x8 Bulgarian split squat is
  // really 16 physical reps and 720 lb of work — not 8 reps and 360 lb.
  // hard_sets stays a literal COUNT (one logged set is one set entered),
  // tonnage doubles via the CASE so volume trends match reality.
  const rows = await db
    .prepare(
      `SELECT strftime('%Y-%W', s.date) AS week,
              COUNT(*) AS hard_sets,
              SUM(sl.weight * sl.reps
                  * CASE WHEN e.laterality = 'unilateral' THEN 2 ELSE 1 END) AS tonnage
       FROM set_logs sl
       JOIN sessions s ON s.id = sl.session_id
       JOIN exercises e ON e.id = sl.exercise_id
       WHERE s.user_id = ?1 AND e.primary_muscle = ?2 AND sl.deleted_at IS NULL
         AND sl.is_warmup = 0 AND sl.logged_at BETWEEN ?3 AND ?4
       GROUP BY week ORDER BY week`,
    )
    .bind(userId, muscle, from, to)
    .all<{ week: string; hard_sets: number; tonnage: number }>();
  return { muscle_group: muscle, buckets: rows.results };
}

// ---- weekly schedule + future-calendar projection ------------------------
//
// The recurring pattern lives in plans.meta JSON (frozen contract, see
// migrations/0005). Schedule edits are plan-tree mutations: they bump
// plans.version and use optimistic concurrency. The one-off planned/skip
// session writes are append-only sessions rows and do NOT bump version.

/**
 * Calendar weekday rule (iOS MUST mirror this byte-for-byte):
 * parse the device-local 'YYYY-MM-DD' string as a proleptic Gregorian date,
 * compute days since the fixed Monday epoch 1970-01-05 using integer day
 * arithmetic (NOT a UTC Date offset, NOT timezone-aware), and index
 * WEEKDAYS = [mon,tue,wed,thu,fri,sat,sun]. 1970-01-05 was a Monday, so
 * ((daysSinceEpoch % 7) + 7) % 7 gives 0=mon ... 6=sun.
 */
function dayNumber(ymd: string): number {
  const parts = ymd.split('-');
  const y = Number(parts[0]);
  const m = Number(parts[1]);
  const d = Number(parts[2]);
  // Days from 1970-01-01 via a pure civil-from-date algorithm (Howard
  // Hinnant's days_from_civil) — no Date object, no UTC, no DST.
  const yy = m <= 2 ? y - 1 : y;
  const era = Math.floor((yy >= 0 ? yy : yy - 399) / 400);
  const yoe = yy - era * 400;
  const doy = Math.floor((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5) + d - 1;
  const doe = yoe * 365 + Math.floor(yoe / 4) - Math.floor(yoe / 100) + doy;
  return era * 146097 + doe - 719468; // days since 1970-01-01
}

/** 'YYYY-MM-DD' -> weekday key, via the calendar rule above (1970-01-05=Mon). */
export function weekdayOf(ymd: string): Weekday {
  const days = dayNumber(ymd) - 4; // 1970-01-05 (Monday) is day 4
  const idx = ((days % 7) + 7) % 7;
  return WEEKDAYS[idx]!;
}

/** Inclusive day count between two 'YYYY-MM-DD' strings (calendar, not UTC). */
function daySpan(from: string, to: string): number {
  return dayNumber(to) - dayNumber(from);
}

/** Add n days to a 'YYYY-MM-DD' string, returning 'YYYY-MM-DD'. */
function addDays(ymd: string, n: number): string {
  // Civil-from-days inverse of dayNumber (Hinnant), pure integer math.
  let z = dayNumber(ymd) + n + 719468;
  const era = Math.floor((z >= 0 ? z : z - 146096) / 146097);
  const doe = z - era * 146097;
  const yoe = Math.floor(
    (doe - Math.floor(doe / 1460) + Math.floor(doe / 36524) - Math.floor(doe / 146096)) / 365,
  );
  const y = yoe + era * 400;
  const doy = doe - (365 * yoe + Math.floor(yoe / 4) - Math.floor(yoe / 100));
  const mp = Math.floor((5 * doy + 2) / 153);
  const d = doy - Math.floor((153 * mp + 2) / 5) + 1;
  const m = mp < 10 ? mp + 3 : mp - 9;
  const yr = m <= 2 ? y + 1 : y;
  const pad = (x: number, w = 2) => String(x).padStart(w, '0');
  return `${pad(yr, 4)}-${pad(m)}-${pad(d)}`;
}

export async function getPlanSchedule(
  db: D1Database,
  userId: string,
): Promise<{ plan: PlanRow; schedule: WeeklySchedule } | null> {
  const plan = await getActivePlan(db, userId);
  if (!plan) return null;
  return { plan, schedule: parsePlanMeta(plan.meta).schedule };
}

/**
 * Replace the full weekly map. Resolves each value (id, day_label, or day
 * name) to a day_template_id belonging to the active plan; rejects any ref
 * that doesn't resolve to a day in THIS plan (no partial write). Optimistic
 * concurrency on expected_version. Bumps plans.version on success.
 */
export async function setPlanSchedule(
  db: D1Database,
  userId: string,
  weekInput: Partial<Record<Weekday, string | null>>,
  expectedVersion?: number | null,
): Promise<
  | { conflict: true; current_version: number }
  | { error: 'no_active_plan' }
  | { error: 'unknown_day_ref'; ref: string }
  | { ok: true; plan: PlanRow; schedule: WeeklySchedule; version: number }
> {
  const plan = await getActivePlan(db, userId);
  if (!plan) return { error: 'no_active_plan' };
  if (expectedVersion != null && expectedVersion !== plan.version) {
    return { conflict: true, current_version: plan.version };
  }
  const days = await db
    .prepare('SELECT id, name, day_label FROM day_templates WHERE plan_id = ?1')
    .bind(plan.id)
    .all<{ id: string; name: string; day_label: string | null }>();
  // Build resolution maps; id wins, then exact day_label, then exact name.
  const byId = new Map(days.results.map((d) => [d.id, d.id]));
  const byLabel = new Map<string, string>();
  const byName = new Map<string, string>();
  for (const d of days.results) {
    if (d.day_label) byLabel.set(d.day_label.toLowerCase(), d.id);
    byName.set(d.name.toLowerCase(), d.id);
  }
  const resolved: ScheduleWeek = {
    mon: null, tue: null, wed: null, thu: null, fri: null, sat: null, sun: null,
  };
  for (const wd of WEEKDAYS) {
    const ref = weekInput[wd];
    if (ref == null || ref === '') {
      resolved[wd] = null;
      continue;
    }
    const id =
      byId.get(ref) ?? byLabel.get(ref.toLowerCase()) ?? byName.get(ref.toLowerCase());
    if (!id) return { error: 'unknown_day_ref', ref };
    resolved[wd] = id;
  }
  const meta = parsePlanMeta(plan.meta);
  // schedule.version is a monotonic change counter for the schedule itself
  // (distinct from plans.version): bump it on every successful write so
  // clients can detect a schedule change without diffing the full week map.
  const schedule: WeeklySchedule = {
    version: meta.schedule.version + 1,
    week: resolved,
  };
  const ts = now();
  const row = await db
    .prepare(
      'UPDATE plans SET meta = ?2, version = version + 1, updated_at = ?3 WHERE id = ?1 RETURNING version',
    )
    .bind(plan.id, serializePlanMeta(meta, schedule), ts)
    .first<{ version: number }>();
  return {
    ok: true,
    plan: { ...plan, version: row?.version ?? plan.version + 1, updated_at: ts },
    schedule,
    version: row?.version ?? plan.version + 1,
  };
}

/**
 * Scrub schedule weekday entries whose day_template_id is not in `liveIds`.
 * Returns the cleaned schedule, or null if nothing changed. Caller decides
 * whether to persist (used inside the plan-rebuild batch so it shares the
 * single version bump).
 */
function scrubSchedule(
  schedule: WeeklySchedule,
  liveIds: Set<string>,
): WeeklySchedule | null {
  let changed = false;
  const week: ScheduleWeek = { ...schedule.week };
  for (const wd of WEEKDAYS) {
    const v = week[wd];
    if (v != null && !liveIds.has(v)) {
      week[wd] = null;
      changed = true;
    }
  }
  return changed ? { version: schedule.version, week } : null;
}

/**
 * Delete one day_template and, in the same transaction, scrub any schedule
 * entries pointing at it and bump plans.version exactly once.
 */
export async function deleteDayTemplate(
  db: D1Database,
  userId: string,
  dayId: string,
): Promise<{ ok: true } | { error: 'day_not_found' }> {
  const plan = await getActivePlan(db, userId);
  if (!plan) return { error: 'day_not_found' };
  const day = await db
    .prepare('SELECT id FROM day_templates WHERE id = ?1 AND plan_id = ?2')
    .bind(dayId, plan.id)
    .first<{ id: string }>();
  if (!day) return { error: 'day_not_found' };
  const meta = parsePlanMeta(plan.meta);
  const remaining = await db
    .prepare('SELECT id FROM day_templates WHERE plan_id = ?1 AND id != ?2')
    .bind(plan.id, dayId)
    .all<{ id: string }>();
  const liveIds = new Set(remaining.results.map((r) => r.id));
  const scrubbed = scrubSchedule(meta.schedule, liveIds);
  const ts = now();
  const stmts: D1PreparedStatement[] = [
    db
      .prepare('DELETE FROM template_exercises WHERE day_template_id = ?1')
      .bind(dayId),
    db.prepare('DELETE FROM day_templates WHERE id = ?1').bind(dayId),
    db
      .prepare(
        'UPDATE plans SET meta = ?2, version = version + 1, updated_at = ?3 WHERE id = ?1',
      )
      .bind(
        plan.id,
        serializePlanMeta(meta, scrubbed ?? meta.schedule),
        ts,
      ),
  ];
  await db.batch(stmts);
  return { ok: true };
}

/**
 * One-off: pin a specific date to a day template (or clear to a bare planned
 * session). Writes/updates a sessions row ONLY — append-only log, NO version
 * bump. `day` accepts id, day_label, or day name.
 */
export async function setPlannedSession(
  db: D1Database,
  userId: string,
  date: string,
  day: string,
): Promise<
  | { error: 'no_active_plan' }
  | { error: 'unknown_day_ref'; ref: string }
  | { ok: true; session: SessionRow }
> {
  const plan = await getActivePlan(db, userId);
  if (!plan) return { error: 'no_active_plan' };
  const d = await db
    .prepare(
      "SELECT id FROM day_templates WHERE plan_id = ?1 AND (id = ?2 OR lower(day_label) = lower(?2) OR lower(name) = lower(?2)) LIMIT 1",
    )
    .bind(plan.id, day)
    .first<{ id: string }>();
  if (!d) return { error: 'unknown_day_ref', ref: day };
  const existing = await db
    .prepare('SELECT * FROM sessions WHERE user_id = ?1 AND date = ?2 ORDER BY created_at LIMIT 1')
    .bind(userId, date)
    .first<SessionRow>();
  const ts = now();
  if (existing) {
    // The SQL CASE already flips the row to a sensible status; the bug was
    // that the response object spread `...existing` and kept the OLD status
    // (e.g. an agent saw `status: 'discarded'` with a past `started_at`
    // while the DB was actually 'planned' now). Compute the new shape
    // explicitly and persist BOTH started_at and completed_at resets when
    // we're reviving a discarded row, mirroring getOrCreateSession's
    // discard→planned resurrection (consistent revival rule across the
    // two places that revive a discarded session).
    const newStatus =
      existing.status === 'completed' || existing.status === 'in_progress'
        ? existing.status
        : 'planned';
    const reviving = existing.status === 'discarded';
    const newStartedAt = reviving ? null : existing.started_at;
    const newCompletedAt = reviving ? null : existing.completed_at;
    await db
      .prepare(
        'UPDATE sessions SET day_template_id = ?2, status = ?3, started_at = ?4, completed_at = ?5, updated_at = ?6 WHERE id = ?1',
      )
      .bind(existing.id, d.id, newStatus, newStartedAt, newCompletedAt, ts)
      .run();
    return {
      ok: true,
      session: {
        ...existing,
        day_template_id: d.id,
        status: newStatus,
        started_at: newStartedAt,
        completed_at: newCompletedAt,
        updated_at: ts,
      },
    };
  }
  const s: SessionRow = {
    id: uuid(),
    user_id: userId,
    plan_id: plan.id,
    day_template_id: d.id,
    date,
    status: 'planned',
    started_at: null,
    completed_at: null,
    perceived_fatigue: null,
    notes: null,
    created_at: ts,
    updated_at: ts,
  };
  await db
    .prepare(
      'INSERT INTO sessions (id,user_id,plan_id,day_template_id,date,status,started_at,completed_at,perceived_fatigue,notes,created_at,updated_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)',
    )
    .bind(s.id, s.user_id, s.plan_id, s.day_template_id, s.date, s.status, s.started_at, s.completed_at, s.perceived_fatigue, s.notes, s.created_at, s.updated_at)
    .run();
  return { ok: true, session: s };
}

/**
 * One-off: mark a specific date a rest/skip day. Writes/updates a sessions
 * row with status 'skipped' — append-only, NO version bump.
 */
export async function skipPlannedSession(
  db: D1Database,
  userId: string,
  date: string,
): Promise<
  | { error: 'no_active_plan' }
  | { error: 'session_already_started'; status: 'in_progress' | 'completed' }
  | { ok: true; session: SessionRow }
> {
  const plan = await getActivePlan(db, userId);
  if (!plan) return { error: 'no_active_plan' };
  const existing = await db
    .prepare('SELECT * FROM sessions WHERE user_id = ?1 AND date = ?2 ORDER BY created_at LIMIT 1')
    .bind(userId, date)
    .first<SessionRow>();
  const ts = now();
  if (existing) {
    // A skip may only override a planned (or absent) session. If the date
    // already has a started/finished workout, skipping it would hide logged
    // sets and destroy visible history for a mis-dated skip. Reject and
    // leave the row untouched — Claude must explicitly intend something
    // else. The MCP wrapper still audits this rejection (audit-on-write).
    if (existing.status === 'in_progress' || existing.status === 'completed') {
      return {
        error: 'session_already_started',
        status: existing.status as 'in_progress' | 'completed',
      };
    }
    await db
      .prepare("UPDATE sessions SET status = 'skipped', updated_at = ?2 WHERE id = ?1")
      .bind(existing.id, ts)
      .run();
    return { ok: true, session: { ...existing, status: 'skipped', updated_at: ts } };
  }
  const s: SessionRow = {
    id: uuid(),
    user_id: userId,
    plan_id: plan.id,
    day_template_id: null,
    date,
    status: 'skipped',
    started_at: null,
    completed_at: null,
    perceived_fatigue: null,
    notes: null,
    created_at: ts,
    updated_at: ts,
  };
  await db
    .prepare(
      'INSERT INTO sessions (id,user_id,plan_id,day_template_id,date,status,started_at,completed_at,perceived_fatigue,notes,created_at,updated_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)',
    )
    .bind(s.id, s.user_id, s.plan_id, s.day_template_id, s.date, s.status, s.started_at, s.completed_at, s.perceived_fatigue, s.notes, s.created_at, s.updated_at)
    .run();
  return { ok: true, session: s };
}

export interface CalendarCell {
  date: string;
  /** projected: from the weekly pattern. rest: no template that weekday.
   *  Otherwise the real sessions.status (planned|in_progress|completed|skipped). */
  status: 'projected' | 'rest' | 'planned' | 'in_progress' | 'completed' | 'skipped';
  /** Set when a template resolves (projected or a real session w/ day). */
  day_template_id: string | null;
  /** True iff this cell came from a real sessions row. */
  real: boolean;
}

/**
 * Pure projection. Given the plan, its schedule, the real sessions in range,
 * and an inclusive [fromDate,toDate] window (capped at 90 days span), emit a
 * calendar cell per date:
 *
 *  - date < today: emit ONLY if a real sessions row exists (use its status).
 *    Never fabricate past rest/missed days.
 *  - date >= today: a real sessions row wins; otherwise weekday(date) ->
 *    schedule.week -> template id. Resolvable id -> 'projected'; null /
 *    missing / dangling id -> 'rest'.
 *
 * Weekday is derived from the 'YYYY-MM-DD' string via weekdayOf() (calendar
 * rule, NOT a UTC offset) — iOS must mirror weekdayOf byte-for-byte.
 */
export function projectCalendar(
  plan: { id: string },
  schedule: WeeklySchedule,
  realSessions: SessionRow[],
  fromDate: string,
  toDate: string,
  today: string,
  /** Day-template ids that still exist; a schedule id not here is dangling
   *  and degrades to 'rest'. Pass [] only if you have no plan tree. */
  liveDayIds: Iterable<string> = [],
): CalendarCell[] {
  void plan;
  const resolvable = new Set(liveDayIds);
  // Clamp the span to 90 days (inclusive endpoint counts as span 0..89).
  let span = daySpan(fromDate, toDate);
  if (span < 0) return [];
  if (span > 89) span = 89;
  const byDate = new Map<string, SessionRow>();
  for (const s of realSessions) {
    // A 'discarded' session is treated as if it never existed: the user
    // explicitly threw it away (its set_logs are soft-deleted by
    // discardSession). Skipping it here makes the date fall through to the
    // schedule projection (past → no cell; today/future → projected/rest)
    // — i.e. it VANISHES rather than showing as a skip. This carve-out is
    // mirrored byte-for-byte in CalendarProjection.swift (`project`): the
    // frozen truth table now reads "a real session WINS *unless* it is
    // 'discarded'". test/calendar.test.ts is the contract.
    if (s.status === 'discarded') continue;
    if (!byDate.has(s.date)) byDate.set(s.date, s);
  }
  const cells: CalendarCell[] = [];
  for (let i = 0; i <= span; i++) {
    const date = addDays(fromDate, i);
    const real = byDate.get(date);
    const isPast = daySpan(today, date) < 0;
    if (real) {
      cells.push({
        date,
        status: real.status as CalendarCell['status'],
        day_template_id: real.day_template_id,
        real: true,
      });
      continue;
    }
    if (isPast) continue; // no fabricated past cells
    const tid = schedule.week[weekdayOf(date)];
    if (tid && resolvable.has(tid)) {
      cells.push({ date, status: 'projected', day_template_id: tid, real: false });
    } else {
      cells.push({ date, status: 'rest', day_template_id: null, real: false });
    }
  }
  return cells;
}

/**
 * Data-layer entry point: load the active plan, its schedule, the live day
 * ids (for dangling detection), and the real sessions in range, then return
 * the pure projection. fromDate/toDate are device-local 'YYYY-MM-DD'.
 */
export async function getProjectedCalendar(
  db: D1Database,
  userId: string,
  fromDate: string,
  toDate: string,
  today: string,
): Promise<CalendarCell[]> {
  const plan = await getActivePlan(db, userId);
  if (!plan) return [];
  const schedule = parsePlanMeta(plan.meta).schedule;
  const liveDays = await db
    .prepare('SELECT id FROM day_templates WHERE plan_id = ?1')
    .bind(plan.id)
    .all<{ id: string }>();
  // NOTE: the `sessions` table has NO soft-delete column (only set_logs and
  // external_events carry deleted_at — see migrations 0001/0006). A session
  // is never soft-deleted; a cancelled/rest day is modelled as a real row
  // with status='skipped', and a thrown-away session as status='discarded'.
  // So there is intentionally no `deleted_at IS NULL` guard here (it would
  // reference a non-existent column). Spurious lift dates are prevented
  // downstream: getRideConflicts' liftDates filter includes only
  // projected|planned|in_progress|completed and EXCLUDES 'skipped'; a
  // 'discarded' session never even reaches that filter because
  // projectCalendar drops it from byDate (vanishes), so it likewise
  // produces no conflict.
  const sessions = await db
    .prepare(
      'SELECT * FROM sessions WHERE user_id = ?1 AND date >= ?2 AND date <= ?3 ORDER BY date',
    )
    .bind(userId, fromDate, toDate)
    .all<SessionRow>();
  return projectCalendar(
    plan,
    schedule,
    sessions.results,
    fromDate,
    toDate,
    today,
    liveDays.results.map((r) => r.id),
  );
}

/** Resolve the schedule to human-readable weekday → day name, for context. */
export async function getResolvedScheduleNames(
  db: D1Database,
  userId: string,
): Promise<Record<Weekday, string | null> | null> {
  const got = await getPlanSchedule(db, userId);
  if (!got) return null;
  const days = await db
    .prepare('SELECT id, name FROM day_templates WHERE plan_id = ?1')
    .bind(got.plan.id)
    .all<{ id: string; name: string }>();
  const nameById = new Map(days.results.map((d) => [d.id, d.name]));
  const out = {} as Record<Weekday, string | null>;
  for (const wd of WEEKDAYS) {
    const id = got.schedule.week[wd];
    out[wd] = id ? nameById.get(id) ?? null : null;
  }
  return out;
}

// ---- external events (cycling-awareness; own consistency class) ----------
//
// `external_events` is a SERVER-OWNED RECONCILED CACHE. It is not the
// versioned plan tree and not the append-only client-UUID log. A sync
// MUST NOT bump plans.version. Rows are soft-deleted, never hard-deleted.

export type SyncStatus =
  | 'disabled' // INTERVALS_ICU_API_KEY/ATHLETE_ID unset — dormant no-op
  | 'ok' // 2xx + parse: cache reconciled
  | 'fetch_failed'; // non-2xx/timeout/parse: cache left COMPLETELY untouched

export interface SyncResult {
  status: SyncStatus;
  /** Count of non-deleted in-window rows after a successful sync (else 0). */
  synced: number;
  /** Diagnostic only (http status / reason) on a failed fetch. */
  detail?: string;
}

export interface SyncDeps extends FetchDeps {
  /** Override the user id (defaults to the single owner). */
  userId?: string;
  /** Allow injecting the env-resolved owner sub (tests). */
  ownerSub?: string;
}

/**
 * Pull intervals.icu planned events and reconcile the cache.
 *
 * THE critical correctness guard: on a failed/disabled fetch the cache is
 * left COMPLETELY untouched (no upsert, NO soft-delete) — a transient
 * intervals.icu outage must NEVER wipe the user's ride awareness. Only a
 * genuinely-empty *successful* window soft-deletes the in-window rows.
 *
 * Reconcile (on {ok:true}):
 *  - upsert each event by (source, external_id) — id = "intervals:{ext}";
 *    reschedules just update `date` (+ other fields) on the same row.
 *  - soft-delete (set deleted_at) any non-deleted row whose date is inside
 *    the synced [today, today+window] window but is no longer present in
 *    the fetched set (the source removed/cancelled it).
 *  - rows OUTSIDE the window are never touched (we didn't ask about them).
 *
 * Never bumps plans.version. Never writes a notes row. (The MCP action
 * wrapper writes the audit_log row — this layer stays pure data.)
 */
export async function syncExternalEvents(
  db: D1Database,
  env: Env,
  deps: SyncDeps = {},
): Promise<SyncResult> {
  const today = deps.today ?? new Date().toISOString().slice(0, 10);
  const windowDays = deps.windowDays ?? 90;

  // Resolve creds for THIS sync. Three call shapes (M1 multi-user):
  //   (a) deps.userId given (refresh_rides MCP tool / tests): sync that one
  //       user, reading creds off their row. If the row has no creds, the
  //       legacy env values are accepted as a fallback so existing
  //       single-user tests keep passing without code changes.
  //   (b) no userId: cron entrypoint. Run the env→DB seed (idempotent), then
  //       iterate ALL users with creds. Aggregate the SyncResult.
  let userId: string;
  let apiKey: string | null | undefined;
  let athleteId: string | null | undefined;
  if (deps.userId) {
    userId = deps.userId;
    const creds = await getUserIntervalsCreds(db, userId);
    apiKey = creds.api_key ?? env.INTERVALS_ICU_API_KEY;
    athleteId = creds.athlete_id ?? env.INTERVALS_ICU_ATHLETE_ID;
  } else {
    const owner = await ensureOwnerUser(db, deps.ownerSub ?? env.OWNER_APPLE_SUB);
    const seeded = await seedOwnerIntervalsCredsFromEnv(
      db,
      env.INTERVALS_ICU_API_KEY,
      env.INTERVALS_ICU_ATHLETE_ID,
    );
    if (seeded.length === 0) {
      // No user has creds AND env is unset → dormant no-op for everyone.
      return { status: 'disabled', synced: 0, detail: 'disabled' };
    }
    if (seeded.length === 1) {
      userId = seeded[0]!.user_id;
      apiKey = seeded[0]!.api_key;
      athleteId = seeded[0]!.athlete_id;
    } else {
      // Multi-user fan-out. Sync each user's cache against THEIR creds; tag
      // the per-user user_id everywhere. Aggregate sums + worst-status semantics:
      //   any 'fetch_failed' wins (operator signal); else 'ok' if any ok'd;
      //   else 'disabled'. `synced` is the sum across users.
      let total = 0;
      let agg: SyncStatus = 'disabled';
      const details: string[] = [];
      for (const c of seeded) {
        const r = await syncExternalEvents(db, env, {
          ...deps,
          userId: c.user_id,
          today,
          windowDays,
        });
        total += r.synced;
        if (r.status === 'fetch_failed') agg = 'fetch_failed';
        else if (agg !== 'fetch_failed' && r.status === 'ok') agg = 'ok';
        if (r.detail) details.push(`${c.user_id.slice(0, 8)}:${r.detail}`);
      }
      return {
        status: agg,
        synced: total,
        ...(details.length ? { detail: details.join(',') } : {}),
      };
    }
    // Single-user path: reference owner.id for downstream logic (it equals
    // the single seeded row, but be explicit so the linter doesn't flag a
    // possibly-unused binding when the multi-user branch returns early).
    void owner;
  }

  const fetched = await fetchPlannedEvents(apiKey, athleteId, { ...deps, today, windowDays });
  if (!fetched.ok) {
    // Disabled OR transient failure → DO NOT TOUCH the cache at all.
    return {
      status: fetched.reason === 'disabled' ? 'disabled' : 'fetch_failed',
      synced: 0,
      detail:
        fetched.reason +
        (fetched.reason === 'http' && 'status' in fetched ? `:${fetched.status}` : ''),
    };
  }

  // Window upper bound, inclusive, as a YYYY-MM-DD string (string compare is
  // valid for zero-padded ISO dates).
  const newest = addDays(today, windowDays);
  const ts = now();
  const seen = new Set<string>();
  const stmts: D1PreparedStatement[] = [];

  for (const ev of fetched.events) {
    const id = `intervals:${ev.external_id}`;
    seen.add(id);
    // Upsert by PK (id is deterministic from source+external_id). A reschedule
    // (same external_id, new date) just updates `date` on the same row and
    // clears any prior soft-delete (the event came back).
    stmts.push(
      db
        .prepare(
          `INSERT INTO external_events
             (id,user_id,source,external_id,date,kind,title,description,
              planned_duration_sec,training_load,intensity,raw,synced_at,deleted_at)
           VALUES (?1,?2,'intervals',?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,NULL)
           ON CONFLICT(id) DO UPDATE SET
             date=excluded.date,
             kind=excluded.kind,
             title=excluded.title,
             description=excluded.description,
             planned_duration_sec=excluded.planned_duration_sec,
             training_load=excluded.training_load,
             intensity=excluded.intensity,
             raw=excluded.raw,
             synced_at=excluded.synced_at,
             deleted_at=NULL`,
        )
        .bind(
          id,
          userId,
          ev.external_id,
          ev.date,
          ev.kind,
          ev.title,
          ev.description,
          ev.planned_duration_sec,
          ev.training_load,
          ev.intensity,
          ev.raw,
          ts,
        ),
    );
  }

  // Soft-delete in-window rows that were NOT seen this sync. Rows outside
  // [today,newest] are intentionally left alone (we didn't query them).
  // Done as a single statement excluding the seen ids.
  const seenIds = [...seen];
  const placeholders = seenIds.map((_, i) => `?${i + 4}`).join(',');
  const notInSeen = seenIds.length ? `AND id NOT IN (${placeholders})` : '';
  stmts.push(
    db
      .prepare(
        // Advance synced_at to the deletion time alongside deleted_at:
        // /api/state?events_since= filters `synced_at > cursor`, so a
        // tombstone that kept its old synced_at would never reach an
        // incremental client (it would keep showing the deleted ride).
        `UPDATE external_events
            SET deleted_at = ?3, synced_at = ?3
          WHERE user_id = ?1
            AND deleted_at IS NULL
            AND date >= ?2 AND date <= ?${seenIds.length ? seenIds.length + 4 : 4}
            ${notInSeen}`,
      )
      .bind(userId, today, ts, ...seenIds, newest),
  );

  await db.batch(stmts);

  const cnt = await db
    .prepare(
      `SELECT COUNT(*) AS c FROM external_events
        WHERE user_id = ?1 AND deleted_at IS NULL
          AND date >= ?2 AND date <= ?3`,
    )
    .bind(userId, today, newest)
    .first<{ c: number }>();
  return { status: 'ok', synced: cnt?.c ?? 0 };
}

/**
 * Non-deleted upcoming external events for a user. `range` is an inclusive
 * day count from `from` (default: today .. +90d).
 */
export async function getUpcomingRides(
  db: D1Database,
  userId: string,
  opts: { from?: string; range?: number } = {},
): Promise<ExternalEventRow[]> {
  const from = opts.from ?? new Date().toISOString().slice(0, 10);
  const to = addDays(from, opts.range ?? 90);
  const r = await db
    .prepare(
      `SELECT * FROM external_events
        WHERE user_id = ?1 AND deleted_at IS NULL
          AND date >= ?2 AND date <= ?3
        ORDER BY date`,
    )
    .bind(userId, from, to)
    .all<ExternalEventRow>();
  return r.results;
}

// ---- completed activities (own consistency class; see migrations/0015) ----
//
// PARALLEL to syncExternalEvents/getUpcomingRides but for COMPLETED, PAST
// recorded activities (the intervals.icu actuals) instead of planned events.
// Same server-owned reconciled-cache discipline: failed/disabled fetch =>
// cache left COMPLETELY untouched; only a successful window soft-deletes the
// in-window rows that vanished. Never bumps plans.version; never writes notes.

export interface ActivitySyncDeps extends ActivityFetchDeps {
  /** Override the user id (defaults to the single owner). */
  userId?: string;
  /** Allow injecting the env-resolved owner sub (tests). */
  ownerSub?: string;
}

/**
 * Pull intervals.icu completed activities and reconcile the cache.
 *
 * Window is BACKWARD: [today-pastDays, today]. On a failed/disabled fetch the
 * cache is left untouched (a transient outage must never wipe completed-
 * activity history). On a successful sync, in-window rows not present in the
 * fetched set are soft-deleted (an activity deleted in intervals.icu) — with
 * synced_at advanced to the deletion time so incremental clients see it
 * (the FIX 3 tombstone rule, same as external_events).
 */
export async function syncExternalActivities(
  db: D1Database,
  env: Env,
  deps: ActivitySyncDeps = {},
): Promise<SyncResult> {
  const today = deps.today ?? new Date().toISOString().slice(0, 10);
  const pastDays = deps.pastDays ?? 90;

  // Mirror of syncExternalEvents: per-user credentials (M1). See that
  // function for the full rationale on the three call shapes (explicit
  // userId vs cron fan-out vs env-seed fallback).
  let userId: string;
  let apiKey: string | null | undefined;
  let athleteId: string | null | undefined;
  if (deps.userId) {
    userId = deps.userId;
    const creds = await getUserIntervalsCreds(db, userId);
    apiKey = creds.api_key ?? env.INTERVALS_ICU_API_KEY;
    athleteId = creds.athlete_id ?? env.INTERVALS_ICU_ATHLETE_ID;
  } else {
    const owner = await ensureOwnerUser(db, deps.ownerSub ?? env.OWNER_APPLE_SUB);
    const seeded = await seedOwnerIntervalsCredsFromEnv(
      db,
      env.INTERVALS_ICU_API_KEY,
      env.INTERVALS_ICU_ATHLETE_ID,
    );
    if (seeded.length === 0) {
      return { status: 'disabled', synced: 0, detail: 'disabled' };
    }
    if (seeded.length === 1) {
      userId = seeded[0]!.user_id;
      apiKey = seeded[0]!.api_key;
      athleteId = seeded[0]!.athlete_id;
    } else {
      let total = 0;
      let agg: SyncStatus = 'disabled';
      const details: string[] = [];
      for (const c of seeded) {
        const r = await syncExternalActivities(db, env, {
          ...deps,
          userId: c.user_id,
          today,
          pastDays,
        });
        total += r.synced;
        if (r.status === 'fetch_failed') agg = 'fetch_failed';
        else if (agg !== 'fetch_failed' && r.status === 'ok') agg = 'ok';
        if (r.detail) details.push(`${c.user_id.slice(0, 8)}:${r.detail}`);
      }
      return {
        status: agg,
        synced: total,
        ...(details.length ? { detail: details.join(',') } : {}),
      };
    }
    void owner;
  }

  const fetched = await fetchCompletedActivities(apiKey, athleteId, { ...deps, today, pastDays });
  if (!fetched.ok) {
    return {
      status: fetched.reason === 'disabled' ? 'disabled' : 'fetch_failed',
      synced: 0,
      detail:
        fetched.reason +
        (fetched.reason === 'http' && 'status' in fetched ? `:${fetched.status}` : ''),
    };
  }

  const oldest = addDays(today, -pastDays);
  const ts = now();
  const seen = new Set<string>();
  const stmts: D1PreparedStatement[] = [];

  for (const a of fetched.activities) {
    const id = `intervals:activity:${a.external_id}`;
    seen.add(id);
    stmts.push(
      db
        .prepare(
          `INSERT INTO external_activities
             (id,user_id,source,external_id,date,kind,name,
              moving_time_sec,elapsed_time_sec,distance_m,average_watts,
              weighted_avg_watts,average_hr,max_hr,training_load,intensity,
              calories,elevation_gain_m,raw,synced_at,deleted_at)
           VALUES (?1,?2,'intervals',?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,
                   ?15,?16,?17,?18,?19,NULL)
           ON CONFLICT(id) DO UPDATE SET
             date=excluded.date,
             kind=excluded.kind,
             name=excluded.name,
             moving_time_sec=excluded.moving_time_sec,
             elapsed_time_sec=excluded.elapsed_time_sec,
             distance_m=excluded.distance_m,
             average_watts=excluded.average_watts,
             weighted_avg_watts=excluded.weighted_avg_watts,
             average_hr=excluded.average_hr,
             max_hr=excluded.max_hr,
             training_load=excluded.training_load,
             intensity=excluded.intensity,
             calories=excluded.calories,
             elevation_gain_m=excluded.elevation_gain_m,
             raw=excluded.raw,
             synced_at=excluded.synced_at,
             deleted_at=NULL`,
        )
        .bind(
          id,
          userId,
          a.external_id,
          a.date,
          a.kind,
          a.name,
          a.moving_time_sec,
          a.elapsed_time_sec,
          a.distance_m,
          a.average_watts,
          a.weighted_avg_watts,
          a.average_hr,
          a.max_hr,
          a.training_load,
          a.intensity,
          a.calories,
          a.elevation_gain_m,
          a.raw,
          ts,
        ),
    );
  }

  // Soft-delete in-window rows not seen this sync (advancing synced_at so the
  // tombstone reaches incremental clients). Rows outside [oldest,today] are
  // left alone (we didn't query them).
  const seenIds = [...seen];
  const placeholders = seenIds.map((_, i) => `?${i + 4}`).join(',');
  const notInSeen = seenIds.length ? `AND id NOT IN (${placeholders})` : '';
  stmts.push(
    db
      .prepare(
        `UPDATE external_activities
            SET deleted_at = ?3, synced_at = ?3
          WHERE user_id = ?1
            AND deleted_at IS NULL
            AND date >= ?2 AND date <= ?${seenIds.length ? seenIds.length + 4 : 4}
            ${notInSeen}`,
      )
      .bind(userId, oldest, ts, ...seenIds, today),
  );

  await db.batch(stmts);

  const cnt = await db
    .prepare(
      `SELECT COUNT(*) AS c FROM external_activities
        WHERE user_id = ?1 AND deleted_at IS NULL
          AND date >= ?2 AND date <= ?3`,
    )
    .bind(userId, oldest, today)
    .first<{ c: number }>();
  return { status: 'ok', synced: cnt?.c ?? 0 };
}

/**
 * Non-deleted completed activities for a user, most-recent first. `range` is
 * an inclusive day count back from `to` (default: last 90 days). `limit`
 * caps the result (default 50).
 */
export async function getRecentActivities(
  db: D1Database,
  userId: string,
  opts: { to?: string; range?: number; limit?: number } = {},
): Promise<ExternalActivityRow[]> {
  const to = opts.to ?? new Date().toISOString().slice(0, 10);
  const from = addDays(to, -(opts.range ?? 90));
  const limit = Math.max(1, Math.min(500, opts.limit ?? 50));
  const r = await db
    .prepare(
      `SELECT * FROM external_activities
        WHERE user_id = ?1 AND deleted_at IS NULL
          AND date >= ?2 AND date <= ?3
        ORDER BY date DESC
        LIMIT ?4`,
    )
    .bind(userId, from, to, limit)
    .all<ExternalActivityRow>();
  return r.results;
}

/**
 * CONFLICT RULE — authoritative. iOS mirrors this BYTE-FOR-BYTE.
 *
 * Inputs: the set of dates that hold a lift (a real lift session OR a
 * projected/scheduled lift day) and the non-deleted external_events.
 * Soft-deleted events are excluded by the caller and ignored here.
 *
 * For each lift date D, in priority order (first match wins; a date emits at
 * most one DayConflict):
 *
 *  (a) SAME-DAY  → severity "clash":
 *      there exists a non-deleted external_event whose `date` == D.
 *      `conflicts` = the ids of ALL such same-day events.
 *
 *  (b) DAY-BEFORE-HARD  → severity "heavy-next-day":
 *      D itself has no same-day event, AND there exists a non-deleted
 *      external_event E on the immediately following calendar day
 *      (date == D + 1 civil day) that is "hard", where hard means
 *      training_load >= 150 OR planned_duration_sec >= 9000.
 *      `conflicts` = the ids of ALL such hard next-day events.
 *      (Sub-threshold next-day events do NOT flag.)
 *
 * "Calendar day before/after" uses the YYYY-MM-DD civil date (the same
 * tz-free rule as weekdayOf/addDays) — never a UTC offset. Output is
 * sorted by date ascending and is fully deterministic.
 */
export function detectConflicts(
  liftDates: Iterable<string>,
  events: Pick<ExternalEventRow, 'id' | 'date' | 'training_load' | 'planned_duration_sec'>[],
): DayConflict[] {
  const byDate = new Map<string, typeof events>();
  for (const e of events) {
    const arr = byDate.get(e.date);
    if (arr) arr.push(e);
    else byDate.set(e.date, [e]);
  }
  const isHard = (e: { training_load: number | null; planned_duration_sec: number | null }) =>
    (e.training_load ?? 0) >= 150 || (e.planned_duration_sec ?? 0) >= 9000;

  const out: DayConflict[] = [];
  // Dedupe + stable order: iterate sorted unique lift dates.
  const dates = [...new Set(liftDates)].sort();
  for (const d of dates) {
    const sameDay = byDate.get(d);
    if (sameDay && sameDay.length) {
      out.push({ date: d, conflicts: sameDay.map((e) => e.id), severity: 'clash' });
      continue;
    }
    const next = byDate.get(addDays(d, 1));
    if (next) {
      const hard = next.filter(isHard);
      if (hard.length) {
        out.push({ date: d, conflicts: hard.map((e) => e.id), severity: 'heavy-next-day' });
      }
    }
  }
  return out;
}

/**
 * Data-layer convenience: collect lift dates from the projected calendar in
 * a window and run detectConflicts against the live ride cache. Pure read.
 */
export async function getRideConflicts(
  db: D1Database,
  userId: string,
  fromDate: string,
  toDate: string,
  today: string,
): Promise<DayConflict[]> {
  const cal = await getProjectedCalendar(db, userId, fromDate, toDate, today);
  const liftDates = cal
    .filter(
      (c) =>
        c.status === 'projected' ||
        c.status === 'planned' ||
        c.status === 'in_progress' ||
        c.status === 'completed',
    )
    .map((c) => c.date);
  const events = await db
    .prepare(
      `SELECT id, date, training_load, planned_duration_sec
         FROM external_events
        WHERE user_id = ?1 AND deleted_at IS NULL
          AND date >= ?2 AND date <= ?3`,
    )
    .bind(userId, fromDate, addDays(toDate, 1))
    .all<Pick<ExternalEventRow, 'id' | 'date' | 'training_load' | 'planned_duration_sec'>>();
  return detectConflicts(liftDates, events.results);
}
