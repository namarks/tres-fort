import { applyD1Migrations, env } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';

type Mutation = 'insert' | 'correction' | 'soft_delete';

interface WriteCount {
  current: number;
  proposed: number;
  delta: number;
}

const USER_ID = 'p0-user';
const SESSION_ID = 'p0-session';
const EXERCISE_ID = 'ex_back_squat';
const SET_ID = 'p0-set';
const LOGGED_AT = 1_788_537_600_000;

function compare(current: number, proposed: number): WriteCount {
  return { current, proposed, delta: proposed - current };
}

async function rowsWritten(statement: D1PreparedStatement): Promise<number> {
  const result = await statement.run();
  const count = result.meta.rows_written;
  expect(Number.isInteger(count)).toBe(true);
  expect(count).toBeGreaterThan(0);
  return count;
}

async function insertAudit(
  table: 'p0_current_audit_log' | 'p0_proposed_audit_log',
  mutation: Mutation,
): Promise<number> {
  const tool =
    mutation === 'insert'
      ? 'log_set'
      : mutation === 'correction'
        ? 'correct_set'
        : 'delete_set';
  return rowsWritten(
    env.DB.prepare(
      `INSERT INTO ${table} (id,user_id,actor,tool,args,result,created_at)
       VALUES (?1,?2,'mcp',?3,?4,?5,?6)`,
    ).bind(
      `p0-audit-${mutation}`,
      USER_ID,
      tool,
      JSON.stringify({ set_id: SET_ID }),
      'ok',
      LOGGED_AT,
    ),
  );
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);

  // These paired tables isolate index cost from application behavior and owner
  // data. The current set model carries the production secondary indexes:
  // session lookup, exercise/time lookup, and the live-slot unique index. The
  // proposed final P1/P3 model adds (user_id, updated_at), replaces the existing
  // exercise/time index with (user_id, exercise_id, logged_at), and preserves
  // the other two indexes. The audit pair differs only by P3's
  // (user_id, actor, created_at) index.
  const ddl = [
    `CREATE TABLE p0_current_set_logs (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL,
      exercise_id TEXT NOT NULL,
      template_exercise_id TEXT,
      set_index INTEGER NOT NULL,
      weight REAL NOT NULL,
      reps INTEGER NOT NULL,
      rpe REAL,
      is_warmup INTEGER NOT NULL DEFAULT 0,
      notes TEXT,
      logged_at INTEGER NOT NULL,
      source TEXT NOT NULL,
      deleted_at INTEGER,
      duration_s INTEGER,
      is_timed INTEGER NOT NULL DEFAULT 0
    )`,
    `CREATE INDEX p0_current_ix_sets_session
      ON p0_current_set_logs(session_id)`,
    `CREATE INDEX p0_current_ix_sets_ex_time
      ON p0_current_set_logs(exercise_id, logged_at)`,
    `CREATE UNIQUE INDEX p0_current_ux_set_slot
      ON p0_current_set_logs(session_id, exercise_id, set_index, is_warmup)
      WHERE deleted_at IS NULL`,

    `CREATE TABLE p0_proposed_set_logs (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL,
      session_id TEXT NOT NULL,
      exercise_id TEXT NOT NULL,
      template_exercise_id TEXT,
      set_index INTEGER NOT NULL,
      weight REAL NOT NULL,
      reps INTEGER NOT NULL,
      rpe REAL,
      is_warmup INTEGER NOT NULL DEFAULT 0,
      notes TEXT,
      logged_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      source TEXT NOT NULL,
      deleted_at INTEGER,
      duration_s INTEGER,
      is_timed INTEGER NOT NULL DEFAULT 0
    )`,
    `CREATE INDEX p0_proposed_ix_sets_session
      ON p0_proposed_set_logs(session_id)`,
    `CREATE INDEX p0_proposed_ix_sets_user_updated
      ON p0_proposed_set_logs(user_id, updated_at)`,
    `CREATE INDEX p0_proposed_ix_sets_user_ex_time
      ON p0_proposed_set_logs(user_id, exercise_id, logged_at)`,
    `CREATE UNIQUE INDEX p0_proposed_ux_set_slot
      ON p0_proposed_set_logs(session_id, exercise_id, set_index, is_warmup)
      WHERE deleted_at IS NULL`,

    `CREATE TABLE p0_current_audit_log (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL,
      actor TEXT NOT NULL,
      tool TEXT NOT NULL,
      args TEXT,
      result TEXT,
      created_at INTEGER NOT NULL
    )`,
    `CREATE TABLE p0_proposed_audit_log (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL,
      actor TEXT NOT NULL,
      tool TEXT NOT NULL,
      args TEXT,
      result TEXT,
      created_at INTEGER NOT NULL
    )`,
    `CREATE INDEX p0_proposed_ix_audit_user_actor_created
      ON p0_proposed_audit_log(user_id, actor, created_at)`,
  ];
  for (const statement of ddl) {
    await env.DB.prepare(statement).run();
  }
});

describe('P0 D1 index write amplification', () => {
  it('measures current versus proposed index cost on canonical MCP set mutations', async () => {
    const setWrites: Record<Mutation, WriteCount> = {} as Record<Mutation, WriteCount>;
    const auditWrites: Record<Mutation, WriteCount> = {} as Record<Mutation, WriteCount>;

    const currentInsert = await rowsWritten(
      env.DB.prepare(
        `INSERT INTO p0_current_set_logs
         (id,session_id,exercise_id,template_exercise_id,set_index,weight,reps,rpe,is_warmup,notes,logged_at,source,duration_s,is_timed,deleted_at)
         VALUES (?1,?2,?3,NULL,1,225,5,8,0,NULL,?4,'mcp',NULL,0,NULL)`,
      ).bind(SET_ID, SESSION_ID, EXERCISE_ID, LOGGED_AT),
    );
    const proposedInsert = await rowsWritten(
      env.DB.prepare(
        `INSERT INTO p0_proposed_set_logs
         (id,user_id,session_id,exercise_id,template_exercise_id,set_index,weight,reps,rpe,is_warmup,notes,logged_at,updated_at,source,duration_s,is_timed,deleted_at)
         VALUES (?1,?2,?3,?4,NULL,1,225,5,8,0,NULL,?5,?5,'mcp',NULL,0,NULL)`,
      ).bind(SET_ID, USER_ID, SESSION_ID, EXERCISE_ID, LOGGED_AT),
    );
    setWrites.insert = compare(currentInsert, proposedInsert);

    const currentCorrection = await rowsWritten(
      env.DB.prepare('UPDATE p0_current_set_logs SET weight = ?2 WHERE id = ?1').bind(
        SET_ID,
        230,
      ),
    );
    const proposedCorrection = await rowsWritten(
      env.DB.prepare(
        'UPDATE p0_proposed_set_logs SET weight = ?2, updated_at = ?3 WHERE id = ?1',
      ).bind(SET_ID, 230, LOGGED_AT + 1_000),
    );
    setWrites.correction = compare(currentCorrection, proposedCorrection);

    const currentSoftDelete = await rowsWritten(
      env.DB.prepare('UPDATE p0_current_set_logs SET deleted_at = ?2 WHERE id = ?1').bind(
        SET_ID,
        LOGGED_AT + 2_000,
      ),
    );
    const proposedSoftDelete = await rowsWritten(
      env.DB.prepare(
        'UPDATE p0_proposed_set_logs SET deleted_at = ?2, updated_at = ?2 WHERE id = ?1',
      ).bind(SET_ID, LOGGED_AT + 2_000),
    );
    setWrites.soft_delete = compare(currentSoftDelete, proposedSoftDelete);

    for (const mutation of ['insert', 'correction', 'soft_delete'] as const) {
      const current = await insertAudit('p0_current_audit_log', mutation);
      const proposed = await insertAudit('p0_proposed_audit_log', mutation);
      auditWrites[mutation] = compare(current, proposed);
    }

    // Assert only the billing-relevant deltas. Absolute counts also include
    // SQLite's table/primary-key work and are useful evidence, but are not the
    // contract this fixture protects.
    expect(setWrites).toEqual({
      insert: { current: expect.any(Number), proposed: expect.any(Number), delta: 1 },
      correction: { current: expect.any(Number), proposed: expect.any(Number), delta: 1 },
      soft_delete: { current: expect.any(Number), proposed: expect.any(Number), delta: 1 },
    });
    expect(auditWrites).toEqual({
      insert: { current: expect.any(Number), proposed: expect.any(Number), delta: 1 },
      correction: { current: expect.any(Number), proposed: expect.any(Number), delta: 1 },
      soft_delete: { current: expect.any(Number), proposed: expect.any(Number), delta: 1 },
    });

    const combined = Object.fromEntries(
      (['insert', 'correction', 'soft_delete'] as const).map((mutation) => [
        mutation,
        compare(
          setWrites[mutation].current + auditWrites[mutation].current,
          setWrites[mutation].proposed + auditWrites[mutation].proposed,
        ),
      ]),
    ) as Record<Mutation, WriteCount>;
    expect(Object.values(combined).map((count) => count.delta)).toEqual([2, 2, 2]);

    console.info(
      JSON.stringify({
        event: 'd1_index_write_amplification',
        modeled_indexes: {
          current_set_logs: [
            'session_id',
            'exercise_id, logged_at',
            'session_id, exercise_id, set_index, is_warmup WHERE deleted_at IS NULL UNIQUE',
          ],
          proposed_set_logs: [
            'session_id',
            'user_id, updated_at',
            'user_id, exercise_id, logged_at',
            'session_id, exercise_id, set_index, is_warmup WHERE deleted_at IS NULL UNIQUE',
          ],
          current_audit_log: [],
          proposed_audit_log: ['user_id, actor, created_at'],
        },
        rows_written: { set_logs: setWrites, audit_log: auditWrites, combined },
      }),
    );
  });
});
