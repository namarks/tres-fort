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

  it('refresh_rides: audited, returns {synced,status}, NO version bump, NO note', async () => {
    // Establish a plan so there is a version to watch.
    const built = await call('update_plan', {
      name: 'Ride Refresh',
      days: [
        { day_label: 'A', name: 'Day A', exercises: [{ exercise: 'bench', target_sets: 3, target_reps: 5 }] },
      ],
    });
    const vBefore = built.plan.version as number;

    const auditBefore = (
      await env.DB.prepare("SELECT COUNT(*) AS c FROM audit_log WHERE tool='refresh_rides'").first<{
        c: number;
      }>()
    )!.c;
    const notesBefore = (
      await env.DB.prepare("SELECT COUNT(*) AS c FROM notes WHERE author='claude'").first<{
        c: number;
      }>()
    )!.c;

    // In the offline test runtime the real intervals.icu fetch cannot
    // connect, so the sync returns the failed-fetch guard status WITHOUT
    // touching the cache. The tool still returns {synced,status}.
    const r = await call('refresh_rides', {});
    expect(r).toHaveProperty('status');
    expect(r).toHaveProperty('synced');
    expect(['ok', 'fetch_failed', 'disabled']).toContain(r.status);

    // Audited (action), but NO plan-version bump and NO claude notes row.
    const auditAfter = (
      await env.DB.prepare("SELECT COUNT(*) AS c FROM audit_log WHERE tool='refresh_rides'").first<{
        c: number;
      }>()
    )!.c;
    expect(auditAfter).toBe(auditBefore + 1);
    const notesAfter = (
      await env.DB.prepare("SELECT COUNT(*) AS c FROM notes WHERE author='claude'").first<{
        c: number;
      }>()
    )!.c;
    expect(notesAfter).toBe(notesBefore);
    expect((await call('get_current_plan', {})).version).toBe(vBefore);
  });

  it('reports unknown exercises instead of failing silently', async () => {
    const r = await call('update_plan', {
      name: 'bad',
      days: [{ name: 'X', exercises: [{ exercise: 'moon press', target_sets: 3, target_reps: 5 }] }],
    });
    expect(JSON.stringify(r)).toContain('unknown_exercise');
  });

  it('set_schedule: resolve names, +1 version, 409 stale, cross-plan reject, audit+note; one-offs no bump', async () => {
    // Fresh plan with two named days.
    const built = await call('update_plan', {
      name: 'Sched Test',
      days: [
        { day_label: 'A', name: 'Push Day', exercises: [{ exercise: 'bench', target_sets: 3, target_reps: 5 }] },
        { day_label: 'B', name: 'Pull Day', exercises: [{ exercise: 'barbell row', target_sets: 3, target_reps: 8 }] },
      ],
    });
    const planId = built.plan.id as string;
    const v0 = built.plan.version as number;

    // happy path: resolve by day name + label, exactly +1 version
    const set1 = await call('set_schedule', {
      week: { mon: 'Push Day', wed: 'B', fri: 'Push Day' },
    });
    expect(set1.ok).toBe(true);
    expect(set1.version).toBe(v0 + 1);
    // resolved to ids belonging to the active plan
    const dayIds = await env.DB.prepare(
      'SELECT id, name FROM day_templates WHERE plan_id = ?1',
    )
      .bind(planId)
      .all<{ id: string; name: string }>();
    const idByName = Object.fromEntries(dayIds.results.map((d) => [d.name, d.id]));
    expect(set1.schedule.week.mon).toBe(idByName['Push Day']);
    expect(set1.schedule.week.wed).toBe(idByName['Pull Day']);
    expect(set1.schedule.week.tue).toBeNull();

    // get_current_plan exposes the resolved weekday → name schedule
    const cp = await call('get_current_plan', {});
    expect(cp.schedule.mon).toBe('Push Day');
    expect(cp.schedule.wed).toBe('Pull Day');
    expect(cp.schedule.tue).toBeNull();

    // 409-style stale expected_version → conflict, no write
    const v1 = set1.version as number;
    const stale = await call('set_schedule', { week: { mon: 'Push Day' }, expected_version: v0 });
    expect(stale).toMatchObject({ conflict: true, current_version: v1 });
    expect((await call('get_current_plan', {})).version).toBe(v1);

    // cross-plan / foreign id rejected, no partial write
    const foreign = await call('set_schedule', {
      week: { mon: 'this-is-not-a-real-day-id' },
    });
    expect(foreign).toMatchObject({ error: 'unknown_day_ref' });
    expect((await call('get_current_plan', {})).version).toBe(v1);

    // correct expected_version succeeds, +1 again
    const set2 = await call('set_schedule', { week: { tue: 'A' }, expected_version: v1 });
    expect(set2.ok).toBe(true);
    expect(set2.version).toBe(v1 + 1);

    // audit rows + Claude notes recorded for schedule writes
    const audit = await env.DB.prepare(
      "SELECT COUNT(*) AS c FROM audit_log WHERE tool='set_schedule'",
    ).first<{ c: number }>();
    expect(audit!.c).toBeGreaterThanOrEqual(4); // 2 ok + stale + foreign
    const note = await env.DB.prepare(
      "SELECT COUNT(*) AS c FROM notes WHERE author='claude' AND body LIKE 'Set recurring weekly schedule%'",
    ).first<{ c: number }>();
    expect(note!.c).toBeGreaterThanOrEqual(2);

    // one-off tools: write a session, do NOT bump version
    const vBefore = (await call('get_current_plan', {})).version as number;
    const planned = await call('set_planned_session', { date: '2026-06-06', day: 'Pull Day' });
    expect(planned.ok).toBe(true);
    const skipped = await call('skip_planned_session', { date: '2026-06-07' });
    expect(skipped.ok).toBe(true);
    expect((await call('get_current_plan', {})).version).toBe(vBefore);

    // one-offs are still audited + noted
    const oneOffAudit = await env.DB.prepare(
      "SELECT COUNT(*) AS c FROM audit_log WHERE tool IN ('set_planned_session','skip_planned_session')",
    ).first<{ c: number }>();
    expect(oneOffAudit!.c).toBeGreaterThanOrEqual(2);

    // schedule.version is a change counter: it increments per successful
    // set_schedule (set1 was the 1st write, set2 the 2nd on this plan).
    expect(set1.schedule.version).toBe(2); // migration baseline 1 → +1
    expect(set2.schedule.version).toBe(3); // → +1 again
  });

  it('schedule survives update_plan for days kept by name; cleared for removed days', async () => {
    // Build a plan with two named days and schedule both.
    const built = await call('update_plan', {
      name: 'Survive Test',
      days: [
        { day_label: 'A', name: 'Push Day', exercises: [{ exercise: 'bench', target_sets: 3, target_reps: 5 }] },
        { day_label: 'B', name: 'Pull Day', exercises: [{ exercise: 'barbell row', target_sets: 3, target_reps: 8 }] },
      ],
    });
    const planId = built.plan.id as string;

    const setSched = await call('set_schedule', { week: { mon: 'Push Day', thu: 'Pull Day' } });
    expect(setSched.ok).toBe(true);
    const oldPushId = setSched.schedule.week.mon as string;
    const oldPullId = setSched.schedule.week.thu as string;

    // Rebuild keeping "Push Day" (same name, new label) + adding a deadlift
    // day; "Pull Day" is dropped. This is the "add a deadlift day" path.
    const rebuilt = await call('update_plan', {
      expected_version: setSched.version,
      name: 'Survive Test',
      days: [
        { day_label: 'PUSH', name: 'Push Day', exercises: [{ exercise: 'bench', target_sets: 3, target_reps: 5 }] },
        { day_label: 'D', name: 'Deadlift Day', exercises: [{ exercise: 'deadlift', target_sets: 3, target_reps: 5 }] },
      ],
    });
    expect(rebuilt.conflict).toBe(false);

    // New ids differ from old ones (full rebuild).
    const newDays = await env.DB.prepare(
      'SELECT id, name FROM day_templates WHERE plan_id = ?1',
    )
      .bind(planId)
      .all<{ id: string; name: string }>();
    const newIdByName = Object.fromEntries(newDays.results.map((d) => [d.name, d.id]));
    expect(newIdByName['Push Day']).not.toBe(oldPushId);

    // Schedule: Mon (Push Day) remapped to the NEW Push Day id by name;
    // Thu (Pull Day, removed) cleared to null.
    const cp = await call('get_current_plan', {});
    expect(cp.schedule.mon).toBe('Push Day'); // resolved name still present
    expect(cp.schedule.thu).toBeNull();
    void oldPullId;

    // Raw schedule holds the NEW push id, not the stale one.
    const planRow = await env.DB.prepare('SELECT meta FROM plans WHERE id = ?1')
      .bind(planId)
      .first<{ meta: string }>();
    const week = JSON.parse(planRow!.meta).schedule.week;
    expect(week.mon).toBe(newIdByName['Push Day']);
    expect(week.thu).toBeNull();
  });

  // FIX 1 — update_plan must not silently wipe the weekly schedule when an
  // unrelated metadata-only edit is made. Without the fix, an incoming
  // `meta` lacking a `schedule` key parsed to an EMPTY schedule and the
  // plan write turned every weekday to rest while all day templates still
  // existed. The fix merges incoming meta over the existing persisted meta
  // and preserves the existing schedule unless meta explicitly carries one.
  describe('FIX 1: update_plan meta merge preserves the weekly schedule', () => {
    it('(a) meta without schedule preserves+remaps the existing schedule; (d) the other meta key persists', async () => {
      const built = await call('update_plan', {
        name: 'Meta Merge A',
        days: [
          { day_label: 'A', name: 'Push Day', exercises: [{ exercise: 'bench', target_sets: 3, target_reps: 5 }] },
          { day_label: 'B', name: 'Pull Day', exercises: [{ exercise: 'barbell row', target_sets: 3, target_reps: 8 }] },
        ],
      });
      const planId = built.plan.id as string;
      const setSched = await call('set_schedule', { week: { mon: 'Push Day', thu: 'Pull Day' } });
      expect(setSched.ok).toBe(true);

      // Metadata-only-ish edit: pass `meta` with an unrelated key and NO
      // schedule, rebuilding the SAME two days (kept by name).
      const updated = await call('update_plan', {
        expected_version: setSched.version,
        name: 'Meta Merge A',
        meta: { deload_scheme: 'week4-50%' },
        days: [
          { day_label: 'A', name: 'Push Day', exercises: [{ exercise: 'bench', target_sets: 3, target_reps: 5 }] },
          { day_label: 'B', name: 'Pull Day', exercises: [{ exercise: 'barbell row', target_sets: 3, target_reps: 8 }] },
        ],
      });
      expect(updated.conflict).toBe(false);

      // Schedule survived AND was remapped onto the rebuilt day UUIDs by name.
      const cp = await call('get_current_plan', {});
      expect(cp.schedule.mon).toBe('Push Day');
      expect(cp.schedule.thu).toBe('Pull Day');

      const newDays = await env.DB.prepare(
        'SELECT id, name FROM day_templates WHERE plan_id = ?1',
      )
        .bind(planId)
        .all<{ id: string; name: string }>();
      const newIdByName = Object.fromEntries(newDays.results.map((d) => [d.name, d.id]));
      const meta = JSON.parse(
        (await env.DB.prepare('SELECT meta FROM plans WHERE id = ?1').bind(planId).first<{ meta: string }>())!.meta,
      );
      // (a) raw schedule points at the NEW (rebuilt) day ids, not stale ones.
      expect(meta.schedule.week.mon).toBe(newIdByName['Push Day']);
      expect(meta.schedule.week.thu).toBe(newIdByName['Pull Day']);
      // (d) the unrelated meta key was actually persisted.
      expect(meta.deload_scheme).toBe('week4-50%');
    });

    it('(b) an explicit meta.schedule replaces the existing one (and still rides the day remap)', async () => {
      const built = await call('update_plan', {
        name: 'Meta Merge B',
        days: [
          { day_label: 'A', name: 'Push Day', exercises: [{ exercise: 'bench', target_sets: 3, target_reps: 5 }] },
          { day_label: 'B', name: 'Pull Day', exercises: [{ exercise: 'barbell row', target_sets: 3, target_reps: 8 }] },
        ],
      });
      const planId = built.plan.id as string;
      const setSched = await call('set_schedule', { week: { mon: 'Push Day' } });
      expect(setSched.ok).toBe(true);
      const oldPushId = setSched.schedule.week.mon as string;

      // Explicit incoming schedule pointing Fri at the (old) Push day id.
      // It must REPLACE the mon entry and still be remapped to the rebuilt
      // Push Day id by name across the UUID rebuild.
      const updated = await call('update_plan', {
        expected_version: setSched.version,
        name: 'Meta Merge B',
        meta: {
          schedule: {
            version: 9,
            week: { mon: null, tue: null, wed: null, thu: null, fri: oldPushId, sat: null, sun: null },
          },
        },
        days: [
          { day_label: 'A', name: 'Push Day', exercises: [{ exercise: 'bench', target_sets: 3, target_reps: 5 }] },
          { day_label: 'B', name: 'Pull Day', exercises: [{ exercise: 'barbell row', target_sets: 3, target_reps: 8 }] },
        ],
      });
      expect(updated.conflict).toBe(false);

      const newDays = await env.DB.prepare(
        'SELECT id, name FROM day_templates WHERE plan_id = ?1',
      )
        .bind(planId)
        .all<{ id: string; name: string }>();
      const newIdByName = Object.fromEntries(newDays.results.map((d) => [d.name, d.id]));
      const meta = JSON.parse(
        (await env.DB.prepare('SELECT meta FROM plans WHERE id = ?1').bind(planId).first<{ meta: string }>())!.meta,
      );
      // The explicit schedule replaced: Mon now null, Fri = remapped Push id.
      expect(meta.schedule.week.mon).toBeNull();
      expect(meta.schedule.week.fri).toBe(newIdByName['Push Day']);
      expect(meta.schedule.version).toBe(9);
    });

    it('(c) no meta at all leaves behavior unchanged (schedule survives by name)', async () => {
      const built = await call('update_plan', {
        name: 'Meta Merge C',
        days: [
          { day_label: 'A', name: 'Push Day', exercises: [{ exercise: 'bench', target_sets: 3, target_reps: 5 }] },
        ],
      });
      const planId = built.plan.id as string;
      const setSched = await call('set_schedule', { week: { mon: 'Push Day' } });
      expect(setSched.ok).toBe(true);

      const updated = await call('update_plan', {
        expected_version: setSched.version,
        name: 'Meta Merge C',
        days: [
          { day_label: 'A', name: 'Push Day', exercises: [{ exercise: 'bench', target_sets: 3, target_reps: 5 }] },
        ],
      });
      expect(updated.conflict).toBe(false);

      const newDays = await env.DB.prepare(
        'SELECT id, name FROM day_templates WHERE plan_id = ?1',
      )
        .bind(planId)
        .all<{ id: string; name: string }>();
      const newIdByName = Object.fromEntries(newDays.results.map((d) => [d.name, d.id]));
      const meta = JSON.parse(
        (await env.DB.prepare('SELECT meta FROM plans WHERE id = ?1').bind(planId).first<{ meta: string }>())!.meta,
      );
      expect(meta.schedule.week.mon).toBe(newIdByName['Push Day']);
    });
  });
});

// FIX2 (MCP path) — the skip_planned_session TOOL's session_already_started
// rejection (added in f7638ce) had no rejection-path coverage; mcp_write
// only ever skipped a planned date. These exercise the guard end-to-end
// through the MCP tool, including no-mutation + sets-intact, and confirm
// the planned/empty path still works.
describe('mcp skip_planned_session — rejects burying started/finished history', () => {
  // The MCP tool resolves the single owner via ensureOwnerUser; update_plan
  // bootstraps it. Resolve that owner + its active plan, then seed a
  // session directly with the status under test.
  async function ownerAndPlan(): Promise<{ userId: string; planId: string }> {
    await call('update_plan', {
      name: 'MCP Skip Guard',
      days: [{ day_label: 'A', name: 'Day A', exercises: [{ exercise: 'bench', target_sets: 3, target_reps: 5 }] }],
    });
    const userId = (
      await env.DB.prepare('SELECT id FROM users ORDER BY created_at LIMIT 1').first<{ id: string }>()
    )!.id;
    const planId = (
      await env.DB.prepare("SELECT id FROM plans WHERE user_id=?1 AND status='active'")
        .bind(userId)
        .first<{ id: string }>()
    )!.id;
    return { userId, planId };
  }
  async function seedSession(
    userId: string,
    planId: string,
    date: string,
    status: string,
  ): Promise<string> {
    const sid = crypto.randomUUID();
    await env.DB.prepare(
      'INSERT INTO sessions (id,user_id,plan_id,day_template_id,date,status,started_at,completed_at,perceived_fatigue,notes,created_at,updated_at) VALUES (?1,?2,?3,NULL,?4,?5,?6,?7,NULL,NULL,?8,?8)',
    )
      .bind(sid, userId, planId, date, status, status === 'planned' ? null : 1, status === 'completed' ? 2 : null, Date.now())
      .run();
    return sid;
  }

  it('REJECTS via the tool when the date has a completed session; row + sets intact', async () => {
    const { userId, planId } = await ownerAndPlan();
    const sid = await seedSession(userId, planId, '2026-08-01', 'completed');
    const setId = crypto.randomUUID();
    await env.DB.prepare(
      "INSERT INTO set_logs (id,session_id,exercise_id,template_exercise_id,set_index,weight,reps,rpe,is_warmup,notes,logged_at,source,deleted_at) VALUES (?1,?2,'ex_bench',NULL,1,225,5,8,0,NULL,?3,'mcp',NULL)",
    )
      .bind(setId, sid, Date.now())
      .run();

    const r = await call('skip_planned_session', { date: '2026-08-01' });
    expect(r).toEqual({ error: 'session_already_started', status: 'completed' });

    const row = await env.DB.prepare('SELECT status FROM sessions WHERE id=?1')
      .bind(sid)
      .first<{ status: string }>();
    expect(row!.status).toBe('completed'); // not buried
    const set = await env.DB.prepare('SELECT deleted_at FROM set_logs WHERE id=?1')
      .bind(setId)
      .first<{ deleted_at: number | null }>();
    expect(set!.deleted_at).toBeNull();
  });

  it('REJECTS via the tool when the date has an in_progress session; row untouched', async () => {
    const { userId, planId } = await ownerAndPlan();
    const sid = await seedSession(userId, planId, '2026-08-02', 'in_progress');
    const r = await call('skip_planned_session', { date: '2026-08-02' });
    expect(r).toEqual({ error: 'session_already_started', status: 'in_progress' });
    const row = await env.DB.prepare('SELECT status FROM sessions WHERE id=?1')
      .bind(sid)
      .first<{ status: string }>();
    expect(row!.status).toBe('in_progress');
  });

  it('still skips a planned/empty date via the tool (unchanged behavior)', async () => {
    const { userId, planId } = await ownerAndPlan();
    await seedSession(userId, planId, '2026-08-03', 'planned');
    const r = await call('skip_planned_session', { date: '2026-08-03' });
    expect(r.ok).toBe(true);
    const row = await env.DB.prepare('SELECT status FROM sessions WHERE user_id=?1 AND date=?2')
      .bind(userId, '2026-08-03')
      .first<{ status: string }>();
    expect(row!.status).toBe('skipped');

    // empty date (no prior session) → create-as-skipped
    const r2 = await call('skip_planned_session', { date: '2026-08-04' });
    expect(r2.ok).toBe(true);
    const row2 = await env.DB.prepare('SELECT status FROM sessions WHERE user_id=?1 AND date=?2')
      .bind(userId, '2026-08-04')
      .first<{ status: string }>();
    expect(row2!.status).toBe('skipped');
  });
});

describe('mcp update_plan — FK-safe rebuild remaps session + set_log references', () => {
  // Repro: a real `sessions` row references a day_template_id that
  // update_plan would DELETE during the rebuild. Pre-fix: D1_ERROR
  // FOREIGN KEY constraint failed. Post-fix: sessions remap to the new
  // day id (matched by label/name); a removed day → NULL.
  it('remaps a session.day_template_id when the day survives by label', async () => {
    await call('update_plan', {
      name: 'Remap test',
      days: [{ name: 'Full Body A', day_label: 'A', exercises: [
        { exercise: 'Bench Press', target_sets: 3, target_reps: 5 },
      ] }],
    });
    // Plant a real session pointing at day A
    await call('set_planned_session', { date: '2026-09-01', day: 'A' });
    const before = await env.DB.prepare("SELECT day_template_id FROM sessions WHERE date='2026-09-01'")
      .first<{ day_template_id: string | null }>();
    const oldDayId = before!.day_template_id!;
    expect(oldDayId).not.toBeNull();

    // Rebuild — same day label "A", new UUID. Pre-fix: FK error.
    const rebuilt = await call('update_plan', {
      name: 'Remap test',
      days: [{ name: 'Full Body A renamed', day_label: 'A', exercises: [
        { exercise: 'Bench Press', target_sets: 4, target_reps: 5 },
      ] }],
    });
    expect(rebuilt.conflict).toBe(false);
    const newDayId = rebuilt.plan.days[0].id;
    expect(newDayId).not.toBe(oldDayId);

    const after = await env.DB.prepare("SELECT day_template_id FROM sessions WHERE date='2026-09-01'")
      .first<{ day_template_id: string | null }>();
    expect(after!.day_template_id).toBe(newDayId);
  });

  it('NULLs a session.day_template_id when the day is removed in the rebuild', async () => {
    await call('update_plan', {
      name: 'Drop test',
      days: [
        { name: 'A day', day_label: 'A', exercises: [{ exercise: 'Bench Press', target_sets: 3, target_reps: 5 }] },
        { name: 'B day', day_label: 'B', exercises: [{ exercise: 'Conventional Deadlift', target_sets: 3, target_reps: 5 }] },
      ],
    });
    await call('set_planned_session', { date: '2026-09-02', day: 'B' });

    // Rebuild WITHOUT day B
    const rebuilt = await call('update_plan', {
      name: 'Drop test',
      days: [{ name: 'A day', day_label: 'A', exercises: [{ exercise: 'Bench Press', target_sets: 3, target_reps: 5 }] }],
    });
    expect(rebuilt.conflict).toBe(false);

    const sess = await env.DB.prepare("SELECT day_template_id FROM sessions WHERE date='2026-09-02'")
      .first<{ day_template_id: string | null }>();
    expect(sess!.day_template_id).toBeNull();
  });

  it('remaps set_logs.template_exercise_id to the new te id when the exercise survives', async () => {
    await call('update_plan', {
      name: 'TE remap',
      days: [{ name: 'A', day_label: 'A', exercises: [{ exercise: 'Bench Press', target_sets: 3, target_reps: 5 }] }],
    });
    await call('set_planned_session', { date: '2026-09-03', day: 'A' });
    // Read the current te id
    const teBefore = await env.DB.prepare(
      "SELECT te.id FROM template_exercises te JOIN day_templates d ON d.id=te.day_template_id WHERE d.day_label='A'",
    ).first<{ id: string }>();
    const oldTeId = teBefore!.id;
    // Plant a set_log with that template_exercise_id
    const sess = await env.DB.prepare("SELECT id FROM sessions WHERE date='2026-09-03'").first<{ id: string }>();
    const setId = crypto.randomUUID();
    await env.DB.prepare(
      `INSERT INTO set_logs (id,session_id,exercise_id,template_exercise_id,set_index,weight,reps,rpe,is_warmup,notes,logged_at,source,duration_s)
       VALUES (?1,?2,'ex_bench',?3,1,135,5,NULL,0,NULL,?4,'test',NULL)`,
    ).bind(setId, sess!.id, oldTeId, Date.now()).run();

    // Rebuild keeps day A + Bench Press → te should remap
    const rebuilt = await call('update_plan', {
      name: 'TE remap',
      days: [{ name: 'A', day_label: 'A', exercises: [{ exercise: 'Bench Press', target_sets: 4, target_reps: 8 }] }],
    });
    expect(rebuilt.conflict).toBe(false);
    const newTeId = rebuilt.plan.days[0].exercises[0].id;

    const set = await env.DB.prepare('SELECT template_exercise_id FROM set_logs WHERE id=?1')
      .bind(setId)
      .first<{ template_exercise_id: string | null }>();
    expect(set!.template_exercise_id).toBe(newTeId);
  });

  it('rejects an exercise item with missing/empty `exercise` (structured, no .trim() crash)', async () => {
    const r = await call('update_plan', {
      name: 'trim test',
      days: [{ name: 'A', day_label: 'A', exercises: [{ target_sets: 3, target_reps: 5 } as never] }],
    });
    // Structured error: same shape every other exercise-resolution
    // failure uses — agents can pattern-match r.error === 'unknown_exercise'.
    expect(r.error).toBe('unknown_exercise');
    expect(r.query).toBe('<missing>');
  });

  it('rejects an unrecognized exercise name with a structured unknown_exercise error', async () => {
    const r = await call('update_plan', {
      name: 'unknown name test',
      days: [{ name: 'A', day_label: 'A', exercises: [{ exercise: 'Kettlebell Underhand Push', target_sets: 3, target_reps: 5 }] }],
    });
    expect(r.error).toBe('unknown_exercise');
    expect(r.query).toBe('Kettlebell Underhand Push');
  });
});

describe('mcp order_index — settable on add and update; rejects unknown patch keys', () => {
  it('add_exercise appends densely (max+1), not the old 99 sentinel', async () => {
    await call('update_plan', {
      name: 'Order test',
      days: [{ name: 'A', day_label: 'A', exercises: [
        { exercise: 'Bench Press', order_index: 0, target_sets: 3, target_reps: 5 },
        { exercise: 'Barbell Row',  order_index: 1, target_sets: 3, target_reps: 8 },
      ] }],
    });

    // No explicit order_index → should land at 2 (max 1 + 1), not 99.
    const r = await call('add_exercise', {
      day: 'A', exercise: 'Overhead Press', target_sets: 3, target_reps: 5,
    });
    expect(r.order_index).toBe(2);

    // Explicit value → honored.
    const r2 = await call('add_exercise', {
      day: 'A', exercise: 'Pull-Up', target_sets: 3, target_reps: 5, order_index: 5,
    });
    expect(r2.order_index).toBe(5);
  });

  it('update_exercise applies order_index', async () => {
    await call('update_plan', {
      name: 'Order patch',
      days: [{ name: 'A', day_label: 'A', exercises: [
        { exercise: 'Bench Press', order_index: 0, target_sets: 3, target_reps: 5 },
      ] }],
    });
    const r = await call('update_exercise', {
      day: 'A', exercise: 'bench', patch: { order_index: 7 },
    });
    expect(r.order_index).toBe(7);
  });

  it('add_day appends densely (max+1), not the old 99 sentinel', async () => {
    await call('update_plan', {
      name: 'Day order',
      days: [
        { name: 'A', day_label: 'A', order_index: 0, exercises: [
          { exercise: 'Bench Press', order_index: 0, target_sets: 3, target_reps: 5 },
        ] },
      ],
    });
    const r = await call('add_day', { name: 'Day 2', day_label: 'B' });
    expect(r.order_index).toBe(1);
  });

  it('update_exercise rejects unknown patch keys instead of silent 200', async () => {
    await call('update_plan', {
      name: 'Unknown key',
      days: [{ name: 'A', day_label: 'A', exercises: [
        { exercise: 'Bench Press', order_index: 0, target_sets: 3, target_reps: 5 },
      ] }],
    });
    // camelCase is the actual diagnosability bug from the report
    const r = await call('update_exercise', {
      day: 'A', exercise: 'bench', patch: { orderIndex: 0 },
    });
    expect(r.error).toBe('unknown_fields');
    expect(r.fields).toContain('orderIndex');
  });
});
