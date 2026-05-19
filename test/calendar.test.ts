import { env, applyD1Migrations } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import {
  getProjectedCalendar,
  projectCalendar,
  setPlanSchedule,
  setPlannedSession,
  skipPlannedSession,
  weekdayOf,
} from '../src/db';
import type { SessionRow, WeeklySchedule } from '../src/types';
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
});
