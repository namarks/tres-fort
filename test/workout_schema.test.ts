import { applyD1Migrations, env } from 'cloudflare:test';
import { beforeAll, expect, it } from 'vitest';
import { createD1UsageObserver } from '../src/db';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS.filter(m => m.name < '0045'));
});

it('migrates existing identities, history and attempt triggers to the canonical schema', async () => {
  const db = env.DB;
  await db.batch([
    db.prepare("INSERT INTO users (id,apple_sub,created_at) VALUES ('u','u',1)"),
    db.prepare("INSERT INTO plans (id,user_id,name,created_at,updated_at) VALUES ('p','u','Plan',1,1)"),
    db.prepare("INSERT INTO day_templates (id,plan_id,name,order_index,created_at,updated_at) VALUES ('w','p','Lift',0,1,1)"),
    db.prepare("INSERT INTO template_exercises (id,day_template_id,exercise_id,order_index,target_sets,target_reps,rest_seconds,created_at,updated_at) VALUES ('slot','w','ex_bench',0,3,5,120,1,1)"),
    db.prepare("INSERT INTO sessions (id,user_id,plan_id,day_template_id,date,created_at,updated_at) VALUES ('s','u','p','w','2026-09-09',1,1)"),
    db.prepare("INSERT INTO set_logs (id,session_id,exercise_id,template_exercise_id,set_index,weight,reps,logged_at,source) VALUES ('set','s','ex_bench','slot',1,100,5,1,'ios')"),
    db.prepare("INSERT INTO session_aliases (alias_session_id,canonical_session_id) VALUES ('old-session','s')"),
    db.prepare("INSERT INTO audit_log (id,user_id,actor,tool,args,created_at) VALUES ('audit','u','mcp','add_day','{\"day_template_id\":\"w\"}',1)"),
  ]);
  await applyD1Migrations(db, env.TEST_MIGRATIONS.filter(m => m.name >= '0045'));
  expect(await db.prepare("SELECT workout_id FROM sessions WHERE id='s'").first('workout_id')).toBe('w');
  expect(await db.prepare("SELECT workout_id FROM template_exercises WHERE id='slot'").first('workout_id')).toBe('w');
  expect(await db.prepare("SELECT template_exercise_id,weight,reps FROM set_logs WHERE id='set'").first())
    .toEqual({ template_exercise_id: 'slot', weight: 100, reps: 5 });
  expect(await db.prepare("SELECT canonical_session_id FROM session_aliases WHERE alias_session_id='old-session'").first('canonical_session_id')).toBe('s');
  expect(await db.prepare("SELECT tool,args FROM audit_log WHERE id='audit'").first())
    .toEqual({ tool: 'add_day', args: '{"day_template_id":"w"}' });
  expect(await db.prepare("SELECT version FROM plans WHERE id='p'").first('version')).toBe(1);
  await db.prepare("UPDATE sessions SET status='discarded' WHERE id='s'").run();
  await db.prepare("UPDATE sessions SET status='planned' WHERE id='s'").run();
  expect(await db.prepare("SELECT attempt FROM sessions WHERE id='s'").first('attempt')).toBe(1);
  expect((await db.prepare('PRAGMA foreign_key_check').all()).results).toEqual([]);
  expect((await db.prepare("SELECT name FROM sqlite_master WHERE name IN ('day_templates','ix_te_day')").all()).results).toEqual([]);
  expect((await db.prepare("SELECT name FROM sqlite_master WHERE name IN ('workouts','ix_te_workout') ORDER BY name").all()).results)
    .toEqual([{ name: 'ix_te_workout' }, { name: 'workouts' }]);

  const observer = createD1UsageObserver(db);
  expect(await observer.db.prepare('SELECT workout_id FROM sessions').first('workout_id')).toBe('w');
  expect(observer.usage.query_count).toBe(1);
  await expect(db.batch([
    db.prepare("UPDATE plans SET version=version+1 WHERE id='p'"),
    db.prepare("UPDATE workouts SET name=NULL WHERE id='w'"),
  ])).rejects.toThrow('NOT NULL');
  expect(await db.prepare("SELECT version FROM plans WHERE id='p'").first('version')).toBe(1);
});
