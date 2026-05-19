import { env, applyD1Migrations } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { resolveExercise } from '../src/db';

// Contract for migrations/0007_seed_exercises_expanded.sql:
//  - applies cleanly on top of 0001-0006
//  - expands the catalog to ~130 (130 +/- 10) curated exercises
//  - preserves the original 12 ex_* rows byte-identically (name + fields)
//  - resolveExercise resolves a representative sample of new canonical
//    names AND aliases (incl. bodyweight staples)
//  - resolver determinism: NO alias shared across exercises, and NO alias
//    that shadows another exercise's canonical name
//  - re-running the migration is a no-op (idempotent + additive)

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

// The original 12, byte-identical to migrations/0002_seed_exercises.sql.
const ORIGINAL_12: Array<{
  id: string;
  name: string;
  primary_muscle: string;
  secondary_muscles: string;
  modality: string;
  unit: string;
  aliases: string;
}> = [
  { id: 'ex_back_squat', name: 'Back Squat', primary_muscle: 'quads', secondary_muscles: '["glutes","core"]', modality: 'barbell', unit: 'lb', aliases: '["squat","back squat","bb squat"]' },
  { id: 'ex_front_squat', name: 'Front Squat', primary_muscle: 'quads', secondary_muscles: '["glutes","core"]', modality: 'barbell', unit: 'lb', aliases: '["front squat"]' },
  { id: 'ex_deadlift', name: 'Conventional Deadlift', primary_muscle: 'hamstrings', secondary_muscles: '["glutes","back"]', modality: 'barbell', unit: 'lb', aliases: '["deadlift","dl","conventional deadlift"]' },
  { id: 'ex_rdl', name: 'Romanian Deadlift', primary_muscle: 'hamstrings', secondary_muscles: '["glutes","back"]', modality: 'barbell', unit: 'lb', aliases: '["rdl","romanian deadlift","romanian"]' },
  { id: 'ex_bench', name: 'Bench Press', primary_muscle: 'chest', secondary_muscles: '["triceps","front delts"]', modality: 'barbell', unit: 'lb', aliases: '["bench","bench press","bp","flat bench"]' },
  { id: 'ex_incline_bench', name: 'Incline Bench Press', primary_muscle: 'chest', secondary_muscles: '["triceps","front delts"]', modality: 'barbell', unit: 'lb', aliases: '["incline","incline bench"]' },
  { id: 'ex_ohp', name: 'Overhead Press', primary_muscle: 'shoulders', secondary_muscles: '["triceps"]', modality: 'barbell', unit: 'lb', aliases: '["ohp","overhead press","press","military press"]' },
  { id: 'ex_barbell_row', name: 'Barbell Row', primary_muscle: 'back', secondary_muscles: '["biceps","rear delts"]', modality: 'barbell', unit: 'lb', aliases: '["row","barbell row","bb row","pendlay row"]' },
  { id: 'ex_pullup', name: 'Pull-Up', primary_muscle: 'back', secondary_muscles: '["biceps"]', modality: 'bw', unit: 'lb', aliases: '["pullup","pull-up","pull up","chin up"]' },
  { id: 'ex_db_press', name: 'Dumbbell Bench Press', primary_muscle: 'chest', secondary_muscles: '["triceps","front delts"]', modality: 'dumbbell', unit: 'lb', aliases: '["db press","dumbbell bench","db bench"]' },
  { id: 'ex_lat_pulldown', name: 'Lat Pulldown', primary_muscle: 'back', secondary_muscles: '["biceps"]', modality: 'machine', unit: 'lb', aliases: '["pulldown","lat pulldown"]' },
  { id: 'ex_leg_press', name: 'Leg Press', primary_muscle: 'quads', secondary_muscles: '["glutes"]', modality: 'machine', unit: 'lb', aliases: '["leg press"]' },
];

describe('expanded exercise catalog (0007)', () => {
  it('expands the catalog to ~130 exercises', async () => {
    const { count } = (await env.DB.prepare(
      'SELECT COUNT(*) AS count FROM exercises',
    ).first<{ count: number }>())!;
    expect(count).toBeGreaterThanOrEqual(120);
    expect(count).toBeLessThanOrEqual(140);
  });

  it('preserves the original 12 ex_* rows byte-identically', async () => {
    for (const o of ORIGINAL_12) {
      const row = await env.DB.prepare(
        'SELECT id,name,primary_muscle,secondary_muscles,modality,unit,aliases,created_at FROM exercises WHERE id = ?1',
      )
        .bind(o.id)
        .first<typeof o & { created_at: number }>();
      expect(row, `missing original id ${o.id}`).toBeTruthy();
      expect(row!.name).toBe(o.name);
      expect(row!.primary_muscle).toBe(o.primary_muscle);
      expect(row!.secondary_muscles).toBe(o.secondary_muscles);
      expect(row!.modality).toBe(o.modality);
      expect(row!.unit).toBe(o.unit);
      expect(row!.aliases).toBe(o.aliases);
      expect(row!.created_at).toBe(0);
    }
  });

  it('covers all major muscle groups and all modalities', async () => {
    const muscles = (
      await env.DB.prepare(
        'SELECT DISTINCT primary_muscle AS m FROM exercises',
      ).all<{ m: string }>()
    ).results.map((r) => r.m);
    for (const m of ['quads', 'hamstrings', 'glutes', 'chest', 'back', 'shoulders', 'biceps', 'triceps', 'calves', 'core']) {
      expect(muscles, `missing primary_muscle ${m}`).toContain(m);
    }
    const modalities = (
      await env.DB.prepare('SELECT DISTINCT modality AS x FROM exercises').all<{
        x: string;
      }>()
    ).results.map((r) => r.x);
    for (const x of ['barbell', 'dumbbell', 'machine', 'bw']) {
      expect(modalities, `missing modality ${x}`).toContain(x);
    }
  });

  it('resolveExercise resolves new canonical names (incl. bodyweight)', async () => {
    const cases: Array<[string, string]> = [
      ['Goblet Squat', 'ex_goblet_squat'],
      ['Push-Up', 'ex_pushup'],
      ['Plank', 'ex_plank'],
      ['Dips', 'ex_dips'],
      ['Bodyweight Squat', 'ex_bw_squat'],
      ['Hip Thrust', 'ex_hip_thrust'],
      ['Barbell Curl', 'ex_bb_curl'],
      ['Triceps Pushdown', 'ex_tricep_pushdown'],
      ['Standing Calf Raise', 'ex_standing_calf_raise'],
      ['Chin-Up', 'ex_chinup'],
      ['Inverted Row', 'ex_inverted_row'],
      ['Hanging Leg Raise', 'ex_hanging_leg_raise'],
    ];
    for (const [name, id] of cases) {
      const r = await resolveExercise(env.DB, name);
      expect(r, `name ${name} unresolved`).toBeTruthy();
      expect((r as { id: string }).id).toBe(id);
    }
  });

  it('resolveExercise resolves conversational aliases', async () => {
    const cases: Array<[string, string]> = [
      ['pushup', 'ex_pushup'],
      ['press up', 'ex_pushup'],
      ['goblet', 'ex_goblet_squat'],
      ['skull crusher', 'ex_skullcrusher'],
      ['cgbp', 'ex_cgbp'],
      ['hammer curl', 'ex_hammer_curl'],
      ['rope pushdown', 'ex_rope_pushdown'],
      ['arnold press', 'ex_arnold_press'],
      ['lat raise', 'ex_lateral_raise'],
      ['face pull', 'ex_face_pull'],
      ['walking lunge', 'ex_bw_lunge'],
      ['bulgarian split squat', 'ex_db_split_squat'],
      // case-insensitive
      ['PUSHUP', 'ex_pushup'],
      // original-12 aliases still resolve unchanged
      ['squat', 'ex_back_squat'],
      ['rdl', 'ex_rdl'],
    ];
    for (const [alias, id] of cases) {
      const r = await resolveExercise(env.DB, alias);
      expect(r, `alias ${alias} unresolved`).toBeTruthy();
      expect((r as { id: string }).id).toBe(id);
    }
  });

  it('resolver determinism: no alias collisions, no canonical-name shadowing', async () => {
    const rows = (
      await env.DB.prepare('SELECT id,name,aliases FROM exercises').all<{
        id: string;
        name: string;
        aliases: string | null;
      }>()
    ).results;

    // (a) every alias token is owned by exactly one exercise
    const aliasOwner = new Map<string, string>();
    for (const row of rows) {
      const aliases: string[] = row.aliases ? JSON.parse(row.aliases) : [];
      for (const a of aliases) {
        const key = a.toLowerCase();
        const prev = aliasOwner.get(key);
        expect(
          prev === undefined || prev === row.id,
          `alias collision "${key}": ${prev} vs ${row.id}`,
        ).toBe(true);
        aliasOwner.set(key, row.id);
      }
    }

    // (b) canonical names are unique
    const nameOwner = new Map<string, string>();
    for (const row of rows) {
      const key = row.name.toLowerCase();
      expect(
        !nameOwner.has(key),
        `duplicate canonical name "${key}"`,
      ).toBe(true);
      nameOwner.set(key, row.id);
    }

    // (c) no alias shadows a *different* exercise's canonical name
    for (const [alias, owner] of aliasOwner) {
      const nameHolder = nameOwner.get(alias);
      if (nameHolder !== undefined) {
        expect(
          nameHolder === owner,
          `alias "${alias}" (owned by ${owner}) shadows canonical name of ${nameHolder}`,
        ).toBe(true);
      }
    }
  });

  it('re-running 0007 is a no-op (idempotent + additive)', async () => {
    const before = (await env.DB.prepare(
      'SELECT COUNT(*) AS c FROM exercises',
    ).first<{ c: number }>())!.c;

    // Re-apply the exact 0007 statement set.
    const mig = (env.TEST_MIGRATIONS as Array<{ name: string; queries: string[] }>).find(
      (m) => m.name.includes('0007'),
    );
    expect(mig, '0007 migration not found in TEST_MIGRATIONS').toBeTruthy();
    for (const q of mig!.queries) {
      await env.DB.prepare(q).run();
    }

    const after = (await env.DB.prepare(
      'SELECT COUNT(*) AS c FROM exercises',
    ).first<{ c: number }>())!.c;
    expect(after).toBe(before);

    // and the originals are still byte-identical after the replay
    const sq = await env.DB.prepare(
      'SELECT name,primary_muscle,aliases FROM exercises WHERE id = ?1',
    )
      .bind('ex_back_squat')
      .first<{ name: string; primary_muscle: string; aliases: string }>();
    expect(sq!.name).toBe('Back Squat');
    expect(sq!.primary_muscle).toBe('quads');
    expect(sq!.aliases).toBe('["squat","back squat","bb squat"]');
  });
});
