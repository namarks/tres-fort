import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { createGroup, getGroupFeed } from '../src/db';
import { sameLoad } from '../src/workoutSummary';

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
async function logSet(sessionID: string, index: number, weight: number, reps: number, unit?: string,
  exercise = 'ex_bench') {
  const id = crypto.randomUUID();
  const body = { id, exercise_id: exercise, set_index: index, weight, reps,
    ...(unit === undefined ? {} : { weight_unit: unit }) };
  return { id, body, response: await rest(`sessions/${sessionID}/sets`, 'POST', body) };
}
async function mcp(method: string, params: unknown) {
  const r = await SELF.fetch(`${BASE}/mcp`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer test-mcp-token' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  });
  expect(r.status).toBe(200);
  return (await r.json<any>()).result;
}
async function coachBrief() {
  const text = (await mcp('resources/read', { uri: 'coach://state/current' })).contents[0].text as string;
  return JSON.parse(text.match(/```json\n([\s\S]*?)\n```/)![1]!);
}
async function completed(date: string, sets: [number, number, string, string?][]) {
  const s = await session(date);
  const logged = [];
  for (const [i, [weight, reps, unit, exercise]] of sets.entries()) {
    const set = await logSet(s.id, i + 1, weight, reps, unit, exercise);
    expect(set.response.status).toBe(201);
    logged.push(set);
  }
  await ok(`sessions/${s.id}?expected_attempt=${s.attempt}`, 'PATCH', { status: 'completed' });
  return { ...s, sets: logged };
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

  it('matches the same physical load across units, never a different one', () => {
    const load = (weight: number, unit: string) => ({ weight, unit });
    for (const [kg, lb] of [[24, 53], [16, 35], [32, 70], [12, 26], [100, 220], [-10, -22]]) {
      expect(sameLoad(load(kg!, 'kg'), load(lb!, 'lb'))).toBe(true);
      expect(sameLoad(load(lb!, 'lb'), load(kg!, 'kg'))).toBe(true);
    }
    expect(sameLoad(load(20, 'kg'), load(45, 'lb'))).toBe(false);
    expect(sameLoad(load(12, 'kg'), load(25, 'lb'))).toBe(false);
    expect(sameLoad(load(24, 'kg'), load(24, 'lb'))).toBe(false);
    expect(sameLoad(load(10, 'kg'), load(-22, 'lb'))).toBe(false);
    expect(sameLoad(load(0, 'kg'), load(0, 'lb'))).toBe(true);
    expect(sameLoad(load(53, 'lb'), load(53.5, 'lb'))).toBe(false);
  });

  it('counts a previous best logged in either unit and keeps workout volume per unit', async () => {
    await completed('2026-09-05', [
      [53, 5, 'lb'], [45, 12, 'lb'], [24, 8, 'kg', 'ex_back_squat'],
    ]);
    const latest = await completed('2026-09-06', [
      // 24 kg is the 53 lb implement: 6 reps beats 5, and the 53 lb × 4 set
      // this session is the same load, so it is one record, not two.
      [24, 6, 'kg'], [53, 4, 'lb'],
      // 20 kg is not the 45 lb bar, so it is a new baseline, not a record.
      [20, 9, 'kg'],
      // 53 lb × 6 is below the 24 kg × 8 best: no record in either unit.
      [53, 6, 'lb', 'ex_back_squat'],
    ]);

    const summary = await ok(`sessions/${latest.id}/summary`);
    expect(summary.records).toEqual([expect.objectContaining({ exercise_id: 'ex_bench', weight: 24, unit: 'kg',
      value: 6, previous: 5, previous_weight: 53, previous_unit: 'lb' })]);
    expect(summary.external_load_volume).toBeNull();
    expect(summary.external_load_volume_by_unit).toEqual([
      { unit: 'kg', value: 24 * 6 + 20 * 9, contributing_sets: 2 },
      { unit: 'lb', value: 53 * 4 + 53 * 6, contributing_sets: 2 },
    ]);

    // The reverse direction: a better earlier pound set is the best to beat.
    const kg = await completed('2026-09-07', [[24, 7, 'kg', 'ex_back_squat']]);
    expect((await ok(`sessions/${kg.id}/summary`)).records).toEqual([]);
    const lb = await completed('2026-09-08', [[53, 9, 'lb', 'ex_back_squat']]);
    expect((await ok(`sessions/${lb.id}/summary`)).records).toEqual([expect.objectContaining({
      exercise_id: 'ex_back_squat', weight: 53, unit: 'lb', value: 9, previous: 8,
      previous_weight: 24, previous_unit: 'kg' })]);
  });

  it('labels group feed and volume trend loads in the unit each set was logged in', async () => {
    const workout = await completed('2026-09-09', [[60, 5, 'kg'], [100, 5, 'lb']]);
    const owner = await env.DB.prepare('SELECT user_id FROM sessions WHERE id = ?1')
      .bind(workout.id).first<{ user_id: string }>();
    const group = await createGroup(env.DB, owner!.user_id, 'Units');
    const feed = await getGroupFeed(env.DB, group.id, null, null, 20, owner!.user_id);
    const item = feed.find((entry) => entry.id === workout.id) as any;
    expect(item.session.cohort_top_sets.map((set: any) => [set.weight, set.unit]))
      .toEqual([[60, 'kg'], [100, 'lb']]);
    // 60 kg × 5 (70 kg ≈ 154 lb estimate) outranks 100 lb × 5 (≈ 117 lb).
    expect(item.session.top_sets).toEqual([expect.objectContaining({ weight: 60, unit: 'kg' })]);

    const trend = JSON.parse((await mcp('tools/call', { name: 'get_volume_trend',
      arguments: { muscle_group: 'chest', range: 'all' } })).content[0].text);
    const week = trend.buckets.find((bucket: any) => bucket.external_load_volume.length === 2);
    expect(week).toMatchObject({ tonnage: null, unit: null, external_load_volume: [
      { unit: 'kg', value: 300, contributing_sets: 1 },
      { unit: 'lb', value: 500, contributing_sets: 1 },
    ] });
  });
});
