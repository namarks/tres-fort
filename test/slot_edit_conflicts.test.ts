import { applyD1Migrations, createExecutionContext, env } from 'cloudflare:test';
import { beforeAll, expect, it } from 'vitest';
import { issueAppJwt } from '../src/auth';
import { addTemplateExercise, deleteTemplateExercise, getPlanTree, updatePlanTree } from '../src/db';
import worker from '../src/index';
import { handleMcp } from '../src/mcp/server';


beforeAll(async () => { await applyD1Migrations(env.DB, env.TEST_MIGRATIONS); });

async function fixture() {
  const userId = crypto.randomUUID();
  await env.DB.prepare('INSERT INTO users(id,apple_sub,created_at) VALUES(?,?,1)').bind(userId, userId).run();
  const built = await updatePlanTree(env.DB, userId, { workouts: [{ name: 'A', day_label: 'A',
    exercises: [{ exercise: 'bench', target_sets: 3, target_reps: 5 }] }] });
  if (!('plan' in built)) throw new Error('fixture_failed');
  const plan = built.plan;
  const day = plan.workouts[0]!;
  const slot = day.exercises[0]!;
  return { userId, plan, day, slot };
}

async function counts(userId: string) {
  return env.DB.prepare(`SELECT
    (SELECT COUNT(*) FROM audit_log WHERE user_id=?1) audits,
    (SELECT COUNT(*) FROM plan_snapshots WHERE user_id=?1) snapshots,
    (SELECT COUNT(*) FROM notes WHERE user_id=?1) notes`).bind(userId).first();
}

function loseClaims(planId: string, maximum = Infinity) {
  let losses = 0;
  const db = new Proxy(env.DB, { get(target, property) {
    if (property === 'batch') return async (statements: D1PreparedStatement[]) => {
      if (losses < maximum) {
        losses++;
        await env.DB.prepare('UPDATE plans SET version=version+1 WHERE id=?').bind(planId).run();
      }
      return target.batch(statements);
    };
    const value = Reflect.get(target, property, target);
    return typeof value === 'function' ? value.bind(target) : value;
  } }) as D1Database;
  return { db, losses: () => losses };
}

it.each(['add', 'delete'] as const)('%s returns a conflict after bounded CAS losses without partial writes', async operation => {
  const { userId, plan, day, slot } = await fixture();
  const before = await counts(userId);
  const race = loseClaims(plan.id);
  const result = operation === 'add'
    ? await addTemplateExercise(race.db, plan.id, { ...slot, workout_id: day.id, order_index: 1 })
    : await deleteTemplateExercise(race.db, userId, { template_exercise_id: slot.id });
  expect(result).toEqual({ conflict: true, current_version: plan.version + 2 });
  expect(race.losses()).toBe(2);
  expect((await getPlanTree(env.DB, userId))!.workouts[0]!.exercises.map(s => s.id)).toEqual([slot.id]);
  expect(await counts(userId)).toEqual(before);
});

it('an unversioned add retries a clean loss and commits exactly once', async () => {
  const { userId, plan, day, slot } = await fixture();
  const race = loseClaims(plan.id, 1);
  const result = await addTemplateExercise(race.db, plan.id, { ...slot, workout_id: day.id, order_index: 1 });
  expect(result).toMatchObject({ workout_id: day.id, order_index: 1 });
  expect((await getPlanTree(env.DB, userId))!.workouts[0]!.exercises).toHaveLength(2);
  expect(race.losses()).toBe(1);
});

it('REST and MCP reject an observed stale version consistently without changing training data', async () => {
  const { userId, plan, day, slot } = await fixture();
  const jwt = await issueAppJwt(userId, env.APP_JWT_SECRET);
  const before = await counts(userId);
  for (const [method, path, body] of [
    ['POST', `workouts/${day.id}/exercises`, { exercise: 'bench', target_sets: 3, target_reps: 5, expected_version: plan.version + 1 }],
    ['PATCH', `workouts/${day.id}/exercises/${slot.id}`, { cues: 'stale', expected_version: plan.version + 1 }],
    ['DELETE', `workouts/${day.id}/exercises/${slot.id}?expected_version=${plan.version + 1}`, undefined],
  ] as const) {
    const response = await worker.fetch(new Request(`https://test/api/${path}`, { method,
      headers: { authorization: `Bearer ${jwt}`, 'content-type': 'application/json' },
      ...(body ? { body: JSON.stringify(body) } : {}),
    }), env, createExecutionContext());
    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({ conflict: true, current_version: plan.version });
  }
  for (const [name, args] of [
    ['add_exercise', { day: 'A', exercise: 'bench', target_sets: 3, target_reps: 5 }],
    ['update_exercise', { template_exercise_id: slot.id, patch: { cues: 'stale' } }],
    ['delete_exercise', { template_exercise_id: slot.id }],
  ] as const) {
    const result = await handleMcp({ jsonrpc: '2.0', id: 1, method: 'tools/call',
      params: { name, arguments: { ...args, expected_version: plan.version + 1 } } }, env, userId);
    const envelope = result.json as { result: { content: { text: string }[] } };
    expect(JSON.parse(envelope.result.content[0]!.text)).toEqual({ conflict: true, current_version: plan.version });
  }
  expect(await counts(userId)).toEqual(before);
  expect(await env.DB.prepare('SELECT cues FROM template_exercises WHERE id=?').bind(slot.id).first())
    .toEqual({ cues: null });
});

it('malformed slot-edit JSON receives a client error', async () => {
  const { userId, day, slot } = await fixture();
  const jwt = await issueAppJwt(userId, env.APP_JWT_SECRET);
  for (const method of ['POST', 'PATCH']) {
    const path = method === 'POST' ? `workouts/${day.id}/exercises` : `workouts/${day.id}/exercises/${slot.id}`;
    const response = await worker.fetch(new Request(`https://test/api/${path}`, { method,
      headers: { authorization: `Bearer ${jwt}`, 'content-type': 'application/json' }, body: '{broken',
    }), env, createExecutionContext());
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: 'invalid_json' });
  }
});
