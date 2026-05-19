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

// The original 12 as defined by 0002. All fields are byte-identical to
// 0002_seed_exercises.sql EXCEPT ex_db_press.aliases: 0007 emits one
// documented, idempotent, additive UPDATE that appends the conventional
// alias "dumbbell press" to ex_db_press so that phrase routes to the bench
// press (not the new ex_db_ohp). Every other original row is untouched.
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
  // aliases = 0002's '["db press","dumbbell bench","db bench"]' + the
  // documented 0007 additive backfill of "dumbbell press".
  { id: 'ex_db_press', name: 'Dumbbell Bench Press', primary_muscle: 'chest', secondary_muscles: '["triceps","front delts"]', modality: 'dumbbell', unit: 'lb', aliases: '["db press", "dumbbell bench", "db bench", "dumbbell press"]' },
  { id: 'ex_lat_pulldown', name: 'Lat Pulldown', primary_muscle: 'back', secondary_muscles: '["biceps"]', modality: 'machine', unit: 'lb', aliases: '["pulldown","lat pulldown"]' },
  { id: 'ex_leg_press', name: 'Leg Press', primary_muscle: 'quads', secondary_muscles: '["glutes"]', modality: 'machine', unit: 'lb', aliases: '["leg press"]' },
];

describe('expanded exercise catalog (0007)', () => {
  it('expands the catalog to ~131 exercises (12 + 5 + 114)', async () => {
    // 0002 = 12, 0004 = 5 timed, 0007 = 114 net-new -> 131 total.
    const { count } = (await env.DB.prepare(
      'SELECT COUNT(*) AS count FROM exercises',
    ).first<{ count: number }>())!;
    expect(count).toBe(131);
  });

  it('preserves the original 12 ex_* rows (byte-identical except the documented ex_db_press alias backfill)', async () => {
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
      // NOTE: every input here is an alias token that is NOT equal to its
      // exercise's lower(name), so it can ONLY match the resolver's
      // `lower(aliases) LIKE '%"<q>"%'` branch (not the lower(name)=q
      // branch) -- this genuinely exercises the alias path.
      ['pushup', 'ex_pushup'], // name is "push-up"
      ['press up', 'ex_pushup'],
      ['goblet', 'ex_goblet_squat'], // name is "goblet squat"
      ['skull crusher', 'ex_skullcrusher'],
      ['cgbp', 'ex_cgbp'],
      ['hammers', 'ex_hammer_curl'], // name is "hammer curl"
      ['rope pushdown', 'ex_rope_pushdown'],
      ['arnold', 'ex_arnold_press'], // name is "arnold press"
      ['lat raise', 'ex_lateral_raise'],
      ['face pulls', 'ex_face_pull'], // name is "face pull"
      ['walking lunge', 'ex_bw_lunge'],
      ['bulgarian split squat', 'ex_db_split_squat'],
      // case-insensitive
      ['PUSHUP', 'ex_pushup'],
      // original-12 aliases still resolve unchanged
      ['squat', 'ex_back_squat'],
      ['rdl', 'ex_rdl'],
      // REGRESSION GUARD: "chin up" is a long-standing ex_pullup alias.
      // The expanded catalog adds a distinct ex_chinup ("chin-up"/
      // "chinup"). The existing user-facing phrase "chin up" must keep
      // routing to ex_pullup, not the new ex_chinup -- guards against a
      // future alias move silently re-pointing it.
      ['chin up', 'ex_pullup'],
    ];
    for (const [alias, id] of cases) {
      const r = await resolveExercise(env.DB, alias);
      expect(r, `alias ${alias} unresolved`).toBeTruthy();
      expect((r as { id: string }).id).toBe(id);
    }
  });

  it('all 12 original keywords still resolve to their original ids', async () => {
    // Guards the active plan + every user-facing legacy phrase. Includes
    // the BLOCKER fix: "dumbbell press"/"db press" MUST route to the
    // original ex_db_press (Dumbbell Bench Press), never the new
    // ex_db_ohp (Dumbbell Shoulder Press).
    const cases: Array<[string, string]> = [
      ['squat', 'ex_back_squat'],
      ['back squat', 'ex_back_squat'],
      ['front squat', 'ex_front_squat'],
      ['deadlift', 'ex_deadlift'],
      ['dl', 'ex_deadlift'],
      ['rdl', 'ex_rdl'],
      ['romanian deadlift', 'ex_rdl'],
      ['bench', 'ex_bench'],
      ['bench press', 'ex_bench'],
      ['incline', 'ex_incline_bench'],
      ['incline bench', 'ex_incline_bench'],
      ['ohp', 'ex_ohp'],
      ['overhead press', 'ex_ohp'],
      ['military press', 'ex_ohp'],
      ['row', 'ex_barbell_row'],
      ['barbell row', 'ex_barbell_row'],
      ['pullup', 'ex_pullup'],
      ['chin up', 'ex_pullup'],
      ['dumbbell press', 'ex_db_press'], // BLOCKER: not ex_db_ohp
      ['db press', 'ex_db_press'], // BLOCKER: not ex_db_ohp
      ['dumbbell bench', 'ex_db_press'],
      ['pulldown', 'ex_lat_pulldown'],
      ['lat pulldown', 'ex_lat_pulldown'],
      ['leg press', 'ex_leg_press'],
    ];
    for (const [kw, id] of cases) {
      const r = await resolveExercise(env.DB, kw);
      expect(r, `keyword ${kw} unresolved`).toBeTruthy();
      expect(
        (r as { id: string }).id,
        `keyword "${kw}" routed to ${(r as { id: string }).id}, expected ${id}`,
      ).toBe(id);
    }

    // And the dumbbell shoulder press is reachable by its own unambiguous
    // aliases (it must NOT own "dumbbell press").
    for (const kw of ['dumbbell shoulder press', 'db shoulder press', 'db ohp']) {
      const r = await resolveExercise(env.DB, kw);
      expect((r as { id: string })?.id, `${kw} should be ex_db_ohp`).toBe(
        'ex_db_ohp',
      );
    }
  });

  it('0007 is strictly additive: introduces NO id already seeded by 0002/0004', async () => {
    // 0002 (the 12) and 0004 (5 timed core/hold) own these ids; 0007 must
    // not restate or collide with any of them.
    const PRIOR_IDS = [
      // 0002
      'ex_back_squat', 'ex_front_squat', 'ex_deadlift', 'ex_rdl', 'ex_bench',
      'ex_incline_bench', 'ex_ohp', 'ex_barbell_row', 'ex_pullup',
      'ex_db_press', 'ex_lat_pulldown', 'ex_leg_press',
      // 0004
      'ex_plank', 'ex_side_plank', 'ex_hollow', 'ex_dead_hang', 'ex_wall_sit',
    ];
    const mig = (
      env.TEST_MIGRATIONS as Array<{ name: string; queries: string[] }>
    ).find((m) => m.name.includes('0007'));
    expect(mig, '0007 migration not found').toBeTruthy();
    const sql = mig!.queries.join('\n');

    // Every id 0007 INSERTs (the VALUES tuples) -- exclude the trailing
    // UPDATE which targets the pre-existing ex_db_press by design.
    const insertIds = [...sql.matchAll(/\(\s*'(ex_[a-z0-9_]+)'\s*,/g)]
      .map((m) => m[1])
      .filter((x): x is string => x !== undefined);
    expect(insertIds.length).toBeGreaterThanOrEqual(110);
    for (const id of insertIds) {
      expect(
        PRIOR_IDS.includes(id),
        `0007 INSERTs prior-owned id ${id} (must be additive-only)`,
      ).toBe(false);
    }

    // The only id 0007 is allowed to write to that pre-exists is
    // ex_db_press, and only via UPDATE (alias backfill), never INSERT.
    expect(insertIds).not.toContain('ex_db_press');
    expect(
      /UPDATE\s+exercises\s+SET\s+aliases\s*=.*WHERE\s+id\s*=\s*'ex_db_press'/i.test(
        sql,
      ),
      '0007 must contain the idempotent ex_db_press alias UPDATE',
    ).toBe(true);
  });

  it("0004's timed exercises survive untouched (plank/side plank stay timed/sec)", async () => {
    for (const [id, name] of [
      ['ex_plank', 'Plank'],
      ['ex_side_plank', 'Side Plank'],
    ] as const) {
      const row = await env.DB.prepare(
        'SELECT id,name,modality,unit FROM exercises WHERE id = ?1',
      )
        .bind(id)
        .first<{ id: string; name: string; modality: string; unit: string }>();
      expect(row, `${id} missing`).toBeTruthy();
      expect(row!.name).toBe(name);
      // 0004 defined these as timed/sec; 0007 must NOT have overwritten
      // them with the generator's stale bw/lb values.
      expect(row!.modality, `${id} modality clobbered`).toBe('timed');
      expect(row!.unit, `${id} unit clobbered`).toBe('sec');
      // and they still resolve by their natural phrase
      const r = await resolveExercise(env.DB, name);
      expect((r as { id: string })?.id).toBe(id);
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

    // The ex_db_press alias backfill UPDATE must be IDEMPOTENT on replay:
    // re-running 0007 must leave the alias array EXACTLY as 0007's UPDATE
    // sets it -- it must NOT grow (e.g. a future switch to json_insert /
    // append-on-conflict would duplicate "dumbbell press" and this guards
    // that). Strict equality, not a contains-check.
    const EXPECTED_DB_PRESS_ALIASES =
      '["db press", "dumbbell bench", "db bench", "dumbbell press"]';
    const dbp = await env.DB.prepare(
      "SELECT aliases FROM exercises WHERE id = 'ex_db_press'",
    ).first<{ aliases: string }>();
    expect(dbp, 'ex_db_press missing after replay').toBeTruthy();
    // (a) exact literal that 0007's UPDATE sets -- no growth, no reorder.
    expect(dbp!.aliases).toBe(EXPECTED_DB_PRESS_ALIASES);
    // (b) "dumbbell press" appears EXACTLY once (proves the array did not
    //     accumulate the alias across the original apply + this replay).
    const occurrences = dbp!.aliases.split('"dumbbell press"').length - 1;
    expect(
      occurrences,
      `"dumbbell press" should appear exactly once, found ${occurrences} in ${dbp!.aliases}`,
    ).toBe(1);
    // and it must still be valid JSON of exactly 4 elements.
    expect(JSON.parse(dbp!.aliases)).toEqual([
      'db press',
      'dumbbell bench',
      'db bench',
      'dumbbell press',
    ]);
  });
});
