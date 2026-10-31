import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { comparePlanSnapshots, parsePlanSnapshot, serializePlanSnapshot } from '../src/planSnapshots';
import { getPlanTree, resolveExercise } from '../src/db';
import { parseRunSteps, serializeRunSteps } from '../src/runSteps';

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
async function runSlots() {
  const plan = await tool('get_current_plan');
  return plan.workouts.flatMap((day: any) => day.exercises)
    .filter((slot: any) => slot.exercise_id === 'ex_outdoor_run')
    .map((slot: any) => slot.run_steps == null ? null : JSON.parse(slot.run_steps));
}

const intervals = [
  { duration_s: 600, kind: 'warmup' },
  { steps: [
    { target: { slowest_s_per_km: 255, type: 'pace', fastest_s_per_km: 245 }, distance_m: 800, kind: 'work' },
    { kind: 'recovery', duration_s: 120 },
  ], repeat: 4 },
  { kind: 'cooldown', duration_s: 600 },
];
// The same plan in canonical key order, as it is stored and returned.
const canonicalIntervals = [
  { kind: 'warmup', duration_s: 600 },
  { repeat: 4, steps: [
    { kind: 'work', distance_m: 800, target: { type: 'pace', fastest_s_per_km: 245, slowest_s_per_km: 255 } },
    { kind: 'recovery', duration_s: 120 },
  ] },
  { kind: 'cooldown', duration_s: 600 },
];
const zoneTwo = [{ kind: 'work', duration_s: 2400, target: { type: 'heart_rate', min_bpm: 130, max_bpm: 145 } }];

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
  const auth = await SELF.fetch(`${BASE}/auth/dev`, { method: 'POST',
    headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ secret: 'test-dev' }) });
  jwt = (await auth.json<any>()).jwt;
  await ok('plan', 'POST', { name: 'Runs' });
});

describe('run step format', () => {
  it('accepts steps, targets and repeats and stores them in one canonical order', () => {
    expect(parseRunSteps(intervals)).toEqual({ ok: true, items: canonicalIntervals });
    expect(serializeRunSteps(intervals)).toBe(JSON.stringify(canonicalIntervals));
    expect(parseRunSteps(JSON.stringify(canonicalIntervals))).toEqual({ ok: true, items: canonicalIntervals });
    expect(parseRunSteps([{ kind: 'work', distance_m: 1609.344 }])).toMatchObject({ ok: true });
    expect(serializeRunSteps(null)).toBeNull();
  });

  it('names the exact field that is wrong', () => {
    const fields = (value: unknown) => {
      const parsed = parseRunSteps(value);
      return parsed.ok ? [] : parsed.fields;
    };
    expect(fields([])).toEqual(['run_steps']);
    expect(fields({ kind: 'work' })).toEqual(['run_steps']);
    expect(fields('not json')).toEqual(['run_steps']);
    expect(fields([{ kind: 'sprint', duration_s: 30 }])).toEqual(['run_steps.0.kind']);
    expect(fields([{ kind: 'work' }])).toEqual(['run_steps.0.duration_s']);
    expect(fields([{ kind: 'work', duration_s: 60, distance_m: 400 }])).toEqual(['run_steps.0.distance_m']);
    expect(fields([{ kind: 'work', duration_s: 0 }])).toEqual(['run_steps.0.duration_s']);
    expect(fields([{ kind: 'work', duration_s: 1.5 }])).toEqual(['run_steps.0.duration_s']);
    expect(fields([{ kind: 'work', distance_m: -400 }])).toEqual(['run_steps.0.distance_m']);
    expect(fields([{ kind: 'work', duration_s: 60, pace: 300 }])).toEqual(['run_steps.0']);
    expect(fields([{ kind: 'work', duration_s: 60,
      target: { type: 'pace', fastest_s_per_km: 300, slowest_s_per_km: 280 } }])).toEqual(['run_steps.0.target']);
    expect(fields([{ kind: 'work', duration_s: 60,
      target: { type: 'heart_rate', min_bpm: 150, max_bpm: 260 } }])).toEqual(['run_steps.0.target']);
    expect(fields([{ kind: 'work', duration_s: 60, target: { type: 'power', min: 200, max: 250 } }]))
      .toEqual(['run_steps.0.target']);
    expect(fields([{ repeat: 0, steps: [{ kind: 'work', duration_s: 60 }] }])).toEqual(['run_steps.0.repeat']);
    expect(fields([{ repeat: 2, steps: [] }])).toEqual(['run_steps.0.steps']);
    expect(fields([{ repeat: 2, steps: [{ repeat: 2, steps: [{ kind: 'work', duration_s: 60 }] }] }]))
      .toEqual(['run_steps.0.steps.0']);
    expect(fields([{ kind: 'warmup', duration_s: 60 }, { repeat: 2, steps: [{ kind: 'work' }] }]))
      .toEqual(['run_steps.1.steps.0.duration_s']);
    // Bounded once repeats are expanded, not only by item count.
    expect(fields([{ repeat: 50, steps: [{ kind: 'work', duration_s: 60 }, { kind: 'recovery', duration_s: 60 },
      { kind: 'work', duration_s: 60 }, { kind: 'recovery', duration_s: 60 }, { kind: 'work', duration_s: 60 }] }]))
      .toEqual(['run_steps']);
  });
});

describe('planned runs in the plan document (migration 0058)', () => {
  it('adds an outdoor run to the catalog without taking the treadmill phrases', async () => {
    const columns = await env.DB.prepare("PRAGMA table_info('template_exercises')").all<{ name: string; notnull: number }>();
    expect(columns.results.find((column) => column.name === 'run_steps')).toMatchObject({ notnull: 0 });
    expect(await resolveExercise(env.DB, 'Outdoor Run')).toMatchObject({ id: 'ex_outdoor_run', modality: 'cardio' });
    expect(await resolveExercise(env.DB, 'tempo run')).toMatchObject({ id: 'ex_outdoor_run' });
    expect(await resolveExercise(env.DB, 'run')).toMatchObject({ id: 'ex_treadmill' });
  });

  it('stores, patches and clears steps through MCP and REST, audited like other plan edits', async () => {
    await ok('workouts', 'POST', { name: 'Track' });
    const before = await tool('get_current_plan');
    const added = await tool('add_exercise', { expected_version: before.version, day: 'Track',
      exercise: 'Outdoor Run', target_sets: 1, target_reps: 1, run_steps: intervals });
    expect(added.run_steps).toBe(JSON.stringify(canonicalIntervals));
    expect(await runSlots()).toEqual([canonicalIntervals]);
    const state = await ok('state');
    const stateSlot = state.plan.workouts.flatMap((day: any) => day.exercises)
      .find((slot: any) => slot.id === added.id);
    expect(JSON.parse(stateSlot.run_steps)).toEqual(canonicalIntervals);

    const audit = await env.DB.prepare(
      "SELECT COUNT(*) AS c FROM audit_log WHERE tool='add_exercise' AND args LIKE '%run_steps%'").first<{ c: number }>();
    expect(audit?.c).toBe(1);
    const note = await env.DB.prepare("SELECT COUNT(*) AS c FROM notes WHERE body='Added Outdoor Run to Track.'")
      .first<{ c: number }>();
    expect(note?.c).toBe(1);

    const patched = await tool('update_exercise', { template_exercise_id: added.id, patch: { run_steps: zoneTwo } });
    expect(JSON.parse(patched.run_steps)).toEqual(zoneTwo);
    expect(await runSlots()).toEqual([zoneTwo]);
    expect(await tool('update_exercise', { template_exercise_id: added.id, patch: { run_steps: [{ kind: 'work' }] } }))
      .toEqual({ error: 'invalid_fields', fields: ['run_steps.0.duration_s'] });
    // A patch of another field keeps the steps.
    expect(JSON.parse((await tool('update_exercise', { template_exercise_id: added.id,
      patch: { cues: 'Flat loop' } })).run_steps)).toEqual(zoneTwo);

    const day = (await tool('get_current_plan')).workouts.find((workout: any) => workout.name === 'Track');
    expect(await ok(`workouts/${day.id}/exercises/${added.id}`, 'PATCH', { run_steps: null }))
      .toMatchObject({ run_steps: null });
    expect(await runSlots()).toEqual([null]);
    expect(await ok(`workouts/${day.id}/exercises`, 'POST', { exercise: 'ex_outdoor_run',
      target_sets: 1, target_reps: 1, run_steps: zoneTwo })).toMatchObject({ run_steps: JSON.stringify(zoneTwo) });
    await tool('delete_exercise', { template_exercise_id: added.id });
  });

  it('keeps steps on a run', async () => {
    await ok('workouts', 'POST', { name: 'Gym' });
    expect(await tool('add_exercise', { day: 'Gym', exercise: 'ex_bench', target_sets: 3, target_reps: 5,
      run_steps: zoneTwo })).toEqual({ error: 'invalid_fields', fields: ['run_steps'] });
    expect(await tool('add_exercise', { day: 'Gym', exercise: 'Treadmill', target_sets: 1, target_reps: 1,
      run_steps: zoneTwo })).toEqual({ error: 'invalid_fields', fields: ['run_steps'] });
    const bench = await tool('add_exercise', { day: 'Gym', exercise: 'ex_bench', target_sets: 3, target_reps: 5 });
    expect(await tool('update_exercise', { template_exercise_id: bench.id, patch: { run_steps: zoneTwo } }))
      .toEqual({ error: 'invalid_fields', fields: ['run_steps'] });
    // Clearing steps that aren't there is allowed everywhere.
    expect(await tool('update_exercise', { template_exercise_id: bench.id, patch: { run_steps: null } }))
      .toMatchObject({ run_steps: null });

    const run = await tool('add_exercise', { day: 'Gym', exercise: 'Outdoor Run', target_sets: 1, target_reps: 1,
      run_steps: zoneTwo });
    expect(await tool('swap_exercise', { day: 'Gym', from_exercise: 'Outdoor Run', to_exercise: 'Treadmill' }))
      .toEqual({ error: 'invalid_fields', fields: ['run_steps'] });
    await tool('update_exercise', { template_exercise_id: run.id, patch: { run_steps: null } });
    expect(await tool('swap_exercise', { day: 'Gym', from_exercise: 'Outdoor Run', to_exercise: 'Treadmill' }))
      .toMatchObject({ exercise_id: 'ex_treadmill' });
  });

  it('travels through update_plan, snapshots, comparison and restore', async () => {
    const before = await tool('get_current_plan');
    const rebuilt = await tool('update_plan', { expected_version: before.version, workouts: [
      { name: 'Track', exercises: [
        { exercise: 'Outdoor Run', target_sets: 1, target_reps: 1, run_steps: intervals },
        { exercise: 'Outdoor Run', target_sets: 1, target_reps: 1, run_steps: zoneTwo },
      ] },
    ] });
    expect(rebuilt).toMatchObject({ conflict: false });
    expect(await runSlots()).toEqual([canonicalIntervals, zoneTwo]);

    // A rebuild that omits the steps keeps the replaced slot's; null clears them.
    const kept = await tool('get_current_plan');
    await tool('update_plan', { expected_version: kept.version, workouts: [
      { name: 'Track', exercises: [
        { exercise: 'Outdoor Run', target_sets: 1, target_reps: 1 },
        { exercise: 'Outdoor Run', target_sets: 1, target_reps: 1, run_steps: null },
      ] },
    ] });
    expect(await runSlots()).toEqual([canonicalIntervals, null]);

    // The match is positional, so changing the warm-up flag keeps them too.
    const flagged = await tool('get_current_plan');
    await tool('update_plan', { expected_version: flagged.version, workouts: [
      { name: 'Track', exercises: [
        { exercise: 'Outdoor Run', target_sets: 1, target_reps: 1, is_warmup: true },
        { exercise: 'Outdoor Run', target_sets: 1, target_reps: 1 },
      ] },
    ] });
    expect(await runSlots()).toEqual([canonicalIntervals, null]);
    const unflagged = await tool('get_current_plan');
    await tool('update_plan', { expected_version: unflagged.version, workouts: [
      { name: 'Track', exercises: [
        { exercise: 'Outdoor Run', target_sets: 1, target_reps: 1, is_warmup: false },
        { exercise: 'Outdoor Run', target_sets: 1, target_reps: 1 },
      ] },
    ] });
    expect(await runSlots()).toEqual([canonicalIntervals, null]);

    const invalid = await tool('update_plan', { expected_version: unflagged.version + 1, workouts: [
      { name: 'Track', exercises: [
        { exercise: 'Outdoor Run', target_sets: 1, target_reps: 1,
          run_steps: [{ kind: 'warmup', duration_s: 60 }, { repeat: 3, steps: [{ kind: 'work', distance_m: 400,
            target: { type: 'heart_rate', min_bpm: 170, max_bpm: 160 } }] }] },
        { exercise: 'ex_bench', target_sets: 3, target_reps: 5, run_steps: zoneTwo },
      ] },
    ] });
    expect(invalid).toEqual({ error: 'invalid_fields', fields: [
      'workouts.0.exercises.0.run_steps.1.steps.0.target', 'workouts.0.exercises.1.run_steps',
    ] });

    const userId = (await env.DB.prepare('SELECT user_id FROM plans').first<{ user_id: string }>())!.user_id;
    const tree = (await getPlanTree(env.DB, userId))!;
    const stored = await env.DB.prepare('SELECT document FROM plan_snapshots WHERE plan_id=?1 AND version=?2')
      .bind(tree.id, tree.version).first<{ document: string }>();
    expect(parsePlanSnapshot(stored!.document)).toEqual(serializePlanSnapshot(tree));
    expect(JSON.stringify(parsePlanSnapshot(stored!.document))).toBe(JSON.stringify(serializePlanSnapshot(tree)));
    expect(JSON.parse(stored!.document).workouts[0].exercises.map((slot: any) => slot.run_steps))
      .toEqual([JSON.stringify(canonicalIntervals), null]);

    // Documents written before the column read as having no steps, and
    // compare as unchanged against the same plan written afterwards.
    const legacy = JSON.parse(stored!.document);
    for (const workout of legacy.workouts) for (const slot of workout.exercises) {
      if (slot.run_steps == null) delete slot.run_steps;
    }
    const legacyDocument = parsePlanSnapshot(JSON.stringify(legacy));
    expect(legacyDocument.workouts[0]!.exercises.map((slot) => slot.run_steps))
      .toEqual([JSON.stringify(canonicalIntervals), null]);
    expect(comparePlanSnapshots(legacyDocument, parsePlanSnapshot(stored!.document)).changes).toEqual([]);

    const cleared = await tool('update_exercise', { expected_version: tree.version,
      template_exercise_id: tree.workouts[0]!.exercises[0]!.id, patch: { run_steps: zoneTwo } });
    const comparison = await tool('compare_plan_versions', { from_version: tree.version });
    expect(comparison.summary).toMatchObject({ exercises_changed: 1 });
    expect(await runSlots()).toEqual([zoneTwo, null]);
    expect(await tool('restore_plan', { plan_id: tree.id, snapshot_version: tree.version,
      expected_version: tree.version + 1 })).toMatchObject({ ok: true });
    expect(cleared.run_steps).toBe(JSON.stringify(zoneTwo));
    expect(await runSlots()).toEqual([canonicalIntervals, null]);
  });
});
