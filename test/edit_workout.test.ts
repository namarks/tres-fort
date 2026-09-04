import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { getProjectedCalendar } from '../src/db';

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

describe('manual routine authoring over REST', () => {
  it('ensures a plan without replacing a concurrent or existing active plan', async () => {
    const jwt = await devJwt();
    const H = auth(jwt);
    const blank = await SELF.fetch(`${BASE}/api/plan/active`, {
      method: 'PUT', headers: H,
      body: JSON.stringify({ name: '   ' }),
    });
    expect(blank.status).toBe(400);
    const existing = await (
      await SELF.fetch(`${BASE}/api/plan`, {
        method: 'POST', headers: H,
        body: JSON.stringify({ name: 'Coach Plan' }),
      })
    ).json<{ id: string; user_id: string; version: number }>();

    const keptResponse = await SELF.fetch(`${BASE}/api/plan/active`, {
      method: 'PUT', headers: H,
      body: JSON.stringify({ name: 'Stale App Plan' }),
    });
    expect(keptResponse.status).toBe(200);
    const kept = await keptResponse.json<{
      plan: { id: string; name: string; version: number };
      created: boolean;
    }>();
    expect(kept).toMatchObject({
      created: false,
      plan: { id: existing.id, name: 'Coach Plan', version: existing.version },
    });
    const wrongWinner = await SELF.fetch(`${BASE}/api/days`, {
      method: 'POST', headers: H,
      body: JSON.stringify({
        name: 'Stale first day',
        expected_plan_id: 'stale-plan-id',
        expected_version: existing.version,
      }),
    });
    expect(wrongWinner.status).toBe(409);
    expect(await wrongWinner.json()).toMatchObject({
      conflict: true,
      current_plan_id: existing.id,
      current_version: existing.version,
    });

    await env.DB.prepare("UPDATE plans SET status='archived' WHERE id=?1")
      .bind(existing.id).run();
    const createdResponse = await SELF.fetch(`${BASE}/api/plan/active`, {
      method: 'PUT', headers: H,
      body: JSON.stringify({ name: 'Member Plan' }),
    });
    expect(createdResponse.status).toBe(201);
    const created = await createdResponse.json<{
      plan: { id: string; name: string; version: number };
      created: boolean;
    }>();
    expect(created.created).toBe(true);
    expect(created.plan).toMatchObject({ name: 'Member Plan', version: 1 });

    const active = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM plans WHERE user_id=?1 AND status='active'",
    ).bind(existing.user_id).first<{ n: number }>();
    expect(active?.n).toBe(1);
    const audits = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM audit_log WHERE tool='ensure_active_plan' AND actor='ios'",
    ).first<{ n: number }>();
    expect(audits?.n).toBeGreaterThanOrEqual(2);
  });

  it('rejects a schedule draft bound to a replaced plan with the same version', async () => {
    const jwt = await devJwt();
    const H = auth(jwt);
    const original = await (
      await SELF.fetch(`${BASE}/api/plan`, {
        method: 'POST', headers: H,
        body: JSON.stringify({ name: 'Original Plan' }),
      })
    ).json<{ id: string; version: number }>();
    const replacement = await (
      await SELF.fetch(`${BASE}/api/plan`, {
        method: 'POST', headers: H,
        body: JSON.stringify({ name: 'Replacement Plan' }),
      })
    ).json<{ id: string; version: number }>();
    expect(replacement.version).toBe(original.version);

    const stale = await SELF.fetch(`${BASE}/api/plan/schedule`, {
      method: 'PUT', headers: H,
      body: JSON.stringify({
        week: {},
        expected_plan_id: original.id,
        expected_version: original.version,
      }),
    });
    expect(stale.status).toBe(409);
    expect(await stale.json()).toEqual({
      conflict: true,
      current_plan_id: replacement.id,
      current_version: replacement.version,
    });
    expect(await env.DB.prepare(
      'SELECT id,version,meta FROM plans WHERE status=\'active\'',
    ).first()).toEqual({ id: replacement.id, version: 1, meta: null });
  });

  it('creates and reorders days densely, rejects a stale version, and writes the weekly schedule', async () => {
    const jwt = await devJwt();
    const H = auth(jwt);
    const plan = await (
      await SELF.fetch(`${BASE}/api/plan`, {
        method: 'POST', headers: H,
        body: JSON.stringify({ name: 'Member Routine' }),
      })
    ).json<{ id: string; version: number }>();

    const dayA = await (
      await SELF.fetch(`${BASE}/api/days`, {
        method: 'POST', headers: H,
        body: JSON.stringify({ name: 'Upper', expected_version: plan.version }),
      })
    ).json<{ id: string; order_index: number }>();
    expect(dayA.order_index).toBe(0);
    const afterA = await (
      await SELF.fetch(`${BASE}/api/plan/active`, { headers: H })
    ).json<{ id: string; version: number }>();
    const dayB = await (
      await SELF.fetch(`${BASE}/api/days`, {
        method: 'POST', headers: H,
        body: JSON.stringify({ name: 'Lower', expected_version: afterA.version }),
      })
    ).json<{ id: string; order_index: number }>();
    expect(dayB.order_index).toBe(1);
    const afterB = await (
      await SELF.fetch(`${BASE}/api/plan/active`, { headers: H })
    ).json<{ id: string; version: number }>();

    const moved = await SELF.fetch(`${BASE}/api/days/${dayB.id}`, {
      method: 'PATCH', headers: H,
      body: JSON.stringify({ order_index: 0, expected_version: afterB.version }),
    });
    expect(moved.status).toBe(200);
    const afterMove = await (
      await SELF.fetch(`${BASE}/api/plan/active`, { headers: H })
    ).json<{ version: number; days: { id: string; order_index: number }[] }>();
    expect(afterMove.days.map((day) => [day.id, day.order_index])).toEqual([
      [dayB.id, 0], [dayA.id, 1],
    ]);

    const stale = await SELF.fetch(`${BASE}/api/days/${dayA.id}`, {
      method: 'PATCH', headers: H,
      body: JSON.stringify({ name: 'Should Not Win', expected_version: afterB.version }),
    });
    expect(stale.status).toBe(409);
    expect(await stale.json()).toMatchObject({
      conflict: true, current_version: afterMove.version,
    });

    const scheduled = await SELF.fetch(`${BASE}/api/plan/schedule`, {
      method: 'PUT', headers: H,
      body: JSON.stringify({
        week: { mon: dayB.id, wed: dayA.id, fri: dayB.id },
        expected_version: afterMove.version,
      }),
    });
    expect(scheduled.status).toBe(200);
    const scheduleResult = await scheduled.json<{
      version: number;
      schedule: { week: Record<string, string | null> };
    }>();
    expect(scheduleResult.schedule.week).toMatchObject({
      mon: dayB.id, tue: null, wed: dayA.id, fri: dayB.id,
    });

    const audits = await env.DB.prepare(
      "SELECT tool FROM audit_log WHERE actor='ios' AND tool IN ('add_day','update_day','set_schedule')",
    ).all<{ tool: string }>();
    expect(new Set(audits.results.map((row) => row.tool))).toEqual(
      new Set(['add_day', 'update_day', 'set_schedule']),
    );
  });

  it('lets only one same-version day write commit under concurrency', async () => {
    const jwt = await devJwt();
    const H = auth(jwt);
    const plan = await (
      await SELF.fetch(`${BASE}/api/plan`, {
        method: 'POST', headers: H,
        body: JSON.stringify({ name: 'Concurrent Routine' }),
      })
    ).json<{ id: string; version: number }>();

    const createDay = (name: string) => SELF.fetch(`${BASE}/api/days`, {
      method: 'POST', headers: H,
      body: JSON.stringify({
        name,
        expected_plan_id: plan.id,
        expected_version: plan.version,
      }),
    });
    const results = await Promise.all([createDay('Upper'), createDay('Lower')]);
    expect(results.map((response) => response.status).sort()).toEqual([201, 409]);

    const tree = await (
      await SELF.fetch(`${BASE}/api/plan/active`, { headers: H })
    ).json<{ version: number; days: { name: string; order_index: number }[] }>();
    expect(tree.version).toBe(plan.version + 1);
    expect(tree.days).toHaveLength(1);
    expect(tree.days[0]?.order_index).toBe(0);
    expect(['Upper', 'Lower']).toContain(tree.days[0]?.name);
  });

  it('walks barbell and bodyweight routines from iOS writes through Today projection and MCP editing', async () => {
    const jwt = await devJwt();
    const H = auth(jwt);
    const superseded = await (
      await SELF.fetch(`${BASE}/api/plan`, {
        method: 'POST', headers: H,
        body: JSON.stringify({ name: 'Superseded setup' }),
      })
    ).json<{ id: string; user_id: string }>();
    await env.DB.prepare("UPDATE plans SET status='archived' WHERE id=?1")
      .bind(superseded.id).run();
    const ensured = await (
      await SELF.fetch(`${BASE}/api/plan/active`, {
        method: 'PUT', headers: H,
        body: JSON.stringify({ name: 'Manual Strength' }),
      })
    ).json<{ plan: { id: string; version: number }; created: boolean }>();
    expect(ensured.created).toBe(true);

    const barbell = await (
      await SELF.fetch(`${BASE}/api/days`, {
        method: 'POST', headers: H,
        body: JSON.stringify({
          name: 'Barbell Day', expected_version: ensured.plan.version,
        }),
      })
    ).json<{ id: string }>();
    expect((await addExercise(H, barbell.id, {
      exercise: 'squat', target_sets: 3, target_reps: 5, rest_seconds: 180,
    })).status).toBe(201);

    let current = await (
      await SELF.fetch(`${BASE}/api/plan/active`, { headers: H })
    ).json<{ id: string; version: number }>();
    const bodyweight = await (
      await SELF.fetch(`${BASE}/api/days`, {
        method: 'POST', headers: H,
        body: JSON.stringify({
          name: 'Bodyweight Day', expected_version: current.version,
        }),
      })
    ).json<{ id: string }>();
    const slots: { id: string; exercise_id: string }[] = [];
    for (const prescription of [
      { exercise: 'pull-up', target_sets: 3, target_reps: 5, rest_seconds: 120 },
      { exercise: 'push-up', target_sets: 3, target_reps: 12, rest_seconds: 90 },
      {
        exercise: 'plank', target_sets: 3, target_reps: 45,
        target_duration_s: 45, rest_seconds: 60,
      },
    ]) {
      const response = await addExercise(H, bodyweight.id, prescription);
      expect(response.status).toBe(201);
      slots.push(await response.json<{ id: string; exercise_id: string }>());
    }

    current = await (
      await SELF.fetch(`${BASE}/api/plan/active`, { headers: H })
    ).json<{ id: string; version: number }>();
    const schedule = await SELF.fetch(`${BASE}/api/plan/schedule`, {
      method: 'PUT', headers: H,
      body: JSON.stringify({
        week: {
          mon: bodyweight.id,
          wed: bodyweight.id,
          thu: barbell.id,
          fri: bodyweight.id,
        },
        expected_version: current.version,
      }),
    });
    expect(schedule.status).toBe(200);

    // iOS reloads through the sync endpoint; the authored plan and schedule
    // must be present there before the client projects Today.
    const synced = await (
      await SELF.fetch(`${BASE}/api/state`, { headers: H })
    ).json<{ plan: { id: string; meta: string } | null }>();
    expect(synced.plan?.id).toBe(ensured.plan.id);
    expect(JSON.parse(synced.plan!.meta).schedule.week).toMatchObject({
      mon: bodyweight.id,
      wed: bodyweight.id,
      thu: barbell.id,
      fri: bodyweight.id,
    });

    // 2026-09-03 is Thursday: the recurring member-authored barbell day is
    // immediately the real Today projection and points at the same template.
    const today = await getProjectedCalendar(
      env.DB, superseded.user_id,
      '2026-09-03', '2026-09-03', '2026-09-03',
    );
    expect(today[0]).toMatchObject({
      status: 'projected', day_template_id: barbell.id, real: false,
    });

    const mcp = async (name: string, args: Record<string, unknown>) => {
      const response = await SELF.fetch(`${BASE}/mcp`, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          Authorization: 'Bearer test-mcp-token',
        },
        body: JSON.stringify({
          jsonrpc: '2.0', id: crypto.randomUUID(), method: 'tools/call',
          params: { name, arguments: args },
        }),
      });
      expect(response.status).toBe(200);
      const rpc = await response.json<any>();
      return JSON.parse(rpc.result.content[0].text);
    };
    const coachTree = await mcp('get_current_plan', {});
    const coachBodyweight = coachTree.days.find(
      (day: { id: string }) => day.id === bodyweight.id,
    );
    expect(coachBodyweight.exercises).toMatchObject([
      { exercise_id: 'ex_pullup', target_sets: 3, target_reps: 5 },
      { exercise_id: 'ex_pushup', target_sets: 3, target_reps: 12 },
      { exercise_id: 'ex_plank', target_sets: 3, target_duration_s: 45 },
    ]);

    // The coach edits the exact slot created by iOS; the REST tree immediately
    // returns that shared mutation rather than a copied/manual-only workout.
    const coachEdit = await mcp('update_exercise', {
      template_exercise_id: slots[2]!.id,
      patch: { target_reps: 60, target_duration_s: 60 },
    });
    expect(coachEdit).toMatchObject({
      id: slots[2]!.id, target_reps: 60, target_duration_s: 60,
    });
    const appTree = await (
      await SELF.fetch(`${BASE}/api/plan/active`, { headers: H })
    ).json<{
      days: { id: string; exercises: { id: string; target_duration_s: number | null }[] }[];
    }>();
    expect(appTree.days.find((day) => day.id === bodyweight.id)
      ?.exercises.find((slot) => slot.id === slots[2]!.id)?.target_duration_s).toBe(60);
  });

  it('assigns a workout or rest to one date without changing the routine version', async () => {
    const jwt = await devJwt();
    const H = auth(jwt);
    const dayId = await freshDay(H, 'Date overrides');
    const before = await (
      await SELF.fetch(`${BASE}/api/plan/active`, { headers: H })
    ).json<{ version: number; meta: string | null }>();

    const workout = await SELF.fetch(`${BASE}/api/calendar/2026-11-05`, {
      method: 'PUT', headers: H,
      body: JSON.stringify({ day_template_id: dayId }),
    });
    expect(workout.status).toBe(200);
    expect(await workout.json()).toMatchObject({
      ok: true,
      session: {
        date: '2026-11-05', day_template_id: dayId,
        status: 'planned', attempt: 1,
      },
    });
    const rest = await SELF.fetch(`${BASE}/api/calendar/2026-11-06`, {
      method: 'PUT', headers: H,
      body: JSON.stringify({ day_template_id: null }),
    });
    expect(rest.status).toBe(200);
    expect(await rest.json()).toMatchObject({
      ok: true,
      session: { date: '2026-11-06', status: 'skipped', attempt: 1 },
    });

    for (const [date, day_template_id] of [
      ['2026-11-15', dayId],
      ['2026-11-16', null],
    ] as const) {
      const staleAbsence = await SELF.fetch(`${BASE}/api/calendar/${date}`, {
        method: 'PUT', headers: H,
        body: JSON.stringify({ day_template_id, expected_attempt: 2 }),
      });
      expect(staleAbsence.status).toBe(409);
      expect(await staleAbsence.json()).toEqual({
        error: 'session_attempt_missing', expected_attempt: 2,
      });
    }

    const after = await (
      await SELF.fetch(`${BASE}/api/plan/active`, { headers: H })
    ).json<{ version: number; meta: string | null }>();
    expect(after).toEqual(before);
  });

  it('refuses to retag a concrete date after its workout has started', async () => {
    const jwt = await devJwt();
    const H = auth(jwt);
    const firstDay = await freshDay(H, 'Started date');
    const plan = await (
      await SELF.fetch(`${BASE}/api/plan/active`, { headers: H })
    ).json<{ version: number }>();
    const secondDay = await (
      await SELF.fetch(`${BASE}/api/days`, {
        method: 'POST', headers: H,
        body: JSON.stringify({ name: 'Other day', expected_version: plan.version }),
      })
    ).json<{ id: string }>();
    const session = await (
      await SELF.fetch(`${BASE}/api/sessions`, {
        method: 'POST', headers: H,
        body: JSON.stringify({ date: '2026-11-08', day_template_id: firstDay }),
      })
    ).json<{ id: string; attempt: number }>();
    const started = await SELF.fetch(`${BASE}/api/sessions/${session.id}`, {
      method: 'PATCH', headers: H,
      body: JSON.stringify({ status: 'in_progress' }),
    });
    expect(started.status).toBe(200);

    const retag = await SELF.fetch(`${BASE}/api/calendar/2026-11-08`, {
      method: 'PUT', headers: H,
      body: JSON.stringify({
        day_template_id: secondDay.id,
        expected_attempt: session.attempt,
      }),
    });
    expect(retag.status).toBe(409);
    expect(await retag.json()).toMatchObject({
      error: 'session_already_started', status: 'in_progress',
    });
    const kept = await env.DB.prepare(
      'SELECT status, day_template_id FROM sessions WHERE id=?1',
    ).bind(session.id).first<{ status: string; day_template_id: string | null }>();
    expect(kept).toEqual({ status: 'in_progress', day_template_id: firstDay });

    expect((await SELF.fetch(`${BASE}/api/sessions/${session.id}`, {
      method: 'PATCH', headers: H,
      body: JSON.stringify({ status: 'completed' }),
    })).status).toBe(200);
    const completedRetag = await SELF.fetch(`${BASE}/api/calendar/2026-11-08`, {
      method: 'PUT', headers: H,
      body: JSON.stringify({
        day_template_id: secondDay.id,
        expected_attempt: session.attempt,
      }),
    });
    expect(completedRetag.status).toBe(409);
    expect(await completedRetag.json()).toMatchObject({
      error: 'session_already_started', status: 'completed',
    });
  });

  it('removes a trained day while preserving its session and set history', async () => {
    const jwt = await devJwt();
    const H = auth(jwt);
    const dayId = await freshDay(H, 'Delete trained day');
    const slot = await (
      await addExercise(H, dayId, {
        exercise: 'squat', target_sets: 3, target_reps: 5,
      })
    ).json<{ id: string; exercise_id: string }>();
    const session = await (
      await SELF.fetch(`${BASE}/api/sessions`, {
        method: 'POST', headers: H,
        body: JSON.stringify({ date: '2026-11-07', day_template_id: dayId }),
      })
    ).json<{ id: string }>();
    const setId = crypto.randomUUID();
    const logged = await SELF.fetch(`${BASE}/api/sessions/${session.id}/sets`, {
      method: 'POST', headers: H,
      body: JSON.stringify({
        id: setId,
        exercise_id: slot.exercise_id,
        template_exercise_id: slot.id,
        set_index: 1,
        weight: 185,
        reps: 5,
      }),
    });
    expect(logged.status).toBe(201);
    const completed = await SELF.fetch(`${BASE}/api/sessions/${session.id}`, {
      method: 'PATCH', headers: H,
      body: JSON.stringify({ status: 'completed' }),
    });
    expect(completed.status).toBe(200);
    await env.DB.prepare('UPDATE sessions SET updated_at=1 WHERE id=?1')
      .bind(session.id)
      .run();
    const version = (await (
      await SELF.fetch(`${BASE}/api/plan/active`, { headers: H })
    ).json<{ version: number }>()).version;

    const removed = await SELF.fetch(
      `${BASE}/api/days/${dayId}?expected_version=${version}`,
      { method: 'DELETE', headers: H },
    );
    expect(removed.status).toBe(200);

    const keptSession = await env.DB.prepare(
      'SELECT status, day_template_id, updated_at FROM sessions WHERE id=?1',
    ).bind(session.id).first<{
      status: string; day_template_id: string | null; updated_at: number;
    }>();
    expect(keptSession).toMatchObject({ status: 'completed', day_template_id: null });
    expect(keptSession!.updated_at).toBeGreaterThan(1);
    const keptSet = await env.DB.prepare(
      'SELECT reps, template_exercise_id, deleted_at FROM set_logs WHERE id=?1',
    ).bind(setId).first<{
      reps: number; template_exercise_id: string | null; deleted_at: number | null;
    }>();
    expect(keptSet).toEqual({ reps: 5, template_exercise_id: null, deleted_at: null });
  });

  it('resolves null-template sessions through the schedule before removing a day', async () => {
    const jwt = await devJwt();
    const H = auth(jwt);
    const plannedDay = await freshDay(H, 'Planned deletion');
    let plan = await (
      await SELF.fetch(`${BASE}/api/plan/active`, { headers: H })
    ).json<{ id: string; version: number }>();
    const activeDay = await (
      await SELF.fetch(`${BASE}/api/days`, {
        method: 'POST', headers: H,
        body: JSON.stringify({ name: 'Active deletion', expected_version: plan.version }),
      })
    ).json<{ id: string }>();
    plan = await (
      await SELF.fetch(`${BASE}/api/plan/active`, { headers: H })
    ).json<{ id: string; version: number }>();
    expect((await SELF.fetch(`${BASE}/api/plan/schedule`, {
      method: 'PUT', headers: H,
      body: JSON.stringify({
        week: { mon: plannedDay, tue: activeDay.id },
        expected_plan_id: plan.id,
        expected_version: plan.version,
      }),
    })).status).toBe(200);
    const planned = await (
      await SELF.fetch(`${BASE}/api/sessions`, {
        method: 'POST', headers: H,
        body: JSON.stringify({ date: '2026-11-09' }),
      })
    ).json<{ id: string; day_template_id: string | null }>();
    const active = await (
      await SELF.fetch(`${BASE}/api/sessions`, {
        method: 'POST', headers: H,
        body: JSON.stringify({ date: '2026-11-10' }),
      })
    ).json<{ id: string; day_template_id: string | null }>();
    expect(planned.day_template_id).toBeNull();
    expect(active.day_template_id).toBeNull();
    expect((await SELF.fetch(`${BASE}/api/sessions/${active.id}`, {
      method: 'PATCH', headers: H,
      body: JSON.stringify({ status: 'in_progress' }),
    })).status).toBe(200);

    plan = await (
      await SELF.fetch(`${BASE}/api/plan/active`, { headers: H })
    ).json<{ id: string; version: number }>();
    expect((await SELF.fetch(
      `${BASE}/api/days/${plannedDay}?expected_version=${plan.version}`,
      { method: 'DELETE', headers: H },
    )).status).toBe(200);
    expect(await env.DB.prepare(
      'SELECT status, day_template_id FROM sessions WHERE id=?1',
    ).bind(planned.id).first()).toEqual({ status: 'skipped', day_template_id: null });

    plan = await (
      await SELF.fetch(`${BASE}/api/plan/active`, { headers: H })
    ).json<{ id: string; version: number }>();
    const rejected = await SELF.fetch(
      `${BASE}/api/days/${activeDay.id}?expected_version=${plan.version}`,
      { method: 'DELETE', headers: H },
    );
    expect(rejected.status).toBe(409);
    expect(await rejected.json()).toEqual({ error: 'day_in_progress' });
    expect(await env.DB.prepare(
      'SELECT status, day_template_id FROM sessions WHERE id=?1',
    ).bind(active.id).first()).toEqual({
      status: 'in_progress', day_template_id: null,
    });
  });

  it('does not infer archived-plan sessions as references to a current scheduled day', async () => {
    const jwt = await devJwt();
    const H = auth(jwt);
    const archivedDay = await freshDay(H, 'Archived plan');
    let archivedPlan = await (
      await SELF.fetch(`${BASE}/api/plan/active`, { headers: H })
    ).json<{ id: string; version: number }>();
    expect((await SELF.fetch(`${BASE}/api/plan/schedule`, {
      method: 'PUT', headers: H,
      body: JSON.stringify({
        week: { mon: archivedDay },
        expected_plan_id: archivedPlan.id,
        expected_version: archivedPlan.version,
      }),
    })).status).toBe(200);
    archivedPlan = await (
      await SELF.fetch(`${BASE}/api/plan/active`, { headers: H })
    ).json<{ id: string; version: number }>();
    const oldActive = await (
      await SELF.fetch(`${BASE}/api/sessions`, {
        method: 'POST', headers: H,
        body: JSON.stringify({ date: '2026-11-02' }),
      })
    ).json<{ id: string }>();
    const oldPlanned = await (
      await SELF.fetch(`${BASE}/api/sessions`, {
        method: 'POST', headers: H,
        body: JSON.stringify({ date: '2026-11-09' }),
      })
    ).json<{ id: string }>();
    expect((await SELF.fetch(`${BASE}/api/sessions/${oldActive.id}`, {
      method: 'PATCH', headers: H,
      body: JSON.stringify({ status: 'in_progress' }),
    })).status).toBe(200);

    const replacement = await (
      await SELF.fetch(`${BASE}/api/plan`, {
        method: 'POST', headers: H,
        body: JSON.stringify({ name: 'Current plan' }),
      })
    ).json<{ id: string; version: number }>();
    const currentDay = await (
      await SELF.fetch(`${BASE}/api/days`, {
        method: 'POST', headers: H,
        body: JSON.stringify({
          name: 'Current Monday',
          expected_plan_id: replacement.id,
          expected_version: replacement.version,
        }),
      })
    ).json<{ id: string }>();
    let currentPlan = await (
      await SELF.fetch(`${BASE}/api/plan/active`, { headers: H })
    ).json<{ id: string; version: number }>();
    expect((await SELF.fetch(`${BASE}/api/plan/schedule`, {
      method: 'PUT', headers: H,
      body: JSON.stringify({
        week: { mon: currentDay.id },
        expected_plan_id: currentPlan.id,
        expected_version: currentPlan.version,
      }),
    })).status).toBe(200);
    currentPlan = await (
      await SELF.fetch(`${BASE}/api/plan/active`, { headers: H })
    ).json<{ id: string; version: number }>();

    const removed = await SELF.fetch(
      `${BASE}/api/days/${currentDay.id}?expected_version=${currentPlan.version}`,
      { method: 'DELETE', headers: H },
    );
    expect(removed.status).toBe(200);
    expect(await env.DB.prepare(
      'SELECT plan_id,status,day_template_id FROM sessions WHERE id=?1',
    ).bind(oldActive.id).first()).toEqual({
      plan_id: archivedPlan.id, status: 'in_progress', day_template_id: null,
    });
    expect(await env.DB.prepare(
      'SELECT plan_id,status,day_template_id FROM sessions WHERE id=?1',
    ).bind(oldPlanned.id).first()).toEqual({
      plan_id: archivedPlan.id, status: 'planned', day_template_id: null,
    });
  });
});

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
