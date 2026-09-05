import { applyD1Migrations, env, SELF } from 'cloudflare:test';
import { afterEach, beforeAll, describe, expect, it, vi } from 'vitest';

import {
  createPlan,
  deleteTemplateExercise,
  discardSession,
  ensureActivePlan,
  getOrCreateSession,
  getState,
  listActivitiesForUser,
  logActivity,
  logSet,
  patchSet,
  softDeleteActivity,
  updatePlanTree,
} from '../src/db';
import { issueAppJwt } from '../src/auth';

const BASE = 'https://tres-fort.test';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

afterEach(() => {
  vi.useRealTimers();
});

async function createUser(label: string): Promise<string> {
  const userId = crypto.randomUUID();
  await env.DB.prepare(
    `INSERT INTO users (id,apple_sub,display_name,created_at)
     VALUES (?1,?2,?3,?4)`,
  )
    .bind(userId, `sub-${userId}`, label, Date.now())
    .run();
  return userId;
}

async function createWorkout(label: string) {
  const userId = await createUser(label);
  await createPlan(env.DB, userId, `${label} plan`);
  const built = await updatePlanTree(env.DB, userId, {
    name: `${label} plan`,
    days: [
      {
        day_label: 'A',
        name: `${label} day`,
        exercises: [{ exercise: 'bench', target_sets: 3, target_reps: 5 }],
      },
    ],
  });
  if (!('plan' in built)) throw new Error('expected_p1_plan');
  return {
    userId,
    planId: built.plan.id,
    version: built.plan.version,
    dayId: built.plan.days[0]!.id,
    slotId: built.plan.days[0]!.exercises[0]!.id,
  };
}

async function createLoggedSet(
  workout: Awaited<ReturnType<typeof createWorkout>>,
  date: string,
  loggedAt: number,
) {
  const session = await getOrCreateSession(
    env.DB,
    workout.userId,
    workout.planId,
    date,
    workout.dayId,
  );
  const result = await logSet(env.DB, workout.userId, {
    id: crypto.randomUUID(),
    session_id: session.id,
    exercise_id: 'ex_bench',
    template_exercise_id: workout.slotId,
    set_index: 1,
    weight: 135,
    reps: 5,
    logged_at: loggedAt,
    source: 'ios',
  });
  return { session: result.session, set: result.set };
}

describe('P1 set/session delta cursors', () => {
  it('exposes monotonic updated_at in REST set acknowledgments and the delta tombstone', async () => {
    const insertedAt = Date.parse('2034-12-01T00:00:00Z');
    vi.setSystemTime(insertedAt);
    const workout = await createWorkout('P1 REST ACK');
    const session = await getOrCreateSession(
      env.DB,
      workout.userId,
      workout.planId,
      '2034-12-01',
      workout.dayId,
    );
    const jwt = await issueAppJwt(workout.userId, 'test-secret');
    const headers = {
      'content-type': 'application/json',
      Authorization: `Bearer ${jwt}`,
    };
    const setId = crypto.randomUUID();
    const createdResponse = await SELF.fetch(`${BASE}/api/sessions/${session.id}/sets`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        id: setId,
        exercise_id: 'ex_bench',
        template_exercise_id: workout.slotId,
        set_index: 1,
        weight: 135,
        reps: 5,
        logged_at: 1,
      }),
    });
    expect(createdResponse.status).toBe(201);
    const created = await createdResponse.json<{ set: { updated_at: number } }>();
    expect(created.set.updated_at).toBe(insertedAt);

    const correctedAt = insertedAt + 120_000;
    vi.setSystemTime(correctedAt);
    const correctedResponse = await SELF.fetch(`${BASE}/api/sets/${setId}`, {
      method: 'PATCH',
      headers,
      body: JSON.stringify({ reps: 6 }),
    });
    expect(correctedResponse.status).toBe(200);
    const corrected = await correctedResponse.json<{
      updated_at: number;
      deleted_at: number | null;
    }>();
    expect(corrected).toMatchObject({ updated_at: correctedAt, deleted_at: null });
    expect(corrected.updated_at).toBeGreaterThan(created.set.updated_at);

    const deletedAt = correctedAt + 120_000;
    vi.setSystemTime(deletedAt);
    const deletedResponse = await SELF.fetch(`${BASE}/api/sets/${setId}`, {
      method: 'PATCH',
      headers,
      body: JSON.stringify({ deleted: true }),
    });
    expect(deletedResponse.status).toBe(200);
    const deleted = await deletedResponse.json<{
      updated_at: number;
      deleted_at: number | null;
    }>();
    expect(deleted).toMatchObject({ updated_at: deletedAt, deleted_at: deletedAt });
    expect(deleted.updated_at).toBeGreaterThan(corrected.updated_at);

    const deltaResponse = await SELF.fetch(
      `${BASE}/api/state?since=${workout.version}&sets_since=${corrected.updated_at}`,
      { headers },
    );
    expect(deltaResponse.status).toBe(200);
    const delta = await deltaResponse.json<{
      sets: Array<{ id: string; updated_at: number; deleted_at: number | null }>;
    }>();
    expect(delta.sets).toEqual([
      expect.objectContaining({ id: setId, updated_at: deletedAt, deleted_at: deletedAt }),
    ]);
  });

  it('uses authenticated ownership and server time for inserts, corrections, and tombstones', async () => {
    const insertedAt = Date.parse('2035-01-01T00:00:00Z');
    vi.setSystemTime(insertedAt);
    const workoutA = await createWorkout('P1 member A');
    const workoutB = await createWorkout('P1 member B');
    const a = await createLoggedSet(workoutA, '2035-01-01', 123);
    const b = await createLoggedSet(workoutB, '2035-01-01', insertedAt + 86_400_000);

    expect(a.set).toMatchObject({
      user_id: workoutA.userId,
      logged_at: 123,
      updated_at: insertedAt,
      deleted_at: null,
    });
    expect(b.set.updated_at).toBe(insertedAt);

    const full = await getState(env.DB, workoutA.userId, 0, 0);
    expect(full.sets.map((set) => set.id)).toContain(a.set.id);
    expect(full.sets.map((set) => set.id)).not.toContain(b.set.id);

    const correctedAt = insertedAt + 120_000;
    vi.setSystemTime(correctedAt);
    const corrected = await patchSet(env.DB, workoutA.userId, a.set.id, { reps: 6 });
    expect(corrected).toMatchObject({ reps: 6, updated_at: correctedAt, deleted_at: null });

    const deletedAt = correctedAt + 120_000;
    vi.setSystemTime(deletedAt);
    const deleted = await patchSet(env.DB, workoutA.userId, a.set.id, { deleted: true });
    expect(deleted).toMatchObject({ updated_at: deletedAt, deleted_at: deletedAt });

    const delta = await getState(env.DB, workoutA.userId, 0, correctedAt);
    expect(delta.sets).toHaveLength(1);
    expect(delta.sets[0]).toMatchObject({
      id: a.set.id,
      user_id: workoutA.userId,
      updated_at: deletedAt,
      deleted_at: deletedAt,
    });

    const plan = await env.DB.prepare(
      `EXPLAIN QUERY PLAN
       SELECT * FROM set_logs
        WHERE user_id = ?1 AND updated_at > ?2
        ORDER BY updated_at, id`,
    )
      .bind(workoutA.userId, correctedAt)
      .all<{ detail: string }>();
    expect(plan.results.some((row) => row.detail.includes('ix_sets_user_updated'))).toBe(true);

    const sessionPlan = await env.DB.prepare(
      `EXPLAIN QUERY PLAN
       SELECT * FROM sessions
        WHERE user_id = ?1 AND updated_at > ?2
        ORDER BY date`,
    )
      .bind(workoutA.userId, deletedAt)
      .all<{ detail: string }>();
    expect(sessionPlan.results.some((row) => row.detail.includes('ix_sessions_user_updated')))
      .toBe(true);
    const emptySets = await env.DB.prepare(
      `SELECT * FROM set_logs
        WHERE user_id = ?1 AND updated_at > ?2
        ORDER BY updated_at, id`,
    )
      .bind(workoutA.userId, deletedAt)
      .all();
    const emptySessions = await env.DB.prepare(
      `SELECT * FROM sessions
        WHERE user_id = ?1 AND updated_at > ?2
        ORDER BY date`,
    )
      .bind(workoutA.userId, deletedAt)
      .all();
    expect(emptySets.results).toEqual([]);
    // D1 charges the bounded index seek itself (currently two rows) even when
    // the range is empty; the query plan above proves it does not scan members.
    expect(emptySets.meta.rows_read).toBeLessThanOrEqual(2);
    expect(emptySessions.results).toEqual([]);
    expect(emptySessions.meta.rows_read).toBeLessThanOrEqual(2);
  });

  it('stamps every set tombstone created by session discard', async () => {
    const insertedAt = Date.parse('2035-02-01T00:00:00Z');
    vi.setSystemTime(insertedAt);
    const workout = await createWorkout('P1 discard');
    const first = await createLoggedSet(workout, '2035-02-01', 10);
    const second = await logSet(env.DB, workout.userId, {
      id: crypto.randomUUID(),
      session_id: first.session.id,
      exercise_id: 'ex_bench',
      template_exercise_id: workout.slotId,
      set_index: 2,
      weight: 135,
      reps: 5,
      logged_at: 20,
      source: 'ios',
    });

    const discardedAt = insertedAt + 120_000;
    vi.setSystemTime(discardedAt);
    await discardSession(env.DB, workout.userId, first.session.id, 0);

    const delta = await getState(env.DB, workout.userId, 0, insertedAt);
    const tombstones = delta.sets.filter(
      (set) => set.id === first.set.id || set.id === second.set.id,
    );
    expect(tombstones).toHaveLength(2);
    expect(tombstones.every((set) => set.deleted_at === discardedAt)).toBe(true);
    expect(tombstones.every((set) => set.updated_at === discardedAt)).toBe(true);
  });

  it('redelivers plan-rebuilt session and slot remaps, then slot detachment', async () => {
    const insertedAt = Date.parse('2035-03-01T00:00:00Z');
    vi.setSystemTime(insertedAt);
    const workout = await createWorkout('P1 remap');
    const logged = await createLoggedSet(workout, '2035-03-01', 10);

    const remappedAt = insertedAt + 120_000;
    vi.setSystemTime(remappedAt);
    const rebuilt = await updatePlanTree(env.DB, workout.userId, {
      name: 'P1 remap plan v2',
      expected_version: workout.version,
      days: [
        {
          day_label: 'A',
          name: 'P1 remap day',
          exercises: [{ exercise: 'bench', target_sets: 4, target_reps: 6 }],
        },
      ],
    });
    if (!('plan' in rebuilt)) throw new Error('expected_rebuilt_p1_plan');
    const newDayId = rebuilt.plan.days[0]!.id;
    const newSlotId = rebuilt.plan.days[0]!.exercises[0]!.id;
    expect(newDayId).not.toBe(workout.dayId);
    expect(newSlotId).not.toBe(workout.slotId);

    const remapDelta = await getState(env.DB, workout.userId, rebuilt.plan.version, insertedAt);
    expect(remapDelta.sessions).toEqual([
      expect.objectContaining({
        id: logged.session.id,
        day_template_id: newDayId,
        updated_at: remappedAt,
      }),
    ]);
    expect(remapDelta.sets).toEqual([
      expect.objectContaining({
        id: logged.set.id,
        template_exercise_id: newSlotId,
        updated_at: remappedAt,
      }),
    ]);

    const detachedAt = remappedAt + 120_000;
    vi.setSystemTime(detachedAt);
    await deleteTemplateExercise(env.DB, workout.userId, { template_exercise_id: newSlotId });
    const detachDelta = await getState(env.DB, workout.userId, rebuilt.plan.version, remappedAt);
    expect(detachDelta.sets).toEqual([
      expect.objectContaining({
        id: logged.set.id,
        template_exercise_id: null,
        updated_at: detachedAt,
      }),
    ]);
  });

  it('captures server_time before reads so an interleaved write lands after the watermark', async () => {
    const insertedAt = Date.parse('2035-04-01T00:00:00Z');
    vi.setSystemTime(insertedAt);
    const workout = await createWorkout('P1 watermark');
    const logged = await createLoggedSet(workout, '2035-04-01', 10);

    const requestStartedAt = insertedAt + 120_000;
    const interleavedAt = requestStartedAt + 5_000;
    vi.setSystemTime(requestStartedAt);
    let intercepted = false;
    const db = new Proxy(env.DB, {
      get(target, property) {
        if (property !== 'prepare') {
          const value = Reflect.get(target, property, target);
          return typeof value === 'function' ? value.bind(target) : value;
        }
        return (query: string) => {
          if (!query.includes('FROM set_logs') || !query.includes('updated_at >')) {
            return target.prepare(query);
          }
          const wrapStatement = (statement: D1PreparedStatement): D1PreparedStatement =>
            new Proxy(statement, {
              get(statementTarget, statementProperty) {
                if (statementProperty === 'bind') {
                  return (...values: unknown[]) =>
                    wrapStatement(statementTarget.bind(...values));
                }
                if (statementProperty !== 'all') {
                  const value = Reflect.get(statementTarget, statementProperty, statementTarget);
                  return typeof value === 'function' ? value.bind(statementTarget) : value;
                }
                return async <T = unknown>() => {
                  const result = await statementTarget.all<T>();
                  if (!intercepted) {
                    intercepted = true;
                    vi.setSystemTime(interleavedAt);
                    await patchSet(env.DB, workout.userId, logged.set.id, {
                      notes: 'committed after set collection read',
                    });
                  }
                  return result;
                };
              },
            });
          return wrapStatement(target.prepare(query));
        };
      },
    });

    const first = await getState(db, workout.userId, workout.version, insertedAt);
    expect(intercepted).toBe(true);
    expect(first.server_time).toBe(requestStartedAt);
    expect(first.sets).toEqual([]);

    const stored = await env.DB.prepare('SELECT updated_at FROM set_logs WHERE id=?1')
      .bind(logged.set.id)
      .first<{ updated_at: number }>();
    expect(stored!.updated_at).toBe(interleavedAt);
    expect(stored!.updated_at).toBeGreaterThan(first.server_time);

    const next = await getState(env.DB, workout.userId, workout.version, first.server_time);
    expect(next.sets).toEqual([
      expect.objectContaining({ id: logged.set.id, updated_at: interleavedAt }),
    ]);
  });
});

describe('P1 monotonic plan replacement cursor', () => {
  async function fetchPlanDelta(userId: string, since: number) {
    const jwt = await issueAppJwt(userId, 'test-secret');
    const response = await SELF.fetch(`${BASE}/api/state?since=${since}&sets_since=0`, {
      headers: { Authorization: `Bearer ${jwt}` },
    });
    expect(response.status).toBe(200);
    return response.json<{ plan: { id: string; version: number } | null }>();
  }

  it('delivers lower-version and equal-version replacements through /api/state', async () => {
    const lowerUser = await createUser('P1 lower replacement');
    const oldHigher = await createPlan(env.DB, lowerUser, 'Old v10');
    await env.DB.prepare('UPDATE plans SET version=10 WHERE id=?1')
      .bind(oldHigher.id)
      .run();
    const higherReplacement = await createPlan(env.DB, lowerUser, 'Replacement v11');
    expect(higherReplacement.version).toBe(11);
    expect(await fetchPlanDelta(lowerUser, 10)).toMatchObject({
      plan: { id: higherReplacement.id, version: 11 },
    });

    const equalUser = await createUser('P1 equal replacement');
    const oldOne = await createPlan(env.DB, equalUser, 'Old v1');
    expect(oldOne.version).toBe(1);
    const equalReplacement = await createPlan(env.DB, equalUser, 'Replacement v2');
    expect(equalReplacement.version).toBe(2);
    expect(await fetchPlanDelta(equalUser, 1)).toMatchObject({
      plan: { id: equalReplacement.id, version: 2 },
    });
  });

  it('continues the cursor after archived history and serializes replacements', async () => {
    const ensureUser = await createUser('P1 archived ensure');
    const archived = await createPlan(env.DB, ensureUser, 'Archived v1');
    await env.DB.prepare("UPDATE plans SET status='archived' WHERE id=?1")
      .bind(archived.id)
      .run();
    const ensured = await ensureActivePlan(env.DB, ensureUser, 'Ensured v2');
    expect(ensured).toMatchObject({ created: true, plan: { version: 2 } });
    expect(await fetchPlanDelta(ensureUser, 1)).toMatchObject({
      plan: { id: ensured.plan.id, version: 2 },
    });

    const concurrentUser = await createUser('P1 concurrent replacement');
    expect((await createPlan(env.DB, concurrentUser, 'Initial')).version).toBe(1);
    const replacements = await Promise.all([
      createPlan(env.DB, concurrentUser, 'Concurrent A'),
      createPlan(env.DB, concurrentUser, 'Concurrent B'),
    ]);
    expect(replacements.map((plan) => plan.version).sort((a, b) => a - b)).toEqual([2, 3]);
    const active = await env.DB.prepare(
      "SELECT id,version FROM plans WHERE user_id=?1 AND status='active'",
    )
      .bind(concurrentUser)
      .first<{ id: string; version: number }>();
    expect(active?.version).toBe(3);
    expect(replacements.map((plan) => plan.id)).toContain(active?.id);
  });
});

describe('P1 manual-activity delta cursor', () => {
  it('delivers a same-millisecond soft-delete as a strictly newer tombstone', async () => {
    const sameMs = Date.parse('2035-04-15T00:00:00Z');
    vi.setSystemTime(sameMs);
    const userId = await createUser('P1 same-ms activity delete');
    const activity = await logActivity(
      env.DB,
      userId,
      {
        id: crypto.randomUUID(),
        date: '2035-04-15',
        type: 'walk',
        logged_at: 1,
      },
      'ios',
    );
    expect(activity.updated_at).toBe(sameMs);
    expect(await softDeleteActivity(env.DB, userId, activity.id)).toBe(true);

    const jwt = await issueAppJwt(userId, 'test-secret');
    const response = await SELF.fetch(
      `${BASE}/api/state?log_since=${activity.updated_at}`,
      { headers: { Authorization: `Bearer ${jwt}` } },
    );
    expect(response.status).toBe(200);
    const delta = await response.json<{
      activities: Array<{ id: string; deleted_at: number; updated_at: number }>;
    }>();
    expect(delta.activities).toEqual([
      expect.objectContaining({
        id: activity.id,
        deleted_at: sameMs,
        updated_at: sameMs + 1,
      }),
    ]);
  });

  it('uses server time for skewed events, returns tombstones, and does not cap the delta at 1000', async () => {
    const serverInsertAt = Date.parse('2035-05-01T00:00:00Z');
    vi.setSystemTime(serverInsertAt);
    const userId = await createUser('P1 activities');
    const backdated = await logActivity(
      env.DB,
      userId,
      {
        id: crypto.randomUUID(),
        date: '2020-01-01',
        type: 'walk',
        logged_at: 1,
      },
      'ios',
    );
    const future = await logActivity(
      env.DB,
      userId,
      {
        id: crypto.randomUUID(),
        date: '2099-01-01',
        type: 'yoga',
        logged_at: Date.parse('2099-01-01T00:00:00Z'),
      },
      'ios',
    );
    expect(backdated.updated_at).toBe(serverInsertAt);
    expect(future.updated_at).toBe(serverInsertAt);

    const first = await listActivitiesForUser(env.DB, userId, serverInsertAt - 60_000);
    expect(first.map((activity) => activity.id).sort()).toEqual(
      [backdated.id, future.id].sort(),
    );

    const deletedAt = serverInsertAt + 120_000;
    vi.setSystemTime(deletedAt);
    expect(await softDeleteActivity(env.DB, userId, backdated.id)).toBe(true);
    const tombstones = await listActivitiesForUser(env.DB, userId, serverInsertAt);
    expect(tombstones).toEqual([
      expect.objectContaining({
        id: backdated.id,
        deleted_at: deletedAt,
        updated_at: deletedAt,
      }),
    ]);

    const bulkUpdatedAt = deletedAt + 120_000;
    await env.DB.prepare(
      `WITH RECURSIVE seq(n) AS (
         SELECT 1
         UNION ALL SELECT n + 1 FROM seq WHERE n < 1005
       )
       INSERT INTO activities
         (id,user_id,date,type,logged_at,source,deleted_at,updated_at)
       SELECT ?1 || ':' || n, ?1, '2020-01-01', 'walk', 1, 'ios', NULL, ?2
         FROM seq`,
    )
      .bind(userId, bulkUpdatedAt)
      .run();
    const bulk = await listActivitiesForUser(env.DB, userId, bulkUpdatedAt - 1);
    expect(bulk).toHaveLength(1005);
    expect(bulk.every((activity) => activity.updated_at === bulkUpdatedAt)).toBe(true);

    const plan = await env.DB.prepare(
      `EXPLAIN QUERY PLAN
       SELECT * FROM activities
        WHERE user_id = ?1 AND updated_at > ?2
        ORDER BY updated_at, id`,
    )
      .bind(userId, bulkUpdatedAt - 1)
      .all<{ detail: string }>();
    expect(plan.results.some((row) => row.detail.includes('ix_activities_user_updated')))
      .toBe(true);
    const empty = await env.DB.prepare(
      `SELECT * FROM activities
        WHERE user_id = ?1 AND updated_at > ?2
        ORDER BY updated_at, id`,
    )
      .bind(userId, bulkUpdatedAt)
      .all();
    expect(empty.results).toEqual([]);
    // The seek stays constant despite the 1,005-row account history above.
    expect(empty.meta.rows_read).toBeLessThanOrEqual(2);
  });

  it('measures one additional billed index row for activity insert and cursor update', async () => {
    await env.DB.prepare(
      `CREATE TABLE p1_activity_cost_without_cursor (
         id TEXT PRIMARY KEY,
         user_id TEXT NOT NULL,
         date TEXT NOT NULL,
         updated_at INTEGER NOT NULL,
         deleted_at INTEGER
       )`,
    ).run();
    await env.DB.prepare(
      'CREATE INDEX p1_activity_cost_without_date ON p1_activity_cost_without_cursor(user_id,date)',
    ).run();
    await env.DB.prepare(
      `CREATE TABLE p1_activity_cost_with_cursor (
         id TEXT PRIMARY KEY,
         user_id TEXT NOT NULL,
         date TEXT NOT NULL,
         updated_at INTEGER NOT NULL,
         deleted_at INTEGER
       )`,
    ).run();
    await env.DB.prepare(
      'CREATE INDEX p1_activity_cost_with_date ON p1_activity_cost_with_cursor(user_id,date)',
    ).run();
    await env.DB.prepare(
      'CREATE INDEX p1_activity_cost_with_updated ON p1_activity_cost_with_cursor(user_id,updated_at)',
    ).run();

    const insertWithout = await env.DB.prepare(
      "INSERT INTO p1_activity_cost_without_cursor VALUES ('a','u','2035-01-01',100,NULL)",
    ).run();
    const insertWith = await env.DB.prepare(
      "INSERT INTO p1_activity_cost_with_cursor VALUES ('a','u','2035-01-01',100,NULL)",
    ).run();
    expect(insertWith.meta.rows_written - insertWithout.meta.rows_written).toBe(1);

    const updateWithout = await env.DB.prepare(
      'UPDATE p1_activity_cost_without_cursor SET deleted_at=200,updated_at=200 WHERE id=\'a\'',
    ).run();
    const updateWith = await env.DB.prepare(
      'UPDATE p1_activity_cost_with_cursor SET deleted_at=200,updated_at=200 WHERE id=\'a\'',
    ).run();
    expect(updateWith.meta.rows_written - updateWithout.meta.rows_written).toBe(1);
  });
});
