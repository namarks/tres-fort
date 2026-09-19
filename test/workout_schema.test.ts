import { applyD1Migrations, env } from 'cloudflare:test';
import { beforeAll, describe, expect, it, vi } from 'vitest';
import { createD1UsageObserver } from '../src/db';
import { workoutDB, workoutSchemaSQL } from '../src/workoutSchema';

const rename = env.TEST_MIGRATIONS.filter((migration) => migration.name === '0045_workouts.sql');
beforeAll(async () => {
  expect(rename).toHaveLength(1);
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS.filter((migration) => migration.name !== '0045_workouts.sql').map(m => ['0053_workout_metadata.sql', '0054_freestyle_sessions.sql'].includes(m.name) ? { ...m, queries: m.queries.map(q => workoutSchemaSQL(q, 'legacy')) } : m));
});

async function fixture() {
  const db = workoutDB(env.DB);
  const userId = crypto.randomUUID();
  const planId = crypto.randomUUID();
  const workoutId = crypto.randomUUID();
  const sessionId = crypto.randomUUID();
  await db.batch([
    db.prepare('INSERT INTO users (id,apple_sub,created_at) VALUES (?,?,1)').bind(userId, userId),
    db.prepare("INSERT INTO plans (id,user_id,name,created_at,updated_at) VALUES (?,?,'Plan',1,1)").bind(planId, userId),
    db.prepare("INSERT INTO workouts (id,plan_id,name,order_index,created_at,updated_at) VALUES (?,?,'On demand',0,1,1)").bind(workoutId, planId),
    db.prepare("INSERT INTO sessions (id,user_id,plan_id,workout_id,date,created_at,updated_at) VALUES (?,?,?,?,'2026-09-09',1,1)")
      .bind(sessionId, userId, planId, workoutId),
  ]);
  return { db, userId, planId, workoutId, sessionId };
}

describe('workout schema rollout', () => {
  it('rewrites only exact SQL identifiers, preserving literals, JSON keys, comments and similar names', () => {
    const sql = `SELECT workout_id, "workout_id", [workout_id], \`workout_id\`, other_workout_id,
      json_object('workout_id', workout_id), 'don''t rename workouts', ?1 FROM workouts
      -- workouts and workout_id stay in comments
      /* workouts */`;
    expect(workoutSchemaSQL(sql, 'legacy')).toBe(`SELECT day_template_id, "day_template_id", [day_template_id], \`day_template_id\`, other_workout_id,
      json_object('workout_id', day_template_id), 'don''t rename workouts', ?1 FROM day_templates
      -- workouts and workout_id stay in comments
      /* workouts */`);
    expect(workoutSchemaSQL(sql, 'workouts')).toBe(sql);
  });

  it('reads the legacy schema with canonical names without rewriting user content', async () => {
    const { db, workoutId, sessionId } = await fixture();
    await db.prepare('UPDATE sessions SET notes=? WHERE id=?').bind('workouts workout_id day_template_id', sessionId).run();
    const session = await db.prepare('SELECT * FROM sessions WHERE id=?').bind(sessionId).first();
    expect(session).toMatchObject({ workout_id: workoutId, notes: 'workouts workout_id day_template_id' });
    expect(session).not.toHaveProperty('day_template_id');
    expect(await db.prepare('SELECT workout_id FROM sessions WHERE id=?').bind(sessionId).first('workout_id')).toBe(workoutId);
    expect(await db.prepare("SELECT json_object('workout_id',workout_id) AS document FROM sessions WHERE id=?")
      .bind(sessionId).first('document')).toBe(JSON.stringify({ workout_id: workoutId }));
  });

  it('executes already-prepared statements after rename and preserves references through rollback', async () => {
    const { db, userId, workoutId, sessionId } = await fixture();
    const slotId = crypto.randomUUID();
    const setId = crypto.randomUUID();
    await db.batch([
      db.prepare("INSERT INTO template_exercises (id,workout_id,exercise_id,order_index,target_sets,target_reps,rest_seconds,created_at,updated_at) VALUES (?,?,'ex_bench',0,3,5,120,1,1)").bind(slotId, workoutId),
      db.prepare("INSERT INTO set_logs (id,session_id,exercise_id,template_exercise_id,set_index,weight,reps,logged_at,source) VALUES (?,?,'ex_bench',?,1,100,5,1,'ios')").bind(setId, sessionId, slotId),
    ]);
    const beforeRename = db.prepare('UPDATE workouts SET name=? WHERE id=?').bind('Renamed workout', workoutId);
    await env.DB.prepare('INSERT INTO session_aliases (alias_session_id,canonical_session_id) VALUES (?,?)').bind('old-session', sessionId).run();
    await applyD1Migrations(env.DB, rename);
    await beforeRename.run();
    expect(await env.DB.prepare('SELECT template_exercise_id FROM set_logs WHERE id=?').bind(setId).first('template_exercise_id')).toBe(slotId);
    await db.prepare("UPDATE sessions SET status='discarded' WHERE id=?").bind(sessionId).run();
    await db.prepare("UPDATE sessions SET status='planned' WHERE id=?").bind(sessionId).run();
    expect(await db.prepare('SELECT attempt FROM sessions WHERE id=?').bind(sessionId).first('attempt')).toBe(1);
    expect(await db.prepare('SELECT name FROM workouts WHERE id=?').bind(workoutId).first('name')).toBe('Renamed workout');
    expect(await db.prepare('SELECT workout_id FROM sessions WHERE id=?').bind(sessionId).first('workout_id')).toBe(workoutId);
    expect((await env.DB.prepare('PRAGMA foreign_key_check').all()).results).toEqual([]);
    expect(await env.DB.prepare('SELECT canonical_session_id FROM session_aliases WHERE alias_session_id=?').bind('old-session').first('canonical_session_id')).toBe(sessionId);
    await env.DB.batch([
      env.DB.prepare('ALTER TABLE workouts RENAME TO day_templates'),
      env.DB.prepare('ALTER TABLE template_exercises RENAME COLUMN workout_id TO day_template_id'),
      env.DB.prepare('ALTER TABLE sessions RENAME COLUMN workout_id TO day_template_id'),
      env.DB.prepare('DROP INDEX ix_te_workout'),
      env.DB.prepare('CREATE INDEX ix_te_day ON template_exercises(day_template_id,order_index)'),
    ]);
    expect(await db.prepare('SELECT workout_id FROM sessions WHERE user_id=?').bind(userId).first('workout_id')).toBe(workoutId);
    expect((await env.DB.prepare('PRAGMA foreign_key_check').all()).results).toEqual([]);
  });

  it('retries the whole atomic batch exactly once across a cached-schema change', async () => {
    const { db, workoutId, planId } = await fixture();
    await applyD1Migrations(env.DB, rename);
    await db.batch([
      db.prepare('UPDATE plans SET version=version+1 WHERE id=?').bind(planId),
      db.prepare('UPDATE workouts SET name=? WHERE id=?').bind('After rename', workoutId),
    ]);
    expect(await env.DB.prepare('SELECT version FROM plans WHERE id=?').bind(planId).first('version')).toBe(2);
    expect(await env.DB.prepare('SELECT name FROM workouts WHERE id=?').bind(workoutId).first('name')).toBe('After rename');
  });

  it('preserves transaction rollback and does not retry an unrelated failure', async () => {
    const { db, planId, workoutId } = await fixture();
    await expect(db.batch([
      db.prepare('UPDATE plans SET version=version+1 WHERE id=?').bind(planId),
      db.prepare('UPDATE workouts SET name=NULL WHERE id=?').bind(workoutId),
    ])).rejects.toThrow('NOT NULL');
    expect(await env.DB.prepare('SELECT version FROM plans WHERE id=?').bind(planId).first('version')).toBe(1);
    let calls = 0;
    const broken = workoutDB(new Proxy(env.DB, { get(target, property) {
      if (property === 'batch') return () => { calls++; throw new Error('network response unavailable'); };
      const value = Reflect.get(target, property, target);
      return typeof value === 'function' ? value.bind(target) : value;
    } }));
    await expect(broken.batch([broken.prepare('UPDATE workouts SET name=? WHERE id=?').bind('No retry', workoutId)]))
      .rejects.toThrow('network response unavailable');
    expect(calls).toBe(1);
  });

  it('shares schema metadata across request observers without sharing their accounting', async () => {
    await fixture();
    let probes = 0;
    const binding = new Proxy(env.DB, { get(target, property) {
      if (property === 'prepare') return (query: string) => {
        if (query === 'PRAGMA table_info(sessions)') probes++;
        return target.prepare(query);
      };
      const value = Reflect.get(target, property, target);
      return typeof value === 'function' ? value.bind(target) : value;
    } });
    const first = createD1UsageObserver(binding);
    const second = createD1UsageObserver(binding);
    await workoutDB(first.db).prepare('SELECT id FROM workouts').all();
    await workoutDB(second.db).prepare('SELECT id FROM workouts').all();
    expect(probes).toBe(1);
    expect(first.usage.query_count).toBe(2);
    expect(second.usage.query_count).toBe(1);
  });

  it('expires the schema cache after sixty seconds and preserves raw column names', async () => {
    const { db, workoutId, sessionId } = await fixture();
    await applyD1Migrations(env.DB, rename);
    const date = vi.spyOn(Date, 'now').mockReturnValue(Date.now() + 60_001);
    try {
      expect(await db.prepare('SELECT workout_id FROM sessions WHERE id=?').bind(sessionId).raw({ columnNames: true }))
        .toEqual([['workout_id'], [workoutId]]);
    } finally { date.mockRestore(); }
  });
});
