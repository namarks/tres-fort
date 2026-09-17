import { applyD1Migrations, env } from 'cloudflare:test';
import { beforeAll, expect, it } from 'vitest';
import { createD1UsageObserver } from '../src/db';

const rename = env.TEST_MIGRATIONS.filter((migration) => migration.name === '0045_workouts.sql');
beforeAll(async () => {
  expect(rename).toHaveLength(1);
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS.filter((migration) => migration.name !== '0045_workouts.sql'));
});

it('migrates existing identities, foreign keys, aliases, set pointers and attempt triggers intact', async () => {
  // Historical migrations retain their original vocabulary. The running
  // service requires the fully migrated schema and has no translation layer.
  await env.DB.batch([
    env.DB.prepare("INSERT INTO users (id,apple_sub,created_at) VALUES ('member','member',1)"),
    env.DB.prepare("INSERT INTO plans (id,user_id,name,created_at,updated_at) VALUES ('plan','member','Plan',1,1)"),
    env.DB.prepare("INSERT INTO day_templates (id,plan_id,name,order_index,created_at,updated_at) VALUES ('workout','plan','On demand',0,1,1)"),
    env.DB.prepare("INSERT INTO sessions (id,user_id,plan_id,day_template_id,date,created_at,updated_at) VALUES ('session','member','plan','workout','2026-09-09',1,1)"),
    env.DB.prepare("INSERT INTO template_exercises (id,day_template_id,exercise_id,order_index,target_sets,target_reps,rest_seconds,created_at,updated_at) VALUES ('slot','workout','ex_bench',0,3,5,120,1,1)"),
    env.DB.prepare("INSERT INTO set_logs (id,session_id,exercise_id,template_exercise_id,set_index,weight,reps,logged_at,source) VALUES ('set','session','ex_bench','slot',1,100,5,1,'ios')"),
    env.DB.prepare("INSERT INTO session_aliases (alias_session_id,canonical_session_id) VALUES ('old-session','session')"),
  ]);
  await applyD1Migrations(env.DB, rename);
  expect(await env.DB.prepare("SELECT template_exercise_id FROM set_logs WHERE id='set'").first('template_exercise_id')).toBe('slot');
  expect(await env.DB.prepare("SELECT workout_id FROM sessions WHERE id='session'").first('workout_id')).toBe('workout');
  expect(await env.DB.prepare("SELECT workout_id FROM template_exercises WHERE id='slot'").first('workout_id')).toBe('workout');
  expect(await env.DB.prepare("SELECT canonical_session_id FROM session_aliases WHERE alias_session_id='old-session'").first('canonical_session_id')).toBe('session');
  await env.DB.prepare("UPDATE sessions SET status='discarded' WHERE id='session'").run();
  await env.DB.prepare("UPDATE sessions SET status='planned' WHERE id='session'").run();
  expect(await env.DB.prepare("SELECT attempt FROM sessions WHERE id='session'").first('attempt')).toBe(1);
  expect((await env.DB.prepare('PRAGMA foreign_key_check').all()).results).toEqual([]);
  expect((await env.DB.prepare("SELECT name FROM sqlite_master WHERE name IN ('day_templates','ix_te_day')").all()).results).toEqual([]);
  await expect(env.DB.batch([
    env.DB.prepare("UPDATE plans SET version=version+1 WHERE id='plan'"),
    env.DB.prepare("UPDATE workouts SET name=NULL WHERE id='workout'"),
  ])).rejects.toThrow('NOT NULL');
  expect(await env.DB.prepare("SELECT version FROM plans WHERE id='plan'").first('version')).toBe(1);
});

it('measures independent requests directly without schema discovery queries', async () => {
  await applyD1Migrations(env.DB, rename);
  let probes = 0;
  const binding = new Proxy(env.DB, { get(target, property) {
    if (property === 'prepare') return (query: string) => {
      if (query.includes('PRAGMA')) probes++;
      return target.prepare(query);
    };
    const value = Reflect.get(target, property, target);
    return typeof value === 'function' ? value.bind(target) : value;
  } });
  const first = createD1UsageObserver(binding);
  const second = createD1UsageObserver(binding);
  await first.db.prepare('SELECT id FROM workouts').all();
  await second.db.prepare('SELECT id FROM workouts').all();
  expect(probes).toBe(0);
  expect(first.usage.query_count).toBe(1);
  expect(second.usage.query_count).toBe(1);
});
