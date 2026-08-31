import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';

const BASE = 'https://tres-fort.test';

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

async function activateWorkoutWriteFence(): Promise<void> {
  await env.DB
    .prepare(
      'UPDATE workout_write_fence SET enabled=1, activated_at=?1 WHERE id=1',
    )
    .bind(Date.now())
    .run();
}

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
  it('rejects a removed day template with a stable non-retryable response', async () => {
    const H = auth(await devJwt());

    await SELF.fetch(`${BASE}/api/plan`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ name: 'Stale Day Contract' }),
    });
    const day = await (
      await SELF.fetch(`${BASE}/api/days`, {
        method: 'POST',
        headers: H,
        body: JSON.stringify({ name: 'Removed Day', order_index: 0 }),
      })
    ).json<{ id: string }>();

    // update_plan rebuilds day UUIDs. Deleting this unused row reproduces the
    // stale optional FK an offline iOS set intent can retain across that
    // rebuild, without involving the client-side fallback under test.
    const removed = await env.DB.prepare('DELETE FROM day_templates WHERE id = ?1')
      .bind(day.id)
      .run();
    expect(removed.meta.changes).toBe(1);

    const response = await SELF.fetch(`${BASE}/api/sessions`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({
        date: '2026-05-17',
        day_template_id: day.id,
      }),
    });

    // 422 is intentionally permanent to the iOS outbox (unlike 408/429), so
    // it clears only the stale association and retries the set as ad-hoc.
    expect(response.status).toBe(422);
    expect(await response.json()).toEqual({ error: 'unknown_day' });
    const persisted = await env.DB.prepare(
      'SELECT COUNT(*) AS n FROM sessions WHERE date = ?1',
    )
      .bind('2026-05-17')
      .first<{ n: number }>();
    expect(persisted?.n).toBe(0);
  });

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
    expect(await first.json()).toMatchObject({
      deduped: false,
      session: { id: session.id, status: 'in_progress', attempt: 0 },
    });

    // same id again (offline retry) -> deduped, no duplicate row
    const retry = await SELF.fetch(`${BASE}/api/sessions/${session.id}/sets`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify(setBody),
    });
    expect(retry.status).toBe(200);
    expect(await retry.json()).toMatchObject({
      deduped: true,
      session: { id: session.id, status: 'in_progress', attempt: 0 },
    });

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

    // A known catalog muscle with no logs is a valid empty result; a typo is
    // a structured client error rather than a misleading zero-volume week.
    const knownEmpty = await SELF.fetch(`${BASE}/api/volume?muscle=shoulders`, {
      headers: H,
    });
    expect(knownEmpty.status).toBe(200);
    expect(await knownEmpty.json()).toMatchObject({ muscle_group: 'shoulders', buckets: [] });
    const unknown = await SELF.fetch(`${BASE}/api/volume?muscle=chset-typo`, {
      headers: H,
    });
    expect(unknown.status).toBe(400);
    expect(await unknown.json()).toEqual({ error: 'unknown_muscle', query: 'chset-typo' });

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

// Phantom-session guard: logging promotes a session planned->in_progress;
// deleting the LAST live set must reverse it back to 'planned' so an empty
// "in progress" row can never linger (the calendar/agenda + MCP otherwise
// surface a workout that records no work). See patchSet's isDelete branch.
describe('deleting the last set reverts an in_progress session to planned', () => {
  it('reverts to planned only when zero live sets remain', async () => {
    const jwt = await devJwt();
    const H = auth(jwt);

    await SELF.fetch(`${BASE}/api/plan`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ name: 'Strength' }),
    });

    const session = await (
      await SELF.fetch(`${BASE}/api/sessions`, {
        method: 'POST',
        headers: H,
        body: JSON.stringify({ date: '2026-06-01' }),
      })
    ).json<{ id: string; status: string }>();
    expect(session.status).toBe('planned'); // fresh row

    const statusOf = async () =>
      (
        await env.DB.prepare('SELECT status, started_at FROM sessions WHERE id=?1')
          .bind(session.id)
          .first<{ status: string; started_at: number | null }>()
      )!;

    // Log two sets -> session promoted to in_progress with a started_at.
    const setA = crypto.randomUUID();
    const setB = crypto.randomUUID();
    for (const [id, idx] of [
      [setA, 1],
      [setB, 2],
    ] as const) {
      const r = await SELF.fetch(`${BASE}/api/sessions/${session.id}/sets`, {
        method: 'POST',
        headers: H,
        body: JSON.stringify({ id, exercise_id: 'ex_bench', set_index: idx, weight: 135, reps: 5 }),
      });
      expect(r.status).toBe(201);
    }
    let s = await statusOf();
    expect(s.status).toBe('in_progress');
    expect(s.started_at).not.toBeNull();

    // Delete ONE of two -> a live set remains -> still in_progress.
    await SELF.fetch(`${BASE}/api/sets/${setA}`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ deleted: true }),
    });
    expect((await statusOf()).status).toBe('in_progress');

    // Delete the LAST live set -> revert to planned, started_at cleared.
    await SELF.fetch(`${BASE}/api/sets/${setB}`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ deleted: true }),
    });
    s = await statusOf();
    expect(s.status).toBe('planned');
    expect(s.started_at).toBeNull();

    // Re-logging cleanly promotes it back to in_progress (no stranded state).
    const setC = crypto.randomUUID();
    const relog = await SELF.fetch(`${BASE}/api/sessions/${session.id}/sets`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ id: setC, exercise_id: 'ex_bench', set_index: 1, weight: 145, reps: 5 }),
    });
    expect(relog.status).toBe(201);
    expect((await statusOf()).status).toBe('in_progress');
  });

  it('does NOT un-complete a completed session when its last set is deleted', async () => {
    const jwt = await devJwt();
    const H = auth(jwt);

    await SELF.fetch(`${BASE}/api/plan`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ name: 'Strength' }),
    });
    const session = await (
      await SELF.fetch(`${BASE}/api/sessions`, {
        method: 'POST',
        headers: H,
        body: JSON.stringify({ date: '2026-06-02' }),
      })
    ).json<{ id: string }>();

    const setId = crypto.randomUUID();
    await SELF.fetch(`${BASE}/api/sessions/${session.id}/sets`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ id: setId, exercise_id: 'ex_bench', set_index: 1, weight: 135, reps: 5 }),
    });
    // Mark the session completed (a deliberate terminal state).
    const comp = await SELF.fetch(`${BASE}/api/sessions/${session.id}`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ status: 'completed' }),
    });
    expect(comp.status).toBe(200);

    // Deleting its only set must NOT auto-un-complete it.
    await SELF.fetch(`${BASE}/api/sets/${setId}`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ deleted: true }),
    });
    const row = await env.DB.prepare('SELECT status FROM sessions WHERE id=?1')
      .bind(session.id)
      .first<{ status: string }>();
    expect(row!.status).toBe('completed');
  });
});

// FIX2 class-completion: the REST PATCH /api/sessions/:id entry point must
// reject a `skipped` patch on a started/finished session, exactly like the
// MCP skipPlannedSession guard — otherwise iOS could bury logged history.
describe('PATCH /api/sessions/:id — skipped patch cannot bury started/finished history', () => {
  // Order-independence: dev auth always resolves to the SAME single owner
  // user, and getOrCreateSession is keyed (user_id, date) with NO plan
  // scoping — so a shared date would return the PRIOR test's mutated row
  // under any storage-isolation regime. Each test therefore uses its OWN
  // unique date, and freshSession asserts the row it gets back is a
  // genuinely fresh `planned` session (fails loudly on any cross-test
  // bleed instead of silently testing the wrong state).
  async function freshSession(H: Record<string, string>, date: string): Promise<string> {
    await SELF.fetch(`${BASE}/api/plan`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ name: 'Skip Guard Plan' }),
    });
    const s = await (
      await SELF.fetch(`${BASE}/api/sessions`, {
        method: 'POST',
        headers: H,
        body: JSON.stringify({ date }),
      })
    ).json<{ id: string; status: string }>();
    expect(s.status).toBe('planned'); // isolation guard: must start fresh
    return s.id;
  }

  it('bridges released tokenless writes until attempt-v1 atomically claims the generation', async () => {
    const H = auth(await devJwt());
    const V1 = { ...H, 'X-TresFort-Write-Protocol': 'attempt-v1' };
    const date = '2026-08-20';
    const id = await freshSession(H, date);

    // Compatibility Worker first: the released app can log, discard, and
    // explicitly start the date again without an attempt field.
    const legacySetId = crypto.randomUUID();
    const legacySet = await SELF.fetch(`${BASE}/api/sessions/${id}/sets`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({
        id: legacySetId,
        exercise_id: 'ex_bench',
        set_index: 1,
        weight: 135,
        reps: 5,
      }),
    });
    expect(legacySet.status).toBe(201);
    const legacyDiscard = await SELF.fetch(`${BASE}/api/sessions/${id}/discard`, {
      method: 'POST',
      headers: H,
    });
    expect(legacyDiscard.status).toBe(200);
    const legacyRestart = await SELF.fetch(`${BASE}/api/sessions`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ date }),
    });
    expect(legacyRestart.status).toBe(201);
    expect(await legacyRestart.json()).toMatchObject({
      id,
      status: 'planned',
      attempt: 1,
      write_protocol: 'legacy',
    });

    const beforeActivation = await SELF.fetch(`${BASE}/api/sessions`, {
      method: 'POST',
      headers: V1,
      body: JSON.stringify({ date, expected_attempt: 1 }),
    });
    expect(beforeActivation.status).toBe(503);
    expect(await beforeActivation.json()).toEqual({
      error: 'write_protocol_not_active',
      protocol: 'attempt-v1',
      retryable: true,
    });
    await activateWorkoutWriteFence();

    // The upgraded app's first scoped resolver fences this exact generation.
    const claimed = await SELF.fetch(`${BASE}/api/sessions`, {
      method: 'POST',
      headers: V1,
      body: JSON.stringify({ date, expected_attempt: 1 }),
    });
    expect(claimed.status).toBe(201);
    expect(await claimed.json()).toMatchObject({
      id,
      attempt: 1,
      write_protocol: 'attempt-v1',
    });

    const staleLegacySetId = crypto.randomUUID();
    const staleLegacySet = await SELF.fetch(`${BASE}/api/sessions/${id}/sets`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({
        id: staleLegacySetId,
        exercise_id: 'ex_bench',
        set_index: 1,
        weight: 145,
        reps: 5,
      }),
    });
    expect(staleLegacySet.status).toBe(409);
    expect(await staleLegacySet.json()).toMatchObject({
      error: 'session_attempt_required',
      current_attempt: 1,
      current_session: { id, write_protocol: 'attempt-v1' },
    });
    expect(
      await env.DB.prepare('SELECT id FROM set_logs WHERE id=?1')
        .bind(staleLegacySetId)
        .first(),
    ).toBeNull();

    for (const response of [
      await SELF.fetch(`${BASE}/api/sessions/${id}`, {
        method: 'PATCH',
        headers: H,
        body: JSON.stringify({ status: 'completed' }),
      }),
      await SELF.fetch(`${BASE}/api/sessions/${id}/discard`, {
        method: 'POST',
        headers: H,
      }),
      await SELF.fetch(`${BASE}/api/sessions`, {
        method: 'POST',
        headers: H,
        body: JSON.stringify({ date }),
      }),
    ]) {
      expect(response.status).toBe(409);
      expect(await response.json()).toMatchObject({
        error: 'session_attempt_required',
        current_attempt: 1,
      });
    }
  });

  it('rejects a nonzero create token without leaving a phantom session', async () => {
    const H = auth(await devJwt());
    const date = '2026-08-21';
    const plan = await SELF.fetch(`${BASE}/api/plan`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ name: 'Missing Attempt Plan' }),
    });
    expect(plan.status).toBe(201);
    await activateWorkoutWriteFence();
    const response = await SELF.fetch(`${BASE}/api/sessions`, {
      method: 'POST',
      headers: { ...H, 'X-TresFort-Write-Protocol': 'attempt-v1' },
      body: JSON.stringify({ date, expected_attempt: 4 }),
    });
    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({
      error: 'session_attempt_missing',
      expected_attempt: 4,
    });
    expect(
      await env.DB.prepare('SELECT id FROM sessions WHERE date=?1').bind(date).first(),
    ).toBeNull();
  });

  it('advances legacy restarts during the migration-before-Worker window', async () => {
    const H = auth(await devJwt());
    const date = '2026-08-22';
    const id = await freshSession(H, date);
    await env.DB.prepare("UPDATE sessions SET status='discarded' WHERE id=?1")
      .bind(id)
      .run();

    // This is the old Worker's restart UPDATE: it knows neither column added
    // by migration 0032. The trigger supplies the missing generation advance.
    await env.DB.prepare(
      `UPDATE sessions
          SET status='planned', started_at=NULL, completed_at=NULL, updated_at=?2
        WHERE id=?1`,
    )
      .bind(id, Date.now())
      .run();
    expect(
      await env.DB.prepare('SELECT status,attempt,write_protocol FROM sessions WHERE id=?1')
        .bind(id)
        .first(),
    ).toEqual({ status: 'planned', attempt: 1, write_protocol: 'legacy' });

    await activateWorkoutWriteFence();
    // The new app may be retrying the explicit restart whose response was
    // lost during that window. It must adopt and claim the trigger-advanced
    // winner rather than leaving tokenless legacy writes enabled.
    const claimed = await SELF.fetch(`${BASE}/api/sessions`, {
      method: 'POST',
      headers: { ...H, 'X-TresFort-Write-Protocol': 'attempt-v1' },
      body: JSON.stringify({
        date,
        restart_discarded: true,
        expected_attempt: 0,
      }),
    });
    expect(claimed.status).toBe(201);
    expect(await claimed.json()).toMatchObject({
      id,
      status: 'planned',
      attempt: 1,
      write_protocol: 'attempt-v1',
    });
  });

  it('REJECTS skipped on a completed session (409); row + logged sets intact', async () => {
    const H = auth(await devJwt());
    const id = await freshSession(H, '2026-07-01');

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
    const id = await freshSession(H, '2026-07-02');
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
    const id = await freshSession(H, '2026-07-03'); // freshly created => 'planned'
    const r = await SELF.fetch(`${BASE}/api/sessions/${id}`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ status: 'skipped' }),
    });
    expect(r.status).toBe(200);
    expect(await r.json<{ status: string }>()).toMatchObject({ status: 'skipped' });
  });

  it('explicitly reopens skipped to a fresh planned attempt before logging', async () => {
    const H = auth(await devJwt());
    const id = await freshSession(H, '2026-07-11');
    const overrideDay = await (
      await SELF.fetch(`${BASE}/api/days`, {
        method: 'POST',
        headers: H,
        body: JSON.stringify({ name: 'Override Day', day_label: 'B', order_index: 0 }),
      })
    ).json<{ id: string }>();
    const skipped = await SELF.fetch(
      `${BASE}/api/sessions/${id}?expected_attempt=0`, {
        method: 'PATCH',
        headers: H,
        body: JSON.stringify({ status: 'skipped' }),
      });
    expect(skipped.status).toBe(200);
    expect(await skipped.json()).toMatchObject({
      id,
      status: 'skipped',
      attempt: 0,
    });

    const blockedSetId = crypto.randomUUID();
    const blocked = await SELF.fetch(`${BASE}/api/sessions/${id}/sets`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({
        id: blockedSetId,
        exercise_id: 'ex_bench',
        set_index: 1,
        weight: 135,
        reps: 5,
        expected_attempt: 0,
      }),
    });
    expect(blocked.status).toBe(409);
    expect(await blocked.json()).toMatchObject({
      error: 'session_state_conflict',
      current_session: { id, status: 'skipped', attempt: 0 },
    });

    const reopened = await SELF.fetch(
      `${BASE}/api/sessions/${id}?expected_attempt=0`, {
        method: 'PATCH',
        headers: H,
        body: JSON.stringify({
          status: 'planned',
          day_template_id: overrideDay.id,
        }),
      });
    expect(reopened.status).toBe(200);
    expect(await reopened.json()).toMatchObject({
      id,
      status: 'planned',
      attempt: 1,
      day_template_id: overrideDay.id,
    });

    const logged = await SELF.fetch(`${BASE}/api/sessions/${id}/sets`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({
        id: crypto.randomUUID(),
        exercise_id: 'ex_bench',
        set_index: 1,
        weight: 135,
        reps: 5,
        expected_attempt: 1,
      }),
    });
    expect(logged.status).toBe(201);
    expect(await logged.json()).toMatchObject({
      session: {
        id,
        status: 'in_progress',
        attempt: 1,
        day_template_id: overrideDay.id,
      },
    });
    expect(
      await env.DB.prepare('SELECT day_template_id FROM sessions WHERE id=?1')
        .bind(id)
        .first<{ day_template_id: string | null }>(),
    ).toEqual({ day_template_id: overrideDay.id });
    expect(
      await env.DB.prepare('SELECT id FROM set_logs WHERE id=?1')
        .bind(blockedSetId)
        .first(),
    ).toBeNull();
  });

  it('non-skipped status patch and field-only patch on a completed session are unchanged', async () => {
    const H = auth(await devJwt());
    const id = await freshSession(H, '2026-07-04');

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

  // P3: casing/whitespace must not bypass the guard. {"status":"  SKIPPED "}
  // on a completed session is normalized to 'skipped' and STILL rejected.
  it('REJECTS a non-canonically-cased skipped patch (e.g. "SKIPPED") on a completed session', async () => {
    const H = auth(await devJwt());
    const id = await freshSession(H, '2026-07-05');
    const comp = await SELF.fetch(`${BASE}/api/sessions/${id}`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ status: 'completed' }),
    });
    expect(comp.status).toBe(200);

    const rej = await SELF.fetch(`${BASE}/api/sessions/${id}`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ status: '  SKIPPED ' }),
    });
    expect(rej.status).toBe(409);
    expect(await rej.json()).toEqual({ error: 'session_already_started', status: 'completed' });
    const row = await env.DB.prepare('SELECT status FROM sessions WHERE id=?1')
      .bind(id)
      .first<{ status: string }>();
    expect(row!.status).toBe('completed'); // not buried by the cased bypass
  });

  // P2: an unknown status must be rejected (400) by the allowlist BEFORE
  // any write — never persisted. This is what makes the patchSession
  // "can never silently corrupt the row" comment actually true.
  it('REJECTS an unknown status with 400 and does not persist it', async () => {
    const H = auth(await devJwt());
    const id = await freshSession(H, '2026-07-06'); // fresh => 'planned'
    const r = await SELF.fetch(`${BASE}/api/sessions/${id}`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ status: 'junk' }),
    });
    expect(r.status).toBe(400);
    expect(await r.json()).toEqual({ error: 'invalid_status', status: 'junk' });
    // Row is untouched — still the freshly-created 'planned'.
    const row = await env.DB.prepare('SELECT status FROM sessions WHERE id=?1')
      .bind(id)
      .first<{ status: string }>();
    expect(row!.status).toBe('planned');
  });

  it('accepts every valid status (planned → in_progress → completed; and skipped)', async () => {
    const H = auth(await devJwt());
    const id = await freshSession(H, '2026-07-07');
    for (const st of ['in_progress', 'completed'] as const) {
      const r = await SELF.fetch(`${BASE}/api/sessions/${id}`, {
        method: 'PATCH',
        headers: H,
        body: JSON.stringify({ status: st }),
      });
      expect(r.status).toBe(200);
      expect(await r.json<{ status: string }>()).toMatchObject({ status: st });
    }
    // A separate fresh session to exercise the planned → skipped valid path.
    const id2 = await freshSession(H, '2026-07-08');
    const skip = await SELF.fetch(`${BASE}/api/sessions/${id2}`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ status: 'planned' }),
    });
    expect(skip.status).toBe(200);
    expect(await skip.json<{ status: string }>()).toMatchObject({ status: 'planned' });
  });

  it('field-only patch (no status key) is unaffected by the allowlist', async () => {
    const H = auth(await devJwt());
    const id = await freshSession(H, '2026-07-09'); // 'planned'
    const r = await SELF.fetch(`${BASE}/api/sessions/${id}`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ perceived_fatigue: 5, notes: 'ok' }),
    });
    expect(r.status).toBe(200);
    expect(await r.json<{ status: string; perceived_fatigue: number; notes: string }>()).toMatchObject({
      status: 'planned', // status preserved, validation not triggered
      perceived_fatigue: 5,
      notes: 'ok',
    });
  });

  // P1 regression: the PATCH body is NOT runtime-validated. A present-but-
  // non-string `status` previously hit .trim() on a non-string → TypeError
  // → HTTP 500. It must now be a clean 400 invalid_status with NOTHING
  // persisted (row stays the freshly-created 'planned').
  it('REJECTS a non-string status with 400 (NOT 500) and persists nothing', async () => {
    const H = auth(await devJwt());
    const cases: Array<{ date: string; status: unknown }> = [
      { date: '2026-07-10', status: 123 },
      { date: '2026-07-11', status: null },
      { date: '2026-07-12', status: true },
      { date: '2026-07-13', status: {} },
      { date: '2026-07-14', status: [] },
    ];
    for (const { date, status } of cases) {
      const id = await freshSession(H, date); // fresh => 'planned'
      const r = await SELF.fetch(`${BASE}/api/sessions/${id}`, {
        method: 'PATCH',
        headers: H,
        body: JSON.stringify({ status }),
      });
      expect(r.status, `status=${JSON.stringify(status)}`).toBe(400);
      const body = await r.json<{ error: string }>();
      expect(body.error, `status=${JSON.stringify(status)}`).toBe('invalid_status');
      // Row untouched — still the freshly-created 'planned'.
      const row = await env.DB.prepare('SELECT status FROM sessions WHERE id=?1')
        .bind(id)
        .first<{ status: string }>();
      expect(row!.status, `status=${JSON.stringify(status)}`).toBe('planned');
    }
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
  it('lists the seeded catalog incl timed exercises and laterality', async () => {
    const jwt = await devJwt();
    const r = await SELF.fetch(`${BASE}/api/exercises`, { headers: auth(jwt) });
    expect(r.status).toBe(200);
    const list = await r.json<{ id: string; modality: string; laterality?: string }[]>();
    expect(list.find((e) => e.id === 'ex_bench')).toBeTruthy();
    expect(list.find((e) => e.id === 'ex_plank')?.modality).toBe('timed');
    // Regression guard: laterality MUST ride along so iOS's sides(for:)
    // lookup doesn't silently default unilateral rows to bilateral and
    // halve every Bulgarian split squat rollup (Codex review on #18).
    expect(list.find((e) => e.id === 'ex_bench')?.laterality).toBe('bilateral');
    expect(list.find((e) => e.id === 'ex_db_split_squat')?.laterality).toBe('unilateral');
    expect(list.every((e) => typeof e.laterality === 'string')).toBe(true);
  });
});

describe('POST /api/sessions/:id/discard — the explicit escape hatch', () => {
  // Each test uses its own unique date (dev auth = one owner;
  // getOrCreateSession is keyed (user,date)) and asserts a fresh planned
  // session, failing loudly on cross-test bleed.
  async function freshSession(H: Record<string, string>, date: string): Promise<string> {
    await SELF.fetch(`${BASE}/api/plan`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ name: 'Discard Plan' }),
    });
    const s = await (
      await SELF.fetch(`${BASE}/api/sessions`, {
        method: 'POST',
        headers: H,
        body: JSON.stringify({ date }),
      })
    ).json<{ id: string; status: string }>();
    expect(s.status).toBe('planned');
    return s.id;
  }

  it('discard soft-deletes the sets and marks the session discarded (even when completed)', async () => {
    const H = auth(await devJwt());
    const id = await freshSession(H, '2026-08-01');
    const setId = crypto.randomUUID();
    await SELF.fetch(`${BASE}/api/sessions/${id}/sets`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ id: setId, exercise_id: 'ex_bench', set_index: 1, weight: 135, reps: 5 }),
    });
    await SELF.fetch(`${BASE}/api/sessions/${id}`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ status: 'completed' }),
    });

    // PATCH→skipped is still rejected (burial guard intact)…
    const rej = await SELF.fetch(`${BASE}/api/sessions/${id}`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ status: 'skipped' }),
    });
    expect(rej.status).toBe(409);

    // …but the explicit discard endpoint IS allowed (sanctioned override).
    const disc = await SELF.fetch(`${BASE}/api/sessions/${id}/discard`, {
      method: 'POST',
      headers: H,
    });
    expect(disc.status).toBe(200);
    expect((await disc.json<{ status: string }>()).status).toBe('discarded');

    const row = await env.DB.prepare('SELECT status FROM sessions WHERE id=?1')
      .bind(id)
      .first<{ status: string }>();
    expect(row!.status).toBe('discarded');
    const set = await env.DB.prepare('SELECT deleted_at FROM set_logs WHERE id=?1')
      .bind(setId)
      .first<{ deleted_at: number | null }>();
    expect(set!.deleted_at).not.toBeNull(); // explicitly thrown away, not hidden
  });

  it('after discard, /api/state carries the discarded session and its set as a tombstone (deleted_at set)', async () => {
    // Projection-vanish itself is unit-tested in calendar.test.ts (3
    // cases). Here we assert the SYNC contract: the session delta still
    // carries the row (status 'discarded' — clients filter/vanish it),
    // while the soft-deleted set no longer appears in the sets delta.
    const H = auth(await devJwt());
    const date = '2026-08-05';
    const id = await freshSession(H, date);
    const setId = crypto.randomUUID();
    await SELF.fetch(`${BASE}/api/sessions/${id}/sets`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ id: setId, exercise_id: 'ex_bench', set_index: 1, weight: 115, reps: 5 }),
    });
    await SELF.fetch(`${BASE}/api/sessions/${id}/discard?expected_attempt=0`, {
      method: 'POST',
      headers: H,
    });

    const state = await (
      await SELF.fetch(`${BASE}/api/state?since=0&sets_since=0`, { headers: H })
    ).json<{
      sessions: { id: string; status: string }[];
      sets: { id: string; deleted_at: number | null }[];
    }>();
    const row = state.sessions.find((s) => s.id === id);
    expect(row?.status).toBe('discarded');
    // A full reload (sets_since=0) carries the discarded set as a
    // TOMBSTONE (deleted_at set) — not absent — so a syncing client drops
    // it locally. This is the documented FIX3 set_logs sync contract.
    const tomb = state.sets.find((s) => s.id === setId);
    expect(tomb).toBeDefined();
    expect(tomb!.deleted_at).not.toBeNull();
  });

  it('rejects stale completion and brand-new sets after discard while preserving exact set retries', async () => {
    const H = auth(await devJwt());
    const id = await freshSession(H, '2026-08-07');
    const priorSetId = crypto.randomUUID();
    const priorSet = {
      id: priorSetId,
      exercise_id: 'ex_bench',
      set_index: 1,
      weight: 125,
      reps: 5,
    };
    const logged = await SELF.fetch(`${BASE}/api/sessions/${id}/sets`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify(priorSet),
    });
    expect(logged.status).toBe(201);

    const discarded = await SELF.fetch(`${BASE}/api/sessions/${id}/discard`, {
      method: 'POST',
      headers: H,
    });
    expect(discarded.status).toBe(200);

    const staleCompletion = await SELF.fetch(`${BASE}/api/sessions/${id}`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ status: 'completed' }),
    });
    expect(staleCompletion.status).toBe(409);
    expect(await staleCompletion.json()).toMatchObject({
      error: 'session_discarded',
      status: 'discarded',
      current_session: { id, status: 'discarded', attempt: 0 },
    });

    const newSetId = crypto.randomUUID();
    const staleNewSet = await SELF.fetch(`${BASE}/api/sessions/${id}/sets`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ ...priorSet, id: newSetId, set_index: 2 }),
    });
    expect(staleNewSet.status).toBe(409);
    expect(await staleNewSet.json()).toMatchObject({
      error: 'session_discarded',
      current_session: { id, status: 'discarded', attempt: 0 },
    });

    // A lost-response retry for the exact pre-discard UUID remains readable
    // and idempotent, including its tombstone, so the client can settle it.
    const exactRetry = await SELF.fetch(`${BASE}/api/sessions/${id}/sets`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify(priorSet),
    });
    expect(exactRetry.status).toBe(200);
    expect(await exactRetry.json()).toMatchObject({
      deduped: true,
      set: { id: priorSetId, session_id: id, deleted_at: expect.any(Number) },
      session: { id, status: 'discarded', attempt: 0 },
    });

    const session = await env.DB
      .prepare('SELECT status FROM sessions WHERE id = ?1')
      .bind(id)
      .first<{ status: string }>();
    const prior = await env.DB
      .prepare('SELECT deleted_at FROM set_logs WHERE id = ?1')
      .bind(priorSetId)
      .first<{ deleted_at: number | null }>();
    expect(session?.status).toBe('discarded');
    expect(prior?.deleted_at).not.toBeNull();
    expect(
      await env.DB.prepare('SELECT id FROM set_logs WHERE id = ?1').bind(newSetId).first(),
    ).toBeNull();
  });

  it('restart after discard resurrects a fresh planned session (same date, reusable)', async () => {
    const H = auth(await devJwt());
    const date = '2026-08-10';
    const id = await freshSession(H, date);
    const discardedSet = {
      id: crypto.randomUUID(),
      exercise_id: 'ex_bench',
      set_index: 1,
      weight: 95,
      reps: 5,
      expected_attempt: 0,
    };
    await SELF.fetch(`${BASE}/api/sessions/${id}/sets`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify(discardedSet),
    });
    const discardResponse = await SELF.fetch(
      `${BASE}/api/sessions/${id}/discard?expected_attempt=0`,
      { method: 'POST', headers: H },
    );
    expect(discardResponse.status).toBe(200);

    // An ordinary delayed creator has no restart provenance and fails closed.
    const staleCreate = await SELF.fetch(`${BASE}/api/sessions`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ date, expected_attempt: 0 }),
    });
    expect(staleCreate.status).toBe(409);
    expect(await staleCreate.json()).toMatchObject({
      error: 'session_discarded',
      current_session: { id, status: 'discarded', attempt: 0 },
    });

    // Explicit restart carries the prior generation and advances exactly once.
    const restartRequest = {
      date,
      restart_discarded: true,
      expected_attempt: 0,
    };
    const revivedResponse = await SELF.fetch(`${BASE}/api/sessions`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify(restartRequest),
    });
    expect(revivedResponse.status).toBe(201);
    const revived = await revivedResponse.json<{
      id: string;
      status: string;
      started_at: number | null;
      attempt: number;
    }>();
    expect(revived.id).toBe(id);
    expect(revived.status).toBe('planned');
    expect(revived.started_at).toBeNull();
    expect(revived.attempt).toBe(1);

    // Commit-then-timeout retry returns the same generation.
    const retriedRestart = await SELF.fetch(`${BASE}/api/sessions`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify(restartRequest),
    });
    expect(retriedRestart.status).toBe(201);
    expect(await retriedRestart.json()).toMatchObject({
      id,
      status: 'planned',
      attempt: 1,
    });

    // Restart is the explicit attempt boundary: fresh work and completion
    // are accepted again only after POST /sessions performed the revival.
    const freshSet = await SELF.fetch(`${BASE}/api/sessions/${id}/sets`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({
        id: crypto.randomUUID(),
        exercise_id: 'ex_bench',
        set_index: 1,
        weight: 105,
        reps: 5,
        expected_attempt: 1,
      }),
    });
    expect(freshSet.status).toBe(201);

    // The exact old UUID settles idempotently after restart. It remains a
    // tombstone and echoes the authoritative current attempt without applying
    // any old work to that attempt.
    const oldRetry = await SELF.fetch(`${BASE}/api/sessions/${id}/sets`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify(discardedSet),
    });
    expect(oldRetry.status).toBe(200);
    expect(await oldRetry.json()).toMatchObject({
      deduped: true,
      set: { id: discardedSet.id, deleted_at: expect.any(Number) },
      session: { id, status: 'in_progress', attempt: 1 },
    });

    const staleSetId = crypto.randomUUID();
    const staleSet = await SELF.fetch(`${BASE}/api/sessions/${id}/sets`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({
        id: staleSetId,
        exercise_id: 'ex_bench',
        set_index: 2,
        weight: 115,
        reps: 5,
        expected_attempt: 0,
      }),
    });
    expect(staleSet.status).toBe(409);
    expect(await staleSet.json()).toMatchObject({
      error: 'session_attempt_conflict',
      expected_attempt: 0,
      current_attempt: 1,
      current_session: { id, status: 'in_progress', attempt: 1 },
    });
    const staleFinish = await SELF.fetch(
      `${BASE}/api/sessions/${id}?expected_attempt=0`, {
        method: 'PATCH',
        headers: H,
        body: JSON.stringify({ status: 'completed' }),
      });
    expect(staleFinish.status).toBe(409);
    expect(await staleFinish.json()).toMatchObject({
      error: 'session_attempt_conflict',
      current_session: { id, status: 'in_progress', attempt: 1 },
    });
    const staleDiscard = await SELF.fetch(
      `${BASE}/api/sessions/${id}/discard?expected_attempt=0`, {
        method: 'POST',
        headers: H,
      });
    expect(staleDiscard.status).toBe(409);
    expect(await staleDiscard.json()).toMatchObject({
      error: 'session_attempt_conflict',
      current_session: { id, status: 'in_progress', attempt: 1 },
    });
    expect(
      await env.DB.prepare('SELECT id FROM set_logs WHERE id=?1')
        .bind(staleSetId)
        .first(),
    ).toBeNull();
    const completed = await SELF.fetch(
      `${BASE}/api/sessions/${id}?expected_attempt=1`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ status: 'completed' }),
    });
    expect(completed.status).toBe(200);
    expect(await completed.json()).toMatchObject({ id, status: 'completed' });
  });

  it('idempotent: re-discarding an already-discarded session is a clean no-op', async () => {
    const H = auth(await devJwt());
    const id = await freshSession(H, '2026-08-15');
    const a = await SELF.fetch(`${BASE}/api/sessions/${id}/discard`, { method: 'POST', headers: H });
    expect(a.status).toBe(200);
    const b = await SELF.fetch(`${BASE}/api/sessions/${id}/discard`, { method: 'POST', headers: H });
    expect(b.status).toBe(200);
    expect((await b.json<{ status: string }>()).status).toBe('discarded');
    const audits = await env.DB
      .prepare("SELECT args FROM audit_log WHERE tool = 'discard_session'")
      .all<{ args: string }>();
    expect(
      audits.results.filter(
        (row) => (JSON.parse(row.args) as { session_id?: string }).session_id === id,
      ),
    ).toHaveLength(1);
  });

  it('discarding an unknown session id → 404', async () => {
    const H = auth(await devJwt());
    const r = await SELF.fetch(`${BASE}/api/sessions/does-not-exist/discard`, {
      method: 'POST',
      headers: H,
    });
    expect(r.status).toBe(404);
  });
});

describe('migration 0029 session aliases — stale REST mutations self-heal', () => {
  async function freshAliasedSession(
    H: Record<string, string>,
    date: string,
  ): Promise<{ aliasId: string; canonicalId: string }> {
    const plan = await SELF.fetch(`${BASE}/api/plan`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ name: `Alias bridge ${date}` }),
    });
    expect(plan.status).toBe(201);
    const session = await SELF.fetch(`${BASE}/api/sessions`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ date }),
    });
    expect(session.status).toBe(201);
    const canonical = await session.json<{ id: string; status: string }>();
    expect(canonical.status).toBe('planned');

    const aliasId = crypto.randomUUID();
    await env.DB
      .prepare(
        'INSERT INTO session_aliases (alias_session_id,canonical_session_id) VALUES (?1,?2)',
      )
      .bind(aliasId, canonical.id)
      .run();
    return { aliasId, canonicalId: canonical.id };
  }

  it('routes alias set retries, completion, and discard to the canonical session', async () => {
    const H = auth(await devJwt());
    const { aliasId, canonicalId } = await freshAliasedSession(H, '2041-01-10');
    const setId = crypto.randomUUID();
    const setBody = {
      id: setId,
      exercise_id: 'ex_bench',
      set_index: 1,
      weight: 185,
      reps: 5,
    };

    const first = await SELF.fetch(`${BASE}/api/sessions/${aliasId}/sets`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify(setBody),
    });
    expect(first.status).toBe(201);
    expect(await first.json()).toMatchObject({
      deduped: false,
      set: { id: setId, session_id: canonicalId },
      session: { id: canonicalId, status: 'in_progress', attempt: 0 },
    });

    // The offline retry still uses the stale path id, but the stored and
    // returned set identifies the canonical session so the client can heal.
    const retry = await SELF.fetch(`${BASE}/api/sessions/${aliasId}/sets`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify(setBody),
    });
    expect(retry.status).toBe(200);
    expect(await retry.json()).toMatchObject({
      deduped: true,
      set: { id: setId, session_id: canonicalId },
      session: { id: canonicalId, status: 'in_progress', attempt: 0 },
    });

    const complete = await SELF.fetch(`${BASE}/api/sessions/${aliasId}`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ status: 'completed' }),
    });
    expect(complete.status).toBe(200);
    expect(await complete.json()).toMatchObject({ id: canonicalId, status: 'completed' });

    const discard = await SELF.fetch(`${BASE}/api/sessions/${aliasId}/discard`, {
      method: 'POST',
      headers: H,
    });
    expect(discard.status).toBe(200);
    expect(await discard.json()).toMatchObject({ id: canonicalId, status: 'discarded' });

    const canonical = await env.DB
      .prepare('SELECT status FROM sessions WHERE id = ?1')
      .bind(canonicalId)
      .first<{ status: string }>();
    const set = await env.DB
      .prepare('SELECT session_id,deleted_at FROM set_logs WHERE id = ?1')
      .bind(setId)
      .first<{ session_id: string; deleted_at: number | null }>();
    expect(canonical?.status).toBe('discarded');
    expect(set?.session_id).toBe(canonicalId);
    expect(set?.deleted_at).not.toBeNull();
    expect(
      await env.DB.prepare('SELECT id FROM sessions WHERE id = ?1').bind(aliasId).first(),
    ).toBeNull();
  });

  it('rejects a foreign tenant alias across every bridged mutation', async () => {
    const H = auth(await devJwt());
    const foreignUserId = crypto.randomUUID();
    const foreignPlanId = crypto.randomUUID();
    const foreignSessionId = crypto.randomUUID();
    const foreignAliasId = crypto.randomUUID();
    const foreignSetId = crypto.randomUUID();
    const ts = Date.now();
    await env.DB.batch([
      env.DB
        .prepare(
          'INSERT INTO users (id,apple_sub,email,display_name,created_at) VALUES (?1,?2,NULL,?3,?4)',
        )
        .bind(foreignUserId, `sub-${foreignUserId}`, 'Foreign lifter', ts),
      env.DB
        .prepare(
          `INSERT INTO plans
           (id,user_id,name,status,version,meta,created_at,updated_at)
           VALUES (?1,?2,'Foreign plan','active',1,NULL,?3,?3)`,
        )
        .bind(foreignPlanId, foreignUserId, ts),
      env.DB
        .prepare(
          `INSERT INTO sessions
           (id,user_id,plan_id,day_template_id,date,status,started_at,completed_at,perceived_fatigue,notes,created_at,updated_at)
           VALUES (?1,?2,?3,NULL,'2041-01-11','planned',NULL,NULL,NULL,NULL,?4,?4)`,
        )
        .bind(foreignSessionId, foreignUserId, foreignPlanId, ts),
      env.DB
        .prepare(
          'INSERT INTO session_aliases (alias_session_id,canonical_session_id) VALUES (?1,?2)',
        )
        .bind(foreignAliasId, foreignSessionId),
      env.DB
        .prepare(
          `INSERT INTO set_logs
           (id,session_id,exercise_id,template_exercise_id,set_index,weight,reps,rpe,is_warmup,notes,logged_at,source,duration_s,is_timed,deleted_at)
           VALUES (?1,?2,'ex_bench',NULL,1,225,5,8,0,NULL,?3,'ios',NULL,0,NULL)`,
        )
        .bind(foreignSetId, foreignSessionId, ts),
    ]);

    const setId = crypto.randomUUID();
    const set = await SELF.fetch(`${BASE}/api/sessions/${foreignAliasId}/sets`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({
        id: setId,
        exercise_id: 'ex_bench',
        set_index: 1,
        weight: 135,
        reps: 5,
      }),
    });
    expect(set.status).toBe(404);
    expect(await set.json()).toEqual({ error: 'session_not_found' });

    const complete = await SELF.fetch(`${BASE}/api/sessions/${foreignAliasId}`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ status: 'completed' }),
    });
    expect(complete.status).toBe(404);
    expect(await complete.json()).toEqual({ error: 'not_found' });

    const discard = await SELF.fetch(`${BASE}/api/sessions/${foreignAliasId}/discard`, {
      method: 'POST',
      headers: H,
    });
    expect(discard.status).toBe(404);
    expect(await discard.json()).toEqual({ error: 'not_found' });

    // A valid owned alias must not turn the globally unique set UUID into a
    // cross-tenant read primitive. The foreign row remains undisclosed and
    // untouched rather than being returned as an idempotent retry.
    const owned = await freshAliasedSession(H, '2041-01-12');
    const foreignSetRetry = await SELF.fetch(`${BASE}/api/sessions/${owned.aliasId}/sets`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({
        id: foreignSetId,
        exercise_id: 'ex_bench',
        set_index: 1,
        weight: 225,
        reps: 5,
      }),
    });
    expect(foreignSetRetry.status).toBe(404);
    expect(await foreignSetRetry.json()).toEqual({ error: 'session_not_found' });
    const ownedAfterCollision = await env.DB
      .prepare('SELECT status FROM sessions WHERE id = ?1')
      .bind(owned.canonicalId)
      .first<{ status: string }>();
    expect(ownedAfterCollision?.status).toBe('planned');

    expect(
      await env.DB.prepare('SELECT id FROM set_logs WHERE id = ?1').bind(setId).first(),
    ).toBeNull();
    const foreign = await env.DB
      .prepare('SELECT status FROM sessions WHERE id = ?1')
      .bind(foreignSessionId)
      .first<{ status: string }>();
    expect(foreign?.status).toBe('planned');
    const foreignSet = await env.DB
      .prepare('SELECT session_id FROM set_logs WHERE id = ?1')
      .bind(foreignSetId)
      .first<{ session_id: string }>();
    expect(foreignSet?.session_id).toBe(foreignSessionId);
  });
});

// /mcp behavior is covered comprehensively in test/mcp.test.ts.

// ---- PATCH /api/me/integrations/intervals (M1 multi-user creds) ----------
describe('PATCH /api/me/integrations/intervals', () => {
  async function userIdFromJwt(): Promise<string> {
    // The dev JWT resolves to the single owner row; the bootstrap is
    // idempotent so we just read it back.
    const r = await env.DB.prepare(
      'SELECT id, intervals_api_key, intervals_athlete_id FROM users ORDER BY created_at LIMIT 1',
    ).first<{ id: string; intervals_api_key: string | null; intervals_athlete_id: string | null }>();
    return r!.id;
  }

  it('sets both credentials and reports connected=true', async () => {
    const H = auth(await devJwt());
    const r = await SELF.fetch(`${BASE}/api/me/integrations/intervals`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ api_key: 'live-key-1', athlete_id: 'i-1' }),
    });
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ connected: true });
    const userId = await userIdFromJwt();
    const row = await env.DB.prepare(
      'SELECT intervals_api_key, intervals_athlete_id FROM users WHERE id = ?1',
    )
      .bind(userId)
      .first<{ intervals_api_key: string; intervals_athlete_id: string }>();
    expect(row!.intervals_api_key).toBe('live-key-1');
    expect(row!.intervals_athlete_id).toBe('i-1');
    // Audit row recorded with actor='ios' (not 'mcp').
    const audit = await env.DB.prepare(
      "SELECT actor, result FROM audit_log WHERE tool='set_intervals_creds' AND user_id=?1 ORDER BY created_at DESC LIMIT 1",
    )
      .bind(userId)
      .first<{ actor: string; result: string }>();
    expect(audit!.actor).toBe('ios');
    expect(audit!.result).toBe('connected');
  });

  it('null on either field disconnects (clears both columns together)', async () => {
    const H = auth(await devJwt());
    // First connect so there is something to clear.
    await SELF.fetch(`${BASE}/api/me/integrations/intervals`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ api_key: 'k', athlete_id: 'a' }),
    });
    // Now null on api_key alone — both columns clear.
    const r = await SELF.fetch(`${BASE}/api/me/integrations/intervals`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ api_key: null, athlete_id: 'a' }),
    });
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ connected: false });
    const userId = await userIdFromJwt();
    const row = await env.DB.prepare(
      'SELECT intervals_api_key, intervals_athlete_id FROM users WHERE id = ?1',
    )
      .bind(userId)
      .first<{ intervals_api_key: string | null; intervals_athlete_id: string | null }>();
    expect(row!.intervals_api_key).toBeNull();
    expect(row!.intervals_athlete_id).toBeNull();
  });

  it('empty string is treated as null (disconnect)', async () => {
    const H = auth(await devJwt());
    await SELF.fetch(`${BASE}/api/me/integrations/intervals`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ api_key: 'live', athlete_id: 'live-id' }),
    });
    const r = await SELF.fetch(`${BASE}/api/me/integrations/intervals`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ api_key: '', athlete_id: '' }),
    });
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ connected: false });
  });

  it('missing fields → 400 (typo guard, so a partial body cannot wipe creds silently)', async () => {
    const H = auth(await devJwt());
    const r1 = await SELF.fetch(`${BASE}/api/me/integrations/intervals`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ api_key: 'k' }), // athlete_id missing
    });
    expect(r1.status).toBe(400);
    const r2 = await SELF.fetch(`${BASE}/api/me/integrations/intervals`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ athlete_id: 'a' }), // api_key missing
    });
    expect(r2.status).toBe(400);
    const r3 = await SELF.fetch(`${BASE}/api/me/integrations/intervals`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({}),
    });
    expect(r3.status).toBe(400);
  });

  it('wrong field type → 400', async () => {
    const H = auth(await devJwt());
    const r = await SELF.fetch(`${BASE}/api/me/integrations/intervals`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ api_key: 42, athlete_id: 'a' }),
    });
    expect(r.status).toBe(400);
  });

  it('rejects unauthenticated', async () => {
    const r = await SELF.fetch(`${BASE}/api/me/integrations/intervals`, {
      method: 'PATCH',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ api_key: 'k', athlete_id: 'a' }),
    });
    expect(r.status).toBe(401);
  });

  it('malformed JSON body → 400', async () => {
    const H = auth(await devJwt());
    const r = await SELF.fetch(`${BASE}/api/me/integrations/intervals`, {
      method: 'PATCH',
      headers: H,
      body: '{not valid',
    });
    expect(r.status).toBe(400);
  });
});
