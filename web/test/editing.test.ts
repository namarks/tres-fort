import { describe, expect, it } from 'vitest';
import {
  describeWriteError,
  draftFromSlot,
  factsOfSlot,
  moveDestination,
  newDraft,
  parseNumber,
  parseTags,
  prescriptionFields,
  searchCatalog,
  switchUnit,
  type CatalogExercise,
  type ExerciseFacts,
} from '../src/editing';
import type { Slot, Workout } from '../src/model';

function slot(overrides: Partial<Slot>): Slot {
  return {
    id: 's1', workout_id: 'w1', exercise_id: 'ex_squat', order_index: 0,
    target_sets: 3, target_reps: 5, target_reps_max: null, target_rpe: null,
    rest_seconds: 120, target_weight: 225, target_weight_unit: 'lb', target_duration_s: null,
    progression: null, run_steps: null, cues: null, is_warmup: 0, created_at: 0, updated_at: 0,
    exercise_name: 'Back Squat', exercise_unit: 'lb', exercise_muscle: 'legs', exercise_modality: 'barbell',
    exercise_laterality: 'bilateral', exercise_load_mode: 'total', exercise_demo_slug: null,
    ...overrides,
  };
}

function workout(exercises: Slot[]): Workout {
  return { id: 'w1', plan_id: 'p1', name: 'Lower', day_label: null, order_index: 0, notes: null, created_at: 0, updated_at: 0, archived_at: null, exercises };
}

const barbell: ExerciseFacts = { id: 'ex_bench', modality: 'barbell', laterality: 'bilateral', loadMode: 'total' };
const pullUp: ExerciseFacts = { id: 'ex_pullup', modality: 'bw', laterality: 'bilateral', loadMode: 'total' };
const plank: ExerciseFacts = { id: 'ex_plank', modality: 'timed', laterality: 'bilateral', loadMode: 'total' };
const row: ExerciseFacts = { id: 'ex_row_erg', modality: 'cardio', laterality: 'bilateral', loadMode: 'total' };

describe('adding a slot', () => {
  it('starts at the app defaults and sends only what was set', () => {
    const draft = newDraft(barbell, { warmup: false, unit: 'kg' });
    expect(prescriptionFields(draft, barbell)).toEqual({
      ok: true,
      fields: { is_warmup: false, target_sets: 3, target_reps: 8, rest_seconds: 120 },
    });
    const loaded = { ...draft, weight: '60', rpe: '8', useRange: true, repsMax: '10' };
    expect(prescriptionFields(loaded, barbell)).toEqual({
      ok: true,
      fields: {
        is_warmup: false, target_sets: 3, target_reps: 8, target_reps_max: 10, rest_seconds: 120,
        target_weight: 60, target_weight_unit: 'kg', target_rpe: 8,
      },
    });
  });

  it('stores a hold in seconds and a cardio effort as one timed set', () => {
    const hold = newDraft(plank, { warmup: false, unit: 'lb' });
    expect(hold.measure).toBe('hold');
    expect(prescriptionFields({ ...hold, holdSeconds: '60' }, plank)).toEqual({
      ok: true,
      fields: { is_warmup: false, target_sets: 3, target_reps: 60, target_duration_s: 60, rest_seconds: 120 },
    });
    const erg = newDraft(row, { warmup: true, unit: 'lb' });
    expect(prescriptionFields({ ...erg, minutes: '5', weight: '99' }, row)).toEqual({
      ok: true,
      fields: { is_warmup: true, target_sets: 1, target_reps: 1, target_duration_s: 300, rest_seconds: 120 },
    });
  });

  it('allows assistance only where load is relative to bodyweight', () => {
    expect(prescriptionFields({ ...newDraft(pullUp, { warmup: false, unit: 'lb' }), weight: '-20' }, pullUp).ok).toBe(true);
    expect(prescriptionFields({ ...newDraft(barbell, { warmup: false, unit: 'lb' }), weight: '-20' }, barbell))
      .toEqual({ ok: false, errors: ['Enter a weight of 0 or more.'] });
  });

  it('explains every invalid field', () => {
    const draft = { ...newDraft(barbell, { warmup: false, unit: 'lb' }), sets: '0', reps: '5', useRange: true, repsMax: '1', rest: '-5', weight: 'heavy', rpe: '11' };
    const result = prescriptionFields(draft, barbell);
    expect(result.ok).toBe(false);
    expect(!result.ok && result.errors).toEqual([
      'Sets must be a whole number from 1 to 99.',
      'Rest must be 0 to 3600 seconds.',
      'The top of the rep range must be at least the minimum.',
      'Enter the weight as a number.',
      'RPE must be from 1 to 10.',
    ]);
    expect(prescriptionFields({ ...draft, sets: '3', rest: '90', useRange: false, weight: '', rpe: '', reps: '2.5' }, barbell))
      .toEqual({ ok: false, errors: ['Reps must be a whole number from 1 to 1000.'] });
  });
});

describe('editing a slot', () => {
  it('sends only the fields that changed', () => {
    const current = slot({ target_reps_max: 8, target_rpe: 8 });
    const draft = draftFromSlot(current);
    expect(draft).toMatchObject({ sets: '3', reps: '5', useRange: true, repsMax: '8', weight: '225', unit: 'lb', rpe: '8' });
    expect(prescriptionFields(draft, factsOfSlot(current), current)).toEqual({ ok: true, fields: {} });
    expect(prescriptionFields({ ...draft, reps: '6', rpe: '' }, factsOfSlot(current), current))
      .toEqual({ ok: true, fields: { target_reps: 6, target_rpe: null } });
    expect(prescriptionFields({ ...draft, useRange: false }, factsOfSlot(current), current))
      .toEqual({ ok: true, fields: { target_reps_max: null } });
    expect(prescriptionFields({ ...draft, weight: '' }, factsOfSlot(current), current))
      .toEqual({ ok: true, fields: { target_weight: null } });
  });

  it('shows a saved load in the other unit without losing precision', () => {
    const current = slot({ target_weight: 100, target_weight_unit: 'kg' });
    const kg = draftFromSlot(current);
    const lb = switchUnit(kg, 'lb');
    expect(lb.weight).toBe('220.462');
    expect(switchUnit(lb, 'kg').weight).toBe('100');
    expect(prescriptionFields(switchUnit(lb, 'kg'), factsOfSlot(current), current)).toEqual({ ok: true, fields: {} });
    const saved = prescriptionFields(lb, factsOfSlot(current), current);
    expect(saved.ok && saved.fields.target_weight_unit).toBe('lb');
    expect(saved.ok && saved.fields.target_weight).toBeCloseTo(220.46226218, 8);
  });

  it('keeps a typed number when the unit changes', () => {
    const fresh = { ...newDraft(barbell, { warmup: false, unit: 'lb' }), weight: '60' };
    expect(switchUnit(fresh, 'kg')).toMatchObject({ weight: '60', unit: 'kg' });
    const current = slot({ target_weight: 100, target_weight_unit: 'kg' });
    const retyped = { ...draftFromSlot(current), weight: '110' };
    expect(switchUnit(retyped, 'lb')).toMatchObject({ weight: '110', unit: 'lb' });
    expect(switchUnit({ ...retyped, weight: 'oops' }, 'lb').weight).toBe('oops');
  });

  it('leaves sets and rest to the group for a superset member', () => {
    const member = slot({ group_id: 'g1', target_sets: 4, rest_seconds: 90 });
    const draft = { ...draftFromSlot(member), sets: '9', rest: '0', reps: '6' };
    expect(prescriptionFields(draft, factsOfSlot(member), member)).toEqual({ ok: true, fields: { target_reps: 6 } });
  });

  it('reads a legacy hold from target_reps and keeps a cardio slot’s reps', () => {
    const plankSlot = slot({ exercise_modality: 'timed', target_reps: 45, target_duration_s: null, target_weight: null });
    expect(draftFromSlot(plankSlot)).toMatchObject({ measure: 'hold', holdSeconds: '45', reps: '8' });
    expect(prescriptionFields(draftFromSlot(plankSlot), factsOfSlot(plankSlot), plankSlot))
      .toEqual({ ok: true, fields: { target_duration_s: 45 } });
    const erg = slot({ exercise_modality: 'cardio', target_sets: 1, target_reps: 1, target_duration_s: 600, target_weight: null });
    expect(draftFromSlot(erg)).toMatchObject({ measure: 'duration', minutes: '10' });
    expect(prescriptionFields({ ...draftFromSlot(erg), minutes: '12.5' }, factsOfSlot(erg), erg))
      .toEqual({ ok: true, fields: { target_duration_s: 750 } });
  });
});

describe('moving a slot', () => {
  const a = slot({ id: 'a', order_index: 0 });
  const b1 = slot({ id: 'b1', order_index: 1, group_id: 'g', group_label: 'B1' } as Partial<Slot>);
  const b2 = slot({ id: 'b2', order_index: 2, group_id: 'g', group_label: 'B2' } as Partial<Slot>);
  const c = slot({ id: 'c', order_index: 5 });
  const plan = workout([a, b1, b2, c]);

  it('moves past a whole superset, never into it', () => {
    expect(moveDestination(plan, 'a', 1)).toBe(2);
    expect(moveDestination(plan, 'c', -1)).toBe(1);
    expect(moveDestination(plan, 'a', -1)).toBeNull();
    expect(moveDestination(plan, 'c', 1)).toBeNull();
  });

  it('leaves group members to the group', () => {
    expect(moveDestination(plan, 'b1', 1)).toBeNull();
  });
});

describe('the exercise search', () => {
  const catalog: CatalogExercise[] = [
    { id: 'ex_bench', name: 'Bench Press', primary_muscle: 'chest', modality: 'barbell', unit: 'lb', laterality: 'bilateral', load_mode: 'total', demo_slug: null, aliases: '["bp","flat bench"]' },
    { id: 'ex_db_bench', name: 'Dumbbell Bench Press', primary_muscle: 'chest', modality: 'dumbbell', unit: 'lb', laterality: 'bilateral', load_mode: 'per_hand', demo_slug: null, aliases: null },
    { id: 'ex_squat', name: 'Back Squat', primary_muscle: 'quads', modality: 'barbell', unit: 'lb', laterality: 'bilateral', load_mode: 'total', demo_slug: null, aliases: '["squat"]' },
  ];

  it('ranks name starts, then word starts, then aliases and muscles', () => {
    expect(searchCatalog(catalog, 'bench').map((e) => e.id)).toEqual(['ex_bench', 'ex_db_bench']);
    expect(searchCatalog(catalog, 'bp').map((e) => e.id)).toEqual(['ex_bench']);
    expect(searchCatalog(catalog, 'squat').map((e) => e.id)).toEqual(['ex_squat']);
    expect(searchCatalog(catalog, 'quad').map((e) => e.id)).toEqual(['ex_squat']);
    expect(searchCatalog(catalog, '').map((e) => e.id)).toEqual(['ex_squat', 'ex_bench', 'ex_db_bench']);
  });
});

describe('small parsers', () => {
  it('reads numbers with a comma decimal and refuses words', () => {
    expect(parseNumber('22,5')).toBe(22.5);
    expect(parseNumber(' -20 ')).toBe(-20);
    expect(parseNumber('1e3')).toBeNull();
    expect(parseNumber('')).toBeNull();
  });

  it('normalizes tags as the Worker stores them', () => {
    expect(parseTags(' Travel, upper ,travel,, ')).toEqual({ ok: true, tags: ['travel', 'upper'] });
    expect(parseTags('x'.repeat(33))).toEqual({ ok: false, error: 'Keep each tag to 32 characters.' });
  });

  it('turns refusals into sentences', () => {
    expect(describeWriteError({ error: 'day_in_progress' })).toMatch(/in progress in the app/);
    expect(describeWriteError({ error: 'invalid_fields', fields: ['target_reps'] })).toBe('The plan didn’t accept: target_reps.');
    expect(describeWriteError(null)).toBe('That change didn’t save. Please try again.');
  });
});
