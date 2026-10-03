import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';

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
  expect(response.ok).toBe(true);
  return response.json<any>();
}
async function session(date: string) {
  return ok('sessions', 'POST', { date }) as Promise<{ id: string; attempt: number }>;
}
async function logSet(sessionID: string, index: number, weight: number, reps: number, unit?: string) {
  const id = crypto.randomUUID();
  const body = { id, exercise_id: 'ex_bench', set_index: index, weight, reps,
    ...(unit === undefined ? {} : { weight_unit: unit }) };
  return { id, body, response: await rest(`sessions/${sessionID}/sets`, 'POST', body) };
}
async function coachBrief() {
  const r = await SELF.fetch(`${BASE}/mcp`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer test-mcp-token' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'resources/read',
      params: { uri: 'coach://state/current' } }),
  });
  expect(r.status).toBe(200);
  const text = (await r.json<any>()).result.contents[0].text as string;
  return JSON.parse(text.match(/```json\n([\s\S]*?)\n```/)![1]!);
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
  const auth = await SELF.fetch(`${BASE}/auth/dev`, { method: 'POST',
    headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ secret: 'test-dev' }) });
  jwt = (await auth.json<any>()).jwt;
  await ok('plan', 'POST', { name: 'Units' });
});

describe('per-set weight_unit (migration 0055)', () => {
  it('defaults existing and unitless rows to lb and accepts only lb or kg', async () => {
    const columns = await env.DB.prepare("PRAGMA table_info('set_logs')")
      .all<{ name: string; notnull: number; dflt_value: string | null }>();
    expect(columns.results.find((c) => c.name === 'weight_unit'))
      .toMatchObject({ notnull: 1, dflt_value: "'lb'" });
    const s = await session('2026-09-01');
    const { id } = await logSet(s.id, 1, 100, 5);
    await expect(env.DB.prepare("UPDATE set_logs SET weight_unit = 'stone' WHERE id = ?1").bind(id).run())
      .rejects.toThrow(/CHECK/);
  });

  it('stores the unit iOS sends, keeps retries idempotent, and syncs it back', async () => {
    const s = await session('2026-09-02');
    const kg = await logSet(s.id, 1, 24, 15, 'kg');
    expect(kg.response.status).toBe(201);
    expect((await kg.response.json<any>()).set).toMatchObject({ weight: 24, weight_unit: 'kg' });
    const retry = await rest(`sessions/${s.id}/sets`, 'POST', kg.body);
    expect(retry.status).toBe(200);
    expect(await retry.json<any>()).toMatchObject({ deduped: true, set: { weight_unit: 'kg' } });
    const legacy = await logSet(s.id, 2, 24, 15);
    expect((await legacy.response.json<any>()).set.weight_unit).toBe('lb');
    const invalid = await logSet(s.id, 3, 24, 15, 'stone');
    expect(invalid.response.status).toBe(400);
    expect(await invalid.response.json()).toEqual({ error: 'invalid_fields', fields: ['weight_unit'] });

    const state = await ok('state');
    const units = Object.fromEntries(state.sets.map((set: any) => [set.id, set.weight_unit]));
    expect(units).toMatchObject({ [kg.id]: 'kg', [legacy.id]: 'lb' });
    expect(units[invalid.id]).toBeUndefined();
  });

  it('reports logged units in the coach brief and compares previous bests per unit', async () => {
    // Earlier completed session: 24 kg × 5 and 24 lb × 10.
    const earlier = await session('2026-09-03');
    await logSet(earlier.id, 1, 24, 5, 'kg');
    await logSet(earlier.id, 2, 24, 10, 'lb');
    await ok(`sessions/${earlier.id}?expected_attempt=${earlier.attempt}`, 'PATCH', { status: 'completed' });
    // Latest session: 24 kg × 6 beats the kg best (5), not the 24 lb × 10 set.
    const latest = await session('2026-09-04');
    const kg = await logSet(latest.id, 1, 24, 6, 'kg');
    const lb = await logSet(latest.id, 2, 24, 4, 'lb');
    await ok(`sessions/${latest.id}?expected_attempt=${latest.attempt}`, 'PATCH', { status: 'completed' });

    const summary = await ok(`sessions/${latest.id}/summary`);
    expect(summary.records).toEqual([expect.objectContaining({ weight: 24, unit: 'kg', value: 6, previous: 5 })]);

    const last = (await coachBrief()).last_session;
    expect(last.id).toBe(latest.id);
    const byId = Object.fromEntries(last.sets.map((set: any) => [set.id, set]));
    expect(byId[kg.id]).toMatchObject({ unit: 'kg', weight: 24 });
    expect(byId[kg.id].label).toContain('· 24 kg');
    expect(byId[lb.id]).toMatchObject({ unit: 'lb', weight: 24 });
    expect(byId[lb.id].label).toContain('· 24 lb');
    expect(last.external_load_volume).toEqual([
      { unit: 'kg', value: 144, contributing_sets: 1 },
      { unit: 'lb', value: 96, contributing_sets: 1 },
    ]);
  });
});
