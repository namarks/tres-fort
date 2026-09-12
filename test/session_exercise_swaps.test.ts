import { applyD1Migrations, env, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { issueAppJwt } from '../src/auth';
import { getPlanTree, updatePlanTree } from '../src/db';
import type { SessionRow } from '../src/types';
import { parseSessionExerciseSwaps } from '../src/sessionExerciseSwaps';

const BASE = 'https://tres-fort.test';
beforeAll(async () => applyD1Migrations(env.DB, env.TEST_MIGRATIONS));
async function fixture(timed = false) {
  const userID = crypto.randomUUID();
  await env.DB.prepare('INSERT INTO users(id,apple_sub,created_at) VALUES(?1,?2,?3)')
    .bind(userID, `sub-${userID}`, Date.now()).run();
  const built = await updatePlanTree(env.DB, userID, { workouts: [{ name: 'Strength', exercises: [
    { exercise: timed ? 'plank' : 'bench', target_sets: 3, target_reps: timed ? 30 : 8,
      target_duration_s: timed ? 30 : null, target_weight: 100, cues: 'Old cue' },
    { exercise: timed ? 'plank' : 'bench', target_sets: 3, target_reps: timed ? 30 : 8 },
  ] }] });
  if (!('plan' in built)) throw new Error('fixture_failed');
  const plan = built.plan, day = plan.workouts[0]!, slot = day.exercises[0]!;
  const headers = { authorization: `Bearer ${await issueAppJwt(userID, 'test-secret')}`, 'content-type': 'application/json' };
  const r = await SELF.fetch(`${BASE}/api/sessions`, { method: 'POST', headers,
    body: JSON.stringify({ date: '2026-09-12', workout_id: day.id }) });
  expect(r.status).toBe(201);
  return { userID, plan, day, slot, headers, session: await r.json<SessionRow>() };
}
async function swap(f: Awaited<ReturnType<typeof fixture>>, extra: Record<string, unknown> = {}, sessionID = f.session.id) {
  return SELF.fetch(`${BASE}/api/sessions/${sessionID}/exercises/${f.slot.id}/swap`, {
    method: 'POST', headers: f.headers, body: JSON.stringify({ to_exercise: 'push-up',
      expected_attempt: f.session.attempt, expected_version: f.plan.version, expected_revision: 0, ...extra }),
  });
}
async function log(f: Awaited<ReturnType<typeof fixture>>, exerciseID: string, index: number) {
  const r = await SELF.fetch(`${BASE}/api/sessions/${f.session.id}/sets`, { method: 'POST', headers: f.headers,
    body: JSON.stringify({ id: crypto.randomUUID(), exercise_id: exerciseID,
      template_exercise_id: f.slot.id, expected_attempt: f.session.attempt, set_index: index,
      weight: 0, reps: 8, is_timed: false, is_warmup: false }) });
  expect(r.status).toBe(201);
  return r.json<{ set: { exercise_id: string; template_exercise_id: string | null }; session: SessionRow }>();
}

describe('workout-only exercise swaps', () => {
  it('preserves routine and old sets, links the replacement and delayed original sets to only the selected slot', async () => {
    const f = await fixture();
    const original = await log(f, f.slot.exercise_id, 1);
    const before = await getPlanTree(env.DB, f.userID);
    const oldLog = await env.DB.prepare('SELECT * FROM set_logs WHERE session_id=?1').bind(f.session.id).all();
    const r = await swap(f);
    expect(r.status).toBe(200);
    const changed = await r.json<SessionRow>();
    const { entries, revision } = parseSessionExerciseSwaps(changed.exercise_swaps);
    expect(revision).toBe(1);
    expect(entries).toHaveLength(1);
    expect(entries[0]!.original).toEqual(f.slot);
    expect(entries[0]!.replacement).toMatchObject({ id: f.slot.id, exercise_id: 'ex_pushup', target_sets: 3,
      target_reps: 8, target_weight: null, cues: null });
    expect(await getPlanTree(env.DB, f.userID)).toEqual(before);
    expect((await env.DB.prepare('SELECT * FROM set_logs WHERE session_id=?1').bind(f.session.id).all()).results).toEqual(oldLog.results);
    expect((await log(f, 'ex_pushup', 2)).set).toMatchObject({ exercise_id: 'ex_pushup', template_exercise_id: f.slot.id });
    expect((await log(f, f.slot.exercise_id, 3)).set.template_exercise_id).toBe(f.slot.id);
    expect(original.set.exercise_id).toBe(f.slot.exercise_id);
    const state = await (await SELF.fetch(`${BASE}/api/state?since=${f.plan.version}`, { headers: f.headers })).json<{ plan: unknown; sessions: SessionRow[] }>();
    expect(state.plan).toBeNull();
    expect(parseSessionExerciseSwaps(state.sessions[0]!.exercise_swaps).revision).toBe(1);
    expect((await env.DB.prepare("SELECT COUNT(*) AS n FROM audit_log WHERE user_id=?1 AND tool='swap_session_exercise'").bind(f.userID).first())!.n).toBe(1);
  });

  it('rejects stale, malformed, foreign and incompatible edits without writing', async () => {
    const f = await fixture(), other = await fixture();
    expect((await swap(f, {}, other.session.id)).status).toBe(404);
    for (const extra of [{ expected_attempt: 50 }, { expected_version: 99 }, { expected_revision: 1 }]) {
      expect((await swap(f, extra)).status).toBe(409);
    }
    for (const extra of [{ to_exercise: 'plank' }, { expected_revision: -1 }, { extra: true }, { to_exercise: 'missing-exercise' }]) {
      expect((await swap(f, extra)).status).toBe(400);
    }
    expect((await env.DB.prepare('SELECT exercise_swaps FROM sessions WHERE id=?1').bind(f.session.id).first())!.exercise_swaps).toBeNull();
  });

  it('serializes two choices and lets the next revision retain all performed movements', async () => {
    const f = await fixture();
    const replies = await Promise.all([swap(f), swap(f, { to_exercise: 'squat' })]);
    expect(replies.map((r) => r.status).sort()).toEqual([200, 409]);
    const winner = await replies.find((r) => r.status === 200)!.json<SessionRow>();
    const first = parseSessionExerciseSwaps(winner.exercise_swaps).entries[0]!;
    expect((await swap(f)).status).toBe(409);
    const r = await swap(f, { expected_revision: 1, to_exercise: 'ring row' });
    expect(r.status).toBe(200);
    const next = parseSessionExerciseSwaps((await r.json<SessionRow>()).exercise_swaps);
    expect(next.revision).toBe(2);
    expect(next.entries[0]!.exercise_ids).toEqual(expect.arrayContaining([f.slot.exercise_id, first.replacement.exercise_id]));
  });

  it('keeps timed duration while clearing exercise-specific load and cues', async () => {
    const f = await fixture(true);
    const r = await swap(f, { to_exercise: 'L-sit' });
    expect(r.status).toBe(200);
    const swaps = parseSessionExerciseSwaps((await r.json<SessionRow>()).exercise_swaps);
    expect(swaps.entries[0]!.replacement).toMatchObject({ target_duration_s: 30, target_weight: null, cues: null });
  });

  it('does not carry a substitution into an explicitly restarted attempt', async () => {
    const f = await fixture();
    expect((await swap(f)).status).toBe(200);
    const discard = await SELF.fetch(`${BASE}/api/sessions/${f.session.id}/discard?expected_attempt=${f.session.attempt}`,
      { method: 'POST', headers: f.headers });
    expect(discard.status).toBe(200);
    expect((await swap(f, { expected_revision: 1 })).status).toBe(409);
    const restart = await SELF.fetch(`${BASE}/api/sessions`, { method: 'POST', headers: f.headers,
      body: JSON.stringify({ date: f.session.date, workout_id: f.day.id, restart_discarded: true,
        expected_attempt: f.session.attempt }) });
    expect(restart.status).toBe(201);
    const session = await restart.json<SessionRow>();
    expect(session.attempt).toBe(f.session.attempt + 1);
    expect(parseSessionExerciseSwaps(session.exercise_swaps, session.attempt).entries).toEqual([]);
    const next = await swap(f, { expected_attempt: session.attempt, to_exercise: 'squat' });
    expect(next.status).toBe(200);
    expect(parseSessionExerciseSwaps((await next.json<SessionRow>()).exercise_swaps).revision).toBe(1);
  });

  it('rolls back a swap when audit persistence fails', async () => {
    const f = await fixture();
    await env.DB.prepare("CREATE TRIGGER fail_session_swap BEFORE INSERT ON audit_log WHEN NEW.tool='swap_session_exercise' BEGIN SELECT RAISE(ABORT,'test_failure'); END").run();
    try { expect((await swap(f)).status).toBe(500); }
    finally { await env.DB.prepare('DROP TRIGGER fail_session_swap').run(); }
    expect((await env.DB.prepare('SELECT exercise_swaps FROM sessions WHERE id=?1').bind(f.session.id).first())!.exercise_swaps).toBeNull();
  });
});
