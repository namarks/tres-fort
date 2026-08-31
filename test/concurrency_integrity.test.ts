import { applyD1Migrations, env } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import {
  discardSession,
  getOrCreateSession,
  logSet,
  logWorkoutComplete,
  patchSession,
  patchSet,
  reviveDiscardedSession,
  setPlannedSession,
  skipPlannedSession,
  updatePlanTree,
} from '../src/db';
import { handleMcp } from '../src/mcp/server';
import type { Env } from '../src/types';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

async function seedUserAndPlan(label: string): Promise<{ userId: string; planId: string }> {
  const userId = crypto.randomUUID();
  const planId = crypto.randomUUID();
  const ts = Date.now();
  await env.DB.batch([
    env.DB
      .prepare(
        'INSERT INTO users (id,apple_sub,email,display_name,created_at) VALUES (?1,?2,NULL,?3,?4)',
      )
      .bind(userId, `sub-${userId}`, label, ts),
    env.DB
      .prepare(
        `INSERT INTO plans
         (id,user_id,name,status,version,meta,created_at,updated_at)
         VALUES (?1,?2,?3,'active',1,NULL,?4,?4)`,
      )
      .bind(planId, userId, `${label} plan`, ts),
  ]);
  return { userId, planId };
}

/**
 * Return two database facades that pause immediately after each caller's
 * first matching `.first()` has completed. Both calls therefore observe the
 * same pre-write state before either is allowed to continue.
 */
function databasesWithSharedReadBarrier(sqlNeedle: string): [D1Database, D1Database] {
  let arrivals = 0;
  let release!: () => void;
  const barrier = new Promise<void>((resolve) => {
    release = resolve;
  });

  const arrive = async <T>(value: T): Promise<T> => {
    arrivals += 1;
    if (arrivals === 2) release();
    await barrier;
    return value;
  };

  const wrapOne = (): D1Database => {
    let intercepted = false;
    const wrapStatement = (statement: D1PreparedStatement): D1PreparedStatement =>
      new Proxy(statement, {
        get(target, property) {
          if (property === 'bind') {
            return (...values: any[]) => wrapStatement(target.bind(...values));
          }
          if (property === 'first') {
            return async (...args: any[]) => {
              const value = await (target.first as (...callArgs: any[]) => Promise<unknown>)(
                ...args,
              );
              return arrive(value);
            };
          }
          const value = Reflect.get(target, property, target);
          return typeof value === 'function' ? value.bind(target) : value;
        },
      });

    return new Proxy(env.DB, {
      get(target, property) {
        if (property === 'prepare') {
          return (sql: string) => {
            const statement = target.prepare(sql);
            if (intercepted || !sql.includes(sqlNeedle)) return statement;
            intercepted = true;
            return wrapStatement(statement);
          };
        }
        const value = Reflect.get(target, property, target);
        return typeof value === 'function' ? value.bind(target) : value;
      },
    });
  };

  return [wrapOne(), wrapOne()];
}

/**
 * Pause one `.run()` mutation after a matching `.first()` has returned. The
 * caller can let another real-D1 mutation commit in that gap, then release
 * the stale writer and assert its conditional write result.
 */
function databaseWithPausedRunAfterRead(
  readNeedle: string,
  runNeedle: string,
): {
  db: D1Database;
  readReached: Promise<void>;
  runReached: Promise<void>;
  releaseRun: () => void;
} {
  let markRead!: () => void;
  const readReached = new Promise<void>((resolve) => {
    markRead = resolve;
  });
  let releaseRun!: () => void;
  const runGate = new Promise<void>((resolve) => {
    releaseRun = resolve;
  });
  let markRun!: () => void;
  const runReached = new Promise<void>((resolve) => {
    markRun = resolve;
  });
  let interceptedRead = false;
  let interceptedRun = false;

  const wrapRead = (statement: D1PreparedStatement): D1PreparedStatement =>
    new Proxy(statement, {
      get(target, property) {
        if (property === 'bind') {
          return (...values: any[]) => wrapRead(target.bind(...values));
        }
        if (property === 'first') {
          return async (...args: any[]) => {
            const value = await (target.first as (...callArgs: any[]) => Promise<unknown>)(
              ...args,
            );
            markRead();
            return value;
          };
        }
        const value = Reflect.get(target, property, target);
        return typeof value === 'function' ? value.bind(target) : value;
      },
    });
  const wrapRun = (statement: D1PreparedStatement): D1PreparedStatement =>
    new Proxy(statement, {
      get(target, property) {
        if (property === 'bind') {
          return (...values: any[]) => wrapRun(target.bind(...values));
        }
        if (property === 'run') {
          return async (...args: any[]) => {
            markRun();
            await runGate;
            return (target.run as (...callArgs: any[]) => Promise<unknown>)(...args);
          };
        }
        const value = Reflect.get(target, property, target);
        return typeof value === 'function' ? value.bind(target) : value;
      },
    });

  const db = new Proxy(env.DB, {
    get(target, property) {
      if (property === 'prepare') {
        return (sql: string) => {
          const statement = target.prepare(sql);
          if (!interceptedRead && sql.includes(readNeedle)) {
            interceptedRead = true;
            return wrapRead(statement);
          }
          if (!interceptedRun && sql.includes(runNeedle)) {
            interceptedRun = true;
            return wrapRun(statement);
          }
          return statement;
        };
      }
      const value = Reflect.get(target, property, target);
      return typeof value === 'function' ? value.bind(target) : value;
    },
  });
  return { db, readReached, runReached, releaseRun };
}

/** Pause before the first matching `.first()` executes. This creates a
 * deterministic gap after an outer caller has observed a session generation
 * but before its nested mutation resolves and rereads the target session. */
function databaseWithPausedFirstBeforeRead(sqlNeedle: string): {
  db: D1Database;
  firstReached: Promise<void>;
  releaseFirst: () => void;
} {
  let markFirst!: () => void;
  const firstReached = new Promise<void>((resolve) => {
    markFirst = resolve;
  });
  let releaseFirst!: () => void;
  const firstGate = new Promise<void>((resolve) => {
    releaseFirst = resolve;
  });
  let intercepted = false;

  const wrapStatement = (statement: D1PreparedStatement): D1PreparedStatement =>
    new Proxy(statement, {
      get(target, property) {
        if (property === 'bind') {
          return (...values: any[]) => wrapStatement(target.bind(...values));
        }
        if (property === 'first') {
          return async (...args: any[]) => {
            markFirst();
            await firstGate;
            return (target.first as (...callArgs: any[]) => Promise<unknown>)(...args);
          };
        }
        const value = Reflect.get(target, property, target);
        return typeof value === 'function' ? value.bind(target) : value;
      },
    });

  const db = new Proxy(env.DB, {
    get(target, property) {
      if (property === 'prepare') {
        return (sql: string) => {
          const statement = target.prepare(sql);
          if (intercepted || !sql.includes(sqlNeedle)) return statement;
          intercepted = true;
          return wrapStatement(statement);
        };
      }
      const value = Reflect.get(target, property, target);
      return typeof value === 'function' ? value.bind(target) : value;
    },
  });
  return { db, firstReached, releaseFirst };
}

/** Pause the first D1 batch after a matching pre-read has returned. */
function databaseWithPausedBatchAfterRead(readNeedle: string): {
  db: D1Database;
  readReached: Promise<void>;
  releaseBatch: () => void;
} {
  let markRead!: () => void;
  const readReached = new Promise<void>((resolve) => {
    markRead = resolve;
  });
  let releaseBatch!: () => void;
  const batchGate = new Promise<void>((resolve) => {
    releaseBatch = resolve;
  });
  let interceptedRead = false;

  const wrapRead = (statement: D1PreparedStatement): D1PreparedStatement =>
    new Proxy(statement, {
      get(target, property) {
        if (property === 'bind') {
          return (...values: any[]) => wrapRead(target.bind(...values));
        }
        if (property === 'first') {
          return async (...args: any[]) => {
            const value = await (target.first as (...callArgs: any[]) => Promise<unknown>)(
              ...args,
            );
            markRead();
            return value;
          };
        }
        const value = Reflect.get(target, property, target);
        return typeof value === 'function' ? value.bind(target) : value;
      },
    });

  const db = new Proxy(env.DB, {
    get(target, property) {
      if (property === 'prepare') {
        return (sql: string) => {
          const statement = target.prepare(sql);
          if (interceptedRead || !sql.includes(readNeedle)) return statement;
          interceptedRead = true;
          return wrapRead(statement);
        };
      }
      if (property === 'batch') {
        return async (statements: D1PreparedStatement[]) => {
          await batchGate;
          return target.batch(statements);
        };
      }
      const value = Reflect.get(target, property, target);
      return typeof value === 'function' ? value.bind(target) : value;
    },
  });
  return { db, readReached, releaseBatch };
}

/** Let logSet's authoritative read snapshot complete, then pause its atomic
 * insert/start batch so another writer can move the session in that gap. */
function databaseWithPausedWriteBatchAfterSnapshot(): {
  db: D1Database;
  snapshotReached: Promise<void>;
  releaseBatch: () => void;
} {
  let markSnapshot!: () => void;
  const snapshotReached = new Promise<void>((resolve) => {
    markSnapshot = resolve;
  });
  let releaseBatch!: () => void;
  const writeGate = new Promise<void>((resolve) => {
    releaseBatch = resolve;
  });
  let batchCount = 0;
  const db = new Proxy(env.DB, {
    get(target, property) {
      if (property === 'batch') {
        return async (statements: D1PreparedStatement[]) => {
          batchCount += 1;
          if (batchCount === 1) {
            const result = await target.batch(statements);
            markSnapshot();
            return result;
          }
          if (batchCount === 2) await writeGate;
          return target.batch(statements);
        };
      }
      const value = Reflect.get(target, property, target);
      return typeof value === 'function' ? value.bind(target) : value;
    },
  });
  return { db, snapshotReached, releaseBatch };
}

describe('plan-tree optimistic concurrency', () => {
  it('allows exactly one full rebuild after two callers read the same version', async () => {
    const { userId, planId } = await seedUserAndPlan('plan-race');
    const oldDayId = crypto.randomUUID();
    const oldSlotId = crypto.randomUUID();
    const sessionId = crypto.randomUUID();
    const setId = crypto.randomUUID();
    const ts = Date.now();
    await env.DB.batch([
      env.DB
        .prepare(
          `INSERT INTO day_templates
           (id,plan_id,name,day_label,order_index,notes,created_at,updated_at)
           VALUES (?1,?2,'Original day','D',0,NULL,?3,?3)`,
        )
        .bind(oldDayId, planId, ts),
      env.DB
        .prepare(
          `INSERT INTO template_exercises
           (id,day_template_id,exercise_id,order_index,target_sets,target_reps,target_reps_max,target_rpe,rest_seconds,target_weight,target_duration_s,progression,cues,is_warmup,created_at,updated_at)
           VALUES (?1,?2,'ex_bench',0,3,5,NULL,NULL,120,NULL,NULL,NULL,NULL,0,?3,?3)`,
        )
        .bind(oldSlotId, oldDayId, ts),
      env.DB
        .prepare(
          `INSERT INTO sessions
           (id,user_id,plan_id,day_template_id,date,status,started_at,completed_at,perceived_fatigue,notes,created_at,updated_at)
           VALUES (?1,?2,?3,?4,'2036-12-31','completed',?5,?5,7,NULL,?5,?5)`,
        )
        .bind(sessionId, userId, planId, oldDayId, ts),
      env.DB
        .prepare(
          `INSERT INTO set_logs
           (id,session_id,exercise_id,template_exercise_id,set_index,weight,reps,rpe,is_warmup,notes,logged_at,source,duration_s,is_timed,deleted_at)
           VALUES (?1,?2,'ex_bench',?3,1,185,5,8,0,NULL,?4,'ios',NULL,0,NULL)`,
        )
        .bind(setId, sessionId, oldSlotId, ts),
    ]);
    const [dbA, dbB] = databasesWithSharedReadBarrier(
      "SELECT * FROM plans WHERE user_id = ?1 AND status = 'active'",
    );

    // Deliberately omit expected_version: the version actually read must still
    // be the compare-and-swap token for every statement in the rebuild batch.
    const results = await Promise.all([
      updatePlanTree(dbA, userId, {
        name: 'Contender A',
        days: [
          {
            name: 'Only A',
            day_label: 'D',
            exercises: [{ exercise: 'bench', target_sets: 3, target_reps: 6 }],
          },
        ],
      }),
      updatePlanTree(dbB, userId, {
        name: 'Contender B',
        days: [
          {
            name: 'Only B',
            day_label: 'D',
            exercises: [{ exercise: 'bench', target_sets: 4, target_reps: 8 }],
          },
        ],
      }),
    ]);

    const successes = results.filter(
      (result) => 'conflict' in result && result.conflict === false,
    );
    const conflicts = results.filter(
      (result) => 'conflict' in result && result.conflict === true,
    );
    expect(successes).toHaveLength(1);
    expect(conflicts).toEqual([{ conflict: true, current_version: 2 }]);

    const plan = await env.DB
      .prepare('SELECT name,version FROM plans WHERE id = ?1')
      .bind(planId)
      .first<{ name: string; version: number }>();
    expect(plan?.version).toBe(2);

    const days = await env.DB
      .prepare('SELECT id,name,day_label FROM day_templates WHERE plan_id = ?1 ORDER BY name')
      .bind(planId)
      .all<{ id: string; name: string; day_label: string }>();
    expect(days.results).toHaveLength(1);
    const slots = await env.DB
      .prepare(
        `SELECT te.id,te.day_template_id,te.target_sets,te.target_reps
           FROM template_exercises te JOIN day_templates d ON d.id=te.day_template_id
          WHERE d.plan_id=?1`,
      )
      .bind(planId)
      .all<{
        id: string;
        day_template_id: string;
        target_sets: number;
        target_reps: number;
      }>();
    expect(slots.results).toHaveLength(1);
    expect(
      [
        { name: 'Contender A', day: 'Only A', target_sets: 3, target_reps: 6 },
        { name: 'Contender B', day: 'Only B', target_sets: 4, target_reps: 8 },
      ],
    ).toContainEqual({
      name: plan?.name,
      day: days.results[0]!.name,
      target_sets: slots.results[0]!.target_sets,
      target_reps: slots.results[0]!.target_reps,
    });

    const remappedSession = await env.DB
      .prepare('SELECT day_template_id FROM sessions WHERE id=?1')
      .bind(sessionId)
      .first<{ day_template_id: string | null }>();
    const remappedSet = await env.DB
      .prepare('SELECT template_exercise_id FROM set_logs WHERE id=?1')
      .bind(setId)
      .first<{ template_exercise_id: string | null }>();
    expect(remappedSession?.day_template_id).toBe(days.results[0]!.id);
    expect(remappedSet?.template_exercise_id).toBe(slots.results[0]!.id);
    expect(slots.results[0]!.day_template_id).toBe(days.results[0]!.id);
    expect(await env.DB.prepare('SELECT id FROM day_templates WHERE id=?1').bind(oldDayId).first()).toBeNull();
    expect(
      await env.DB.prepare('SELECT id FROM template_exercises WHERE id=?1').bind(oldSlotId).first(),
    ).toBeNull();
  });
});

describe('session create concurrency', () => {
  it('returns one winner row and never clobbers its explicit day pin', async () => {
    const { userId, planId } = await seedUserAndPlan('session-race');
    const ts = Date.now();
    const dayA = crypto.randomUUID();
    const dayB = crypto.randomUUID();
    await env.DB.batch([
      env.DB
        .prepare(
          `INSERT INTO day_templates
           (id,plan_id,name,day_label,order_index,notes,created_at,updated_at)
           VALUES (?1,?2,'Day A','A',0,NULL,?3,?3)`,
        )
        .bind(dayA, planId, ts),
      env.DB
        .prepare(
          `INSERT INTO day_templates
           (id,plan_id,name,day_label,order_index,notes,created_at,updated_at)
           VALUES (?1,?2,'Day B','B',1,NULL,?3,?3)`,
        )
        .bind(dayB, planId, ts),
    ]);

    const [dbA, dbB] = databasesWithSharedReadBarrier(
      'SELECT * FROM sessions WHERE user_id = ?1 AND date = ?2 ORDER BY created_at, id LIMIT 1',
    );
    const [resultA, resultB] = await Promise.all([
      getOrCreateSession(dbA, userId, planId, '2037-01-02', dayA),
      getOrCreateSession(dbB, userId, planId, '2037-01-02', dayB),
    ]);

    expect(resultA.id).toBe(resultB.id);
    expect(resultA.day_template_id).toBe(resultB.day_template_id);
    expect([dayA, dayB]).toContain(resultA.day_template_id);

    const rows = await env.DB
      .prepare('SELECT id,day_template_id FROM sessions WHERE user_id = ?1 AND date = ?2')
      .bind(userId, '2037-01-02')
      .all<{ id: string; day_template_id: string | null }>();
    expect(rows.results).toEqual([
      { id: resultA.id, day_template_id: resultA.day_template_id },
    ]);

    const otherDay = resultA.day_template_id === dayA ? dayB : dayA;
    const repeated = await getOrCreateSession(
      env.DB,
      userId,
      planId,
      '2037-01-02',
      otherDay,
    );
    expect(repeated.id).toBe(resultA.id);
    expect(repeated.day_template_id).toBe(resultA.day_template_id);
  });

  it('applies a planned-day override after losing an insert race', async () => {
    const { userId, planId } = await seedUserAndPlan('planned-override-race');
    const dayId = crypto.randomUUID();
    const ts = Date.now();
    await env.DB
      .prepare(
        `INSERT INTO day_templates
         (id,plan_id,name,day_label,order_index,notes,created_at,updated_at)
         VALUES (?1,?2,'Override day','O',0,NULL,?3,?3)`,
      )
      .bind(dayId, planId, ts)
      .run();

    const [creatorDb, overrideDb] = databasesWithSharedReadBarrier(
      'SELECT * FROM sessions WHERE user_id = ?1 AND date = ?2 ORDER BY created_at, id LIMIT 1',
    );
    const [created, override] = await Promise.all([
      getOrCreateSession(creatorDb, userId, planId, '2037-01-04', null),
      setPlannedSession(overrideDb, userId, '2037-01-04', 'O'),
    ]);

    expect(override).toMatchObject({
      ok: true,
      session: { id: created.id, day_template_id: dayId, status: 'planned' },
    });
    const rows = await env.DB
      .prepare(
        'SELECT id,day_template_id,status FROM sessions WHERE user_id = ?1 AND date = ?2',
      )
      .bind(userId, '2037-01-04')
      .all<{ id: string; day_template_id: string | null; status: string }>();
    expect(rows.results).toEqual([
      { id: created.id, day_template_id: dayId, status: 'planned' },
    ]);
  });

  it('applies a skip override after losing an insert race', async () => {
    const { userId, planId } = await seedUserAndPlan('skip-override-race');
    const [creatorDb, overrideDb] = databasesWithSharedReadBarrier(
      'SELECT * FROM sessions WHERE user_id = ?1 AND date = ?2 ORDER BY created_at, id LIMIT 1',
    );
    const [created, override] = await Promise.all([
      getOrCreateSession(creatorDb, userId, planId, '2037-01-05', null),
      skipPlannedSession(overrideDb, userId, '2037-01-05'),
    ]);

    expect(override).toMatchObject({
      ok: true,
      session: { id: created.id, status: 'skipped' },
    });
    const rows = await env.DB
      .prepare('SELECT id,status FROM sessions WHERE user_id = ?1 AND date = ?2')
      .bind(userId, '2037-01-05')
      .all<{ id: string; status: string }>();
    expect(rows.results).toEqual([{ id: created.id, status: 'skipped' }]);
  });

  it('does not let a stale default resolver reset an explicitly restarted attempt', async () => {
    const { userId, planId } = await seedUserAndPlan('resolver-restart-race');
    const date = '2037-01-14';
    const session = await getOrCreateSession(env.DB, userId, planId, date, null);
    // Seed a released-client legacy tombstone so the stale tokenless resolver
    // can begin before the explicit v1 restart claims the generation.
    await discardSession(env.DB, userId, session.id);
    const paused = databaseWithPausedRunAfterRead(
      'SELECT * FROM sessions WHERE user_id = ?1 AND date = ?2',
      'SET day_template_id=?2',
    );

    const staleResolver = getOrCreateSession(
      paused.db,
      userId,
      planId,
      date,
      null,
    );
    await paused.runReached;
    const restarted = await reviveDiscardedSession(
      env.DB,
      userId,
      session.id,
      0,
      null,
    );
    expect(restarted).toMatchObject({ status: 'planned', attempt: 1 });
    const setId = crypto.randomUUID();
    await logSet(env.DB, userId, {
      id: setId,
      session_id: session.id,
      exercise_id: 'ex_bench',
      set_index: 1,
      weight: 205,
      reps: 3,
      expected_attempt: 1,
      source: 'ios',
    });
    paused.releaseRun();

    expect(await staleResolver).toMatchObject({
      id: session.id,
      status: 'in_progress',
      attempt: 1,
    });
    expect(
      await env.DB.prepare('SELECT status,attempt FROM sessions WHERE id=?1')
        .bind(session.id)
        .first(),
    ).toEqual({ status: 'in_progress', attempt: 1 });
  });

  it('does not let a stale planned-session writer relabel a restarted workout', async () => {
    const { userId, planId } = await seedUserAndPlan('planned-restart-race');
    const dayId = crypto.randomUUID();
    const date = '2037-01-15';
    const ts = Date.now();
    await env.DB
      .prepare(
        `INSERT INTO day_templates
         (id,plan_id,name,day_label,order_index,notes,created_at,updated_at)
         VALUES (?1,?2,'Override day','O',0,NULL,?3,?3)`,
      )
      .bind(dayId, planId, ts)
      .run();
    const session = await getOrCreateSession(env.DB, userId, planId, date, null);
    const paused = databaseWithPausedRunAfterRead(
      'SELECT * FROM sessions WHERE user_id = ?1 AND date = ?2',
      'SET day_template_id = ?2',
    );
    const staleOverride = setPlannedSession(
      paused.db,
      userId,
      date,
      'O',
      0,
    );
    await paused.runReached;
    await discardSession(env.DB, userId, session.id, 0);
    await reviveDiscardedSession(env.DB, userId, session.id, 0, null);
    await logSet(env.DB, userId, {
      id: crypto.randomUUID(),
      session_id: session.id,
      exercise_id: 'ex_bench',
      set_index: 1,
      weight: 205,
      reps: 3,
      expected_attempt: 1,
      source: 'ios',
    });
    paused.releaseRun();

    expect(await staleOverride).toMatchObject({
      error: 'session_attempt_conflict',
      expected_attempt: 0,
      current_attempt: 1,
      current_session: {
        id: session.id,
        day_template_id: null,
        status: 'in_progress',
        attempt: 1,
      },
    });
    expect(
      await env.DB.prepare('SELECT day_template_id,status,attempt FROM sessions WHERE id=?1')
        .bind(session.id)
        .first(),
    ).toEqual({ day_template_id: null, status: 'in_progress', attempt: 1 });
  });

  it('does not let a stale skip writer hide a restarted workout', async () => {
    const { userId, planId } = await seedUserAndPlan('skip-restart-race');
    const date = '2037-01-16';
    const session = await getOrCreateSession(env.DB, userId, planId, date, null);
    const paused = databaseWithPausedRunAfterRead(
      'SELECT * FROM sessions WHERE user_id = ?1 AND date = ?2',
      "SET status = 'skipped'",
    );
    const staleSkip = skipPlannedSession(paused.db, userId, date, 0);
    await paused.runReached;
    await discardSession(env.DB, userId, session.id, 0);
    await reviveDiscardedSession(env.DB, userId, session.id, 0, null);
    await logSet(env.DB, userId, {
      id: crypto.randomUUID(),
      session_id: session.id,
      exercise_id: 'ex_bench',
      set_index: 1,
      weight: 205,
      reps: 3,
      expected_attempt: 1,
      source: 'ios',
    });
    paused.releaseRun();

    expect(await staleSkip).toMatchObject({
      error: 'session_attempt_conflict',
      expected_attempt: 0,
      current_attempt: 1,
      current_session: { id: session.id, status: 'in_progress', attempt: 1 },
    });
    expect(
      await env.DB.prepare('SELECT status,attempt FROM sessions WHERE id=?1')
        .bind(session.id)
        .first(),
    ).toEqual({ status: 'in_progress', attempt: 1 });
  });
});

describe('discard terminal-state concurrency', () => {
  it('keeps discard final when a completion PATCH already read the old state', async () => {
    const { userId, planId } = await seedUserAndPlan('completion-discard-race');
    const session = await getOrCreateSession(
      env.DB,
      userId,
      planId,
      '2037-01-06',
      null,
    );
    const paused = databaseWithPausedRunAfterRead(
      'SELECT * FROM sessions WHERE id = ?1 AND user_id = ?2',
      'SET status = CASE WHEN ?8 = 1 THEN ?2 ELSE status END',
    );

    const completionPromise = patchSession(paused.db, userId, session.id, {
      status: 'completed',
    });
    await paused.readReached;
    const discarded = await discardSession(env.DB, userId, session.id);
    paused.releaseRun();
    const completion = await completionPromise;

    expect(discarded).toMatchObject({ id: session.id, status: 'discarded' });
    expect(completion).toMatchObject({
      error: 'session_discarded',
      status: 'discarded',
      current_session: { id: session.id, status: 'discarded', attempt: 0 },
    });
    const final = await env.DB
      .prepare('SELECT status FROM sessions WHERE id = ?1')
      .bind(session.id)
      .first<{ status: string }>();
    expect(final?.status).toBe('discarded');
  });

  it('rejects a stale completion after discard and explicit restart advance the attempt', async () => {
    const { userId, planId } = await seedUserAndPlan('completion-restart-race');
    const session = await getOrCreateSession(
      env.DB,
      userId,
      planId,
      '2037-01-11',
      null,
    );
    const paused = databaseWithPausedRunAfterRead(
      'SELECT * FROM sessions WHERE id = ?1 AND user_id = ?2',
      'SET status = CASE WHEN ?8 = 1 THEN ?2 ELSE status END',
    );
    const completionPromise = patchSession(
      paused.db,
      userId,
      session.id,
      { status: 'completed' },
      0,
    );
    await paused.readReached;
    await discardSession(env.DB, userId, session.id, 0);
    const restarted = await reviveDiscardedSession(
      env.DB,
      userId,
      session.id,
      0,
      null,
    );
    expect(restarted).toMatchObject({ id: session.id, status: 'planned', attempt: 1 });
    paused.releaseRun();

    expect(await completionPromise).toMatchObject({
      error: 'session_attempt_conflict',
      expected_attempt: 0,
      current_attempt: 1,
      current_session: { id: session.id, status: 'planned', attempt: 1 },
    });
    const final = await env.DB
      .prepare('SELECT status,attempt FROM sessions WHERE id=?1')
      .bind(session.id)
      .first<{ status: string; attempt: number }>();
    expect(final).toEqual({ status: 'planned', attempt: 1 });
  });

  it('returns the same terminal conflict through MCP workout completion', async () => {
    const { userId, planId } = await seedUserAndPlan('mcp-completion-discard-race');
    const date = '2037-01-10';
    const session = await getOrCreateSession(env.DB, userId, planId, date, null);
    const paused = databaseWithPausedRunAfterRead(
      'SELECT * FROM sessions WHERE id = ?1 AND user_id = ?2',
      'SET status = CASE WHEN ?8 = 1 THEN ?2 ELSE status END',
    );

    const completionPromise = logWorkoutComplete(paused.db, userId, date, 7, null);
    await paused.readReached;
    await discardSession(env.DB, userId, session.id);
    paused.releaseRun();

    expect(await completionPromise).toMatchObject({
      error: 'session_discarded',
      status: 'discarded',
      current_session: { id: session.id, attempt: 0 },
    });
  });

  it('keeps MCP workout completion pinned to the attempt it observed before its patch', async () => {
    const { userId, planId } = await seedUserAndPlan('mcp-completion-restart-race');
    const date = '2037-01-22';
    const session = await getOrCreateSession(env.DB, userId, planId, date, null);
    const paused = databaseWithPausedFirstBeforeRead(
      'LEFT JOIN session_aliases AS sa',
    );

    const completionPromise = logWorkoutComplete(paused.db, userId, date, 8, 'old attempt');
    await paused.firstReached;
    await discardSession(env.DB, userId, session.id, 0);
    await reviveDiscardedSession(env.DB, userId, session.id, 0, null);
    paused.releaseFirst();

    expect(await completionPromise).toMatchObject({
      error: 'session_attempt_conflict',
      expected_attempt: 0,
      current_attempt: 1,
      current_session: {
        id: session.id,
        status: 'planned',
        attempt: 1,
      },
    });
    expect(
      await env.DB
        .prepare(
          'SELECT status,attempt,perceived_fatigue,notes FROM sessions WHERE id=?1',
        )
        .bind(session.id)
        .first(),
    ).toEqual({
      status: 'planned',
      attempt: 1,
      perceived_fatigue: null,
      notes: null,
    });
  });

  it('returns a structured attempt conflict when MCP log_set loses to discard and restart', async () => {
    const { userId, planId } = await seedUserAndPlan('mcp-set-restart-race');
    const date = '2037-01-23';
    const session = await getOrCreateSession(env.DB, userId, planId, date, null);
    const paused = databaseWithPausedFirstBeforeRead(
      'LEFT JOIN session_aliases AS sa',
    );
    const mcpEnv = { ...env, DB: paused.db } as unknown as Env;

    const rpcPromise = handleMcp(
      {
        jsonrpc: '2.0',
        id: 1,
        method: 'tools/call',
        params: {
          name: 'log_set',
          arguments: {
            exercise: 'bench',
            weight: 185,
            reps: 5,
            session_date: date,
          },
        },
      },
      mcpEnv,
      userId,
    );
    await paused.firstReached;
    await discardSession(env.DB, userId, session.id, 0);
    await reviveDiscardedSession(env.DB, userId, session.id, 0, null);
    paused.releaseFirst();

    const rpc = await rpcPromise;
    expect(rpc.status).toBe(200);
    const envelope = rpc.json as {
      result: { content: Array<{ text: string }>; isError?: boolean };
    };
    expect(envelope.result.isError).toBeUndefined();
    expect(JSON.parse(envelope.result.content[0]!.text)).toMatchObject({
      error: 'session_attempt_conflict',
      expected_attempt: 0,
      current_attempt: 1,
      current_session: {
        id: session.id,
        status: 'planned',
        attempt: 1,
      },
    });
    expect(
      await env.DB.prepare('SELECT id FROM set_logs WHERE session_id=?1').bind(session.id).first(),
    ).toBeNull();
  });

  it('returns the authoritative started session to an exact-UUID race loser', async () => {
    const { userId, planId } = await seedUserAndPlan('exact-uuid-winner-race');
    const session = await getOrCreateSession(
      env.DB,
      userId,
      planId,
      '2037-01-24',
      null,
    );
    const setId = crypto.randomUUID();
    const input = {
      id: setId,
      session_id: session.id,
      exercise_id: 'ex_bench',
      set_index: 1,
      weight: 185,
      reps: 5,
      expected_attempt: 0,
      source: 'ios' as const,
    };
    const paused = databaseWithPausedWriteBatchAfterSnapshot();
    const loserPromise = logSet(paused.db, userId, input);
    await paused.snapshotReached;
    expect(await logSet(env.DB, userId, input)).toMatchObject({
      deduped: false,
      session: { status: 'in_progress', attempt: 0 },
    });
    paused.releaseBatch();

    expect(await loserPromise).toMatchObject({
      deduped: true,
      set: { id: setId, deleted_at: null },
      session: {
        id: session.id,
        status: 'in_progress',
        attempt: 0,
        write_protocol: 'attempt-v1',
      },
    });
  });

  it('returns the authoritative restarted session and tombstone to an exact-UUID race loser', async () => {
    const { userId, planId } = await seedUserAndPlan('exact-uuid-restart-race');
    const session = await getOrCreateSession(
      env.DB,
      userId,
      planId,
      '2037-01-25',
      null,
    );
    const setId = crypto.randomUUID();
    const input = {
      id: setId,
      session_id: session.id,
      exercise_id: 'ex_bench',
      set_index: 1,
      weight: 185,
      reps: 5,
      expected_attempt: 0,
      source: 'ios' as const,
    };
    const paused = databaseWithPausedWriteBatchAfterSnapshot();
    const loserPromise = logSet(paused.db, userId, input);
    await paused.snapshotReached;
    await logSet(env.DB, userId, input);
    await discardSession(env.DB, userId, session.id, 0);
    await reviveDiscardedSession(env.DB, userId, session.id, 0, null);
    paused.releaseBatch();

    expect(await loserPromise).toMatchObject({
      deduped: true,
      set: { id: setId, deleted_at: expect.any(Number) },
      session: {
        id: session.id,
        status: 'planned',
        attempt: 1,
        write_protocol: 'attempt-v1',
      },
    });
    expect(
      await env.DB.prepare('SELECT status,attempt FROM sessions WHERE id=?1')
        .bind(session.id)
        .first(),
    ).toEqual({ status: 'planned', attempt: 1 });
  });

  it('tombstones a set that commits after discard reads but before its batch', async () => {
    const { userId, planId } = await seedUserAndPlan('set-before-discard-race');
    const session = await getOrCreateSession(
      env.DB,
      userId,
      planId,
      '2037-01-09',
      null,
    );
    const setId = crypto.randomUUID();
    const paused = databaseWithPausedBatchAfterRead(
      'SELECT * FROM sessions WHERE id = ?1 AND user_id = ?2',
    );

    const discardPromise = discardSession(paused.db, userId, session.id);
    await paused.readReached;
    const logged = await logSet(env.DB, userId, {
      id: setId,
      session_id: session.id,
      exercise_id: 'ex_bench',
      set_index: 1,
      weight: 175,
      reps: 5,
      source: 'ios',
    });
    paused.releaseBatch();
    const discarded = await discardPromise;

    expect(logged).toMatchObject({ deduped: false, set: { id: setId } });
    expect(discarded).toMatchObject({ id: session.id, status: 'discarded' });
    const finalSet = await env.DB
      .prepare('SELECT deleted_at FROM set_logs WHERE id = ?1')
      .bind(setId)
      .first<{ deleted_at: number | null }>();
    expect(finalSet?.deleted_at).not.toBeNull();
    const audit = await env.DB
      .prepare("SELECT args FROM audit_log WHERE user_id = ?1 AND tool = 'discard_session'")
      .bind(userId)
      .first<{ args: string }>();
    expect(JSON.parse(audit!.args)).toMatchObject({
      session_id: session.id,
      sets_discarded: 1,
    });
  });

  it('does not let a stale duplicate discard tombstone a restarted attempt', async () => {
    const { userId, planId } = await seedUserAndPlan('discard-restart-race');
    const session = await getOrCreateSession(
      env.DB,
      userId,
      planId,
      '2037-01-12',
      null,
    );
    const paused = databaseWithPausedBatchAfterRead(
      'SELECT * FROM sessions WHERE id = ?1 AND user_id = ?2',
    );
    const staleDiscardPromise = discardSession(
      paused.db,
      userId,
      session.id,
      0,
    );
    await paused.readReached;
    await discardSession(env.DB, userId, session.id, 0);
    const restarted = await reviveDiscardedSession(
      env.DB,
      userId,
      session.id,
      0,
      null,
    );
    if (!restarted || 'error' in restarted) {
      throw new Error('expected discarded session revival to succeed');
    }
    const newSetId = crypto.randomUUID();
    await logSet(env.DB, userId, {
      id: newSetId,
      session_id: session.id,
      exercise_id: 'ex_bench',
      set_index: 1,
      weight: 205,
      reps: 3,
      expected_attempt: 1,
      source: 'ios',
    });
    paused.releaseBatch();

    expect(await staleDiscardPromise).toMatchObject({
      error: 'session_attempt_conflict',
      current_attempt: 1,
      current_session: { id: session.id, status: 'in_progress', attempt: 1 },
    });
    const finalSession = await env.DB
      .prepare('SELECT status,attempt FROM sessions WHERE id=?1')
      .bind(session.id)
      .first<{ status: string; attempt: number }>();
    const finalSet = await env.DB
      .prepare('SELECT deleted_at FROM set_logs WHERE id=?1')
      .bind(newSetId)
      .first<{ deleted_at: number | null }>();
    expect(restarted.attempt).toBe(1);
    expect(finalSession).toEqual({ status: 'in_progress', attempt: 1 });
    expect(finalSet?.deleted_at).toBeNull();
    const audits = await env.DB
      .prepare("SELECT args FROM audit_log WHERE user_id=?1 AND tool='discard_session'")
      .bind(userId)
      .all<{ args: string }>();
    expect(audits.results.filter((row) =>
      JSON.parse(row.args).session_id === session.id)).toHaveLength(1);
  });

  it('rejects a set when discard commits between its idempotency read and write batch', async () => {
    const { userId, planId } = await seedUserAndPlan('set-discard-race');
    const session = await getOrCreateSession(
      env.DB,
      userId,
      planId,
      '2037-01-07',
      null,
    );
    const setId = crypto.randomUUID();
    const paused = databaseWithPausedWriteBatchAfterSnapshot();

    const setPromise = logSet(paused.db, userId, {
      id: setId,
      session_id: session.id,
      exercise_id: 'ex_bench',
      set_index: 1,
      weight: 185,
      reps: 5,
      source: 'ios',
    }).then(
      (value) => ({ ok: true as const, value }),
      (error: Error) => ({ ok: false as const, error: error.message }),
    );
    await paused.snapshotReached;
    const discarded = await discardSession(env.DB, userId, session.id);
    paused.releaseBatch();
    const setOutcome = await setPromise;

    expect(discarded).toMatchObject({ id: session.id, status: 'discarded' });
    expect(setOutcome).toEqual({ ok: false, error: 'session_discarded' });
    const finalSession = await env.DB
      .prepare('SELECT status FROM sessions WHERE id = ?1')
      .bind(session.id)
      .first<{ status: string }>();
    const finalSet = await env.DB
      .prepare('SELECT deleted_at FROM set_logs WHERE id = ?1')
      .bind(setId)
      .first<{ deleted_at: number | null }>();
    const live = await env.DB
      .prepare('SELECT COUNT(*) AS n FROM set_logs WHERE session_id = ?1 AND deleted_at IS NULL')
      .bind(session.id)
      .first<{ n: number }>();
    expect(finalSession?.status).toBe('discarded');
    expect(finalSet == null || finalSet.deleted_at != null).toBe(true);
    expect(live?.n).toBe(0);
  });

  it('rejects a stale set when discard and restart advance its attempt before write', async () => {
    const { userId, planId } = await seedUserAndPlan('set-restart-race');
    const session = await getOrCreateSession(
      env.DB,
      userId,
      planId,
      '2037-01-13',
      null,
    );
    const setId = crypto.randomUUID();
    const paused = databaseWithPausedWriteBatchAfterSnapshot();
    const setPromise = logSet(paused.db, userId, {
      id: setId,
      session_id: session.id,
      exercise_id: 'ex_bench',
      set_index: 1,
      weight: 185,
      reps: 5,
      expected_attempt: 0,
      source: 'ios',
    }).then(
      (value) => ({ ok: true as const, value }),
      (error: Error) => ({
        ok: false as const,
        error: error.message,
        conflict: error instanceof Error && 'currentSession' in error
          ? (error as Error & { currentSession: { attempt: number } }).currentSession
          : null,
      }),
    );
    await paused.snapshotReached;
    await discardSession(env.DB, userId, session.id, 0);
    await reviveDiscardedSession(env.DB, userId, session.id, 0, null);
    paused.releaseBatch();

    expect(await setPromise).toEqual({
      ok: false,
      error: 'session_attempt_conflict',
      conflict: expect.objectContaining({ attempt: 1 }),
    });
    expect(
      await env.DB.prepare('SELECT id FROM set_logs WHERE id=?1').bind(setId).first(),
    ).toBeNull();
    expect(
      await env.DB.prepare('SELECT status,attempt FROM sessions WHERE id=?1')
        .bind(session.id)
        .first(),
    ).toEqual({ status: 'planned', attempt: 1 });
  });

  it('emits exactly one audit when two discards read the same live session', async () => {
    const { userId, planId } = await seedUserAndPlan('double-discard-race');
    const session = await getOrCreateSession(
      env.DB,
      userId,
      planId,
      '2037-01-08',
      null,
    );
    const [dbA, dbB] = databasesWithSharedReadBarrier(
      'SELECT * FROM sessions WHERE id = ?1 AND user_id = ?2',
    );

    const [a, b] = await Promise.all([
      discardSession(dbA, userId, session.id),
      discardSession(dbB, userId, session.id),
    ]);
    expect(a?.status).toBe('discarded');
    expect(b?.status).toBe('discarded');
    const audits = await env.DB
      .prepare("SELECT args FROM audit_log WHERE user_id = ?1 AND tool = 'discard_session'")
      .bind(userId)
      .all<{ args: string }>();
    expect(
      audits.results.filter(
        (row) =>
          (JSON.parse(row.args) as { session_id?: string }).session_id === session.id,
      ),
    ).toHaveLength(1);
  });

  it('rejects a stale skipped PATCH after a set starts the same attempt', async () => {
    const { userId, planId } = await seedUserAndPlan('patch-skip-set-race');
    const session = await getOrCreateSession(
      env.DB,
      userId,
      planId,
      '2037-01-19',
      null,
    );
    const paused = databaseWithPausedRunAfterRead(
      'SELECT * FROM sessions WHERE id = ?1 AND user_id = ?2',
      'SET status = CASE WHEN ?8 = 1 THEN ?2 ELSE status END',
    );
    const staleSkip = patchSession(
      paused.db,
      userId,
      session.id,
      { status: 'skipped' },
      0,
    );
    await paused.runReached;
    const setId = crypto.randomUUID();
    await logSet(env.DB, userId, {
      id: setId,
      session_id: session.id,
      exercise_id: 'ex_bench',
      set_index: 1,
      weight: 185,
      reps: 5,
      expected_attempt: 0,
      source: 'ios',
    });
    paused.releaseRun();

    expect(await staleSkip).toEqual({
      error: 'session_already_started',
      status: 'in_progress',
    });
    expect(
      await env.DB.prepare('SELECT status,attempt,started_at FROM sessions WHERE id=?1')
        .bind(session.id)
        .first(),
    ).toMatchObject({ status: 'in_progress', attempt: 0 });
    expect(
      await env.DB.prepare('SELECT deleted_at FROM set_logs WHERE id=?1')
        .bind(setId)
        .first(),
    ).toEqual({ deleted_at: null });
  });

  it('preserves the set start timestamp when completion races the final set', async () => {
    const { userId, planId } = await seedUserAndPlan('patch-finish-set-race');
    const session = await getOrCreateSession(
      env.DB,
      userId,
      planId,
      '2037-01-20',
      null,
    );
    const paused = databaseWithPausedRunAfterRead(
      'SELECT * FROM sessions WHERE id = ?1 AND user_id = ?2',
      'SET status = CASE WHEN ?8 = 1 THEN ?2 ELSE status END',
    );
    const completion = patchSession(
      paused.db,
      userId,
      session.id,
      { status: 'completed' },
      0,
    );
    await paused.runReached;
    const setId = crypto.randomUUID();
    await logSet(env.DB, userId, {
      id: setId,
      session_id: session.id,
      exercise_id: 'ex_bench',
      set_index: 1,
      weight: 185,
      reps: 5,
      expected_attempt: 0,
      source: 'ios',
    });
    paused.releaseRun();

    expect(await completion).toMatchObject({
      id: session.id,
      status: 'completed',
      attempt: 0,
    });
    const final = await env.DB
      .prepare('SELECT status,attempt,started_at,completed_at FROM sessions WHERE id=?1')
      .bind(session.id)
      .first<{
        status: string;
        attempt: number;
        started_at: number | null;
        completed_at: number | null;
      }>();
    expect(final).toMatchObject({ status: 'completed', attempt: 0 });
    expect(final?.started_at).not.toBeNull();
    expect(final?.completed_at).not.toBeNull();
  });

  it('rejects a delayed set when skip wins first in the same attempt', async () => {
    const { userId, planId } = await seedUserAndPlan('set-skip-race');
    const session = await getOrCreateSession(
      env.DB,
      userId,
      planId,
      '2037-01-21',
      null,
    );
    const setId = crypto.randomUUID();
    const paused = databaseWithPausedWriteBatchAfterSnapshot();
    const delayedSet = logSet(paused.db, userId, {
      id: setId,
      session_id: session.id,
      exercise_id: 'ex_bench',
      set_index: 1,
      weight: 185,
      reps: 5,
      expected_attempt: 0,
      source: 'ios',
    }).then(
      (value) => ({ ok: true as const, value }),
      (error: unknown) => ({
        ok: false as const,
        response:
          error instanceof Error && 'response' in error
            ? (error as Error & { response: () => unknown }).response()
            : null,
      }),
    );
    await paused.snapshotReached;
    expect(await skipPlannedSession(env.DB, userId, session.date, 0)).toMatchObject({
      ok: true,
      session: { id: session.id, status: 'skipped', attempt: 0 },
    });
    paused.releaseBatch();

    expect(await delayedSet).toEqual({
      ok: false,
      response: {
        error: 'session_state_conflict',
        current_session: expect.objectContaining({
          id: session.id,
          status: 'skipped',
          attempt: 0,
        }),
      },
    });
    expect(
      await env.DB.prepare('SELECT id FROM set_logs WHERE id=?1').bind(setId).first(),
    ).toBeNull();
    expect(
      await env.DB.prepare('SELECT status,attempt FROM sessions WHERE id=?1')
        .bind(session.id)
        .first(),
    ).toEqual({ status: 'skipped', attempt: 0 });
  });
});

describe('set correction concurrency', () => {
  it('combines disjoint corrections without resurrecting a concurrent delete', async () => {
    const { userId, planId } = await seedUserAndPlan('set-correction-race');
    const session = await getOrCreateSession(
      env.DB,
      userId,
      planId,
      '2037-01-03',
      null,
    );
    const setId = crypto.randomUUID();
    await env.DB
      .prepare(
        `INSERT INTO set_logs
         (id,session_id,exercise_id,template_exercise_id,set_index,weight,reps,rpe,is_warmup,notes,logged_at,source,duration_s,is_timed,deleted_at)
         VALUES (?1,?2,'ex_bench',NULL,1,185,5,8,0,NULL,?3,'ios',NULL,0,NULL)`,
      )
      .bind(setId, session.id, Date.now())
      .run();

    const [correctionDb, deletionDb] = databasesWithSharedReadBarrier(
      'SELECT sl.*, s.attempt AS session_attempt',
    );
    await Promise.all([
      patchSet(correctionDb, userId, setId, { duration_s: 75 }),
      patchSet(deletionDb, userId, setId, { deleted: true }),
    ]);

    const final = await env.DB
      .prepare('SELECT weight,duration_s,deleted_at FROM set_logs WHERE id = ?1')
      .bind(setId)
      .first<{ weight: number; duration_s: number | null; deleted_at: number | null }>();
    expect(final).toMatchObject({ weight: 185, duration_s: 75 });
    expect(final?.deleted_at).not.toBeNull();
  });

  it('does not demote a session when another live set wins the delete race', async () => {
    const { userId, planId } = await seedUserAndPlan('delete-log-race');
    const session = await getOrCreateSession(
      env.DB,
      userId,
      planId,
      '2037-01-17',
      null,
    );
    const oldSetId = crypto.randomUUID();
    await logSet(env.DB, userId, {
      id: oldSetId,
      session_id: session.id,
      exercise_id: 'ex_bench',
      set_index: 1,
      weight: 185,
      reps: 5,
      expected_attempt: 0,
      source: 'ios',
    });
    const paused = databaseWithPausedRunAfterRead(
      'SELECT sl.*, s.attempt AS session_attempt',
      "SET status = 'planned'",
    );
    const deletion = patchSet(paused.db, userId, oldSetId, { deleted: true });
    await paused.runReached;
    const newSetId = crypto.randomUUID();
    await logSet(env.DB, userId, {
      id: newSetId,
      session_id: session.id,
      exercise_id: 'ex_bench',
      set_index: 2,
      weight: 190,
      reps: 5,
      expected_attempt: 0,
      source: 'ios',
    });
    paused.releaseRun();
    await deletion;

    expect(
      await env.DB.prepare('SELECT status,attempt FROM sessions WHERE id=?1')
        .bind(session.id)
        .first(),
    ).toEqual({ status: 'in_progress', attempt: 0 });
    expect(
      await env.DB.prepare('SELECT deleted_at FROM set_logs WHERE id=?1')
        .bind(newSetId)
        .first(),
    ).toEqual({ deleted_at: null });
  });

  it('does not let a stale last-set deletion demote a restarted attempt', async () => {
    const { userId, planId } = await seedUserAndPlan('delete-restart-race');
    const session = await getOrCreateSession(
      env.DB,
      userId,
      planId,
      '2037-01-18',
      null,
    );
    const oldSetId = crypto.randomUUID();
    await logSet(env.DB, userId, {
      id: oldSetId,
      session_id: session.id,
      exercise_id: 'ex_bench',
      set_index: 1,
      weight: 185,
      reps: 5,
      expected_attempt: 0,
      source: 'ios',
    });
    const paused = databaseWithPausedRunAfterRead(
      'SELECT sl.*, s.attempt AS session_attempt',
      "SET status = 'planned'",
    );
    const deletion = patchSet(paused.db, userId, oldSetId, { deleted: true });
    await paused.runReached;
    await discardSession(env.DB, userId, session.id, 0);
    await reviveDiscardedSession(env.DB, userId, session.id, 0, null);
    const newSetId = crypto.randomUUID();
    await logSet(env.DB, userId, {
      id: newSetId,
      session_id: session.id,
      exercise_id: 'ex_bench',
      set_index: 1,
      weight: 205,
      reps: 3,
      expected_attempt: 1,
      source: 'ios',
    });
    paused.releaseRun();
    await deletion;

    expect(
      await env.DB.prepare('SELECT status,attempt FROM sessions WHERE id=?1')
        .bind(session.id)
        .first(),
    ).toEqual({ status: 'in_progress', attempt: 1 });
    expect(
      await env.DB.prepare('SELECT deleted_at FROM set_logs WHERE id=?1')
        .bind(newSetId)
        .first(),
    ).toEqual({ deleted_at: null });
  });

  it('does not allow a discarded-attempt set to be undeleted after restart', async () => {
    const { userId, planId } = await seedUserAndPlan('undelete-restart-guard');
    const session = await getOrCreateSession(
      env.DB,
      userId,
      planId,
      '2037-01-26',
      null,
    );
    const setId = crypto.randomUUID();
    await logSet(env.DB, userId, {
      id: setId,
      session_id: session.id,
      exercise_id: 'ex_bench',
      set_index: 1,
      weight: 185,
      reps: 5,
      expected_attempt: 0,
      source: 'ios',
    });
    await discardSession(env.DB, userId, session.id, 0);
    await reviveDiscardedSession(env.DB, userId, session.id, 0, null);

    await expect(patchSet(env.DB, userId, setId, { deleted: false })).rejects.toThrow(
      'set_undelete_unsupported',
    );
    expect(
      await env.DB.prepare('SELECT deleted_at FROM set_logs WHERE id=?1')
        .bind(setId)
        .first<{ deleted_at: number | null }>(),
    ).toEqual({ deleted_at: expect.any(Number) });
    expect(
      await env.DB.prepare('SELECT status,attempt FROM sessions WHERE id=?1')
        .bind(session.id)
        .first(),
    ).toEqual({ status: 'planned', attempt: 1 });
  });
});

describe('session revival hygiene', () => {
  it('clears all attempt metadata when setPlannedSession revives a discarded session', async () => {
    const { userId, planId } = await seedUserAndPlan('planned-revival-hygiene');
    const dayId = crypto.randomUUID();
    const ts = Date.now();
    await env.DB
      .prepare(
        `INSERT INTO day_templates
         (id,plan_id,name,day_label,order_index,notes,created_at,updated_at)
         VALUES (?1,?2,'Revival day','R',0,NULL,?3,?3)`,
      )
      .bind(dayId, planId, ts)
      .run();
    const date = '2037-01-27';
    const session = await getOrCreateSession(env.DB, userId, planId, date, dayId);
    await patchSession(env.DB, userId, session.id, { status: 'in_progress' }, 0);
    await patchSession(
      env.DB,
      userId,
      session.id,
      { status: 'completed', perceived_fatigue: 9, notes: 'old attempt' },
      0,
    );
    await discardSession(env.DB, userId, session.id, 0);

    expect(await setPlannedSession(env.DB, userId, date, 'R', 0)).toMatchObject({
      ok: true,
      session: {
        id: session.id,
        status: 'planned',
        attempt: 1,
        started_at: null,
        completed_at: null,
        perceived_fatigue: null,
        notes: null,
      },
    });
    expect(
      await env.DB
        .prepare(
          'SELECT status,attempt,started_at,completed_at,perceived_fatigue,notes FROM sessions WHERE id=?1',
        )
        .bind(session.id)
        .first(),
    ).toEqual({
      status: 'planned',
      attempt: 1,
      started_at: null,
      completed_at: null,
      perceived_fatigue: null,
      notes: null,
    });
  });

  it('clears all attempt metadata and advances the token when PATCH reopens a skip', async () => {
    const { userId, planId } = await seedUserAndPlan('skipped-revival-hygiene');
    const session = await getOrCreateSession(
      env.DB,
      userId,
      planId,
      '2037-01-28',
      null,
    );
    await patchSession(
      env.DB,
      userId,
      session.id,
      { status: 'skipped', perceived_fatigue: 7, notes: 'old skip' },
      0,
    );
    await env.DB
      .prepare('UPDATE sessions SET started_at=?2,completed_at=?3 WHERE id=?1')
      .bind(session.id, Date.now() - 1_000, Date.now())
      .run();

    expect(await patchSession(env.DB, userId, session.id, { status: 'planned' }, 0)).toMatchObject({
      id: session.id,
      status: 'planned',
      attempt: 1,
      started_at: null,
      completed_at: null,
      perceived_fatigue: null,
      notes: null,
    });
    expect(
      await env.DB
        .prepare(
          'SELECT status,attempt,started_at,completed_at,perceived_fatigue,notes FROM sessions WHERE id=?1',
        )
        .bind(session.id)
        .first(),
    ).toEqual({
      status: 'planned',
      attempt: 1,
      started_at: null,
      completed_at: null,
      perceived_fatigue: null,
      notes: null,
    });
  });
});

describe('0029 duplicate-session reconciliation', () => {
  it('preserves every set, retains one export, and restores both unique indexes', async () => {
    const { userId, planId } = await seedUserAndPlan('migration-replay');
    const suffix = crypto.randomUUID();
    const winner = `${suffix}-a`;
    const tieLoser = `${suffix}-b`;
    const lateLoser = `${suffix}-c`;
    const exportWinner = `${suffix}-d`;
    const exportLoser = `${suffix}-e`;
    const movedExportWinner = `${suffix}-f`;
    const movedExportLoser = `${suffix}-g`;
    const canonicalDay = `${suffix}-canonical-day`;
    const promotedPlan = `${suffix}-promoted-plan`;
    const promotedDay = `${suffix}-promoted-day`;
    const date = '2038-02-03';
    const exportDate = '2038-02-04';
    const movedExportDate = '2038-02-05';

    await env.DB.prepare('DROP INDEX ux_session_user_date').run();
    const sessionInsert = (id: string, sessionDate: string, createdAt: number) =>
      env.DB
        .prepare(
          `INSERT INTO sessions
           (id,user_id,plan_id,day_template_id,date,status,started_at,completed_at,perceived_fatigue,notes,created_at,updated_at)
           VALUES (?1,?2,?3,NULL,?4,'completed',?5,?5,7,NULL,?5,?5)`,
        )
        .bind(id, userId, planId, sessionDate, createdAt);
    await env.DB.batch([
      env.DB
        .prepare(
          `INSERT INTO plans
           (id,user_id,name,status,version,meta,created_at,updated_at)
           VALUES (?1,?2,'Prior plan','archived',1,NULL,50,50)`,
        )
        .bind(promotedPlan, userId),
      env.DB
        .prepare(
          `INSERT INTO day_templates
           (id,plan_id,name,day_label,order_index,notes,created_at,updated_at)
           VALUES (?1,?2,'Canonical day','C',0,NULL,60,60)`,
        )
        .bind(canonicalDay, planId),
      env.DB
        .prepare(
          `INSERT INTO day_templates
           (id,plan_id,name,day_label,order_index,notes,created_at,updated_at)
           VALUES (?1,?2,'Completed day','P',0,NULL,70,70)`,
        )
        .bind(promotedDay, promotedPlan),
      env.DB
        .prepare(
          `INSERT INTO sessions
           (id,user_id,plan_id,day_template_id,date,status,started_at,completed_at,perceived_fatigue,notes,created_at,updated_at)
           VALUES (?1,?2,?3,?4,?5,'planned',NULL,NULL,NULL,'canonical shell',100,150)`,
        )
        .bind(winner, userId, planId, canonicalDay, date),
      env.DB
        .prepare(
          `INSERT INTO sessions
           (id,user_id,plan_id,day_template_id,date,status,started_at,completed_at,perceived_fatigue,notes,created_at,updated_at)
           VALUES (?1,?2,?3,?4,?5,'completed',700,900,9,'completed duplicate',100,950)`,
        )
        .bind(tieLoser, userId, promotedPlan, promotedDay, date),
      env.DB
        .prepare(
          `INSERT INTO sessions
           (id,user_id,plan_id,day_template_id,date,status,started_at,completed_at,perceived_fatigue,notes,created_at,updated_at)
           VALUES (?1,?2,?3,?4,?5,'in_progress',800,NULL,5,'newer in-progress duplicate',200,1000)`,
        )
        .bind(lateLoser, userId, planId, canonicalDay, date),
      sessionInsert(exportWinner, exportDate, 300),
      sessionInsert(exportLoser, exportDate, 400),
      env.DB
        .prepare(
          `INSERT INTO sessions
           (id,user_id,plan_id,day_template_id,date,status,started_at,completed_at,perceived_fatigue,notes,created_at,updated_at)
           VALUES (?1,?2,?3,?4,?5,'planned',NULL,NULL,NULL,'empty skip shell',500,510)`,
        )
        .bind(movedExportWinner, userId, planId, canonicalDay, movedExportDate),
      env.DB
        .prepare(
          `INSERT INTO sessions
           (id,user_id,plan_id,day_template_id,date,status,started_at,completed_at,perceived_fatigue,notes,created_at,updated_at)
           VALUES (?1,?2,?3,?4,?5,'skipped',NULL,NULL,NULL,'explicit skip',600,650)`,
        )
        .bind(movedExportLoser, userId, promotedPlan, promotedDay, movedExportDate),
    ]);

    const setInsert = (
      id: string,
      sessionId: string,
      loggedAt: number,
      deletedAt: number | null = null,
    ) =>
      env.DB
        .prepare(
          `INSERT INTO set_logs
           (id,session_id,exercise_id,template_exercise_id,set_index,weight,reps,rpe,is_warmup,notes,logged_at,source,duration_s,is_timed,deleted_at)
           VALUES (?1,?2,'ex_bench',NULL,1,225,5,8,0,NULL,?3,'ios',NULL,0,?4)`,
        )
        .bind(id, sessionId, loggedAt, deletedAt);
    const liveOne = `${suffix}-set-1`;
    const liveTwo = `${suffix}-set-2`;
    const liveThree = `${suffix}-set-3`;
    const deleted = `${suffix}-set-deleted`;
    await env.DB.batch([
      setInsert(liveThree, winner, 30),
      setInsert(liveOne, tieLoser, 10),
      setInsert(liveTwo, lateLoser, 20),
      setInsert(deleted, lateLoser, 40, 999),
      env.DB
        .prepare(
          `INSERT INTO session_load_exports
           (session_id,intervals_ref,load,status,attempts,updated_at)
           VALUES (?1,NULL,50,'disabled',4,600)`,
        )
        .bind(exportWinner),
      env.DB
        .prepare(
          `INSERT INTO session_load_exports
           (session_id,intervals_ref,load,status,attempts,updated_at)
           VALUES (?1,'usable-ref',100,'ok',1,500)`,
        )
        .bind(exportLoser),
      env.DB
        .prepare(
          `INSERT INTO session_load_exports
           (session_id,intervals_ref,load,status,attempts,updated_at)
           VALUES (?1,'moved-ref',125,'ok',2,700)`,
        )
        .bind(movedExportLoser),
    ]);

    const migration = (
      env.TEST_MIGRATIONS as Array<{ name: string; queries: string[] }>
    ).find((candidate) => candidate.name.includes('0029'));
    expect(migration, '0029 migration missing from TEST_MIGRATIONS').toBeTruthy();
    for (const query of migration!.queries) {
      await env.DB.prepare(query).run();
    }

    const aliases = await env.DB
      .prepare(
        `SELECT sa.alias_session_id,sa.canonical_session_id,s.id AS surviving_session_id
         FROM session_aliases AS sa
         JOIN sessions AS s ON s.id = sa.canonical_session_id
         WHERE sa.alias_session_id IN (?1,?2,?3,?4)
         ORDER BY sa.alias_session_id`,
      )
      .bind(tieLoser, lateLoser, exportLoser, movedExportLoser)
      .all<{
        alias_session_id: string;
        canonical_session_id: string;
        surviving_session_id: string;
      }>();
    expect(aliases.results).toEqual([
      {
        alias_session_id: tieLoser,
        canonical_session_id: winner,
        surviving_session_id: winner,
      },
      {
        alias_session_id: lateLoser,
        canonical_session_id: winner,
        surviving_session_id: winner,
      },
      {
        alias_session_id: exportLoser,
        canonical_session_id: exportWinner,
        surviving_session_id: exportWinner,
      },
      {
        alias_session_id: movedExportLoser,
        canonical_session_id: movedExportWinner,
        surviving_session_id: movedExportWinner,
      },
    ]);

    const sessions = await env.DB
      .prepare(
        `SELECT id,user_id,plan_id,day_template_id,date,status,started_at,completed_at,
                perceived_fatigue,notes,created_at,updated_at
         FROM sessions WHERE user_id = ?1 AND date = ?2`,
      )
      .bind(userId, date)
      .all<{
        id: string;
        user_id: string;
        plan_id: string;
        day_template_id: string | null;
        date: string;
        status: string;
        started_at: number | null;
        completed_at: number | null;
        perceived_fatigue: number | null;
        notes: string | null;
        created_at: number;
        updated_at: number;
      }>();
    expect(sessions.results).toEqual([
      {
        id: winner,
        user_id: userId,
        plan_id: promotedPlan,
        day_template_id: promotedDay,
        date,
        status: 'completed',
        started_at: 700,
        completed_at: 900,
        perceived_fatigue: 9,
        notes: 'completed duplicate',
        created_at: 100,
        updated_at: 950,
      },
    ]);

    const meaningfulCanonical = await env.DB
      .prepare('SELECT status,created_at,updated_at FROM sessions WHERE id = ?1')
      .bind(exportWinner)
      .first<{ status: string; created_at: number; updated_at: number }>();
    expect(meaningfulCanonical).toEqual({
      status: 'completed',
      created_at: 300,
      updated_at: 300,
    });

    const sets = await env.DB
      .prepare(
        'SELECT id,session_id,set_index,deleted_at FROM set_logs WHERE id IN (?1,?2,?3,?4) ORDER BY logged_at,id',
      )
      .bind(liveOne, liveTwo, liveThree, deleted)
      .all<{ id: string; session_id: string; set_index: number; deleted_at: number | null }>();
    expect(sets.results).toEqual([
      { id: liveOne, session_id: winner, set_index: 1, deleted_at: null },
      { id: liveTwo, session_id: winner, set_index: 2, deleted_at: null },
      { id: liveThree, session_id: winner, set_index: 3, deleted_at: null },
      { id: deleted, session_id: winner, set_index: 1, deleted_at: 999 },
    ]);

    const retainedExport = await env.DB
      .prepare('SELECT * FROM session_load_exports WHERE session_id = ?1')
      .bind(exportWinner)
      .first<{
        session_id: string;
        intervals_ref: string;
        load: number;
        status: string;
        attempts: number;
      }>();
    expect(retainedExport).toMatchObject({
      intervals_ref: 'usable-ref',
      load: 100,
      status: 'ok',
      attempts: 1,
    });
    expect(
      await env.DB
        .prepare('SELECT * FROM session_load_exports WHERE session_id = ?1')
        .bind(exportLoser)
        .first(),
      ).toBeNull();

    const movedExport = await env.DB
      .prepare('SELECT * FROM session_load_exports WHERE session_id = ?1')
      .bind(movedExportWinner)
      .first<{ session_id: string; intervals_ref: string }>();
    expect(movedExport?.intervals_ref).toBe('moved-ref');

    const promotedSkip = await env.DB
      .prepare(
        `SELECT id,user_id,plan_id,day_template_id,date,status,started_at,completed_at,
                perceived_fatigue,notes,created_at,updated_at
         FROM sessions WHERE id = ?1`,
      )
      .bind(movedExportWinner)
      .first<{
        id: string;
        user_id: string;
        plan_id: string;
        day_template_id: string | null;
        date: string;
        status: string;
        started_at: number | null;
        completed_at: number | null;
        perceived_fatigue: number | null;
        notes: string | null;
        created_at: number;
        updated_at: number;
      }>();
    expect(promotedSkip).toEqual({
      id: movedExportWinner,
      user_id: userId,
      plan_id: promotedPlan,
      day_template_id: promotedDay,
      date: movedExportDate,
      status: 'skipped',
      started_at: null,
      completed_at: null,
      perceived_fatigue: null,
      notes: 'explicit skip',
      created_at: 500,
      updated_at: 650,
    });
    expect(
      await env.DB
        .prepare('SELECT * FROM session_load_exports WHERE session_id = ?1')
        .bind(movedExportLoser)
        .first(),
    ).toBeNull();

    await expect(
      sessionInsert(`${suffix}-duplicate`, date, 500).run(),
    ).rejects.toThrow(/UNIQUE constraint failed/);
    await expect(
      setInsert(`${suffix}-slot-duplicate`, winner, 50).run(),
    ).rejects.toThrow(/UNIQUE constraint failed/);
  });
});
