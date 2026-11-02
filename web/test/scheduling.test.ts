import { describe, expect, it } from 'vitest';
import type { Trip } from '../../src/types';
import type { StateResponse } from '../src/api';
import type { CalendarCell } from '../src/model';
import {
  attemptOn,
  awayDraft,
  awayFields,
  awayKindLabel,
  dateChangeBlocked,
  dateSession,
  hasWorkout,
  moveBlocked,
  splitTrips,
  weekWith,
} from '../src/scheduling';

type Session = StateResponse['sessions'][number];

function session(overrides: Partial<Session>): Session {
  return {
    id: 's1', user_id: 'u', plan_id: 'p', workout_id: 'w1', date: '2026-11-05', status: 'planned',
    started_at: null, completed_at: null, perceived_fatigue: null, notes: null, created_at: 1, updated_at: 1,
    attempt: 1, write_protocol: 'attempt-v1', ...overrides,
  };
}

function cell(overrides: Partial<CalendarCell>): CalendarCell {
  return { date: '2026-11-05', status: 'projected', workout_id: 'w1', real: false, items: [], ...overrides } as CalendarCell;
}

const today = '2026-11-03';

describe('the weekly routine', () => {
  it('sends the whole week with one day changed', () => {
    expect(weekWith({ mon: 'a', thu: 'b' }, 'sat', 'c')).toEqual({
      mon: 'a', tue: null, wed: null, thu: 'b', fri: null, sat: 'c', sun: null,
    });
    expect(weekWith({ mon: 'a' }, 'mon', null).mon).toBeNull();
  });
});

describe('single dates', () => {
  it('checks against the date’s first sessions row, as the Worker does', () => {
    const rows = [
      session({ id: 'b', created_at: 5, attempt: 3 }),
      session({ id: 'a', created_at: 2, attempt: 2 }),
      session({ id: 'c', date: '2026-11-06', attempt: 7 }),
    ];
    expect(dateSession(rows, '2026-11-05')?.id).toBe('a');
    expect(attemptOn(rows, '2026-11-05')).toBe(2);
    expect(attemptOn(rows, '2026-11-09')).toBe(0);
  });

  it('keeps past, started and blocked dates as they are', () => {
    expect(dateChangeBlocked('2026-11-02', today, cell({}), [])).toMatch(/Past dates/);
    expect(dateChangeBlocked('2026-11-05', today, cell({}), [session({ status: 'in_progress' })])).toMatch(/started/);
    expect(dateChangeBlocked('2026-11-05', today, cell({ status: 'unavailable' }), [])).toMatch(/away with no training/);
    expect(dateChangeBlocked('2026-11-05', today, cell({}), [session({ status: 'planned' })])).toBeNull();
    expect(dateChangeBlocked(today, today, cell({ status: 'light' }), [])).toBeNull();
  });

  it('moves a workout only to a later, empty, open date', () => {
    const base = { from: '2026-11-05', today, fromCell: cell({}), sessions: [] as Session[] };
    expect(moveBlocked({ ...base, to: '', toCell: undefined })).toBe('Choose a date.');
    expect(moveBlocked({ ...base, to: '2026-11-05', toCell: cell({}) })).toBe('Choose a different date.');
    expect(moveBlocked({ ...base, to: '2026-11-01', toCell: cell({ status: 'rest' }) })).toBe('Choose today or a later date.');
    expect(moveBlocked({ ...base, to: '2026-11-06', toCell: cell({ date: '2026-11-06' }) })).toMatch(/already has a workout/);
    expect(moveBlocked({ ...base, to: '2026-11-06', toCell: cell({ date: '2026-11-06', status: 'unavailable', workout_id: null }) })).toMatch(/away/);
    expect(moveBlocked({ ...base, to: '2026-11-06', toCell: cell({ date: '2026-11-06', status: 'rest', workout_id: null }) })).toBeNull();
  });

  it('counts a workout only where the date shows one', () => {
    expect(hasWorkout(cell({}))).toBe(true);
    expect(hasWorkout(cell({ status: 'planned' }))).toBe(true);
    expect(hasWorkout(cell({ status: 'rest', workout_id: null }))).toBe(false);
    expect(hasWorkout(cell({ status: 'skipped' }))).toBe(false);
    expect(hasWorkout(undefined)).toBe(false);
  });
});

describe('away dates', () => {
  const trip: Trip = { id: 't1', start: '2026-12-20', end: '2026-12-28', type: 'travel', can_train_light: true, note: 'Hotel gym' };

  it('sends every field for new dates and only changes for an edit', () => {
    expect(awayFields({ ...awayDraft(null, today), note: '  ' }, null)).toEqual({
      ok: true, fields: { start: today, end: today, type: 'travel', can_train_light: true },
    });
    const draft = awayDraft(trip, today);
    expect(awayFields(draft, trip)).toEqual({ ok: true, fields: {} });
    expect(awayFields({ ...draft, end: '2026-12-30', canTrain: false, note: '' }, trip)).toEqual({
      ok: true, fields: { end: '2026-12-30', can_train_light: false, note: '' },
    });
  });

  it('refuses a backwards range or a long note', () => {
    expect(awayFields({ ...awayDraft(null, today), end: '2026-11-01' }, null)).toEqual({ ok: false, error: 'The last day can’t be before the first day.' });
    expect(awayFields({ ...awayDraft(null, today), note: 'x'.repeat(501) }, null).ok).toBe(false);
    expect(awayFields({ ...awayDraft(null, today), start: '' }, null).ok).toBe(false);
  });

  it('lists upcoming dates soonest first and past ones latest first', () => {
    const trips: Trip[] = [
      { ...trip, id: 'later', start: '2027-01-10', end: '2027-01-12' },
      { ...trip, id: 'old', start: '2026-09-01', end: '2026-09-03' },
      trip,
      { ...trip, id: 'older', start: '2026-08-01', end: '2026-08-02' },
      { ...trip, id: 'now', start: '2026-11-01', end: today },
    ];
    const { upcoming, past } = splitTrips(trips, today);
    expect(upcoming.map((t) => t.id)).toEqual(['now', 't1', 'later']);
    expect(past.map((t) => t.id)).toEqual(['old', 'older']);
    expect(awayKindLabel({ ...trip, can_train_light: false })).toBe('Travel · no training');
  });
});
