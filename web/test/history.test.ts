import { describe, expect, it } from 'vitest';
import {
  actorLabel,
  affectedText,
  changeViews,
  operationLabel,
  reasonText,
  shortDate,
  text,
  type HistoryItem,
  type PlanChange,
} from '../src/history';

const item = (overrides: Partial<HistoryItem>): HistoryItem => ({
  version: 7, actor: 'web', operation: 'update_exercise', reason: null, created_at: 0,
  summary: null, previous_version: 6, ...overrides,
});

const slot = (overrides: Record<string, unknown> = {}) => ({
  id: 'slot-1', exercise_id: 'ex_bench', exercise_name: 'Bench Press', order_index: 0,
  target_sets: 3, target_reps: 5, target_reps_max: null, target_rpe: null, rest_seconds: 120,
  target_weight: 135, target_weight_unit: 'lb', target_duration_s: null, progression: null,
  cues: null, is_warmup: 0, run_steps: null, group_id: null, group_rest_seconds: null,
  group_transition_seconds: null, ...overrides,
});

describe('a saved version', () => {
  it('says who changed the plan and what kind of change it was', () => {
    expect(actorLabel('mcp')).toBe('Coach');
    expect(actorLabel('ios')).toBe('You, in the app');
    expect(actorLabel('web')).toBe('You, on the web');
    expect(actorLabel('partner_sync')).toBe('Partner sync');
    expect(operationLabel('set_schedule')).toBe('Weekly routine changed');
    expect(operationLabel('restore_plan')).toBe('Earlier version restored');
    expect(operationLabel('mystery_tool')).toBe('Mystery tool');
    expect(reasonText(item({ reason: '  ' }))).toBeNull();
    expect(reasonText(item({ reason: 'Deload week' }))).toBe('Deload week');
  });

  it('names what changed in words, not storage names', () => {
    expect(affectedText(item({
      affected: ['Weekly schedule · thu', 'Workout · Upper A', 'Upper A · Bench Press · occurrence 2', 'Training context', 'Training plan name'],
    }))).toBe('Weekly routine · Thursday; Upper A; Upper A · Bench Press (2); Plan settings; and 1 more');
    expect(affectedText(item({
      affected: [],
      summary: { plan_fields: 0, schedule_days: 2, days_added: 0, days_removed: 0, days_changed: 0, exercises_added: 1, exercises_removed: 0, exercises_changed: 0 },
    }))).toBe('3 changes');
    expect(affectedText(item({}))).toBeNull();
  });
});

describe('a comparison with the plan now', () => {
  it('puts weekday changes together, in week order', () => {
    const changes: PlanChange[] = [
      { kind: 'schedule', path: 'Weekly schedule · sat', before: null, after: { day_id: 'w2', day_name: 'Tempo run', day_label: null } },
      { kind: 'schedule', path: 'Weekly schedule · mon', before: { day_id: 'w1', day_name: 'Upper A', day_label: 'A' }, after: null },
    ];
    expect(changeViews(changes, true)).toEqual([{
      key: 'routine', title: 'Weekly routine', status: 'changed',
      rows: [
        { label: 'Monday', then: 'Upper A', now: 'Rest' },
        { label: 'Saturday', then: 'Rest', now: 'Tempo run' },
      ],
    }]);
  });

  it('shows only the slot fields that differ, in the units they were saved in', () => {
    const [view] = changeViews([{
      kind: 'exercise', path: 'Upper A · Bench Press',
      before: slot(),
      after: slot({ target_reps: 6, target_reps_max: 8, target_weight: 60, target_weight_unit: 'kg', rest_seconds: 90, order_index: 2, cues: 'Pause' }),
    }], false);
    expect(view).toEqual({
      key: '0:Upper A · Bench Press', title: 'Upper A · Bench Press', status: 'changed',
      rows: [
        { label: 'Reps', then: '5', now: '6–8' },
        { label: 'Load', then: '135 lb', now: '60 kg' },
        { label: 'Rest', then: '2:00', now: '1:30' },
        { label: 'Cues', then: 'None', now: 'Pause' },
        { label: 'Position', then: '1', now: '3' },
      ],
    });
  });

  it('describes groups, run steps and progression in words', () => {
    const [view] = changeViews([{
      kind: 'exercise', path: 'Easy run · Outdoor Run',
      before: slot({ exercise_name: 'Outdoor Run', target_weight: null, group_id: 'g1', group_rest_seconds: 60, progression: '{"type":"linear","increment":5}' }),
      after: slot({
        exercise_name: 'Outdoor Run', target_weight: null, group_id: null, group_rest_seconds: null,
        progression: null, run_steps: JSON.stringify([{ kind: 'warmup', duration_s: 600 }]),
      }),
    }], false);
    expect(view!.rows).toEqual([
      { label: 'Progression', then: 'Type: linear, Increment: 5', now: 'None' },
      { label: 'Run steps', then: 'None', now: expect.stringContaining('10:00') },
      { label: 'Superset or circuit', then: 'In a group', now: 'Not grouped' },
      { label: 'Rest after each round', then: '1:00', now: 'None' },
    ]);
  });

  it('shows a whole workout or exercise that is new or gone', () => {
    const views = changeViews([
      { kind: 'day', path: 'Workout · Legs', before: null, after: { day_id: 'w3', day_name: 'Legs', day_label: null, exercises: [slot({ exercise_name: 'Squat' }), slot({ exercise_name: 'Lunge' })] } },
      { kind: 'exercise', path: 'Upper A · Bench Press', before: slot({ is_warmup: 1 }), after: null },
    ], false);
    expect(views[0]).toMatchObject({ title: 'Workout · Legs', status: 'added', rows: [{ label: 'Exercises', then: '—', now: 'Squat, Lunge' }] });
    expect(views[1]).toMatchObject({ status: 'removed', rows: [{ label: 'Prescription', then: '3 × 5 @ 135 lb · rest 2:00 · warm-up', now: '—' }] });
  });

  it('shows a renamed or archived workout and changed plan settings', () => {
    const views = changeViews([
      {
        kind: 'day', path: 'Workout · Upper B',
        before: { day_id: 'w1', day_name: 'Upper A', day_label: 'A', order_index: 0, notes: null, tags: '[]', archived_at: null },
        after: { day_id: 'w1', day_name: 'Upper B', day_label: 'A', order_index: 0, notes: null, tags: '["gym"]', archived_at: 5 },
      },
      {
        kind: 'plan', path: 'meta',
        before: { trips: [{ id: 't1', start: '2026-12-20', end: '2026-12-28', type: 'travel' }] },
        after: { race: { name: 'Turkey Trot', date: '2026-11-26', discipline: 'running', distance: '5k' } },
      },
    ], false);
    expect(views[0]!.rows).toEqual([
      { label: 'Name', then: 'Upper A', now: 'Upper B' },
      { label: 'Tags', then: 'None', now: 'gym' },
      { label: 'Status', then: 'Active', now: 'Archived' },
    ]);
    expect(views[1]).toMatchObject({ title: 'Plan settings', rows: [
      { label: 'Away dates', then: `${shortDate('2026-12-20')} to ${shortDate('2026-12-28')} (travel)`, now: 'None' },
      { label: 'Race goal', then: 'None', now: `Turkey Trot, 5k, ${shortDate('2026-11-26')}` },
    ] });
    expect(shortDate('2026-12-20')).toMatch(/20/);
    expect(shortDate('soon')).toBe('soon');
  });

  it('never shows storage IDs', () => {
    expect(text({ id: 'x', day_id: 'y', day_name: 'Upper A' })).toBe('Day name: Upper A');
    expect(text(null)).toBe('None');
    expect(text(true)).toBe('Yes');
  });
});
