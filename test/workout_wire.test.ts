import { applyD1Migrations, env, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { workoutInput, workoutWire } from '../src/workoutWire';

beforeAll(async () => applyD1Migrations(env.DB, env.TEST_MIGRATIONS.filter(m => m.name !== '0045_workouts.sql')));
const base = 'https://tres-fort.test';
async function tool(name: string, args: unknown = {}) {
  const response = await SELF.fetch(`${base}/mcp`, { method: 'POST',
    headers: { Authorization: 'Bearer test-mcp-token', 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: args } }) });
  const rpc = await response.json<any>();
  return JSON.parse(rpc.result.content[0].text);
}

it('keeps opaque content unchanged and rejects contradictory aliases', () => {
  const opaque = { workouts: ['user text'], workout_id: 'not a field to rename' };
  expect(workoutWire({ workouts: [{ id: 'w' }], meta: opaque, notes: opaque, document: opaque }))
    .toEqual({ workouts: [{ id: 'w' }], days: [{ id: 'w' }], meta: opaque, notes: opaque, document: opaque });
  expect(workoutInput({ workouts: [{ name: 'A', exercises: [] }], days: [{ exercises: [], name: 'A' }] }))
    .toEqual({ workouts: [{ exercises: [], name: 'A' }] });
  expect(() => workoutInput({ workout_id: null, day_template_id: 'w' })).toThrow('conflicting_workout_fields');
});

describe.each([false, true])('wire contracts with migrated=%s', (migrated) => {
  let jwt: string;
  let tree: any;
  let gym: any;
  let hotel: string;
  let today: string;
  async function api(path: string, method = 'GET', body?: unknown) {
    const response = await SELF.fetch(`${base}/api/${path}`, { method,
      headers: { Authorization: `Bearer ${jwt}`, 'content-type': 'application/json' },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
    return { status: response.status, body: await response.json<any>() };
  }
  // Seed once per schema. Each independent test gets the same isolated snapshot;
  // no long multi-stage HTTP chain competes with the default five-second limit.
  beforeAll(async () => {
    if (migrated) await applyD1Migrations(env.DB, env.TEST_MIGRATIONS.filter(m => m.name === '0045_workouts.sql'));
    const auth = await SELF.fetch(`${base}/auth/dev`, { method: 'POST',
      headers: { 'content-type': 'application/json' }, body: JSON.stringify({ secret: 'test-dev' }) });
    jwt = (await auth.json<{ jwt: string }>()).jwt;
    const original = await tool('update_plan', { days: [{ name: 'Gym', exercises: [{ exercise: 'bench', target_sets: 3, target_reps: 5 }] }] });
    expect(original).toHaveProperty('plan');
    expect(original.plan.days).toEqual(original.plan.workouts);
    gym = original.plan.workouts[0];
    const add = await api('workouts', 'POST', { name: 'Hotel' });
    expect(add.status).toBe(201); hotel = add.body.id;
    tree = (await api('plan/active')).body;
    today = (await tool('get_today_workout')).date;
    const weekday = ['sun','mon','tue','wed','thu','fri','sat'][new Date(`${today}T12:00:00Z`).getUTCDay()]!;
    expect((await api('plan/schedule', 'PUT', { week: { [weekday]: gym.id }, expected_plan_id: tree.id, expected_version: tree.version })).status).toBe(200);
    tree = (await api('plan/active')).body;
  });

  it('accepts the released REST authoring route', async () => {
    expect((await api(`days/${hotel}`, 'PATCH', { name: 'Travel' })).status).toBe(200);
    expect((await api('plan/active')).body.workouts.find((w: any) => w.id === hotel).name).toBe('Travel');
  });

  it.each(['add_day', 'add_workout'])('audits the called %s name', async (name) => {
    const added = await tool(name, { name: 'Coach workout' });
    expect(added.id).toBeTruthy();
    const audit = await env.DB.prepare('SELECT tool FROM audit_log WHERE user_id=? AND tool=?')
      .bind(tree.user_id, name).all<{ tool: string }>();
    expect(audit.results).toContainEqual({ tool: name });
  });

  it.each(['update_day', 'update_workout'])('accepts the %s selector', async (name) => {
    const key = name === 'update_day' ? 'day_template_id' : 'workout_id';
    expect(await tool(name, { [key]: hotel, patch: { notes: 'On demand' } })).not.toHaveProperty('error');
    expect((await api('plan/active')).body.workouts.find((w: any) => w.id === hotel).notes).toBe('On demand');
  });

  it('deletes through the canonical MCP tool at the observed plan version', async () => {
    expect(await tool('delete_workout', { workout_id: hotel, expected_version: tree.version })).toMatchObject({ ok: true });
    const latest = (await api('plan/active')).body;
    expect(latest.workouts.map((w: any) => w.id)).toEqual([gym.id]);
    expect(latest.version).toBe(tree.version + 1);
  });

  it('assigns an on-demand workout over the scheduled workout without changing the recurring plan', async () => {
    const assigned = await api(`calendar/${today}`, 'PUT', { day_template_id: hotel, expected_attempt: 0 });
    expect(assigned.status).toBe(200);
    expect(assigned.body.session).toMatchObject({ workout_id: hotel, day_template_id: hotel });
    const read = (await api('state')).body;
    expect(read.plan.version).toBe(tree.version); expect(read.plan.meta).toBe(tree.meta);
    expect(read.sessions.find((s: any) => s.id === assigned.body.session.id).workout_id).toBe(hotel);
    expect((await tool('get_today_workout')).session.workout_id).toBe(hotel);
    expect((await api(`calendar/${today}`, 'PUT', { workout_id: gym.id, day_template_id: hotel, expected_attempt: assigned.body.session.attempt })).status).toBe(400);
    const retry = await api(`calendar/${today}`, 'PUT', { workout_id: hotel, expected_attempt: assigned.body.session.attempt });
    expect(retry.body.session.attempt).toBe(assigned.body.session.attempt);
  });

  it('moves a date with released request keys and dual acknowledgement fields', async () => {
    const next = new Date(`${today}T12:00:00Z`);
    next.setUTCDate(next.getUTCDate() + 1);
    const toDate = next.toISOString().slice(0, 10);
    const request = { id: crypto.randomUUID(), to_date: toDate, today,
      day_template_id: gym.id, expected_plan_id: tree.id, expected_version: tree.version,
      expected_from_attempt: 0, expected_to_attempt: 0 };
    const move = await api(`calendar/${today}/move`, 'POST', request);
    expect(move.status).toBe(200);
    expect(move.body.from).toMatchObject({ date: today, status: 'skipped',
      workout_id: null, day_template_id: null, attempt: 1 });
    expect(move.body.to).toMatchObject({ date: toDate, status: 'planned',
      workout_id: gym.id, day_template_id: gym.id, attempt: 1 });
    expect(await api(`calendar/${today}/move`, 'POST', request)).toEqual(move);
    const unchanged = (await api('plan/active')).body;
    expect(unchanged.version).toBe(tree.version);
    expect(unchanged.meta).toBe(tree.meta);
  });

  it('retains the historical account export collection name', async () => {
    const exported = (await api('me/export')).body;
    expect(exported.training.day_templates).toEqual(exported.training.workouts);
    expect(exported.training.workouts).toEqual(expect.arrayContaining([expect.objectContaining({ id: hotel })]));
  });
});
