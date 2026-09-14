import { applyD1Migrations, env } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import {
  adjustToday,
  comparePlanVersions,
  createPlan,
  deleteUserAccount,
  exportUserData,
  getOrCreateSession,
  getPlanSnapshot,
  getPlanTree,
  listPlanHistory,
  restorePlanSnapshot,
  updatePlanTree,
  updateExercise,
} from '../src/db';
import { comparePlanSnapshots, serializePlanSnapshot } from '../src/planSnapshots';

beforeAll(async () => applyD1Migrations(env.DB, env.TEST_MIGRATIONS));

async function fixture(label: string) {
  const userId = crypto.randomUUID();
  await env.DB.prepare(
    'INSERT INTO users (id,apple_sub,display_name,created_at) VALUES (?1,?2,?3,?4)',
  ).bind(userId, `sub-${userId}`, label, Date.now()).run();
  await createPlan(env.DB, userId, `${label} plan`);
  const built = await updatePlanTree(env.DB, userId, {
    name: `${label} plan`,
    workouts: [{ name: 'Strength A', day_label: 'A', exercises: [
      { exercise: 'bench', target_sets: 3, target_reps: 5, target_weight: 135 },
    ] }],
  });
  if (!('plan' in built)) throw new Error('fixture_plan_failed');
  return { userId, plan: built.plan };
}

describe('plan snapshots', () => {
  it('round trips the canonical writable document and reports a useful comparison', async () => {
    const { userId, plan } = await fixture('roundtrip');
    const stored = await getPlanSnapshot(env.DB, userId, plan.id, plan.version);
    expect(stored?.parsed).toEqual(serializePlanSnapshot(plan));
    const changed = structuredClone(stored!.parsed);
    changed.workouts[0]!.exercises[0]!.target_weight = 145;
    const diff = comparePlanSnapshots(stored!.parsed, changed);
    expect(diff.summary.exercises_changed).toBe(1);
    expect(diff.changes[0]?.path).toContain('Strength A');
  });

  it('keeps the history page bounded to the version read before a concurrent change', async () => {
    const { userId, plan } = await fixture('history race');
    let injected = false;
    const racingDb = new Proxy(env.DB, {
      get(target, property) {
        if (property === 'prepare') return (sql: string) => {
          const statement = target.prepare(sql);
          if (!sql.includes('SELECT * FROM plan_snapshots')) return statement;
          return new Proxy(statement, {
            get(target, property) {
              if (property === 'bind') return (...values: unknown[]) => {
                const bound = target.bind(...values);
                return new Proxy(bound, {
                  get(target, property) {
                    if (property === 'all') return async () => {
                      if (!injected) {
                        injected = true;
                        await updateExercise(env.DB, userId, {
                          template_exercise_id: plan.workouts[0]!.exercises[0]!.id,
                        }, { target_weight: 155 });
                      }
                      return target.all();
                    };
                    const value = Reflect.get(target, property, target);
                    return typeof value === 'function' ? value.bind(target) : value;
                  },
                });
              };
              const value = Reflect.get(target, property, target);
              return typeof value === 'function' ? value.bind(target) : value;
            },
          });
        };
        const value = Reflect.get(target, property, target);
        return typeof value === 'function' ? value.bind(target) : value;
      },
    }) as D1Database;
    const history = await listPlanHistory(racingDb, userId);
    expect(injected).toBe(true);
    expect(history).toMatchObject({ current_version: plan.version });
    if (!('items' in history) || !history.items) throw new Error('history_missing');
    expect(history.items[0]!.version).toBe(plan.version);
    expect((await getPlanTree(env.DB, userId))?.version).toBe(plan.version + 1);
  });

  it('compares a labeled current version from its immutable snapshot', async () => {
    const { userId, plan } = await fixture('comparison fence');
    const snapshotOnlyDb = new Proxy(env.DB, {
      get(target, property) {
        if (property === 'prepare') return (sql: string) => {
          if (sql.includes('FROM workouts WHERE plan_id')) {
            throw new Error('live_tree_read_not_allowed');
          }
          return target.prepare(sql);
        };
        const value = Reflect.get(target, property, target);
        return typeof value === 'function' ? value.bind(target) : value;
      },
    }) as D1Database;
    const comparison = await comparePlanVersions(snapshotOnlyDb, userId, plan.version);
    expect(comparison).toMatchObject({
      from_version: plan.version, to_version: plan.version, changes: [],
    });
  });

  it('restores an immutable pre-rename document without rewriting its stored bytes', async () => {
    const { userId, plan } = await fixture('legacy snapshot');
    const canonical = serializePlanSnapshot(plan);
    const legacy = JSON.stringify({ schema_version: 1, plan: canonical.plan, days: canonical.workouts });
    // Model an existing v1 row created before the rollout.
    await env.DB.prepare('UPDATE plan_snapshots SET document=? WHERE plan_id=? AND version=?')
      .bind(legacy, plan.id, plan.version).run();
    const changed = await updatePlanTree(env.DB, userId, { expected_version: plan.version,
      name: 'Changed', workouts: [{ name: 'Hotel', exercises: [] }] });
    if (!('plan' in changed)) throw new Error('change_failed');
    expect(await restorePlanSnapshot(env.DB, userId, { plan_id: plan.id, snapshot_version: plan.version,
      expected_version: changed.plan.version, actor: 'ios' })).toMatchObject({ ok: true });
    expect(await comparePlanVersions(env.DB, userId, plan.version)).toMatchObject({ changes: [] });
    expect(await env.DB.prepare('SELECT document FROM plan_snapshots WHERE plan_id=? AND version=?')
      .bind(plan.id, plan.version).first('document')).toBe(legacy);
  });

  it('returns the acknowledged plan version when another write wins before response refresh', async () => {
    const { userId, plan } = await fixture('response race');
    let injected = false;
    const racingDb = new Proxy(env.DB, {
      get(target, property) {
        if (property === 'batch') return async (statements: D1PreparedStatement[]) => {
          const result = await target.batch(statements);
          if (!injected) {
            injected = true;
            const concurrent = await updatePlanTree(env.DB, userId, {
              expected_version: plan.version + 1,
              name: 'Concurrent second write',
              workouts: [{ name: 'Second', exercises: [] }],
            });
            if (!('plan' in concurrent)) throw new Error('concurrent_write_failed');
          }
          return result;
        };
        const value = Reflect.get(target, property, target);
        return typeof value === 'function' ? value.bind(target) : value;
      },
    }) as D1Database;
    const acknowledged = await updatePlanTree(racingDb, userId, {
      expected_version: plan.version,
      name: 'Acknowledged first write',
      workouts: [{ name: 'First', exercises: [] }],
    });
    expect(acknowledged).toMatchObject({
      conflict: false,
      plan: { name: 'Acknowledged first write', version: plan.version + 1 },
    });
    expect((await getPlanTree(env.DB, userId))?.name).toBe('Concurrent second write');
  });

  it('keeps a committed update acknowledged when its response snapshot read fails', async () => {
    const { userId, plan } = await fixture('refresh failure');
    let committed = false;
    const failingRefreshDb = new Proxy(env.DB, {
      get(target, property) {
        if (property === 'batch') return async (statements: D1PreparedStatement[]) => {
          const result = await target.batch(statements);
          committed = true;
          return result;
        };
        if (property === 'prepare') return (sql: string) => {
          if (committed && sql.includes('FROM plan_snapshots WHERE user_id')) {
            throw new Error('injected_refresh_failure');
          }
          return target.prepare(sql);
        };
        const value = Reflect.get(target, property, target);
        return typeof value === 'function' ? value.bind(target) : value;
      },
    }) as D1Database;
    expect(await updatePlanTree(failingRefreshDb, userId, {
      expected_version: plan.version, name: 'Committed despite refresh failure',
      workouts: [{ name: 'A', exercises: [] }],
    })).toMatchObject({
      conflict: false, acknowledged: true, refresh_required: true,
      plan_id: plan.id, version: plan.version + 1,
    });
    expect((await getPlanTree(env.DB, userId))?.version).toBe(plan.version + 1);
  });

  it('restores a caller-owned snapshot as a new version and retains both versions', async () => {
    const { userId, plan } = await fixture('restore');
    const changed = await updatePlanTree(env.DB, userId, {
      expected_version: plan.version,
      name: 'Changed plan',
      workouts: [{ name: 'Strength B', day_label: 'B', exercises: [
        { exercise: 'squat', target_sets: 4, target_reps: 6 },
      ] }],
    });
    if (!('plan' in changed)) throw new Error('changed_plan_failed');
    const restored = await restorePlanSnapshot(env.DB, userId, {
      plan_id: plan.id, snapshot_version: plan.version,
      expected_version: changed.plan.version, actor: 'ios', reason: 'Undo change',
    });
    expect(restored).toMatchObject({ ok: true, restored_from_version: plan.version, version: changed.plan.version + 1 });
    expect((await getPlanTree(env.DB, userId))?.name).toBe(plan.name);
    expect(await getPlanSnapshot(env.DB, userId, plan.id, plan.version)).not.toBeNull();
    expect(await getPlanSnapshot(env.DB, userId, plan.id, changed.plan.version + 1)).not.toBeNull();
    const history = await listPlanHistory(env.DB, userId);
    if (!('items' in history) || !Array.isArray(history.items)) throw new Error('history_missing');
    expect(history.items[0]?.operation).toBe('restore_plan');
    const comparison = await comparePlanVersions(env.DB, userId, plan.version);
    expect('changes' in comparison && comparison.changes).toHaveLength(0);
  });

  it('rejects stale, cross-user, and active-workout restore attempts', async () => {
    const one = await fixture('owner-one');
    const two = await fixture('owner-two');
    expect(await restorePlanSnapshot(env.DB, two.userId, {
      plan_id: one.plan.id, snapshot_version: one.plan.version,
      expected_version: two.plan.version, actor: 'mcp',
    })).toMatchObject({ conflict: true });
    expect(await restorePlanSnapshot(env.DB, one.userId, {
      plan_id: one.plan.id, snapshot_version: one.plan.version,
      expected_version: one.plan.version - 1, actor: 'mcp',
    })).toMatchObject({ conflict: true });
    const session = await getOrCreateSession(
      env.DB, one.userId, one.plan.id, '2026-09-07', one.plan.workouts[0]!.id,
    );
    await env.DB.prepare("UPDATE sessions SET status='in_progress' WHERE id=?1").bind(session.id).run();
    expect(await restorePlanSnapshot(env.DB, one.userId, {
      plan_id: one.plan.id, snapshot_version: one.plan.version,
      expected_version: one.plan.version, actor: 'ios',
    })).toEqual({ error: 'active_workout' });
  });

  it('rejects a workout that starts after restore prechecks but before its write batch', async () => {
    const { userId, plan } = await fixture('restore race');
    const changed = await updatePlanTree(env.DB, userId, {
      expected_version: plan.version,
      workouts: [{ name: 'Current', day_label: 'C', exercises: [
        { exercise: 'squat', target_sets: 3, target_reps: 5 },
      ] }],
    });
    if (!('plan' in changed)) throw new Error('changed_plan_failed');
    let intercepted = false;
    const racingDb = new Proxy(env.DB, {
      get(target, property) {
        if (property === 'batch') return async (statements: D1PreparedStatement[]) => {
          if (!intercepted) {
            intercepted = true;
            const ts = Date.now();
            await env.DB.prepare(
              `INSERT INTO sessions
               (id,user_id,plan_id,workout_id,date,status,started_at,created_at,updated_at)
               VALUES (?1,?2,?3,?4,'2026-09-07','in_progress',?5,?5,?5)`,
            ).bind(crypto.randomUUID(), userId, plan.id, changed.plan.workouts[0]!.id, ts).run();
          }
          return target.batch(statements);
        };
        const value = Reflect.get(target, property, target);
        return typeof value === 'function' ? value.bind(target) : value;
      },
    }) as D1Database;
    expect(await restorePlanSnapshot(racingDb, userId, {
      plan_id: plan.id, snapshot_version: plan.version,
      expected_version: changed.plan.version, actor: 'ios',
    })).toEqual({ error: 'active_workout' });
    expect((await getPlanTree(env.DB, userId))?.version).toBe(changed.plan.version);
  });

  it('includes immutable plan history in the portable export', async () => {
    const { userId } = await fixture('export');
    const exported = await exportUserData(env.DB, userId) as {
      schema_version: number; training: { plan_snapshots: unknown[] };
    };
    expect(exported.schema_version).toBe(3);
    expect(exported.training.plan_snapshots).toHaveLength(2);
  });

  it('does not leave an empty plan when first-plan snapshot contribution fails', async () => {
    const userId = crypto.randomUUID();
    await env.DB.prepare(
      'INSERT INTO users (id,apple_sub,display_name,created_at) VALUES (?1,?2,?3,?4)',
    ).bind(userId, `sub-${userId}`, 'atomic bootstrap', Date.now()).run();
    await env.DB.prepare(
      `CREATE TRIGGER fail_bootstrap_snapshot BEFORE INSERT ON plan_snapshots
       WHEN NEW.user_id='${userId}' BEGIN SELECT RAISE(ABORT,'snapshot_failure'); END`,
    ).run();
    try {
      await expect(updatePlanTree(env.DB, userId, {
        name: 'First plan',
        workouts: [{ name: 'A', exercises: [{ exercise: 'bench', target_sets: 3, target_reps: 5 }] }],
      })).rejects.toThrow();
    } finally {
      await env.DB.prepare('DROP TRIGGER fail_bootstrap_snapshot').run();
    }
    expect(await getPlanTree(env.DB, userId)).toBeNull();
  });

  it('rolls back the document, version, audit, and note when a result snapshot fails', async () => {
    const { userId, plan } = await fixture('rollback');
    const stored = await getPlanSnapshot(env.DB, userId, plan.id, plan.version);
    await env.DB.prepare(
      `INSERT INTO plan_snapshots
       (id,user_id,plan_id,version,document,actor,operation,reason,created_at)
       VALUES (?1,?2,?3,?4,?5,'system','collision',NULL,?6)`,
    ).bind(crypto.randomUUID(), userId, plan.id, plan.version + 1,
      stored!.document, Date.now()).run();
    const beforeAudit = await env.DB.prepare(
      'SELECT COUNT(*) AS n FROM audit_log WHERE user_id=?1',
    ).bind(userId).first<{ n: number }>();
    const beforeNotes = await env.DB.prepare(
      'SELECT COUNT(*) AS n FROM notes WHERE user_id=?1',
    ).bind(userId).first<{ n: number }>();
    await expect(updatePlanTree(env.DB, userId, {
      expected_version: plan.version,
      workouts: [{ name: 'Should roll back', exercises: [{ exercise: 'squat', target_sets: 3, target_reps: 5 }] }],
    }, { actor: 'mcp', operation: 'update_plan', note: 'Must not survive' })).rejects.toThrow();
    const after = await getPlanTree(env.DB, userId);
    expect(after?.version).toBe(plan.version);
    expect(after?.workouts[0]?.name).toBe('Strength A');
    expect((await env.DB.prepare('SELECT COUNT(*) AS n FROM audit_log WHERE user_id=?1').bind(userId).first<{ n: number }>())?.n)
      .toBe(beforeAudit?.n);
    expect((await env.DB.prepare('SELECT COUNT(*) AS n FROM notes WHERE user_id=?1').bind(userId).first<{ n: number }>())?.n)
      .toBe(beforeNotes?.n);
  });

  it('does not add history after account deletion has claimed the user', async () => {
    const { userId, plan } = await fixture('deletion fence');
    const before = await env.DB.prepare(
      'SELECT COUNT(*) AS n FROM plan_snapshots WHERE user_id=?1',
    ).bind(userId).first<{ n: number }>();
    await env.DB.prepare(
      `INSERT INTO account_deletion_intents
       (user_id,idempotency_key_sha256,apple_revocation,created_at)
       VALUES (?1,?2,'manual_required',?3)`,
    ).bind(userId, 'f'.repeat(64), Date.now()).run();
    expect(await updatePlanTree(env.DB, userId, {
      expected_version: plan.version,
      workouts: [{ name: 'Blocked', exercises: [] }],
    })).toMatchObject({ conflict: true });
    expect((await env.DB.prepare('SELECT COUNT(*) AS n FROM plan_snapshots WHERE user_id=?1').bind(userId).first<{ n: number }>())?.n)
      .toBe(before?.n);
    expect((await getPlanTree(env.DB, userId))?.version).toBe(plan.version);
  });

  it('deletes user-owned snapshots while retaining the deletion receipt', async () => {
    const { userId } = await fixture('snapshot deletion');
    expect(await deleteUserAccount(env.DB, userId, undefined, crypto.randomUUID()))
      .toMatchObject({ ok: true });
    expect(await env.DB.prepare('SELECT 1 FROM plan_snapshots WHERE user_id=?1').bind(userId).first())
      .toBeNull();
    expect(await env.DB.prepare('SELECT 1 FROM users WHERE id=?1').bind(userId).first()).toBeNull();
    expect(await env.DB.prepare('SELECT 1 FROM account_deletion_receipts WHERE user_id=?1').bind(userId).first())
      .not.toBeNull();
  });

  it('preserves historical session and set values while safely detaching replaced refs', async () => {
    const { userId, plan } = await fixture('historical refs');
    const day = plan.workouts[0]!;
    const slot = day.exercises[0]!;
    const session = await getOrCreateSession(env.DB, userId, plan.id, '2026-08-01', day.id);
    const setId = crypto.randomUUID();
    await env.DB.prepare(
      `INSERT INTO set_logs
       (id,session_id,exercise_id,template_exercise_id,set_index,weight,reps,is_warmup,logged_at,source)
       VALUES (?1,?2,?3,?4,1,135,5,0,?5,'ios')`,
    ).bind(setId, session.id, slot.exercise_id, slot.id, Date.now()).run();
    const changed = await updatePlanTree(env.DB, userId, {
      expected_version: plan.version,
      workouts: [{ name: 'Different', day_label: 'B', exercises: [
        { exercise: 'squat', target_sets: 3, target_reps: 5 },
      ] }],
    });
    if (!('plan' in changed)) throw new Error('changed_plan_failed');
    const restored = await restorePlanSnapshot(env.DB, userId, {
      plan_id: plan.id, snapshot_version: plan.version,
      expected_version: changed.plan.version, actor: 'ios',
    });
    expect(restored).toMatchObject({ ok: true });
    expect(await env.DB.prepare('SELECT workout_id,date FROM sessions WHERE id=?1').bind(session.id).first())
      .toEqual({ workout_id: null, date: '2026-08-01' });
    expect(await env.DB.prepare('SELECT template_exercise_id,weight,reps FROM set_logs WHERE id=?1').bind(setId).first())
      .toEqual({ template_exercise_id: null, weight: 135, reps: 5 });
  });

  it('keeps a large canonical snapshot within a measured portable bound', async () => {
    const { userId, plan } = await fixture('growth');
    const stored = (await getPlanSnapshot(env.DB, userId, plan.id, plan.version))!.parsed;
    stored.workouts = Array.from({ length: 50 }, (_, dayIndex) => ({
      ...structuredClone(stored.workouts[0]!), id: crypto.randomUUID(), name: `Day ${dayIndex}`,
      exercises: Array.from({ length: 20 }, (_, slotIndex) => ({
        ...structuredClone(stored.workouts[0]!.exercises[0]!), id: crypto.randomUUID(),
        order_index: slotIndex, cues: 'Controlled eccentric and consistent setup.',
      })),
    }));
    const bytes = new TextEncoder().encode(JSON.stringify(stored)).byteLength;
    console.log(JSON.stringify({ event: 'plan_snapshot_growth', workouts: 50, slots: 1000, bytes }));
    expect(bytes).toBeGreaterThan(100_000);
    expect(bytes).toBeLessThan(1_000_000);
  });

  it('rejects invalid legacy prescriptions and reports an adjustment write race as conflict', async () => {
    const invalidFixture = await fixture('invalid adjustment');
    const invalidSlot = invalidFixture.plan.workouts[0]!.exercises[0]!;
    await env.DB.prepare('UPDATE template_exercises SET target_sets=?2 WHERE id=?1')
      .bind(invalidSlot.id, 'bad').run();
    expect(await adjustToday(env.DB, invalidFixture.userId, 'reduce_volume'))
      .toMatchObject({ error: 'invalid_fields' });
    expect((await getPlanTree(env.DB, invalidFixture.userId))?.version).toBe(invalidFixture.plan.version);

    const overflow = await fixture('adjustment overflow');
    const overflowPlan = await updatePlanTree(env.DB, overflow.userId, {
      expected_version: overflow.plan.version,
      workouts: [{ name: 'Assisted', exercises: [
        { exercise: 'pull-up', target_sets: 3, target_reps: 5, target_weight: -Number.MAX_VALUE },
      ] }],
    });
    if (!('plan' in overflowPlan)) throw new Error('overflow_plan_failed');
    expect(await adjustToday(env.DB, overflow.userId, 'reduce_intensity'))
      .toMatchObject({ error: 'invalid_fields', fields: [expect.stringContaining('target_weight')] });
    expect((await getPlanTree(env.DB, overflow.userId))?.version).toBe(overflowPlan.plan.version);

    const raced = await fixture('adjustment race');
    let injected = false;
    const racingDb = new Proxy(env.DB, {
      get(target, property) {
        if (property === 'batch') return async (statements: D1PreparedStatement[]) => {
          if (!injected) {
            injected = true;
            const concurrent = await updatePlanTree(env.DB, raced.userId, {
              expected_version: raced.plan.version,
              name: 'Concurrent winner',
              workouts: [{ name: 'Winner', exercises: [] }],
            });
            if (!('plan' in concurrent)) throw new Error('concurrent_write_failed');
          }
          return target.batch(statements);
        };
        const value = Reflect.get(target, property, target);
        return typeof value === 'function' ? value.bind(target) : value;
      },
    }) as D1Database;
    expect(await adjustToday(racingDb, raced.userId, 'reduce_volume'))
      .toMatchObject({ conflict: true, current_version: raced.plan.version + 1 });
  });

  it('refuses to restore an invalid legacy baseline after a valid repair', async () => {
    const { userId, plan } = await fixture('invalid restore');
    const slot = plan.workouts[0]!.exercises[0]!;
    await env.DB.prepare('DELETE FROM plan_snapshots WHERE plan_id=?1').bind(plan.id).run();
    await env.DB.prepare('UPDATE template_exercises SET target_sets=?2,target_rpe=?3 WHERE id=?1')
      .bind(slot.id, 'three', 99).run();
    const repaired = await updatePlanTree(env.DB, userId, {
      expected_version: plan.version,
      workouts: [{ name: 'Strength A', day_label: 'A', exercises: [
        { exercise: 'bench', target_sets: 3, target_reps: 5, target_rpe: 8 },
      ] }],
    });
    if (!('plan' in repaired)) throw new Error('repair_failed');
    const beforeAudit = await env.DB.prepare('SELECT COUNT(*) AS n FROM audit_log WHERE user_id=?1')
      .bind(userId).first<{ n: number }>();
    const beforeSnapshots = await env.DB.prepare('SELECT COUNT(*) AS n FROM plan_snapshots WHERE user_id=?1')
      .bind(userId).first<{ n: number }>();
    expect(await restorePlanSnapshot(env.DB, userId, {
      plan_id: plan.id, snapshot_version: plan.version,
      expected_version: repaired.plan.version, actor: 'ios',
    })).toMatchObject({ error: 'invalid_fields' });
    expect((await getPlanTree(env.DB, userId))?.version).toBe(repaired.plan.version);
    expect((await env.DB.prepare('SELECT COUNT(*) AS n FROM audit_log WHERE user_id=?1').bind(userId).first<{ n: number }>())?.n)
      .toBe(beforeAudit?.n);
    expect((await env.DB.prepare('SELECT COUNT(*) AS n FROM plan_snapshots WHERE user_id=?1').bind(userId).first<{ n: number }>())?.n)
      .toBe(beforeSnapshots?.n);
  });

  it('returns an explicit conflict after both legacy slot-patch claims lose', async () => {
    const { userId, plan } = await fixture('slot retry exhaustion');
    const slot = plan.workouts[0]!.exercises[0]!;
    const before = await env.DB.prepare(
      `SELECT
        (SELECT COUNT(*) FROM audit_log WHERE user_id=?1) AS audits,
        (SELECT COUNT(*) FROM plan_snapshots WHERE user_id=?1) AS snapshots`,
    ).bind(userId).first<{ audits: number; snapshots: number }>();
    let losses = 0;
    const losingDb = new Proxy(env.DB, {
      get(target, property) {
        if (property === 'batch') return async (statements: D1PreparedStatement[]) => {
          losses += 1;
          await env.DB.prepare('UPDATE plans SET version=version+1 WHERE id=?1')
            .bind(plan.id).run();
          return target.batch(statements);
        };
        const value = Reflect.get(target, property, target);
        return typeof value === 'function' ? value.bind(target) : value;
      },
    }) as D1Database;
    expect(await updateExercise(losingDb, userId, {
      template_exercise_id: slot.id,
    }, { target_weight: 145 }, {
      actor: 'ios', operation: 'update_exercise', args: { target_weight: 145 },
    })).toEqual({ conflict: true, current_version: plan.version + 2 });
    expect(losses).toBe(2);
    expect(await env.DB.prepare('SELECT target_weight FROM template_exercises WHERE id=?1')
      .bind(slot.id).first()).toEqual({ target_weight: 135 });
    expect(await env.DB.prepare(
      `SELECT
        (SELECT COUNT(*) FROM audit_log WHERE user_id=?1) AS audits,
        (SELECT COUNT(*) FROM plan_snapshots WHERE user_id=?1) AS snapshots`,
    ).bind(userId).first()).toEqual(before);
  });
});
