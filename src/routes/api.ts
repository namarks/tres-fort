import { Hono } from 'hono';
import type { HonoEnv } from '../types';
import { requireAppJwt } from '../auth';
import {
  addDayTemplate,
  addTemplateExercise,
  createPlan,
  discardSession,
  getActivePlan,
  getHistory,
  getOrCreateSession,
  getPlanTree,
  getState,
  getVolume,
  logSet,
  nextExerciseOrderIndex,
  patchDayTemplate,
  patchSession,
  patchSet,
  resolveExercise,
} from '../db';

export const apiRoutes = new Hono<HonoEnv>();
apiRoutes.use('*', requireAppJwt);

const todayLocal = () => new Date().toISOString().slice(0, 10);

// ---- sync pull -----------------------------------------------------------
apiRoutes.get('/state', async (c) => {
  const userId = c.get('userId');
  const since = Number(c.req.query('since') ?? 0);
  const setsSince = Number(c.req.query('sets_since') ?? 0);
  const eventsSince = Number(c.req.query('events_since') ?? 0);
  return c.json(await getState(c.env.DB, userId, since, setsSince, eventsSince));
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
  const b = await c.req.json<{ name?: string; order_index?: number; notes?: string | null }>();
  const row = await patchDayTemplate(c.env.DB, plan.id, c.req.param('id'), b);
  return row ? c.json(row) : c.json({ error: 'not_found' }, 404);
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
  const r = await c.env.DB.prepare(
    'SELECT id, name, primary_muscle, modality, unit FROM exercises ORDER BY name',
  ).all();
  return c.json(r.results);
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
