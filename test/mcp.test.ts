import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';

const BASE = 'https://lift-coach.test';
const MCP_TOKEN = 'test-mcp-token';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

let rpcId = 0;
async function rpc(method: string, params?: unknown, token = MCP_TOKEN) {
  const r = await SELF.fetch(`${BASE}/mcp`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify({ jsonrpc: '2.0', id: ++rpcId, method, params }),
  });
  return { status: r.status, body: await r.json<any>().catch(() => null), res: r };
}

/** Seed a plan + a logged bench set via REST (dev auth on in tests). */
async function seed() {
  const jwt = (
    await (
      await SELF.fetch(`${BASE}/auth/dev`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ secret: 'test-dev' }),
      })
    ).json<{ jwt: string }>()
  ).jwt;
  const H = { 'content-type': 'application/json', Authorization: `Bearer ${jwt}` };
  await SELF.fetch(`${BASE}/api/plan`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({ name: 'Upper/Lower' }),
  });
  const day = await (
    await SELF.fetch(`${BASE}/api/days`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ name: 'Upper A', day_label: 'A' }),
    })
  ).json<{ id: string }>();
  await SELF.fetch(`${BASE}/api/days/${day.id}/exercises`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({ exercise: 'bench', target_sets: 3, target_reps: 5 }),
  });
  const session = await (
    await SELF.fetch(`${BASE}/api/sessions`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ date: '2026-05-18' }),
    })
  ).json<{ id: string }>();
  await SELF.fetch(`${BASE}/api/sessions/${session.id}/sets`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({
      id: crypto.randomUUID(),
      exercise_id: 'ex_bench',
      set_index: 1,
      weight: 225,
      reps: 8,
      rpe: 8,
    }),
  });
}

const toolJson = (body: any) => JSON.parse(body.result.content[0].text);

describe('mcp auth + protocol', () => {
  it('401 + WWW-Authenticate without the static token', async () => {
    const r = await SELF.fetch(`${BASE}/mcp`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'ping' }),
    });
    expect(r.status).toBe(401);
    expect(r.headers.get('WWW-Authenticate')).toContain('oauth-protected-resource');
  });

  it('GET is 405 (no server-initiated stream)', async () => {
    const r = await SELF.fetch(`${BASE}/mcp`, { headers: { Authorization: `Bearer ${MCP_TOKEN}` } });
    expect(r.status).toBe(405);
  });

  it('initialize echoes a supported protocol + advertises capabilities', async () => {
    const { body } = await rpc('initialize', { protocolVersion: '2025-06-18' });
    expect(body.result.protocolVersion).toBe('2025-06-18');
    expect(body.result.capabilities).toMatchObject({ tools: {}, resources: {}, prompts: {} });
    expect(body.result.serverInfo.name).toBe('lift-coach');
  });

  it('notifications get a bare 202', async () => {
    const r = await SELF.fetch(`${BASE}/mcp`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', Authorization: `Bearer ${MCP_TOKEN}` },
      body: JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }),
    });
    expect(r.status).toBe(202);
  });

  it('unknown method -> JSON-RPC -32601', async () => {
    const { body } = await rpc('does/not/exist');
    expect(body.error.code).toBe(-32601);
  });
});

describe('mcp tools list', () => {
  it('lists read + write tools with input schemas', async () => {
    const { body } = await rpc('tools/list');
    const names = body.result.tools.map((t: any) => t.name);
    expect(names).toEqual(
      expect.arrayContaining([
        'get_current_plan',
        'get_current_session',
        'get_history',
        'get_session_log',
        'get_today_workout',
        'get_volume_trend',
        'log_set',
        'log_workout_complete',
        'add_note',
        'update_plan',
        'update_exercise',
        'swap_exercise',
        'add_exercise',
        'add_day',
        'adjust_today',
        'set_schedule',
        'set_planned_session',
        'skip_planned_session',
      ]),
    );
    expect(names).toHaveLength(18);
    for (const t of body.result.tools) expect(t.inputSchema.type).toBe('object');
  });
});

describe('mcp tools read live D1', () => {
  it('empty state is graceful', async () => {
    const { body } = await rpc('tools/call', { name: 'get_current_plan', arguments: {} });
    expect(toolJson(body)).toMatchObject({ plan: null });
  });

  it('reads a seeded plan, history, and volume', async () => {
    await seed();

    const plan = toolJson((await rpc('tools/call', { name: 'get_current_plan', arguments: {} })).body);
    expect(plan.name).toBe('Upper/Lower');
    expect(plan.days[0].exercises).toHaveLength(1);

    const hist = toolJson(
      (await rpc('tools/call', { name: 'get_history', arguments: { exercise: 'bench' } })).body,
    );
    expect(hist.by_session).toHaveLength(1);
    expect(hist.by_session[0].est_1rm).toBeGreaterThan(280);

    const vol = toolJson(
      (await rpc('tools/call', { name: 'get_volume_trend', arguments: { muscle_group: 'chest' } }))
        .body,
    );
    expect(vol.buckets[0].tonnage).toBe(225 * 8);

    const unknown = toolJson(
      (await rpc('tools/call', { name: 'get_history', arguments: { exercise: 'xyzzy' } })).body,
    );
    expect(unknown.error).toBe('unknown_exercise');
  });

  it('exposes the state resource and the coach_brief prompt', async () => {
    await seed();
    const list = await rpc('resources/list');
    expect(list.body.result.resources[0].uri).toBe('coach://state/current');

    const read = await rpc('resources/read', { uri: 'coach://state/current' });
    const text = read.body.result.contents[0].text as string;
    expect(text).toContain('Upper/Lower');
    expect(read.body.result.contents[0].mimeType).toBe('text/markdown');

    const prompts = await rpc('prompts/list');
    expect(prompts.body.result.prompts[0].name).toBe('coach_brief');
    const got = await rpc('prompts/get', { name: 'coach_brief' });
    expect(got.body.result.messages[0].content.text).toContain('strength coach');
  });
});
