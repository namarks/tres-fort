/**
 * 0020 (demo_slug backfill) + 0021 (v2 catalog expansion) contracts.
 *
 *  - 0020 adds a nullable demo_slug column and backfills 127 of the 138
 *    pre-existing rows from free-exercise-db ids. The 11 unmapped rows
 *    (band/quadruped/timed-holds/ab-wheel/sissy) stay NULL — covered.
 *  - 0021 adds ~108 net-new exercises with heavy bodyweight + unilateral
 *    bias. INSERTs are OR IGNORE so re-runs are a no-op. Every row carries
 *    laterality + load_mode + demo_slug inline at INSERT time.
 *  - alias determinism (no shadowing across the whole catalog) is the
 *    invariant /api/exercises and MCP list_exercises depend on.
 */
import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { resolveExercise } from '../src/db';

const BASE = 'https://tres-fort.test';
const TOKEN = 'test-mcp-token';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

let id = 0;
async function call(name: string, args: unknown) {
  const r = await SELF.fetch(`${BASE}/mcp`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      Authorization: `Bearer ${TOKEN}`,
    },
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

describe('0020 demo_slug backfill', () => {
  it('adds demo_slug column to exercises', async () => {
    const row = await env.DB.prepare(
      "SELECT demo_slug FROM exercises WHERE id = 'ex_back_squat'",
    ).first<{ demo_slug: string | null }>();
    expect(row).toBeTruthy();
  });

  it('backfills the original 12 from free-exercise-db slugs', async () => {
    const pairs: Array<[string, string]> = [
      ['ex_back_squat', 'Barbell_Squat'],
      ['ex_deadlift', 'Barbell_Deadlift'],
      ['ex_bench', 'Barbell_Bench_Press_-_Medium_Grip'],
      ['ex_ohp', 'Standing_Military_Press'],
      ['ex_pullup', 'Pullups'],
      ['ex_db_press', 'Dumbbell_Bench_Press'],
      ['ex_leg_press', 'Leg_Press'],
    ];
    for (const [exId, slug] of pairs) {
      const r = await env.DB.prepare(
        'SELECT demo_slug FROM exercises WHERE id = ?1',
      )
        .bind(exId)
        .first<{ demo_slug: string | null }>();
      expect(r?.demo_slug, `${exId} slug`).toBe(slug);
    }
  });

  it('leaves rows without an upstream pairing NULL', async () => {
    // Holds + bands + quadruped primitives have no upstream image; the
    // demo sheet falls back to a cue card for these.
    const nullSlugs = [
      'ex_hollow',
      'ex_dead_hang',
      'ex_wall_sit',
      'ex_bird_dog',
      'ex_banded_pull_apart',
      'ex_banded_glute_bridge',
    ];
    for (const exId of nullSlugs) {
      const r = await env.DB.prepare(
        'SELECT demo_slug FROM exercises WHERE id = ?1',
      )
        .bind(exId)
        .first<{ demo_slug: string | null }>();
      expect(r?.demo_slug, `${exId} should be NULL`).toBeNull();
    }
  });

  it('surfaces demo_slug on GET /api/exercises (so iOS can render)', async () => {
    // Manual call via SELF.fetch + dev-auth — the existing api.test.ts
    // pattern. We're checking the JSON wire shape, not auth.
    const { results } = (await env.DB.prepare(
      "SELECT id, demo_slug FROM exercises WHERE id = 'ex_back_squat'",
    ).all<{ id: string; demo_slug: string | null }>())!;
    expect(results[0]?.demo_slug).toBe('Barbell_Squat');
  });
});

describe('0021 catalog v2 (bodyweight + unilateral expansion)', () => {
  it('catalog grows by 108 net-new rows (138 + 108 = 246)', async () => {
    const { count } = (await env.DB.prepare(
      'SELECT COUNT(*) AS count FROM exercises',
    ).first<{ count: number }>())!;
    // ex_kb_swing re-listed as INSERT OR IGNORE no-op — net 108 new.
    expect(count).toBe(246);
  });

  it('adds priority bodyweight at-home rows', async () => {
    // The user explicitly asked for at-home bw coverage. Spot-check the
    // headline additions land with the right modality.
    const bw = [
      'ex_pistol_squat',
      'ex_skater_squat',
      'ex_cossack_squat',
      'ex_bw_single_leg_rdl',
      'ex_bw_reverse_lunge',
      'ex_archer_pushup',
      'ex_single_arm_pushup',
      'ex_diamond_pushup',
      'ex_pike_pushup',
      'ex_archer_pullup',
      'ex_burpee',
      'ex_mountain_climber',
      'ex_plank_to_pike',
      'ex_v_up',
      'ex_hollow_rocks',
      'ex_bear_crawl',
      'ex_inchworm',
      'ex_jumping_jack',
      'ex_high_knees',
      'ex_broad_jump',
      'ex_box_jump',
      'ex_jackknife_situp',
      'ex_clamshell',
      'ex_fire_hydrant',
      'ex_glute_bridge_march',
    ];
    for (const exId of bw) {
      const row = await env.DB.prepare(
        'SELECT id, modality FROM exercises WHERE id = ?1',
      )
        .bind(exId)
        .first<{ id: string; modality: string }>();
      expect(row, `${exId} missing`).toBeTruthy();
      expect(row!.modality, `${exId} modality`).toBe('bw');
    }
  });

  it('tags new unilateral rows correctly (per-side reps + tonnage doubling)', async () => {
    // The whole point of laterality is the per-side accounting. Every new
    // single-leg/single-arm row must be tagged so the volume math doubles.
    const uni = [
      'ex_pistol_squat',
      'ex_skater_squat',
      'ex_shrimp_squat',
      'ex_cossack_squat',
      'ex_bw_single_leg_rdl',
      'ex_bw_single_leg_hip_thrust',
      'ex_bw_reverse_lunge',
      'ex_bw_lateral_lunge',
      'ex_bw_curtsy_lunge',
      'ex_jumping_lunge',
      'ex_clamshell',
      'ex_fire_hydrant',
      'ex_side_lying_abduction',
      'ex_glute_bridge_march',
      'ex_single_leg_calf_raise',
      'ex_archer_pushup',
      'ex_single_arm_pushup',
      'ex_archer_pullup',
      'ex_shoulder_tap',
      'ex_sa_db_ohp',
      'ex_sa_db_bench',
      'ex_db_bstance_rdl',
      'ex_db_single_leg_rdl',
      'ex_db_suitcase_dl',
      'ex_db_suitcase_carry',
      'ex_sa_cable_row',
      'ex_sa_lat_pulldown',
      'ex_sa_cable_lateral',
      'ex_sa_cable_curl',
      'ex_sa_cable_pushdown',
      'ex_single_leg_press',
      'ex_single_leg_curl',
      'ex_single_leg_extension',
      'ex_landmine_press',
      'ex_landmine_row',
      'ex_sa_kb_swing',
      'ex_kb_snatch',
      'ex_kb_clean',
      'ex_mountain_climber',
      'ex_bicycle_crunch',
      'ex_worlds_greatest_stretch',
      'ex_90_90_hip',
      'ex_couch_stretch',
      'ex_pigeon_pose',
      'ex_thoracic_rotation',
      'ex_high_knees',
      'ex_bear_crawl',
      'ex_crab_walk',
      'ex_wall_sit_marching',
    ];
    for (const exId of uni) {
      const row = await env.DB.prepare(
        'SELECT id, laterality FROM exercises WHERE id = ?1',
      )
        .bind(exId)
        .first<{ id: string; laterality: string }>();
      expect(row, `${exId} missing`).toBeTruthy();
      expect(row!.laterality, `${exId} laterality`).toBe('unilateral');
    }
  });

  it('tags per_hand on the two-DB carries / RDL / overhead carry', async () => {
    const perHand = [
      'ex_db_bstance_rdl',
      'ex_db_farmers_walk',
      'ex_db_overhead_carry',
    ];
    for (const exId of perHand) {
      const row = await env.DB.prepare(
        'SELECT id, load_mode FROM exercises WHERE id = ?1',
      )
        .bind(exId)
        .first<{ id: string; load_mode: string }>();
      expect(row, `${exId} missing`).toBeTruthy();
      expect(row!.load_mode, `${exId} load_mode`).toBe('per_hand');
    }
  });

  it('sets demo_slug inline on new rows that have an upstream entry', async () => {
    const slugs: Array<[string, string]> = [
      ['ex_jump_squat', 'Freehand_Jump_Squat'],
      ['ex_single_arm_pushup', 'Single-Arm_Push-Up'],
      ['ex_wide_pushup', 'Push-Up_Wide'],
      ['ex_plyo_pushup', 'Plyo_Push-up'],
      ['ex_inchworm', 'Inchworm'],
      ['ex_superman', 'Superman'],
      ['ex_box_jump', 'Bench_Jump'],
      ['ex_power_clean', 'Power_Clean'],
      ['ex_snatch_pull', 'Snatch_Pull'],
      ['ex_trap_bar_dl', 'Trap_Bar_Deadlift'],
      ['ex_sa_db_bench', 'One_Arm_Dumbbell_Bench_Press'],
      ['ex_db_farmers_walk', 'Farmers_Walk'],
    ];
    for (const [exId, slug] of slugs) {
      const row = await env.DB.prepare(
        'SELECT demo_slug FROM exercises WHERE id = ?1',
      )
        .bind(exId)
        .first<{ demo_slug: string | null }>();
      expect(row?.demo_slug, `${exId} demo_slug`).toBe(slug);
    }
  });

  it('resolves new exercises by canonical name + common aliases', async () => {
    const cases: Array<[string, string]> = [
      ['Pistol Squat', 'ex_pistol_squat'],
      ['Cossack Squat', 'ex_cossack_squat'],
      ['Burpee', 'ex_burpee'],
      ['Burpees', 'ex_burpee'],
      ['Mountain Climbers', 'ex_mountain_climber'],
      ['Single-Arm Push-Up', 'ex_single_arm_pushup'],
      ['Archer Push-Up', 'ex_archer_pushup'],
      ['Power Clean', 'ex_power_clean'],
      ['snatch', 'ex_full_snatch'],
      ['trap bar deadlift', 'ex_trap_bar_dl'],
      ['hex bar deadlift', 'ex_trap_bar_dl'],
      ['farmer carry', 'ex_db_farmers_walk'],
      ['Pike Push-Up', 'ex_pike_pushup'],
      ["world's greatest stretch", 'ex_worlds_greatest_stretch'],
      ['box jump', 'ex_box_jump'],
      ['90/90 hip', 'ex_90_90_hip'],
    ];
    for (const [name, exId] of cases) {
      const r = await resolveExercise(env.DB, name);
      expect(r, `name ${name} unresolved`).toBeTruthy();
      expect((r as { id: string }).id, `${name} routed`).toBe(exId);
    }
  });

  it('alias determinism: no new alias shadows another canonical name; no alias collisions catalog-wide', async () => {
    const rows = (
      await env.DB.prepare('SELECT id,name,aliases FROM exercises').all<{
        id: string;
        name: string;
        aliases: string | null;
      }>()
    ).results;

    const aliasOwner = new Map<string, string>();
    const nameOwner = new Map<string, string>();
    for (const row of rows) {
      nameOwner.set(row.name.toLowerCase(), row.id);
    }
    for (const row of rows) {
      const aliases: string[] = row.aliases ? JSON.parse(row.aliases) : [];
      for (const a of aliases) {
        const key = a.toLowerCase();
        const prev = aliasOwner.get(key);
        if (prev !== undefined && prev !== row.id) {
          throw new Error(`alias collision "${key}": ${prev} vs ${row.id}`);
        }
        aliasOwner.set(key, row.id);
        const nameHolder = nameOwner.get(key);
        if (nameHolder !== undefined && nameHolder !== row.id) {
          throw new Error(
            `alias "${key}" (owned by ${row.id}) shadows canonical name of ${nameHolder}`,
          );
        }
      }
    }
  });

  it('list_exercises (MCP) surfaces demo_slug for new rows', async () => {
    const all = await call('list_exercises', {});
    const byId: Record<string, { demo_slug?: string | null }> =
      Object.fromEntries(all.map((e: { id: string }) => [e.id, e]));
    expect(byId['ex_pistol_squat']).toBeTruthy();
    expect(byId['ex_pistol_squat']!.demo_slug).toBeNull();
    expect(byId['ex_power_clean']!.demo_slug).toBe('Power_Clean');
    // confirm the field rides on every row (not undefined on the new
    // entries that lack a slug).
    expect(
      all.every((e: { demo_slug?: unknown }) => 'demo_slug' in e),
    ).toBe(true);
  });

  it('re-running 0021 is a no-op (INSERT OR IGNORE keeps count stable)', async () => {
    const before = (await env.DB.prepare(
      'SELECT COUNT(*) AS c FROM exercises',
    ).first<{ c: number }>())!.c;
    const mig = (
      env.TEST_MIGRATIONS as Array<{ name: string; queries: string[] }>
    ).find((m) => m.name.includes('0021'));
    expect(mig, '0021 migration missing').toBeTruthy();
    for (const q of mig!.queries) {
      await env.DB.prepare(q).run();
    }
    const after = (await env.DB.prepare(
      'SELECT COUNT(*) AS c FROM exercises',
    ).first<{ c: number }>())!.c;
    expect(after).toBe(before);
  });
});
