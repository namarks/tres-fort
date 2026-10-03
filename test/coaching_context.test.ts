import { describe, it, expect } from 'vitest';
import { coachingSession, coachingPlanMeta } from '../src/coachingContext';
import { metricCohorts } from '../src/metrics';
import { detectConflicts } from '../src/calendarProjection';
import fixture from '../ios/TresFortTests/Fixtures/CoachingContext.json';
import progress from '../ios/TresFortTests/Fixtures/BodyweightProgress.json';

describe('coaching projection shared with Swift', () => {
  it('preserves each logged condition, optional effort and feedback with unit-separated volume', () => {
    expect(coachingSession(fixture.session, fixture.sets, fixture.catalog)).toMatchObject(fixture.expected_session);
    expect(coachingSession(fixture.session, fixture.sets, fixture.catalog).sets).toEqual(fixture.expected_session.sets);
  });
  it('reports each set in its own logged unit and never pools lb with kg volume', () => {
    const units = fixture.set_units;
    const result = coachingSession(units.session, units.sets, units.catalog);
    expect(result).toMatchObject(units.expected_session);
    expect(result.sets).toEqual(units.expected_session.sets);
    // 24 kg and 24 lb are separate comparable conditions; zero load keeps the catalog unit.
    expect(result.comparable_cohorts.filter(c => c.exercise_id === 'swing').map(c => [c.weight, c.unit]))
      .toEqual([[24, 'kg'], [24, 'lb'], [53, 'lb']]);
    expect(result.comparable_cohorts.filter(c => c.exercise_id === 'hold').map(c => [c.weight, c.unit]))
      .toEqual([[0, 'lb'], [10, 'kg']]);
  });
  it('keys cohorts by the set unit only when a row carries one', () => {
    const exercise = { modality: 'barbell', unit: 'lb', laterality: 'bilateral', load_mode: 'total' };
    const set = { exercise_id: 'press', weight: 24, reps: 5, duration_s: null, is_timed: 0 };
    const legacy = metricCohorts([set], exercise)[0]!;
    expect(legacy.key).toBe(JSON.stringify(['press', false, 24, 'lb', 'bilateral', 'total']));
    expect(legacy.unit).toBe('lb');
    expect(metricCohorts([set, { ...set, weight_unit: 'lb' }], exercise)).toHaveLength(1);
    const split = metricCohorts([set, { ...set, weight_unit: 'kg' }], exercise);
    expect(split.map(c => c.unit)).toEqual(['lb', 'kg']);
    expect(metricCohorts([{ ...set, weight: 0 }, { ...set, weight: 0, weight_unit: 'kg' }], exercise))
      .toHaveLength(1);
  });
  it('retains authored metadata without interpreting or dropping freeform settings', () => {
    expect(coachingPlanMeta(JSON.stringify(fixture.meta))).toEqual(fixture.meta);
    expect(Object.values(coachingPlanMeta('{invalid'))).toEqual([null, null, null, null, null]);
  });
  it.each(fixture.conflicts)('$name is a scheduling heuristic with honest missing inputs', c => {
    const result = detectConflicts([c.lift_date], c.events);
    expect(result[0]?.severity ?? 'none').toBe(c.expected);
  });
  it.each(progress)('reuses delivered $name comparable cohorts', f => {
    const result = coachingSession({ ...fixture.session, id: f.name }, f.sets, f.catalog);
    for (const c of f.expected_cohorts) expect(result.comparable_cohorts).toContainEqual(expect.objectContaining({
      weight: c.weight, is_timed: c.is_timed, best_reps: c.best_reps, best_duration_s: c.best_duration_s,
    }));
  });
});
