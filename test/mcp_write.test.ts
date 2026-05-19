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
