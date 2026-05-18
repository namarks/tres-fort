import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';

const BASE = 'https://lift-coach.test';
const TOKEN = 'test-mcp-token';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

let id = 0;
async function call(name: string, args: unknown) {
  const r = await SELF.fetch(`${BASE}/mcp`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', Authorization: `Bearer ${TOKEN}` },
    body: JSON.stringify({ jsonrpc: '2.0', id: ++id, method: 'tools/call', params: { name, arguments: args } }),
  });
  const body = await r.json<any>();
  const text = body.result.content[0].text as string;
  try {
    return JSON.parse(text);
  } catch {
    return { error: text };
  }
}

describe('mcp write tools', () => {
  it('builds, mutates, and audits the plan via chat-style calls', async () => {
    // 1. build a plan from scratch
    const built = await call('update_plan', {
      name: 'Upper/Lower',
      days: [
        {
          day_label: 'A',
          name: 'Upper A',
          exercises: [
            { exercise: 'bench', target_sets: 3, target_reps: 5, target_reps_max: 8 },
            { exercise: 'barbell row', target_sets: 3, target_reps: 8 },
          ],
        },
        {
          day_label: 'B',
          name: 'Lower B',
          exercises: [
            { exercise: 'squat', target_sets: 3, target_reps: 5 },
            { exercise: 'rdl', target_sets: 3, target_reps: 8 },
          ],
        },
      ],
    });
    expect(built.conflict).toBe(false);
    expect(built.plan.days).toHaveLength(2);
    const v = built.plan.version;
    expect(v).toBeGreaterThan(1);

    // 2. optimistic concurrency: a stale expected_version conflicts
    const stale = await call('update_plan', { name: 'x', expected_version: 1, days: [] });
    expect(stale).toMatchObject({ conflict: true, current_version: v });

    // 3. correct expected_version succeeds
    const fresh = await call('update_plan', {
      expected_version: v,
      name: 'Upper/Lower v2',
      days: built.plan.days.map((d: any) => ({
        day_label: d.day_label,
        name: d.name,
        exercises: d.exercises.map((e: any) => ({
          exercise: e.exercise_id,
          target_sets: e.target_sets,
          target_reps: e.target_reps,
        })),
      })),
    });
    expect(fresh.conflict).toBe(false);
    expect(fresh.plan.version).toBeGreaterThan(v);

    // 4. swap RDL -> front squat on day B
    const swap = await call('swap_exercise', {
      day: 'B',
      from_exercise: 'rdl',
      to_exercise: 'front squat',
    });
    expect(swap.exercise_id).toBe('ex_front_squat');

    // 5. add a deadlift day, then an exercise to it
    const day = await call('add_day', { name: 'Deadlift Day', day_label: 'D' });
    expect(day.day_label).toBe('D');
    const added = await call('add_exercise', {
      day: 'D',
      exercise: 'deadlift',
      target_sets: 3,
      target_reps: 5,
    });
    expect(added.exercise_id).toBe('ex_deadlift');

    // 6. patch that slot
    const patched = await call('update_exercise', {
      day: 'D',
      exercise: 'deadlift',
      patch: { target_sets: 5, target_weight: 315 },
    });
    expect(patched.target_sets).toBe(5);
    expect(patched.target_weight).toBe(315);

    // 7. log a set (auto-creates today's session) + complete it
    const logged = await call('log_set', { exercise: 'bench', weight: 225, reps: 8, rpe: 8 });
    expect(logged.deduped).toBe(false);
    expect(logged.set.source).toBe('mcp');
    const done = await call('log_workout_complete', { perceived_fatigue: 7 });
    expect(done.status).toBe('completed');
    expect(done.perceived_fatigue).toBe(7);

    // 8. "I'm beat — adjust" scales day A's sets and bumps version
    const before = (await call('get_current_plan', {})).version;
    const adj = await call('adjust_today', {
      intent: 'reduce_volume',
      magnitude: 'moderate',
      day_label: 'A',
      reason: 'slept 4h, HRV tanked',
    });
    expect(adj.changes.length).toBeGreaterThan(0);
    expect((await call('get_current_plan', {})).version).toBeGreaterThan(before);

    // 9. explicit coaching note
    expect(await call('add_note', { scope: 'general', body: 'deload next week' })).toMatchObject({
      ok: true,
    });

    // 10. audit trail + Claude notes were written
    const audits = await env.DB.prepare(
      "SELECT COUNT(*) AS c FROM audit_log WHERE actor='mcp'",
    ).first<{ c: number }>();
    expect(audits!.c).toBeGreaterThanOrEqual(9);
    const notes = await env.DB.prepare(
      "SELECT COUNT(*) AS c FROM notes WHERE author='claude'",
    ).first<{ c: number }>();
    expect(notes!.c).toBeGreaterThan(0);
    const reason = await env.DB.prepare(
      "SELECT body FROM notes WHERE body LIKE '%HRV tanked%' LIMIT 1",
    ).first<{ body: string }>();
    expect(reason?.body).toContain('reduce_volume');
  });

  it('reports unknown exercises instead of failing silently', async () => {
    const r = await call('update_plan', {
      name: 'bad',
      days: [{ name: 'X', exercises: [{ exercise: 'moon press', target_sets: 3, target_reps: 5 }] }],
    });
    expect(JSON.stringify(r)).toContain('unknown_exercise');
  });
});
