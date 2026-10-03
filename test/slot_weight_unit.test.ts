import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { parsePlanSnapshot, serializePlanSnapshot } from '../src/planSnapshots';
import { getPlanTree } from '../src/db';

const BASE = 'https://tres-fort.test';
let jwt: string;

async function rest(path: string, method = 'GET', body?: unknown) {
  return SELF.fetch(`${BASE}/api/${path}`, {
    method, headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${jwt}` },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}
async function ok(path: string, method = 'GET', body?: unknown) {
  const response = await rest(path, method, body);
  if (!response.ok) throw new Error(`${method} ${path}: ${response.status} ${await response.text()}`);
  return response.json<any>();
}
async function tool(name: string, args: Record<string, unknown> = {}) {
  const r = await SELF.fetch(`${BASE}/mcp`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer test-mcp-token' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: args } }),
  });
  expect(r.status).toBe(200);
  return JSON.parse((await r.json<any>()).result.content[0].text);
}
async function slot(dayId: string, exercise: string, weight: number, unit?: string, extra = {}) {
  return ok(`workouts/${dayId}/exercises`, 'POST', { exercise, target_sets: 2, target_reps: 5,
    target_weight: weight, ...(unit === undefined ? {} : { target_weight_unit: unit }), ...extra });
}
async function units() {
  const plan = await tool('get_current_plan');
  return Object.fromEntries(plan.workouts.flatMap((day: any) => day.exercises)
    .map((slot: any) => [slot.exercise_id, [slot.target_weight, slot.target_weight_unit]]));
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
  const auth = await SELF.fetch(`${BASE}/auth/dev`, { method: 'POST',
    headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ secret: 'test-dev' }) });
  jwt = (await auth.json<any>()).jwt;
  await ok('plan', 'POST', { name: 'Units' });
});

describe('per-slot target_weight_unit (migration 0055)', () => {
  it('stores each slot unit through REST and MCP writers and reads it back', async () => {
    const columns = await env.DB.prepare("PRAGMA table_info('template_exercises')")
      .all<{ name: string; notnull: number; dflt_value: string | null }>();
    expect(columns.results.find((c) => c.name === 'target_weight_unit'))
      .toMatchObject({ notnull: 1, dflt_value: "'lb'" });

    const day = await ok('workouts', 'POST', { name: 'Bells' });
    expect(await slot(day.id, 'ex_bench', 24, 'kg')).toMatchObject({ target_weight: 24, target_weight_unit: 'kg' });
    const squat = await slot(day.id, 'ex_back_squat', 135);
    expect(squat.target_weight_unit).toBe('lb');
    const invalid = await rest(`workouts/${day.id}/exercises`, 'POST',
      { exercise: 'ex_barbell_row', target_sets: 2, target_reps: 5, target_weight: 20, target_weight_unit: 'stone' });
    expect(invalid.status).toBe(400);
    expect(await invalid.json()).toEqual({ error: 'invalid_fields', fields: ['target_weight_unit'] });

    expect(await ok(`workouts/${day.id}/exercises/${squat.id}`, 'PATCH', { target_weight_unit: 'kg' }))
      .toMatchObject({ target_weight: 135, target_weight_unit: 'kg' });
    expect(await tool('update_exercise', { template_exercise_id: squat.id, patch: { target_weight: 60 } }))
      .toMatchObject({ target_weight: 60, target_weight_unit: 'kg' });
    expect(await tool('update_exercise', { template_exercise_id: squat.id, patch: { target_weight_unit: 'stone' } }))
      .toEqual({ error: 'invalid_fields', fields: ['target_weight_unit'] });
    expect(await tool('add_exercise', { day: 'Bells', exercise: 'ex_barbell_row', target_sets: 3,
      target_reps: 8, target_weight: 20, target_weight_unit: 'kg' })).toMatchObject({ target_weight_unit: 'kg' });

    expect(await units()).toEqual({ ex_bench: [24, 'kg'], ex_back_squat: [60, 'kg'], ex_barbell_row: [20, 'kg'] });
    const state = await ok('state');
    expect(JSON.stringify(state)).toContain('"target_weight_unit":"kg"');
  });

  it('keeps slot units through update_plan, snapshots and restore', async () => {
    const day = await ok('workouts', 'POST', { name: 'Bells' });
    await slot(day.id, 'ex_bench', 24, 'kg');
    const before = await tool('get_current_plan');
    // A rebuild that omits the unit keeps the replaced slot's unit; a new slot
    // defaults to lb; an explicit unit always wins.
    await tool('update_plan', { expected_version: before.version, workouts: [{ name: 'Bells', exercises: [
      { exercise: 'ex_bench', target_sets: 3, target_reps: 6, target_weight: 24 },
      { exercise: 'ex_back_squat', target_sets: 3, target_reps: 5, target_weight: 135 },
      { exercise: 'ex_barbell_row', target_sets: 3, target_reps: 8, target_weight: 20, target_weight_unit: 'kg' },
    ] }] });
    expect(await units()).toEqual({ ex_bench: [24, 'kg'], ex_back_squat: [135, 'lb'], ex_barbell_row: [20, 'kg'] });
    const rebuilt = (await getPlanTree(env.DB, (await env.DB.prepare('SELECT user_id FROM plans').first<any>()).user_id))!;
    const stored = await env.DB.prepare('SELECT document FROM plan_snapshots WHERE plan_id=?1 AND version=?2')
      .bind(rebuilt.id, rebuilt.version).first<{ document: string }>();
    expect(parsePlanSnapshot(stored!.document)).toEqual(serializePlanSnapshot(rebuilt));
    expect(JSON.parse(stored!.document).workouts[0].exercises.map((s: any) => s.target_weight_unit))
      .toEqual(['kg', 'lb', 'kg']);
    const invalid = await tool('update_plan', { expected_version: rebuilt.version, workouts: [{ name: 'Bells',
      exercises: [{ exercise: 'ex_bench', target_sets: 3, target_reps: 6, target_weight: 24, target_weight_unit: 'stone' }] }] });
    expect(invalid).toEqual({ error: 'invalid_fields', fields: ['workouts.0.exercises.0.target_weight_unit'] });

    const pounds = await tool('update_plan', { expected_version: rebuilt.version, workouts: [{ name: 'Bells',
      exercises: [{ exercise: 'ex_bench', target_sets: 3, target_reps: 6, target_weight: 53, target_weight_unit: 'lb' }] }] });
    expect(await units()).toEqual({ ex_bench: [53, 'lb'] });
    const restored = await tool('restore_plan', { plan_id: rebuilt.id, snapshot_version: rebuilt.version,
      expected_version: pounds.version ?? rebuilt.version + 1 });
    expect(restored).toMatchObject({ ok: true });
    expect(await units()).toEqual({ ex_bench: [24, 'kg'], ex_back_squat: [135, 'lb'], ex_barbell_row: [20, 'kg'] });

    // Documents written before the column existed were authored in lb.
    const legacy = JSON.parse(stored!.document);
    for (const workout of legacy.workouts) for (const exercise of workout.exercises) delete exercise.target_weight_unit;
    expect(parsePlanSnapshot(JSON.stringify(legacy)).workouts[0]!.exercises.map((s) => s.target_weight_unit))
      .toEqual(['lb', 'lb', 'lb']);
  });

  it('logs MCP sets in the slot unit and compares runner targets in their unit', async () => {
    const day = await ok('workouts', 'POST', { name: 'Bells' });
    const bench = await slot(day.id, 'ex_bench', 24, 'kg');
    const session = await ok('sessions', 'POST', { date: '2026-09-10', workout_id: day.id });
    const set = async (weight: number, unit: string, index: number) => ok(`sessions/${session.id}/sets`, 'POST', {
      id: crypto.randomUUID(), exercise_id: 'ex_bench', template_exercise_id: bench.id, set_index: index,
      weight, reps: 5, weight_unit: unit, expected_attempt: session.attempt });
    await set(24, 'kg', 1);
    await set(24, 'lb', 2);
    const captured = await env.DB.prepare('SELECT runner_targets FROM sessions WHERE id=?1')
      .bind(session.id).first<{ runner_targets: string }>();
    expect(JSON.parse(captured!.runner_targets).slots).toEqual([expect.objectContaining({ weight: 24, weight_unit: 'kg' })]);
    await ok(`sessions/${session.id}?expected_attempt=${session.attempt}`, 'PATCH', { status: 'completed' });
    // 24 kg met the 24 kg target; 24 lb did not.
    expect((await ok(`sessions/${session.id}/summary`)).targets)
      .toEqual([expect.objectContaining({ actual_sets: 2, changed_sets: 1 })]);

    // An MCP set with no unit inherits the session workout's slot unit.
    const planned = await ok('sessions', 'POST', { date: '2026-09-11', workout_id: day.id });
    const inherited = await tool('log_set', { exercise: 'ex_bench', weight: 24, reps: 6, session_date: '2026-09-11' });
    expect(inherited.session_id).toBe(planned.id);
    expect(inherited.set).toMatchObject({ weight: 24, weight_unit: 'kg' });
    expect(inherited.effective.weight_display).toBe('24 kg');
    const explicit = await tool('log_set', { exercise: 'ex_bench', weight: 53, reps: 6, weight_unit: 'lb',
      session_date: '2026-09-11' });
    expect(explicit.set.weight_unit).toBe('lb');
    expect(await tool('log_set', { exercise: 'ex_bench', weight: 53, reps: 6, weight_unit: 'stone',
      session_date: '2026-09-11' })).toEqual({ error: 'invalid_fields', fields: ['weight_unit'] });
    // A freestyle set has no slot, so it defaults to lb.
    const freestyle = await tool('log_set', { exercise: 'ex_bench', weight: 24, reps: 6, session_date: '2026-09-12' });
    expect(freestyle.set.weight_unit).toBe('lb');

    expect(await tool('correct_set', { set_id: explicit.set.id, weight: 24, weight_unit: 'kg' }))
      .toMatchObject({ weight: 24, weight_unit: 'kg' });
    expect(await tool('correct_set', { set_id: explicit.set.id, weight_unit: 'stone' }))
      .toEqual({ error: 'invalid_fields', fields: ['weight_unit'] });
    const patched = await ok(`sets/${explicit.set.id}`, 'PATCH', { weight_unit: 'lb' });
    expect(patched).toMatchObject({ weight: 24, weight_unit: 'lb' });
    expect(patched.updated_at).toBeGreaterThan(explicit.set.updated_at);
  });

  it('separates recent duplicates by unit when the coach names one', async () => {
    const day = await ok('workouts', 'POST', { name: 'Bells' });
    const session = await ok('sessions', 'POST', { date: '2026-09-13', workout_id: day.id });
    await ok(`sessions/${session.id}/sets`, 'POST', { id: crypto.randomUUID(), exercise_id: 'ex_bench',
      set_index: 1, weight: 24, reps: 5, weight_unit: 'kg', expected_attempt: session.attempt });
    expect(await tool('log_set', { exercise: 'ex_bench', weight: 24, reps: 5 }))
      .toMatchObject({ error: 'recent_duplicate' });
    expect(await tool('log_set', { exercise: 'ex_bench', weight: 24, reps: 5, weight_unit: 'kg' }))
      .toMatchObject({ error: 'recent_duplicate' });
    expect((await tool('log_set', { exercise: 'ex_bench', weight: 24, reps: 5, weight_unit: 'lb' })).set)
      .toMatchObject({ weight: 24, weight_unit: 'lb' });
  });

  it('rounds a reduced kg target to 2.5 kg and a pound target to 5 lb', async () => {
    const day = await ok('workouts', 'POST', { name: 'Bells' });
    await slot(day.id, 'ex_bench', 24, 'kg');
    await slot(day.id, 'ex_back_squat', 135, 'lb');
    const result = await tool('adjust_today', { intent: 'reduce_intensity', magnitude: 'moderate' });
    expect(result.changes).toEqual(expect.arrayContaining([
      expect.stringContaining('weight 24→22.5 kg'), expect.stringContaining('weight 135→120 lb')]));
    expect(await units()).toEqual({ ex_bench: [22.5, 'kg'], ex_back_squat: [120, 'lb'] });
  });

  it('drafts and saves a freestyle workout in each load\'s logged unit', async () => {
    // Freestyle sessions exist only once the workout write fence is active.
    await env.DB.prepare('UPDATE workout_write_fence SET enabled=1,activated_at=1 WHERE id=1').run();
    const session = await ok('sessions', 'POST', { date: '2026-09-14', kind: 'freestyle', expected_attempt: 0 });
    for (const [index, unit] of ['kg', 'kg', 'lb'].entries()) {
      await ok(`sessions/${session.id}/sets`, 'POST', { id: crypto.randomUUID(), exercise_id: 'ex_bench',
        set_index: index + 1, weight: 24, reps: 5, weight_unit: unit, expected_attempt: session.attempt });
    }
    await ok(`sessions/${session.id}?expected_attempt=${session.attempt}`, 'PATCH', { status: 'completed' });
    const draft = await ok(`sessions/${session.id}/workout-draft`);
    expect(draft.slots.map((s: any) => [s.target_weight, s.target_weight_unit, s.target_sets]))
      .toEqual([[24, 'kg', 2], [24, 'lb', 1]]);
    const plan = await tool('get_current_plan');
    // An older client omits the unit; each reviewed load keeps its source unit.
    const saved = await ok(`sessions/${session.id}/save-workout`, 'POST', {
      workout_id: crypto.randomUUID(), name: 'Hotel', expected_plan_id: plan.id, expected_version: plan.version,
      expected_attempt: session.attempt, source_signature: draft.source_signature,
      slots: draft.slots.map(({ is_timed, target_weight_unit, ...s }: any) => s) });
    const slots = (await tool('get_current_plan')).workouts.find((w: any) => w.id === saved.workout_id).exercises;
    expect(slots.map((s: any) => [s.target_weight, s.target_weight_unit])).toEqual([[24, 'kg'], [24, 'lb']]);
  });
});
