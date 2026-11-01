import { describe, expect, it } from 'vitest';
import type { StateResponse } from '../src/api';
import {
  calendarInputs,
  describeRunSteps,
  describeSlot,
  localToday,
  monthWeeks,
  orderedSlots,
  prefersMiles,
  projectRange,
  shiftMonth,
  type Slot,
  type Workout,
} from '../src/model';

function slot(overrides: Partial<Slot>): Slot {
  return {
    id: 's1', workout_id: 'w1', exercise_id: 'ex_squat', order_index: 0,
    target_sets: 3, target_reps: 5, target_reps_max: null, target_rpe: null,
    rest_seconds: 120, target_weight: 225, target_weight_unit: 'lb', target_duration_s: null,
    progression: null, run_steps: null, cues: null, is_warmup: 0, created_at: 0, updated_at: 0,
    exercise_name: 'Back Squat', exercise_unit: 'lb', exercise_muscle: 'legs', exercise_modality: 'strength',
    exercise_laterality: 'bilateral', exercise_load_mode: 'total', exercise_demo_slug: null,
    ...overrides,
  };
}

function workout(id: string, name: string, exercises: Slot[] = []): Workout {
  return { id, plan_id: 'p1', name, day_label: null, order_index: 0, notes: null, created_at: 0, updated_at: 0, archived_at: null, exercises };
}

function state(overrides: Partial<StateResponse> = {}): StateResponse {
  return {
    plan: {
      id: 'p1', user_id: 'u1', name: 'Plan', status: 'active', version: 3, meta: null, created_at: 0, updated_at: 0,
      schedule: { version: 1, week: { mon: 'w1', tue: null, wed: 'w2', thu: null, fri: 'w1', sat: null, sun: null } },
      trips: [],
      workouts: [workout('w1', 'Lower'), { ...workout('w2', 'Old'), archived_at: 1 }],
    },
    plan_version: 3,
    sessions: [],
    external_events: [],
    external_activities: [],
    ...overrides,
  };
}

describe('calendar', () => {
  it('builds Monday-first weeks that cover the whole month', () => {
    const weeks = monthWeeks('2026-11');
    expect(weeks[0]![0]).toBe('2026-10-26');
    expect(weeks.at(-1)![6]).toBe('2026-12-06');
    expect(weeks.flat()).toContain('2026-11-30');
    expect(weeks).toHaveLength(6);
    expect(monthWeeks('2027-02')).toHaveLength(4);
  });

  it('shifts months across years', () => {
    expect(shiftMonth('2026-12', 1)).toBe('2027-01');
    expect(shiftMonth('2026-01', -1)).toBe('2025-12');
  });

  it('uses the browser’s civil date for today', () => {
    expect(localToday(new Date(2026, 10, 1, 23, 59))).toBe('2026-11-01');
  });

  it('projects with the Worker’s own rules: routine, archived workouts, real sessions and trips', () => {
    const inputs = calendarInputs(state({
      sessions: [{
        id: 'sess', user_id: 'u1', plan_id: 'p1', workout_id: 'w1', date: '2026-10-30', status: 'completed',
        started_at: 1, completed_at: 2, perceived_fatigue: null, notes: null, created_at: 0, updated_at: 0,
        attempt: 1, write_protocol: 'attempt-v1',
      }],
      external_events: [{
        id: 'intervals:e1', user_id: 'u1', source: 'intervals', external_id: 'e1', date: '2026-11-03', kind: 'ride',
        title: 'Endurance ride', description: null, planned_duration_sec: 3600, training_load: 50, intensity: null,
        raw: null, synced_at: 0, deleted_at: null,
      }, {
        id: 'intervals:e2', user_id: 'u1', source: 'intervals', external_id: 'e2', date: '2026-11-04', kind: 'run',
        title: 'Deleted', description: null, planned_duration_sec: 1800, training_load: 20, intensity: null,
        raw: null, synced_at: 0, deleted_at: 5,
      }],
    }))!;
    inputs.trips = [{ id: 't1', start: '2026-11-06', end: '2026-11-06', type: 'travel', can_train_light: false }];
    const cells = projectRange(inputs, '2026-10-26', '2026-11-08', '2026-11-01');

    expect(cells.get('2026-10-30')).toMatchObject({ status: 'completed', workout_id: 'w1', real: true });
    expect(cells.has('2026-10-27')).toBe(false); // no invented past days
    expect(cells.get('2026-11-02')).toMatchObject({ status: 'projected', workout_id: 'w1' }); // Monday
    expect(cells.get('2026-11-03')!.items.map((i) => i.title)).toEqual(['Endurance ride']);
    expect(cells.get('2026-11-04')).toMatchObject({ status: 'rest', workout_id: null, items: [] }); // archived w2, deleted event
    expect(cells.get('2026-11-06')).toMatchObject({ status: 'unavailable' }); // trip over a Friday
  });

  it('has no calendar without a plan', () => {
    expect(calendarInputs(state({ plan: null }))).toBeNull();
  });
});

describe('workout details', () => {
  it('describes reps, ranges, loads, RPE, holds and sides', () => {
    expect(describeSlot(slot({}))).toBe('3 × 5 @ 225 lb · rest 2:00');
    expect(describeSlot(slot({ target_reps_max: 8, target_rpe: 8, target_weight: 100, target_weight_unit: 'kg' })))
      .toBe('3 × 5–8 @ 100 kg · RPE 8 · rest 2:00');
    expect(describeSlot(slot({ target_duration_s: 45, target_weight: null, rest_seconds: 0 }))).toBe('3 × 0:45');
    expect(describeSlot(slot({ exercise_laterality: 'unilateral', exercise_load_mode: 'per_hand', target_weight: 40 })))
      .toBe('3 × 5 each side @ 40 lb each hand · rest 2:00');
  });

  it('orders slots and labels supersets', () => {
    const labelled = orderedSlots(workout('w', 'W', [
      slot({ id: 'b', order_index: 1, group_id: 'g' }),
      slot({ id: 'a', order_index: 0, group_id: 'g' }),
      slot({ id: 'c', order_index: 2 }),
    ]));
    expect(labelled.map((s) => [s.id, s.group_label])).toEqual([['a', 'A1'], ['b', 'A2'], ['c', undefined]]);
  });

  it('describes planned run steps in miles or kilometres', () => {
    const raw = JSON.stringify([
      { kind: 'warmup', duration_s: 600 },
      { repeat: 4, steps: [
        { kind: 'work', distance_m: 800, target: { type: 'pace', fastest_s_per_km: 240, slowest_s_per_km: 250 } },
        { kind: 'recovery', duration_s: 120, target: { type: 'heart_rate', min_bpm: 120, max_bpm: 140 } },
      ] },
    ]);
    expect(describeRunSteps(raw, false)).toEqual([
      'Warm up 10:00',
      '4 × (Run 800 m at 4:00–4:10 /km, Recover 2:00 at 120–140 bpm)',
    ]);
    expect(describeRunSteps(raw, true)[1]).toBe('4 × (Run 0.5 mi at 6:26–6:42 /mi, Recover 2:00 at 120–140 bpm)');
    expect(describeRunSteps('not json', true)).toEqual([]);
    expect(describeRunSteps(null, true)).toEqual([]);
  });

  it('uses miles for US and UK locales only', () => {
    expect(prefersMiles('en-US')).toBe(true);
    expect(prefersMiles('en-GB')).toBe(true);
    expect(prefersMiles('fr-FR')).toBe(false);
    expect(prefersMiles('de')).toBe(false);
  });
});
