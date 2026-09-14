import { describe, it, expect } from 'vitest';
import { coachingSession, coachingPlanMeta } from '../src/coachingContext';
import { detectConflicts } from '../src/calendarProjection';
import fixture from '../ios/TresFortTests/Fixtures/CoachingContext.json';
import progress from '../ios/TresFortTests/Fixtures/BodyweightProgress.json';

describe('coaching projection shared with Swift', () => {
  it('preserves each logged condition, optional effort and feedback with unit-separated volume', () => {
    expect(coachingSession(fixture.session, fixture.sets, fixture.catalog)).toMatchObject(fixture.expected_session);
    expect(coachingSession(fixture.session, fixture.sets, fixture.catalog).sets).toEqual(fixture.expected_session.sets);
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
