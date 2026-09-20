import { applyD1Migrations, env, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { ensureOwnerUser, getPlanTree, updatePlanTree } from '../src/db';
import { handleMcp } from '../src/mcp/server';
import type { PlanTree } from '../src/types';

const BASE = 'https://tres-fort.test';
let jwt: string;
let userId: string;
let plan: PlanTree;
let groupId: string;

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
  const auth = await SELF.fetch(`${BASE}/auth/dev`, { method: 'POST',
    headers: { 'content-type': 'application/json' }, body: JSON.stringify({ secret: 'test-dev' }) });
  jwt = (await auth.json<{ jwt: string }>()).jwt;
  userId = (await ensureOwnerUser(env.DB, undefined))!.id;
  const result = await updatePlanTree(env.DB, userId, {
    name: 'Superset fixture', workouts: [{ name: 'Strength', day_label: 'A', exercises: [
      { exercise: 'push-up', target_sets: 2, target_reps: 10, rest_seconds: 45, is_warmup: 1 },
      { exercise: 'squat', target_sets: 2, target_reps: 10, rest_seconds: 90, is_warmup: 1 },
      { exercise: 'bench', target_sets: 3, target_reps: 5, rest_seconds: 120 },
    ] }],
  });
  if (!('plan' in result)) throw new Error('fixture_failed');
  plan = result.plan;
  groupId = crypto.randomUUID();
});

async function api(path: string, method = 'GET', body?: unknown, capabilities?: string) {
  const response = await SELF.fetch(`${BASE}/api${path}`, { method,
    headers: { 'content-type': 'application/json', Authorization: `Bearer ${jwt}`,
      ...(capabilities === undefined ? {} : { 'X-TresFort-Capabilities': capabilities }) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
  return { status: response.status, body: await response.json<any>() };
}
async function mcp(name: string, args: Record<string, unknown> = {}, callerId = userId) {
  const result = await handleMcp({ jsonrpc: '2.0', id: 1, method: 'tools/call',
    params: { name, arguments: args } }, env, callerId) as any;
  expect(result.json.result.isError).not.toBe(true);
  return JSON.parse(result.json.result.content[0].text);
}
const day = () => plan.workouts[0]!;
const members = () => day().exercises.slice(0, 2).map((slot) => slot.id);
const grouping = () => ({ group_id: groupId, expected_version: plan.version,
  exercises: members(), round_rest: 30, transition_rest: 0 });
async function trail() {
  return env.DB.prepare(`SELECT
    (SELECT version FROM plans WHERE id=?1) AS version,
    (SELECT COUNT(*) FROM audit_log WHERE user_id=?2) AS audits,
    (SELECT COUNT(*) FROM notes WHERE user_id=?2) AS notes,
    (SELECT COUNT(*) FROM plan_snapshots WHERE user_id=?2) AS snapshots`)
    .bind(plan.id, userId).first();
}

describe('group authoring API and released-client projection', () => {
  it('authors the warm-up via MCP and renders A1/A2 with both rests in coach reads', async () => {
    const grouped = await mcp('group_exercises', { ...grouping(), day: 'A', exercises: ['push-up', 'squat'] });
    expect(grouped).toMatchObject({ ok: true, group_id: groupId, version: plan.version + 1 });
    const tree = await mcp('get_current_plan');
    expect(tree.workouts[0].exercises.slice(0, 2)).toMatchObject([
      { group_label: 'A1', group_id: groupId, is_warmup: 1, group_rest_seconds: 30, group_transition_seconds: 0 },
      { group_label: 'A2', group_id: groupId, is_warmup: 1, group_rest_seconds: 30, group_transition_seconds: 0 },
    ]);
    const today = await mcp('get_today_workout');
    expect(today.plan_workouts[0].exercises[1].group_label).toBe('A2');
    const brief = await handleMcp({ jsonrpc: '2.0', id: 2, method: 'resources/read',
      params: { uri: 'coach://state/current' } }, env, userId) as any;
    expect(brief.json.result.contents[0].text).toContain('"label": "A1"');
    expect(brief.json.result.contents[0].text).toContain('"round_rest": 30');
    expect(brief.json.result.contents[0].text).toContain('"transition_rest": 0');
  });

  it('projects both legacy plan reads without mutating stored ordinary rests', async () => {
    expect((await api(`/workouts/${day().id}/groups`, 'PUT', grouping())).status).toBe(200);
    for (const path of ['/state', '/plan/active']) {
      const response = await api(path);
      expect(response.status).toBe(200);
      expect(response.body).not.toHaveProperty('plan_groups_version');
      const view = path === '/state' ? response.body.plan : response.body;
      expect(view.workouts[0].exercises.map((slot: any) => slot.rest_seconds)).toEqual([30, 30, 120]);
      for (const slot of view.workouts[0].exercises) {
        expect(slot).not.toHaveProperty('group_id');
        expect(slot).not.toHaveProperty('group_rest_seconds');
        expect(slot).not.toHaveProperty('group_transition_seconds');
      }
    }
    const stored = await getPlanTree(env.DB, userId);
    expect(stored!.workouts[0]!.exercises.map((slot) => slot.rest_seconds)).toEqual([45, 90, 120]);
  });

  it.each([undefined, 'groups'])('projects a restored grouped plan for capability %s without changing stored rests', async (capability) => {
    const grouped = await api(`/workouts/${day().id}/groups`, 'PUT', grouping());
    await api(`/workouts/${day().id}/groups`, 'PUT', {
      group_id: groupId, exercises: [], expected_version: grouped.body.version,
    });
    const restored = await api(`/plan/history/${grouped.body.version}/restore`, 'POST', {
      expected_plan_id: plan.id, expected_version: grouped.body.version + 1,
    }, capability);
    expect(restored.status).toBe(200);
    expect(restored.body.plan.workouts[0].exercises.map((slot: any) => slot.rest_seconds))
      .toEqual(capability === 'groups' ? [45, 90, 120] : [30, 30, 120]);
    if (capability === 'groups') {
      expect(restored.body.plan.workouts[0].exercises[0]).toMatchObject({ group_id: groupId, group_rest_seconds: 30 });
    } else {
      expect(restored.body.plan.workouts[0].exercises[0]).not.toHaveProperty('group_id');
    }
    const stored = await getPlanTree(env.DB, userId);
    expect(stored!.workouts[0]!.exercises.map((slot) => slot.rest_seconds)).toEqual([45, 90, 120]);
  });

  it('honors groups among other comma-separated capabilities and preserves ungrouped slots', async () => {
    await api(`/workouts/${day().id}/groups`, 'PUT', grouping());
    for (const path of ['/state', '/plan/active']) {
      const response = await api(path, 'GET', undefined, 'slots, groups ,future');
      if (path === '/state') expect(response.body.plan_groups_version).toBe(1);
      const view = path === '/state' ? response.body.plan : response.body;
      expect(view.workouts[0].exercises.map((slot: any) => slot.rest_seconds)).toEqual([45, 90, 120]);
      expect(view.workouts[0].exercises[0]).toMatchObject({ group_id: groupId, group_rest_seconds: 30 });
      expect(view.workouts[0].exercises[2].group_id).toBeNull();
    }
    const delta = await api(`/state?since=${plan.version + 1}`, 'GET', undefined, 'groups');
    expect(delta.body.plan).toBeNull();
    expect(delta.body.plan_groups_version).toBe(1);
  });

  it('does not certify a state representation for unrelated or partial capability names', async () => {
    for (const capability of ['slots', 'groups-v2', 'no-groups', '']) {
      const response = await api('/state', 'GET', undefined, capability);
      expect(response.status).toBe(200);
      expect(response.body).not.toHaveProperty('plan_groups_version');
      expect(response.body.plan.workouts[0].exercises[0]).not.toHaveProperty('group_id');
    }
  });

  it('recognizes a REST acknowledged retry before stale rejection, without duplicate history', async () => {
    const body = grouping();
    const first = await api(`/workouts/${day().id}/groups`, 'PUT', body);
    expect(first.status).toBe(200);
    const before = await trail();
    const repeated = await api(`/workouts/${day().id}/groups`, 'PUT', body);
    expect(repeated.status).toBe(200);
    expect(repeated.body).toMatchObject({ ok: true, version: plan.version + 1 });
    expect(await trail()).toEqual(before);
    const changed = await api(`/workouts/${day().id}/groups`, 'PUT', { ...body, round_rest: 60 });
    expect(changed.status).toBe(409);
    expect(changed.body).toMatchObject({ conflict: true, current_version: plan.version + 1 });
    expect(await trail()).toEqual(before);
  });

  it('clears all members via the same REST endpoint and repeated clear keeps one history event', async () => {
    await api(`/workouts/${day().id}/groups`, 'PUT', grouping());
    const clear = { group_id: groupId, exercises: [], expected_version: plan.version + 1 };
    const result = await api(`/workouts/${day().id}/groups`, 'PUT', clear);
    expect(result.status).toBe(200);
    expect(result.body).toMatchObject({ ok: true, cleared: true, version: plan.version + 2 });
    const before = await trail();
    expect((await api(`/workouts/${day().id}/groups`, 'PUT', clear)).status).toBe(200);
    expect(await trail()).toEqual(before);
    const view = (await api('/plan/active')).body;
    expect(view.workouts[0].exercises.map((slot: any) => slot.rest_seconds)).toEqual([45, 90, 120]);
  });

  it('scopes REST clear to its day while replaying an acknowledged clear after day replacement', async () => {
    await api(`/workouts/${day().id}/groups`, 'PUT', grouping());
    const clear = { group_id: groupId, exercises: [], expected_version: plan.version + 1 };
    const before = await trail();
    expect((await api(`/workouts/${crypto.randomUUID()}/groups`, 'PUT', clear)).status).toBe(404);
    expect(await trail()).toEqual(before);
    const accepted = await api(`/workouts/${day().id}/groups`, 'PUT', clear);
    expect(accepted.status).toBe(200);
    await mcp('update_plan', { expected_version: accepted.body.version,
      workouts: [{ name: 'Replacement', exercises: [] }] });
    const after = await trail();
    const replay = await api(`/workouts/${day().id}/groups`, 'PUT', clear);
    expect(replay.status).toBe(200);
    expect(replay.body).toMatchObject({ ok: true, replayed: true, version: accepted.body.version });
    expect(await trail()).toEqual(after);
  });

  it('uses MCP atomic attribution exactly once for group and ungroup', async () => {
    const args = { ...grouping(), day: day().id };
    await mcp('group_exercises', args);
    const grouped = await trail();
    await mcp('group_exercises', args);
    expect(await trail()).toEqual(grouped);
    const result = await mcp('ungroup_exercises', { group_id: groupId, expected_version: plan.version + 1 });
    expect(result).toMatchObject({ cleared: true, version: plan.version + 2 });
    const audits = await env.DB.prepare("SELECT actor,tool FROM audit_log WHERE user_id=?1 AND tool IN ('group_exercises','ungroup_exercises')")
      .bind(userId).all();
    expect(audits.results).toEqual([{ actor: 'mcp', tool: 'group_exercises' }, { actor: 'mcp', tool: 'ungroup_exercises' }]);
  });

  it.each([
    ['expected_version', undefined], ['expected_version', '1'], ['round_rest', -1],
    ['round_rest', 1.5], ['transition_rest', false], ['target_sets', 0], ['group_id', 'invalid'],
  ])('rejects invalid REST %s without attribution', async (field, value) => {
    const before = await trail();
    const result = await api(`/workouts/${day().id}/groups`, 'PUT', { ...grouping(), [field]: value });
    expect(result.status).toBe(400);
    expect(result.body.error).toBe('invalid_fields');
    expect(await trail()).toEqual(before);
  });

  it('rejects group-column single-slot writes on both authoring clients', async () => {
    const before = await trail();
    const patch = { group_id: groupId, group_rest_seconds: 30, group_transition_seconds: 0 };
    const rest = await api(`/workouts/${day().id}/exercises/${members()[0]}`, 'PATCH', patch);
    expect(rest.status).toBe(400);
    expect(rest.body.error).toBe('unknown_fields');
    expect((await mcp('update_exercise', { template_exercise_id: members()[0], patch })).error).toBe('unknown_fields');
    const add = await api(`/workouts/${day().id}/exercises`, 'POST', { exercise: 'bench', target_sets: 2, target_reps: 5, ...patch });
    expect(add.status).toBe(400);
    expect(add.body.error).toBe('unknown_fields');
    expect((await mcp('add_exercise', { day: 'A', exercise: 'bench', target_sets: 2, target_reps: 5, ...patch })).error).toBe('unknown_fields');
    expect(await trail()).toEqual(before);
  });

  it('moves the whole group as one versioned block and keeps member rests intact', async () => {
    await api(`/workouts/${day().id}/groups`, 'PUT', grouping());
    const result = await api(`/workouts/${day().id}/groups`, 'PUT', {
      ...grouping(), expected_version: plan.version + 1, order_index: 1,
    });
    expect(result.status).toBe(200);
    const tree = await getPlanTree(env.DB, userId);
    expect(tree!.workouts[0]!.exercises.map((slot) => slot.id)).toEqual([day().exercises[2]!.id, ...members()]);
    expect(tree!.workouts[0]!.exercises.map((slot) => slot.rest_seconds)).toEqual([120, 45, 90]);
    expect(tree!.version).toBe(plan.version + 2);
  });

  it('returns an MCP receipt after a later tree rebuild without restoring old membership', async () => {
    const args = { ...grouping(), day: day().id };
    const accepted = await mcp('group_exercises', args);
    const replaced = await mcp('update_plan', { expected_version: accepted.version,
      workouts: [{ name: 'Replacement', exercises: [{ exercise: 'bench', target_sets: 3, target_reps: 5 }] }] });
    expect(replaced.plan.version).toBe(plan.version + 2);
    const before = await trail();
    expect(await mcp('group_exercises', args)).toMatchObject({ ok: true, version: accepted.version, replayed: true });
    expect(await trail()).toEqual(before);
    expect((await getPlanTree(env.DB, userId))!.workouts[0]!.name).toBe('Replacement');
  });

  it.each(['A', 'Strength'])('replays a name-based request for %s after IDs are rebuilt', async (dayReference) => {
    const args = { ...grouping(), day: dayReference, exercises: ['push-up', 'squat'] };
    const accepted = await mcp('group_exercises', args);
    const replaced = await mcp('update_plan', { expected_version: accepted.version,
      workouts: [{ name: 'Strength', day_label: 'A', exercises: [
        { exercise: 'push-up', target_sets: 4, target_reps: 12 },
        { exercise: 'squat', target_sets: 4, target_reps: 12 },
      ] }] });
    expect(replaced.plan.workouts[0].id).not.toBe(day().id);
    expect(replaced.plan.workouts[0].exercises.map((slot: any) => slot.id)).not.toEqual(members());
    const before = await trail();
    const beforeTree = await getPlanTree(env.DB, userId);
    const reorderedArguments = Object.fromEntries(Object.entries(args).reverse());
    expect(await mcp('group_exercises', reorderedArguments)).toEqual({ ...accepted, replayed: true });
    expect(await mcp('group_exercises', { ...args, round_rest: 40 }))
      .toEqual({ conflict: true, current_version: replaced.plan.version });
    expect(await mcp('group_exercises', { ...args, exercises: ['squat', 'push-up'] }))
      .toEqual({ conflict: true, current_version: replaced.plan.version });
    expect(await trail()).toEqual(before);
    expect(await getPlanTree(env.DB, userId)).toEqual(beforeTree);
  });

  it('replays names after their day is removed without bypassing argument or tenant validation', async () => {
    const args = { ...grouping(), day: 'A', exercises: ['push-up', 'squat'] };
    const accepted = await mcp('group_exercises', args);
    await mcp('update_plan', { expected_version: accepted.version, workouts: [] });
    const before = await trail();
    expect(await mcp('group_exercises', args)).toEqual({ ...accepted, replayed: true });
    expect(await mcp('group_exercises', { ...args, surprise: true }))
      .toEqual({ error: 'unknown_fields', fields: ['surprise'] });
    expect(await mcp('group_exercises', { ...args, round_rest: '30' }))
      .toEqual({ error: 'invalid_fields', fields: ['round_rest'] });
    const otherUserId = crypto.randomUUID();
    await env.DB.prepare('INSERT INTO users(id,apple_sub,created_at) VALUES(?1,?2,?3)')
      .bind(otherUserId, `group-retry-${otherUserId}`, Date.now()).run();
    expect(await mcp('group_exercises', args, otherUserId)).toEqual({ error: 'no_active_plan' });
    expect(await trail()).toEqual(before);
    expect((await getPlanTree(env.DB, userId))!.workouts).toEqual([]);
  });

  it('rejects unknown group arguments and malformed MCP values without coercing', async () => {
    const before = await trail();
    const rest = await api(`/workouts/${day().id}/groups`, 'PUT', { ...grouping(), surprise: true });
    expect(rest.body).toEqual({ error: 'unknown_fields', fields: ['surprise'] });
    expect((await mcp('group_exercises', { ...grouping(), day: 'A', round_rest: '30' })).error).toBe('invalid_fields');
    expect((await mcp('ungroup_exercises', { group_id: groupId })).error).toBe('invalid_fields');
    expect(await trail()).toEqual(before);
  });
});
