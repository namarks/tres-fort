/**
 * PR A bug fixes:
 *  - #5 order_index determinism: an explicit colliding order_index is
 *    densified so a day never holds duplicate indices.
 *  - last_session open question: get_today_workout exposes
 *    last_completed_session (most recent COMPLETED) distinct from
 *    last_session (most recent of any non-discarded status).
 */
import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';

const BASE = 'https://tres-forte.test';
const TOKEN = 'test-mcp-token';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

let id = 0;
async function call(name: string, args: unknown) {
  const r = await SELF.fetch(`${BASE}/mcp`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', Authorization: `Bearer ${TOKEN}` },
    body: JSON.stringify({
      jsonrpc: '2.0',
      id: ++id,
      method: 'tools/call',
      params: { name, arguments: args },
    }),
  });
  const body = await r.json<any>();
  return JSON.parse(body.result.content[0].text);
}

describe('#5 order_index determinism', () => {
  it('densifies a colliding explicit order_index on add_exercise', async () => {
    const built = await call('update_plan', {
      name: 'Order',
      days: [
        {
          day_label: 'A',
          name: 'Day A',
          exercises: [
            { exercise: 'bench', order_index: 0, target_sets: 3, target_reps: 5 },
            { exercise: 'barbell row', order_index: 1, target_sets: 3, target_reps: 8 },
          ],
        },
      ],
    });
    expect(built.conflict).toBe(false);

    // Add a third exercise forcing a collision at order_index 1.
    const added = await call('add_exercise', {
      day: 'A',
      exercise: 'squat',
      order_index: 1,
      target_sets: 3,
      target_reps: 5,
    });
    expect(added.error).toBeUndefined();

    const plan = await call('get_current_plan', {});
    const slots = plan.days[0].exercises as { order_index: number }[];
    const indices = slots.map((s) => s.order_index).sort((a, b) => a - b);
    // Three slots, dense + unique 0,1,2 — no duplicate index.
    expect(indices).toEqual([0, 1, 2]);
    expect(new Set(indices).size).toBe(3);
  });

  it('densifies when update_exercise patches order_index onto a sibling', async () => {
    const built = await call('update_plan', {
      name: 'Order2',
      days: [
        {
          day_label: 'A',
          name: 'Day A',
          exercises: [
            { exercise: 'bench', order_index: 0, target_sets: 3, target_reps: 5 },
            { exercise: 'squat', order_index: 1, target_sets: 3, target_reps: 5 },
            { exercise: 'deadlift', order_index: 2, target_sets: 1, target_reps: 5 },
          ],
        },
      ],
    });
    expect(built.conflict).toBe(false);

    // Patch deadlift to collide at 0.
    const patched = await call('update_exercise', {
      day: 'A',
      exercise: 'deadlift',
      patch: { order_index: 0 },
    });
    expect(patched.error).toBeUndefined();

    const plan = await call('get_current_plan', {});
    const slots = plan.days[0].exercises as { order_index: number; exercise_id: string }[];
    const indices = slots.map((s) => s.order_index).sort((a, b) => a - b);
    expect(indices).toEqual([0, 1, 2]);
    expect(new Set(indices).size).toBe(3);
    // The MOVED slot must actually land at the requested index 0 — not lose
    // the tie to the older sibling already there.
    expect(slots.find((s) => s.exercise_id === 'ex_deadlift')!.order_index).toBe(0);
    // Plan tree is returned in order, so first slot is deadlift.
    expect(slots[0]!.exercise_id).toBe('ex_deadlift');
  });

  it('honors a DOWNWARD move to a later occupied index', async () => {
    const built = await call('update_plan', {
      name: 'OrderDown',
      days: [
        {
          day_label: 'A',
          name: 'Day A',
          exercises: [
            { exercise: 'bench', order_index: 0, target_sets: 3, target_reps: 5 },
            { exercise: 'squat', order_index: 1, target_sets: 3, target_reps: 5 },
            { exercise: 'deadlift', order_index: 2, target_sets: 1, target_reps: 5 },
            { exercise: 'overhead press', order_index: 3, target_sets: 3, target_reps: 5 },
          ],
        },
      ],
    });
    expect(built.conflict).toBe(false);

    // Move bench (0) DOWN to 2 (occupied by deadlift). Must land at 2,
    // not one short at 1 (the bug Codex flagged in the tiebreak approach).
    const patched = await call('update_exercise', {
      day: 'A',
      exercise: 'bench',
      patch: { order_index: 2 },
    });
    expect(patched.error).toBeUndefined();

    const plan = await call('get_current_plan', {});
    const slots = plan.days[0].exercises as { order_index: number; exercise_id: string }[];
    const indices = slots.map((s) => s.order_index).sort((a, b) => a - b);
    expect(indices).toEqual([0, 1, 2, 3]);
    expect(slots.find((s) => s.exercise_id === 'ex_bench')!.order_index).toBe(2);
    // Expected resulting order: squat, deadlift, bench, OHP.
    expect(slots.map((s) => s.exercise_id)).toEqual([
      'ex_back_squat',
      'ex_deadlift',
      'ex_bench',
      'ex_ohp',
    ]);
  });
});

describe('last_completed_session', () => {
  it('get_today_workout returns the last COMPLETED session, not an intervening skip', async () => {
    // Build a plan and complete a session on a past date.
    await call('update_plan', {
      name: 'Completed Ctx',
      days: [
        { day_label: 'A', name: 'Full A', exercises: [{ exercise: 'bench', target_sets: 3, target_reps: 5 }] },
      ],
    });
    // Log + complete a session two days ago.
    const twoAgo = new Date(Date.now() - 2 * 86_400_000).toISOString().slice(0, 10);
    await call('log_set', { exercise: 'bench', weight: 225, reps: 5, session_date: twoAgo });
    const done = await call('log_workout_complete', { session_date: twoAgo, perceived_fatigue: 6 });
    expect(done.status).toBe('completed');

    // Skip yesterday (a one-off rest row, status != completed).
    const yesterday = new Date(Date.now() - 86_400_000).toISOString().slice(0, 10);
    await call('skip_planned_session', { date: yesterday });

    const today = await call('get_today_workout', {});
    // last_completed_session must be the completed two-days-ago session.
    expect(today.last_completed_session).not.toBeNull();
    expect(today.last_completed_session.date).toBe(twoAgo);
    expect(today.last_completed_session.status).toBe('completed');
    expect(today.last_completed_session_sets.length).toBeGreaterThanOrEqual(1);
  });
});
