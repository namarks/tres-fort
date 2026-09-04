import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { logSet } from '../src/db';

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
  describe('builds, mutates, and audits the plan via chat-style calls', () => {
    // One seed for the block. vitest-pool-workers' default isolatedStorage
    // keeps beforeAll writes visible to every `it` below and undoes each
    // `it`'s own writes after it runs, so every case starts from this same
    // plan at the same version. The cases are independent by design: a
    // single sequential case covering all of them made 17 Worker round-trips
    // and sat near vitest's 5 s default per-test timeout on a CI runner.
    let built: any;
    let v: number;

    beforeAll(async () => {
      // build a plan from scratch
      built = await call('update_plan', {
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
      v = built.plan.version;
      expect(v).toBeGreaterThan(1);
    });

    it('update_plan: a stale expected_version conflicts; the current one rebuilds, audited + noted', async () => {
      // optimistic concurrency: a stale expected_version conflicts
      const stale = await call('update_plan', { name: 'x', expected_version: 1, days: [] });
      expect(stale).toMatchObject({ conflict: true, current_version: v });

      // correct expected_version succeeds
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

      // every call is audited, the conflict included; only successful
      // rebuilds write a Claude note
      const audits = await env.DB.prepare(
        "SELECT COUNT(*) AS c FROM audit_log WHERE actor='mcp' AND tool='update_plan'",
      ).first<{ c: number }>();
      expect(audits!.c).toBe(3); // seed build + stale + fresh
      const notes = await env.DB.prepare(
        "SELECT COUNT(*) AS c FROM notes WHERE author='claude' AND body LIKE 'Rebuilt plan:%'",
      ).first<{ c: number }>();
      expect(notes!.c).toBe(2); // seed build + fresh
    });

    it('swap_exercise / add_day / add_exercise / update_exercise edit the tree in place, each audited + noted', async () => {
      // swap RDL -> front squat on day B
      const swap = await call('swap_exercise', {
        day: 'B',
        from_exercise: 'rdl',
        to_exercise: 'front squat',
      });
      expect(swap.exercise_id).toBe('ex_front_squat');

      // add a deadlift day, then an exercise to it
      const day = await call('add_day', { name: 'Deadlift Day', day_label: 'D' });
      expect(day.day_label).toBe('D');
      const added = await call('add_exercise', {
        day: 'D',
        exercise: 'deadlift',
        target_sets: 3,
        target_reps: 5,
      });
      expect(added.exercise_id).toBe('ex_deadlift');

      // patch that slot
      const patched = await call('update_exercise', {
        day: 'D',
        exercise: 'deadlift',
        patch: { target_sets: 5, target_weight: 315 },
      });
      expect(patched.target_sets).toBe(5);
      expect(patched.target_weight).toBe(315);

      // audit trail + Claude notes were written, one of each per mutation
      const audits = await env.DB.prepare(
        "SELECT COUNT(*) AS c FROM audit_log WHERE actor='mcp' AND tool IN ('swap_exercise','add_day','add_exercise','update_exercise')",
      ).first<{ c: number }>();
      expect(audits!.c).toBe(4);
      const notes = await env.DB.prepare(
        "SELECT COUNT(*) AS c FROM notes WHERE author='claude'",
      ).first<{ c: number }>();
      expect(notes!.c).toBe(5); // seed rebuild + one per mutation above
    });

    it("log_set auto-creates today's session on the legacy write protocol; log_workout_complete closes it", async () => {
      const logged = await call('log_set', { exercise: 'bench', weight: 225, reps: 8, rpe: 8 });
      expect(logged.deduped).toBe(false);
      expect(logged.set.source).toBe('mcp');
      const done = await call('log_workout_complete', { perceived_fatigue: 7 });
      expect(done.status).toBe('completed');
      expect(done.perceived_fatigue).toBe(7);
      expect(
        await env.DB
          .prepare('SELECT write_protocol FROM sessions WHERE id = ?1')
          .bind(logged.set.session_id)
          .first(),
      ).toEqual({ write_protocol: 'legacy' });

      // both log writes are audited
      const audits = await env.DB.prepare(
        "SELECT COUNT(*) AS c FROM audit_log WHERE actor='mcp' AND tool IN ('log_set','log_workout_complete')",
      ).first<{ c: number }>();
      expect(audits!.c).toBe(2);
    });

    it("adjust_today scales day A's sets, bumps the version, and stores the reason as a note; add_note records a coaching note", async () => {
      // "I'm beat — adjust" scales day A's sets and bumps version
      const adj = await call('adjust_today', {
        intent: 'reduce_volume',
        magnitude: 'moderate',
        day_label: 'A',
        reason: 'slept 4h, HRV tanked',
      });
      expect(adj.changes.length).toBeGreaterThan(0);
      expect((await call('get_current_plan', {})).version).toBeGreaterThan(v);

      // explicit coaching note
      expect(await call('add_note', { scope: 'general', body: 'deload next week' })).toMatchObject({
        ok: true,
      });

      // audit trail + Claude notes were written
      const audits = await env.DB.prepare(
        "SELECT COUNT(*) AS c FROM audit_log WHERE actor='mcp' AND tool IN ('adjust_today','add_note')",
      ).first<{ c: number }>();
      expect(audits!.c).toBe(2);
      const notes = await env.DB.prepare(
        "SELECT COUNT(*) AS c FROM notes WHERE author='claude'",
      ).first<{ c: number }>();
      expect(notes!.c).toBe(3); // seed rebuild + adjust_today reason + add_note
      const reason = await env.DB.prepare(
        "SELECT body FROM notes WHERE body LIKE '%HRV tanked%' LIMIT 1",
      ).first<{ body: string }>();
      expect(reason?.body).toContain('reduce_volume');
    });
  });

  it('keeps MCP generation CAS compatible with a released tokenless iOS writer', async () => {
    await call('update_plan', {
      name: 'Protocol compatibility',
      days: [
        {
          day_label: 'P',
          name: 'Protocol Day',
          exercises: [{ exercise: 'bench', target_sets: 3, target_reps: 5 }],
        },
      ],
    });
    const date = '2038-01-01';
    const mcpSet = await call('log_set', {
      exercise: 'bench',
      weight: 176.25,
      reps: 7,
      session_date: date,
    });
    expect(mcpSet.error).toBeUndefined();
    const sessionId = mcpSet.set.session_id as string;
    const exerciseId = mcpSet.set.exercise_id as string;
    const session = await env.DB
      .prepare(
        'SELECT user_id,plan_id,attempt,write_protocol FROM sessions WHERE id=?1',
      )
      .bind(sessionId)
      .first<{
        user_id: string;
        plan_id: string;
        attempt: number;
        write_protocol: string;
      }>();
    expect(session).toMatchObject({ attempt: 0, write_protocol: 'legacy' });

    // This is the released app's tokenless backend path: no expected attempt
    // and no protocol claim. The normal MCP CAS above must leave it usable.
    expect(
      await logSet(env.DB, session!.user_id, {
        id: crypto.randomUUID(),
        session_id: sessionId,
        exercise_id: exerciseId,
        set_index: 2,
        weight: 177.5,
        reps: 7,
        source: 'ios',
      }),
    ).toMatchObject({ deduped: false, session: { write_protocol: 'legacy' } });
  });

  it('refresh_rides: audited, returns {rides,activities}, NO version bump, NO note', async () => {
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
    // connect, so both syncs return the failed-fetch guard status WITHOUT
    // touching the caches. The tool returns {rides,activities}, each a
    // {synced,status} pair (planned events + completed activities).
    const r = await call('refresh_rides', {});
    expect(r.rides).toHaveProperty('status');
    expect(r.rides).toHaveProperty('synced');
    expect(r.activities).toHaveProperty('status');
    expect(r.activities).toHaveProperty('synced');
    expect(['ok', 'fetch_failed', 'disabled']).toContain(r.rides.status);
    expect(['ok', 'fetch_failed', 'disabled']).toContain(r.activities.status);

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

  describe('set_schedule: resolve names, +1 version, 409 stale, cross-plan reject, audit+note; one-offs no bump', () => {
    // One seed for the block (see the note on the first describe above):
    // isolatedStorage keeps it visible to every `it` and rolls each `it`'s
    // own writes back, so every case starts at version v0 with no schedule.
    // The single sequential case this replaces made 17 Worker round-trips.
    let planId: string;
    let v0: number;

    beforeAll(async () => {
      // Fresh plan with two named days.
      const built = await call('update_plan', {
        name: 'Sched Test',
        days: [
          { day_label: 'A', name: 'Push Day', exercises: [{ exercise: 'bench', target_sets: 3, target_reps: 5 }] },
          { day_label: 'B', name: 'Pull Day', exercises: [{ exercise: 'barbell row', target_sets: 3, target_reps: 8 }] },
        ],
      });
      expect(built.conflict).toBe(false);
      planId = built.plan.id as string;
      v0 = built.plan.version as number;
    });

    it("resolves day names + labels to the active plan's ids, exactly +1 version, audited + noted", async () => {
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

      // schedule.version is a change counter: migration baseline 1 → +1 on
      // the first successful set_schedule for this plan.
      expect(set1.schedule.version).toBe(2);

      // audit row + Claude note recorded for the schedule write
      const audit = await env.DB.prepare(
        "SELECT COUNT(*) AS c FROM audit_log WHERE tool='set_schedule'",
      ).first<{ c: number }>();
      expect(audit!.c).toBe(1);
      const note = await env.DB.prepare(
        "SELECT COUNT(*) AS c FROM notes WHERE author='claude' AND body LIKE 'Set recurring weekly schedule%'",
      ).first<{ c: number }>();
      expect(note!.c).toBe(1);
    });

    it('a stale expected_version conflicts with no write; the current one succeeds, +1 again', async () => {
      const set1 = await call('set_schedule', {
        week: { mon: 'Push Day', wed: 'B', fri: 'Push Day' },
      });
      expect(set1.ok).toBe(true);
      const v1 = set1.version as number;

      // 409-style stale expected_version → conflict, no write
      const stale = await call('set_schedule', { week: { mon: 'Push Day' }, expected_version: v0 });
      expect(stale).toMatchObject({ conflict: true, current_version: v1 });
      expect((await call('get_current_plan', {})).version).toBe(v1);

      // correct expected_version succeeds, +1 again
      const set2 = await call('set_schedule', { week: { tue: 'A' }, expected_version: v1 });
      expect(set2.ok).toBe(true);
      expect(set2.version).toBe(v1 + 1);

      // schedule.version is a change counter: it increments per successful
      // set_schedule (set1 was the 1st write, set2 the 2nd on this plan);
      // the conflict in between did not move it.
      expect(set1.schedule.version).toBe(2); // migration baseline 1 → +1
      expect(set2.schedule.version).toBe(3); // → +1 again

      // every call is audited, the conflict included; only the two
      // successful writes are noted
      const audit = await env.DB.prepare(
        "SELECT COUNT(*) AS c FROM audit_log WHERE tool='set_schedule'",
      ).first<{ c: number }>();
      expect(audit!.c).toBe(3); // set1 + stale + set2
      const note = await env.DB.prepare(
        "SELECT COUNT(*) AS c FROM notes WHERE author='claude' AND body LIKE 'Set recurring weekly schedule%'",
      ).first<{ c: number }>();
      expect(note!.c).toBe(2);
    });

    it('an unknown day ref (not in the active plan) is rejected with no partial write', async () => {
      const set1 = await call('set_schedule', {
        week: { mon: 'Push Day', wed: 'B', fri: 'Push Day' },
      });
      expect(set1.ok).toBe(true);
      const v1 = set1.version as number;

      // a ref that resolves to no day in the active plan is rejected, no
      // partial write
      const foreign = await call('set_schedule', {
        week: { mon: 'this-is-not-a-real-day-id' },
      });
      expect(foreign).toMatchObject({ error: 'unknown_day_ref' });
      const cp = await call('get_current_plan', {});
      expect(cp.version).toBe(v1);
      expect(cp.schedule.mon).toBe('Push Day'); // the existing schedule is intact

      // the rejection is audited but not noted
      const audit = await env.DB.prepare(
        "SELECT COUNT(*) AS c FROM audit_log WHERE tool='set_schedule'",
      ).first<{ c: number }>();
      expect(audit!.c).toBe(2); // set1 + foreign
      const note = await env.DB.prepare(
        "SELECT COUNT(*) AS c FROM notes WHERE author='claude' AND body LIKE 'Set recurring weekly schedule%'",
      ).first<{ c: number }>();
      expect(note!.c).toBe(1);
    });

    it('one-off tools write legacy sessions, do NOT bump the version, and are still audited + noted', async () => {
      // one-off tools: write a session, do NOT bump version
      const planned = await call('set_planned_session', { date: '2026-06-06', day: 'Pull Day' });
      expect(planned.ok).toBe(true);
      const skipped = await call('skip_planned_session', { date: '2026-06-07' });
      expect(skipped.ok).toBe(true);
      expect((await call('get_current_plan', {})).version).toBe(v0);
      expect(
        await env.DB
          .prepare(
            "SELECT date, write_protocol FROM sessions WHERE date IN ('2026-06-06', '2026-06-07') ORDER BY date",
          )
          .all(),
      ).toMatchObject({
        results: [
          { date: '2026-06-06', write_protocol: 'legacy' },
          { date: '2026-06-07', write_protocol: 'legacy' },
        ],
      });

      // one-offs are still audited + noted
      const oneOffAudit = await env.DB.prepare(
        "SELECT COUNT(*) AS c FROM audit_log WHERE tool IN ('set_planned_session','skip_planned_session')",
      ).first<{ c: number }>();
      expect(oneOffAudit!.c).toBe(2);
      const oneOffNotes = await env.DB.prepare(
        "SELECT COUNT(*) AS c FROM notes WHERE author='claude' AND (body LIKE 'Planned 2026-06-06%' OR body LIKE 'Skipped 2026-06-07%')",
      ).first<{ c: number }>();
      expect(oneOffNotes!.c).toBe(2);
    });
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
    expect(r.queries).toEqual(['<missing>']);
  });

  it('rejects an unrecognized exercise name with a structured unknown_exercise error', async () => {
    const r = await call('update_plan', {
      name: 'unknown name test',
      days: [{ name: 'A', day_label: 'A', exercises: [{ exercise: 'Kettlebell Underhand Push', target_sets: 3, target_reps: 5 }] }],
    });
    expect(r.error).toBe('unknown_exercise');
    expect(r.query).toBe('Kettlebell Underhand Push');
    expect(r.queries).toEqual(['Kettlebell Underhand Push']);
  });

  it('collects ALL unknowns in one response — no fail-fix-retry round trips', async () => {
    const r = await call('update_plan', {
      name: 'multi-unknown',
      days: [{
        name: 'A', day_label: 'A', exercises: [
          { exercise: 'Bench Press', target_sets: 3, target_reps: 5 }, // OK
          { exercise: 'Kettlebell Underhand Push', target_sets: 3, target_reps: 5 }, // unknown
          { exercise: 'Bird Cow Dog Squat', target_sets: 3, target_reps: 5 },        // unknown
          { exercise: 'Banded Floor Crunch', target_sets: 3, target_reps: 10 },      // unknown
        ],
      }],
    });
    expect(r.error).toBe('unknown_exercise');
    expect(r.queries).toEqual([
      'Kettlebell Underhand Push',
      'Bird Cow Dog Squat',
      'Banded Floor Crunch',
    ]);
    // `query` retained as the first unknown for back-compat.
    expect(r.query).toBe('Kettlebell Underhand Push');
  });
});

describe('mcp set_planned_session — clean revival of a discarded session', () => {
  it('returns a planned session with cleared started_at/completed_at when reviving a discarded row', async () => {
    await call('update_plan', {
      name: 'Revival',
      days: [{ name: 'A', day_label: 'A', exercises: [
        { exercise: 'Bench Press', order_index: 0, target_sets: 3, target_reps: 5 },
      ] }],
    });
    await call('set_planned_session', { date: '2026-11-01', day: 'A' });
    const seeded = (await env.DB.prepare(
      "SELECT id,attempt FROM sessions WHERE date='2026-11-01'",
    ).first<{ id: string; attempt: number }>())!;
    const sid = seeded.id;
    // Force the row to a discarded state with a past started_at.
    await env.DB
      .prepare("UPDATE sessions SET status='discarded', started_at=12345 WHERE id=?1")
      .bind(sid)
      .run();

    const r = await call('set_planned_session', {
      date: '2026-11-01', day: 'A', expected_attempt: seeded.attempt,
    });
    // Pre-fix: r.session.status was 'discarded' (stale — the SQL had
    // already flipped to 'planned' in the DB but the response spread
    // ...existing). Post-fix: returned shape matches the row, with
    // started_at/completed_at cleared on revival.
    expect(r.ok).toBe(true);
    expect(r.session.status).toBe('planned');
    expect(r.session.started_at).toBeNull();
    expect(r.session.completed_at).toBeNull();

    const row = await env.DB
      .prepare("SELECT status, started_at FROM sessions WHERE id=?1")
      .bind(sid)
      .first<{ status: string; started_at: number | null }>();
    expect(row!.status).toBe('planned');
    expect(row!.started_at).toBeNull();
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

describe('mcp update_day — patch a day in place (no full plan rebuild)', () => {
  it('updates notes/name/day_label/order_index via day label; densifies and bumps version', async () => {
    const built = await call('update_plan', {
      name: 'Day patch',
      days: [{ name: 'Old A', day_label: 'A', notes: 'old', exercises: [
        { exercise: 'Bench Press', order_index: 0, target_sets: 3, target_reps: 5 },
      ] }],
    });
    const v0 = built.plan.version;

    const r = await call('update_day', {
      day: 'A',
      patch: { name: 'New A', notes: 'warmup first', order_index: 7 },
    });
    expect(r.error).toBeUndefined();
    expect(r.name).toBe('New A');
    expect(r.notes).toBe('warmup first');
    expect(r.order_index).toBe(0);

    const after = await call('get_current_plan', {});
    expect(after.version).toBeGreaterThan(v0);
    expect(after.days[0].name).toBe('New A');
  });

  it('rejects unknown patch keys with structured error', async () => {
    await call('update_plan', {
      name: 'Unknown day key',
      days: [{ name: 'A', day_label: 'A', exercises: [
        { exercise: 'Bench Press', order_index: 0, target_sets: 3, target_reps: 5 },
      ] }],
    });
    const r = await call('update_day', {
      day: 'A',
      patch: { dayName: 'oops' }, // wrong key
    });
    expect(r.error).toBe('unknown_fields');
    expect(r.fields).toContain('dayName');
  });

  it('returns day_not_found for an unknown ref', async () => {
    await call('update_plan', {
      name: 'Missing day',
      days: [{ name: 'A', day_label: 'A', exercises: [
        { exercise: 'Bench Press', order_index: 0, target_sets: 3, target_reps: 5 },
      ] }],
    });
    const r = await call('update_day', { day: 'Z', patch: { notes: 'x' } });
    expect(r.error).toBe('day_not_found');
  });
});

describe('mcp delete_exercise — removes a slot; detaches historical sets', () => {
  it('deletes by (day, exercise) and NULLs set_logs.template_exercise_id', async () => {
    await call('update_plan', {
      name: 'Delete slot',
      days: [{ name: 'A', day_label: 'A', exercises: [
        { exercise: 'Bench Press',  order_index: 0, target_sets: 3, target_reps: 5 },
        { exercise: 'Barbell Row',  order_index: 1, target_sets: 3, target_reps: 8 },
      ] }],
    });
    // Plant a set_log that references the te id we're about to delete.
    const te = await env.DB
      .prepare(
        "SELECT te.id FROM template_exercises te JOIN day_templates d ON d.id=te.day_template_id WHERE d.day_label='A' AND te.exercise_id='ex_bench'",
      )
      .first<{ id: string }>();
    const teId = te!.id;
    await call('set_planned_session', { date: '2026-10-01', day: 'A' });
    const sess = await env.DB.prepare("SELECT id FROM sessions WHERE date='2026-10-01'").first<{ id: string }>();
    const setId = crypto.randomUUID();
    await env.DB.prepare(
      `INSERT INTO set_logs (id,session_id,exercise_id,template_exercise_id,set_index,weight,reps,rpe,is_warmup,notes,logged_at,source,duration_s)
       VALUES (?1,?2,'ex_bench',?3,1,135,5,NULL,0,NULL,?4,'test',NULL)`,
    ).bind(setId, sess!.id, teId, Date.now()).run();

    const r = await call('delete_exercise', { day: 'A', exercise: 'bench' });
    expect(r.error).toBeUndefined();
    expect(r.id).toBe(teId);

    // Slot gone; sibling row still there.
    const remaining = await env.DB
      .prepare(
        "SELECT exercise_id FROM template_exercises te JOIN day_templates d ON d.id=te.day_template_id WHERE d.day_label='A'",
      )
      .all<{ exercise_id: string }>();
    expect(remaining.results.map((r) => r.exercise_id)).toEqual(['ex_barbell_row']);

    // Historical set: detached (template_exercise_id NULLed) but still present (exercise_id preserved).
    const set = await env.DB.prepare('SELECT template_exercise_id, exercise_id FROM set_logs WHERE id=?1')
      .bind(setId)
      .first<{ template_exercise_id: string | null; exercise_id: string }>();
    expect(set!.template_exercise_id).toBeNull();
    expect(set!.exercise_id).toBe('ex_bench');
  });

  it('returns slot_not_found for an unknown ref', async () => {
    await call('update_plan', {
      name: 'No slot',
      days: [{ name: 'A', day_label: 'A', exercises: [
        { exercise: 'Bench Press', order_index: 0, target_sets: 3, target_reps: 5 },
      ] }],
    });
    const r = await call('delete_exercise', { day: 'A', exercise: 'pullup' });
    expect(r.error).toBe('slot_not_found');
  });
});

describe('mcp target_duration_s — timed slots specified natively (no rep-overload)', () => {
  it('add_exercise persists target_duration_s and it round-trips via get_current_plan', async () => {
    await call('update_plan', {
      name: 'Timed via add',
      days: [{ name: 'A', day_label: 'A', exercises: [
        { exercise: 'Bench Press', order_index: 0, target_sets: 3, target_reps: 5 },
      ] }],
    });
    const added = await call('add_exercise', {
      day: 'A',
      exercise: 'Side Plank',
      target_sets: 2,
      target_reps: 1,
      target_duration_s: 45,
    });
    expect(added.target_duration_s).toBe(45);

    const tree = await call('get_current_plan', {});
    const plank = tree.days[0].exercises.find(
      (e: { exercise_id: string }) => e.exercise_id === 'ex_side_plank',
    );
    expect(plank).toBeDefined();
    expect(plank.target_duration_s).toBe(45);
  });

  it('update_exercise patches target_duration_s; null clears it', async () => {
    await call('update_plan', {
      name: 'Timed via patch',
      days: [{ name: 'A', day_label: 'A', exercises: [
        { exercise: 'Plank', order_index: 0, target_sets: 1, target_reps: 1, target_duration_s: 30 },
      ] }],
    });
    const r = await call('update_exercise', {
      day: 'A', exercise: 'plank', patch: { target_duration_s: 60 },
    });
    expect(r.target_duration_s).toBe(60);

    const cleared = await call('update_exercise', {
      day: 'A', exercise: 'plank', patch: { target_duration_s: null },
    });
    expect(cleared.target_duration_s).toBeNull();
  });

  it('update_plan accepts target_duration_s on exercise items in the tree', async () => {
    const r = await call('update_plan', {
      name: 'Timed in tree',
      days: [{ name: 'A', day_label: 'A', exercises: [
        { exercise: 'Bench Press', order_index: 0, target_sets: 3, target_reps: 5 },
        { exercise: 'Plank',       order_index: 1, target_sets: 2, target_reps: 1, target_duration_s: 30 },
        { exercise: 'Dead Hang',   order_index: 2, target_sets: 2, target_reps: 1, target_duration_s: 15 },
      ] }],
    });
    expect(r.conflict).toBe(false);
    const exs = r.plan.days[0].exercises;
    expect(exs.find((e: { exercise_id: string }) => e.exercise_id === 'ex_plank').target_duration_s).toBe(30);
    expect(exs.find((e: { exercise_id: string }) => e.exercise_id === 'ex_dead_hang').target_duration_s).toBe(15);
    // Non-timed slot stays null.
    expect(exs.find((e: { exercise_id: string }) => e.exercise_id === 'ex_bench').target_duration_s).toBeNull();
  });

  it('log_set preserves a same-weight MCP straight-set series', async () => {
    await call('update_plan', {
      name: 'Straight sets',
      days: [
        {
          day_label: 'S',
          name: 'Straight Sets',
          exercises: [{ exercise: 'bench', target_sets: 3, target_reps: 5 }],
        },
      ],
    });

    const sets = [];
    for (let i = 0; i < 3; i++) {
      sets.push(
        await call('log_set', {
          exercise: 'bench',
          weight: 187,
          reps: 5,
        }),
      );
    }

    expect(sets.map((r) => r.error)).toEqual([undefined, undefined, undefined]);
    const indexes = sets.map((r) => r.set.set_index);
    expect(indexes[1]).toBe(indexes[0] + 1);
    expect(indexes[2]).toBe(indexes[1] + 1);
    expect(new Set(sets.map((r) => r.set.id)).size).toBe(3);
  });

  it('log_set preserves repeated timed MCP efforts', async () => {
    await call('update_plan', {
      name: 'Timed repeats',
      days: [
        {
          day_label: 'T',
          name: 'Timed Repeats',
          exercises: [{ exercise: 'plank', target_sets: 2, target_reps: 1, target_duration_s: 30 }],
        },
      ],
    });

    const first = await call('log_set', {
      exercise: 'plank',
      weight: 0,
      reps: 1,
      duration_s: 30,
      is_timed: true,
    });
    const second = await call('log_set', {
      exercise: 'plank',
      weight: 0,
      reps: 1,
      duration_s: 30,
      is_timed: true,
    });

    expect(first.error).toBeUndefined();
    expect(second.error).toBeUndefined();
    expect([first.set.duration_s, second.set.duration_s]).toEqual([30, 30]);
    expect([first.set.is_timed, second.set.is_timed]).toEqual([1, 1]);
    expect(second.set.set_index).toBe(first.set.set_index + 1);
    expect(first.set.id).not.toBe(second.set.id);
  });

  describe('log_set blocks ambiguous iOS narration but accepts explicit distinctions and confirmation', () => {
    // One seed for the block. vitest-pool-workers' default isolatedStorage
    // keeps beforeAll writes visible to every `it` below and undoes each
    // `it`'s own writes after it runs, so every case starts from the same
    // plan + iOS session. The seeded iOS sets are logged 20–40 s before the
    // block starts and findRecentMatchingSet's window is 120 s, so they stay
    // "recent" for every case. The cases are independent by design: a single
    // sequential case covering all of them made 21 round-trips and sat near
    // vitest's 5 s default per-test timeout on a CI runner.
    let sessionId: string;
    let today: string;

    beforeAll(async () => {
      // Plan + a session iOS just logged a 185x5 squat into.
      const built = await call('update_plan', {
        name: 'Dedupe',
        days: [
          {
            day_label: 'L',
            name: 'Legs',
            exercises: [{ exercise: 'squat', target_sets: 3, target_reps: 5 }],
          },
        ],
      });
      expect(built.conflict).toBe(false);
      // Simulate the iOS write directly: create today's session + a set with
      // source='ios' logged 30s ago. (Bypasses the MCP gate — that's the
      // point: iOS is the source of truth, MCP must respect what's there.)
      const planId = built.plan.id as string;
      // The plan's owner is the MCP-resolved owner; use that user_id so the
      // hand-inserted iOS session shares the same user (single-user invariant).
      const planRow = await env.DB
        .prepare("SELECT user_id FROM plans WHERE id = ?1")
        .bind(planId)
        .first<{ user_id: string }>();
      const userId = planRow!.user_id;
      today = new Date().toISOString().slice(0, 10);
      sessionId = crypto.randomUUID();
      const tNow = Date.now();
      await env.DB
        .prepare(
          `INSERT INTO sessions (id,user_id,plan_id,date,status,started_at,created_at,updated_at)
           VALUES (?1,?2,?3,?4,'in_progress',?5,?5,?5)`,
        )
        .bind(sessionId, userId, planId, today, tNow - 30_000)
        .run();
      const insertIosSet = env.DB.prepare(
        `INSERT INTO set_logs (id,session_id,exercise_id,template_exercise_id,set_index,weight,reps,rpe,is_warmup,notes,logged_at,source,duration_s,deleted_at)
         VALUES (?1,?2,'ex_back_squat',NULL,?3,?4,5,NULL,0,NULL,?5,'ios',?6,NULL)`,
      );
      const iosSets: Array<[number, number, number, number]> = [
        [1, 185, tNow - 30_000, 30],
        [2, 195, tNow - 30_000, 30],
        [3, 205, tNow - 30_000, 30],
        // Same triple twice: the older row must remain discoverable when an
        // explicit discriminator matches it but not the newest candidate.
        [4, 215, tNow - 40_000, 30],
        [5, 215, tNow - 20_000, 45],
      ];
      await env.DB.batch(
        iosSets.map(([setIndex, weight, loggedAt, duration]) =>
          insertIosSet.bind(crypto.randomUUID(), sessionId, setIndex, weight, loggedAt, duration),
        ),
      );
    });

    it("rejects the phantom narration (same triple ~30 s later), with or without today's date, and does not insert", async () => {
      // The phantom narration call: same exercise/weight/reps, ~30s later.
      const dup = await call('log_set', { exercise: 'squat', weight: 185, reps: 5 });
      expect(dup.error).toBe('recent_duplicate');
      expect(dup.existing_set.source).toBe('ios');
      expect(dup.message).toMatch(/iOS/);

      // Only the one matching iOS set survives — the MCP call did NOT insert.
      const live = await env.DB
        .prepare(
          "SELECT COUNT(*) AS c FROM set_logs WHERE session_id = ?1 AND deleted_at IS NULL AND weight = 185 AND reps = 5",
        )
        .bind(sessionId)
        .first<{ c: number }>();
      expect(live!.c).toBe(1);

      // Supplying today's date is still ambiguous and remains blocked.
      const sameDay = await call('log_set', {
        exercise: 'squat',
        weight: 185,
        reps: 5,
        session_date: today,
      });
      expect(sameDay.error).toBe('recent_duplicate');
    });

    it('an older recent iOS row matching a supplied discriminator is not shadowed by the newest same-triple row', async () => {
      // The newest same-triple row differs, but an older recent iOS row still
      // matches each supplied discriminator and must not be shadowed.
      const olderIndexMatch = await call('log_set', {
        exercise: 'squat',
        weight: 215,
        reps: 5,
        set_index: 4,
      });
      expect(olderIndexMatch.error).toBe('recent_duplicate');
      expect(olderIndexMatch.existing_set.set_index).toBe(4);

      const olderDurationMatch = await call('log_set', {
        exercise: 'squat',
        weight: 215,
        reps: 5,
        duration_s: 30,
        is_timed: true,
      });
      expect(olderDurationMatch.error).toBe('recent_duplicate');
      expect(olderDurationMatch.existing_set.duration_s).toBe(30);

      const trulyDistinct = await call('log_set', {
        exercise: 'squat',
        weight: 215,
        reps: 5,
        set_index: 21,
        duration_s: 60,
        is_timed: true,
      });
      expect(trulyDistinct.error).toBeUndefined();
      expect(trulyDistinct.set.set_index).toBe(21);
      expect(trulyDistinct.set.duration_s).toBe(60);
    });

    it('accepts explicit distinctions: a warm-up, a different weight, an explicit set_index, a distinct duration', async () => {
      // Same triple-but-warmup is NOT considered a dupe of a working set.
      const wu = await call('log_set', {
        exercise: 'squat',
        weight: 185,
        reps: 5,
        is_warmup: true,
      });
      expect(wu.error).toBeUndefined();
      expect(wu.set.is_warmup).toBe(1);

      // Different weight in the window logs fine (real next set).
      const next = await call('log_set', { exercise: 'squat', weight: 225, reps: 5 });
      expect(next.error).toBeUndefined();
      expect(next.set.weight).toBe(225);

      // An explicit different set index identifies a separate intended set,
      // even though an iOS set has the same exercise/weight/reps triple.
      const indexed = await call('log_set', {
        exercise: 'squat',
        weight: 205,
        reps: 5,
        set_index: 20,
      });
      expect(indexed.error).toBeUndefined();
      expect(indexed.set.set_index).toBe(20);

      // Duration distinguishes repeated timed efforts across channels.
      const durationDistinct = await call('log_set', {
        exercise: 'squat',
        weight: 185,
        reps: 5,
        duration_s: 45,
        is_timed: true,
      });
      expect(durationDistinct.error).toBeUndefined();
      expect(durationDistinct.set.duration_s).toBe(45);
    });

    it('an identical recent iOS set stays blocked until confirm_duplicate; explicit backfill to a past date bypasses the gate', async () => {
      // An otherwise identical recent iOS set remains blocked until the user
      // explicitly confirms it is a separate intentional repeat.
      const needsConfirmation = await call('log_set', {
        exercise: 'squat',
        weight: 195,
        reps: 5,
      });
      expect(needsConfirmation.error).toBe('recent_duplicate');
      const confirmed = await call('log_set', {
        exercise: 'squat',
        weight: 195,
        reps: 5,
        confirm_duplicate: true,
      });
      expect(confirmed.error).toBeUndefined();
      expect(confirmed.set.source).toBe('mcp');

      // Explicit backfill to a past date bypasses the gate — "log yesterday's
      // 185x5" is an explicit logging intent and must not be blocked by today's
      // matching iOS set.
      const yesterday = new Date(Date.now() - 86_400_000).toISOString().slice(0, 10);
      const backfill = await call('log_set', {
        exercise: 'squat',
        weight: 185,
        reps: 5,
        session_date: yesterday,
      });
      expect(backfill.error).toBeUndefined();
      expect(backfill.set.weight).toBe(185);
    });
  });

  it('log_set rejects a recent duplicate before reviving its discarded target date', async () => {
    const built = await call('update_plan', {
      name: 'Duplicate rejection is mutation-free',
      days: [
        {
          day_label: 'L',
          name: 'Legs',
          exercises: [{ exercise: 'squat', target_sets: 3, target_reps: 5 }],
        },
      ],
    });
    const planId = built.plan.id as string;
    const planRow = await env.DB
      .prepare('SELECT user_id FROM plans WHERE id = ?1')
      .bind(planId)
      .first<{ user_id: string }>();
    const userId = planRow!.user_id;
    const targetDate = (await call('get_today_workout', {})).date as string;
    const now = Date.now();

    // Reuse the singleton date row if an earlier test created it, then pin a
    // distinctive generation so any accidental revival is observable.
    const existingTarget = await env.DB
      .prepare('SELECT id, attempt FROM sessions WHERE user_id = ?1 AND date = ?2')
      .bind(userId, targetDate)
      .first<{ id: string; attempt: number }>();
    const targetId = existingTarget?.id ?? crypto.randomUUID();
    const targetAttempt = (existingTarget?.attempt ?? 0) + 17;
    const targetUpdatedAt = now - 5_000;
    if (existingTarget) {
      await env.DB
        .prepare(
          `UPDATE sessions
              SET plan_id=?2, day_template_id=NULL, status='discarded',
                  started_at=NULL, completed_at=NULL, perceived_fatigue=NULL,
                  notes=NULL, updated_at=?3, attempt=?4, write_protocol='legacy'
            WHERE id=?1`,
        )
        .bind(targetId, planId, targetUpdatedAt, targetAttempt)
        .run();
    } else {
      await env.DB
        .prepare(
          `INSERT INTO sessions
             (id,user_id,plan_id,day_template_id,date,status,started_at,
              completed_at,perceived_fatigue,notes,created_at,updated_at,
              attempt,write_protocol)
           VALUES (?1,?2,?3,NULL,?4,'discarded',NULL,NULL,NULL,NULL,?5,?5,?6,'legacy')`,
        )
        .bind(targetId, userId, planId, targetDate, targetUpdatedAt, targetAttempt)
        .run();
    }

    // The matching iOS set is recent, but belongs to a different date. The
    // duplicate guard is intentionally cross-date; rejecting it must not
    // touch the discarded target row selected above.
    const sourceSessionId = crypto.randomUUID();
    await env.DB
      .prepare(
        `INSERT INTO sessions
           (id,user_id,plan_id,day_template_id,date,status,started_at,
            completed_at,perceived_fatigue,notes,created_at,updated_at,
            attempt,write_protocol)
         VALUES (?1,?2,?3,NULL,'1999-12-31','in_progress',?4,NULL,NULL,NULL,?4,?4,0,'legacy')`,
      )
      .bind(sourceSessionId, userId, planId, now - 1_000)
      .run();
    await env.DB
      .prepare(
        `INSERT INTO set_logs
           (id,session_id,exercise_id,template_exercise_id,set_index,weight,
            reps,rpe,is_warmup,notes,logged_at,source,duration_s,deleted_at)
         VALUES (?1,?2,'ex_back_squat',NULL,1,333.7,13,NULL,0,NULL,?3,'ios',NULL,NULL)`,
      )
      .bind(crypto.randomUUID(), sourceSessionId, now - 1_000)
      .run();

    const duplicate = await call('log_set', { exercise: 'squat', weight: 333.7, reps: 13 });
    expect(duplicate).toMatchObject({
      error: 'recent_duplicate',
      existing_set: { session_id: sourceSessionId, source: 'ios' },
    });

    const targetAfter = await env.DB
      .prepare(
        'SELECT status, attempt, write_protocol, updated_at FROM sessions WHERE id = ?1',
      )
      .bind(targetId)
      .first<{
        status: string;
        attempt: number;
        write_protocol: string;
        updated_at: number;
      }>();
    expect(targetAfter).toEqual({
      status: 'discarded',
      attempt: targetAttempt,
      write_protocol: 'legacy',
      updated_at: targetUpdatedAt,
    });

    // Rejected writes remain visible in the normal MCP audit trail.
    const audit = await env.DB
      .prepare(
        `SELECT result FROM audit_log
          WHERE actor='mcp' AND tool='log_set' AND args LIKE '%"weight":333.7%'
          ORDER BY created_at DESC LIMIT 1`,
      )
      .first<{ result: string }>();
    // Audit payloads are intentionally capped at 500 bytes, so assert the
    // leading outcome without requiring the truncated JSON to parse.
    expect(audit!.result).toContain('"error":"recent_duplicate"');
  });

  it('delete_set soft-deletes a logged set; missing id reports not_found', async () => {
    // Fresh plan + one MCP-logged set.
    const built = await call('update_plan', {
      name: 'Delete',
      days: [
        {
          day_label: 'P',
          name: 'Press',
          exercises: [{ exercise: 'overhead press', target_sets: 3, target_reps: 5 }],
        },
      ],
    });
    expect(built.conflict).toBe(false);
    const logged = await call('log_set', {
      exercise: 'overhead press',
      weight: 95,
      reps: 5,
    });
    expect(logged.error).toBeUndefined();
    const setId = logged.set.id as string;

    // Delete via MCP.
    const del = await call('delete_set', { set_id: setId });
    expect(del.error).toBeUndefined();
    expect(del.id).toBe(setId);
    expect(del.deleted_at).toBeTruthy();

    // get_current_session no longer surfaces it.
    const cur = await call('get_current_session', {});
    const stillThere = (cur.sets ?? []).some((s: { id: string }) => s.id === setId);
    expect(stillThere).toBe(false);

    // Audit row written; missing id returns not_found.
    const audit = await env.DB
      .prepare("SELECT COUNT(*) AS c FROM audit_log WHERE tool='delete_set'")
      .first<{ c: number }>();
    expect(audit!.c).toBeGreaterThanOrEqual(1);
    const miss = await call('delete_set', { set_id: 'no-such-uuid' });
    expect(miss.error).toBe('not_found');
  });

  describe('correct_set validates and visibly corrects values without crossing tenant boundaries', () => {
    // One seed for the block (isolatedStorage keeps it visible to every `it`
    // and rolls each `it`'s own writes back): a plan and one MCP-logged
    // 185x5 bench set with a 42 s duration, which every case starts from
    // unchanged. The single sequential case this replaces made 19 round-trips
    // and sat near vitest's 5 s default per-test timeout on a CI runner.
    let setId: string;

    beforeAll(async () => {
      const built = await call('update_plan', {
        name: 'Corrections',
        days: [
          {
            day_label: 'C',
            name: 'Correction day',
            exercises: [{ exercise: 'bench', target_sets: 3, target_reps: 5 }],
          },
        ],
      });
      expect(built.conflict).toBe(false);
      const logged = await call('log_set', {
        exercise: 'bench',
        weight: 185,
        reps: 5,
        duration_s: 42,
      });
      expect(logged.error).toBeUndefined();
      setId = logged.set.id as string;
    });

    it('corrects values visibly, clears nullable fields with null, and is audited + noted', async () => {
      const corrected = await call('correct_set', {
        set_id: setId,
        weight: 190,
        reps: 6,
        rpe: 8.5,
        notes: 'corrected from watch',
        duration_s: 75,
      });
      expect(corrected).toMatchObject({
        id: setId,
        weight: 190,
        reps: 6,
        rpe: 8.5,
        notes: 'corrected from watch',
        duration_s: 75,
      });

      const visible = await call('get_current_session', {});
      expect(visible.sets.find((set: { id: string }) => set.id === setId)).toMatchObject({
        weight: 190,
        reps: 6,
        duration_s: 75,
      });

      const cleared = await call('correct_set', {
        set_id: setId,
        rpe: null,
        notes: null,
        duration_s: null,
      });
      expect(cleared).toMatchObject({ id: setId, rpe: null, notes: null, duration_s: null });

      const audit = await env.DB
        .prepare("SELECT COUNT(*) AS c FROM audit_log WHERE tool='correct_set'")
        .first<{ c: number }>();
      expect(audit!.c).toBe(2);
      const note = await env.DB
        .prepare('SELECT body FROM notes WHERE body = ?1 ORDER BY created_at DESC LIMIT 1')
        .bind(`Corrected set ${setId} to 190x6.`)
        .first<{ body: string }>();
      expect(note?.body).toBe(`Corrected set ${setId} to 190x6.`);
    });

    it('one invalid value, an unknown field, or an empty correction rejects the whole call with no partial write', async () => {
      // One invalid value rejects the whole correction; valid siblings do not
      // leak through as a partial update.
      const invalid = await call('correct_set', {
        set_id: setId,
        weight: 999,
        duration_s: 1.5,
      });
      expect(invalid).toEqual({ error: 'invalid_fields', fields: ['duration_s'] });
      const unchanged = await env.DB
        .prepare('SELECT weight, duration_s FROM set_logs WHERE id = ?1')
        .bind(setId)
        .first<{ weight: number; duration_s: number | null }>();
      expect(unchanged).toEqual({ weight: 185, duration_s: 42 });

      const unknownField = await call('correct_set', {
        set_id: setId,
        weight: 999,
        duration_seconds: 75,
      });
      expect(unknownField).toEqual({
        error: 'invalid_fields',
        fields: ['duration_seconds'],
      });
      expect(
        await env.DB
          .prepare('SELECT weight, duration_s FROM set_logs WHERE id = ?1')
          .bind(setId)
          .first<{ weight: number; duration_s: number | null }>(),
      ).toEqual({ weight: 185, duration_s: 42 });
      expect(await call('correct_set', { set_id: setId })).toEqual({ error: 'no_corrections' });

      // rejections stay visible in the audit trail but never write a note
      const audit = await env.DB
        .prepare("SELECT COUNT(*) AS c FROM audit_log WHERE tool='correct_set'")
        .first<{ c: number }>();
      expect(audit!.c).toBe(3);
      const notes = await env.DB
        .prepare("SELECT COUNT(*) AS c FROM notes WHERE body LIKE 'Corrected set %'")
        .first<{ c: number }>();
      expect(notes!.c).toBe(0);
    });

    it("reports not_found for a missing id and for another tenant's set, which stays untouched", async () => {
      expect(await call('correct_set', { set_id: 'missing-set', weight: 1 })).toMatchObject({
        error: 'not_found',
        set_id: 'missing-set',
      });

      const foreignUserId = crypto.randomUUID();
      const foreignPlanId = crypto.randomUUID();
      const foreignSessionId = crypto.randomUUID();
      const foreignSetId = crypto.randomUUID();
      const now = Date.now();
      await env.DB.batch([
        env.DB
          .prepare(
            'INSERT INTO users (id,apple_sub,email,display_name,created_at) VALUES (?1,?2,NULL,?3,?4)',
          )
          .bind(foreignUserId, `sub-${foreignUserId}`, 'Foreign lifter', now),
        env.DB
          .prepare(
            "INSERT INTO plans (id,user_id,name,status,version,meta,created_at,updated_at) VALUES (?1,?2,'Foreign','active',1,NULL,?3,?3)",
          )
          .bind(foreignPlanId, foreignUserId, now),
        env.DB
          .prepare(
            "INSERT INTO sessions (id,user_id,plan_id,day_template_id,date,status,started_at,completed_at,perceived_fatigue,notes,created_at,updated_at) VALUES (?1,?2,?3,NULL,'2040-01-02','in_progress',?4,NULL,NULL,NULL,?4,?4)",
          )
          .bind(foreignSessionId, foreignUserId, foreignPlanId, now),
        env.DB
          .prepare(
            "INSERT INTO set_logs (id,session_id,exercise_id,template_exercise_id,set_index,weight,reps,rpe,is_warmup,notes,logged_at,source,deleted_at,duration_s,is_timed) VALUES (?1,?2,'ex_bench',NULL,1,95,5,NULL,0,NULL,?3,'ios',NULL,NULL,0)",
          )
          .bind(foreignSetId, foreignSessionId, now),
      ]);

      expect(await call('correct_set', { set_id: foreignSetId, weight: 100 })).toMatchObject({
        error: 'not_found',
        set_id: foreignSetId,
      });
      const foreignRow = await env.DB
        .prepare('SELECT weight FROM set_logs WHERE id = ?1')
        .bind(foreignSetId)
        .first<{ weight: number }>();
      expect(foreignRow?.weight).toBe(95);

      // both misses are audited
      const audit = await env.DB
        .prepare("SELECT COUNT(*) AS c FROM audit_log WHERE tool='correct_set'")
        .first<{ c: number }>();
      expect(audit!.c).toBe(2);
    });
  });
});

describe('update_plan preserves warm-up flags', () => {
  it('keeps is_warmup on a slot when a rebuild omits the field', async () => {
    // Build a day with a prescribed warm-up slot + a working slot.
    const built = await call('update_plan', {
      name: 'Warmup preservation',
      days: [
        {
          day_label: 'A',
          name: 'Warmup Day',
          exercises: [
            { exercise: 'erg', target_sets: 1, target_reps: 1, target_duration_s: 300, is_warmup: true },
            { exercise: 'bench', target_sets: 3, target_reps: 5 },
          ],
        },
      ],
    });
    expect(built.conflict).toBe(false);
    const day0 = built.plan.days[0];
    const warm = day0.exercises.find((e: any) => e.is_warmup === 1);
    const work = day0.exercises.find((e: any) => e.is_warmup === 0);
    expect(warm).toBeTruthy();
    expect(work).toBeTruthy();

    // Rebuild the SAME tree as an older caller would: omit is_warmup entirely.
    const rebuilt = await call('update_plan', {
      name: 'Warmup preservation',
      days: [
        {
          day_label: 'A',
          name: 'Warmup Day',
          exercises: [
            { exercise: 'erg', target_sets: 1, target_reps: 1, target_duration_s: 300 },
            { exercise: 'bench', target_sets: 3, target_reps: 5 },
          ],
        },
      ],
    });
    expect(rebuilt.conflict).toBe(false);

    // The warm-up flag survived — not silently demoted to a working slot.
    const rday = rebuilt.plan.days[0];
    const rerg = rday.exercises.find((e: any) => e.exercise_id === warm.exercise_id);
    const rbench = rday.exercises.find((e: any) => e.exercise_id === work.exercise_id);
    expect(rerg.is_warmup).toBe(1);
    expect(rbench.is_warmup).toBe(0);
  });

  it('honors an explicit is_warmup:false over the preserved value', async () => {
    const built = await call('update_plan', {
      name: 'Explicit clear',
      days: [
        {
          day_label: 'A',
          name: 'Clear Day',
          exercises: [{ exercise: 'erg', target_sets: 1, target_reps: 1, target_duration_s: 300, is_warmup: true }],
        },
      ],
    });
    const warmId = built.plan.days[0].exercises[0].exercise_id;

    const cleared = await call('update_plan', {
      name: 'Explicit clear',
      days: [
        {
          day_label: 'A',
          name: 'Clear Day',
          exercises: [{ exercise: 'erg', target_sets: 1, target_reps: 1, target_duration_s: 300, is_warmup: false }],
        },
      ],
    });
    const slot = cleared.plan.days[0].exercises.find((e: any) => e.exercise_id === warmId);
    expect(slot.is_warmup).toBe(0);
  });

  it('preserves per-occurrence flags when the same exercise appears twice', async () => {
    // A day with the same movement twice: a prescribed warm-up ramp, then
    // working sets. Both resolve to the same exercise_id.
    const built = await call('update_plan', {
      name: 'Dup occurrence',
      days: [
        {
          day_label: 'A',
          name: 'Ramp Day',
          exercises: [
            { exercise: 'erg', target_sets: 1, target_reps: 1, target_duration_s: 300, is_warmup: true },
            { exercise: 'erg', target_sets: 3, target_reps: 10, target_duration_s: 600, is_warmup: false },
          ],
        },
      ],
    });
    let ex = built.plan.days[0].exercises;
    expect(ex).toHaveLength(2);
    expect(ex[0].is_warmup).toBe(1);
    expect(ex[1].is_warmup).toBe(0);

    // Older caller omits is_warmup on both occurrences during a rebuild.
    const rebuilt = await call('update_plan', {
      name: 'Dup occurrence',
      days: [
        {
          day_label: 'A',
          name: 'Ramp Day',
          exercises: [
            { exercise: 'erg', target_sets: 1, target_reps: 1, target_duration_s: 300 },
            { exercise: 'erg', target_sets: 3, target_reps: 10, target_duration_s: 600 },
          ],
        },
      ],
    });
    ex = rebuilt.plan.days[0].exercises;
    expect(ex).toHaveLength(2);
    // Each occurrence keeps its own flag — the warm-up isn't smeared onto the
    // working slot, nor the working flag onto the warm-up.
    expect(ex[0].is_warmup).toBe(1);
    expect(ex[1].is_warmup).toBe(0);
  });

  it('remaps a logged set to the same occurrence across a rebuild', async () => {
    // Day with the same exercise twice: warm-up ramp (occ0) + working (occ1).
    const planBody = {
      name: 'Dup remap',
      days: [
        {
          day_label: 'A',
          name: 'Remap Day',
          exercises: [
            { exercise: 'erg', target_sets: 1, target_reps: 1, target_duration_s: 300, is_warmup: true },
            { exercise: 'erg', target_sets: 3, target_reps: 10, target_duration_s: 600, is_warmup: false },
          ],
        },
      ],
    };
    const built = await call('update_plan', planBody);
    const slots0 = built.plan.days[0].exercises;
    expect(slots0).toHaveLength(2);
    const workingOldId = slots0[1].id; // occ1 — the working slot
    expect(slots0[1].is_warmup).toBe(0);

    // Seed a session with a set logged against the WORKING slot (occ1) — the
    // case the first-occurrence remap mis-pointed onto the warm-up slot.
    const userId = (await env.DB.prepare('SELECT id FROM users ORDER BY created_at LIMIT 1').first<{ id: string }>())!.id;
    const planId = (
      await env.DB.prepare("SELECT id FROM plans WHERE user_id=?1 AND status='active'").bind(userId).first<{ id: string }>()
    )!.id;
    const sid = crypto.randomUUID();
    await env.DB.prepare(
      'INSERT INTO sessions (id,user_id,plan_id,day_template_id,date,status,started_at,completed_at,perceived_fatigue,notes,created_at,updated_at) VALUES (?1,?2,?3,NULL,?4,?5,?6,NULL,NULL,NULL,?7,?7)',
    )
      .bind(sid, userId, planId, '2026-09-01', 'in_progress', Date.now(), Date.now())
      .run();
    const setId = crypto.randomUUID();
    await env.DB.prepare(
      "INSERT INTO set_logs (id,session_id,exercise_id,template_exercise_id,set_index,weight,reps,rpe,is_warmup,notes,logged_at,source,deleted_at) VALUES (?1,?2,?3,?4,1,150,10,8,0,NULL,?5,'ios',NULL)",
    )
      .bind(setId, sid, slots0[1].exercise_id, workingOldId, Date.now())
      .run();

    // Rebuild with both occurrences intact (new slot ids minted).
    const rebuilt = await call('update_plan', planBody);
    const slots1 = rebuilt.plan.days[0].exercises;
    const newWarmupId = slots1[0].id; // new occ0
    const newWorkingId = slots1[1].id; // new occ1

    // The set followed the working occurrence — not collapsed onto occ0.
    const set = await env.DB.prepare('SELECT template_exercise_id FROM set_logs WHERE id=?1')
      .bind(setId)
      .first<{ template_exercise_id: string }>();
    expect(set!.template_exercise_id).toBe(newWorkingId);
    expect(set!.template_exercise_id).not.toBe(newWarmupId);
  });

  it('detaches (nulls) a logged set when its occurrence is dropped, never falling back to a surviving slot', async () => {
    // Same warm-up (occ0) + working (occ1) day; the working slot's sets must
    // NOT reattach to the surviving warm-up slot when the rebuild drops occ1.
    const dupBody = {
      name: 'Dup detach',
      days: [
        {
          day_label: 'A',
          name: 'Detach Day',
          exercises: [
            { exercise: 'erg', target_sets: 1, target_reps: 1, target_duration_s: 300, is_warmup: true },
            { exercise: 'erg', target_sets: 3, target_reps: 10, target_duration_s: 600, is_warmup: false },
          ],
        },
      ],
    };
    const built = await call('update_plan', dupBody);
    const slots0 = built.plan.days[0].exercises;
    expect(slots0).toHaveLength(2);
    const workingOldId = slots0[1].id; // occ1 — the working slot

    const userId = (await env.DB.prepare('SELECT id FROM users ORDER BY created_at LIMIT 1').first<{ id: string }>())!.id;
    const planId = (
      await env.DB.prepare("SELECT id FROM plans WHERE user_id=?1 AND status='active'").bind(userId).first<{ id: string }>()
    )!.id;
    const sid = crypto.randomUUID();
    await env.DB.prepare(
      'INSERT INTO sessions (id,user_id,plan_id,day_template_id,date,status,started_at,completed_at,perceived_fatigue,notes,created_at,updated_at) VALUES (?1,?2,?3,NULL,?4,?5,?6,NULL,NULL,NULL,?7,?7)',
    )
      .bind(sid, userId, planId, '2026-09-02', 'in_progress', Date.now(), Date.now())
      .run();
    const setId = crypto.randomUUID();
    await env.DB.prepare(
      "INSERT INTO set_logs (id,session_id,exercise_id,template_exercise_id,set_index,weight,reps,rpe,is_warmup,notes,logged_at,source,deleted_at) VALUES (?1,?2,?3,?4,1,150,10,8,0,NULL,?5,'ios',NULL)",
    )
      .bind(setId, sid, slots0[1].exercise_id, workingOldId, Date.now())
      .run();

    // Rebuild dropping the working slot, keeping ONLY the warm-up occurrence.
    const rebuilt = await call('update_plan', {
      name: 'Dup detach',
      days: [
        {
          day_label: 'A',
          name: 'Detach Day',
          exercises: [
            { exercise: 'erg', target_sets: 1, target_reps: 1, target_duration_s: 300, is_warmup: true },
          ],
        },
      ],
    });
    const slots1 = rebuilt.plan.days[0].exercises;
    expect(slots1).toHaveLength(1);
    const survivingWarmupId = slots1[0].id;

    // The orphaned working set detaches to null — it does NOT land on the
    // surviving warm-up slot (which would corrupt that slot's completion).
    const set = await env.DB.prepare('SELECT template_exercise_id FROM set_logs WHERE id=?1')
      .bind(setId)
      .first<{ template_exercise_id: string | null }>();
    expect(set!.template_exercise_id).toBeNull();
    expect(set!.template_exercise_id).not.toBe(survivingWarmupId);
  });

  it('detaches a LEADING dropped duplicate (warm-up) instead of sliding it onto the working slot', async () => {
    // Warm-up erg (occ0) + working erg (occ1); dropping the FRONT occurrence
    // (the warm-up) must detach the warm-up's logged sets, NOT remap them onto
    // the surviving working slot. The pre-class-keying positional remap paired
    // old-occ0 → new-occ0 and slid warm-up sets onto the working erg.
    const dupBody = {
      name: 'Lead detach',
      days: [
        {
          day_label: 'A',
          name: 'Lead Day',
          exercises: [
            { exercise: 'erg', target_sets: 1, target_reps: 1, target_duration_s: 300, is_warmup: true },
            { exercise: 'erg', target_sets: 3, target_reps: 10, target_duration_s: 600, is_warmup: false },
          ],
        },
      ],
    };
    const built = await call('update_plan', dupBody);
    const slots0 = built.plan.days[0].exercises;
    expect(slots0).toHaveLength(2);
    const warmupOldId = slots0[0].id; // occ0 — the warm-up slot
    expect(slots0[0].is_warmup).toBe(1);

    const userId = (await env.DB.prepare('SELECT id FROM users ORDER BY created_at LIMIT 1').first<{ id: string }>())!.id;
    const planId = (
      await env.DB.prepare("SELECT id FROM plans WHERE user_id=?1 AND status='active'").bind(userId).first<{ id: string }>()
    )!.id;
    const sid = crypto.randomUUID();
    await env.DB.prepare(
      'INSERT INTO sessions (id,user_id,plan_id,day_template_id,date,status,started_at,completed_at,perceived_fatigue,notes,created_at,updated_at) VALUES (?1,?2,?3,NULL,?4,?5,?6,NULL,NULL,NULL,?7,?7)',
    )
      .bind(sid, userId, planId, '2026-09-03', 'in_progress', Date.now(), Date.now())
      .run();
    // A warm-up set (is_warmup=1) logged against the WARM-UP slot.
    const setId = crypto.randomUUID();
    await env.DB.prepare(
      "INSERT INTO set_logs (id,session_id,exercise_id,template_exercise_id,set_index,weight,reps,rpe,is_warmup,notes,logged_at,source,deleted_at) VALUES (?1,?2,?3,?4,1,0,300,NULL,1,NULL,?5,'ios',NULL)",
    )
      .bind(setId, sid, slots0[0].exercise_id, warmupOldId, Date.now())
      .run();

    // Rebuild dropping the warm-up, keeping ONLY the working erg.
    const rebuilt = await call('update_plan', {
      name: 'Lead detach',
      days: [
        {
          day_label: 'A',
          name: 'Lead Day',
          exercises: [
            { exercise: 'erg', target_sets: 3, target_reps: 10, target_duration_s: 600, is_warmup: false },
          ],
        },
      ],
    });
    const slots1 = rebuilt.plan.days[0].exercises;
    expect(slots1).toHaveLength(1);
    const survivingWorkingId = slots1[0].id;
    expect(slots1[0].is_warmup).toBe(0);

    // The warm-up set detaches — it does NOT slide onto the working slot.
    const set = await env.DB.prepare('SELECT template_exercise_id FROM set_logs WHERE id=?1')
      .bind(setId)
      .first<{ template_exercise_id: string | null }>();
    expect(set!.template_exercise_id).toBeNull();
    expect(set!.template_exercise_id).not.toBe(survivingWorkingId);
  });
});
