import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';

const BASE = 'https://lift-coach.test';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

async function devJwt(): Promise<string> {
  const r = await SELF.fetch(`${BASE}/auth/dev`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ secret: 'test-dev' }),
  });
  expect(r.status).toBe(200);
  return (await r.json<{ jwt: string }>()).jwt;
}

const auth = (jwt: string) => ({
  'content-type': 'application/json',
  Authorization: `Bearer ${jwt}`,
});

describe('health + auth', () => {
  it('health is public', async () => {
    const r = await SELF.fetch(`${BASE}/health`);
    expect(r.status).toBe(200);
    expect(await r.json()).toMatchObject({ ok: true });
  });

  it('rejects /api without bearer', async () => {
    const r = await SELF.fetch(`${BASE}/api/state`);
    expect(r.status).toBe(401);
  });

  it('rejects a garbage bearer', async () => {
    const r = await SELF.fetch(`${BASE}/api/state`, {
      headers: { Authorization: 'Bearer not-a-jwt' },
    });
    expect(r.status).toBe(401);
  });

  it('dev auth issues a working JWT', async () => {
    const jwt = await devJwt();
    const r = await SELF.fetch(`${BASE}/api/state`, { headers: auth(jwt) });
    expect(r.status).toBe(200);
  });

  it('dev auth rejects a bad secret', async () => {
    const r = await SELF.fetch(`${BASE}/auth/dev`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ secret: 'wrong' }),
    });
    expect(r.status).toBe(401);
  });
});

describe('plan tree + versioned sync', () => {
  it('builds a plan, bumps version on each mutation, syncs deltas', async () => {
    const jwt = await devJwt();
    const H = auth(jwt);

    const plan = await (
      await SELF.fetch(`${BASE}/api/plan`, {
        method: 'POST',
        headers: H,
        body: JSON.stringify({ name: 'Upper/Lower', meta: { unit: 'lb' } }),
      })
    ).json<{ id: string; version: number }>();
    expect(plan.version).toBe(1);

    // state with since=0 returns the full tree
    let state = await (
      await SELF.fetch(`${BASE}/api/state?since=0`, { headers: H })
    ).json<{ plan: any; plan_version: number }>();
    expect(state.plan).not.toBeNull();
    expect(state.plan_version).toBe(1);

    // state with since=current version returns plan:null (nothing changed)
    state = await (
      await SELF.fetch(`${BASE}/api/state?since=${state.plan_version}`, { headers: H })
    ).json<{ plan: any; plan_version: number }>();
    expect(state.plan).toBeNull();

    // add a day -> version bumps -> a stale client sees the tree again
    const day = await (
      await SELF.fetch(`${BASE}/api/days`, {
        method: 'POST',
        headers: H,
        body: JSON.stringify({ name: 'Upper A', day_label: 'A', order_index: 0 }),
      })
    ).json<{ id: string }>();

    state = await (
      await SELF.fetch(`${BASE}/api/state?since=1`, { headers: H })
    ).json<{ plan: any; plan_version: number }>();
    expect(state.plan).not.toBeNull();
    expect(state.plan_version).toBeGreaterThan(1);

    // add an exercise by natural name -> resolver maps "bench" -> Bench Press
    const teRes = await SELF.fetch(`${BASE}/api/days/${day.id}/exercises`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({
        exercise: 'bench',
        order_index: 0,
        target_sets: 3,
        target_reps: 5,
        target_reps_max: 8,
        rest_seconds: 180,
        progression: { type: 'double', increment: 5, unit: 'lb' },
      }),
    });
    expect(teRes.status).toBe(201);
    const te = await teRes.json<{ exercise_id: string }>();
    expect(te.exercise_id).toBe('ex_bench');

    const tree = await (
      await SELF.fetch(`${BASE}/api/plan/active`, { headers: H })
    ).json<{ days: { exercises: unknown[] }[] }>();
    expect(tree.days[0]?.exercises ?? []).toHaveLength(1);

    // unknown exercise -> 400
    const bad = await SELF.fetch(`${BASE}/api/days/${day.id}/exercises`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ exercise: 'zercher hack thruster', target_sets: 3, target_reps: 5 }),
    });
    expect(bad.status).toBe(400);
  });
});

describe('sessions, idempotent set logging, history, volume', () => {
  it('logs sets idempotently and computes history + volume', async () => {
    const jwt = await devJwt();
    const H = auth(jwt);

    // isolated per-test storage: this test owns its plan
    await SELF.fetch(`${BASE}/api/plan`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ name: 'Strength' }),
    });

    const session = await (
      await SELF.fetch(`${BASE}/api/sessions`, {
        method: 'POST',
        headers: H,
        body: JSON.stringify({ date: '2026-05-18' }),
      })
    ).json<{ id: string }>();

    const setId = crypto.randomUUID();
    const setBody = {
      id: setId,
      exercise_id: 'ex_bench',
      set_index: 1,
      weight: 225,
      reps: 8,
      rpe: 8,
    };

    const first = await SELF.fetch(`${BASE}/api/sessions/${session.id}/sets`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify(setBody),
    });
    expect(first.status).toBe(201);
    expect(await first.json<{ deduped: boolean }>()).toMatchObject({ deduped: false });

    // same id again (offline retry) -> deduped, no duplicate row
    const retry = await SELF.fetch(`${BASE}/api/sessions/${session.id}/sets`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify(setBody),
    });
    expect(retry.status).toBe(200);
    expect(await retry.json<{ deduped: boolean }>()).toMatchObject({ deduped: true });

    // logging into someone else's / unknown session -> 404
    const orphan = await SELF.fetch(`${BASE}/api/sessions/nope/sets`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ ...setBody, id: crypto.randomUUID() }),
    });
    expect(orphan.status).toBe(404);

    // state sets delta includes exactly one set
    const state = await (
      await SELF.fetch(`${BASE}/api/state?since=0&sets_since=0`, { headers: H })
    ).json<{ sets: unknown[] }>();
    expect(state.sets.filter((s: any) => s.id === setId)).toHaveLength(1);

    // history for bench: one session, est-1rm computed (Epley 225x8 ≈ 285)
    const hist = await (
      await SELF.fetch(`${BASE}/api/history?exercise_id=ex_bench`, { headers: H })
    ).json<{ by_session: { est_1rm: number }[] }>();
    expect(hist.by_session).toHaveLength(1);
    expect(hist.by_session[0]!.est_1rm).toBeGreaterThan(280);

    // volume for chest: one weekly bucket with tonnage 225*8
    const vol = await (
      await SELF.fetch(`${BASE}/api/volume?muscle=chest`, { headers: H })
    ).json<{ buckets: { hard_sets: number; tonnage: number }[] }>();
    expect(vol.buckets.length).toBeGreaterThanOrEqual(1);
    expect(vol.buckets[0]!.tonnage).toBe(225 * 8);

    // soft-delete the set
    const del = await SELF.fetch(`${BASE}/api/sets/${setId}`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ deleted: true }),
    });
    expect(del.status).toBe(200);
    const histAfter = await (
      await SELF.fetch(`${BASE}/api/history?exercise_id=ex_bench`, { headers: H })
    ).json<{ by_session: unknown[] }>();
    expect(histAfter.by_session).toHaveLength(0);
  });
});

// FIX2 class-completion: the REST PATCH /api/sessions/:id entry point must
// reject a `skipped` patch on a started/finished session, exactly like the
// MCP skipPlannedSession guard — otherwise iOS could bury logged history.
describe('PATCH /api/sessions/:id — skipped patch cannot bury started/finished history', () => {
  async function freshSession(H: Record<string, string>): Promise<string> {
    await SELF.fetch(`${BASE}/api/plan`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ name: 'Skip Guard Plan' }),
    });
    const s = await (
      await SELF.fetch(`${BASE}/api/sessions`, {
        method: 'POST',
        headers: H,
        body: JSON.stringify({ date: '2026-07-01' }),
      })
    ).json<{ id: string }>();
    return s.id;
  }

  it('REJECTS skipped on a completed session (409); row + logged sets intact', async () => {
    const H = auth(await devJwt());
    const id = await freshSession(H);

    // Log a set, then complete the session — this is the history to protect.
    const setId = crypto.randomUUID();
    await SELF.fetch(`${BASE}/api/sessions/${id}/sets`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ id: setId, exercise_id: 'ex_bench', set_index: 1, weight: 225, reps: 5, rpe: 8 }),
    });
    const comp = await SELF.fetch(`${BASE}/api/sessions/${id}`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ status: 'completed' }),
    });
    expect(comp.status).toBe(200);

    const rej = await SELF.fetch(`${BASE}/api/sessions/${id}`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ status: 'skipped' }),
    });
    expect(rej.status).toBe(409);
    expect(await rej.json()).toEqual({ error: 'session_already_started', status: 'completed' });

    // Session row still completed; the logged set is untouched.
    const row = await env.DB.prepare('SELECT status FROM sessions WHERE id=?1')
      .bind(id)
      .first<{ status: string }>();
    expect(row!.status).toBe('completed');
    const set = await env.DB.prepare('SELECT deleted_at FROM set_logs WHERE id=?1')
      .bind(setId)
      .first<{ deleted_at: number | null }>();
    expect(set!.deleted_at).toBeNull();
  });

  it('REJECTS skipped on an in_progress session (409); row untouched', async () => {
    const H = auth(await devJwt());
    const id = await freshSession(H);
    const start = await SELF.fetch(`${BASE}/api/sessions/${id}`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ status: 'in_progress' }),
    });
    expect(start.status).toBe(200);

    const rej = await SELF.fetch(`${BASE}/api/sessions/${id}`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ status: 'skipped' }),
    });
    expect(rej.status).toBe(409);
    expect(await rej.json()).toEqual({ error: 'session_already_started', status: 'in_progress' });
    const row = await env.DB.prepare('SELECT status FROM sessions WHERE id=?1')
      .bind(id)
      .first<{ status: string }>();
    expect(row!.status).toBe('in_progress');
  });

  it('ALLOWS skipped on a planned session (unchanged behavior)', async () => {
    const H = auth(await devJwt());
    const id = await freshSession(H); // freshly created => status 'planned'
    const r = await SELF.fetch(`${BASE}/api/sessions/${id}`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ status: 'skipped' }),
    });
    expect(r.status).toBe(200);
    expect(await r.json<{ status: string }>()).toMatchObject({ status: 'skipped' });
  });

  it('non-skipped status patch and field-only patch on a completed session are unchanged', async () => {
    const H = auth(await devJwt());
    const id = await freshSession(H);

    // planned -> completed (non-skipped transition): allowed as before.
    const toCompleted = await SELF.fetch(`${BASE}/api/sessions/${id}`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ status: 'completed' }),
    });
    expect(toCompleted.status).toBe(200);
    expect(await toCompleted.json<{ status: string }>()).toMatchObject({ status: 'completed' });

    // field-only patch (no status) on a completed session: allowed, status
    // preserved — the guard only fires for an explicit skipped patch.
    const fieldOnly = await SELF.fetch(`${BASE}/api/sessions/${id}`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ perceived_fatigue: 7, notes: 'cooked' }),
    });
    expect(fieldOnly.status).toBe(200);
    expect(await fieldOnly.json<{ status: string; perceived_fatigue: number; notes: string }>()).toMatchObject({
      status: 'completed',
      perceived_fatigue: 7,
      notes: 'cooked',
    });
  });
});

describe('/api/state carries the weekly schedule, gated on version', () => {
  it('schedule appears when plans.version advanced, and not otherwise', async () => {
    const jwt = await devJwt();
    const H = auth(jwt);

    // Build a plan with a named day, then set the weekly schedule via MCP
    // (schedule rides the plan-tree sync; there is no REST schedule write).
    await SELF.fetch(`${BASE}/api/plan`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ name: 'Sched Sync' }),
    });
    const day = await (
      await SELF.fetch(`${BASE}/api/days`, {
        method: 'POST',
        headers: H,
        body: JSON.stringify({ name: 'Push Day', day_label: 'A', order_index: 0 }),
      })
    ).json<{ id: string }>();

    const setSched = await SELF.fetch(`${BASE}/mcp`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', Authorization: 'Bearer test-mcp-token' },
      body: JSON.stringify({
        jsonrpc: '2.0',
        id: 1,
        method: 'tools/call',
        params: { name: 'set_schedule', arguments: { week: { mon: 'Push Day' } } },
      }),
    });
    const setBody = await setSched.json<any>();
    const sched = JSON.parse(setBody.result.content[0].text);
    expect(sched.ok).toBe(true);
    const curVer = sched.version as number;

    // Stale client (since below current version) → full tree WITH schedule.
    const fresh = await (
      await SELF.fetch(`${BASE}/api/state?since=0`, { headers: H })
    ).json<{ plan: any; plan_version: number }>();
    expect(fresh.plan).not.toBeNull();
    expect(fresh.plan_version).toBe(curVer);
    expect(fresh.plan.schedule).toBeTruthy();
    // schedule.version is a change counter: baseline 1, +1 for the
    // set_schedule write performed above.
    expect(fresh.plan.schedule.version).toBe(2);
    expect(fresh.plan.schedule.week.mon).toBe(day.id);
    expect(fresh.plan.schedule.week.tue).toBeNull();

    // Up-to-date client (since = current version) → plan null, no schedule.
    const same = await (
      await SELF.fetch(`${BASE}/api/state?since=${curVer}`, { headers: H })
    ).json<{ plan: any }>();
    expect(same.plan).toBeNull();
  });
});

describe('/api/state external_events delta (own consistency class)', () => {
  it('gates events on events_since and never bumps plans.version', async () => {
    const jwt = await devJwt();
    const H = auth(jwt);

    // Own plan so plan_version is well-defined for this test.
    await SELF.fetch(`${BASE}/api/plan`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ name: 'Ride State' }),
    });
    const planVer = (
      await (await SELF.fetch(`${BASE}/api/state?since=0`, { headers: H })).json<{
        plan_version: number;
      }>()
    ).plan_version;

    // Resolve the owner user id (dev auth → owner).
    const userId = (
      await env.DB.prepare("SELECT id FROM users ORDER BY created_at LIMIT 1").first<{
        id: string;
      }>()
    )!.id;

    // Seed the reconciled cache directly (server-owned class; no API write).
    const t1 = Date.now();
    await env.DB.prepare(
      `INSERT INTO external_events
         (id,user_id,source,external_id,date,kind,title,description,
          planned_duration_sec,training_load,intensity,raw,synced_at,deleted_at)
       VALUES ('intervals:state-1',?1,'intervals','state-1','2026-06-01','ride','Z2',NULL,
               7200,120,0.7,'{}',?2,NULL)`,
    )
      .bind(userId, t1)
      .run();

    // events_since=0 → the new event is in the delta.
    const s1 = await (
      await SELF.fetch(`${BASE}/api/state?since=0&events_since=0`, { headers: H })
    ).json<{ external_events: { id: string }[]; plan_version: number }>();
    expect(s1.external_events.some((e) => e.id === 'intervals:state-1')).toBe(true);

    // events_since at/after the row's synced_at → excluded from the delta.
    const s2 = await (
      await SELF.fetch(`${BASE}/api/state?events_since=${t1}`, { headers: H })
    ).json<{ external_events: { id: string }[]; plan_version: number }>();
    expect(s2.external_events.some((e) => e.id === 'intervals:state-1')).toBe(false);

    // A later sync (new synced_at) re-surfaces it and a soft-delete is in
    // the delta too (client filters on deleted_at, like set_logs).
    const t2 = t1 + 1000;
    await env.DB.prepare(
      "UPDATE external_events SET synced_at=?1, deleted_at=?1 WHERE id='intervals:state-1'",
    )
      .bind(t2)
      .run();
    const s3 = await (
      await SELF.fetch(`${BASE}/api/state?events_since=${t1}`, { headers: H })
    ).json<{ external_events: { id: string; deleted_at: number | null }[] }>();
    const row = s3.external_events.find((e) => e.id === 'intervals:state-1');
    expect(row).toBeTruthy();
    expect(row!.deleted_at).not.toBeNull();

    // plans.version is untouched by any of the cache activity above.
    const after = await (
      await SELF.fetch(`${BASE}/api/state?since=0`, { headers: H })
    ).json<{ plan_version: number }>();
    expect(after.plan_version).toBe(planVer);
  });

  it('full-reload (events_since absent OR 0) → full NON-deleted set, no tombstones', async () => {
    const jwt = await devJwt();
    const H = auth(jwt);

    await SELF.fetch(`${BASE}/api/plan`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ name: 'Full Reload' }),
    });
    const planVer = (
      await (await SELF.fetch(`${BASE}/api/state?since=0`, { headers: H })).json<{
        plan_version: number;
      }>()
    ).plan_version;
    const userId = (
      await env.DB.prepare("SELECT id FROM users ORDER BY created_at LIMIT 1").first<{
        id: string;
      }>()
    )!.id;

    // One live ride + one soft-deleted (tombstone) ride.
    const t = Date.now();
    await env.DB.prepare(
      `INSERT INTO external_events
         (id,user_id,source,external_id,date,kind,title,description,
          planned_duration_sec,training_load,intensity,raw,synced_at,deleted_at)
       VALUES ('intervals:fr-live',?1,'intervals','fr-live','2026-07-01','ride','Live',NULL,
               3600,60,0.6,'{}',?2,NULL)`,
    )
      .bind(userId, t)
      .run();
    await env.DB.prepare(
      `INSERT INTO external_events
         (id,user_id,source,external_id,date,kind,title,description,
          planned_duration_sec,training_load,intensity,raw,synced_at,deleted_at)
       VALUES ('intervals:fr-dead',?1,'intervals','fr-dead','2026-07-02','ride','Dead',NULL,
               3600,60,0.6,'{}',?2,?2)`,
    )
      .bind(userId, t)
      .run();

    // Absent events_since → full non-deleted set; tombstone NOT present.
    const absent = await (
      await SELF.fetch(`${BASE}/api/state?since=0`, { headers: H })
    ).json<{ external_events: { id: string }[]; plan_version: number }>();
    const absentIds = absent.external_events.map((e) => e.id);
    expect(absentIds).toContain('intervals:fr-live');
    expect(absentIds).not.toContain('intervals:fr-dead');

    // events_since=0 is the same full-reload contract (also no tombstone).
    const zero = await (
      await SELF.fetch(`${BASE}/api/state?since=0&events_since=0`, { headers: H })
    ).json<{ external_events: { id: string }[] }>();
    const zeroIds = zero.external_events.map((e) => e.id);
    expect(zeroIds).toContain('intervals:fr-live');
    expect(zeroIds).not.toContain('intervals:fr-dead');

    // Incremental path (events_since > 0) DOES carry the tombstone so a
    // syncing client can drop it.
    const incr = await (
      await SELF.fetch(`${BASE}/api/state?events_since=${t - 1}`, { headers: H })
    ).json<{ external_events: { id: string; deleted_at: number | null }[] }>();
    const dead = incr.external_events.find((e) => e.id === 'intervals:fr-dead');
    expect(dead).toBeTruthy();
    expect(dead!.deleted_at).not.toBeNull();

    // plans.version unaffected throughout.
    const after = await (
      await SELF.fetch(`${BASE}/api/state?since=0`, { headers: H })
    ).json<{ plan_version: number }>();
    expect(after.plan_version).toBe(planVer);
  });
});

describe('exercise catalog', () => {
  it('lists the seeded catalog incl timed exercises', async () => {
    const jwt = await devJwt();
    const r = await SELF.fetch(`${BASE}/api/exercises`, { headers: auth(jwt) });
    expect(r.status).toBe(200);
    const list = await r.json<{ id: string; modality: string }[]>();
    expect(list.find((e) => e.id === 'ex_bench')).toBeTruthy();
    expect(list.find((e) => e.id === 'ex_plank')?.modality).toBe('timed');
  });
});

// /mcp behavior is covered comprehensively in test/mcp.test.ts.
