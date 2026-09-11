import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { moveCalendarWorkout, type CalendarMoveInput } from '../src/db';
import type { SessionRow } from '../src/types';

beforeAll(async () => { await applyD1Migrations(env.DB, env.TEST_MIGRATIONS); });

async function fixture() {
  const user = crypto.randomUUID(), plan = crypto.randomUUID(), workout = crypto.randomUUID();
  const meta = JSON.stringify({ schedule: { version: 1, week: { mon: workout } } });
  await env.DB.batch([
    env.DB.prepare('INSERT INTO users (id,apple_sub,display_name,created_at) VALUES (?1,?2,?3,0)')
      .bind(user, `synthetic-${user}`, 'Calendar test'),
    env.DB.prepare("INSERT INTO plans (id,user_id,name,status,version,meta,created_at,updated_at) VALUES (?1,?2,'Training','active',1,?3,0,0)")
      .bind(plan, user, meta),
    env.DB.prepare("INSERT INTO workouts (id,plan_id,name,order_index,created_at,updated_at) VALUES (?1,?2,'Gym',0,0,0)")
      .bind(workout, plan),
  ]);
  const input: CalendarMoveInput = { id: crypto.randomUUID(), from_date: '2037-01-05', to_date: '2037-01-06',
    today: '2037-01-05', workout_id: workout, expected_plan_id: plan, expected_version: 1,
    expected_from_attempt: 0, expected_to_attempt: 0 };
  const rows = async () => (await env.DB.prepare('SELECT * FROM sessions WHERE user_id=?1 ORDER BY date')
    .bind(user).all<SessionRow>()).results;
  return { user, plan, workout, meta, input, rows };
}

describe('atomic one-date workout moves', () => {
  it('moves a projected workout, advances both dates and acknowledges a lost response once', async () => {
    const f = await fixture();
    const result = await moveCalendarWorkout(env.DB, f.user, f.input);
    expect(result).toMatchObject({ ok: true, from: { date: f.input.from_date, status: 'skipped', attempt: 1 },
      to: { date: f.input.to_date, status: 'planned', workout_id: f.workout, attempt: 1 } });
    expect(await moveCalendarWorkout(env.DB, f.user, f.input)).toEqual(result);
    expect((await f.rows()).length).toBe(2);
    expect(await env.DB.prepare('SELECT version,meta FROM plans WHERE id=?1').bind(f.plan).first())
      .toEqual({ version: 1, meta: f.meta });
    expect((await env.DB.prepare('SELECT COUNT(*) AS n FROM audit_log WHERE user_id=?1').bind(f.user).first<{ n: number }>())?.n).toBe(1);
  });

  it('rejects an occupied or started destination without changing either date', async () => {
    for (const status of ['planned', 'in_progress', 'completed']) {
      const f = await fixture();
      await env.DB.prepare('INSERT INTO sessions (id,user_id,plan_id,workout_id,date,status,attempt,created_at,updated_at) VALUES (?1,?2,?3,?4,?5,?6,1,0,0)')
        .bind(crypto.randomUUID(), f.user, f.plan, f.workout, f.input.to_date, status).run();
      const before = await f.rows();
      expect(await moveCalendarWorkout(env.DB, f.user, { ...f.input, expected_to_attempt: 1 }))
        .toEqual({ error: 'calendar_move_conflict' });
      expect(await f.rows()).toEqual(before);
    }
  });

  it('lets only one competing destination win the same original workout', async () => {
    const f = await fixture();
    const results = await Promise.all([
      moveCalendarWorkout(env.DB, f.user, f.input),
      moveCalendarWorkout(env.DB, f.user, { ...f.input, id: crypto.randomUUID(), to_date: '2037-01-07' }),
    ]);
    expect(results.filter((result) => 'ok' in result)).toHaveLength(1);
    expect(results.filter((result) => 'error' in result)).toHaveLength(1);
    const rows = await f.rows();
    expect(rows).toHaveLength(2);
    expect(rows.filter((row) => row.workout_id === f.workout)).toHaveLength(1);
  });

  it('treats skipped rows with retained workout identities as rest in both directions', async () => {
    const f = await fixture();
    await env.DB.prepare('INSERT INTO sessions (id,user_id,plan_id,workout_id,date,status,attempt,created_at,updated_at) VALUES (?1,?2,?3,?4,?5,\'skipped\',1,0,0)')
      .bind(crypto.randomUUID(), f.user, f.plan, f.workout, f.input.to_date).run();
    const before = await f.rows();
    expect(await moveCalendarWorkout(env.DB, f.user, { ...f.input,
      from_date: f.input.to_date, to_date: '2037-01-07', expected_from_attempt: 1 }))
      .toEqual({ error: 'calendar_move_conflict' });
    expect(await f.rows()).toEqual(before);
    expect(await moveCalendarWorkout(env.DB, f.user, { ...f.input, expected_to_attempt: 1 }))
      .toMatchObject({ ok: true, to: { status: 'planned', workout_id: f.workout, attempt: 2 } });
  });

  it('rolls the source and receipt back if the destination write fails', async () => {
    const f = await fixture();
    await env.DB.exec("CREATE TRIGGER fail_calendar_destination BEFORE INSERT ON sessions WHEN NEW.date='2037-01-06' BEGIN SELECT RAISE(ABORT,'synthetic_destination_failure'); END");
    await expect(moveCalendarWorkout(env.DB, f.user, f.input)).rejects.toThrow('synthetic_destination_failure');
    expect(await f.rows()).toEqual([]);
    expect((await env.DB.prepare('SELECT COUNT(*) AS n FROM audit_log WHERE user_id=?1').bind(f.user).first<{ n: number }>())?.n).toBe(0);
    await env.DB.exec('DROP TRIGGER fail_calendar_destination');
    expect(await moveCalendarWorkout(env.DB, f.user, f.input)).toMatchObject({ ok: true });
  });

  it('preserves date notes and fatigue when moving the workout assignment', async () => {
    const f = await fixture();
    for (const [date, status, note, fatigue] of [
      [f.input.from_date, 'planned', 'Original date note', 4],
      [f.input.to_date, 'skipped', 'Destination date note', 2],
    ] as const) {
      await env.DB.prepare('INSERT INTO sessions (id,user_id,plan_id,workout_id,date,status,attempt,notes,perceived_fatigue,created_at,updated_at) VALUES (?1,?2,?3,?4,?5,?6,1,?7,?8,0,0)')
        .bind(crypto.randomUUID(), f.user, f.plan, f.workout, date, status, note, fatigue).run();
    }
    const input = { ...f.input, expected_from_attempt: 1, expected_to_attempt: 1 };
    const result = await moveCalendarWorkout(env.DB, f.user, input);
    expect(result).toMatchObject({ ok: true,
      from: { notes: 'Original date note', perceived_fatigue: 4 },
      to: { notes: 'Destination date note', perceived_fatigue: 2 } });
    expect((await f.rows()).map(({ notes, perceived_fatigue }) => ({ notes, perceived_fatigue })))
      .toEqual([{ notes: 'Original date note', perceived_fatigue: 4 },
        { notes: 'Destination date note', perceived_fatigue: 2 }]);
    expect(await moveCalendarWorkout(env.DB, f.user, input)).toEqual(result);
  });

  it('rejects stale plans, attempts, hard blackouts, past dates and reused keys with other input', async () => {
    const f = await fixture();
    expect(await moveCalendarWorkout(env.DB, f.user, { ...f.input, expected_version: 2 })).toEqual({ error: 'calendar_move_conflict' });
    expect(await moveCalendarWorkout(env.DB, f.user, { ...f.input, expected_to_attempt: 3 })).toEqual({ error: 'calendar_move_conflict' });
    expect(await moveCalendarWorkout(env.DB, f.user, { ...f.input, today: '2037-01-07' })).toEqual({ error: 'invalid_move' });
    expect(await moveCalendarWorkout(env.DB, f.user, { ...f.input, to_date: f.input.from_date })).toEqual({ error: 'invalid_move' });
    await env.DB.prepare("UPDATE plans SET meta=json_set(meta,'$.trips',json(?1)) WHERE id=?2")
      .bind(JSON.stringify([{ id: 'trip', type: 'travel', start: '2037-01-06', end: '2037-01-07', can_train_light: false }]), f.plan).run();
    expect(await moveCalendarWorkout(env.DB, f.user, f.input)).toEqual({ error: 'calendar_move_conflict' });
    await env.DB.prepare('UPDATE plans SET meta=?1 WHERE id=?2').bind(f.meta, f.plan).run();
    expect(await moveCalendarWorkout(env.DB, f.user, f.input)).toMatchObject({ ok: true });
    expect(await moveCalendarWorkout(env.DB, f.user, { ...f.input, to_date: '2037-01-07' })).toEqual({ error: 'idempotency_conflict' });
    expect(await moveCalendarWorkout(env.DB, 'another-user', f.input)).toEqual({ error: 'idempotency_conflict' });
  });

  it('validates API dates without a server exception and requires authentication', async () => {
    const auth = await SELF.fetch('https://test/auth/dev', { method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ secret: 'test-dev' }) });
    const { jwt } = await auth.json<{ jwt: string }>();
    const f = await fixture();
    const { from_date: _from, ...body } = f.input;
    const response = await SELF.fetch('https://test/api/calendar/2037-13-32/move', {
      method: 'POST', headers: { Authorization: `Bearer ${jwt}`, 'content-type': 'application/json' }, body: JSON.stringify(body),
    });
    expect(response.status).toBe(400);
    expect((await SELF.fetch('https://test/api/calendar/2037-01-05/move', { method: 'POST' })).status).toBe(401);
  });
});
