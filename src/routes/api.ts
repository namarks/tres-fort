import { Hono } from 'hono';
import type { HonoEnv } from '../types';
import { requireAppJwt } from '../auth';
import {
  addDayTemplate,
  addTemplateExercise,
  createPlan,
  discardSession,
  getActivePlan,
  getExercises,
  getHistory,
  getOrCreateSession,
  getPlanTree,
  getState,
  getVolume,
  logActivity,
  logSet,
  nextExerciseOrderIndex,
  patchDayTemplate,
  patchSession,
  patchSet,
  resolveExercise,
  softDeleteActivity,
} from '../db';

export const apiRoutes = new Hono<HonoEnv>();
apiRoutes.use('*', requireAppJwt);

const todayLocal = () => new Date().toISOString().slice(0, 10);

// ---- sync pull -----------------------------------------------------------
// Device timezone (X-Device-TZ) is captured for EVERY authenticated request
// in the requireAppJwt middleware, so it stays fresh even on non-/state
// actions after the user travels — not handled here anymore.
apiRoutes.get('/state', async (c) => {
  const userId = c.get('userId');
  const since = Number(c.req.query('since') ?? 0);
  const setsSince = Number(c.req.query('sets_since') ?? 0);
  const eventsSince = Number(c.req.query('events_since') ?? 0);
  const activitiesSince = Number(c.req.query('activities_since') ?? 0);
  // log_since gates the M3 generic activity log delta (separate cursor —
  // `activities_since` is already taken by the intervals.icu external
  // actuals cache, see migration 0015 / getState).
  const logSince = Number(c.req.query('log_since') ?? 0);
  return c.json(
    await getState(c.env.DB, userId, since, setsSince, eventsSince, activitiesSince, logSince),
  );
});

// ---- plan tree -----------------------------------------------------------
apiRoutes.get('/plan/active', async (c) => {
  const tree = await getPlanTree(c.env.DB, c.get('userId'));
  return tree ? c.json(tree) : c.json({ error: 'no_active_plan' }, 404);
});

apiRoutes.post('/plan', async (c) => {
  const b = await c.req.json<{ name: string; meta?: unknown }>();
  if (!b.name) return c.json({ error: 'missing_name' }, 400);
  return c.json(await createPlan(c.env.DB, c.get('userId'), b.name, b.meta ?? null), 201);
});

apiRoutes.post('/days', async (c) => {
  const plan = await getActivePlan(c.env.DB, c.get('userId'));
  if (!plan) return c.json({ error: 'no_active_plan' }, 400);
  const b = await c.req.json<{ name: string; day_label?: string; order_index?: number }>();
  if (!b.name) return c.json({ error: 'missing_name' }, 400);
  return c.json(
    await addDayTemplate(c.env.DB, plan.id, b.name, b.day_label ?? null, b.order_index ?? 0),
    201,
  );
});

apiRoutes.patch('/days/:id', async (c) => {
  const plan = await getActivePlan(c.env.DB, c.get('userId'));
  if (!plan) return c.json({ error: 'no_active_plan' }, 400);
  const b = await c.req.json<{
    name?: string;
    day_label?: string | null;
    order_index?: number;
    notes?: string | null;
  }>();
  const row = await patchDayTemplate(c.env.DB, plan.id, c.req.param('id'), b);
  if (!row) return c.json({ error: 'not_found' }, 404);
  if ('error' in row) return c.json(row, 400);
  return c.json(row);
});

apiRoutes.post('/days/:id/exercises', async (c) => {
  const plan = await getActivePlan(c.env.DB, c.get('userId'));
  if (!plan) return c.json({ error: 'no_active_plan' }, 400);
  const b = await c.req.json<{
    exercise: string;
    order_index?: number;
    target_sets: number;
    target_reps: number;
    target_reps_max?: number | null;
    target_rpe?: number | null;
    rest_seconds?: number;
    target_weight?: number | null;
    target_duration_s?: number | null;
    progression?: unknown;
    cues?: string | null;
  }>();
  const ex = await resolveExercise(c.env.DB, b.exercise);
  if (!ex) return c.json({ error: 'unknown_exercise', query: b.exercise }, 400);
  const dayId = c.req.param('id');
  const orderIndex =
    typeof b.order_index === 'number'
      ? b.order_index
      : await nextExerciseOrderIndex(c.env.DB, dayId);
  const row = await addTemplateExercise(c.env.DB, plan.id, {
    day_template_id: dayId,
    exercise_id: (ex as { id: string }).id,
    order_index: orderIndex,
    target_sets: b.target_sets,
    target_reps: b.target_reps,
    target_reps_max: b.target_reps_max ?? null,
    target_rpe: b.target_rpe ?? null,
    rest_seconds: b.rest_seconds ?? 120,
    target_weight: b.target_weight ?? null,
    target_duration_s: b.target_duration_s ?? null,
    progression: b.progression == null ? null : JSON.stringify(b.progression),
    cues: b.cues ?? null,
  });
  return c.json(row, 201);
});

// ---- sessions + sets -----------------------------------------------------
apiRoutes.get('/today', async (c) => {
  const userId = c.get('userId');
  const plan = await getActivePlan(c.env.DB, userId);
  if (!plan) return c.json({ error: 'no_active_plan' }, 400);
  const session = await getOrCreateSession(c.env.DB, userId, plan.id, todayLocal(), null);
  const sets = await c.env.DB
    .prepare('SELECT * FROM set_logs WHERE session_id = ?1 AND deleted_at IS NULL ORDER BY logged_at')
    .bind(session.id)
    .all();
  return c.json({ session, sets: sets.results });
});

apiRoutes.post('/sessions', async (c) => {
  const userId = c.get('userId');
  const plan = await getActivePlan(c.env.DB, userId);
  if (!plan) return c.json({ error: 'no_active_plan' }, 400);
  const b = await c.req.json<{ date?: string; day_template_id?: string | null }>();
  const s = await getOrCreateSession(
    c.env.DB,
    userId,
    plan.id,
    b.date ?? todayLocal(),
    b.day_template_id ?? null,
  );
  return c.json(s, 201);
});

apiRoutes.patch('/sessions/:id', async (c) => {
  const b = await c.req.json<{ status?: string; perceived_fatigue?: number; notes?: string }>();
  const s = await patchSession(c.env.DB, c.get('userId'), c.req.param('id'), b);
  if (!s) return c.json({ error: 'not_found' }, 404);
  if ('error' in s) {
    // Exhaustive: invalid_status → 400 (bad request, nothing persisted);
    // session_already_started → 409 (history-integrity burial guard).
    if (s.error === 'invalid_status') return c.json(s, 400);
    return c.json(s, 409);
  }
  return c.json(s);
});

// Discard a session — "I didn't really do this." Soft-deletes its sets
// and marks it 'discarded' (vanishes from the projection; excluded from
// history/volume/conflicts). Idempotent. Restarting the same date via
// GET /today or POST /sessions resurrects a fresh planned session.
apiRoutes.post('/sessions/:id/discard', async (c) => {
  const s = await discardSession(c.env.DB, c.get('userId'), c.req.param('id'));
  if (!s) return c.json({ error: 'not_found' }, 404);
  return c.json(s);
});

apiRoutes.post('/sessions/:id/sets', async (c) => {
  const b = await c.req.json<{
    id: string;
    exercise_id: string;
    set_index: number;
    weight: number;
    reps: number;
    rpe?: number | null;
    is_warmup?: boolean;
    template_exercise_id?: string | null;
    notes?: string | null;
    logged_at?: number;
    duration_s?: number | null;
  }>();
  if (!b.id) return c.json({ error: 'missing_set_id' }, 400);
  try {
    const result = await logSet(c.env.DB, c.get('userId'), {
      ...b,
      session_id: c.req.param('id'),
      source: 'ios',
    });
    return c.json(result, result.deduped ? 200 : 201);
  } catch (e) {
    return c.json({ error: (e as Error).message }, 404);
  }
});

apiRoutes.patch('/sets/:id', async (c) => {
  const b = await c.req.json<{
    weight?: number;
    reps?: number;
    rpe?: number | null;
    notes?: string | null;
    deleted?: boolean;
  }>();
  const row = await patchSet(c.env.DB, c.get('userId'), c.req.param('id'), b);
  return row ? c.json(row) : c.json({ error: 'not_found' }, 404);
});

// ---- read models ---------------------------------------------------------
apiRoutes.get('/exercises', async (c) => {
  // Funnel through getExercises so the wire shape matches MCP's
  // list_exercises — in particular, `laterality` rides along, which iOS
  // needs to compute per-side rollups (Bulgarian split squat 45×8 →
  // 16 reps / 720 lb instead of 8 / 360).
  return c.json(await getExercises(c.env.DB));
});

apiRoutes.get('/history', async (c) => {
  const exerciseId = c.req.query('exercise_id');
  if (!exerciseId) return c.json({ error: 'missing_exercise_id' }, 400);
  const from = Number(c.req.query('from') ?? 0);
  const to = Number(c.req.query('to') ?? Date.now());
  return c.json(await getHistory(c.env.DB, c.get('userId'), exerciseId, from, to));
});

apiRoutes.get('/volume', async (c) => {
  const muscle = c.req.query('muscle');
  if (!muscle) return c.json({ error: 'missing_muscle' }, 400);
  const from = Number(c.req.query('from') ?? 0);
  const to = Number(c.req.query('to') ?? Date.now());
  return c.json(await getVolume(c.env.DB, c.get('userId'), muscle, from, to));
});

// ---- generic activities (M3 — pilates / cardio / yoga / walks / …) -------
//
// Append-only log, client-UUID idempotent (same model as POST /sessions/:id/
// sets). The iOS outbox can retry safely; the second POST with the same `id`
// returns the existing row instead of duplicating.

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ISO_DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

apiRoutes.post('/activities', async (c) => {
  const b = await c.req.json<{
    id?: string;
    date?: string;
    type?: string;
    title?: string | null;
    duration_minutes?: number | null;
    notes?: string | null;
    logged_at?: number;
  }>();
  if (!b.id || typeof b.id !== 'string' || !UUID_RE.test(b.id)) {
    return c.json({ error: 'invalid_id' }, 400);
  }
  if (typeof b.date !== 'string' || !ISO_DATE_RE.test(b.date)) {
    return c.json({ error: 'invalid_date' }, 400);
  }
  if (typeof b.type !== 'string' || b.type.length === 0 || b.type !== b.type.toLowerCase()) {
    return c.json({ error: 'invalid_type' }, 400);
  }
  if (typeof b.logged_at !== 'number' || !Number.isFinite(b.logged_at)) {
    return c.json({ error: 'invalid_logged_at' }, 400);
  }
  const row = await logActivity(
    c.env.DB,
    c.get('userId'),
    {
      id: b.id,
      date: b.date,
      type: b.type,
      title: b.title ?? null,
      duration_minutes:
        typeof b.duration_minutes === 'number' ? b.duration_minutes : null,
      notes: b.notes ?? null,
      logged_at: b.logged_at,
    },
    'ios',
  );
  return c.json(row, 201);
});

apiRoutes.delete('/activities/:id', async (c) => {
  const ok = await softDeleteActivity(c.env.DB, c.get('userId'), c.req.param('id'));
  if (!ok) return c.json({ error: 'not_found' }, 404);
  return c.json({ ok: true });
});
