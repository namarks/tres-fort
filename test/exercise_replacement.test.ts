import { applyD1Migrations, env, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { issueAppJwt } from '../src/auth';
import { getPlanTree, swapExercise, updateExercise, updatePlanTree } from '../src/db';
import { handleMcp } from '../src/mcp/server';
import type { Env } from '../src/types';

const BASE = 'https://tres-fort.test';
beforeAll(async () => applyD1Migrations(env.DB, env.TEST_MIGRATIONS));

async function fixture(timed = false) {
  const userId = crypto.randomUUID();
  await env.DB.prepare('INSERT INTO users(id,apple_sub,created_at) VALUES(?1,?2,?3)')
    .bind(userId, `sub-${userId}`, Date.now()).run();
  const built = await updatePlanTree(env.DB, userId, { workouts: [
    { name: 'Strength', day_label: 'A', exercises: [
      { exercise: 'pull-up', target_sets: 3, target_reps: 6 },
      { exercise: timed ? 'plank' : 'pull-up', target_sets: 2,
        target_reps: timed ? 30 : 8, target_reps_max: timed ? null : 12,
        target_weight: -10, target_rpe: 7, target_duration_s: timed ? 30 : null,
        rest_seconds: 75, is_warmup: 1, cues: 'Controlled',
        progression: { type: 'manual' } },
    ] },
    { name: 'Other', exercises: [] },
  ] });
  if (!('plan' in built)) throw new Error('fixture_failed');
  const plan = built.plan;
  return { userId, plan, day: plan.workouts[0]!, slot: plan.workouts[0]!.exercises[1]!,
    headers: { authorization: `Bearer ${await issueAppJwt(userId, 'test-secret')}`,
      'content-type': 'application/json' } };
}

async function footprint(userId: string) {
  return {
    plan: await getPlanTree(env.DB, userId),
    counts: await env.DB.prepare(`SELECT
      (SELECT COUNT(*) FROM audit_log WHERE user_id=?1) AS audits,
      (SELECT COUNT(*) FROM notes WHERE user_id=?1) AS notes,
      (SELECT COUNT(*) FROM plan_snapshots WHERE user_id=?1) AS snapshots`)
      .bind(userId).first<{ audits: number; notes: number; snapshots: number }>(),
  };
}

function replace(f: Awaited<ReturnType<typeof fixture>>, body: unknown,
                 dayID = f.day.id, slotID = f.slot.id) {
  return SELF.fetch(`${BASE}/api/workouts/${dayID}/exercises/${slotID}/swap`, {
    method: 'POST', headers: f.headers, body: JSON.stringify(body),
  });
}

describe('exercise replacement', () => {
  it('replaces exactly one duplicate slot, preserving prescription, history, and atomic attribution', async () => {
    const f = await fixture();
    const sessionResponse = await SELF.fetch(`${BASE}/api/sessions`, {
      method: 'POST', headers: f.headers,
      body: JSON.stringify({ date: '2026-09-08', workout_id: f.day.id }),
    });
    expect(sessionResponse.status).toBe(201);
    const session = await sessionResponse.json<{ id: string; attempt: number }>();
    const logResponse = await SELF.fetch(`${BASE}/api/sessions/${session.id}/sets`, {
      method: 'POST', headers: f.headers, body: JSON.stringify({
        id: crypto.randomUUID(), exercise_id: f.slot.exercise_id,
        template_exercise_id: f.slot.id, set_index: 1, weight: -10, reps: 8,
        expected_attempt: session.attempt,
      }),
    });
    expect(logResponse.status).toBe(201);
    const logs = await env.DB.prepare('SELECT * FROM set_logs WHERE session_id=?1').bind(session.id).all();
    const before = await footprint(f.userId);
    const response = await replace(f, { to_exercise: 'ring row', expected_version: f.plan.version });
    expect(response.status).toBe(200);
    const after = await footprint(f.userId);
    const slot = after.plan!.workouts[0]!.exercises[1]!;
    expect(slot.exercise_id).not.toBe(f.slot.exercise_id);
    for (const key of ['id', 'order_index', 'target_sets', 'target_reps', 'target_reps_max',
      'target_weight', 'target_rpe', 'target_duration_s', 'rest_seconds', 'is_warmup',
      'cues', 'progression'] as const) expect(slot[key]).toEqual(f.slot[key]);
    expect(after.plan!.workouts[0]!.exercises[0]).toEqual(f.day.exercises[0]);
    expect(after.plan!.version).toBe(f.plan.version + 1);
    expect(after.counts).toEqual({ audits: before.counts!.audits + 1,
      notes: before.counts!.notes, snapshots: before.counts!.snapshots + 1 });
    expect((await env.DB.prepare('SELECT * FROM set_logs WHERE session_id=?1').bind(session.id).all()).results)
      .toEqual(logs.results);
    expect(await env.DB.prepare("SELECT actor,tool FROM audit_log WHERE user_id=?1 AND tool='swap_exercise'")
      .bind(f.userId).first()).toEqual({ actor: 'ios', tool: 'swap_exercise' });
    const snapshot = await env.DB.prepare('SELECT document FROM plan_snapshots WHERE plan_id=?1 AND version=?2')
      .bind(f.plan.id, f.plan.version + 1).first<string>('document');
    expect(JSON.parse(snapshot!).workouts[0].exercises[1].exercise_id).toBe(slot.exercise_id);
    // A lost response cannot turn a retry into another write or overwrite a newer choice.
    expect((await replace(f, { to_exercise: 'ring row', expected_version: f.plan.version })).status).toBe(409);
    expect(await footprint(f.userId)).toEqual(after);
  });

  it('preserves timed targets and signed assistance for a compatible hold', async () => {
    const f = await fixture(true);
    const response = await replace(f, { to_exercise: 'L-sit', expected_version: f.plan.version });
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ id: f.slot.id, target_duration_s: 30,
      target_reps: 30, target_weight: -10, is_warmup: 1 });
  });

  it('rejects incompatible targets and malformed requests without durable contributions', async () => {
    const f = await fixture();
    const before = await footprint(f.userId);
    for (const body of [
      { to_exercise: 'bench', expected_version: f.plan.version },
      { to_exercise: 'nonexistent movement', expected_version: f.plan.version },
      { to_exercise: 'ring row' },
      { to_exercise: 42, expected_version: f.plan.version },
      { to_exercise: 'ring row', expected_version: String(f.plan.version) },
      { to_exercise: 'ring row', expected_version: f.plan.version, carry_targets: false },
      [],
    ]) {
      expect((await replace(f, body)).status).toBe(400);
      expect(await footprint(f.userId)).toEqual(before);
    }
    const malformed = await SELF.fetch(`${BASE}/api/workouts/${f.day.id}/exercises/${f.slot.id}/swap`, {
      method: 'POST', headers: f.headers, body: '{',
    });
    expect(malformed.status).toBe(400);
    expect(await footprint(f.userId)).toEqual(before);
  });

  it('scopes replacement to the caller, nested day, and active plan', async () => {
    const f = await fixture();
    const foreign = await fixture();
    const foreignBefore = await footprint(foreign.userId);
    const body = { to_exercise: 'ring row', expected_version: f.plan.version };
    const before = await footprint(f.userId);
    expect((await replace(f, body, foreign.day.id, foreign.slot.id)).status).toBe(404);
    expect((await replace(f, body, f.plan.workouts[1]!.id)).status).toBe(404);
    expect((await SELF.fetch(`${BASE}/api/workouts/${f.day.id}/exercises/${f.slot.id}/swap`, {
      method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
    })).status).toBe(401);
    expect(await footprint(f.userId)).toEqual(before);
    await env.DB.prepare("UPDATE plans SET status='archived' WHERE id=?1").bind(f.plan.id).run();
    await updatePlanTree(env.DB, f.userId, { workouts: [{ name: 'New', exercises: [] }] });
    const archivedBefore = await footprint(f.userId);
    expect((await replace(f, body)).status).toBe(404);
    expect(await footprint(f.userId)).toEqual(archivedBefore);
    expect(await footprint(foreign.userId)).toEqual(foreignBefore);
  });

  it('returns a conflict when a concurrent target edit wins the commit boundary', async () => {
    const f = await fixture();
    let injected = false;
    const db = new Proxy(env.DB, {
      get(target, property) {
        if (property === 'batch') return async (statements: D1PreparedStatement[]) => {
          if (!injected) {
            injected = true;
            await updateExercise(env.DB, f.userId, { template_exercise_id: f.slot.id }, { target_reps: 10 });
          }
          return target.batch(statements);
        };
        const value = Reflect.get(target, property, target);
        return typeof value === 'function' ? value.bind(target) : value;
      },
    }) as D1Database;
    expect(await swapExercise(db, f.userId, { template_exercise_id: f.slot.id,
      workout_id: f.day.id, to_exercise: 'ring row', expected_version: f.plan.version }))
      .toEqual({ conflict: true, current_version: f.plan.version + 1 });
    const slot = (await getPlanTree(env.DB, f.userId))!.workouts[0]!.exercises[1]!;
    expect(slot).toMatchObject({ exercise_id: f.slot.exercise_id, target_reps: 10 });
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM audit_log WHERE user_id=?1 AND tool='swap_exercise'")
      .bind(f.userId).first<number>('n')).toBe(0);
  });

  it('rolls back the swap and version if snapshot insertion fails', async () => {
    const f = await fixture();
    const before = await footprint(f.userId);
    await env.DB.prepare(`CREATE TRIGGER fail_swap_snapshot BEFORE INSERT ON plan_snapshots
      WHEN NEW.operation='swap_exercise' BEGIN SELECT RAISE(ABORT,'test_swap_snapshot_failure'); END`).run();
    try {
      expect((await replace(f, { to_exercise: 'ring row', expected_version: f.plan.version })).status).toBe(500);
      expect(await footprint(f.userId)).toEqual(before);
    } finally { await env.DB.prepare('DROP TRIGGER fail_swap_snapshot').run(); }
  });

  it('keeps MCP swaps compatible and records their coach note with the same preserved targets', async () => {
    const f = await fixture(true);
    const before = await footprint(f.userId);
    const result = await handleMcp({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: {
      name: 'swap_exercise', arguments: { day: 'A', from_exercise: 'plank', to_exercise: 'L-sit' },
    } }, env as Env, f.userId);
    const body = result.json as { result: { content: Array<{ text: string }> } };
    expect(JSON.parse(body.result.content[0]!.text)).toMatchObject({ id: f.slot.id,
      target_duration_s: 30, target_weight: -10 });
    const after = await footprint(f.userId);
    expect(after.counts).toEqual({ audits: before.counts!.audits + 1,
      notes: before.counts!.notes + 1, snapshots: before.counts!.snapshots + 1 });
    const list = await handleMcp({ jsonrpc: '2.0', id: 2, method: 'tools/list' }, env as Env, f.userId);
    const tools = (list.json as { result: { tools: Array<{ name: string; inputSchema: { properties: object } }> } }).result.tools;
    expect(tools.find((tool) => tool.name === 'swap_exercise')!.inputSchema.properties).not.toHaveProperty('carry_targets');
    // Retain the established MCP audit contract even when the caller selects
    // the same movement; do not add an unaudited early-success path.
    await handleMcp({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: {
      name: 'swap_exercise', arguments: { day: 'A', from_exercise: 'L-sit', to_exercise: 'L-sit' },
    } }, env as Env, f.userId);
    const repeated = await footprint(f.userId);
    expect(repeated.plan!.version).toBe(after.plan!.version + 1);
    expect(repeated.counts).toEqual({ audits: after.counts!.audits + 1,
      notes: after.counts!.notes + 1, snapshots: after.counts!.snapshots + 1 });
  });
});
