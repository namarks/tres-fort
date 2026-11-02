import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { decode } from 'hono/jwt';
import { beforeAll, describe, expect, it } from 'vitest';

// Plan editing from the web app (docs/plans/web-app P2). The web signs in with
// a token that carries `client: 'web'`, and the same REST writers then record
// the web, not the iOS app, as the actor on audit rows and plan versions.

const BASE = 'https://tres-fort.test';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

async function devJwt(client?: 'web'): Promise<string> {
  const response = await SELF.fetch(`${BASE}/auth/dev`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ secret: 'test-dev', ...(client ? { client } : {}) }),
  });
  expect(response.status).toBe(200);
  return (await response.json<{ jwt: string }>()).jwt;
}

const headers = (jwt: string) => ({ 'content-type': 'application/json', Authorization: `Bearer ${jwt}` });

async function call<T>(jwt: string, method: string, path: string, body?: unknown): Promise<{ status: number; body: T }> {
  const response = await SELF.fetch(`${BASE}${path}`, {
    method, headers: headers(jwt), ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  return { status: response.status, body: await response.json<T>() };
}

type Plan = { id: string; version: number };
type Slot = { id: string; exercise_id: string; order_index: number };

async function activePlan(jwt: string): Promise<Plan> {
  return (await call<{ plan: Plan }>(jwt, 'PUT', '/api/plan/active', { name: 'My Training' })).body.plan;
}

async function version(jwt: string): Promise<number> {
  return (await call<{ plan_version: number }>(jwt, 'GET', '/api/state')).body.plan_version;
}

describe('web sign-in attribution', () => {
  it('marks only web tokens, and renewal keeps the mark', async () => {
    const web = await devJwt('web');
    const app = await devJwt();
    expect(decode(web).payload.client).toBe('web');
    expect(decode(app).payload.client).toBeUndefined();

    const renewed = await SELF.fetch(`${BASE}/auth/renew`, { method: 'POST', headers: headers(web) });
    expect(renewed.status).toBe(200);
    expect(decode((await renewed.json<{ jwt: string }>()).jwt).payload.client).toBe('web');
  });

  it('records the web as the actor on workout and slot edits, and the app otherwise', async () => {
    const web = await devJwt('web');
    const plan = await activePlan(web);
    const workout = await call<{ id: string }>(web, 'POST', '/api/workouts', {
      name: 'Upper', expected_plan_id: plan.id, expected_version: plan.version,
    });
    expect(workout.status).toBe(201);
    const slot = await call<Slot>(web, 'POST', `/api/workouts/${workout.body.id}/exercises`, {
      exercise: 'Bench Press', target_sets: 3, target_reps: 5, target_weight: 60,
      target_weight_unit: 'kg', expected_version: await version(web),
    });
    expect(slot.status).toBe(201);
    const edited = await call<Slot>(web, 'PATCH', `/api/workouts/${workout.body.id}/exercises/${slot.body.id}`, {
      target_reps: 6, expected_version: await version(web),
    });
    expect(edited.status).toBe(200);

    const app = await devJwt();
    const renamed = await call(app, 'PATCH', `/api/workouts/${workout.body.id}`, {
      name: 'Upper A', expected_version: await version(app),
    });
    expect(renamed.status).toBe(200);

    const audits = await env.DB.prepare(
      `SELECT tool, actor FROM audit_log
        WHERE tool IN ('add_workout','add_exercise','update_exercise','update_workout')
        ORDER BY created_at, rowid`,
    ).all<{ tool: string; actor: string }>();
    expect(audits.results).toEqual([
      { tool: 'add_workout', actor: 'web' },
      { tool: 'add_exercise', actor: 'web' },
      { tool: 'update_exercise', actor: 'web' },
      { tool: 'update_workout', actor: 'ios' },
    ]);
    const versions = await env.DB.prepare(
      `SELECT operation, actor FROM plan_snapshots
        WHERE operation IN ('add_workout','add_exercise','update_exercise','update_workout')
        ORDER BY version`,
    ).all<{ operation: string; actor: string }>();
    expect(versions.results).toEqual([
      { operation: 'add_workout', actor: 'web' },
      { operation: 'add_exercise', actor: 'web' },
      { operation: 'update_exercise', actor: 'web' },
      { operation: 'update_workout', actor: 'ios' },
    ]);
  });

  it('answers a stale web edit with a conflict and changes nothing', async () => {
    const web = await devJwt('web');
    const plan = await activePlan(web);
    const workout = await call<{ id: string }>(web, 'POST', '/api/workouts', {
      name: 'Lower', expected_plan_id: plan.id, expected_version: plan.version,
    });
    const stale = plan.version;
    const response = await call<{ conflict: boolean; current_version: number }>(
      web, 'POST', `/api/workouts/${workout.body.id}/exercises`,
      { exercise: 'Back Squat', target_sets: 3, target_reps: 5, expected_version: stale },
    );
    expect(response.status).toBe(409);
    expect(response.body).toEqual({ conflict: true, current_version: await version(web) });
  });
});

describe('moving a slot after another was removed', () => {
  it('treats order_index as the destination position even when indexes have gaps', async () => {
    const web = await devJwt('web');
    const plan = await activePlan(web);
    const workout = (await call<{ id: string }>(web, 'POST', '/api/workouts', {
      name: 'Gaps', expected_plan_id: plan.id, expected_version: plan.version,
    })).body.id;
    const ids: string[] = [];
    for (const exercise of ['Bench Press', 'Back Squat', 'Deadlift', 'Overhead Press']) {
      const slot = await call<Slot>(web, 'POST', `/api/workouts/${workout}/exercises`, {
        exercise, target_sets: 3, target_reps: 5, expected_version: await version(web),
      });
      expect(slot.status).toBe(201);
      ids.push(slot.body.id);
    }
    // Removing the second slot leaves indexes 0, 2, 3.
    const removed = await call(web, 'DELETE',
      `/api/workouts/${workout}/exercises/${ids[1]}?expected_version=${await version(web)}`);
    expect(removed.status).toBe(200);

    // Move the first slot down one place: it belongs after the old third slot.
    const moved = await call<Slot>(web, 'PATCH', `/api/workouts/${workout}/exercises/${ids[0]}`, {
      order_index: 1, expected_version: await version(web),
    });
    expect(moved.status).toBe(200);
    expect(moved.body.order_index).toBe(1);
    const order = await env.DB.prepare(
      'SELECT id, order_index FROM template_exercises WHERE workout_id=?1 ORDER BY order_index',
    ).bind(workout).all<{ id: string; order_index: number }>();
    expect(order.results).toEqual([
      { id: ids[2], order_index: 0 },
      { id: ids[0], order_index: 1 },
      { id: ids[3], order_index: 2 },
    ]);
  });
});
