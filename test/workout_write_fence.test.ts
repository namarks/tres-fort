import { env, applyD1Migrations } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';

import { getOrCreateSession, logSet, updatePlanTree } from '../src/db';
import { handleMcp } from '../src/mcp/server';
import type { Env } from '../src/types';
import {
  isWorkoutWriteFenceActiveError,
  isWorkoutWriteFenceError,
  runWorkoutWriteBatch,
} from '../src/workout-write-fence';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

describe('workout write rollout fence', () => {
  it('deploys disabled, activates once, and admits writes only inside an atomic permit batch', async () => {
    const now = Date.now();
    const userId = crypto.randomUUID();
    const planId = crypto.randomUUID();
    const exerciseId = crypto.randomUUID();
    const sessionId = crypto.randomUUID();
    const setId = crypto.randomUUID();

    expect(
      await env.DB.prepare(
        'SELECT enabled, activated_at FROM workout_write_fence WHERE id = 1',
      ).first(),
    ).toEqual({ enabled: 0, activated_at: null });

    // Migration-first deployment remains compatible with the pre-fence
    // Worker because enforcement starts disabled.
    await env.DB.batch([
      env.DB
        .prepare(
          'INSERT INTO users (id, apple_sub, display_name, created_at) VALUES (?1, ?2, ?3, ?4)',
        )
        .bind(userId, `sub-${userId}`, 'Fence test', now),
      env.DB
        .prepare(
          "INSERT INTO plans (id, user_id, name, status, version, created_at, updated_at) VALUES (?1, ?2, 'Fence plan', 'active', 1, ?3, ?3)",
        )
        .bind(planId, userId, now),
      env.DB
        .prepare(
          "INSERT INTO exercises (id, name, primary_muscle, unit, created_at) VALUES (?1, 'Fence lift', 'other', 'lb', ?2)",
        )
        .bind(exerciseId, now),
      env.DB
        .prepare(
          "INSERT INTO sessions (id, user_id, plan_id, date, status, created_at, updated_at) VALUES (?1, ?2, ?3, '2030-01-01', 'planned', ?4, ?4)",
        )
        .bind(sessionId, userId, planId, now),
      env.DB
        .prepare(
          "INSERT INTO set_logs (id, session_id, exercise_id, set_index, weight, reps, logged_at, source) VALUES (?1, ?2, ?3, 1, 100, 5, ?4, 'ios')",
        )
        .bind(setId, sessionId, exerciseId, now),
    ]);
    await env.DB
      .prepare("UPDATE sessions SET notes = 'legacy-compatible' WHERE id = ?1")
      .bind(sessionId)
      .run();
    let prematureClaim: unknown;
    try {
      await env.DB
        .prepare("UPDATE sessions SET write_protocol = 'attempt-v1' WHERE id = ?1")
        .bind(sessionId)
        .run();
    } catch (error) {
      prematureClaim = error;
    }
    expect(isWorkoutWriteFenceError(prematureClaim)).toBe(true);
    await expect(
      env.DB
        .prepare(
          "INSERT INTO sessions (id, user_id, plan_id, date, status, created_at, updated_at, write_protocol) VALUES (?1, ?2, ?3, '2030-01-09', 'planned', ?4, ?4, 'attempt-v1')",
        )
        .bind(crypto.randomUUID(), userId, planId, now)
        .run(),
    ).rejects.toThrow(/workout_write_fence_not_active/);

    // A leaked permit would make enforcement ineffective.  Activation must
    // fail before changing the monotonic flag, then succeed once it is empty.
    await env.DB.prepare('INSERT INTO workout_write_permit (id) VALUES (1)').run();
    await expect(
      env.DB
        .prepare(
          'UPDATE workout_write_fence SET enabled = 1, activated_at = ?1 WHERE id = 1',
        )
        .bind(now + 1)
        .run(),
    ).rejects.toThrow(/workout_write_fence_permit_not_empty/);
    expect(
      await env.DB.prepare('SELECT enabled FROM workout_write_fence WHERE id = 1').first(),
    ).toEqual({ enabled: 0 });
    await env.DB.prepare('DELETE FROM workout_write_permit WHERE id = 1').run();
    await env.DB
      .prepare('UPDATE workout_write_fence SET enabled = 1, activated_at = ?1 WHERE id = 1')
      .bind(now + 1)
      .run();

    let rejectedWrite: unknown;
    try {
      await env.DB
        .prepare("UPDATE sessions SET notes = 'old-worker-write' WHERE id = ?1")
        .bind(sessionId)
        .run();
    } catch (error) {
      rejectedWrite = error;
    }
    expect(isWorkoutWriteFenceActiveError(rejectedWrite)).toBe(true);
    await expect(
      env.DB
        .prepare(
          "INSERT INTO sessions (id, user_id, plan_id, date, status, created_at, updated_at) VALUES (?1, ?2, ?3, '2030-01-02', 'planned', ?4, ?4)",
        )
        .bind(crypto.randomUUID(), userId, planId, now + 2)
        .run(),
    ).rejects.toThrow(/workout_write_fence_active/);
    await expect(
      env.DB
        .prepare("UPDATE set_logs SET notes = 'old-worker-write' WHERE id = ?1")
        .bind(setId)
        .run(),
    ).rejects.toThrow(/workout_write_fence_active/);
    await expect(
      env.DB
        .prepare(
          "INSERT INTO set_logs (id, session_id, exercise_id, set_index, weight, reps, logged_at, source) VALUES (?1, ?2, ?3, 2, 100, 5, ?4, 'ios')",
        )
        .bind(crypto.randomUUID(), sessionId, exerciseId, now + 2)
        .run(),
    ).rejects.toThrow(/workout_write_fence_active/);

    const nextSessionId = crypto.randomUUID();
    const nextSetId = crypto.randomUUID();
    const results = await runWorkoutWriteBatch(env.DB, [
      env.DB
        .prepare(
          "UPDATE sessions SET notes = 'permitted', write_protocol = 'attempt-v1' WHERE id = ?1",
        )
        .bind(sessionId),
      env.DB.prepare("UPDATE set_logs SET notes = 'permitted' WHERE id = ?1").bind(setId),
      env.DB
        .prepare(
          "INSERT INTO sessions (id, user_id, plan_id, date, status, created_at, updated_at) VALUES (?1, ?2, ?3, '2030-01-02', 'planned', ?4, ?4)",
        )
        .bind(nextSessionId, userId, planId, now + 2),
      env.DB
        .prepare(
          "INSERT INTO set_logs (id, session_id, exercise_id, set_index, weight, reps, logged_at, source) VALUES (?1, ?2, ?3, 1, 105, 5, ?4, 'ios')",
        )
        .bind(nextSetId, nextSessionId, exerciseId, now + 2),
    ]);
    expect(results).toHaveLength(4);
    expect(
      await env.DB
        .prepare('SELECT notes, write_protocol FROM sessions WHERE id = ?1')
        .bind(sessionId)
        .first(),
    ).toEqual({ notes: 'permitted', write_protocol: 'attempt-v1' });
    expect(
      await env.DB.prepare('SELECT notes FROM set_logs WHERE id = ?1').bind(setId).first(),
    ).toEqual({ notes: 'permitted' });
    expect(
      await env.DB.prepare('SELECT COUNT(*) AS count FROM workout_write_permit').first(),
    ).toEqual({ count: 0 });

    // A later statement failure rolls back both earlier mutations and the
    // permit insert; no cleanup path or guessed drain delay is required.
    await expect(
      runWorkoutWriteBatch(env.DB, [
        env.DB
          .prepare("UPDATE sessions SET notes = 'must-roll-back' WHERE id = ?1")
          .bind(sessionId),
        env.DB
          .prepare(
            "INSERT INTO sessions (id, user_id, plan_id, date, status, created_at, updated_at) VALUES (?1, ?2, ?3, '2030-01-03', 'planned', ?4, ?4)",
          )
          .bind(sessionId, userId, planId, now + 3),
      ]),
    ).rejects.toThrow();
    expect(
      await env.DB
        .prepare('SELECT notes, write_protocol FROM sessions WHERE id = ?1')
        .bind(sessionId)
        .first(),
    ).toEqual({ notes: 'permitted', write_protocol: 'attempt-v1' });
    expect(
      await env.DB.prepare('SELECT COUNT(*) AS count FROM workout_write_permit').first(),
    ).toEqual({ count: 0 });

    await expect(
      env.DB
        .prepare('UPDATE workout_write_fence SET enabled = 0, activated_at = NULL WHERE id = 1')
        .run(),
    ).rejects.toThrow(/workout_write_fence_is_monotonic/);
    await expect(
      env.DB.prepare('DELETE FROM workout_write_fence WHERE id = 1').run(),
    ).rejects.toThrow(/workout_write_fence_cannot_be_deleted/);
  });

  it('keeps production MCP writes and plan-reference remaps live after activation', async () => {
    const now = Date.now();
    const userId = crypto.randomUUID();
    const planId = crypto.randomUUID();
    await env.DB.batch([
      env.DB
        .prepare(
          'INSERT INTO users (id, apple_sub, display_name, created_at) VALUES (?1, ?2, ?3, ?4)',
        )
        .bind(userId, `sub-${userId}`, 'Active fence test', now),
      env.DB
        .prepare(
          "INSERT INTO plans (id, user_id, name, status, version, created_at, updated_at) VALUES (?1, ?2, 'Active fence plan', 'active', 1, ?3, ?3)",
        )
        .bind(planId, userId, now),
    ]);

    const built = await updatePlanTree(env.DB, userId, {
      name: 'Active fence plan',
      days: [
        {
          day_label: 'A',
          name: 'Fence day',
          exercises: [{ exercise: 'bench', target_sets: 3, target_reps: 5 }],
        },
      ],
    });
    expect(built).toMatchObject({ conflict: false });
    if (!('plan' in built)) throw new Error('expected_initial_plan');
    const oldDayId = built.plan.days[0]!.id;
    const oldSlotId = built.plan.days[0]!.exercises[0]!.id;
    const session = await getOrCreateSession(
      env.DB,
      userId,
      planId,
      '2030-02-01',
      oldDayId,
    );
    const setId = crypto.randomUUID();
    await logSet(env.DB, userId, {
      id: setId,
      session_id: session.id,
      exercise_id: 'ex_bench',
      template_exercise_id: oldSlotId,
      set_index: 1,
      weight: 135,
      reps: 5,
      source: 'ios',
    });

    await env.DB
      .prepare('UPDATE workout_write_fence SET enabled = 1, activated_at = ?1 WHERE id = 1')
      .bind(now + 1)
      .run();

    const rpc = await handleMcp(
      {
        jsonrpc: '2.0',
        id: 1,
        method: 'tools/call',
        params: {
          name: 'log_set',
          arguments: {
            exercise: 'bench',
            weight: 987.65,
            reps: 3,
            session_date: '2030-02-02',
          },
        },
      },
      env as unknown as Env,
      userId,
    );
    expect(rpc.status).toBe(200);
    const envelope = rpc.json as {
      result: { content: Array<{ text: string }>; isError?: boolean };
    };
    expect(envelope.result.isError).toBeUndefined();
    const mcpResult = JSON.parse(envelope.result.content[0]!.text) as {
      error?: string;
      set: { session_id: string };
    };
    expect(mcpResult.error).toBeUndefined();
    expect(
      await env.DB
        .prepare('SELECT write_protocol FROM sessions WHERE id = ?1')
        .bind(mcpResult.set.session_id)
        .first(),
    ).toEqual({ write_protocol: 'legacy' });

    const rebuilt = await updatePlanTree(env.DB, userId, {
      name: 'Active fence plan v2',
      expected_version: built.plan.version,
      days: [
        {
          day_label: 'A',
          name: 'Fence day',
          exercises: [{ exercise: 'bench', target_sets: 4, target_reps: 6 }],
        },
      ],
    });
    expect(rebuilt).toMatchObject({ conflict: false });
    if (!('plan' in rebuilt)) throw new Error('expected_rebuilt_plan');
    const newDayId = rebuilt.plan.days[0]!.id;
    const newSlotId = rebuilt.plan.days[0]!.exercises[0]!.id;
    expect(newDayId).not.toBe(oldDayId);
    expect(newSlotId).not.toBe(oldSlotId);
    expect(
      await env.DB
        .prepare('SELECT day_template_id FROM sessions WHERE id = ?1')
        .bind(session.id)
        .first(),
    ).toEqual({ day_template_id: newDayId });
    expect(
      await env.DB
        .prepare('SELECT template_exercise_id FROM set_logs WHERE id = ?1')
        .bind(setId)
        .first(),
    ).toEqual({ template_exercise_id: newSlotId });
    expect(
      await env.DB.prepare('SELECT COUNT(*) AS count FROM workout_write_permit').first(),
    ).toEqual({ count: 0 });
  });
});
