import { env, applyD1Migrations } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import {
  deleteDayTemplate,
  detectConflicts,
  getProjectedCalendar,
  getRideConflicts,
  projectCalendar,
  setPlanSchedule,
  setPlannedSession,
  skipPlannedSession,
  weekdayOf,
} from '../src/db';
import type { ExternalEventRow, SessionRow, WeeklySchedule } from '../src/types';
import { parsePlanMeta } from '../src/types';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

const sess = (date: string, status: string, day: string | null = null): SessionRow => ({
  id: `s-${date}`,
  user_id: 'u',
  plan_id: 'p',
  day_template_id: day,
  date,
  status,
  started_at: null,
  completed_at: null,
  perceived_fatigue: null,
  notes: null,
  created_at: 0,
  updated_at: 0,
});

// Mon..Sun schedule: Mon=push, Wed=pull, Fri=legs, rest otherwise.
const SCHED: WeeklySchedule = {
  version: 1,
  week: {
    mon: 'd_push',
    tue: null,
    wed: 'd_pull',
    thu: null,
    fri: 'd_legs',
    sat: null,
    sun: null,
  },
};
const LIVE = ['d_push', 'd_pull', 'd_legs'];

describe('weekdayOf — calendar rule (iOS must mirror byte-for-byte)', () => {
  it('1970-01-05 is Monday; known anchors hold', () => {
    expect(weekdayOf('1970-01-05')).toBe('mon');
    expect(weekdayOf('1970-01-11')).toBe('sun');
    // 2026-05-18 is a Monday.
    expect(weekdayOf('2026-05-18')).toBe('mon');
    expect(weekdayOf('2026-05-24')).toBe('sun');
    // Leap-year boundary sanity: 2024-02-29 was a Thursday.
    expect(weekdayOf('2024-02-29')).toBe('thu');
    // Century non-leap: 2000-01-01 was a Saturday (Gregorian).
    expect(weekdayOf('2000-01-01')).toBe('sat');
  });
});

describe('projectCalendar — truth table', () => {
  const today = '2026-05-18'; // Monday

  it('past dates are omitted unless a real session exists', () => {
    const cells = projectCalendar(
      { id: 'p' },
      SCHED,
      [sess('2026-05-11', 'completed', 'd_push')],
      '2026-05-11',
      '2026-05-15',
      today,
      LIVE,
    );
    // Only the one real past session; no fabricated rest/missed days.
    expect(cells).toHaveLength(1);
    expect(cells[0]).toMatchObject({
      date: '2026-05-11',
      status: 'completed',
      real: true,
      day_template_id: 'd_push',
    });
  });

  it('future dates project from the weekly pattern', () => {
    const cells = projectCalendar(
      { id: 'p' },
      SCHED,
      [],
      '2026-05-18', // Mon
      '2026-05-24', // Sun
      today,
      LIVE,
    );
    expect(cells).toHaveLength(7);
    const byDate = Object.fromEntries(cells.map((c) => [c.date, c]));
    expect(byDate['2026-05-18']).toMatchObject({ status: 'projected', day_template_id: 'd_push' });
    expect(byDate['2026-05-19']).toMatchObject({ status: 'rest', day_template_id: null });
    expect(byDate['2026-05-20']).toMatchObject({ status: 'projected', day_template_id: 'd_pull' });
    expect(byDate['2026-05-22']).toMatchObject({ status: 'projected', day_template_id: 'd_legs' });
    expect(byDate['2026-05-24']).toMatchObject({ status: 'rest' });
  });

  it('a real session wins over the projection on a future date', () => {
    const cells = projectCalendar(
      { id: 'p' },
      SCHED,
      [sess('2026-05-20', 'skipped')], // Wed would project d_pull
      '2026-05-18',
      '2026-05-20',
      today,
      LIVE,
    );
    const wed = cells.find((c) => c.date === '2026-05-20')!;
    expect(wed.status).toBe('skipped');
    expect(wed.real).toBe(true);
  });

  // ── 'discarded' carve-out — VANISHES (mirrored byte-for-byte in
  // CalendarProjection.swift `project`). A discarded session is treated as
  // if it never existed: the date falls through to past=omitted /
  // today+=schedule. NOT shown as a skip.
  it('a discarded session VANISHES — future date falls back to the schedule', () => {
    const cells = projectCalendar(
      { id: 'p' },
      SCHED,
      [sess('2026-05-20', 'discarded')], // Wed → would project d_pull
      '2026-05-18',
      '2026-05-20',
      today,
      LIVE,
    );
    const wed = cells.find((c) => c.date === '2026-05-20')!;
    expect(wed).toMatchObject({ status: 'projected', day_template_id: 'd_pull', real: false });
  });

  it('a discarded session today falls back to the schedule (projected, not session)', () => {
    const cells = projectCalendar(
      { id: 'p' },
      SCHED,
      [sess('2026-05-18', 'discarded', 'd_push')], // today = Mon → d_push
      '2026-05-18',
      '2026-05-18',
      today,
      LIVE,
    );
    expect(cells[0]).toMatchObject({ status: 'projected', day_template_id: 'd_push', real: false });
  });

  it('a discarded session in the past produces no cell (as if absent)', () => {
    const cells = projectCalendar(
      { id: 'p' },
      SCHED,
      [sess('2026-05-15', 'discarded')], // before today
      '2026-05-15',
      '2026-05-15',
      today,
      LIVE,
    );
    expect(cells).toEqual([]);
  });

  // ── past 'planned' carve-out — VANISHES (#48, mirrored byte-for-byte in
  // CalendarProjection.swift). A still-'planned' past session never
  // executed (logging flips it to in_progress/completed), so the past
  // calendar — which shows only what happened — must not render it as a
  // workout. ("Why does it show a workout yesterday with no content?")
  it('a past planned session VANISHES — produces no cell (#48)', () => {
    const cells = projectCalendar(
      { id: 'p' },
      SCHED,
      [sess('2026-05-15', 'planned', 'd_legs')], // before today, never done
      '2026-05-15',
      '2026-05-15',
      today,
      LIVE,
    );
    expect(cells).toEqual([]);
  });

  it('a past planned session with a null template also VANISHES (#48 repro)', () => {
    // The exact shape of the filed bug: planned, no template, no sets.
    const cells = projectCalendar(
      { id: 'p' },
      SCHED,
      [sess('2026-05-15', 'planned', null)],
      '2026-05-14',
      '2026-05-16',
      today,
      LIVE,
    );
    // 14th/15th/16th are all past → no fabricated cells, and the planned
    // 15th vanishes too.
    expect(cells).toEqual([]);
  });

  it('a FUTURE planned session still WINS over the schedule projection (#48 guard)', () => {
    const cells = projectCalendar(
      { id: 'p' },
      SCHED,
      [sess('2026-05-22', 'planned', 'd_legs')], // Fri, after today
      '2026-05-22',
      '2026-05-22',
      today,
      LIVE,
    );
    expect(cells[0]).toMatchObject({ status: 'planned', real: true, day_template_id: 'd_legs' });
  });

  it('a past completed session is still shown (only planned vanishes)', () => {
    const cells = projectCalendar(
      { id: 'p' },
      SCHED,
      [sess('2026-05-15', 'completed', 'd_legs')],
      '2026-05-15',
      '2026-05-15',
      today,
      LIVE,
    );
    expect(cells[0]).toMatchObject({ status: 'completed', real: true });
  });

  it('today with a real in_progress session uses the real status', () => {
    const cells = projectCalendar(
      { id: 'p' },
      SCHED,
      [sess('2026-05-18', 'in_progress', 'd_push')],
      '2026-05-18',
      '2026-05-18',
      today,
      LIVE,
    );
    expect(cells[0]).toMatchObject({ status: 'in_progress', real: true });
  });

  it('null/absent weekday entry → rest', () => {
    const cells = projectCalendar(
      { id: 'p' },
      SCHED,
      [],
      '2026-05-19', // Tue = null
      '2026-05-19',
      today,
      LIVE,
    );
    expect(cells[0]).toMatchObject({ status: 'rest', day_template_id: null, real: false });
  });

  it('dangling schedule id (day deleted) degrades to rest', () => {
    const cells = projectCalendar(
      { id: 'p' },
      SCHED,
      [],
      '2026-05-18', // Mon → d_push, but d_push not in live set
      '2026-05-18',
      today,
      ['d_pull', 'd_legs'], // d_push removed
    );
    expect(cells[0]).toMatchObject({ status: 'rest', day_template_id: null });
  });

  it('clamps the range span to 90 days', () => {
    const cells = projectCalendar(
      { id: 'p' },
      SCHED,
      [],
      '2026-01-01',
      '2026-12-31', // ~364 days
      '2026-01-01',
      LIVE,
    );
    // span clamped: 90 cells (indices 0..89 inclusive)
    expect(cells).toHaveLength(90);
    expect(cells[0]!.date).toBe('2026-01-01');
    expect(cells[89]!.date).toBe('2026-03-31');
  });

  it('inverted range yields no cells', () => {
    expect(projectCalendar({ id: 'p' }, SCHED, [], '2026-05-20', '2026-05-18', today, LIVE)).toEqual(
      [],
    );
  });
});

describe('migration 0005 + schedule round-trip via real D1', () => {
  async function freshPlan(name: string): Promise<string> {
    const userRow = await env.DB.prepare(
      "SELECT id FROM users ORDER BY created_at LIMIT 1",
    ).first<{ id: string }>();
    let userId = userRow?.id;
    if (!userId) {
      userId = crypto.randomUUID();
      await env.DB.prepare(
        'INSERT INTO users (id,apple_sub,email,display_name,created_at) VALUES (?1,?2,?3,?4,?5)',
      )
        .bind(userId, `sub-${userId}`, null, 'Owner', Date.now())
        .run();
    }
    const planId = crypto.randomUUID();
    await env.DB.prepare(
      "UPDATE plans SET status='archived' WHERE user_id=?1 AND status='active'",
    )
      .bind(userId)
      .run();
    // Insert a plan with NULL meta to prove the migration-equivalent
    // accessor backfills a well-formed empty schedule.
    await env.DB.prepare(
      "INSERT INTO plans (id,user_id,name,status,version,meta,created_at,updated_at) VALUES (?1,?2,?3,'active',1,NULL,?4,?4)",
    )
      .bind(planId, userId, name, Date.now())
      .run();
    return userId;
  }

  it('NULL meta parses to a well-formed empty schedule', async () => {
    await freshPlan('Sched Plan');
    const plan = await env.DB.prepare(
      "SELECT meta FROM plans WHERE status='active' LIMIT 1",
    ).first<{ meta: string | null }>();
    const meta = parsePlanMeta(plan!.meta);
    expect(meta.schedule.version).toBe(1);
    expect(meta.schedule.week).toEqual({
      mon: null, tue: null, wed: null, thu: null, fri: null, sat: null, sun: null,
    });
  });

  it('migration backfills the schedule key idempotently', async () => {
    const userId = await freshPlan('Idem Plan');
    const planId = (
      await env.DB.prepare("SELECT id FROM plans WHERE user_id=?1 AND status='active'")
        .bind(userId)
        .first<{ id: string }>()
    )!.id;
    // Apply the exact UPDATE the migration runs, twice; result is stable.
    const mig = `UPDATE plans SET meta = json_set(CASE WHEN meta IS NOT NULL AND json_valid(meta) THEN meta ELSE '{}' END, '$.schedule', json('{"version":1,"week":{"mon":null,"tue":null,"wed":null,"thu":null,"fri":null,"sat":null,"sun":null}}')) WHERE meta IS NULL OR NOT json_valid(meta) OR json_type(meta,'$.schedule') IS NULL`;
    await env.DB.prepare(mig).run();
    const a = await env.DB.prepare('SELECT meta FROM plans WHERE id=?1').bind(planId).first<{ meta: string }>();
    await env.DB.prepare(mig).run();
    const b = await env.DB.prepare('SELECT meta FROM plans WHERE id=?1').bind(planId).first<{ meta: string }>();
    expect(a!.meta).toEqual(b!.meta);
    expect(parsePlanMeta(a!.meta).schedule.week.mon).toBeNull();
  });

  it('setPlanSchedule resolves names, bumps version; one-offs do not', async () => {
    const userId = await freshPlan('Resolve Plan');
    const planId = (
      await env.DB.prepare("SELECT id FROM plans WHERE user_id=?1 AND status='active'").bind(userId).first<{ id: string }>()
    )!.id;
    const dPush = crypto.randomUUID();
    await env.DB.prepare(
      "INSERT INTO day_templates (id,plan_id,name,day_label,order_index,notes,created_at,updated_at) VALUES (?1,?2,'Push Day','A',0,NULL,0,0)",
    )
      .bind(dPush, planId)
      .run();

    const before = (
      await env.DB.prepare('SELECT version FROM plans WHERE id=?1').bind(planId).first<{ version: number }>()
    )!.version;

    // resolve by day name
    const r = await setPlanSchedule(env.DB, userId, { mon: 'Push Day' });
    expect('ok' in r && r.ok).toBe(true);
    if ('ok' in r) expect(r.schedule.week.mon).toBe(dPush);

    const afterVer = (
      await env.DB.prepare('SELECT version FROM plans WHERE id=?1').bind(planId).first<{ version: number }>()
    )!.version;
    expect(afterVer).toBe(before + 1);

    // stale expected_version → conflict, no write
    const stale = await setPlanSchedule(env.DB, userId, { mon: 'Push Day' }, before);
    expect(stale).toMatchObject({ conflict: true, current_version: afterVer });
    const stillVer = (
      await env.DB.prepare('SELECT version FROM plans WHERE id=?1').bind(planId).first<{ version: number }>()
    )!.version;
    expect(stillVer).toBe(afterVer);

    // unknown ref → error, no write
    const bad = await setPlanSchedule(env.DB, userId, { tue: 'Nonexistent Day' });
    expect(bad).toMatchObject({ error: 'unknown_day_ref', ref: 'Nonexistent Day' });
    expect(
      (await env.DB.prepare('SELECT version FROM plans WHERE id=?1').bind(planId).first<{ version: number }>())!.version,
    ).toBe(afterVer);

    // one-off planned/skip: NO version bump
    const verBeforeOneOff = afterVer;
    const planned = await setPlannedSession(env.DB, userId, '2026-05-25', 'Push Day');
    expect('ok' in planned && planned.ok).toBe(true);
    const skipped = await skipPlannedSession(env.DB, userId, '2026-05-26');
    expect('ok' in skipped && skipped.ok).toBe(true);
    expect(
      (await env.DB.prepare('SELECT version FROM plans WHERE id=?1').bind(planId).first<{ version: number }>())!.version,
    ).toBe(verBeforeOneOff);

    // projection picks up the schedule + one-off rows
    const cal = await getProjectedCalendar(env.DB, userId, '2026-05-25', '2026-05-27', '2026-05-20');
    const m = Object.fromEntries(cal.map((c) => [c.date, c]));
    expect(m['2026-05-25']).toMatchObject({ status: 'planned', real: true, day_template_id: dPush });
    expect(m['2026-05-26']).toMatchObject({ status: 'skipped', real: true });
  });

  it('deleteDayTemplate scrubs the schedule entry and bumps version once', async () => {
    const userId = await freshPlan('Delete Scrub Plan');
    const planId = (
      await env.DB.prepare("SELECT id FROM plans WHERE user_id=?1 AND status='active'")
        .bind(userId)
        .first<{ id: string }>()
    )!.id;
    const dLegs = crypto.randomUUID();
    await env.DB.prepare(
      "INSERT INTO day_templates (id,plan_id,name,day_label,order_index,notes,created_at,updated_at) VALUES (?1,?2,'Legs Day','L',0,NULL,0,0)",
    )
      .bind(dLegs, planId)
      .run();

    // Point Friday at the Legs day.
    const set = await setPlanSchedule(env.DB, userId, { fri: 'Legs Day' });
    expect('ok' in set && set.ok).toBe(true);
    if ('ok' in set) expect(set.schedule.week.fri).toBe(dLegs);

    const verBefore = (
      await env.DB.prepare('SELECT version FROM plans WHERE id=?1')
        .bind(planId)
        .first<{ version: number }>()
    )!.version;

    // Delete the day the schedule points at.
    const del = await deleteDayTemplate(env.DB, userId, dLegs);
    expect('ok' in del && del.ok).toBe(true);

    // Day row is gone.
    const stillThere = await env.DB.prepare('SELECT id FROM day_templates WHERE id=?1')
      .bind(dLegs)
      .first();
    expect(stillThere).toBeNull();

    // Schedule entry for that weekday is scrubbed to null.
    const planRow = await env.DB.prepare('SELECT meta, version FROM plans WHERE id=?1')
      .bind(planId)
      .first<{ meta: string; version: number }>();
    expect(parsePlanMeta(planRow!.meta).schedule.week.fri).toBeNull();

    // plans.version bumped exactly once by the delete.
    expect(planRow!.version).toBe(verBefore + 1);

    // Projection no longer projects that weekday (dangling → rest).
    // 2026-05-22 is a Friday.
    const cal = await getProjectedCalendar(env.DB, userId, '2026-05-22', '2026-05-22', '2026-05-20');
    expect(cal[0]).toMatchObject({ status: 'rest', day_template_id: null });
  });
});

// FIX 2 — skip_planned_session must NOT clobber a started/finished workout.
// Previously it unconditionally set the date's session to 'skipped',
// hiding logged sets and destroying visible history for a mis-dated skip.
// The fix rejects when the date already has an in_progress/completed
// session and leaves the row (and its sets) untouched.
describe('FIX 2: skipPlannedSession refuses to bury started/finished history', () => {
  async function planFor(name: string): Promise<{ userId: string; planId: string }> {
    const userId = crypto.randomUUID();
    await env.DB.prepare(
      'INSERT INTO users (id,apple_sub,email,display_name,created_at) VALUES (?1,?2,?3,?4,?5)',
    )
      .bind(userId, `sub-${userId}`, null, 'Owner', Date.now())
      .run();
    const planId = crypto.randomUUID();
    await env.DB.prepare(
      "INSERT INTO plans (id,user_id,name,status,version,meta,created_at,updated_at) VALUES (?1,?2,?3,'active',1,NULL,?4,?4)",
    )
      .bind(planId, userId, name, Date.now())
      .run();
    return { userId, planId };
  }
  async function insertSession(
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

  it('skipping a planned/empty date still produces a skipped row, no version bump', async () => {
    const { userId, planId } = await planFor('Skip Empty');
    const verBefore = (
      await env.DB.prepare('SELECT version FROM plans WHERE id=?1').bind(planId).first<{ version: number }>()
    )!.version;
    const r = await skipPlannedSession(env.DB, userId, '2026-06-01');
    expect('ok' in r && r.ok).toBe(true);
    const row = await env.DB
      .prepare('SELECT status FROM sessions WHERE user_id=?1 AND date=?2')
      .bind(userId, '2026-06-01')
      .first<{ status: string }>();
    expect(row!.status).toBe('skipped');
    expect(
      (await env.DB.prepare('SELECT version FROM plans WHERE id=?1').bind(planId).first<{ version: number }>())!.version,
    ).toBe(verBefore); // append-only: skip never bumps plan version
  });

  it('skipping a planned session overrides it to skipped (unchanged behavior)', async () => {
    const { userId, planId } = await planFor('Skip Planned');
    await insertSession(userId, planId, '2026-06-02', 'planned');
    const r = await skipPlannedSession(env.DB, userId, '2026-06-02');
    expect('ok' in r && r.ok).toBe(true);
    const row = await env.DB
      .prepare('SELECT status FROM sessions WHERE user_id=?1 AND date=?2')
      .bind(userId, '2026-06-02')
      .first<{ status: string }>();
    expect(row!.status).toBe('skipped');
  });

  it('REJECTS skipping a completed session and leaves the row + sets intact', async () => {
    const { userId, planId } = await planFor('Skip Completed');
    const sid = await insertSession(userId, planId, '2026-06-03', 'completed');
    // A logged set on that session — this is the history that must survive.
    const setId = crypto.randomUUID();
    await env.DB.prepare(
      "INSERT INTO set_logs (id,session_id,exercise_id,template_exercise_id,set_index,weight,reps,rpe,is_warmup,notes,logged_at,source,deleted_at) VALUES (?1,?2,'ex_back_squat',NULL,1,225,5,8,0,NULL,?3,'mcp',NULL)",
    )
      .bind(setId, sid, Date.now())
      .run();

    const r = await skipPlannedSession(env.DB, userId, '2026-06-03');
    expect(r).toEqual({ error: 'session_already_started', status: 'completed' });

    const row = await env.DB
      .prepare('SELECT status FROM sessions WHERE id=?1')
      .bind(sid)
      .first<{ status: string }>();
    expect(row!.status).toBe('completed'); // NOT skipped — history preserved
    const set = await env.DB
      .prepare('SELECT deleted_at FROM set_logs WHERE id=?1')
      .bind(setId)
      .first<{ deleted_at: number | null }>();
    expect(set!.deleted_at).toBeNull(); // logged set untouched
  });

  it('REJECTS skipping an in_progress session and leaves it untouched', async () => {
    const { userId, planId } = await planFor('Skip InProgress');
    const sid = await insertSession(userId, planId, '2026-06-04', 'in_progress');
    const r = await skipPlannedSession(env.DB, userId, '2026-06-04');
    expect(r).toEqual({ error: 'session_already_started', status: 'in_progress' });
    const row = await env.DB
      .prepare('SELECT status FROM sessions WHERE id=?1')
      .bind(sid)
      .first<{ status: string }>();
    expect(row!.status).toBe('in_progress');
  });
});

describe('detectConflicts — truth table (iOS mirrors this byte-for-byte)', () => {
  const evt = (
    id: string,
    date: string,
    over: Partial<ExternalEventRow> = {},
  ): Pick<ExternalEventRow, 'id' | 'date' | 'training_load' | 'planned_duration_sec'> => ({
    id,
    date,
    training_load: over.training_load ?? null,
    planned_duration_sec: over.planned_duration_sec ?? null,
  });

  it('same-day lift + ride → clash, lists every same-day event', () => {
    const out = detectConflicts(
      ['2026-05-20'],
      [evt('intervals:a', '2026-05-20'), evt('intervals:b', '2026-05-20')],
    );
    expect(out).toEqual([
      { date: '2026-05-20', conflicts: ['intervals:a', 'intervals:b'], severity: 'clash' },
    ]);
  });

  it('day-before a >=150 TSS ride → heavy-next-day', () => {
    const out = detectConflicts(
      ['2026-05-19'],
      [evt('intervals:big', '2026-05-20', { training_load: 150 })],
    );
    expect(out).toEqual([
      { date: '2026-05-19', conflicts: ['intervals:big'], severity: 'heavy-next-day' },
    ]);
  });

  it('day-before a >=9000s ride → heavy-next-day (duration threshold)', () => {
    const out = detectConflicts(
      ['2026-05-19'],
      [evt('intervals:long', '2026-05-20', { planned_duration_sec: 9000 })],
    );
    expect(out).toEqual([
      { date: '2026-05-19', conflicts: ['intervals:long'], severity: 'heavy-next-day' },
    ]);
  });

  it('sub-threshold next-day ride is NOT flagged', () => {
    const out = detectConflicts(
      ['2026-05-19'],
      [evt('intervals:easy', '2026-05-20', { training_load: 149, planned_duration_sec: 8999 })],
    );
    expect(out).toEqual([]);
  });

  it('rest day + ride → no conflict (only lift dates are evaluated)', () => {
    // The lift-date set excludes rest days; an event on a non-lift date and
    // not adjacent-before any lift date yields nothing.
    const out = detectConflicts([], [evt('intervals:a', '2026-05-20', { training_load: 300 })]);
    expect(out).toEqual([]);
  });

  it('soft-deleted ride is ignored (caller passes only live events)', () => {
    // detectConflicts trusts its input: a soft-deleted row simply is not in
    // the events array, so it cannot produce a conflict.
    const out = detectConflicts(['2026-05-20'], []);
    expect(out).toEqual([]);
  });

  it('same-day takes priority over day-before for the same date', () => {
    const out = detectConflicts(
      ['2026-05-20'],
      [
        evt('intervals:today', '2026-05-20'),
        evt('intervals:tomorrowBig', '2026-05-21', { training_load: 200 }),
      ],
    );
    // Only the clash is emitted for 2026-05-20 (first match wins).
    expect(out).toEqual([
      { date: '2026-05-20', conflicts: ['intervals:today'], severity: 'clash' },
    ]);
  });

  it('output is deduped and sorted by date ascending', () => {
    const out = detectConflicts(
      ['2026-05-22', '2026-05-20', '2026-05-20'],
      [evt('intervals:x', '2026-05-20'), evt('intervals:y', '2026-05-22')],
    );
    expect(out.map((c) => c.date)).toEqual(['2026-05-20', '2026-05-22']);
  });
});

describe('getRideConflicts — cancelled (skipped) sessions produce no conflict', () => {
  // sessions has no soft-delete column; a cancelled day is status='skipped'.
  // The liftDates filter (projected|planned|in_progress|completed) excludes
  // 'skipped', so a same-day ride on a skipped session is NOT a conflict,
  // while a completed session on the same date IS.
  async function freshUserAndPlan(): Promise<{ userId: string; planId: string }> {
    const userId = crypto.randomUUID();
    await env.DB.prepare(
      'INSERT INTO users (id,apple_sub,email,display_name,created_at) VALUES (?1,?2,?3,?4,?5)',
    )
      .bind(userId, `sub-${userId}`, null, 'Rider', Date.now())
      .run();
    await env.DB.prepare(
      "UPDATE plans SET status='archived' WHERE user_id=?1 AND status='active'",
    )
      .bind(userId)
      .run();
    const planId = crypto.randomUUID();
    await env.DB.prepare(
      "INSERT INTO plans (id,user_id,name,status,version,meta,created_at,updated_at) VALUES (?1,?2,'Conflict Plan','active',1,NULL,?3,?3)",
    )
      .bind(planId, userId, Date.now())
      .run();
    return { userId, planId };
  }

  const insertSession = (
    userId: string,
    planId: string,
    date: string,
    status: string,
  ) =>
    env.DB.prepare(
      `INSERT INTO sessions
         (id,user_id,plan_id,day_template_id,date,status,started_at,completed_at,
          perceived_fatigue,notes,created_at,updated_at)
       VALUES (?1,?2,?3,NULL,?4,?5,NULL,NULL,NULL,NULL,?6,?6)`,
    )
      .bind(`sess-${date}-${status}`, userId, planId, date, status, Date.now())
      .run();

  const insertRide = (userId: string, id: string, date: string) =>
    env.DB.prepare(
      `INSERT INTO external_events
         (id,user_id,source,external_id,date,kind,title,description,
          planned_duration_sec,training_load,intensity,raw,synced_at,deleted_at)
       VALUES (?1,?2,'intervals',?3,?4,'ride','Ride',NULL,7200,120,0.7,'{}',?5,NULL)`,
    )
      .bind(id, userId, id.replace('intervals:', ''), date, Date.now())
      .run();

  it('skipped session + same-day ride → NO conflict; completed → clash', async () => {
    const { userId, planId } = await freshUserAndPlan();
    // 2026-06-10 skipped, 2026-06-12 completed; rides on both days.
    await insertSession(userId, planId, '2026-06-10', 'skipped');
    await insertSession(userId, planId, '2026-06-12', 'completed');
    await insertRide(userId, 'intervals:r-skip', '2026-06-10');
    await insertRide(userId, 'intervals:r-done', '2026-06-12');

    const conflicts = await getRideConflicts(
      env.DB,
      userId,
      '2026-06-09',
      '2026-06-13',
      '2026-06-09',
    );
    const dates = conflicts.map((c) => c.date);
    expect(dates).not.toContain('2026-06-10'); // skipped → ignored
    const done = conflicts.find((c) => c.date === '2026-06-12');
    expect(done).toBeTruthy();
    expect(done!.severity).toBe('clash');
    expect(done!.conflicts).toContain('intervals:r-done');
  });

  it('soft-deleted ride is excluded from getRideConflicts', async () => {
    const { userId, planId } = await freshUserAndPlan();
    await insertSession(userId, planId, '2026-06-20', 'completed');
    await insertRide(userId, 'intervals:r-del', '2026-06-20');
    await env.DB.prepare(
      "UPDATE external_events SET deleted_at=?1 WHERE id='intervals:r-del'",
    )
      .bind(Date.now())
      .run();
    const conflicts = await getRideConflicts(
      env.DB,
      userId,
      '2026-06-19',
      '2026-06-21',
      '2026-06-19',
    );
    expect(conflicts.map((c) => c.date)).not.toContain('2026-06-20');
  });
});
