import { applyD1Migrations, env } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';

import { findRecentMatchingSet, getHistory } from '../src/db';
import { runWorkoutWriteBatch } from '../src/workout-write-fence';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

async function queryPlan(sql: string, bindings: unknown[]) {
  const plan = await env.DB.prepare(`EXPLAIN QUERY PLAN ${sql}`)
    .bind(...bindings)
    .all<{ detail: string }>();
  return plan.results.map((row) => row.detail);
}

describe('P3 member-first hot-path indexes', () => {
  it('installs the final indexes and removes the cross-member exercise index', async () => {
    const indexes = await env.DB.prepare(
      `SELECT name, sql FROM sqlite_master
        WHERE type = 'index'
          AND name IN (
            'ix_sets_ex_time',
            'ix_sets_user_ex_time',
            'ix_audit_user_actor_created',
            'ix_oauth_tokens_user'
          )
        ORDER BY name`,
    ).all<{ name: string; sql: string }>();

    expect(indexes.results.map((row) => row.name)).toEqual([
      'ix_audit_user_actor_created',
      'ix_oauth_tokens_user',
      'ix_sets_user_ex_time',
    ]);

    const columns = async (indexName: string) =>
      (
        await env.DB.prepare(`PRAGMA index_info('${indexName}')`).all<{
          seqno: number;
          name: string;
        }>()
      ).results
        .sort((a, b) => a.seqno - b.seqno)
        .map((row) => row.name);

    expect(await columns('ix_sets_user_ex_time')).toEqual([
      'user_id',
      'exercise_id',
      'logged_at',
    ]);
    expect(await columns('ix_audit_user_actor_created')).toEqual([
      'user_id',
      'actor',
      'created_at',
    ]);
    expect(await columns('ix_oauth_tokens_user')).toEqual(['user_id']);
  });

  it('uses the named member-first indexes for every P3 hot query', async () => {
    const cases = [
      {
        expected: 'ix_oauth_tokens_user',
        plan: await queryPlan(
          `SELECT 1 AS x FROM oauth_tokens
            WHERE refresh_token IS NOT NULL AND user_id = ?1 LIMIT 1`,
          ['member-a'],
        ),
      },
      {
        expected: 'ix_oauth_tokens_user',
        plan: await queryPlan(
          `SELECT 1 AS x FROM oauth_tokens
            WHERE refresh_token IS NOT NULL AND (user_id = ?1 OR user_id IS NULL)
            LIMIT 1`,
          ['member-a'],
        ),
      },
      {
        expected: 'ix_audit_user_actor_created',
        plan: await queryPlan(
          `SELECT MAX(created_at) AS t FROM audit_log
            WHERE user_id = ?1 AND actor = 'mcp'`,
          ['member-a'],
        ),
      },
      {
        expected: 'ix_sets_user_ex_time',
        plan: await queryPlan(
          `SELECT sl.*, s.date AS session_date FROM set_logs sl
            JOIN sessions s ON s.id = sl.session_id
            WHERE sl.user_id = ?1 AND s.user_id = ?1
              AND sl.exercise_id = ?2
              AND sl.deleted_at IS NULL AND sl.is_warmup = 0
              AND sl.logged_at BETWEEN ?3 AND ?4
            ORDER BY sl.logged_at`,
          ['member-a', 'ex_bench', 0, Date.now()],
        ),
      },
      {
        expected: 'ix_sets_user_ex_time',
        plan: await queryPlan(
          `SELECT sl.* FROM set_logs sl
            JOIN sessions s ON s.id = sl.session_id
            WHERE sl.user_id = ?1 AND s.user_id = ?1
              AND sl.exercise_id = ?2
              AND sl.weight = ?3 AND sl.reps = ?4 AND sl.is_warmup = ?5
              AND sl.source <> 'mcp' AND sl.deleted_at IS NULL
              AND sl.logged_at >= ?6
              AND (?7 IS NULL OR sl.set_index = ?7)
              AND (?8 IS NULL OR sl.duration_s = ?8)
            ORDER BY sl.logged_at DESC LIMIT 1`,
          ['member-a', 'ex_bench', 135, 5, 0, 0, null, null],
        ),
      },
    ];

    for (const testCase of cases) {
      expect(
        testCase.plan.some((detail) => detail.includes(testCase.expected)),
        testCase.plan.join('\n'),
      ).toBe(true);
    }
  });

  it('keeps exercise history and recent-set matching tenant-isolated', async () => {
    const timestamp = Date.now();
    const userA = crypto.randomUUID();
    const userB = crypto.randomUUID();
    const planA = crypto.randomUUID();
    const planB = crypto.randomUUID();
    const sessionA = crypto.randomUUID();
    const sessionB = crypto.randomUUID();
    const setA = crypto.randomUUID();
    const setB = crypto.randomUUID();
    const mismatchedSet = crypto.randomUUID();

    await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO users (id,apple_sub,display_name,created_at)
         VALUES (?1,?2,'P3 A',?3)`,
      ).bind(userA, `sub-${userA}`, timestamp),
      env.DB.prepare(
        `INSERT INTO users (id,apple_sub,display_name,created_at)
         VALUES (?1,?2,'P3 B',?3)`,
      ).bind(userB, `sub-${userB}`, timestamp),
      env.DB.prepare(
        `INSERT INTO plans (id,user_id,name,status,version,created_at,updated_at)
         VALUES (?1,?2,'P3 A','active',1,?3,?3)`,
      ).bind(planA, userA, timestamp),
      env.DB.prepare(
        `INSERT INTO plans (id,user_id,name,status,version,created_at,updated_at)
         VALUES (?1,?2,'P3 B','active',1,?3,?3)`,
      ).bind(planB, userB, timestamp),
      env.DB.prepare(
        `UPDATE workout_write_fence
            SET enabled = 1, activated_at = ?1
          WHERE id = 1 AND enabled = 0`,
      ).bind(timestamp),
    ]);

    // Inject one deliberately inconsistent ownership row under the same
    // transaction-local permit required by the active production fence. This
    // bypasses only service-layer ownership validation so the read boundary is
    // tested against storage corruption without weakening the write guard.
    await runWorkoutWriteBatch(env.DB, [
      env.DB.prepare(
        `INSERT INTO sessions (id,user_id,plan_id,date,status,created_at,updated_at)
         VALUES (?1,?2,?3,'2026-09-06','completed',?4,?4)`,
      ).bind(sessionA, userA, planA, timestamp),
      env.DB.prepare(
        `INSERT INTO sessions (id,user_id,plan_id,date,status,created_at,updated_at)
         VALUES (?1,?2,?3,'2026-09-07','completed',?4,?4)`,
      ).bind(sessionB, userB, planB, timestamp),
      env.DB.prepare(
        `INSERT INTO set_logs
           (id,user_id,session_id,exercise_id,set_index,weight,reps,logged_at,updated_at,source)
         VALUES (?1,?2,?3,'ex_bench',1,135,5,?4,?4,'ios')`,
      ).bind(setA, userA, sessionA, timestamp),
      env.DB.prepare(
        `INSERT INTO set_logs
           (id,user_id,session_id,exercise_id,set_index,weight,reps,logged_at,updated_at,source)
         VALUES (?1,?2,?3,'ex_bench',1,135,5,?4,?4,'ios')`,
      ).bind(setB, userB, sessionB, timestamp),
      env.DB.prepare(
        `INSERT INTO set_logs
           (id,user_id,session_id,exercise_id,set_index,weight,reps,logged_at,updated_at,source)
         VALUES (?1,?2,?3,'ex_bench',2,135,5,?4,?4,'ios')`,
      ).bind(mismatchedSet, userA, sessionB, timestamp + 1),
    ]);

    const history = await getHistory(env.DB, userA, 'ex_bench', 0, timestamp + 1);
    expect(history.sets.map((set) => set.id)).toEqual([setA]);
    expect(history.by_session.map((session) => session.date)).toEqual(['2026-09-06']);

    const recent = await findRecentMatchingSet(env.DB, userA, {
      exercise_id: 'ex_bench',
      weight: 135,
      reps: 5,
      is_warmup: false,
    });
    expect(recent?.id).toBe(setA);
    expect(recent?.user_id).toBe(userA);
    expect(
      await env.DB.prepare('SELECT COUNT(*) AS count FROM workout_write_permit').first(),
    ).toEqual({ count: 0 });
  });
});
