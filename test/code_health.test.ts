import { applyD1Migrations, env } from 'cloudflare:test';
import { afterEach, beforeAll, expect, it, vi } from 'vitest';
import { addDays, createD1UsageObserver, createPlan, getRideConflicts, updatePlanTree } from '../src/db';
import { handleMcp } from '../src/mcp/server';


const TODAY = '2026-09-14';
const NOTES = 'Member words: "keep this"\n  indented line — très fort';
let userId: string;
let completedId: string;

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
  const db = env.DB;
  userId = crypto.randomUUID();
  await db.prepare('INSERT INTO users (id, apple_sub, created_at) VALUES (?, ?, 1)').bind(userId, userId).run();
  await createPlan(env.DB, userId, 'Performance fixture');
  const built = await updatePlanTree(env.DB, userId, {
    name: 'Performance fixture', workouts: [{ name: 'Lift', day_label: 'A',
      exercises: [{ exercise: 'bench', target_sets: 3, target_reps: 5 }] }],
  });
  if (!('plan' in built)) throw new Error('fixture_plan_missing');
  const plan = built.plan;
  const workoutId = plan.workouts[0]!.id;
  await db.prepare('UPDATE plans SET meta = ? WHERE id = ?').bind(JSON.stringify({
    schedule: { version: 1, week: { mon: workoutId } },
  }), plan.id).run();
  // Seven recent rows plus an older completed session exercise the maximum
  // brief fan-out. A discarded/deleted set must not leak into its summary.
  for (let daysAgo = 1; daysAgo <= 8; daysAgo++) {
    const sessionId = crypto.randomUUID();
    if (daysAgo === 8) completedId = sessionId;
    await db.prepare(`INSERT INTO sessions
      (id,user_id,plan_id,workout_id,date,status,notes,created_at,updated_at)
      VALUES (?,?,?,?,?,?,?,1,1)`).bind(sessionId, userId, plan.id, workoutId,
      addDays(TODAY, -daysAgo), daysAgo === 8 ? 'completed' : 'skipped', NOTES).run();
    for (let index = 1; index <= 2; index++) {
      await db.prepare(`INSERT INTO set_logs
        (id,user_id,session_id,exercise_id,set_index,weight,reps,logged_at,source,deleted_at)
        VALUES (?,?,?,'ex_bench',?,100,5,?,'mcp',?)`)
        .bind(crypto.randomUUID(), userId, sessionId, index, index, index === 2 ? 3 : null).run();
    }
  }
  await db.prepare(`INSERT INTO external_events
    (id,user_id,source,external_id,date,kind,title,training_load,planned_duration_sec,synced_at)
    VALUES ('performance-ride',?,'intervals','performance-ride',?,'ride','Long ride',160,10000,1)`)
    .bind(userId, TODAY).run();
  // Prime only the physical-schema metadata. It is not a per-request query.
  await db.prepare('SELECT id FROM workouts LIMIT 1').all();
});

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

it('bounds conflict-read work while retaining the real scheduling result', async () => {
  const observer = createD1UsageObserver(env.DB);
  const conflicts = await getRideConflicts(observer.db, userId, TODAY, addDays(TODAY, 28), TODAY);
  expect(conflicts).toEqual([{ date: TODAY, conflicts: ['performance-ride'], severity: 'clash' }]);
  expect(observer.usage.rows_written).toBe(0);
  console.log('code-health conflict reads', observer.usage);
  expect(observer.usage.query_count).toBeLessThanOrEqual(4);
});

it('bounds the eight-session coaching brief and retains text, tombstones and older completion context', async () => {
  // The brief's civil-date boundary uses new Date(), not only Date.now().
  vi.setSystemTime(new Date(`${TODAY}T12:00:00Z`));
  const observer = createD1UsageObserver(env.DB);
  const result = await handleMcp({ jsonrpc: '2.0', id: 7, method: 'tools/call',
    params: { name: 'get_coach_brief', arguments: {} } }, { ...env, DB: observer.db }, userId);
  const envelope = result.json as { result: { content: { type: string; text: string }[]; isError?: boolean } };
  expect(result.status).toBe(200);
  expect(envelope.result.isError).not.toBe(true);
  expect(envelope.result.content[0]!.type).toBe('text');
  // Compact the outer object only. Member-authored whitespace inside the
  // Markdown/JSON brief remains meaningful and must survive decoding.
  expect(envelope.result.content[0]!.text).not.toContain('\n');
  const payload = JSON.parse(envelope.result.content[0]!.text);
  const brief = JSON.parse(payload.brief.match(/```json\n([\s\S]*?)\n```/)[1]);
  expect(brief.recent_sessions).toHaveLength(7);
  expect(brief.last_completed_session).toMatchObject({ id: completedId, notes: NOTES,
    logged_working_sets: 1 });
  for (const session of brief.recent_sessions) expect(session.logged_working_sets).toBe(1);
  expect(brief.active_plan).not.toHaveProperty('days');
  expect(brief.ride_conflicts).toEqual([{ date: TODAY, conflicts: ['performance-ride'], severity: 'clash' }]);
  expect(observer.usage.rows_written).toBe(0);
  console.log('code-health brief reads', observer.usage);
  expect(observer.usage.query_count).toBeLessThanOrEqual(15);
});
