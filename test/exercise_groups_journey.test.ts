import { applyD1Migrations, env, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import fixture from '../ios/TresFortTests/Fixtures/ExerciseGroups.json';

const base = 'https://tres-fort.test';
let headers: Record<string, string>;
let plan: any;
const groupIDs = fixture.groups.map(() => crypto.randomUUID());

async function api(path: string, method = 'GET', body?: unknown) {
  const response = await SELF.fetch(`${base}/api${path}`, { method, headers,
    ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
  return { status: response.status, body: await response.json<any>() };
}

async function mcp(name: string, args: unknown = {}) {
  const response = await SELF.fetch(`${base}/mcp`, { method: 'POST',
    headers: { 'content-type': 'application/json', Authorization: 'Bearer test-mcp-token' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: args } }) });
  expect(response.status).toBe(200);
  const result = await response.json<any>();
  expect(result.result.isError).not.toBe(true);
  return JSON.parse(result.result.content[0].text);
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
  const auth = await SELF.fetch(`${base}/auth/dev`, { method: 'POST',
    headers: { 'content-type': 'application/json' }, body: JSON.stringify({ secret: 'test-dev' }) });
  headers = { 'content-type': 'application/json', Authorization: `Bearer ${(await auth.json<any>()).jwt}`,
    'X-TresFort-Capabilities': 'groups' };
  await mcp('update_plan', { name: fixture.name, workouts: [{ name: fixture.day_name, exercises: fixture.slots.map((slot) => ({
    exercise: slot.exercise, target_sets: slot.target_sets, target_reps: slot.target_reps,
    target_weight: slot.target_weight, rest_seconds: slot.rest_seconds, is_warmup: slot.is_warmup,
  })) }] });
  plan = (await api('/state')).body.plan;
  for (const [index, group] of fixture.groups.entries()) {
    const result = await api(`/workouts/${plan.workouts[0].id}/groups`, 'PUT', {
      group_id: groupIDs[index], expected_version: plan.version,
      exercises: group.member_indices.map((i) => plan.workouts[0].exercises[i].id),
      round_rest: group.round_rest, transition_rest: group.transition_rest, target_sets: group.rounds,
    });
    expect(result.status).toBe(200);
    plan = (await api('/state')).body.plan;
  }
});

describe('shared simulator and real-D1 superset workout', () => {
  it('reads the member-authored warm-up and working group identically through state and coach', async () => {
    const state = await api('/state');
    expect(state.body.plan_groups_version).toBe(1);
    const coach = await mcp('get_current_plan');
    expect(coach.version).toBe(plan.version);
    expect(coach.workouts[0].exercises.map((slot: any) => slot.group_label)).toEqual(['A1', 'A2', 'B1', 'B2']);
    for (const [index, expected] of fixture.slots.entries()) {
      const member = state.body.plan.workouts[0].exercises[index];
      const groupIndex = fixture.groups.findIndex((group) => group.member_indices.includes(index));
      const group = fixture.groups[groupIndex]!;
      expect(member).toMatchObject({ exercise_id: expected.exercise_id, exercise_name: expected.exercise_name,
        target_sets: group.rounds, target_reps: expected.target_reps, target_weight: expected.target_weight,
        is_warmup: expected.is_warmup, rest_seconds: expected.rest_seconds, group_id: groupIDs[groupIndex],
        group_rest_seconds: group.round_rest, group_transition_seconds: group.transition_rest });
      const { group_label: _label, ...canonical } = coach.workouts[0].exercises[index];
      expect(canonical).toEqual(member);
    }
  });

  describe('recorded alternating rounds', () => {
    let session: any;
    const counts = new Map<string, number>();
    const logs: any[] = [];
    // Reuse a complete real-API fixture under isolatedStorage. Each assertion
    // case gets the same logged rounds and rolls back its own completion write.
    beforeAll(async () => {
      const created = await api('/sessions', 'POST', {
        date: fixture.date, workout_id: plan.workouts[0].id, expected_attempt: 0,
      });
      expect(created.status).toBe(201);
      session = created.body;
      for (const index of fixture.execution_indices) {
        const slot = plan.workouts[0].exercises[index];
        const count = (counts.get(slot.id) ?? 0) + 1;
        counts.set(slot.id, count);
        const logged = await api(`/sessions/${session.id}/sets`, 'POST', {
          id: crypto.randomUUID(), exercise_id: slot.exercise_id, template_exercise_id: slot.id,
          set_index: count, weight: slot.target_weight, reps: slot.target_reps,
          is_warmup: slot.is_warmup === 1, is_timed: false, expected_attempt: session.attempt,
        });
        expect(logged.status).toBe(201);
        logs.push(logged.body.set);
      }
    });

    it('retains each physical set on its own slot with unchanged warm-up classification', async () => {
      expect(logs.map((set) => set.template_exercise_id))
        .toEqual(fixture.execution_indices.map((index) => plan.workouts[0].exercises[index].id));
      expect(logs.filter((set) => set.is_warmup === 1)).toHaveLength(4);
      expect(logs.filter((set) => set.is_warmup === 0)).toHaveLength(4);
      expect([...counts.values()]).toEqual([2, 2, 2, 2]);
      const state = (await api('/state')).body;
      expect(state.sets.filter((set: any) => set.session_id === session.id)).toHaveLength(8);
      expect((await mcp('get_current_plan')).version).toBe(plan.version);
    });

    it('keeps warm-ups out of completion totals', async () => {
      const completion = await api(`/sessions/${session.id}?expected_attempt=${session.attempt}`, 'PATCH', { status: 'completed' });
      expect(completion.status).toBe(200);
      const summary = await api(`/sessions/${session.id}/summary`);
      expect(summary.body.working_sets).toBe(4);
    });
  });

  it('moves a complete card and restores each ordinary rest when ungrouped', async () => {
    const first = fixture.groups[0]!;
    const moved = await api(`/workouts/${plan.workouts[0].id}/groups`, 'PUT', {
      group_id: groupIDs[0], expected_version: plan.version,
      exercises: first.member_indices.map((i) => plan.workouts[0].exercises[i].id),
      round_rest: first.round_rest, transition_rest: first.transition_rest, target_sets: first.rounds, order_index: 2,
    });
    expect(moved.status).toBe(200);
    const reordered = (await api('/state')).body.plan.workouts[0].exercises;
    expect(reordered.map((slot: any) => slot.exercise_id)).toEqual([2, 3, 0, 1].map((i) => fixture.slots[i]!.exercise_id));
    const cleared = await api(`/workouts/${plan.workouts[0].id}/groups`, 'PUT', {
      group_id: groupIDs[0], expected_version: moved.body.version, exercises: [],
    });
    expect(cleared.status).toBe(200);
    const ordinary = (await api('/state')).body.plan.workouts[0].exercises.slice(2);
    expect(ordinary.map((slot: any) => slot.group_id)).toEqual([null, null]);
    expect(ordinary.map((slot: any) => slot.rest_seconds)).toEqual([45, 90]);
  });
});
