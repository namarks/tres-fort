import { applyD1Migrations, env, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { acceptStarterWorkout, getPlanTree, saveTrainingProfile, upsertUser } from '../src/db';

beforeAll(async () => applyD1Migrations(env.DB, env.TEST_MIGRATIONS));
const base = 'https://tres-fort.test';
async function rpc(method: string, params: unknown = {}) {
  const response = await SELF.fetch(`${base}/mcp`, { method: 'POST',
    headers: { Authorization: 'Bearer test-mcp-token', 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
  return response.json<any>();
}
async function tool(name: string, args: unknown = {}) {
  const result = await rpc('tools/call', { name, arguments: args });
  return JSON.parse(result.result.content[0].text);
}

describe('canonical workout contract', () => {
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
  // Seed the migrated schema. Each independent test gets the same isolated snapshot;
  // no long multi-stage HTTP chain competes with the default five-second limit.
  beforeAll(async () => {
    const auth = await SELF.fetch(`${base}/auth/dev`, { method: 'POST',
      headers: { 'content-type': 'application/json' }, body: JSON.stringify({ secret: 'test-dev' }) });
    jwt = (await auth.json<{ jwt: string }>()).jwt;
    const original = await tool('update_plan', { workouts: [{ name: 'Gym', exercises: [{ exercise: 'bench', target_sets: 3, target_reps: 5 }] }] });
    expect(original).toHaveProperty('plan');
    expect(original.plan).not.toHaveProperty('days');
    gym = original.plan.workouts[0];
    const add = await api('workouts', 'POST', { name: 'Hotel' });
    expect(add.status).toBe(201); hotel = add.body.id;
    tree = (await api('plan/active')).body;
    today = (await tool('get_today_workout')).date;
    const weekday = ['sun','mon','tue','wed','thu','fri','sat'][new Date(`${today}T12:00:00Z`).getUTCDay()]!;
    expect((await api('plan/schedule', 'PUT', { week: { [weekday]: gym.id }, expected_plan_id: tree.id, expected_version: tree.version })).status).toBe(200);
    tree = (await api('plan/active')).body;
  });

  it('creates and replays a starter on the migrated schema', async () => {
    const member = await upsertUser(env.DB, crypto.randomUUID(), null, 'Synthetic starter member');
    await saveTrainingProfile(env.DB, member.id, { goal: 'general_fitness', activities: ['running'],
      activity_context: '', experience: 'new', strength_days: 2, session_minutes: 30,
      equipment: 'bodyweight', avoid: [], baselines: [] }, 0);
    const first = await acceptStarterWorkout(env.DB, member.id, 'bodyweight-v1', 1);
    expect(first).toMatchObject({ acknowledged: true, version: 2 });
    expect(await acceptStarterWorkout(env.DB, member.id, 'bodyweight-v1', 1)).toEqual(first);
    const tree = await getPlanTree(env.DB, member.id);
    expect(tree?.workouts).toHaveLength(1);
    expect(tree?.workouts[0]?.exercises).toHaveLength(3);
  });

  it('edits through the canonical REST authoring route', async () => {
    expect((await api(`workouts/${hotel}`, 'PATCH', { name: 'Travel' })).status).toBe(200);
    expect((await api('plan/active')).body.workouts.find((w: any) => w.id === hotel).name).toBe('Travel');
  });

  it('rejects retired routes, tools and fields without changing training data', async () => {
    const before = (await api('state')).body;
    const auditCount = await env.DB.prepare('SELECT COUNT(*) AS n FROM audit_log').first('n');
    const removed = await SELF.fetch(`${base}/api/days/${hotel}`, { method: 'PATCH',
      headers: { Authorization: `Bearer ${jwt}`, 'content-type': 'application/json' },
      body: JSON.stringify({ name: 'Must not change' }) });
    expect(removed.status).toBe(404);
    for (const [path, method] of [[`calendar/${today}`, 'PUT'], ['sessions', 'POST']]) {
      expect(await api(path!, method!, { date: today, day_template_id: hotel, expected_attempt: 0 }))
        .toMatchObject({ status: 400, body: { error: 'unsupported_workout_fields' } });
    }
    const listed = await rpc('tools/list');
    const names = listed.result.tools.map((t: any) => t.name);
    expect(names).toEqual(expect.arrayContaining(['add_workout', 'update_workout', 'delete_workout']));
    for (const name of ['add_day', 'update_day']) {
      expect(names).not.toContain(name);
      expect(await rpc('tools/call', { name, arguments: { name: 'Must not create' } }))
        .toMatchObject({ error: { code: -32602 } });
    }
    for (const [name, args] of [
      ['update_plan', { days: [] }],
      ['update_workout', { day_template_id: hotel, patch: { notes: 'Must not change' } }],
      ['delete_exercise', { target: { day_template_id: gym.id, exercise: 'bench' } }],
    ]) {
      expect(await rpc('tools/call', { name, arguments: args })).toMatchObject({ error: { code: -32602 } });
    }
    const after = (await api('state')).body;
    expect(after.plan).toEqual(before.plan);
    expect(after.sessions).toEqual(before.sessions);
    expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM audit_log').first('n')).toBe(auditCount);
  });

  it('returns canonical state and coach fields while preserving opaque metadata', async () => {
    const meta = { workouts: ['member text'], days: ['member text'], day_template_id: 'member text' };
    const result = await tool('update_plan', { meta, workouts: [{ name: 'Lift', exercises: [] }] });
    expect(JSON.parse(result.plan.meta)).toMatchObject(meta);
    expect(result.plan).not.toHaveProperty('days');
    const state = (await api('state')).body;
    expect(state.plan).not.toHaveProperty('days');
    expect((await rpc('tools/list')).result.tools.find((t: any) => t.name === 'update_plan').inputSchema.properties)
      .not.toHaveProperty('days');
  });

  it.each(['day_template_id', 'days', 'plan_days'])('rejects retired %s on slot writes before changing the tree or trail', async (field) => {
    const before = (await api('plan/active')).body;
    const trail = () => env.DB.prepare(`SELECT
      (SELECT COUNT(*) FROM audit_log) AS audits,
      (SELECT COUNT(*) FROM notes) AS notes,
      (SELECT COUNT(*) FROM plan_snapshots) AS snapshots`).first();
    const originalTrail = await trail();
    expect(await api(`workouts/${gym.id}/exercises`, 'POST', {
      exercise: 'bench', target_sets: 3, target_reps: 5, [field]: 'retired',
    })).toMatchObject({ status: 400, body: { error: 'unsupported_workout_fields' } });
    expect(await api(`workouts/${gym.id}/exercises/${gym.exercises[0].id}`, 'PATCH', {
      target_reps: 9, [field]: 'retired',
    })).toMatchObject({ status: 400, body: { error: 'unsupported_workout_fields' } });
    expect((await api('plan/active')).body).toEqual(before);
    expect(await trail()).toEqual(originalTrail);
  });

  it.each(['add_workout'])('audits the called %s name', async (name) => {
    const added = await tool(name, { name: 'Coach workout' });
    expect(added.id).toBeTruthy();
    const audit = await env.DB.prepare('SELECT tool FROM audit_log WHERE user_id=? AND tool=?')
      .bind(tree.user_id, name).all<{ tool: string }>();
    expect(audit.results).toContainEqual({ tool: name });
  });

  it.each(['update_workout'])('accepts the %s selector', async (name) => {
    expect(await tool(name, { workout_id: hotel, patch: { notes: 'On demand' } })).not.toHaveProperty('error');
    expect((await api('plan/active')).body.workouts.find((w: any) => w.id === hotel).notes).toBe('On demand');
  });

  it('deletes through the canonical MCP tool at the observed plan version', async () => {
    expect(await tool('delete_workout', { workout_id: hotel, expected_version: tree.version })).toMatchObject({ ok: true });
    const latest = (await api('plan/active')).body;
    expect(latest.workouts.map((w: any) => w.id)).toEqual([gym.id]);
    expect(latest.version).toBe(tree.version + 1);
  });

  it('assigns an on-demand workout over the scheduled workout without changing the recurring plan', async () => {
    const assigned = await api(`calendar/${today}`, 'PUT', { workout_id: hotel, expected_attempt: 0 });
    expect(assigned.status).toBe(200);
    expect(assigned.body.session).toMatchObject({ workout_id: hotel });
    expect(assigned.body.session).not.toHaveProperty('day_template_id');
    const read = (await api('state')).body;
    expect(read.plan.version).toBe(tree.version); expect(read.plan.meta).toBe(tree.meta);
    expect(read.sessions.find((s: any) => s.id === assigned.body.session.id).workout_id).toBe(hotel);
    expect((await tool('get_today_workout')).session.workout_id).toBe(hotel);
    expect((await api(`calendar/${today}`, 'PUT', { workout_id: gym.id, day_template_id: hotel, expected_attempt: assigned.body.session.attempt })).status).toBe(400);
    const retry = await api(`calendar/${today}`, 'PUT', { workout_id: hotel, expected_attempt: assigned.body.session.attempt });
    expect(retry.body.session.attempt).toBe(assigned.body.session.attempt);
  });

  it('moves a date with canonical requests and idempotent acknowledgements', async () => {
    const next = new Date(`${today}T12:00:00Z`);
    next.setUTCDate(next.getUTCDate() + 1);
    const toDate = next.toISOString().slice(0, 10);
    const request = { id: crypto.randomUUID(), to_date: toDate, today,
      workout_id: gym.id, expected_plan_id: tree.id, expected_version: tree.version,
      expected_from_attempt: 0, expected_to_attempt: 0 };
    const move = await api(`calendar/${today}/move`, 'POST', request);
    expect(move.status).toBe(200);
    expect(move.body.from).toMatchObject({ date: today, status: 'skipped',
      workout_id: null, attempt: 1 });
    expect(move.body.to).toMatchObject({ date: toDate, status: 'planned',
      workout_id: gym.id, attempt: 1 });
    expect(await api(`calendar/${today}/move`, 'POST', request)).toEqual(move);
    const unchanged = (await api('plan/active')).body;
    expect(unchanged.version).toBe(tree.version);
    expect(unchanged.meta).toBe(tree.meta);
  });

  it('exports one canonical workout collection', async () => {
    const exported = (await api('me/export')).body;
    expect(exported.schema_version).toBe(3);
    expect(exported.training).not.toHaveProperty('day_templates');
    expect(exported.training.workouts).toEqual(expect.arrayContaining([expect.objectContaining({ id: hotel })]));
  });
});
