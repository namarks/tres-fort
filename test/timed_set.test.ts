// set_logs.is_timed (migration 0024): a per-set timed-hold flag so a
// duration-pinned slot renders consistently as timed regardless of the
// exercise's catalog modality, without legacy incidental durations causing
// false positives. Default at log time = exercise modality; an explicit flag
// overrides (the path a target_duration_s hold on a non-timed exercise uses).
import { env, applyD1Migrations } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { logSet, getOrCreateSession, getSetsForSession } from '../src/db';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

async function setup() {
  const userId = crypto.randomUUID();
  const planId = crypto.randomUUID();
  const ts = Date.now();
  await env.DB.prepare(
    'INSERT INTO users (id,apple_sub,email,display_name,created_at) VALUES (?1,?2,?3,?4,?5)',
  )
    .bind(userId, `sub-${userId}`, null, 'T', ts)
    .run();
  await env.DB.prepare(
    "INSERT INTO plans (id,user_id,name,status,version,meta,created_at,updated_at) VALUES (?1,?2,'P','active',1,NULL,?3,?3)",
  )
    .bind(planId, userId, ts)
    .run();
  // Pull a timed-modality and a non-timed exercise from the seeded catalog.
  const timedEx = (
    await env.DB.prepare("SELECT id FROM exercises WHERE modality = 'timed' LIMIT 1").first<{
      id: string;
    }>()
  )?.id;
  const repEx = (
    await env.DB.prepare("SELECT id FROM exercises WHERE modality = 'barbell' LIMIT 1").first<{
      id: string;
    }>()
  )?.id;
  if (!timedEx || !repEx) throw new Error('seed missing timed/barbell exercise');
  const session = await getOrCreateSession(env.DB, userId, planId, '2026-06-15', null);
  return { userId, timedEx, repEx, session };
}

const args = (sessionId: string, exId: string, extra: Record<string, unknown> = {}) => ({
  id: crypto.randomUUID(),
  session_id: sessionId,
  exercise_id: exId,
  set_index: 1,
  weight: 0,
  reps: 1,
  source: 'ios' as const,
  ...extra,
});

describe('set_logs.is_timed', () => {
  it('defaults is_timed from the exercise catalog modality', async () => {
    const { userId, timedEx, repEx, session } = await setup();
    const timed = await logSet(env.DB, userId, args(session.id, timedEx, { duration_s: 45 }));
    expect(timed.set.is_timed).toBe(1);
    const rep = await logSet(env.DB, userId, args(session.id, repEx, { weight: 225, reps: 5 }));
    expect(rep.set.is_timed).toBe(0);
  });

  it('honors an explicit is_timed flag over the modality default', async () => {
    const { userId, timedEx, repEx, session } = await setup();
    // A duration-pinned hold on a NON-timed exercise: explicitly timed.
    const pinned = await logSet(
      env.DB,
      userId,
      args(session.id, repEx, { is_timed: true, duration_s: 60 }),
    );
    expect(pinned.set.is_timed).toBe(1);
    // Explicitly NOT timed on a timed-modality exercise.
    const forcedRep = await logSet(env.DB, userId, args(session.id, timedEx, { is_timed: false }));
    expect(forcedRep.set.is_timed).toBe(0);
  });

  it('persists is_timed for read-back via getSetsForSession', async () => {
    const { userId, timedEx, session } = await setup();
    await logSet(env.DB, userId, args(session.id, timedEx, { duration_s: 30 }));
    const sets = await getSetsForSession(env.DB, session.id);
    expect(sets).toHaveLength(1);
    expect(sets[0]!.is_timed).toBe(1);
  });
});
