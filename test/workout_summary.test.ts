import { applyD1Migrations, env, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { getWorkoutSummary, patchSet, reviveDiscardedSession, discardSession } from '../src/db';
import { summarizeWorkout, type SummarySet, type SummaryExercise } from '../src/workoutSummary';
import bodyweight from '../ios/TresFortTests/Fixtures/BodyweightProgress.json';
import completionFixture from '../ios/TresFortTests/Fixtures/WorkoutCompletion.json';

beforeAll(async () => { await applyD1Migrations(env.DB, env.TEST_MIGRATIONS); });
const BASE = 'https://tres-fort.test';

async function fixture() {
  const auth = await SELF.fetch(`${BASE}/auth/dev`, { method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ secret: 'test-dev' }) });
  const { jwt } = await auth.json<{ jwt: string }>();
  const headers = { 'content-type': 'application/json', Authorization: `Bearer ${jwt}` };
  async function post(path: string, body: object) {
    const response = await SELF.fetch(`${BASE}/api/${path}`, { method: 'POST', headers, body: JSON.stringify(body) });
    expect(response.status).toBe(201);
    return response.json<any>();
  }
  const plan = await post('plan', { name: 'Runner summary' });
  const day = await post('workouts', { name: 'Bench day' });
  const slot = await post(`workouts/${day.id}/exercises`, { exercise: 'ex_bench', target_sets: 3,
    target_reps: 5, target_weight: 135, target_rpe: 8 });
  const session = await post('sessions', { date: '2038-09-08', workout_id: day.id });
  const created = await post(`sessions/${session.id}/sets`, { id: crypto.randomUUID(),
    exercise_id: 'ex_bench', template_exercise_id: slot.id, set_index: 1, weight: 135, reps: 4,
    rpe: 9, expected_attempt: 0 });
  const owner = await env.DB.prepare('SELECT user_id FROM plans WHERE id=?1').bind(plan.id).first<{user_id: string}>();
  return { post, headers, plan, day, slot, session, set: created.set, userId: owner!.user_id };
}

async function complete(headers: Record<string, string>, id: string) {
  const response = await SELF.fetch(`${BASE}/api/sessions/${id}?expected_attempt=0`, {
    method: 'PATCH', headers, body: JSON.stringify({ status: 'completed' }),
  });
  expect(response.status).toBe(200);
  return response.json<any>();
}

describe('persisted completion summary', () => {
  it('captures starting targets atomically, then ignores later plan changes', async () => {
    const f = await fixture();
    const captured = await env.DB.prepare('SELECT runner_targets FROM sessions WHERE id=?1')
      .bind(f.session.id).first<{runner_targets: string}>();
    expect(JSON.parse(captured!.runner_targets)).toMatchObject({ version: 1,
      slots: [expect.objectContaining({ slot_id: f.slot.id, sets: 3, reps: 5, weight: 135, rpe: 8 })] });
    await env.DB.prepare('UPDATE template_exercises SET target_sets=1,target_reps=4,target_weight=185 WHERE id=?1').bind(f.slot.id).run();
    const finished = await complete(f.headers, f.session.id);
    expect(finished.summary).toMatchObject({ final: true, working_sets: 1, total_reps: 4,
      external_load_volume: 540, targets_available: true,
      targets: [{ sets: 3, actual_sets: 1, missed_sets: 2, changed_sets: 1, below_target_sets: 1 }] });
    const response = await SELF.fetch(`${BASE}/api/sessions/${f.session.id}/summary`, { headers: f.headers });
    expect(await response.json()).toEqual(finished.summary);
    expect(await getWorkoutSummary(env.DB, f.userId, f.session.id)).toEqual(finished.summary);
  });

  it('resolves an offline tap against its immutable plan version', async () => {
    const f = await fixture();
    const first = await env.DB.prepare('SELECT runner_targets FROM sessions WHERE id=?1')
      .bind(f.session.id).first<{ runner_targets: string }>();
    const version = JSON.parse(first!.runner_targets).plan_version;
    const later = await f.post('sessions', { date: '2038-09-09', workout_id: f.day.id });
    const edit = await SELF.fetch(`${BASE}/api/workouts/${f.day.id}/exercises/${f.slot.id}`, {
      method: 'PATCH', headers: f.headers, body: JSON.stringify({ target_weight: 185 }),
    });
    expect(edit.status).toBe(200);
    await f.post(`sessions/${later.id}/sets`, { id: crypto.randomUUID(), exercise_id: 'ex_bench',
      template_exercise_id: f.slot.id, set_index: 1, weight: 135, reps: 5, expected_attempt: 0,
      prescription: { plan_id: f.plan.id, day_id: f.day.id, version } });
    const done = await complete(f.headers, later.id);
    expect(done.summary.targets[0]).toMatchObject({ weight: 135, changed_sets: 0 });
  });

  it('does not substitute current targets when a tap snapshot is unavailable', async () => {
    const f = await fixture();
    const later = await f.post('sessions', { date: '2038-09-09', workout_id: f.day.id });
    await f.post(`sessions/${later.id}/sets`, { id: crypto.randomUUID(), exercise_id: 'ex_bench',
      template_exercise_id: f.slot.id, set_index: 1, weight: 135, reps: 5, expected_attempt: 0,
      prescription: { plan_id: f.plan.id, day_id: f.day.id, version: 9999 } });
    expect((await complete(f.headers, later.id)).summary.targets_available).toBe(false);
  });

  it('recomputes from final corrected/deleted records without un-completing the workout', async () => {
    const f = await fixture();
    await complete(f.headers, f.session.id);
    const changed = await patchSet(env.DB, f.userId, f.set.id, { reps: 5, rpe: 8 },
      { session_id: f.session.id, attempt: 0, updated_at: f.set.updated_at });
    let summary = await getWorkoutSummary(env.DB, f.userId, f.session.id);
    expect(summary).toMatchObject({ final: true, total_reps: 5, external_load_volume: 675,
      targets: [{ changed_sets: 0, below_target_sets: 0, missed_sets: 2 }] });
    await patchSet(env.DB, f.userId, f.set.id, { deleted: true },
      { session_id: f.session.id, attempt: 0, updated_at: changed!.updated_at });
    summary = await getWorkoutSummary(env.DB, f.userId, f.session.id);
    expect(summary).toMatchObject({ final: true, working_sets: 0, external_load_volume: null,
      targets: [{ missed_sets: 3 }] });
  });

  it('leaves old targets unavailable and clears them on explicit restart', async () => {
    const f = await fixture();
    await env.DB.prepare('UPDATE sessions SET runner_targets=NULL WHERE id=?1').bind(f.session.id).run();
    const old = await complete(f.headers, f.session.id);
    expect(old.summary.targets_available).toBe(false);
    await discardSession(env.DB, f.userId, f.session.id, 0);
    const revived = await reviveDiscardedSession(env.DB, f.userId, f.session.id, 0, f.day.id);
    expect(revived).toMatchObject({ attempt: 1, runner_targets: null });
    expect(await getWorkoutSummary(env.DB, 'different-owner', f.session.id)).toBeNull();
  });

  it('reports detached slot attribution as unavailable rather than missed work', async () => {
    const f = await fixture();
    await complete(f.headers, f.session.id);
    await env.DB.prepare('UPDATE set_logs SET template_exercise_id=NULL WHERE id=?1').bind(f.set.id).run();
    expect((await getWorkoutSummary(env.DB, f.userId, f.session.id))?.targets[0]?.comparison_available).toBe(false);
  });
});

const exercise: SummaryExercise = { id: 'pull', name: 'Pull-up', modality: 'bw', unit: 'lb', laterality: 'bilateral', load_mode: 'total' };
const row = (id: string, weight: number, reps: number, timed = false): SummarySet => ({ id, exercise_id: 'pull', weight, reps,
  duration_s: timed ? reps : null, is_timed: timed ? 1 : 0, template_exercise_id: 'pull-slot', is_warmup: 0, deleted_at: null, rpe: null });
const session = { id: 'today', date: '2038-09-08', attempt: 0, status: 'completed' };

describe('completion records reuse comparable cohorts', () => {
  it('does not mix assistance, strict bodyweight, added load or rep/hold mode', () => {
    const result = summarizeWorkout(session, [row('assist', -30, 12), row('strict', 0, 8), row('added', 45, 5), row('hold', 0, 45, true)],
      [row('prior-assist', -30, 10), row('prior-strict', 0, 8), row('prior-hold', 0, 60, true)], [exercise], null);
    expect(result.records).toEqual([expect.objectContaining({ weight: -30, value: 12, previous: 10, metric: 'reps' })]);
    expect(result).toEqual(completionFixture);
    expect(result.external_load_volume).toBe(225);
    expect(result.total_reps).toBe(25);
    expect(summarizeWorkout({ ...session, status: 'in_progress' }, [row('new', -30, 12)], [row('old', -30, 10)], [exercise], null).records).toEqual([]);
  });
  it('ignores warmups and deletions and produces no PR for an initial baseline', () => {
    const result = summarizeWorkout(session, [row('base', 0, 8), { ...row('warm', 0, 50), is_warmup: 1 },
      { ...row('gone', 0, 60), deleted_at: 1 }], [], [exercise], null);
    expect(result.working_sets).toBe(1);
    expect(result.records).toEqual([]);
    expect(result.external_load_volume).toBeNull();
  });
  for (const fixture of bodyweight) {
    it(`matches the delivered ${fixture.name} metric and volume contract`, () => {
      const result = summarizeWorkout(session, fixture.sets, [], fixture.catalog, null);
      expect(result.external_load_volume).toBe(fixture.expected_tonnage);
      expect(result.cohorts).toHaveLength(fixture.expected_cohorts.length);
      for (const cohort of fixture.expected_cohorts) {
        expect(result.cohorts.find((row) => row.weight === cohort.weight
          && row.metric === (cohort.is_timed ? 'duration' : 'reps'))?.value)
          .toBe(cohort.best_duration_s ?? cohort.best_reps);
      }
    });
  }
});
