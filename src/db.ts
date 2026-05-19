// Service layer: all D1 access goes through here so REST (now) and MCP
// (milestone b) share identical behavior. Timestamps are epoch-ms integers.
import type {
  DayTemplateRow,
  EnrichedTemplateExercise,
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
    .prepare('SELECT * FROM day_templates WHERE plan_id = ?1 ORDER BY order_index')
    .bind(plan.id)
    .all<DayTemplateRow>();
  const dayIds = days.results.map((d) => d.id);
  let exercises: EnrichedTemplateExercise[] = [];
  if (dayIds.length) {
    const placeholders = dayIds.map((_, i) => `?${i + 1}`).join(',');
    const res = await db
      .prepare(
        `SELECT te.*, e.name AS exercise_name, e.unit AS exercise_unit,
                e.primary_muscle AS exercise_muscle, e.modality AS exercise_modality
         FROM template_exercises te
         JOIN exercises e ON e.id = te.exercise_id
         WHERE te.day_template_id IN (${placeholders}) ORDER BY te.order_index`,
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

export async function patchDayTemplate(
  db: D1Database,
  planId: string,
  dayId: string,
  patch: { name?: string; order_index?: number; notes?: string | null },
): Promise<DayTemplateRow | null> {
  const existing = await db
    .prepare('SELECT * FROM day_templates WHERE id = ?1 AND plan_id = ?2')
    .bind(dayId, planId)
    .first<DayTemplateRow>();
  if (!existing) return null;
  const merged = {
    name: patch.name ?? existing.name,
    order_index: patch.order_index ?? existing.order_index,
    notes: patch.notes === undefined ? existing.notes : patch.notes,
  };
  await db
    .prepare('UPDATE day_templates SET name=?2, order_index=?3, notes=?4, updated_at=?5 WHERE id=?1')
    .bind(dayId, merged.name, merged.order_index, merged.notes, now())
    .run();
  await bumpPlanVersion(db, planId);
  return { ...existing, ...merged, updated_at: now() };
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
       (id,day_template_id,exercise_id,order_index,target_sets,target_reps,target_reps_max,target_rpe,rest_seconds,target_weight,progression,cues,created_at,updated_at)
       VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14)`,
    )
    .bind(
      row.id, row.day_template_id, row.exercise_id, row.order_index, row.target_sets,
      row.target_reps, row.target_reps_max, row.target_rpe, row.rest_seconds,
      row.target_weight, row.progression, row.cues, row.created_at, row.updated_at,
    )
    .run();
  await bumpPlanVersion(db, planId);
  return row;
}

// ---- exercise resolver ---------------------------------------------------

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
  if (existing) return existing;
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
  patch: { status?: string; perceived_fatigue?: number; notes?: string },
): Promise<SessionRow | null> {
  const s = await db
    .prepare('SELECT * FROM sessions WHERE id = ?1 AND user_id = ?2')
    .bind(sessionId, userId)
    .first<SessionRow>();
  if (!s) return null;
  const status = patch.status ?? s.status;
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

  const row: SetLogRow = {
    id: input.id,
    session_id: input.session_id,
    exercise_id: input.exercise_id,
    template_exercise_id: input.template_exercise_id ?? null,
    set_index: input.set_index,
    weight: input.weight,
    reps: input.reps,
    rpe: input.rpe ?? null,
    is_warmup: input.is_warmup ? 1 : 0,
    notes: input.notes ?? null,
    logged_at: input.logged_at ?? now(),
    source: input.source,
    duration_s: input.duration_s ?? null,
    deleted_at: null,
  };
  await db
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
  // Logging a set implicitly starts the session.
  await db
    .prepare("UPDATE sessions SET status = CASE WHEN status='planned' THEN 'in_progress' ELSE status END, started_at = COALESCE(started_at, ?2), updated_at = ?2 WHERE id = ?1")
    .bind(input.session_id, now())
    .run();
  return { set: row, deduped: false };
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
  const deletedAt = patch.deleted ? row.deleted_at ?? now() : patch.deleted === false ? null : row.deleted_at;
  await db
    .prepare('UPDATE set_logs SET weight=?2, reps=?3, rpe=?4, notes=?5, deleted_at=?6 WHERE id=?1')
    .bind(setId, weight, reps, rpe, notes, deletedAt)
    .run();
  return { ...row, weight, reps, rpe, notes, deleted_at: deletedAt };
}

// ---- read models ---------------------------------------------------------

export async function getState(
  db: D1Database,
  userId: string,
  sincePlanVersion: number,
  setsSince: number,
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
  const sets = await db
    .prepare(
      `SELECT sl.* FROM set_logs sl JOIN sessions s ON s.id = sl.session_id
       WHERE s.user_id = ?1 AND sl.logged_at > ?2 ORDER BY sl.logged_at`,
    )
    .bind(userId, setsSince)
    .all<SetLogRow>();
  return {
    plan: tree,
    plan_version: plan?.version ?? 0,
    sessions: sessions.results,
    sets: sets.results,
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
  const r = await db
    .prepare('SELECT * FROM sessions WHERE user_id = ?1 ORDER BY date DESC LIMIT ?2')
    .bind(userId, n)
    .all<SessionRow>();
  return r.results;
}

export async function getSessionByDate(
  db: D1Database,
  userId: string,
  date: string,
): Promise<SessionRow | null> {
  return db
    .prepare('SELECT * FROM sessions WHERE user_id = ?1 AND date = ?2 ORDER BY created_at LIMIT 1')
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
): Promise<void> {
  await db
    .prepare(
      'INSERT INTO audit_log (id,user_id,actor,tool,args,result,created_at) VALUES (?1,?2,?3,?4,?5,?6,?7)',
    )
    .bind(uuid(), userId, 'mcp', tool, JSON.stringify(args).slice(0, 4000), result.slice(0, 500), now())
    .run();
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
> {
  let plan = await getActivePlan(db, userId);
  if (!plan) plan = await createPlan(db, userId, input.name ?? 'My Plan', input.meta ?? null);
  if (
    input.expected_version != null &&
    input.expected_version !== plan.version
  ) {
    return { conflict: true, current_version: plan.version };
  }

  // Resolve every exercise name up front (outside the batch).
  const resolved = new Map<string, string>();
  for (const d of input.days) {
    for (const e of d.exercises ?? []) {
      if (!resolved.has(e.exercise)) {
        resolved.set(e.exercise, await resolveOrThrow(db, e.exercise));
      }
    }
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

  const stmts: D1PreparedStatement[] = [
    db
      .prepare(
        'DELETE FROM template_exercises WHERE day_template_id IN (SELECT id FROM day_templates WHERE plan_id = ?1)',
      )
      .bind(plan.id),
    db.prepare('DELETE FROM day_templates WHERE plan_id = ?1').bind(plan.id),
  ];
  input.days.forEach((d, di) => {
    const dayId = newDayIds[di]!;
    stmts.push(
      db
        .prepare(
          'INSERT INTO day_templates (id,plan_id,name,day_label,order_index,notes,created_at,updated_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8)',
        )
        .bind(dayId, plan!.id, d.name, d.day_label ?? null, d.order_index ?? di, d.notes ?? null, ts, ts),
    );
    (d.exercises ?? []).forEach((e, ei) => {
      stmts.push(
        db
          .prepare(
            `INSERT INTO template_exercises
             (id,day_template_id,exercise_id,order_index,target_sets,target_reps,target_reps_max,target_rpe,rest_seconds,target_weight,progression,cues,created_at,updated_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14)`,
          )
          .bind(
            uuid(), dayId, resolved.get(e.exercise)!, e.order_index ?? ei, e.target_sets,
            e.target_reps, e.target_reps_max ?? null, e.target_rpe ?? null, e.rest_seconds ?? 120,
            e.target_weight ?? null, e.progression == null ? null : JSON.stringify(e.progression),
            e.cues ?? null, ts, ts,
          ),
      );
    });
  });
  // The full tree is rebuilt with fresh day UUIDs. Re-point each schedule
  // weekday at the NEW day whose name/label matches the OLD day it pointed
  // at; weekdays whose day genuinely no longer exists (no matching new day)
  // are cleared. Same batch ⇒ shares the single version bump. Never lose
  // the schedule key.
  const baseMeta =
    input.meta === undefined
      ? parsePlanMeta(plan.meta)
      : parsePlanMeta(JSON.stringify(input.meta));
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
      | 'cues'
    >
  > & { progression?: unknown },
): Promise<TemplateExerciseRow | null> {
  const slot = await findSlot(db, userId, ref);
  if (!slot) return null;
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
    cues: patch.cues === undefined ? slot.cues : patch.cues,
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
       target_rpe=?5,rest_seconds=?6,target_weight=?7,cues=?8,progression=?9,updated_at=?10
       WHERE id=?1`,
    )
    .bind(
      slot.id, m.target_sets, m.target_reps, m.target_reps_max, m.target_rpe,
      m.rest_seconds, m.target_weight, m.cues, m.progression, m.updated_at,
    )
    .run();
  await bumpPlanVersionByDay(db, slot.day_template_id);
  return m;
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
  return patchSession(db, userId, session.id, {
    status: 'completed',
    perceived_fatigue: perceivedFatigue ?? undefined,
    notes: notes ?? undefined,
  });
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
  const rows = await db
    .prepare(
      `SELECT strftime('%Y-%W', s.date) AS week,
              COUNT(*) AS hard_sets,
              SUM(sl.weight * sl.reps) AS tonnage
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
    await db
      .prepare(
        "UPDATE sessions SET day_template_id = ?2, status = CASE WHEN status IN ('completed','in_progress') THEN status ELSE 'planned' END, updated_at = ?3 WHERE id = ?1",
      )
      .bind(existing.id, d.id, ts)
      .run();
    return {
      ok: true,
      session: { ...existing, day_template_id: d.id, updated_at: ts },
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
): Promise<{ error: 'no_active_plan' } | { ok: true; session: SessionRow }> {
  const plan = await getActivePlan(db, userId);
  if (!plan) return { error: 'no_active_plan' };
  const existing = await db
    .prepare('SELECT * FROM sessions WHERE user_id = ?1 AND date = ?2 ORDER BY created_at LIMIT 1')
    .bind(userId, date)
    .first<SessionRow>();
  const ts = now();
  if (existing) {
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
