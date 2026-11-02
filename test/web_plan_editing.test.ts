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

describe('supersets and circuits from the web', () => {
  type GroupSlot = Slot & { group_id: string | null; target_sets: number; group_rest_seconds: number | null; group_transition_seconds: number | null };
  const slotsOf = async (workout: string) => (await env.DB.prepare(
    `SELECT id, order_index, group_id, target_sets, group_rest_seconds, group_transition_seconds
       FROM template_exercises WHERE workout_id=?1 ORDER BY order_index`,
  ).bind(workout).all<GroupSlot>()).results;

  it('groups, reorders members, moves the block past a gap and ungroups, all as the web', async () => {
    const web = await devJwt('web');
    const plan = await activePlan(web);
    const workout = (await call<{ id: string }>(web, 'POST', '/api/workouts', {
      name: 'Circuits', expected_plan_id: plan.id, expected_version: plan.version,
    })).body.id;
    const ids: string[] = [];
    for (const exercise of ['Bench Press', 'Back Squat', 'Deadlift', 'Overhead Press', 'Pull-Up']) {
      const slot = await call<Slot>(web, 'POST', `/api/workouts/${workout}/exercises`, {
        exercise, target_sets: 3, target_reps: 5, rest_seconds: 120, expected_version: await version(web),
      });
      expect(slot.status).toBe(201);
      ids.push(slot.body.id);
    }
    const group = crypto.randomUUID();
    const put = (body: Record<string, unknown>) => call<{ ok?: boolean; conflict?: boolean }>(
      web, 'PUT', `/api/workouts/${workout}/groups`, { group_id: group, ...body },
    );

    // A superset of the third and fourth exercises.
    const made = await put({
      exercises: [ids[2], ids[3]], target_sets: 4, round_rest: 90, transition_rest: 15,
      expected_version: await version(web),
    });
    expect(made.status).toBe(200);
    // Swap its members; rounds and rests are resent unchanged.
    expect((await put({
      exercises: [ids[3], ids[2]], target_sets: 4, round_rest: 90, transition_rest: 15,
      expected_version: await version(web),
    })).status).toBe(200);
    expect((await slotsOf(workout)).map((slot) => slot.id)).toEqual([ids[0], ids[1], ids[3], ids[2], ids[4]]);

    // Removing the first exercise leaves a gap; the group then moves up past
    // the second one: no other exercise before it.
    expect((await call(web, 'DELETE',
      `/api/workouts/${workout}/exercises/${ids[0]}?expected_version=${await version(web)}`)).status).toBe(200);
    expect((await put({
      exercises: [ids[3], ids[2]], target_sets: 4, round_rest: 90, transition_rest: 15, order_index: 0,
      expected_version: await version(web),
    })).status).toBe(200);
    expect(await slotsOf(workout)).toEqual([
      { id: ids[3], order_index: 0, group_id: group, target_sets: 4, group_rest_seconds: 90, group_transition_seconds: 15 },
      { id: ids[2], order_index: 1, group_id: group, target_sets: 4, group_rest_seconds: 90, group_transition_seconds: 15 },
      { id: ids[1], order_index: 2, group_id: null, target_sets: 3, group_rest_seconds: null, group_transition_seconds: null },
      { id: ids[4], order_index: 3, group_id: null, target_sets: 3, group_rest_seconds: null, group_transition_seconds: null },
    ]);

    // A stale version changes nothing.
    const stale = await put({ exercises: [], expected_version: plan.version });
    expect(stale.status).toBe(409);
    expect(stale.body).toEqual({ conflict: true, current_version: await version(web) });

    expect((await put({ exercises: [], expected_version: await version(web) })).status).toBe(200);
    expect((await slotsOf(workout)).every((slot) => slot.group_id === null)).toBe(true);

    const audits = await env.DB.prepare(
      `SELECT tool, actor FROM audit_log WHERE tool IN ('group_exercises','ungroup_exercises')
        AND json_extract(args,'$.group_id')=?1 ORDER BY created_at, rowid`,
    ).bind(group).all<{ tool: string; actor: string }>();
    expect(audits.results).toEqual([
      { tool: 'group_exercises', actor: 'web' },
      { tool: 'group_exercises', actor: 'web' },
      { tool: 'group_exercises', actor: 'web' },
      { tool: 'ungroup_exercises', actor: 'web' },
    ]);
  });
});

describe('the routine, single dates and away dates from the web', () => {
  it('records the web as the actor on schedule, date and away-date writes', async () => {
    const web = await devJwt('web');
    const plan = await activePlan(web);
    const workout = (await call<{ id: string }>(web, 'POST', '/api/workouts', {
      name: 'Routine', expected_plan_id: plan.id, expected_version: plan.version,
    })).body.id;
    const week = { mon: workout, tue: null, wed: null, thu: null, fri: null, sat: null, sun: null };
    const schedule = await call(web, 'PUT', '/api/plan/schedule', {
      week, expected_plan_id: plan.id, expected_version: await version(web),
    });
    expect(schedule.status).toBe(200);

    const trip = await call<{ ok: boolean }>(web, 'POST', '/api/plan/trips', {
      start: '2031-03-01', end: '2031-03-05', type: 'travel', can_train_light: true, expected_version: await version(web),
    });
    expect(trip.status).toBe(200);
    const trips = (await call<{ plan: { trips: { id: string }[] } }>(web, 'GET', '/api/state')).body.plan.trips;
    const tripId = trips[trips.length - 1]!.id;
    expect((await call(web, 'PATCH', `/api/plan/trips/${tripId}`, {
      can_train_light: false, expected_version: await version(web),
    })).status).toBe(200);
    expect((await call(web, 'DELETE', `/api/plan/trips/${tripId}?expected_version=${await version(web)}`)).status).toBe(200);

    const assigned = await call<{ session: { attempt: number } }>(web, 'PUT', '/api/calendar/2031-04-02', {
      workout_id: workout, expected_attempt: 0,
    });
    expect(assigned.status).toBe(200);
    const moved = await call(web, 'POST', '/api/calendar/2031-04-02/move', {
      id: crypto.randomUUID(), to_date: '2031-04-04', today: '2031-04-01', workout_id: workout,
      expected_plan_id: plan.id, expected_version: await version(web),
      expected_from_attempt: assigned.body.session.attempt, expected_to_attempt: 0,
    });
    expect(moved.status).toBe(200);
    // The page's view of a date is stale once another device changed it.
    const stale = await call<{ error: string }>(web, 'PUT', '/api/calendar/2031-04-04', { workout_id: null, expected_attempt: 0 });
    expect(stale.status).toBe(409);
    expect(stale.body.error).toBe('session_attempt_conflict');

    const audits = await env.DB.prepare(
      `SELECT tool, actor FROM audit_log
        WHERE tool IN ('set_schedule','add_trip','update_trip','remove_trip','set_planned_session','move_calendar_workout')
          AND user_id = (SELECT user_id FROM plans WHERE id=?1)
        ORDER BY created_at, rowid`,
    ).bind(plan.id).all<{ tool: string; actor: string }>();
    expect(audits.results.map((row) => row.actor)).toEqual(audits.results.map(() => 'web'));
    expect(audits.results.map((row) => row.tool)).toEqual(expect.arrayContaining([
      'set_schedule', 'add_trip', 'update_trip', 'remove_trip', 'set_planned_session', 'move_calendar_workout',
    ]));
  });
});

describe('restoring a plan version from the web', () => {
  it('compares, restores as a new web version, and refuses a version it did not review', async () => {
    const web = await devJwt('web');
    const plan = await activePlan(web);
    const workout = (await call<{ id: string }>(web, 'POST', '/api/workouts', {
      name: 'Restore me', expected_plan_id: plan.id, expected_version: plan.version,
    })).body.id;
    const saved = await version(web);
    expect((await call(web, 'PATCH', `/api/workouts/${workout}`, {
      name: 'Renamed', expected_version: saved,
    })).status).toBe(200);
    const current = await version(web);

    const history = await call<{ plan_id: string; current_version: number; items: { version: number; actor: string }[] }>(
      web, 'GET', '/api/plan/history?limit=5');
    expect(history.status).toBe(200);
    expect(history.body.current_version).toBe(current);
    expect(history.body.items[0]).toMatchObject({ version: current, actor: 'web' });
    const comparison = await call<{ from_version: number; to_version: number; changes: { kind: string }[] }>(
      web, 'GET', `/api/plan/history/${saved}/compare?to_version=${current}`);
    expect(comparison.body).toMatchObject({ from_version: saved, to_version: current });
    expect(comparison.body.changes.map((change) => change.kind)).toContain('day');

    // A version the page didn't compare against is refused, not overwritten.
    const stale = await call<{ conflict: boolean }>(web, 'POST', `/api/plan/history/${saved}/restore`, {
      expected_plan_id: plan.id, expected_version: saved, reason: 'Restored from the web plan history',
    });
    expect(stale.status).toBe(409);
    expect(stale.body.conflict).toBe(true);

    const restored = await call<{ version: number; restored_from_version: number }>(web, 'POST', `/api/plan/history/${saved}/restore`, {
      expected_plan_id: plan.id, expected_version: current, reason: 'Restored from the web plan history',
    });
    expect(restored.status).toBe(200);
    expect(restored.body).toMatchObject({ restored_from_version: saved, version: current + 1 });
    const state = await call<{ plan: { workouts: { id: string; name: string }[] } }>(web, 'GET', '/api/state');
    expect(state.body.plan.workouts.find((w) => w.id === workout)?.name).toBe('Restore me');
    const snapshot = await env.DB.prepare(
      'SELECT actor, operation, reason FROM plan_snapshots WHERE plan_id=?1 AND version=?2',
    ).bind(plan.id, current + 1).first<{ actor: string; operation: string; reason: string }>();
    expect(snapshot).toEqual({ actor: 'web', operation: 'restore_plan', reason: 'Restored from the web plan history' });
  });
});
