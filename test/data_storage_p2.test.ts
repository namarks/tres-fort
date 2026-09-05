import { applyD1Migrations, env } from 'cloudflare:test';
import { afterEach, beforeAll, describe, expect, it, vi } from 'vitest';
import {
  createD1UsageObserver,
  dedupeHealthKitAgainstIntervals,
  getState,
  syncExternalActivities,
  syncExternalEvents,
  upsertHealthKitActivity,
} from '../src/db';
import type { Fetcher } from '../src/intervals';
import type { Env } from '../src/types';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

afterEach(() => {
  vi.useRealTimers();
});

const TODAY = '2026-05-18';

function payload(rows: unknown[]): Fetcher {
  return async () => ({
    ok: true,
    status: 200,
    json: async () => rows,
  });
}

async function freshUser(): Promise<string> {
  const id = crypto.randomUUID();
  await env.DB.prepare(
    'INSERT INTO users (id,apple_sub,email,display_name,created_at) VALUES (?1,?2,NULL,?3,?4)',
  )
    .bind(id, `sub-${id}`, 'P2 Rider', Date.now())
    .run();
  return id;
}

const plannedEvent = (over: Record<string, unknown> = {}) => ({
  id: 'event-1',
  category: 'WORKOUT',
  type: 'Ride',
  start_date_local: '2026-05-20T06:00:00',
  name: 'Endurance ride',
  description: 'Z2',
  moving_time: 7200,
  icu_training_load: 90,
  icu_intensity: 0.7,
  ...over,
});

const completedActivity = (over: Record<string, unknown> = {}) => ({
  id: 'activity-1',
  type: 'Ride',
  start_date_local: '2026-05-15T07:00:00',
  name: 'Morning ride',
  moving_time: 5400,
  elapsed_time: 5700,
  distance: 42000,
  icu_average_watts: 185,
  icu_weighted_avg_watts: 205,
  average_heartrate: 142,
  max_heartrate: 171,
  icu_training_load: 88,
  icu_intensity: 0.74,
  calories: 760,
  total_elevation_gain: 430,
  ...over,
});

const healthKitActivity = (over: Record<string, unknown> = {}) => ({
  id: crypto.randomUUID(),
  date: '2026-05-15',
  start_date_local_ms: Date.parse('2026-05-15T07:00:30Z'),
  kind: 'ride',
  name: 'Morning ride',
  moving_time_sec: 5400,
  elapsed_time_sec: 5700,
  distance_m: 42000,
  average_watts: 185,
  average_hr: 142,
  max_hr: 171,
  calories: 760,
  elevation_gain_m: 430,
  raw: '{"source":"healthkit"}',
  ...over,
});

describe('P2 intervals cache write elision', () => {
  it('advertises the change-aware external cursor contract in state responses', async () => {
    const state = await getState(env.DB, await freshUser(), 0, 0);
    expect(state.external_sync_cursors_version).toBe(2);
  });

  it('materializes each constant-bind reconcile id list once instead of correlating it per row', async () => {
    const seenJson = JSON.stringify(['intervals:user:a', 'intervals:user:b']);
    const eventPlan = await env.DB.prepare(
      `EXPLAIN QUERY PLAN
       SELECT id FROM external_events
        WHERE user_id=?1 AND deleted_at IS NULL AND date>=?2 AND date<=?3
          AND id NOT IN (SELECT CAST(value AS TEXT) FROM json_each(?4))`,
    )
      .bind('user', TODAY, TODAY, seenJson)
      .all<{ detail: string }>();
    const activityPlan = await env.DB.prepare(
      `EXPLAIN QUERY PLAN
       SELECT id FROM external_activities
        WHERE user_id=?1 AND source='intervals' AND deleted_at IS NULL
          AND date>=?2 AND date<=?3
          AND id NOT IN (SELECT CAST(value AS TEXT) FROM json_each(?4))`,
    )
      .bind('user', TODAY, TODAY, seenJson)
      .all<{ detail: string }>();

    for (const result of [eventPlan, activityPlan]) {
      const details = result.results.map((row) => row.detail).join('\n');
      expect(details).toMatch(/LIST SUBQUERY/);
      expect(details).toMatch(/json_each/);
      expect(details).not.toMatch(/CORRELATED/);
    }
  });

  it('events: raw-only provider drift writes zero rows and preserves raw and synced_at', async () => {
    const userId = await freshUser();
    const firstResponse = plannedEvent({
      provider_revision: 1,
      provider_metadata: { source: 'calendar', color: 'blue' },
    });
    await syncExternalEvents(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([firstResponse]),
    });

    const id = `intervals:${userId}:event-1`;
    const before = await env.DB.prepare(
      'SELECT raw, synced_at FROM external_events WHERE id = ?1',
    )
      .bind(id)
      .first<{ raw: string; synced_at: number }>();

    // Same extracted values, but a different unknown provider field and key
    // order. JSON serialization changes even though the app-facing row does not.
    const secondResponse = {
      provider_metadata: { color: 'green', source: 'calendar' },
      ...plannedEvent(),
      provider_revision: 2,
    };
    expect(JSON.stringify(secondResponse)).not.toBe(before!.raw);

    const observed = createD1UsageObserver(env.DB);
    const result = await syncExternalEvents(observed.db, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([secondResponse]),
    });
    expect(result).toMatchObject({ status: 'ok', synced: 1 });
    expect(observed.usage.rows_written).toBe(0);

    const after = await env.DB.prepare(
      'SELECT raw, synced_at FROM external_events WHERE id = ?1',
    )
      .bind(id)
      .first<{ raw: string; synced_at: number }>();
    expect(after).toEqual(before);
  });

  it('events: an extracted change or resurrection writes once and advances the cursor', async () => {
    const sameMs = Date.parse('2036-05-18T12:00:00Z');
    vi.setSystemTime(sameMs);
    const userId = await freshUser();
    const base = plannedEvent();
    await syncExternalEvents(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([base]),
    });
    const id = `intervals:${userId}:event-1`;
    const inserted = await env.DB.prepare(
      'SELECT synced_at FROM external_events WHERE id = ?1',
    )
      .bind(id)
      .first<{ synced_at: number }>();
    expect(inserted!.synced_at).toBe(sameMs);

    const changedResponse = plannedEvent({ description: 'Recovery spin', provider_revision: 2 });
    const changed = createD1UsageObserver(env.DB);
    await syncExternalEvents(changed.db, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([changedResponse]),
    });
    // One logical row mutation maintains the date and P2 cursor indexes.
    expect(changed.usage.rows_written).toBe(3);
    const changedRow = await env.DB.prepare(
      'SELECT description, raw, synced_at FROM external_events WHERE id = ?1',
    )
      .bind(id)
      .first<{ description: string; raw: string; synced_at: number }>();
    expect(changedRow).toMatchObject({
      description: 'Recovery spin',
      raw: JSON.stringify(changedResponse),
    });
    expect(changedRow!.synced_at).toBe(sameMs + 1);

    await syncExternalEvents(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([]),
    });
    const tombstone = await env.DB.prepare(
      'SELECT raw, synced_at, deleted_at FROM external_events WHERE id = ?1',
    )
      .bind(id)
      .first<{ raw: string; synced_at: number; deleted_at: number }>();
    expect(tombstone!.deleted_at).toBe(tombstone!.synced_at);
    expect(tombstone!.synced_at).toBe(sameMs + 2);

    const resurrectionResponse = {
      provider_revision: 3,
      ...changedResponse,
      provider_metadata: { changed_without_extracted_change: true },
    };
    const resurrected = createD1UsageObserver(env.DB);
    await syncExternalEvents(resurrected.db, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([resurrectionResponse]),
    });
    expect(resurrected.usage.rows_written).toBe(3);
    const liveAgain = await env.DB.prepare(
      'SELECT raw, synced_at, deleted_at FROM external_events WHERE id = ?1',
    )
      .bind(id)
      .first<{ raw: string; synced_at: number; deleted_at: number | null }>();
    expect(liveAgain!.deleted_at).toBeNull();
    expect(liveAgain!.synced_at).toBe(sameMs + 3);
    // Resurrection is a real row change, but raw itself still changes only
    // when an extracted provider field changed.
    expect(liveAgain!.raw).toBe(tombstone!.raw);
  });

  it('activities: raw-only provider drift writes zero rows and preserves raw and synced_at', async () => {
    const userId = await freshUser();
    const firstResponse = completedActivity({
      provider_revision: 1,
      provider_metadata: { source: 'strava', visibility: 'followers' },
    });
    await syncExternalActivities(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([firstResponse]),
    });

    const id = `intervals:activity:${userId}:activity-1`;
    const before = await env.DB.prepare(
      'SELECT raw, synced_at FROM external_activities WHERE id = ?1',
    )
      .bind(id)
      .first<{ raw: string; synced_at: number }>();

    const secondResponse = {
      provider_metadata: { visibility: 'private', source: 'strava' },
      ...completedActivity(),
      provider_revision: 2,
    };
    expect(JSON.stringify(secondResponse)).not.toBe(before!.raw);

    const observed = createD1UsageObserver(env.DB);
    const result = await syncExternalActivities(observed.db, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([secondResponse]),
    });
    expect(result).toMatchObject({ status: 'ok', synced: 1 });
    expect(observed.usage.rows_written).toBe(0);

    const after = await env.DB.prepare(
      'SELECT raw, synced_at FROM external_activities WHERE id = ?1',
    )
      .bind(id)
      .first<{ raw: string; synced_at: number }>();
    expect(after).toEqual(before);
  });

  it('activities: an extracted change or resurrection writes once and advances the cursor', async () => {
    const sameMs = Date.parse('2036-05-18T12:00:00Z');
    vi.setSystemTime(sameMs);
    const userId = await freshUser();
    const base = completedActivity();
    await syncExternalActivities(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([base]),
    });
    const id = `intervals:activity:${userId}:activity-1`;
    const inserted = await env.DB.prepare(
      'SELECT synced_at FROM external_activities WHERE id = ?1',
    )
      .bind(id)
      .first<{ synced_at: number }>();
    expect(inserted!.synced_at).toBe(sameMs);

    const changedResponse = completedActivity({ icu_average_watts: 212, provider_revision: 2 });
    const changed = createD1UsageObserver(env.DB);
    await syncExternalActivities(changed.db, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([changedResponse]),
    });
    expect(changed.usage.rows_written).toBe(3);
    const changedRow = await env.DB.prepare(
      'SELECT average_watts, raw, synced_at FROM external_activities WHERE id = ?1',
    )
      .bind(id)
      .first<{ average_watts: number; raw: string; synced_at: number }>();
    expect(changedRow).toMatchObject({
      average_watts: 212,
      raw: JSON.stringify(changedResponse),
    });
    expect(changedRow!.synced_at).toBe(sameMs + 1);

    await syncExternalActivities(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([]),
    });
    const tombstone = await env.DB.prepare(
      'SELECT raw, synced_at, deleted_at FROM external_activities WHERE id = ?1',
    )
      .bind(id)
      .first<{ raw: string; synced_at: number; deleted_at: number }>();
    expect(tombstone!.deleted_at).toBe(tombstone!.synced_at);
    expect(tombstone!.synced_at).toBe(sameMs + 2);

    const resurrectionResponse = {
      provider_revision: 3,
      ...changedResponse,
      provider_metadata: { changed_without_extracted_change: true },
    };
    const resurrected = createD1UsageObserver(env.DB);
    await syncExternalActivities(resurrected.db, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([resurrectionResponse]),
    });
    expect(resurrected.usage.rows_written).toBe(3);
    const liveAgain = await env.DB.prepare(
      'SELECT raw, synced_at, deleted_at FROM external_activities WHERE id = ?1',
    )
      .bind(id)
      .first<{ raw: string; synced_at: number; deleted_at: number | null }>();
    expect(liveAgain!.deleted_at).toBeNull();
    expect(liveAgain!.synced_at).toBe(sameMs + 3);
    expect(liveAgain!.raw).toBe(tombstone!.raw);
  });

  it('HealthKit: an identical or raw-only retry is a no-op, while a real revision advances', async () => {
    const sameMs = Date.parse('2036-05-18T12:00:00Z');
    vi.setSystemTime(sameMs);
    const userId = await freshUser();
    const input = healthKitActivity();
    const first = await upsertHealthKitActivity(env.DB, userId, input);
    expect(first.synced_at).toBe(sameMs);

    const retry = createD1UsageObserver(env.DB);
    const retried = await upsertHealthKitActivity(retry.db, userId, input);
    expect(retry.usage.rows_written).toBe(0);
    expect(retried).toMatchObject({
      id: first.id,
      synced_at: first.synced_at,
      deleted_at: first.deleted_at,
      canonical: first.canonical,
      duplicate_of: first.duplicate_of,
      raw: first.raw,
    });

    const rawOnly = createD1UsageObserver(env.DB);
    const rawOnlyResult = await upsertHealthKitActivity(rawOnly.db, userId, {
      ...input,
      raw: '{"source":"healthkit","irrelevant_revision":2}',
    });
    expect(rawOnly.usage.rows_written).toBe(0);
    expect(rawOnlyResult.raw).toBe(first.raw);
    expect(rawOnlyResult.synced_at).toBe(first.synced_at);

    const changed = createD1UsageObserver(env.DB);
    const changedResult = await upsertHealthKitActivity(changed.db, userId, {
      ...input,
      average_hr: 150,
      raw: '{"source":"healthkit","summary_revision":2}',
    });
    expect(changed.usage.rows_written).toBe(3);
    expect(changedResult.average_hr).toBe(150);
    expect(changedResult.raw).toBe('{"source":"healthkit","summary_revision":2}');
    expect(changedResult.synced_at).toBe(sameMs + 1);
  });

  it('HealthKit: an identical retry preserves dedup-retired state and provenance', async () => {
    const sameMs = Date.parse('2036-05-15T12:00:00Z');
    vi.setSystemTime(sameMs);
    const userId = await freshUser();
    const input = healthKitActivity();
    const intervalsId = `intervals:activity:${userId}:winner`;
    await env.DB.prepare(
      `INSERT INTO external_activities
         (id,user_id,source,external_id,date,start_date_local_ms,kind,name,
          synced_at,deleted_at,canonical,duplicate_of)
       VALUES (?1,?2,'intervals','winner',?3,?4,?5,'Intervals winner',1,NULL,1,NULL)`,
    )
      .bind(intervalsId, userId, input.date, input.start_date_local_ms, input.kind)
      .run();

    const retired = await upsertHealthKitActivity(env.DB, userId, input);
    expect(retired).toMatchObject({
      synced_at: sameMs + 1,
      deleted_at: sameMs + 1,
      canonical: 0,
      duplicate_of: intervalsId,
    });

    const retry = createD1UsageObserver(env.DB);
    const retried = await upsertHealthKitActivity(retry.db, userId, input);
    expect(retry.usage.rows_written).toBe(0);
    expect(retried).toMatchObject({
      id: retired.id,
      synced_at: retired.synced_at,
      deleted_at: retired.deleted_at,
      canonical: 0,
      duplicate_of: intervalsId,
      raw: retired.raw,
    });
  });

  it('dedupe winner changes and restoration advance past a future cursor', async () => {
    const clockNow = Date.parse('2036-05-15T12:00:00Z');
    vi.setSystemTime(clockNow);
    const userId = await freshUser();
    const start = Date.parse('2036-05-15T07:00:00Z');
    const healthKitId = `healthkit:activity:${userId}:clock-edge`;
    const oldWinner = `intervals:activity:${userId}:old-winner`;
    const newWinner = `intervals:activity:${userId}:new-winner`;
    const futureCursor = clockNow + 60_000;
    await env.DB.prepare(
      `INSERT INTO external_activities
         (id,user_id,source,external_id,date,start_date_local_ms,kind,name,
          synced_at,deleted_at,canonical,duplicate_of)
       VALUES
         (?1,?2,'healthkit','clock-edge','2036-05-15',?3,'ride','HealthKit',?4,?4,0,?5),
         (?5,?2,'intervals','old-winner','2036-05-15',?6,'ride','Old winner',1,NULL,1,NULL),
         (?7,?2,'intervals','new-winner','2036-05-15',?8,'ride','New winner',1,NULL,1,NULL)`,
    )
      .bind(
        healthKitId,
        userId,
        start,
        futureCursor,
        oldWinner,
        start + 90_000,
        newWinner,
        start + 30_000,
      )
      .run();

    expect(await dedupeHealthKitAgainstIntervals(env.DB, userId)).toBe(1);
    const repointed = await env.DB.prepare(
      'SELECT synced_at,deleted_at,duplicate_of FROM external_activities WHERE id=?1',
    )
      .bind(healthKitId)
      .first<{ synced_at: number; deleted_at: number; duplicate_of: string }>();
    expect(repointed).toEqual({
      synced_at: futureCursor + 1,
      deleted_at: futureCursor,
      duplicate_of: newWinner,
    });
    const repointDelta = await getState(env.DB, userId, 0, 0, 0, futureCursor);
    expect(repointDelta.external_activities).toEqual([
      expect.objectContaining({
        id: healthKitId,
        synced_at: futureCursor + 1,
        duplicate_of: newWinner,
      }),
    ]);

    await env.DB.prepare(
      "UPDATE external_activities SET deleted_at=1 WHERE user_id=?1 AND source='intervals'",
    )
      .bind(userId)
      .run();
    expect(await dedupeHealthKitAgainstIntervals(env.DB, userId)).toBe(1);
    const restored = await env.DB.prepare(
      'SELECT synced_at,deleted_at,canonical,duplicate_of FROM external_activities WHERE id=?1',
    )
      .bind(healthKitId)
      .first<{
        synced_at: number;
        deleted_at: number | null;
        canonical: number;
        duplicate_of: string | null;
      }>();
    expect(restored).toEqual({
      synced_at: futureCursor + 2,
      deleted_at: null,
      canonical: 1,
      duplicate_of: null,
    });
    const restoreDelta = await getState(
      env.DB,
      userId,
      0,
      0,
      0,
      repointed!.synced_at,
    );
    expect(restoreDelta.external_activities).toEqual([
      expect.objectContaining({
        id: healthKitId,
        synced_at: futureCursor + 2,
        deleted_at: null,
        canonical: 1,
        duplicate_of: null,
      }),
    ]);
  });

  it('keeps same-id/time correction, tombstone, resurrection, and dedup tenant-scoped', async () => {
    const userA = await freshUser();
    const userB = await freshUser();
    const sharedActivity = completedActivity({ id: 'shared-upstream' });
    await syncExternalActivities(env.DB, env as unknown as Env, {
      userId: userA,
      today: TODAY,
      fetcher: payload([{ ...sharedActivity, icu_average_watts: 200 }]),
    });
    await syncExternalActivities(env.DB, env as unknown as Env, {
      userId: userB,
      today: TODAY,
      fetcher: payload([{ ...sharedActivity, icu_average_watts: 300 }]),
    });
    const intervalsA = `intervals:activity:${userA}:shared-upstream`;
    const intervalsB = `intervals:activity:${userB}:shared-upstream`;
    const bBefore = await env.DB.prepare(
      'SELECT average_watts,synced_at,deleted_at FROM external_activities WHERE id=?1',
    )
      .bind(intervalsB)
      .first<{ average_watts: number; synced_at: number; deleted_at: number | null }>();

    await syncExternalActivities(env.DB, env as unknown as Env, {
      userId: userA,
      today: TODAY,
      fetcher: payload([{ ...sharedActivity, icu_average_watts: 225 }]),
    });
    expect(
      await env.DB.prepare(
        'SELECT average_watts,deleted_at FROM external_activities WHERE id=?1',
      )
        .bind(intervalsA)
        .first(),
    ).toEqual({ average_watts: 225, deleted_at: null });
    expect(
      await env.DB.prepare(
        'SELECT average_watts,synced_at,deleted_at FROM external_activities WHERE id=?1',
      )
        .bind(intervalsB)
        .first(),
    ).toEqual(bBefore);

    await syncExternalActivities(env.DB, env as unknown as Env, {
      userId: userA,
      today: TODAY,
      fetcher: payload([]),
    });
    expect(
      (
        await env.DB.prepare('SELECT deleted_at FROM external_activities WHERE id=?1')
          .bind(intervalsA)
          .first<{ deleted_at: number | null }>()
      )?.deleted_at,
    ).not.toBeNull();
    expect(
      await env.DB.prepare(
        'SELECT average_watts,synced_at,deleted_at FROM external_activities WHERE id=?1',
      )
        .bind(intervalsB)
        .first(),
    ).toEqual(bBefore);

    await syncExternalActivities(env.DB, env as unknown as Env, {
      userId: userA,
      today: TODAY,
      fetcher: payload([{ ...sharedActivity, icu_average_watts: 225 }]),
    });
    expect(
      await env.DB.prepare(
        'SELECT average_watts,deleted_at FROM external_activities WHERE id=?1',
      )
        .bind(intervalsA)
        .first(),
    ).toEqual({ average_watts: 225, deleted_at: null });
    expect(
      await env.DB.prepare(
        'SELECT average_watts,synced_at,deleted_at FROM external_activities WHERE id=?1',
      )
        .bind(intervalsB)
        .first(),
    ).toEqual(bBefore);

    const sharedHealthKitId = crypto.randomUUID();
    const healthKitA = await upsertHealthKitActivity(
      env.DB,
      userA,
      healthKitActivity({ id: sharedHealthKitId }),
    );
    const healthKitB = await upsertHealthKitActivity(
      env.DB,
      userB,
      healthKitActivity({ id: sharedHealthKitId }),
    );
    expect(healthKitA).toMatchObject({ canonical: 0, duplicate_of: intervalsA });
    expect(healthKitB).toMatchObject({ canonical: 0, duplicate_of: intervalsB });

    await syncExternalActivities(env.DB, env as unknown as Env, {
      userId: userA,
      today: TODAY,
      fetcher: payload([]),
    });
    expect(
      await env.DB.prepare(
        'SELECT deleted_at,canonical,duplicate_of FROM external_activities WHERE id=?1',
      )
        .bind(healthKitA.id)
        .first(),
    ).toEqual({ deleted_at: null, canonical: 1, duplicate_of: null });
    expect(
      await env.DB.prepare(
        'SELECT deleted_at,canonical,duplicate_of FROM external_activities WHERE id=?1',
      )
        .bind(healthKitB.id)
        .first(),
    ).toEqual({
      deleted_at: healthKitB.deleted_at,
      canonical: 0,
      duplicate_of: intervalsB,
    });
    expect(
      await env.DB.prepare(
        'SELECT average_watts,synced_at,deleted_at FROM external_activities WHERE id=?1',
      )
        .bind(intervalsB)
        .first(),
    ).toEqual(bBefore);
  });

  it('migration 0035 makes empty external deltas member-first and constant-cost', async () => {
    const userId = await freshUser();
    await syncExternalEvents(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([plannedEvent()]),
    });
    await syncExternalActivities(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([completedActivity()]),
    });
    const cursor = Date.now() + 60_000;

    const eventPlan = await env.DB.prepare(
      `EXPLAIN QUERY PLAN
       SELECT * FROM external_events
        WHERE user_id = ?1 AND synced_at > ?2
        ORDER BY synced_at`,
    )
      .bind(userId, cursor)
      .all<{ detail: string }>();
    expect(eventPlan.results.some((row) => row.detail.includes('ix_ext_events_user_synced')))
      .toBe(true);
    const activityPlan = await env.DB.prepare(
      `EXPLAIN QUERY PLAN
       SELECT * FROM external_activities
        WHERE user_id = ?1 AND synced_at > ?2
        ORDER BY synced_at`,
    )
      .bind(userId, cursor)
      .all<{ detail: string }>();
    expect(
      activityPlan.results.some((row) => row.detail.includes('ix_ext_activities_user_synced')),
    ).toBe(true);

    const emptyEvents = await env.DB.prepare(
      `SELECT * FROM external_events
        WHERE user_id = ?1 AND synced_at > ?2
        ORDER BY synced_at`,
    )
      .bind(userId, cursor)
      .all();
    const emptyActivities = await env.DB.prepare(
      `SELECT * FROM external_activities
        WHERE user_id = ?1 AND synced_at > ?2
        ORDER BY synced_at`,
    )
      .bind(userId, cursor)
      .all();
    expect(emptyEvents.results).toEqual([]);
    expect(emptyEvents.meta.rows_read).toBeLessThanOrEqual(2);
    expect(emptyActivities.results).toEqual([]);
    expect(emptyActivities.meta.rows_read).toBeLessThanOrEqual(2);
  });

  it('measures one additional billed index row per real external cache mutation', async () => {
    await env.DB.prepare(
      `CREATE TABLE p2_external_cost_without_cursor (
         id TEXT PRIMARY KEY,
         user_id TEXT NOT NULL,
         date TEXT NOT NULL,
         synced_at INTEGER NOT NULL,
         payload TEXT
       )`,
    ).run();
    await env.DB.prepare(
      'CREATE INDEX p2_external_cost_without_date ON p2_external_cost_without_cursor(user_id,date)',
    ).run();
    await env.DB.prepare(
      `CREATE TABLE p2_external_cost_with_cursor (
         id TEXT PRIMARY KEY,
         user_id TEXT NOT NULL,
         date TEXT NOT NULL,
         synced_at INTEGER NOT NULL,
         payload TEXT
       )`,
    ).run();
    await env.DB.prepare(
      'CREATE INDEX p2_external_cost_with_date ON p2_external_cost_with_cursor(user_id,date)',
    ).run();
    await env.DB.prepare(
      'CREATE INDEX p2_external_cost_with_synced ON p2_external_cost_with_cursor(user_id,synced_at)',
    ).run();

    const insertWithout = await env.DB.prepare(
      "INSERT INTO p2_external_cost_without_cursor VALUES ('a','u','2026-05-18',100,'a')",
    ).run();
    const insertWith = await env.DB.prepare(
      "INSERT INTO p2_external_cost_with_cursor VALUES ('a','u','2026-05-18',100,'a')",
    ).run();
    expect(insertWith.meta.rows_written - insertWithout.meta.rows_written).toBe(1);

    const updateWithout = await env.DB.prepare(
      "UPDATE p2_external_cost_without_cursor SET payload='b',synced_at=101 WHERE id='a'",
    ).run();
    const updateWith = await env.DB.prepare(
      "UPDATE p2_external_cost_with_cursor SET payload='b',synced_at=101 WHERE id='a'",
    ).run();
    expect(updateWith.meta.rows_written - updateWithout.meta.rows_written).toBe(1);
  });
});
