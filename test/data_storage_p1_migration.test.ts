import { applyD1Migrations, env } from 'cloudflare:test';
import { expect, it } from 'vitest';

import { runWorkoutWriteBatch } from '../src/workout-write-fence';

type TestMigration = { name: string; queries: string[] };

it('0034 backfills cursor ownership under the active fence and preserves legacy writes', async () => {
  const futureLoggedAt = Date.parse('2100-01-01T00:00:00Z');
  const migrations = env.TEST_MIGRATIONS as TestMigration[];
  const p1Index = migrations.findIndex((migration) => migration.name.includes('0034'));
  expect(p1Index, '0034 migration missing from TEST_MIGRATIONS').toBeGreaterThan(0);
  const p1 = migrations[p1Index]!;

  await applyD1Migrations(env.DB, migrations.slice(0, p1Index));

  const userA = crypto.randomUUID();
  const userB = crypto.randomUUID();
  const planA = crypto.randomUUID();
  const planB = crypto.randomUUID();
  const dayA = crypto.randomUUID();
  const oldSlot = crypto.randomUUID();
  const newSlot = crypto.randomUUID();
  const sessionA = crypto.randomUUID();
  const sessionB = crypto.randomUUID();
  const discardSession = crypto.randomUUID();
  const liveSet = crypto.randomUUID();
  const softDeleteSet = crypto.randomUUID();
  const discardSet = crypto.randomUUID();
  const deletedSet = crypto.randomUUID();
  const liveActivity = crypto.randomUUID();
  const deletedActivity = crypto.randomUUID();
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO users (id,apple_sub,display_name,created_at)
       VALUES (?1,?2,'P1 A',10)`,
    ).bind(userA, `sub-${userA}`),
    env.DB.prepare(
      `INSERT INTO users (id,apple_sub,display_name,created_at)
       VALUES (?1,?2,'P1 B',10)`,
    ).bind(userB, `sub-${userB}`),
    env.DB.prepare(
      `INSERT INTO plans (id,user_id,name,status,version,created_at,updated_at)
       VALUES (?1,?2,'P1 A','active',1,10,10)`,
    ).bind(planA, userA),
    env.DB.prepare(
      `INSERT INTO plans (id,user_id,name,status,version,created_at,updated_at)
       VALUES (?1,?2,'P1 B','active',1,10,10)`,
    ).bind(planB, userB),
    env.DB.prepare(
      `INSERT INTO day_templates
         (id,plan_id,day_label,name,order_index,created_at,updated_at)
       VALUES (?1,?2,'A','P1 day',0,10,10)`,
    ).bind(dayA, planA),
    env.DB.prepare(
      `INSERT INTO template_exercises
         (id,day_template_id,exercise_id,order_index,target_sets,target_reps,rest_seconds,created_at,updated_at)
       VALUES (?1,?2,'ex_bench',0,3,5,120,10,10)`,
    ).bind(oldSlot, dayA),
    env.DB.prepare(
      `INSERT INTO template_exercises
         (id,day_template_id,exercise_id,order_index,target_sets,target_reps,rest_seconds,created_at,updated_at)
       VALUES (?1,?2,'ex_bench',1,3,5,120,10,10)`,
    ).bind(newSlot, dayA),
    env.DB.prepare(
      `INSERT INTO sessions (id,user_id,plan_id,date,status,created_at,updated_at)
       VALUES (?1,?2,?3,'2026-09-01','in_progress',10,10)`,
    ).bind(sessionA, userA, planA),
    env.DB.prepare(
      `INSERT INTO sessions (id,user_id,plan_id,date,status,created_at,updated_at)
       VALUES (?1,?2,?3,'2026-09-02','completed',10,10)`,
    ).bind(sessionB, userB, planB),
    env.DB.prepare(
      `INSERT INTO sessions (id,user_id,plan_id,date,status,created_at,updated_at)
       VALUES (?1,?2,?3,'2026-09-03','in_progress',10,10)`,
    ).bind(discardSession, userA, planA),
    env.DB.prepare(
      `INSERT INTO set_logs
         (id,session_id,exercise_id,template_exercise_id,set_index,weight,reps,logged_at,source)
       VALUES (?1,?2,'ex_bench',?3,1,100,5,?4,'ios')`,
    ).bind(liveSet, sessionA, oldSlot, futureLoggedAt),
    env.DB.prepare(
      `INSERT INTO set_logs
         (id,session_id,exercise_id,set_index,weight,reps,logged_at,source)
       VALUES (?1,?2,'ex_bench',2,100,5,300,'ios')`,
    ).bind(softDeleteSet, sessionA),
    env.DB.prepare(
      `INSERT INTO set_logs
         (id,session_id,exercise_id,set_index,weight,reps,logged_at,source)
       VALUES (?1,?2,'ex_bench',1,100,5,400,'ios')`,
    ).bind(discardSet, discardSession),
    env.DB.prepare(
      `INSERT INTO set_logs
         (id,session_id,exercise_id,set_index,weight,reps,logged_at,source,deleted_at)
       VALUES (?1,?2,'ex_bench',1,100,5,200,'ios',250)`,
    ).bind(deletedSet, sessionB),
    env.DB.prepare(
      `INSERT INTO activities
         (id,user_id,date,type,logged_at,source)
       VALUES (?1,?2,'2026-09-01','walk',?3,'ios')`,
    ).bind(liveActivity, userA, futureLoggedAt),
    env.DB.prepare(
      `INSERT INTO activities
         (id,user_id,date,type,logged_at,source,deleted_at)
       VALUES (?1,?2,'2026-09-02','yoga',60,'ios',70)`,
    ).bind(deletedActivity, userB),
  ]);

  await env.DB.prepare(
    'UPDATE workout_write_fence SET enabled=1, activated_at=20 WHERE id=1',
  ).run();
  await applyD1Migrations(env.DB, [p1]);

  const sets = await env.DB.prepare(
    `SELECT id,user_id,updated_at FROM set_logs
      WHERE id IN (?1,?2,?3,?4) ORDER BY id`,
  )
    .bind(liveSet, softDeleteSet, discardSet, deletedSet)
    .all<{ id: string; user_id: string; updated_at: number }>();
  expect(sets.results.map(({ id, user_id }) => ({ id, user_id }))).toEqual(
    [
      { id: liveSet, user_id: userA },
      { id: softDeleteSet, user_id: userA },
      { id: discardSet, user_id: userA },
      { id: deletedSet, user_id: userB },
    ].sort((a, b) => a.id.localeCompare(b.id)),
  );
  expect(new Set(sets.results.map((row) => row.updated_at))).toHaveLength(1);
  expect(sets.results[0]!.updated_at).toBeGreaterThan(250);
  expect(sets.results[0]!.updated_at).toBeLessThan(futureLoggedAt);

  const activities = await env.DB.prepare(
    `SELECT id,updated_at FROM activities
      WHERE id IN (?1,?2) ORDER BY id`,
  )
    .bind(liveActivity, deletedActivity)
    .all<{ id: string; updated_at: number }>();
  expect(activities.results.map((row) => row.id).sort()).toEqual(
    [liveActivity, deletedActivity].sort(),
  );
  expect(new Set(activities.results.map((row) => row.updated_at))).toHaveLength(1);
  expect(activities.results[0]!.updated_at).toBeGreaterThan(70);
  expect(activities.results[0]!.updated_at).toBeLessThan(futureLoggedAt);

  const columns = await env.DB.prepare("PRAGMA table_info('set_logs')")
    .all<{ name: string; notnull: number }>();
  expect(columns.results.find((column) => column.name === 'user_id')?.notnull).toBe(1);
  expect(columns.results.find((column) => column.name === 'updated_at')?.notnull).toBe(1);
  expect(
    await env.DB.prepare(
      `SELECT COUNT(*) AS count
         FROM set_logs AS sl
         JOIN sessions AS s ON s.id = sl.session_id
        WHERE sl.user_id IS NOT s.user_id`,
    ).first(),
  ).toEqual({ count: 0 });
  expect(
    await env.DB.prepare(
      "SELECT COUNT(*) AS count FROM sqlite_master WHERE name = 'p1_set_log_backfill_assertion'",
    ).first(),
  ).toEqual({ count: 0 });
  expect(
    await env.DB.prepare('SELECT COUNT(*) AS count FROM workout_write_permit').first(),
  ).toEqual({ count: 0 });

  const readSet = (id: string) =>
    env.DB.prepare(
      `SELECT id,user_id,template_exercise_id,weight,reps,rpe,notes,
              logged_at,updated_at,deleted_at
         FROM set_logs WHERE id=?1`,
    )
      .bind(id)
      .first<{
        id: string;
        user_id: string;
        template_exercise_id: string | null;
        weight: number;
        reps: number;
        rpe: number | null;
        notes: string | null;
        logged_at: number;
        updated_at: number;
        deleted_at: number | null;
      }>();

  // Exact old-Worker correction shape: a mutable field changes without the
  // statement naming updated_at. The compatibility trigger advances only the
  // cursor and preserves ownership and client-authored event time.
  const initialLive = await readSet(liveSet);
  await runWorkoutWriteBatch(env.DB, [
    env.DB.prepare('UPDATE set_logs SET weight=?2 WHERE id=?1').bind(liveSet, 105),
  ]);
  const corrected = await readSet(liveSet);
  expect(corrected).toMatchObject({
    user_id: userA,
    weight: 105,
    logged_at: futureLoggedAt,
    template_exercise_id: oldSlot,
  });
  expect(corrected!.updated_at).toBeGreaterThan(initialLive!.updated_at);

  await runWorkoutWriteBatch(env.DB, [
    env.DB.prepare('UPDATE set_logs SET weight=?2 WHERE id=?1').bind(liveSet, 105),
  ]);
  expect((await readSet(liveSet))!.updated_at).toBe(corrected!.updated_at);

  // Exact old plan-rebuild and slot-delete shapes: remap a historical slot,
  // then detach it, without allowing either change to hide behind the cursor.
  await runWorkoutWriteBatch(env.DB, [
    env.DB.prepare(
      `UPDATE set_logs SET template_exercise_id=?2
        WHERE template_exercise_id=?1
          AND EXISTS (
            SELECT 1 FROM plans
             WHERE id=?3 AND user_id=?4 AND status='active' AND version=?5
          )`,
    ).bind(oldSlot, newSlot, planA, userA, 1),
  ]);
  const remapped = await readSet(liveSet);
  expect(remapped).toMatchObject({
    user_id: userA,
    logged_at: futureLoggedAt,
    template_exercise_id: newSlot,
  });
  expect(remapped!.updated_at).toBeGreaterThan(corrected!.updated_at);

  await runWorkoutWriteBatch(env.DB, [
    env.DB.prepare(
      'UPDATE set_logs SET template_exercise_id=NULL WHERE template_exercise_id=?1',
    ).bind(newSlot),
  ]);
  const detached = await readSet(liveSet);
  expect(detached).toMatchObject({
    user_id: userA,
    logged_at: futureLoggedAt,
    template_exercise_id: null,
  });
  expect(detached!.updated_at).toBeGreaterThan(remapped!.updated_at);

  // Both old deletion statements omit updated_at: patchSet targets an id,
  // while discardSession tombstones all live sets in the session.
  const oldSoftDeletedAt = Date.now();
  const softDeleteBefore = await readSet(softDeleteSet);
  await runWorkoutWriteBatch(env.DB, [
    env.DB.prepare('UPDATE set_logs SET deleted_at=?2 WHERE id=?1')
      .bind(softDeleteSet, oldSoftDeletedAt),
  ]);
  const softDeleted = await readSet(softDeleteSet);
  expect(softDeleted).toMatchObject({
    user_id: userA,
    logged_at: 300,
    deleted_at: oldSoftDeletedAt,
  });
  expect(softDeleted!.updated_at).toBeGreaterThan(softDeleteBefore!.updated_at);

  const oldDiscardedAt = oldSoftDeletedAt + 1;
  const discardBefore = await readSet(discardSet);
  await runWorkoutWriteBatch(env.DB, [
    env.DB.prepare(
      `UPDATE sessions SET status='discarded',updated_at=?2
        WHERE id=?1 AND status!='discarded' AND attempt=0`,
    ).bind(discardSession, oldDiscardedAt),
    env.DB.prepare(
      `UPDATE set_logs SET deleted_at=?2
        WHERE session_id=?1 AND deleted_at IS NULL
          AND EXISTS (
            SELECT 1 FROM sessions
             WHERE id=?1 AND status='discarded' AND attempt=0
          )`,
    ).bind(discardSession, oldDiscardedAt),
  ]);
  const discarded = await readSet(discardSet);
  expect(discarded).toMatchObject({
    user_id: userA,
    logged_at: 400,
    deleted_at: oldDiscardedAt,
  });
  expect(discarded!.updated_at).toBeGreaterThan(discardBefore!.updated_at);

  // A normal new-Worker statement that advances the cursor bypasses the
  // compatibility trigger exactly. If its server timestamp ties the prior
  // cursor, the statement performs one +1 monotonic bump without invoking the
  // trigger or inflating D1's logical change count.
  const explicitCursor = detached!.updated_at + 60_000;
  const [advancedWrite] = await runWorkoutWriteBatch(env.DB, [
    env.DB.prepare(
      'UPDATE set_logs SET notes=?2,updated_at=MAX(updated_at + 1,?3) WHERE id=?1',
    )
      .bind(liveSet, 'new Worker advanced', explicitCursor),
  ]);
  expect(advancedWrite!.meta.changes).toBe(1);
  expect(await readSet(liveSet)).toMatchObject({
    notes: 'new Worker advanced',
    updated_at: explicitCursor,
  });
  const [sameMsWrite] = await runWorkoutWriteBatch(env.DB, [
    env.DB.prepare(
      'UPDATE set_logs SET reps=?2,updated_at=MAX(updated_at + 1,?3) WHERE id=?1',
    )
      .bind(liveSet, 6, explicitCursor),
  ]);
  expect(sameMsWrite!.meta.changes).toBe(1);
  expect(await readSet(liveSet)).toMatchObject({
    reps: 6,
    updated_at: explicitCursor + 1,
  });

  const legacySet = crypto.randomUUID();
  await runWorkoutWriteBatch(env.DB, [
    env.DB.prepare(
      `INSERT INTO set_logs
       (id,session_id,exercise_id,set_index,weight,reps,logged_at,source)
       VALUES (?1,?2,'ex_bench',2,105,5,?3,'ios')`,
    ).bind(legacySet, sessionB, futureLoggedAt),
  ]);
  const insertedLegacySet = await env.DB.prepare(
    'SELECT user_id,logged_at,updated_at FROM set_logs WHERE id=?1',
  )
    .bind(legacySet)
    .first<{ user_id: string; logged_at: number; updated_at: number }>();
  expect(insertedLegacySet).toMatchObject({ user_id: userB, logged_at: futureLoggedAt });
  expect(insertedLegacySet!.updated_at).toBeGreaterThan(0);
  expect(insertedLegacySet!.updated_at).toBeLessThan(futureLoggedAt);

  const overlapDelta = await env.DB.prepare(
    `SELECT id FROM set_logs
      WHERE user_id=?1 AND updated_at>?2
      ORDER BY updated_at,id`,
  )
    .bind(userB, insertedLegacySet!.updated_at - 60_000)
    .all<{ id: string }>();
  expect(overlapDelta.results.map((row) => row.id)).toContain(legacySet);
  const crossedLegacyCursor = await env.DB.prepare(
    `SELECT id FROM set_logs
      WHERE user_id=?1 AND updated_at>?2
      ORDER BY updated_at,id`,
  )
    .bind(userB, insertedLegacySet!.updated_at)
    .all<{ id: string }>();
  expect(crossedLegacyCursor.results).toEqual([]);

  const legacyActivity = crypto.randomUUID();
  await env.DB.prepare(
    `INSERT INTO activities (id,user_id,date,type,logged_at,source)
     VALUES (?1,?2,'2026-09-03','walk',1,'ios')`,
  )
    .bind(legacyActivity, userA)
    .run();
  const insertedLegacyActivity = await env.DB.prepare(
    'SELECT updated_at FROM activities WHERE id=?1',
  )
    .bind(legacyActivity)
    .first<{ updated_at: number }>();
  expect(insertedLegacyActivity!.updated_at).toBeGreaterThan(1);
  const deletedAt = insertedLegacyActivity!.updated_at;
  await env.DB.prepare('UPDATE activities SET deleted_at=?2 WHERE id=?1')
    .bind(legacyActivity, deletedAt)
    .run();
  expect(
    await env.DB.prepare('SELECT deleted_at,updated_at FROM activities WHERE id=?1')
      .bind(legacyActivity)
      .first(),
  ).toEqual({ deleted_at: deletedAt, updated_at: deletedAt + 1 });

  const newWorkerActivity = crypto.randomUUID();
  const sameMsCursor = deletedAt + 1_000;
  await env.DB.prepare(
    `INSERT INTO activities
       (id,user_id,date,type,logged_at,source,updated_at)
     VALUES (?1,?2,'2026-09-04','walk',1,'ios',?3)`,
  )
    .bind(newWorkerActivity, userA, sameMsCursor)
    .run();
  const newWorkerDelete = await env.DB.prepare(
    `UPDATE activities
        SET deleted_at=?3,
            updated_at=MAX(updated_at + 1,?3)
      WHERE id=?1 AND user_id=?2 AND deleted_at IS NULL`,
  )
    .bind(newWorkerActivity, userA, sameMsCursor)
    .run();
  expect(newWorkerDelete.meta.changes).toBe(1);
  expect(
    await env.DB.prepare('SELECT deleted_at,updated_at FROM activities WHERE id=?1')
      .bind(newWorkerActivity)
      .first(),
  ).toEqual({ deleted_at: sameMsCursor, updated_at: sameMsCursor + 1 });

  const cursorBeforeRejectedUpdate = (await readSet(liveSet))!.updated_at;
  await expect(
    env.DB.prepare("UPDATE set_logs SET notes='unpermitted' WHERE id=?1")
      .bind(liveSet)
      .run(),
  ).rejects.toThrow(/workout_write_fence_active/);
  expect((await readSet(liveSet))!.updated_at).toBe(cursorBeforeRejectedUpdate);
  expect(
    await env.DB.prepare('SELECT COUNT(*) AS count FROM workout_write_permit').first(),
  ).toEqual({ count: 0 });

  const schema = await env.DB.prepare(
    `SELECT type,name FROM sqlite_master
      WHERE name IN (
        'set_logs_workout_write_fence_update',
        'set_logs_legacy_delta_fields',
        'set_logs_legacy_update_cursor',
        'activities_legacy_insert_cursor',
        'activities_legacy_delete_cursor',
        'ix_sets_user_updated',
        'ix_sessions_user_updated',
        'ix_activities_user_updated'
      ) ORDER BY name`,
  ).all<{ type: string; name: string }>();
  expect(schema.results).toHaveLength(8);
});
