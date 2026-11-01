import { describe, expect, it } from 'vitest';
import type { StateActivity, StateResponse } from '../src/api';
import {
  activityLoad,
  activityLoads,
  calendarInputs,
  describeDistance,
  describeGroup,
  describeRunSteps,
  describeSlot,
  itemLoad,
  localToday,
  monthWeeks,
  orderedSlots,
  prefersMiles,
  projectRange,
  shiftMonth,
  slotBlocks,
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

  it('shows a superset’s or circuit’s own rests, not its members’ ordinary rests', () => {
    const blocks = slotBlocks(workout('w', 'W', [
      slot({ id: 'a', order_index: 0, group_id: 'g', target_sets: 4, rest_seconds: 120, group_rest_seconds: 60, group_transition_seconds: 0 }),
      slot({ id: 'b', order_index: 1, group_id: 'g', target_sets: 4, rest_seconds: 120, group_rest_seconds: 60, group_transition_seconds: 0 }),
      slot({ id: 'c', order_index: 2 }),
      slot({ id: 'd', order_index: 3, group_id: 'h', group_rest_seconds: 90, group_transition_seconds: 15 }),
      slot({ id: 'e', order_index: 4, group_id: 'h', group_rest_seconds: 90, group_transition_seconds: 15 }),
      slot({ id: 'f', order_index: 5, group_id: 'h', group_rest_seconds: 90, group_transition_seconds: 15 }),
    ]));
    expect(blocks.map((b) => [b.group?.title ?? null, b.members.map((m) => m.id)])).toEqual([
      ['Superset A', ['a', 'b']], [null, ['c']], ['Circuit B', ['d', 'e', 'f']],
    ]);
    expect(describeGroup(blocks[0]!.group!)).toBe('4 rounds · round rest 1:00');
    expect(describeGroup(blocks[2]!.group!)).toBe('3 rounds · round rest 1:30 · 0:15 between exercises');
    expect(describeSlot(blocks[0]!.members[0]!)).toBe('4 × 5 @ 225 lb');
    expect(describeSlot(blocks[1]!.members[0]!)).toBe('3 × 5 @ 225 lb · rest 2:00');
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
    expect(describeRunSteps(raw, true)[1]).toBe('4 × (Run 800 m at 6:26–6:42 /mi, Recover 2:00 at 120–140 bpm)');
    const single = JSON.stringify([{ kind: 'work', duration_s: 2400, target: { type: 'heart_rate', min_bpm: 140, max_bpm: 140 } }]);
    expect(describeRunSteps(single, false)).toEqual(['Run 40:00 at 140 bpm']);
    expect(describeRunSteps('not json', true)).toEqual([]);
    expect(describeRunSteps(null, true)).toEqual([]);
  });

  it('reads distances as the app does: meters under a kilometer, else up to two decimals', () => {
    expect(describeDistance(50, true)).toBe('50 m');
    expect(describeDistance(400, true)).toBe('400 m');
    expect(describeDistance(999.6, false)).toBe('1000 m');
    expect(describeDistance(1000, false)).toBe('1 km');
    expect(describeDistance(1250, false)).toBe('1.25 km');
    expect(describeDistance(1609.344, true)).toBe('1 mi');
    expect(describeDistance(5000, true)).toBe('3.11 mi');
    expect(describeDistance(1500, true)).toBe('0.93 mi');
  });

  it('keeps two decimals of a load', () => {
    expect(describeSlot(slot({ target_weight: 21.25, target_weight_unit: 'kg', rest_seconds: 0 }))).toBe('3 × 5 @ 21.25 kg');
  });

  it('uses miles for US and UK locales only', () => {
    expect(prefersMiles('en-US')).toBe(true);
    expect(prefersMiles('en-GB')).toBe(true);
    expect(prefersMiles('fr-FR')).toBe(false);
    expect(prefersMiles('de')).toBe(false);
  });
});

describe('activity load', () => {
  function activity(overrides: Partial<StateActivity>): StateActivity {
    return {
      id: 'intervals:a1', user_id: 'u1', source: 'intervals', external_id: 'a1', date: '2026-10-30', kind: 'run',
      name: 'Easy run', moving_time_sec: 2400, elapsed_time_sec: 2500, distance_m: 7000, average_watts: null,
      weighted_avg_watts: null, average_hr: 140, max_hr: 160, training_load: null, intensity: null, calories: null,
      elevation_gain_m: null, raw: null, synced_at: 0, deleted_at: null, canonical: 1, duplicate_of: null,
      ...overrides,
    } as StateActivity;
  }

  it('shows the effective load and its method, not the provider figure alone', () => {
    expect(activityLoad(activity({ training_load: null, effective_load: 42, load_method: 'heart_rate' })))
      .toEqual({ load: 42, method: 'heart_rate' });
    expect(activityLoad(activity({ training_load: 60, effective_load: 60, load_method: 'provider' })))
      .toEqual({ load: 60, method: 'provider' });
  });

  it('leaves missing data unknown', () => {
    expect(activityLoad(activity({ training_load: null, effective_load: null, load_method: null }))).toBeNull();
    expect(activityLoad(activity({ training_load: null }))).toBeNull();
  });

  it('falls back to the provider load from an API without effective loads', () => {
    expect(activityLoad(activity({ training_load: 55 }))).toEqual({ load: 55, method: 'provider' });
  });

  it('carries completed loads through the calendar and keeps planned events their own', () => {
    const s = state({
      external_activities: [activity({ id: 'intervals:a1', training_load: null, effective_load: 42, load_method: 'pace' })],
      external_events: [{
        id: 'intervals:e1', user_id: 'u1', source: 'intervals', external_id: 'e1', date: '2026-11-03', kind: 'ride',
        title: 'Endurance ride', description: null, planned_duration_sec: 3600, training_load: 50, intensity: null,
        raw: null, synced_at: 0, deleted_at: null,
      }],
    });
    const cells = projectRange(calendarInputs(s)!, '2026-10-30', '2026-11-03', '2026-11-01');
    const loads = activityLoads(s);
    expect(itemLoad(cells.get('2026-10-30')!.items[0]!, loads)).toEqual({ load: 42, method: 'pace' });
    expect(itemLoad(cells.get('2026-11-03')!.items[0]!, loads)).toEqual({ load: 50, method: null });
  });
});
