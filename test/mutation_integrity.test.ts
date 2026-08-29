import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';

const BASE = 'https://tres-fort.test';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

async function devJwt(): Promise<string> {
  const response = await SELF.fetch(`${BASE}/auth/dev`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ secret: 'test-dev' }),
  });
  expect(response.status).toBe(200);
  return (await response.json<{ jwt: string }>()).jwt;
}

const auth = (jwt: string) => ({
  'content-type': 'application/json',
  Authorization: `Bearer ${jwt}`,
});

async function createPlanAndDay(
  headers: Record<string, string>,
  name: string,
): Promise<{ planId: string; dayId: string; version: number }> {
  const planResponse = await SELF.fetch(`${BASE}/api/plan`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ name }),
  });
  expect(planResponse.status).toBe(201);
  const plan = await planResponse.json<{ id: string }>();

  const dayResponse = await SELF.fetch(`${BASE}/api/days`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ name: 'Day A', day_label: 'A' }),
  });
  expect(dayResponse.status).toBe(201);
  const day = await dayResponse.json<{ id: string }>();

  const active = await (
    await SELF.fetch(`${BASE}/api/plan/active`, { headers })
  ).json<{ version: number }>();
  return { planId: plan.id, dayId: day.id, version: active.version };
}

async function addBench(headers: Record<string, string>, dayId: string) {
  return SELF.fetch(`${BASE}/api/days/${dayId}/exercises`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ exercise: 'bench', target_sets: 3, target_reps: 5 }),
  });
}

describe('POST /api/days/:id/exercises scopes the day to the active plan', () => {
  it("does not add to another user's day or bump the caller's plan", async () => {
    const headers = auth(await devJwt());
    const owner = await createPlanAndDay(headers, 'Owner active');

    const foreignUserId = crypto.randomUUID();
    const foreignPlanId = crypto.randomUUID();
    const foreignDayId = crypto.randomUUID();
    const now = Date.now();
    await env.DB.prepare(
      'INSERT INTO users (id,apple_sub,email,display_name,created_at) VALUES (?1,?2,NULL,?3,?4)',
    )
      .bind(foreignUserId, `sub-${foreignUserId}`, 'Other lifter', now)
      .run();
    await env.DB.prepare(
      "INSERT INTO plans (id,user_id,name,status,version,meta,created_at,updated_at) VALUES (?1,?2,'Foreign active','active',1,NULL,?3,?3)",
    )
      .bind(foreignPlanId, foreignUserId, now)
      .run();
    await env.DB.prepare(
      "INSERT INTO day_templates (id,plan_id,name,day_label,order_index,notes,created_at,updated_at) VALUES (?1,?2,'Foreign day','F',0,NULL,?3,?3)",
    )
      .bind(foreignDayId, foreignPlanId, now)
      .run();

    const response = await addBench(headers, foreignDayId);
    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ error: 'not_found' });

    const foreignSlots = await env.DB
      .prepare('SELECT COUNT(*) AS count FROM template_exercises WHERE day_template_id = ?1')
      .bind(foreignDayId)
      .first<{ count: number }>();
    expect(foreignSlots?.count).toBe(0);
    const activeVersion = await env.DB
      .prepare('SELECT version FROM plans WHERE id = ?1')
      .bind(owner.planId)
      .first<{ version: number }>();
    expect(activeVersion?.version).toBe(owner.version);
  });

  it("does not add to one of the caller's archived days", async () => {
    const headers = auth(await devJwt());
    const archived = await createPlanAndDay(headers, 'Soon archived');

    const activeResponse = await SELF.fetch(`${BASE}/api/plan`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ name: 'Replacement active' }),
    });
    expect(activeResponse.status).toBe(201);
    const active = await activeResponse.json<{ id: string; version: number }>();

    const response = await addBench(headers, archived.dayId);
    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ error: 'not_found' });

    const archivedSlots = await env.DB
      .prepare('SELECT COUNT(*) AS count FROM template_exercises WHERE day_template_id = ?1')
      .bind(archived.dayId)
      .first<{ count: number }>();
    expect(archivedSlots?.count).toBe(0);
    const activeVersion = await env.DB
      .prepare('SELECT version FROM plans WHERE id = ?1')
      .bind(active.id)
      .first<{ version: number }>();
    expect(activeVersion?.version).toBe(active.version);
  });
});

describe('REST session and set bodies are runtime-validated before writes', () => {
  it('rejects malformed fields and keeps later /api/state rows decodable', async () => {
    const headers = auth(await devJwt());
    await createPlanAndDay(headers, 'Validation plan');

    const badSession = await SELF.fetch(`${BASE}/api/sessions`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ date: 123 }),
    });
    expect(badSession.status).toBe(400);
    expect(await badSession.json()).toEqual({ error: 'invalid_fields', fields: ['date'] });
    const numericDateRows = await env.DB
      .prepare("SELECT COUNT(*) AS count FROM sessions WHERE date = '123'")
      .first<{ count: number }>();
    expect(numericDateRows?.count).toBe(0);

    const sessionResponse = await SELF.fetch(`${BASE}/api/sessions`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ date: '2026-12-20' }),
    });
    expect(sessionResponse.status).toBe(201);
    const session = await sessionResponse.json<{ id: string }>();

    const badSessionPatch = await SELF.fetch(`${BASE}/api/sessions/${session.id}`, {
      method: 'PATCH',
      headers,
      body: JSON.stringify({ perceived_fatigue: 'wrecked', notes: { text: 'nope' } }),
    });
    expect(badSessionPatch.status).toBe(400);
    expect(await badSessionPatch.json()).toEqual({
      error: 'invalid_fields',
      fields: ['perceived_fatigue', 'notes'],
    });
    const unchangedSession = await env.DB
      .prepare('SELECT perceived_fatigue, notes FROM sessions WHERE id = ?1')
      .bind(session.id)
      .first<{ perceived_fatigue: number | null; notes: string | null }>();
    expect(unchangedSession).toEqual({ perceived_fatigue: null, notes: null });

    const malformedSetId = crypto.randomUUID();
    const malformedSet = await SELF.fetch(`${BASE}/api/sessions/${session.id}/sets`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        id: malformedSetId,
        exercise_id: 'ex_bench',
        set_index: 1,
        weight: 'heavy',
        reps: 5.5,
        logged_at: Date.now() + 0.5,
      }),
    });
    expect(malformedSet.status).toBe(400);
    expect(await malformedSet.json()).toEqual({
      error: 'invalid_fields',
      fields: ['weight', 'reps', 'logged_at'],
    });
    expect(
      await env.DB.prepare('SELECT id FROM set_logs WHERE id = ?1').bind(malformedSetId).first(),
    ).toBeNull();

    // Number.isInteger(1e100) is true, but SQLite stores that magnitude as
    // REAL even in INTEGER-affinity columns. Reject it before it can break
    // Swift's Int decoding of the entire /api/state set delta.
    const oversizedSetId = crypto.randomUUID();
    const oversizedSet = await SELF.fetch(`${BASE}/api/sessions/${session.id}/sets`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        id: oversizedSetId,
        exercise_id: 'ex_bench',
        set_index: 1e100,
        weight: 225,
        reps: 1e100,
        logged_at: 1e100,
        duration_s: 1e100,
      }),
    });
    expect(oversizedSet.status).toBe(400);
    expect(await oversizedSet.json()).toEqual({
      error: 'invalid_fields',
      fields: ['set_index', 'reps', 'logged_at', 'duration_s'],
    });
    expect(
      await env.DB.prepare('SELECT id FROM set_logs WHERE id = ?1').bind(oversizedSetId).first(),
    ).toBeNull();

    const validSetId = crypto.randomUUID();
    const validSet = await SELF.fetch(`${BASE}/api/sessions/${session.id}/sets`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        id: validSetId,
        exercise_id: 'ex_bench',
        set_index: 1,
        weight: 225,
        reps: 5,
      }),
    });
    expect(validSet.status).toBe(201);

    const badSetPatch = await SELF.fetch(`${BASE}/api/sets/${validSetId}`, {
      method: 'PATCH',
      headers,
      body: JSON.stringify({ weight: 'still heavy', reps: 3.5 }),
    });
    expect(badSetPatch.status).toBe(400);
    expect(await badSetPatch.json()).toEqual({
      error: 'invalid_fields',
      fields: ['weight', 'reps'],
    });
    const unchangedSet = await env.DB
      .prepare('SELECT weight, reps FROM set_logs WHERE id = ?1')
      .bind(validSetId)
      .first<{ weight: number; reps: number }>();
    expect(unchangedSet).toEqual({ weight: 225, reps: 5 });

    const stateResponse = await SELF.fetch(`${BASE}/api/state?since=0&sets_since=0`, {
      headers,
    });
    expect(stateResponse.status).toBe(200);
    const state = await stateResponse.json<{
      sets: Array<{
        id: string;
        set_index: unknown;
        weight: unknown;
        reps: unknown;
        logged_at: unknown;
      }>;
    }>();
    expect(state.sets.some((set) => set.id === malformedSetId)).toBe(false);
    expect(state.sets.some((set) => set.id === oversizedSetId)).toBe(false);
    const returned = state.sets.find((set) => set.id === validSetId);
    expect(returned).toBeDefined();
    expect(Number.isInteger(returned?.set_index)).toBe(true);
    expect(typeof returned?.weight).toBe('number');
    expect(Number.isInteger(returned?.reps)).toBe(true);
    expect(Number.isInteger(returned?.logged_at)).toBe(true);
  });
});
