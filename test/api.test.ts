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

// /mcp behavior is covered comprehensively in test/mcp.test.ts.
