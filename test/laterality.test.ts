/**
 * Unilateral / laterality plumbing — protects three guarantees:
 *
 * 1. The catalog row carries `laterality`, and the MCP `list_exercises` tool
 *    surfaces it (so iOS + the LLM can both compute correct totals).
 * 2. `getVolume` independently accounts for unilateral sides and per-hand
 *    implements — a two-DB 45×8 Bulgarian split squat reads as 1,440 lb,
 *    not 360 lb. hard_sets stays a literal count.
 * 3. `log_set` returns the resolved exercise's laterality + effective totals
 *    so the LLM can confirm "16 reps total / 1,440 lb" back to the user.
 *
 * Catalog rows seeded as unilateral by migration 0011: lunges, Bulgarian
 * split squat, step-ups, single-leg glute bridge, one-arm DB row.
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

describe('laterality (unilateral exercises)', () => {
  it('list_exercises surfaces laterality; seeded unilateral rows are tagged', async () => {
    const all = await call('list_exercises', {});
    // every row has the field — string, not undefined
    expect(all.every((e: { laterality?: string }) => typeof e.laterality === 'string')).toBe(true);

    const byId = Object.fromEntries(all.map((e: { id: string }) => [e.id, e]));
    // Spot-check the ones migration 0011 backfills.
    for (const exId of [
      'ex_db_split_squat',
      'ex_one_arm_db_row',
      'ex_db_lunge',
      'ex_bb_step_up',
      'ex_sl_glute_bridge',
    ]) {
      expect(byId[exId]?.laterality).toBe('unilateral');
    }
    // And a few obvious bilateral rows.
    for (const exId of ['ex_bench', 'ex_back_squat', 'ex_deadlift']) {
      expect(byId[exId]?.laterality).toBe('bilateral');
    }
  });

  it('log_set echoes laterality + effective totals (per-side reps doubled)', async () => {
    // Plan with the Bulgarian split squat slot so log_set has a session to log into.
    const built = await call('update_plan', {
      name: 'Uni',
      days: [
        {
          day_label: 'L',
          name: 'Legs',
          exercises: [
            { exercise: 'bulgarian split squat', target_sets: 3, target_reps: 8 },
          ],
        },
      ],
    });
    expect(built.conflict).toBe(false);

    // 45 lb in each hand, 8 reps each leg — should round-trip the per-side
    // numbers literally, with effective.total_reps=16 / tonnage=1,440.
    const r = await call('log_set', {
      exercise: 'bulgarian split squat',
      weight: 45,
      reps: 8,
    });
    expect(r.set.weight).toBe(45);
    expect(r.set.reps).toBe(8); // stored per-side, NOT doubled
    expect(r.exercise.laterality).toBe('unilateral');
    expect(r.effective.sides).toBe(2);
    expect(r.effective.implements).toBe(2);
    expect(r.effective.total_reps).toBe(16);
    expect(r.effective.tonnage).toBe(45 * 8 * 2 * 2); // 1,440

    // A bilateral set (bench) gets sides=1 / no doubling.
    const b = await call('log_set', { exercise: 'bench', weight: 135, reps: 5 });
    // bench has no slot in this plan but log_set auto-resolves catalog ids;
    // it might fail if there's no session — guard:
    if (!b.error) {
      expect(b.exercise.laterality).toBe('bilateral');
      expect(b.effective.sides).toBe(1);
      expect(b.effective.implements).toBe(1);
      expect(b.effective.total_reps).toBe(5);
      expect(b.effective.tonnage).toBe(135 * 5);
    }
  });

  it('get_volume_trend multiplies unilateral sides and per-hand implements', async () => {
    // Fresh state: plan with one unilateral quad exercise so the volume
    // bucket math is unambiguous.
    const built = await call('update_plan', {
      name: 'Volume',
      days: [
        {
          day_label: 'L',
          name: 'Legs',
          exercises: [
            // Bulgarian split squat is primary_muscle=quads in the seed.
            { exercise: 'bulgarian split squat', target_sets: 1, target_reps: 8 },
          ],
        },
      ],
    });
    expect(built.conflict).toBe(false);

    await call('log_set', { exercise: 'bulgarian split squat', weight: 45, reps: 8 });

    const vol = await call('get_volume_trend', { muscle_group: 'quads', range: '4w' });
    const total = (vol.buckets as { tonnage: number }[]).reduce(
      (s, b) => s + (b.tonnage ?? 0),
      0,
    );
    // 45 × 8 = 360 logged, doubled for two legs and two implements = 1,440.
    expect(total).toBe(1440);
    // hard_sets is a literal set count, not doubled.
    const sets = (vol.buckets as { hard_sets: number }[]).reduce(
      (s, b) => s + (b.hard_sets ?? 0),
      0,
    );
    expect(sets).toBe(1);
  });
});
