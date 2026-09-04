import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';

const BASE = 'https://tres-fort.test';
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
    expect(body.result.serverInfo.name).toBe('tres-fort');
    // Host-injected guidance: must mention the no-auto-log policy so the
    // model picks up the narration guard at session start.
    expect(typeof body.result.instructions).toBe('string');
    expect(body.result.instructions).toMatch(/log_set/);
    expect(body.result.instructions).toMatch(/correct_set/);
    expect(body.result.instructions).toMatch(/iOS/);
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
        'list_exercises',
        'log_set',
        'correct_set',
        'delete_set',
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
        'refresh_rides',
        'get_upcoming_rides',
        'get_recent_activities',
        'update_day',
        'delete_exercise',
        'log_activity',
        'get_group_feed',
        'set_race',
        'set_periodization',
        'add_trip',
        'update_trip',
        'remove_trip',
        'set_stress_model',
      ]),
    );
    expect(names).toHaveLength(34);
    for (const t of body.result.tools) expect(t.inputSchema.type).toBe('object');
    const correction = body.result.tools.find((t: any) => t.name === 'correct_set');
    expect(correction.inputSchema.required).toEqual(['set_id']);
    expect(correction.inputSchema.properties.duration_s.type).toEqual(['integer', 'null']);

    const logSet = body.result.tools.find((t: any) => t.name === 'log_set');
    expect(logSet.description).toMatch(/negative for band or machine assistance/i);
    expect(logSet.description).toMatch(/do not substitute the athlete's body mass/i);

    const addExercise = body.result.tools.find((t: any) => t.name === 'add_exercise');
    expect(addExercise.description).toMatch(/AMRAP/);
    expect(addExercise.inputSchema.properties.target_weight.description)
      .toMatch(/negative = assistance/i);

    const history = body.result.tools.find((t: any) => t.name === 'get_history');
    expect(history.description).toMatch(/best and total reps/i);
    expect(history.description).toMatch(/best hold/i);
    const volume = body.result.tools.find((t: any) => t.name === 'get_volume_trend');
    expect(volume.description).toMatch(/positive-load tonnage/i);
  });
});

describe('mcp tools read live D1', () => {
  it('empty state is graceful', async () => {
    const { body } = await rpc('tools/call', { name: 'get_current_plan', arguments: {} });
    expect(toolJson(body)).toMatchObject({ plan: null });
  });

  // Regression: getSessionByDate (→ get_today_workout / get_session_log)
  // must NOT surface a discarded session to Claude — it reads as "no
  // session on this date", same vanish semantics as the calendar.
  it('a discarded session is invisible to get_today_workout', async () => {
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
      body: JSON.stringify({ name: 'Discard Vis' }),
    });
    // No date → REST and MCP resolve the same stored user-timezone date.
    const session = await (
      await SELF.fetch(`${BASE}/api/sessions`, { method: 'POST', headers: H, body: '{}' })
    ).json<{ id: string }>();
    await SELF.fetch(`${BASE}/api/sessions/${session.id}/sets`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ id: crypto.randomUUID(), exercise_id: 'ex_bench', set_index: 1, weight: 95, reps: 5 }),
    });

    const before = toolJson((await rpc('tools/call', { name: 'get_today_workout', arguments: {} })).body);
    expect(before.session?.id).toBe(session.id);
    // get_today_workout now carries the weekly schedule too — agents can
    // answer "what should I do today?" in a single call.
    expect(before.schedule).toBeDefined();
    expect(Object.keys(before.schedule).sort()).toEqual(
      ['fri', 'mon', 'sat', 'sun', 'thu', 'tue', 'wed'],
    );

    await SELF.fetch(`${BASE}/api/sessions/${session.id}/discard`, { method: 'POST', headers: H });

    const after = toolJson((await rpc('tools/call', { name: 'get_today_workout', arguments: {} })).body);
    expect(after.session).toBeNull();
    // …and it must not resurface as the coach's "last_session" either.
    expect(after.last_session?.id).not.toBe(session.id);
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

    const knownEmpty = toolJson(
      (
        await rpc('tools/call', {
          name: 'get_volume_trend',
          arguments: { muscle_group: 'shoulders' },
        })
      ).body,
    );
    expect(knownEmpty).toMatchObject({ muscle_group: 'shoulders', buckets: [] });
    const unknownMuscle = toolJson(
      (
        await rpc('tools/call', {
          name: 'get_volume_trend',
          arguments: { muscle_group: 'chset-typo' },
        })
      ).body,
    );
    expect(unknownMuscle).toEqual({ error: 'unknown_muscle', query: 'chset-typo' });

    // list_exercises: catalog discoverability for agents (closes the
    // bug-report P1 "exercise vocabulary is closed and undiscoverable").
    const allEx = toolJson(
      (await rpc('tools/call', { name: 'list_exercises', arguments: {} })).body,
    );
    expect(Array.isArray(allEx)).toBe(true);
    expect(allEx.length).toBeGreaterThan(20); // catalog is 131+ post-migration 0007
    expect(allEx.find((e: { id: string }) => e.id === 'ex_bench')).toBeTruthy();

    const benchish = toolJson(
      (await rpc('tools/call', { name: 'list_exercises', arguments: { query: 'bench' } })).body,
    );
    expect(benchish.every((e: { name: string }) => /bench/i.test(e.name))).toBe(true);
    expect(benchish.length).toBeLessThan(allEx.length);

    const quads = toolJson(
      (await rpc('tools/call', { name: 'list_exercises', arguments: { muscle: 'quads' } })).body,
    );
    expect(quads.every((e: { primary_muscle: string }) => e.primary_muscle === 'quads')).toBe(true);

    const unknown = toolJson(
      (await rpc('tools/call', { name: 'get_history', arguments: { exercise: 'xyzzy' } })).body,
    );
    expect(unknown.error).toBe('unknown_exercise');
  });

  it('get_upcoming_rides + brief expose rides and lift/ride conflicts', async () => {
    await seed(); // plan "Upper/Lower", day "Upper A", a logged set today

    const userId = (
      await env.DB.prepare('SELECT id FROM users ORDER BY created_at LIMIT 1').first<{
        id: string;
      }>()
    )!.id;

    const today = new Date().toISOString().slice(0, 10);
    // Ensure a real lift session exists on the REAL "today" (the seed uses
    // a fixed 2026-05-18 date which the wall clock may not match), so the
    // conflict detector sees a lift on `today`.
    const plan = (
      await env.DB.prepare(
        "SELECT id FROM plans WHERE user_id=?1 AND status='active'",
      )
        .bind(userId)
        .first<{ id: string }>()
    )!.id;
    await env.DB.prepare(
      `INSERT OR IGNORE INTO sessions
         (id,user_id,plan_id,day_template_id,date,status,started_at,completed_at,
          perceived_fatigue,notes,created_at,updated_at)
       VALUES (?1,?2,?3,NULL,?4,'completed',NULL,NULL,NULL,NULL,?5,?5)`,
    )
      .bind(`sess-today-${today}`, userId, plan, today, Date.now())
      .run();

    // Same-day ride → expect a 'clash'. Anchored to today (within window).
    await env.DB.prepare(
      `INSERT INTO external_events
         (id,user_id,source,external_id,date,kind,title,description,
          planned_duration_sec,training_load,intensity,raw,synced_at,deleted_at)
       VALUES ('intervals:clash-1',?1,'intervals','clash-1',?2,'ride','Big ride',NULL,
               10800,210,0.85,'{}',?3,NULL)`,
    )
      .bind(userId, today, Date.now())
      .run();

    const ur = toolJson(
      (await rpc('tools/call', { name: 'get_upcoming_rides', arguments: { range: 30 } })).body,
    );
    expect(ur.rides.some((r: any) => r.id === 'intervals:clash-1')).toBe(true);
    const clash = ur.conflicts.find((c: any) => c.date === today);
    expect(clash).toBeTruthy();
    expect(clash.severity).toBe('clash');
    expect(clash.conflicts).toContain('intervals:clash-1');

    // The auto-loaded brief carries the same conflict, zero extra calls.
    const read = await rpc('resources/read', { uri: 'coach://state/current' });
    const text = read.body.result.contents[0].text as string;
    expect(text).toContain('ride_conflicts');
    expect(text).toContain('intervals:clash-1');

    // get_current_plan folds the conflicts into plan context too.
    const cp = toolJson((await rpc('tools/call', { name: 'get_current_plan', arguments: {} })).body);
    expect(Array.isArray(cp.ride_conflicts)).toBe(true);
    expect(cp.ride_conflicts.some((c: any) => c.date === today && c.severity === 'clash')).toBe(
      true,
    );
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

  // M4: get_group_feed. The MCP user resolves to the bootstrap owner via
  // ensureOwnerUser; seed() above already minted an owner via /auth/dev.
  // The owner here creates a group with one logged session — the tool
  // should surface it back and stamp is_me=true on the owner's items.
  it('get_group_feed: returns the owner\'s feed for the first group when group_id omitted', async () => {
    await seed(); // creates owner + a session on 2026-05-18 with a bench set
    // Create a group under the owner via REST (using the same /auth/dev jwt).
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
    const g = await (
      await SELF.fetch(`${BASE}/api/groups`, {
        method: 'POST',
        headers: H,
        body: JSON.stringify({ name: 'mcp-feed' }),
      })
    ).json<{ id: string }>();

    const out = toolJson(
      (await rpc('tools/call', { name: 'get_group_feed', arguments: { range: '14d' } })).body,
    );
    expect(out.group_id).toBe(g.id);
    expect(out.group_name).toBe('mcp-feed');
    expect(out.range).toBe('14d');
    expect(Array.isArray(out.items)).toBe(true);
    expect(Array.isArray(out.stats)).toBe(true);
    // The seeded session shows up as a session-type feed item with is_me=true.
    const sessionItem = out.items.find((it: any) => it.type === 'session');
    expect(sessionItem).toBeTruthy();
    expect(sessionItem.is_me).toBe(true);
    expect(sessionItem.session.top_sets[0].exercise).toBe('Bench Press');
    // stats include the owner with workout_count >= 0 (the seeded session
    // is dated 2026-05-18 which may or may not be in the rolling 14d
    // window depending on wall clock; the shape is what we lock here).
    const me = out.stats.find((s: any) => s.is_me === true);
    expect(me).toBeTruthy();
    expect(typeof me.workout_count).toBe('number');
    expect(typeof me.streak_days).toBe('number');
  });

  it('get_group_feed: empty-state when caller is in no groups', async () => {
    // No /auth/dev call, no group creation → bootstrap owner exists from
    // ensureOwnerUser but has no group_members rows.
    const out = toolJson(
      (await rpc('tools/call', { name: 'get_group_feed', arguments: {} })).body,
    );
    expect(out.items).toEqual([]);
    expect(out.stats).toEqual([]);
    expect(out.note).toMatch(/not in any groups/);
  });
});

describe('mcp bodyweight intensity adjustment', () => {
  it('adds assistance magnitude while reducing positive external load', async () => {
    const built = toolJson((await rpc('tools/call', {
      name: 'update_plan',
      arguments: {
        name: 'Assistance scaling',
        days: [{
          name: 'A',
          day_label: 'A',
          exercises: [
            { exercise: 'Pull-Up', target_sets: 3, target_reps: 8, target_weight: -30 },
            { exercise: 'Bench Press', target_sets: 3, target_reps: 5, target_weight: 100 },
          ],
        }],
      },
    })).body);
    expect(built.conflict).toBe(false);

    const adjusted = toolJson((await rpc('tools/call', {
      name: 'adjust_today',
      arguments: {
        intent: 'reduce_intensity',
        magnitude: 'moderate',
        day_label: 'A',
        reason: 'fatigued',
      },
    })).body);
    const exercises = adjusted.plan.days[0].exercises;
    expect(exercises.find((exercise: any) => exercise.exercise_id === 'ex_pullup')
      .target_weight).toBe(-35);
    expect(exercises.find((exercise: any) => exercise.exercise_id === 'ex_bench')
      .target_weight).toBe(90);
  });
});
