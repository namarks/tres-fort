import { applyD1Migrations, env } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import {
  getOrCreateSession,
  patchSet,
  setPlannedSession,
  skipPlannedSession,
  updatePlanTree,
} from '../src/db';

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
      'SELECT sl.* FROM set_logs sl JOIN sessions s ON s.id = sl.session_id',
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
