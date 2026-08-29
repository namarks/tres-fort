/**
 * load_mode — two-dumbbell lifts log/display weight per hand.
 *
 * #feature: a DB bench at "25 in each hand" must read as 25 per hand, never
 * a vague doubled 50. The catalog carries load_mode ("total" | "per_hand");
 * list_exercises surfaces it and log_set echoes it plus a ready-to-say
 * weight_display so coaching never says the wrong number.
 */
import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';

const BASE = 'https://tres-fort.test';
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

describe('load_mode (per-hand dumbbell lifts)', () => {
  it('list_exercises surfaces load_mode; two-DB lifts are per_hand, others total', async () => {
    const all = await call('list_exercises', {});
    expect(all.every((e: { load_mode?: string }) => typeof e.load_mode === 'string')).toBe(true);
    const byId = Object.fromEntries(all.map((e: { id: string }) => [e.id, e]));

    for (const exId of [
      'ex_db_press', // flat DB bench — the most common two-DB lift
      'ex_db_curl',
      'ex_db_ohp',
      'ex_lateral_raise',
      'ex_incline_db_press',
    ]) {
      expect(byId[exId]?.load_mode).toBe('per_hand');
    }
    // Single-implement / barbell / one-arm stay total.
    for (const exId of ['ex_goblet_squat', 'ex_one_arm_db_row', 'ex_bench', 'ex_back_squat']) {
      expect(byId[exId]?.load_mode).toBe('total');
    }
  });

  it('log_set echoes load_mode and counts both implements for two-DB lifts', async () => {
    await call('update_plan', {
      name: 'PerHand',
      days: [
        {
          day_label: 'A',
          name: 'Upper',
          exercises: [{ exercise: 'dumbbell curl', target_sets: 3, target_reps: 10 }],
        },
      ],
    });
    const r = await call('log_set', { exercise: 'dumbbell curl', weight: 25, reps: 10 });
    expect(r.set.weight).toBe(25); // stored per hand, not doubled
    expect(r.exercise.load_mode).toBe('per_hand');
    expect(r.effective.implements).toBe(2);
    expect(r.effective.tonnage).toBe(25 * 10 * 2);
    expect(r.effective.weight_display).toBe('25 lb in each hand');
    const volume = await call('get_volume_trend', { muscle_group: 'biceps', range: '4w' });
    const tonnage = (volume.buckets as { tonnage: number }[]).reduce(
      (total, bucket) => total + (bucket.tonnage ?? 0),
      0,
    );
    // Dumbbell curl is bilateral + per_hand: count two implements, but no
    // unilateral side multiplier.
    expect(tonnage).toBe(25 * 10 * 2);

    // A barbell lift reads as a plain total.
    const b = await call('log_set', { exercise: 'bench', weight: 135, reps: 5 });
    if (!b.error) {
      expect(b.exercise.load_mode).toBe('total');
      expect(b.effective.implements).toBe(1);
      expect(b.effective.tonnage).toBe(135 * 5);
      expect(b.effective.weight_display).toBe('135 lb');
    }
  });
});
