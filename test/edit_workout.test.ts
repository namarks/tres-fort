import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';

// In-app workout editing (migration 0026): per-slot PATCH/DELETE over REST,
// the warm-up flag on a plan slot, and the erg/cardio catalog rows that make
// an "erg warm-up" representable. These are thin wrappers over the same
// updateExercise / deleteTemplateExercise the MCP tools use, so the tests
// assert the REST contract (status codes, version bumps, audit trail, slot
// inheritance on logged sets) rather than re-deriving db.ts internals.

const BASE = 'https://tres-fort.test';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

async function devJwt(): Promise<string> {
  const r = await SELF.fetch(`${BASE}/auth/dev`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ secret: 'test-dev' }),
  });
  expect(r.status).toBe(200);
  return (await r.json<{ jwt: string }>()).jwt;
}

const auth = (jwt: string) => ({
  'content-type': 'application/json',
  Authorization: `Bearer ${jwt}`,
});

/** Fresh active plan + one day; returns the day id. */
async function freshDay(H: Record<string, string>, name: string): Promise<string> {
  await SELF.fetch(`${BASE}/api/plan`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({ name }),
  });
  const day = await (
    await SELF.fetch(`${BASE}/api/days`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ name: 'Day A', day_label: 'A', order_index: 0 }),
    })
  ).json<{ id: string }>();
  return day.id;
}

async function addExercise(
  H: Record<string, string>,
  dayId: string,
  body: Record<string, unknown>,
) {
  return SELF.fetch(`${BASE}/api/days/${dayId}/exercises`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify(body),
  });
}

describe('the erg/cardio catalog (migration 0026)', () => {
  it('resolves an erg warm-up by its common aliases', async () => {
    const jwt = await devJwt();
    const H = auth(jwt);
    const dayId = await freshDay(H, 'Erg test');
    // "erg" and "rower" both resolve to the seeded Rowing Erg.
    for (const name of ['erg', 'rower', 'concept2']) {
      const r = await addExercise(H, dayId, {
        exercise: name,
        target_sets: 1,
        target_reps: 1,
        is_warmup: true,
        target_duration_s: 300,
        // unique order so each append lands; backend densifies anyway
        order_index: 99,
      });
      expect(r.status, `add ${name}`).toBe(201);
      const row = await r.json<{ exercise_id: string }>();
      expect(row.exercise_id, `${name} → ex_row_erg`).toBe('ex_row_erg');
    }
  });
});

describe('add / edit / delete a plan slot over REST', () => {
  it('adds a warm-up slot, surfaces it in the tree, bumps version, audits', async () => {
    const jwt = await devJwt();
    const H = auth(jwt);
    const dayId = await freshDay(H, 'Warmup add');

    const before = await (
      await SELF.fetch(`${BASE}/api/plan/active`, { headers: H })
    ).json<{ version: number }>();

    const r = await addExercise(H, dayId, {
      exercise: 'rowing erg',
      target_sets: 1,
      target_reps: 1,
      is_warmup: true,
      target_duration_s: 300,
    });
    expect(r.status).toBe(201);
    const slot = await r.json<{ id: string; is_warmup: number; exercise_id: string }>();
    expect(slot.is_warmup).toBe(1);

    // It rides the plan tree with the warm-up flag intact, and the version bumped.
    const tree = await (
      await SELF.fetch(`${BASE}/api/plan/active`, { headers: H })
    ).json<{ version: number; days: { id: string; exercises: { id: string; is_warmup: number }[] }[] }>();
    expect(tree.version).toBeGreaterThan(before.version);
    const day = tree.days.find((d) => d.id === dayId)!;
    const found = day.exercises.find((e) => e.id === slot.id)!;
    expect(found.is_warmup).toBe(1);

    // An ios-actor audit row records the edit (trust/undo trail).
    const audit = await env.DB.prepare(
      "SELECT result FROM audit_log WHERE tool = 'add_exercise' AND actor = 'ios' AND result = ?1",
    )
      .bind(slot.id)
      .first<{ result: string }>();
    expect(audit?.result).toBe(slot.id);
  });

  it('edits a slot in place (targets + warm-up flip) and rejects unknown fields', async () => {
    const jwt = await devJwt();
    const H = auth(jwt);
    const dayId = await freshDay(H, 'Edit slot');
    const slot = await (
      await addExercise(H, dayId, { exercise: 'bench', target_sets: 3, target_reps: 5 })
    ).json<{ id: string; is_warmup: number }>();
    expect(slot.is_warmup).toBe(0);

    const patched = await SELF.fetch(`${BASE}/api/days/${dayId}/exercises/${slot.id}`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ target_sets: 5, is_warmup: true }),
    });
    expect(patched.status).toBe(200);
    const after = await patched.json<{ target_sets: number; is_warmup: number }>();
    expect(after.target_sets).toBe(5);
    expect(after.is_warmup).toBe(1);

    // Unknown patch key → 400 unknown_fields (no silent drop).
    const bad = await SELF.fetch(`${BASE}/api/days/${dayId}/exercises/${slot.id}`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ bogus: 1 }),
    });
    expect(bad.status).toBe(400);
    expect(await bad.json<{ error: string }>()).toMatchObject({ error: 'unknown_fields' });

    // Unknown slot id → 404.
    const missing = await SELF.fetch(`${BASE}/api/days/${dayId}/exercises/nope`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ target_sets: 2 }),
    });
    expect(missing.status).toBe(404);
  });

  it('deletes a slot but detaches (not deletes) its logged sets', async () => {
    const jwt = await devJwt();
    const H = auth(jwt);
    const dayId = await freshDay(H, 'Delete slot');
    const slot = await (
      await addExercise(H, dayId, { exercise: 'squat', target_sets: 3, target_reps: 5 })
    ).json<{ id: string; exercise_id: string }>();

    const session = await (
      await SELF.fetch(`${BASE}/api/sessions`, {
        method: 'POST',
        headers: H,
        body: JSON.stringify({ date: '2026-06-01', day_template_id: dayId }),
      })
    ).json<{ id: string }>();

    const setId = crypto.randomUUID();
    await SELF.fetch(`${BASE}/api/sessions/${session.id}/sets`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({
        id: setId,
        exercise_id: slot.exercise_id,
        template_exercise_id: slot.id,
        set_index: 1,
        weight: 135,
        reps: 5,
      }),
    });

    const del = await SELF.fetch(`${BASE}/api/days/${dayId}/exercises/${slot.id}`, {
      method: 'DELETE',
      headers: H,
    });
    expect(del.status).toBe(200);

    // The slot is gone from the tree…
    const tree = await (
      await SELF.fetch(`${BASE}/api/plan/active`, { headers: H })
    ).json<{ days: { id: string; exercises: { id: string }[] }[] }>();
    const day = tree.days.find((d) => d.id === dayId)!;
    expect(day.exercises.find((e) => e.id === slot.id)).toBeUndefined();

    // …but the logged set survives, with its slot link nulled out.
    const setRow = await env.DB.prepare(
      'SELECT template_exercise_id, deleted_at FROM set_logs WHERE id = ?1',
    )
      .bind(setId)
      .first<{ template_exercise_id: string | null; deleted_at: number | null }>();
    expect(setRow?.deleted_at).toBeNull();
    expect(setRow?.template_exercise_id).toBeNull();

    // Deleting an unknown slot → 404.
    const missing = await SELF.fetch(`${BASE}/api/days/${dayId}/exercises/${slot.id}`, {
      method: 'DELETE',
      headers: H,
    });
    expect(missing.status).toBe(404);
  });

  it('reorders slots by patching order_index', async () => {
    const jwt = await devJwt();
    const H = auth(jwt);
    const dayId = await freshDay(H, 'Reorder');
    const a = await (
      await addExercise(H, dayId, { exercise: 'bench', target_sets: 3, target_reps: 5, order_index: 0 })
    ).json<{ id: string }>();
    const b = await (
      await addExercise(H, dayId, { exercise: 'squat', target_sets: 3, target_reps: 5, order_index: 1 })
    ).json<{ id: string }>();

    // Move the second slot to the front.
    const moved = await SELF.fetch(`${BASE}/api/days/${dayId}/exercises/${b.id}`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ order_index: 0 }),
    });
    expect(moved.status).toBe(200);

    const tree = await (
      await SELF.fetch(`${BASE}/api/plan/active`, { headers: H })
    ).json<{ days: { id: string; exercises: { id: string }[] }[] }>();
    const day = tree.days.find((d) => d.id === dayId)!;
    expect(day.exercises.map((e) => e.id)).toEqual([b.id, a.id]);
  });
});

describe('logging a set against a warm-up slot inherits is_warmup', () => {
  it('stores is_warmup=1 from the slot when the client omits the flag', async () => {
    const jwt = await devJwt();
    const H = auth(jwt);
    const dayId = await freshDay(H, 'Warmup inherit');
    const slot = await (
      await addExercise(H, dayId, {
        exercise: 'rowing erg',
        target_sets: 1,
        target_reps: 1,
        is_warmup: true,
        target_duration_s: 300,
      })
    ).json<{ id: string; exercise_id: string }>();

    const session = await (
      await SELF.fetch(`${BASE}/api/sessions`, {
        method: 'POST',
        headers: H,
        body: JSON.stringify({ date: '2026-06-02', day_template_id: dayId }),
      })
    ).json<{ id: string }>();

    // Note: NO is_warmup in the body — the slot link supplies it.
    const setId = crypto.randomUUID();
    const r = await SELF.fetch(`${BASE}/api/sessions/${session.id}/sets`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({
        id: setId,
        exercise_id: slot.exercise_id,
        template_exercise_id: slot.id,
        set_index: 1,
        weight: 0,
        reps: 300,
        duration_s: 300,
        is_timed: true,
      }),
    });
    expect(r.status).toBe(201);
    expect(await r.json<{ set: { is_warmup: number } }>()).toMatchObject({
      set: { is_warmup: 1 },
    });
  });

  it('defaults a cardio set to is_timed even when the caller omits the flag', async () => {
    // Codex P2: cardio (erg/treadmill) is duration-driven, so a caller that
    // logs duration_s without an explicit is_timed must still persist a timed
    // set — otherwise clients render the effort as reps.
    const jwt = await devJwt();
    const H = auth(jwt);
    await SELF.fetch(`${BASE}/api/plan`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ name: 'Cardio timed default' }),
    });
    const session = await (
      await SELF.fetch(`${BASE}/api/sessions`, {
        method: 'POST',
        headers: H,
        body: JSON.stringify({ date: '2026-06-03' }),
      })
    ).json<{ id: string }>();

    const setId = crypto.randomUUID();
    const r = await SELF.fetch(`${BASE}/api/sessions/${session.id}/sets`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({
        id: setId,
        exercise_id: 'ex_row_erg',
        set_index: 1,
        weight: 0,
        reps: 300,
        duration_s: 300,
        // NO is_timed — the cardio modality must supply the default.
      }),
    });
    expect(r.status).toBe(201);
    expect(await r.json<{ set: { is_timed: number } }>()).toMatchObject({
      set: { is_timed: 1 },
    });
  });

  it('drops a dangling template_exercise_id instead of failing the insert', async () => {
    // Plan-rebuild race: a stale client sends a slot id update_plan has since
    // deleted. template_exercise_id is an enforced FK, so inserting it would
    // 500 and block logging. The set must still land as an exercise-only log.
    const jwt = await devJwt();
    const H = auth(jwt);
    await SELF.fetch(`${BASE}/api/plan`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ name: 'Dangling slot' }),
    });
    const session = await (
      await SELF.fetch(`${BASE}/api/sessions`, {
        method: 'POST',
        headers: H,
        body: JSON.stringify({ date: '2026-06-04' }),
      })
    ).json<{ id: string }>();

    const setId = crypto.randomUUID();
    const r = await SELF.fetch(`${BASE}/api/sessions/${session.id}/sets`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({
        id: setId,
        exercise_id: 'ex_bench',
        template_exercise_id: 'te_does_not_exist',
        set_index: 1,
        weight: 135,
        reps: 5,
      }),
    });
    expect(r.status).toBe(201);
    // Link nulled (not the bogus id), set preserved.
    expect(await r.json<{ set: { template_exercise_id: string | null } }>()).toMatchObject({
      set: { template_exercise_id: null },
    });
    const row = await env.DB.prepare(
      'SELECT template_exercise_id FROM set_logs WHERE id = ?1',
    )
      .bind(setId)
      .first<{ template_exercise_id: string | null }>();
    expect(row?.template_exercise_id).toBeNull();
  });

  it('drops a template_exercise_id whose slot now holds a different exercise', async () => {
    // Stale-swap race: the slot still EXISTS but was swapped to another movement
    // mid-workout while iOS cached the old slot id. Keeping the link would file
    // this set under the swapped-in slot and todaySlotSets would mark the wrong
    // slot complete. The link must drop to null (exercise-only log), set kept.
    const jwt = await devJwt();
    const H = auth(jwt);
    const dayId = await freshDay(H, 'Stale swap');
    // A real bench slot — exists, but holds ex_bench, not the squat we log.
    const slot = await (
      await addExercise(H, dayId, { exercise: 'bench', target_sets: 3, target_reps: 5 })
    ).json<{ id: string; exercise_id: string }>();
    expect(slot.exercise_id).toBe('ex_bench');

    const session = await (
      await SELF.fetch(`${BASE}/api/sessions`, {
        method: 'POST',
        headers: H,
        body: JSON.stringify({ date: '2026-06-05', day_template_id: dayId }),
      })
    ).json<{ id: string }>();

    const setId = crypto.randomUUID();
    const r = await SELF.fetch(`${BASE}/api/sessions/${session.id}/sets`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({
        id: setId,
        exercise_id: 'ex_back_squat', // mismatched: slot holds ex_bench
        template_exercise_id: slot.id,
        set_index: 1,
        weight: 225,
        reps: 5,
      }),
    });
    expect(r.status).toBe(201);
    expect(await r.json<{ set: { template_exercise_id: string | null } }>()).toMatchObject({
      set: { template_exercise_id: null },
    });
    const row = await env.DB.prepare(
      'SELECT template_exercise_id FROM set_logs WHERE id = ?1',
    )
      .bind(setId)
      .first<{ template_exercise_id: string | null }>();
    expect(row?.template_exercise_id).toBeNull();
  });
});

describe('slot PATCH/DELETE are scoped to the URL day', () => {
  // The nested /days/:id/exercises/:teId routes claim a day in their path. A
  // stale edit sheet or mixed-up client must not mutate/delete a slot that
  // lives in a DIFFERENT day just because teId is globally unique.
  async function planWithTwoDays(H: Record<string, string>) {
    const dayA = await freshDay(H, 'Two day plan'); // creates plan + Day A
    const dayB = await (
      await SELF.fetch(`${BASE}/api/days`, {
        method: 'POST',
        headers: H,
        body: JSON.stringify({ name: 'Day B', day_label: 'B', order_index: 1 }),
      })
    ).json<{ id: string }>();
    const slotB = await (
      await addExercise(H, dayB.id, { exercise: 'bench', target_sets: 3, target_reps: 5 })
    ).json<{ id: string; target_sets: number }>();
    return { dayA, dayB: dayB.id, slotB };
  }

  it('PATCH via the wrong day 404s and leaves the slot unchanged', async () => {
    const H = auth(await devJwt());
    const { dayA, slotB } = await planWithTwoDays(H);

    const r = await SELF.fetch(`${BASE}/api/days/${dayA}/exercises/${slotB.id}`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ target_sets: 99 }),
    });
    expect(r.status).toBe(404);

    const row = await env.DB.prepare('SELECT target_sets FROM template_exercises WHERE id = ?1')
      .bind(slotB.id)
      .first<{ target_sets: number }>();
    expect(row?.target_sets).toBe(3); // untouched
  });

  it('DELETE via the wrong day 404s and leaves the slot intact; the right day succeeds', async () => {
    const H = auth(await devJwt());
    const { dayA, dayB, slotB } = await planWithTwoDays(H);

    const wrong = await SELF.fetch(`${BASE}/api/days/${dayA}/exercises/${slotB.id}`, {
      method: 'DELETE',
      headers: H,
    });
    expect(wrong.status).toBe(404);
    const stillThere = await env.DB.prepare('SELECT id FROM template_exercises WHERE id = ?1')
      .bind(slotB.id)
      .first<{ id: string }>();
    expect(stillThere?.id).toBe(slotB.id);

    // The correct day path deletes it.
    const right = await SELF.fetch(`${BASE}/api/days/${dayB}/exercises/${slotB.id}`, {
      method: 'DELETE',
      headers: H,
    });
    expect(right.status).toBe(200);
    const gone = await env.DB.prepare('SELECT id FROM template_exercises WHERE id = ?1')
      .bind(slotB.id)
      .first<{ id: string }>();
    expect(gone).toBeNull();
  });
});
