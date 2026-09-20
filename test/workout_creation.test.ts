import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, expect, it } from 'vitest';

beforeAll(async () => { await applyD1Migrations(env.DB, env.TEST_MIGRATIONS); });
const BASE = 'https://tres-fort.test';
async function setup() {
  const signIn = await SELF.fetch(`${BASE}/auth/dev`, { method: 'POST',
    headers: { 'content-type': 'application/json' }, body: JSON.stringify({ secret: 'test-dev' }) });
  const { jwt } = await signIn.json<{ jwt: string }>();
  const headers = { 'content-type': 'application/json', Authorization: `Bearer ${jwt}` };
  const ensured = await SELF.fetch(`${BASE}/api/plan/active`, { method: 'PUT', headers,
    body: JSON.stringify({ name: 'Training' }) });
  const { plan } = await ensured.json<{ plan: { id: string; version: number } }>();
  const create = (fields: Record<string, unknown>, path = 'workouts') => SELF.fetch(`${BASE}/api/${path}`, {
    method: 'POST', headers, body: JSON.stringify({ name: 'Workout 1',
      expected_plan_id: plan.id, expected_version: plan.version, ...fields }),
  });
  return { plan, create };
}

it('creates the selected exercises in order with one version and a complete snapshot', async () => {
  const { plan, create } = await setup();
  const selected = ['ex_bench', 'ex_back_squat', 'ex_plank', 'ex_row_erg'];
  // Check the real seed ID rather than relying on an alias during insertion.
  const cardio = await env.DB.prepare("SELECT id FROM exercises WHERE modality='cardio' LIMIT 1").first<{id:string}>();
  selected[3] = cardio!.id;
  const result = await create({ exercise_ids: selected });
  expect(result.status).toBe(201);
  const workout = await result.json<{ id: string }>();
  const slots = await env.DB.prepare('SELECT * FROM template_exercises WHERE workout_id=? ORDER BY order_index')
    .bind(workout.id).all();
  expect(slots.results.map(row => row.exercise_id)).toEqual(selected);
  expect(slots.results.map(row => row.order_index)).toEqual([0, 1, 2, 3]);
  expect(slots.results.map(row => row.target_weight)).toEqual([0, 0, 0, 0]);
  expect(slots.results[0]).toMatchObject({ target_sets: 3, target_reps: 8, target_duration_s: null });
  expect(slots.results[2]).toMatchObject({ target_sets: 3, target_reps: 45, target_duration_s: 45 });
  expect(slots.results[3]).toMatchObject({ target_sets: 1, target_duration_s: 300 });
  expect((await env.DB.prepare('SELECT version FROM plans WHERE id=?').bind(plan.id).first())?.version).toBe(plan.version + 1);
  const snapshot = await env.DB.prepare('SELECT * FROM plan_snapshots WHERE plan_id=? AND version=?')
    .bind(plan.id, plan.version + 1).first();
  expect(JSON.stringify(snapshot)).toContain(workout.id);
  expect(JSON.stringify(snapshot)).toContain(slots.results[3]!.id);
  const audit = await env.DB.prepare("SELECT * FROM audit_log WHERE tool='add_workout'").all();
  expect(audit.results).toHaveLength(1);
  expect(audit.results[0]!.actor).toBe('ios');
  // Same captured request cannot append a second workout after a lost reply.
  expect((await create({ exercise_ids: selected })).status).toBe(409);
  expect((await env.DB.prepare('SELECT id FROM workouts WHERE plan_id=?').bind(plan.id).all()).results).toHaveLength(1);
});

it.each([
  { name: 'empty selection', fields: { exercise_ids: [] } },
  { name: 'unknown exercise', fields: { exercise_ids: ['ex_bench', 'missing'] } },
  { name: 'duplicate selection', fields: { exercise_ids: ['ex_bench', 'ex_bench'] } },
  { name: 'non-string ID', fields: { exercise_ids: [null] } },
  { name: 'non-array selection', fields: { exercise_ids: 'ex_bench' } },
  { name: 'oversized selection', fields: { exercise_ids: Array(51).fill('ex_bench') } },
  { name: 'missing version', fields: { exercise_ids: ['ex_bench'], expected_version: undefined } },
])('rejects $name without changing durable state', async ({ fields }) => {
  const { plan, create } = await setup();
  expect((await create(fields)).status).toBe(400);
  expect((await env.DB.prepare('SELECT id FROM workouts WHERE plan_id=?').bind(plan.id).all()).results).toHaveLength(0);
  expect((await env.DB.prepare('SELECT version FROM plans WHERE id=?').bind(plan.id).first())?.version).toBe(plan.version);
  expect((await env.DB.prepare("SELECT id FROM audit_log WHERE tool='add_workout'").all()).results).toHaveLength(0);
});

it('lets one concurrent selection win and supports empty canonical workout creation', async () => {
  const { plan, create } = await setup();
  const replies = await Promise.all([create({ exercise_ids: ['ex_bench'] }), create({ exercise_ids: ['ex_back_squat'] })]);
  expect(replies.map(r => r.status).sort()).toEqual([201, 409]);
  const workouts = await env.DB.prepare('SELECT id FROM workouts WHERE plan_id=?').bind(plan.id).all<{id:string}>();
  expect(workouts.results).toHaveLength(1);
  expect((await env.DB.prepare('SELECT id FROM template_exercises WHERE workout_id=?').bind(workouts.results[0]!.id).all()).results).toHaveLength(1);
  expect((await create({ name: 'Empty workout', expected_version: plan.version + 1 })).status).toBe(201);
});
