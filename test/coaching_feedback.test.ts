import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { issueAppJwt } from '../src/auth';
import { coachingSession, coachingPlanMeta } from '../src/coachingContext';
import contextFixture from '../ios/TresFortTests/Fixtures/CoachingContext.json';
import feedback from '../ios/TresFortTests/Fixtures/WorkoutFeedback.json';

const BASE = 'https://tres-fort.test';
let jwt: string;
let session: { id: string; date: string; attempt: number };
async function rest(path: string, method = 'GET', body?: unknown, token = jwt) {
  const response = await SELF.fetch(`${BASE}/api/${path}`, {
    method, headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  expect(response.ok).toBe(true);
  return response.json<any>();
}
async function rpc(method: string, params: unknown) {
  const r = await SELF.fetch(`${BASE}/mcp`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer test-mcp-token' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  });
  expect(r.status).toBe(200);
  return (await r.json<any>()).result;
}
async function tool(name: string, args = {}) {
  return JSON.parse((await rpc('tools/call', { name, arguments: args })).content[0].text);
}
function brief(text: string) { return JSON.parse(text.match(/```json\n([\s\S]*?)\n```/)![1]!); }

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
  const auth = await SELF.fetch(`${BASE}/auth/dev`, { method: 'POST',
    headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ secret: 'test-dev' }) });
  jwt = (await auth.json<any>()).jwt;
  await rest('plan', 'POST', { name: 'Feedback contract' });
  session = await rest('sessions', 'POST', { date: '2026-09-08' });
  await rest(`sessions/${session.id}/sets`, 'POST', { id: crypto.randomUUID(),
    exercise_id: 'ex_bench', set_index: 1, weight: 45, reps: 5 });
  // The same edited transcript and fatigue fixture is encoded by iOS tests.
  await rest(`sessions/${session.id}?expected_attempt=${session.attempt}`, 'PATCH', {
    notes: feedback.recognized, perceived_fatigue: feedback.perceived_fatigue,
  });
  await rest(`sessions/${session.id}?expected_attempt=${session.attempt}`, 'PATCH', {
    status: 'completed', notes: feedback.edited, perceived_fatigue: feedback.perceived_fatigue,
    expected_feedback: { notes: feedback.recognized, perceived_fatigue: feedback.perceived_fatigue },
  });
});

const expected = { notes: feedback.edited, perceived_fatigue: feedback.perceived_fatigue };
describe('private workout feedback from finish to coach', () => {
  it('returns the edited words and fatigue through state, session log, and exercise history', async () => {
    const state = await rest('state');
    expect(state.sessions.find((s: any) => s.id === session.id)).toMatchObject(expected);
    expect((await tool('get_session_log', { date: session.date }))[0].session).toMatchObject(expected);
    const history = await tool('get_history', { exercise: 'bench', range: '365d' });
    expect(history.by_session.find((s: any) => s.date === session.date)).toMatchObject(expected);
  });
  it('keeps feedback on the latest completed session in the resource and prompt', async () => {
    const resource = await rpc('resources/read', { uri: 'coach://state/current' });
    expect(brief(resource.contents[0].text).last_session).toMatchObject(expected);
    const prompt = await rpc('prompts/get', { name: 'coach_brief' });
    expect(prompt.messages.map((m: any) => m.content.text).join('\n')).toContain(feedback.edited);
  });
  it.each(['skipped', 'in_progress'])('keeps prior completed feedback when latest is %s', async (status) => {
    const latest = await rest('sessions', 'POST', { date: '2026-09-09' });
    if (status === 'skipped') await rest(`sessions/${latest.id}`, 'PATCH', { status });
    else await rest(`sessions/${latest.id}/sets`, 'POST', { id: crypto.randomUUID(),
      exercise_id: 'ex_bench', set_index: 1, weight: 45, reps: 5 });
    const resource = await rpc('resources/read', { uri: 'coach://state/current' });
    const result = brief(resource.contents[0].text);
    expect(result.last_session.status).toBe(status);
    expect(result.last_session.notes).toBeNull();
    expect(result.last_session.perceived_fatigue).toBeNull();
    expect(result.last_completed_session).toMatchObject({ date: session.date, ...expected });
    expect((await tool('get_today_workout')).last_completed_session).toMatchObject(expected);
  });
  it('projects the same persisted sessions and authored plan metadata delivered to iOS', async () => {
    const state = await rest('state');
    await env.DB.prepare('UPDATE plans SET meta = ? WHERE id = ?')
      .bind(JSON.stringify(contextFixture.meta), state.plan.id).run();
    // A future planned row must not displace recent training in the brief.
    await rest('sessions', 'POST', { date: '2099-01-01' });
    const current = await rest('state');
    const catalog = await rest('exercises');
    const result = brief((await rpc('resources/read', { uri: 'coach://state/current' })).contents[0].text);
    expect(result.active_plan).toMatchObject({ id: current.plan.id, version: current.plan.version,
      authored_context: coachingPlanMeta(current.plan.meta) });
    expect(result.active_plan.authored_context.stress_model).toEqual(contextFixture.meta.stress_model);
    expect(result.recent_sessions.some((s: any) => s.date === '2099-01-01')).toBe(false);
    const row = current.sessions.find((s: any) => s.id === session.id);
    const projection = coachingSession(row, current.sets, catalog);
    expect(result.recent_sessions.find((s: any) => s.id === row.id)).toEqual(projection);
    expect(result.last_completed_session).toEqual(projection);
    expect(result.scheduling_context.basis).toBe('scheduling_heuristic');
    expect(JSON.stringify(result)).not.toContain('readiness_score');
  });
  it('retries an identical finish without losing edited feedback', async () => {
    const response = await rest(`sessions/${session.id}?expected_attempt=${session.attempt}`, 'PATCH', {
      status: 'completed', ...expected,
    });
    expect(response).toMatchObject(expected);
    expect((await rest('state')).sessions.filter((s: any) => s.id === session.id)).toHaveLength(1);
  });
  it('does not replay a timed-out finish over newer feedback in the same attempt', async () => {
    await rest(`sessions/${session.id}`, 'PATCH', { notes: 'Newer coaching correction', perceived_fatigue: 4 });
    const response = await SELF.fetch(`${BASE}/api/sessions/${session.id}?expected_attempt=${session.attempt}`, {
      method: 'PATCH', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${jwt}` },
      body: JSON.stringify({ status: 'completed', ...expected,
        expected_feedback: { notes: feedback.recognized, perceived_fatigue: feedback.perceived_fatigue } }),
    });
    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({ error: 'session_feedback_conflict', current_session: {
      notes: 'Newer coaching correction', perceived_fatigue: 4,
    } });
    expect((await rest('state')).sessions.find((s: any) => s.id === session.id)).toMatchObject({
      notes: 'Newer coaching correction', perceived_fatigue: 4,
    });
  });
  it('allows explicit clearing while an absent feedback envelope leaves fields unchanged', async () => {
    const unchanged = await rest(`sessions/${session.id}`, 'PATCH', { status: 'completed' });
    expect(unchanged).toMatchObject(expected);
    const cleared = await rest(`sessions/${session.id}`, 'PATCH', { status: 'completed',
      notes: null, perceived_fatigue: null, expected_feedback: expected });
    expect(cleared).toMatchObject({ notes: null, perceived_fatigue: null });
  });
  it('accepts exact feedback retries and rejects a competing edit atomically', async () => {
    const send = (notes: string) => SELF.fetch(`${BASE}/api/sessions/${session.id}`, {
      method: 'PATCH', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${jwt}` },
      body: JSON.stringify({ status: 'completed', notes, perceived_fatigue: 5, expected_feedback: expected }),
    });
    const responses = await Promise.all([send('Choice A'), send('Choice B')]);
    expect(responses.map(r => r.status).sort()).toEqual([200, 409]);
    const winner = await responses.find(r => r.status === 200)!.json<any>();
    const retry = await send(winner.notes);
    expect(retry.status).toBe(200);
    expect(await retry.json()).toMatchObject({ notes: winner.notes, perceived_fatigue: 5 });
  });
  it('keeps feedback absent from group projections and other member state', async () => {
    const group = await rest('groups', 'POST', { name: 'Private feedback check' });
    const feed = await tool('get_group_feed', { group_id: group.id, range: '30d' });
    expect(feed.items.length).toBeGreaterThan(0);
    expect(JSON.stringify(feed)).not.toContain(feedback.edited);
    expect(JSON.stringify(feed)).not.toMatch(/perceived_fatigue|session_notes/);
    const id = crypto.randomUUID();
    await env.DB.prepare('INSERT INTO users (id,apple_sub,display_name,created_at) VALUES (?1,?2,?3,?4)')
      .bind(id, `synthetic-${id}`, 'Other member', Date.now()).run();
    const other = await rest('state', 'GET', undefined, await issueAppJwt(id, 'test-secret'));
    expect(other.sessions).toEqual([]);
    expect(JSON.stringify(other)).not.toContain(feedback.edited);
  });
});

describe('working-set trend semantics', () => {
  it('states effort coverage and primary attribution and never adds incompatible units', async () => {
    await rest(`sessions/${session.id}/sets`, 'POST', { id: crypto.randomUUID(),
      exercise_id: 'ex_bench', set_index: 2, weight: 50, reps: 5, rpe: 8 });
    // Same primary muscle, different unit; the set carries its own unit.
    // Catalog fixtures are test-only.
    await env.DB.prepare(`INSERT INTO exercises (id,name,primary_muscle,modality,unit,created_at)
      VALUES ('coaching-kg','Kilogram press','chest','barbell','kg',0)`).run();
    await rest(`sessions/${session.id}/sets`, 'POST', { id: crypto.randomUUID(),
      exercise_id: 'coaching-kg', set_index: 1, weight: 20, reps: 5, weight_unit: 'kg' });
    const result = await tool('get_volume_trend', { muscle_group: 'chest', range: 'all' });
    expect(result).toMatchObject({ muscle_attribution: 'primary_muscle_only', set_count_basis: 'logged_non_warmup_sets' });
    expect(result.buckets).toEqual([expect.objectContaining({ hard_sets: 3, logged_working_sets: 3,
      sets_with_effort: 1, tonnage: null, unit: null, external_load_volume: [
        { unit: 'kg', value: 100, contributing_sets: 1 },
        { unit: 'lb', value: 475, contributing_sets: 2 },
      ] })]);
  });
});
