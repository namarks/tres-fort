import { env, applyD1Migrations } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import {
  fetchCompletedActivities,
  fetchPlannedEvents,
  type Fetcher,
} from '../src/intervals';
import {
  ensureOwnerUser,
  getRecentActivities,
  getState,
  getUpcomingRides,
  syncExternalActivities,
  syncExternalEvents,
} from '../src/db';
import type { Env } from '../src/types';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

const TODAY = '2026-05-18';

// A canned intervals.icu /events payload. Only category=="WORKOUT" rows
// should survive the filter; a RACE row is dropped.
function payload(rows: unknown[]): Fetcher {
  return async () => ({
    ok: true,
    status: 200,
    json: async () => rows,
  });
}
const httpErr = (status: number): Fetcher => async () => ({
  ok: false,
  status,
  json: async () => ({}),
});
const timeoutFetcher: Fetcher = async () => {
  throw new Error('network down');
};

const ev = (over: Record<string, unknown>) => ({
  id: 'e1',
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

/** Each test gets its own user so cache rows never bleed across tests. */
async function freshUser(): Promise<string> {
  const id = crypto.randomUUID();
  await env.DB.prepare(
    'INSERT INTO users (id,apple_sub,email,display_name,created_at) VALUES (?1,?2,?3,?4,?5)',
  )
    .bind(id, `sub-${id}`, null, 'Rider', Date.now())
    .run();
  return id;
}

describe('fetchPlannedEvents — injected fetcher, never real network', () => {
  it('dormant (no fetch, no error) when API key/athlete unset', async () => {
    let called = false;
    const spy: Fetcher = async () => {
      called = true;
      return { ok: true, status: 200, json: async () => [] };
    };
    const res = await fetchPlannedEvents(
      undefined,
      env.INTERVALS_ICU_ATHLETE_ID,
      { fetcher: spy, today: TODAY },
    );
    expect(res).toEqual({ ok: false, reason: 'disabled' });
    expect(called).toBe(false);
  });

  it('parses 2xx, filters non-WORKOUT, uses start_date_local verbatim', async () => {
    const res = await fetchPlannedEvents(env.INTERVALS_ICU_API_KEY, env.INTERVALS_ICU_ATHLETE_ID, {
      today: TODAY,
      fetcher: payload([
        ev({ id: 'e1' }),
        { id: 'r1', category: 'RACE', type: 'Ride', start_date_local: '2026-05-21T06:00:00' },
        ev({ id: 'e2', type: 'Run', start_date_local: '2026-05-22T05:30:00', icu_training_load: 40 }),
      ]),
    });
    expect(res.ok).toBe(true);
    if (!res.ok) return;
    expect(res.events).toHaveLength(2);
    expect(res.events[0]).toMatchObject({
      external_id: 'e1',
      date: '2026-05-20',
      kind: 'ride',
      planned_duration_sec: 7200,
      training_load: 90,
    });
    expect(res.events[1]).toMatchObject({ external_id: 'e2', kind: 'run', date: '2026-05-22' });
  });

  it('non-2xx → {ok:false, http}; thrown/timeout → {ok:false, timeout}', async () => {
    expect(
      await fetchPlannedEvents(env.INTERVALS_ICU_API_KEY, env.INTERVALS_ICU_ATHLETE_ID, {
        fetcher: httpErr(500),
        today: TODAY,
      }),
    ).toEqual({ ok: false, reason: 'http', status: 500 });
    expect(
      await fetchPlannedEvents(env.INTERVALS_ICU_API_KEY, env.INTERVALS_ICU_ATHLETE_ID, {
        fetcher: timeoutFetcher,
        today: TODAY,
      }),
    ).toEqual({ ok: false, reason: 'timeout' });
  });
});

describe('syncExternalEvents — reconciled cache, the failed-fetch guard', () => {
  it('upserts on a successful sync', async () => {
    const userId = await freshUser();
    const r = await syncExternalEvents(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([ev({ id: 'a' }), ev({ id: 'b', start_date_local: '2026-05-25T06:00:00' })]),
    } as any);
    expect(r.status).toBe('ok');
    expect(r.synced).toBe(2);
    const rows = await getUpcomingRides(env.DB, userId, { from: TODAY });
    expect(rows.map((x) => x.id).sort()).toEqual([
      `intervals:${userId}:a`,
      `intervals:${userId}:b`,
    ]);
    expect(rows.find((x) => x.id === `intervals:${userId}:a`)!.date).toBe('2026-05-20');
  });

  it('reschedule: same external_id, new date → date updates in place', async () => {
    const userId = await freshUser();
    await syncExternalEvents(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([ev({ id: 'a', start_date_local: '2026-05-20T06:00:00' })]),
    } as any);
    await syncExternalEvents(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([ev({ id: 'a', start_date_local: '2026-05-27T06:00:00' })]),
    } as any);
    const rows = await getUpcomingRides(env.DB, userId, { from: TODAY });
    expect(rows).toHaveLength(1);
    expect(rows[0]!.id).toBe(`intervals:${userId}:a`);
    expect(rows[0]!.date).toBe('2026-05-27');
  });

  it('removed event → soft-deleted on a successful sync', async () => {
    const userId = await freshUser();
    await syncExternalEvents(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([ev({ id: 'a' }), ev({ id: 'b', start_date_local: '2026-05-25T06:00:00' })]),
    } as any);
    // Next sync no longer contains 'b'.
    const r = await syncExternalEvents(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([ev({ id: 'a' })]),
    } as any);
    expect(r.synced).toBe(1);
    const live = await getUpcomingRides(env.DB, userId, { from: TODAY });
    expect(live.map((x) => x.id)).toEqual([`intervals:${userId}:a`]);
    const dead = await env.DB.prepare(
      "SELECT deleted_at FROM external_events WHERE id=?1",
    )
      .bind(`intervals:${userId}:b`)
      .first<{ deleted_at: number | null }>();
    expect(dead!.deleted_at).not.toBeNull();
  });

  it('CRITICAL GUARD: a 500 leaves the cache COMPLETELY untouched', async () => {
    const userId = await freshUser();
    await syncExternalEvents(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([ev({ id: 'a' }), ev({ id: 'b', start_date_local: '2026-05-25T06:00:00' })]),
    } as any);
    const r = await syncExternalEvents(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: httpErr(500),
    } as any);
    expect(r.status).toBe('fetch_failed');
    expect(r.synced).toBe(0);
    // BOTH rows still live — nothing upserted, nothing soft-deleted.
    const live = await getUpcomingRides(env.DB, userId, { from: TODAY });
    expect(live.map((x) => x.id).sort()).toEqual([
      `intervals:${userId}:a`,
      `intervals:${userId}:b`,
    ]);
    const anyDeleted = await env.DB.prepare(
      'SELECT COUNT(*) AS c FROM external_events WHERE user_id=?1 AND deleted_at IS NOT NULL',
    )
      .bind(userId)
      .first<{ c: number }>();
    expect(anyDeleted!.c).toBe(0);
  });

  it('CRITICAL GUARD: a timeout leaves the cache COMPLETELY untouched', async () => {
    const userId = await freshUser();
    await syncExternalEvents(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([ev({ id: 'a' })]),
    } as any);
    const r = await syncExternalEvents(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: timeoutFetcher,
    } as any);
    expect(r.status).toBe('fetch_failed');
    const live = await getUpcomingRides(env.DB, userId, { from: TODAY });
    expect(live.map((x) => x.id)).toEqual([`intervals:${userId}:a`]);
    // Symmetric with the 500-guard test: prove the existing row was NOT
    // soft-deleted by the timed-out sync (deleted_at still NULL).
    const row = await env.DB.prepare(
      "SELECT deleted_at FROM external_events WHERE id=?1",
    )
      .bind(`intervals:${userId}:a`)
      .first<{ deleted_at: number | null }>();
    expect(row!.deleted_at).toBeNull();
  });

  it('a genuinely-empty SUCCESSFUL window DOES soft-delete in-window rows', async () => {
    const userId = await freshUser();
    await syncExternalEvents(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([ev({ id: 'a' })]),
    } as any);
    const r = await syncExternalEvents(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([]), // empty BUT successful
    } as any);
    expect(r.status).toBe('ok');
    expect(r.synced).toBe(0);
    const live = await getUpcomingRides(env.DB, userId, { from: TODAY });
    expect(live).toHaveLength(0);
    const dead = await env.DB.prepare(
      "SELECT deleted_at FROM external_events WHERE id=?1",
    )
      .bind(`intervals:${userId}:a`)
      .first<{ deleted_at: number | null }>();
    expect(dead!.deleted_at).not.toBeNull();
  });

  it('dormant when key unset: status disabled, cache untouched', async () => {
    const userId = await freshUser();
    await syncExternalEvents(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([ev({ id: 'a' })]),
    } as any);
    const r = await syncExternalEvents(
      env.DB,
      { ...env, INTERVALS_ICU_API_KEY: undefined } as unknown as Env,
      { userId, today: TODAY } as any,
    );
    expect(r.status).toBe('disabled');
    const live = await getUpcomingRides(env.DB, userId, { from: TODAY });
    expect(live).toHaveLength(1);
  });

  it('ensureOwnerUser is the default principal when userId omitted', async () => {
    const owner = await ensureOwnerUser(env.DB, undefined);
    const r = await syncExternalEvents(env.DB, env as unknown as Env, {
      today: TODAY,
      fetcher: payload([ev({ id: 'owner-ride' })]),
    } as any);
    expect(r.status).toBe('ok');
    const rows = await getUpcomingRides(env.DB, owner.id, { from: TODAY });
    expect(rows.some((x) => x.id === `intervals:${owner.id}:owner-ride`)).toBe(true);
  });
});

// FIX 3 — a tombstone from the successful-sync reconcile must advance
// synced_at to the deletion time. /api/state?events_since= filters
// `synced_at > cursor`; if the tombstone keeps its old synced_at an
// incremental client that already saw the live event never receives the
// removal and keeps showing a deleted ride.
describe('FIX 3: tombstone advances synced_at so incremental clients see removals', () => {
  it('removed in-window event: deleted_at set AND synced_at advanced to the sync time', async () => {
    const userId = await freshUser();
    await syncExternalEvents(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([ev({ id: 'a' }), ev({ id: 'b', start_date_local: '2026-05-25T06:00:00' })]),
    } as any);

    // Pin 'b' to a known OLD synced_at — the cursor an incremental client
    // would hold after it saw the live event. Deterministic, clock-free.
    const OLD = 1000;
    const bId = `intervals:${userId}:b`;
    const aId = `intervals:${userId}:a`;
    await env.DB.prepare('UPDATE external_events SET synced_at = ?1 WHERE id = ?2')
      .bind(OLD, bId)
      .run();

    // Successful sync that no longer contains 'b' → tombstone.
    const r = await syncExternalEvents(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([ev({ id: 'a' })]),
    } as any);
    expect(r.status).toBe('ok');

    const dead = await env.DB.prepare(
      'SELECT deleted_at, synced_at FROM external_events WHERE id=?1',
    )
      .bind(bId)
      .first<{ deleted_at: number | null; synced_at: number }>();
    expect(dead!.deleted_at).not.toBeNull();
    // The fix: synced_at moved off the old cursor to the deletion time.
    expect(dead!.synced_at).toBe(dead!.deleted_at);
    expect(dead!.synced_at).toBeGreaterThan(OLD);

    // getState with the OLD cursor (before the deletion) must now return
    // the tombstone so the client can drop it. Pre-fix this is excluded
    // because synced_at stayed at OLD and the filter is `synced_at > OLD`.
    const incr = await getState(env.DB, userId, 0, 0, OLD);
    const bTomb = incr.external_events.find((e) => e.id === bId);
    expect(bTomb).toBeDefined();
    expect(bTomb!.deleted_at).not.toBeNull();

    // Full reload (events_since absent/0) still returns only non-deleted.
    const full = await getState(env.DB, userId, 0, 0, 0);
    expect(full.external_events.some((e) => e.id === bId)).toBe(false);
    expect(full.external_events.some((e) => e.id === aId)).toBe(true);
  });
});

// ---- completed activities (own consistency class; migrations/0015) --------

// A canned intervals.icu /activities row. Mirrors the recorded-activity
// shape (start_date_local + actuals). pastDays defaults to 90, so dates are
// chosen to land BEFORE/at TODAY.
const act = (over: Record<string, unknown>) => ({
  id: 'a1',
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

describe('fetchCompletedActivities — injected fetcher, never real network', () => {
  it('dormant (no fetch, no error) when API key unset', async () => {
    let called = false;
    const spy: Fetcher = async () => {
      called = true;
      return { ok: true, status: 200, json: async () => [] };
    };
    const res = await fetchCompletedActivities(
      undefined,
      env.INTERVALS_ICU_ATHLETE_ID,
      { fetcher: spy, today: TODAY },
    );
    expect(res).toEqual({ ok: false, reason: 'disabled' });
    expect(called).toBe(false);
  });

  it('queries the /activities feed with a backward window', async () => {
    let seenUrl = '';
    const spy: Fetcher = async (url) => {
      seenUrl = url;
      return { ok: true, status: 200, json: async () => [] };
    };
    await fetchCompletedActivities(env.INTERVALS_ICU_API_KEY, env.INTERVALS_ICU_ATHLETE_ID, {
      fetcher: spy,
      today: TODAY,
      pastDays: 30,
    });
    expect(seenUrl).toContain('/activities?');
    expect(seenUrl).toContain(`newest=${TODAY}`);
    expect(seenUrl).toContain('oldest=2026-04-18'); // TODAY - 30d
  });

  it('parses 2xx, maps actuals, skips our own strength exports', async () => {
    const res = await fetchCompletedActivities(env.INTERVALS_ICU_API_KEY, env.INTERVALS_ICU_ATHLETE_ID, {
      today: TODAY,
      fetcher: payload([
        act({ id: 'a1' }),
        act({ id: 'a2', type: 'Run', start_date_local: '2026-05-16T05:30:00' }),
        // our own exported lift — must be filtered out
        { id: 'x', type: 'WeightTraining', start_date_local: '2026-05-14T18:00:00' },
      ]),
    });
    expect(res.ok).toBe(true);
    if (!res.ok) return;
    expect(res.activities).toHaveLength(2);
    expect(res.activities[0]).toMatchObject({
      external_id: 'a1',
      date: '2026-05-15',
      kind: 'ride',
      moving_time_sec: 5400,
      distance_m: 42000,
      average_watts: 185,
      weighted_avg_watts: 205,
      average_hr: 142,
      max_hr: 171,
      training_load: 88,
      intensity: 0.74,
      calories: 760,
      elevation_gain_m: 430,
    });
    expect(res.activities[1]).toMatchObject({ external_id: 'a2', kind: 'run' });
  });

  it('falls back to average_watts when icu_average_watts is absent', async () => {
    const res = await fetchCompletedActivities(env.INTERVALS_ICU_API_KEY, env.INTERVALS_ICU_ATHLETE_ID, {
      today: TODAY,
      fetcher: payload([act({ id: 'a1', icu_average_watts: undefined, average_watts: 150 })]),
    });
    expect(res.ok).toBe(true);
    if (!res.ok) return;
    expect(res.activities[0]!.average_watts).toBe(150);
  });

  it('non-2xx → http; thrown → timeout', async () => {
    expect(
      await fetchCompletedActivities(env.INTERVALS_ICU_API_KEY, env.INTERVALS_ICU_ATHLETE_ID, {
        fetcher: httpErr(503),
        today: TODAY,
      }),
    ).toEqual({ ok: false, reason: 'http', status: 503 });
    expect(
      await fetchCompletedActivities(env.INTERVALS_ICU_API_KEY, env.INTERVALS_ICU_ATHLETE_ID, {
        fetcher: timeoutFetcher,
        today: TODAY,
      }),
    ).toEqual({ ok: false, reason: 'timeout' });
  });
});

describe('syncExternalActivities — reconciled cache + failed-fetch guard', () => {
  it('upserts completed activities on a successful sync', async () => {
    const userId = await freshUser();
    const r = await syncExternalActivities(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([act({ id: 'a1' }), act({ id: 'a2', start_date_local: '2026-05-10T06:00:00' })]),
    } as any);
    expect(r.status).toBe('ok');
    expect(r.synced).toBe(2);
    const rows = await getRecentActivities(env.DB, userId, { to: TODAY });
    expect(rows.map((x) => x.id).sort()).toEqual([
      `intervals:activity:${userId}:a1`,
      `intervals:activity:${userId}:a2`,
    ]);
    expect(rows.find((x) => x.id === `intervals:activity:${userId}:a1`)!.average_watts).toBe(185);
  });

  it('re-sync with changed actuals updates the same row in place', async () => {
    const userId = await freshUser();
    await syncExternalActivities(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([act({ id: 'a1', icu_average_watts: 185 })]),
    } as any);
    await syncExternalActivities(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([act({ id: 'a1', icu_average_watts: 999 })]),
    } as any);
    const rows = await getRecentActivities(env.DB, userId, { to: TODAY });
    expect(rows).toHaveLength(1);
    expect(rows[0]!.average_watts).toBe(999);
  });

  it('an activity removed in intervals.icu is soft-deleted', async () => {
    const userId = await freshUser();
    await syncExternalActivities(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([act({ id: 'a1' }), act({ id: 'a2', start_date_local: '2026-05-10T06:00:00' })]),
    } as any);
    const r = await syncExternalActivities(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([act({ id: 'a1' })]),
    } as any);
    expect(r.synced).toBe(1);
    const live = await getRecentActivities(env.DB, userId, { to: TODAY });
    expect(live.map((x) => x.id)).toEqual([`intervals:activity:${userId}:a1`]);
    const dead = await env.DB.prepare(
      'SELECT deleted_at FROM external_activities WHERE id=?1',
    )
      .bind(`intervals:activity:${userId}:a2`)
      .first<{ deleted_at: number | null }>();
    expect(dead!.deleted_at).not.toBeNull();
  });

  it('CRITICAL GUARD: a 500 leaves the completed cache COMPLETELY untouched', async () => {
    const userId = await freshUser();
    await syncExternalActivities(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([act({ id: 'a1' })]),
    } as any);
    const r = await syncExternalActivities(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: httpErr(500),
    } as any);
    expect(r.status).toBe('fetch_failed');
    const live = await getRecentActivities(env.DB, userId, { to: TODAY });
    expect(live.map((x) => x.id)).toEqual([`intervals:activity:${userId}:a1`]);
  });

  it('dormant when key unset: status disabled, cache untouched', async () => {
    const userId = await freshUser();
    await syncExternalActivities(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([act({ id: 'a1' })]),
    } as any);
    const r = await syncExternalActivities(
      env.DB,
      { ...env, INTERVALS_ICU_API_KEY: undefined } as unknown as Env,
      { userId, today: TODAY } as any,
    );
    expect(r.status).toBe('disabled');
    const live = await getRecentActivities(env.DB, userId, { to: TODAY });
    expect(live).toHaveLength(1);
  });

  it('getState carries external_activities (full reload + incremental delta)', async () => {
    const userId = await freshUser();
    await syncExternalActivities(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([act({ id: 'a1' })]),
    } as any);

    const a1Id = `intervals:activity:${userId}:a1`;
    // Full reload (activities_since omitted/0) → present.
    const full = await getState(env.DB, userId, 0, 0, 0, 0);
    expect(full.external_activities.some((a) => a.id === a1Id)).toBe(true);

    // Pin an OLD cursor, then tombstone via an empty successful sync.
    const OLD = 1000;
    await env.DB.prepare('UPDATE external_activities SET synced_at=?1 WHERE id=?2')
      .bind(OLD, a1Id)
      .run();
    await syncExternalActivities(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([]),
    } as any);

    // Incremental (activities_since=OLD) → the tombstone reaches the client.
    const incr = await getState(env.DB, userId, 0, 0, 0, OLD);
    const tomb = incr.external_activities.find((a) => a.id === a1Id);
    expect(tomb).toBeDefined();
    expect(tomb!.deleted_at).not.toBeNull();

    // Full reload now excludes the tombstoned activity.
    const after = await getState(env.DB, userId, 0, 0, 0, 0);
    expect(after.external_activities.some((a) => a.id === a1Id)).toBe(false);
  });
});

// ---- M1: per-user credentials (multi-user backend foundation) ------------

/**
 * Seed a user row with intervals.icu credentials. Used by the multi-user
 * iteration tests below so each user has their own key/athlete pair the
 * sync loop should consume independently.
 */
async function userWithCreds(
  apiKey: string,
  athleteId: string,
): Promise<string> {
  const id = crypto.randomUUID();
  await env.DB.prepare(
    `INSERT INTO users (id,apple_sub,email,display_name,created_at,intervals_api_key,intervals_athlete_id)
     VALUES (?1,?2,?3,?4,?5,?6,?7)`,
  )
    .bind(id, `sub-${id}`, null, 'Multi User', Date.now(), apiKey, athleteId)
    .run();
  return id;
}

describe('M1: per-user creds — multi-user fan-out in syncExternalEvents', () => {
  it('cron path iterates EACH user with creds; each user gets only their own rows', async () => {
    // Hermetic: prior tests in this suite seed users (with and without creds),
    // and the cron path fans out across ALL credentialed users. Reset so the
    // dispatch fetcher only has to know about the two we set up here.
    await env.DB.prepare('DELETE FROM external_events').run();
    await env.DB.prepare('DELETE FROM users').run();
    // Two distinct users, each with their own credentials. The cron path
    // (no deps.userId) must fetch once per user, with that user's creds.
    const userA = await userWithCreds('key-A', 'athlete-A');
    const userB = await userWithCreds('key-B', 'athlete-B');

    // Per-call fetcher dispatches by the URL's athlete segment AND verifies
    // the HTTP Basic header carries that user's API key — proves we are
    // NOT using the legacy env values for either call.
    const seenCalls: { athleteId: string; apiKey: string }[] = [];
    const dispatchFetcher = (async (url: string, init?: { headers?: Record<string, string> }) => {
      const m = /athlete\/([^/]+)\//.exec(url);
      const athleteId = m ? m[1]! : '';
      const auth = init?.headers?.Authorization ?? '';
      const decoded = auth.startsWith('Basic ')
        ? atob(auth.slice(6))
        : '';
      const apiKey = decoded.startsWith('API_KEY:') ? decoded.slice(8) : '';
      seenCalls.push({ athleteId, apiKey });
      const rows = athleteId === 'athlete-A' ? [ev({ id: 'A1' })] : [ev({ id: 'B1', start_date_local: '2026-05-22T06:00:00' })];
      return { ok: true, status: 200, json: async () => rows };
    }) as Fetcher;

    // No userId → cron fan-out path. Aggregated result.
    const r = await syncExternalEvents(env.DB, env as unknown as Env, {
      today: TODAY,
      fetcher: dispatchFetcher,
    } as any);
    expect(r.status).toBe('ok');
    expect(r.synced).toBe(2); // one per user

    // Each user got a fetch with their OWN creds, not env's.
    const callA = seenCalls.find((c) => c.athleteId === 'athlete-A');
    const callB = seenCalls.find((c) => c.athleteId === 'athlete-B');
    expect(callA).toBeDefined();
    expect(callA!.apiKey).toBe('key-A');
    expect(callB).toBeDefined();
    expect(callB!.apiKey).toBe('key-B');

    // Each user's cache contains only their own external_id, tagged with
    // their own user_id — no cross-contamination.
    const aRows = await getUpcomingRides(env.DB, userA, { from: TODAY });
    expect(aRows.map((x) => x.id)).toEqual([`intervals:${userA}:A1`]);
    const bRows = await getUpcomingRides(env.DB, userB, { from: TODAY });
    expect(bRows.map((x) => x.id)).toEqual([`intervals:${userB}:B1`]);
  });

  it('env-seed fallback: zero users with creds + env present → owner row seeded once', async () => {
    // Fresh, hermetic database state: no user has creds. Cron path runs and
    // observes that the env vars are set → seeds them onto the owner row,
    // then proceeds to sync as that single-user case (the legacy behavior).
    await env.DB.prepare('DELETE FROM users').run();
    await env.DB.prepare('DELETE FROM external_events').run();
    const ownerId = crypto.randomUUID();
    await env.DB.prepare(
      'INSERT INTO users (id,apple_sub,email,display_name,created_at) VALUES (?1,?2,?3,?4,?5)',
    )
      .bind(ownerId, 'mcp-owner', null, 'Owner', Date.now())
      .run();
    // Sanity: columns start null.
    const pre = await env.DB.prepare(
      'SELECT intervals_api_key, intervals_athlete_id FROM users WHERE id = ?1',
    )
      .bind(ownerId)
      .first<{ intervals_api_key: string | null; intervals_athlete_id: string | null }>();
    expect(pre!.intervals_api_key).toBeNull();
    expect(pre!.intervals_athlete_id).toBeNull();

    const r = await syncExternalEvents(env.DB, env as unknown as Env, {
      today: TODAY,
      fetcher: payload([ev({ id: 'seed-1' })]),
    } as any);
    expect(r.status).toBe('ok');

    // After: owner row has the env creds populated, idempotently.
    const post = await env.DB.prepare(
      'SELECT intervals_api_key, intervals_athlete_id FROM users WHERE id = ?1',
    )
      .bind(ownerId)
      .first<{ intervals_api_key: string; intervals_athlete_id: string }>();
    expect(post!.intervals_api_key).toBe(env.INTERVALS_ICU_API_KEY);
    expect(post!.intervals_athlete_id).toBe(env.INTERVALS_ICU_ATHLETE_ID);

    // And the synced row tags to the owner.
    const rows = await getUpcomingRides(env.DB, ownerId, { from: TODAY });
    expect(rows.map((x) => x.id)).toEqual([`intervals:${ownerId}:seed-1`]);
  });

  it('env-seed fallback: respects explicit disconnect — once owner has PATCHed creds, env is not re-seeded', async () => {
    // Reproduces Codex PR #36 P1 finding: a user who explicitly disconnects
    // their intervals.icu account leaves both columns NULL. Without a marker,
    // the next sync's env-seed would re-seed from the legacy Worker secrets
    // and resume polling — undoing the disconnect. The audit_log row written
    // by PATCH /api/me/integrations/intervals (tool='set_intervals_creds') is
    // the durable marker.
    await env.DB.prepare('DELETE FROM users').run();
    await env.DB.prepare('DELETE FROM external_events').run();
    await env.DB.prepare('DELETE FROM audit_log').run();
    const ownerId = crypto.randomUUID();
    await env.DB.prepare(
      'INSERT INTO users (id,apple_sub,email,display_name,created_at) VALUES (?1,?2,?3,?4,?5)',
    )
      .bind(ownerId, 'mcp-owner', null, 'Owner', Date.now())
      .run();
    // Simulate the user having previously PATCHed (set then cleared) their
    // intervals creds — the disconnect audit row is what closes the seed
    // window. Both columns are NULL just like a fresh deploy.
    await env.DB.prepare(
      `INSERT INTO audit_log (id, user_id, actor, tool, args, result, created_at)
         VALUES (?1, ?2, 'ios', 'set_intervals_creds', '{"connected":false}', 'disconnected', ?3)`,
    )
      .bind(crypto.randomUUID(), ownerId, Date.now())
      .run();

    let fetcherCalled = false;
    const spy: Fetcher = async () => {
      fetcherCalled = true;
      return { ok: true, status: 200, json: async () => [] };
    };
    const r = await syncExternalEvents(env.DB, env as unknown as Env, {
      today: TODAY,
      fetcher: spy,
    } as any);
    // No user has creds; the audit row blocks re-seeding from env → disabled.
    expect(r.status).toBe('disabled');
    expect(fetcherCalled).toBe(false);

    // And the owner row stays NULL — disconnect held.
    const post = await env.DB.prepare(
      'SELECT intervals_api_key, intervals_athlete_id FROM users WHERE id = ?1',
    )
      .bind(ownerId)
      .first<{ intervals_api_key: string | null; intervals_athlete_id: string | null }>();
    expect(post!.intervals_api_key).toBeNull();
    expect(post!.intervals_athlete_id).toBeNull();
  });

  it('explicit-userId path: respects disconnect — env fallback NOT used after PATCH', async () => {
    // Sibling case for the MCP refresh_rides path (deps.userId given). Same
    // invariant: once the user has touched their creds, NULL means
    // "intentionally cleared", not "fall back to env".
    await env.DB.prepare('DELETE FROM users').run();
    await env.DB.prepare('DELETE FROM external_events').run();
    await env.DB.prepare('DELETE FROM audit_log').run();
    const ownerId = crypto.randomUUID();
    await env.DB.prepare(
      'INSERT INTO users (id,apple_sub,email,display_name,created_at) VALUES (?1,?2,?3,?4,?5)',
    )
      .bind(ownerId, 'mcp-owner', null, 'Owner', Date.now())
      .run();
    await env.DB.prepare(
      `INSERT INTO audit_log (id, user_id, actor, tool, args, result, created_at)
         VALUES (?1, ?2, 'ios', 'set_intervals_creds', '{"connected":false}', 'disconnected', ?3)`,
    )
      .bind(crypto.randomUUID(), ownerId, Date.now())
      .run();

    let fetcherCalled = false;
    const spy: Fetcher = async () => {
      fetcherCalled = true;
      return { ok: true, status: 200, json: async () => [] };
    };
    const r = await syncExternalEvents(env.DB, env as unknown as Env, {
      today: TODAY,
      fetcher: spy,
      userId: ownerId,
    } as any);
    expect(r.status).toBe('disabled');
    expect(fetcherCalled).toBe(false);
  });

  it('env-seed fallback: no users with creds AND env unset → disabled, NO touch', async () => {
    await env.DB.prepare('DELETE FROM users').run();
    await env.DB.prepare('DELETE FROM external_events').run();
    const ownerId = crypto.randomUUID();
    await env.DB.prepare(
      'INSERT INTO users (id,apple_sub,email,display_name,created_at) VALUES (?1,?2,?3,?4,?5)',
    )
      .bind(ownerId, 'mcp-owner', null, 'Owner', Date.now())
      .run();

    let fetcherCalled = false;
    const spy: Fetcher = async () => {
      fetcherCalled = true;
      return { ok: true, status: 200, json: async () => [] };
    };
    const r = await syncExternalEvents(
      env.DB,
      { ...env, INTERVALS_ICU_API_KEY: undefined, INTERVALS_ICU_ATHLETE_ID: undefined } as unknown as Env,
      { today: TODAY, fetcher: spy } as any,
    );
    expect(r.status).toBe('disabled');
    expect(fetcherCalled).toBe(false);
  });
});

describe('M1: per-user creds — multi-user fan-out in syncExternalActivities', () => {
  it('cron path iterates EACH user with creds; activities tag per user', async () => {
    await env.DB.prepare('DELETE FROM external_activities').run();
    await env.DB.prepare('DELETE FROM users').run();
    const userA = await userWithCreds('akey-A', 'aath-A');
    const userB = await userWithCreds('akey-B', 'aath-B');
    const seen: { athleteId: string; apiKey: string }[] = [];
    const dispatchFetcher = (async (url: string, init?: { headers?: Record<string, string> }) => {
      const m = /athlete\/([^/]+)\//.exec(url);
      const athleteId = m ? m[1]! : '';
      const auth = init?.headers?.Authorization ?? '';
      const decoded = auth.startsWith('Basic ') ? atob(auth.slice(6)) : '';
      const apiKey = decoded.startsWith('API_KEY:') ? decoded.slice(8) : '';
      seen.push({ athleteId, apiKey });
      const rows = athleteId === 'aath-A' ? [act({ id: 'aA1' })] : [act({ id: 'aB1', start_date_local: '2026-05-12T06:00:00' })];
      return { ok: true, status: 200, json: async () => rows };
    }) as Fetcher;

    const r = await syncExternalActivities(env.DB, env as unknown as Env, {
      today: TODAY,
      fetcher: dispatchFetcher,
    } as any);
    expect(r.status).toBe('ok');
    expect(r.synced).toBe(2);
    expect(seen.find((c) => c.athleteId === 'aath-A')!.apiKey).toBe('akey-A');
    expect(seen.find((c) => c.athleteId === 'aath-B')!.apiKey).toBe('akey-B');

    const aRows = await getRecentActivities(env.DB, userA, { to: TODAY });
    expect(aRows.map((x) => x.id)).toEqual([`intervals:activity:${userA}:aA1`]);
    const bRows = await getRecentActivities(env.DB, userB, { to: TODAY });
    expect(bRows.map((x) => x.id)).toEqual([`intervals:activity:${userB}:aB1`]);
  });

  // Codex PR #36 P2: under the single-user schema, the PK was just
  // "intervals:activity:{external_id}", so two users returning the SAME
  // upstream external_id (intervals.icu ids are per-athlete, not globally
  // unique) would collide on the PK and the second sync's ON CONFLICT
  // would silently overwrite user_A's row with user_B's payload while
  // leaving user_id pointing at user_A. The fix is per-user PKs; this
  // test reproduces a same-external_id collision and asserts both users
  // get their own row attributed correctly.
  it('two users syncing the SAME upstream external_id keep their rows separate', async () => {
    await env.DB.prepare('DELETE FROM external_activities').run();
    await env.DB.prepare('DELETE FROM users').run();
    const userA = await userWithCreds('cAk-A', 'cAath-A');
    const userB = await userWithCreds('cAk-B', 'cAath-B');
    // Both athletes return an activity with the SAME external_id 'shared-7'.
    const dispatchFetcher = (async (url: string) => {
      const m = /athlete\/([^/]+)\//.exec(url);
      const athleteId = m ? m[1]! : '';
      const rows =
        athleteId === 'cAath-A'
          ? [act({ id: 'shared-7', icu_average_watts: 200 })]
          : [act({ id: 'shared-7', icu_average_watts: 300 })];
      return { ok: true, status: 200, json: async () => rows };
    }) as Fetcher;

    const r = await syncExternalActivities(env.DB, env as unknown as Env, {
      today: TODAY,
      fetcher: dispatchFetcher,
    } as any);
    expect(r.status).toBe('ok');
    expect(r.synced).toBe(2);

    // Each user's row stays attributed to them with their own payload.
    const aRows = await getRecentActivities(env.DB, userA, { to: TODAY });
    expect(aRows).toHaveLength(1);
    expect(aRows[0]!.id).toBe(`intervals:activity:${userA}:shared-7`);
    expect(aRows[0]!.average_watts).toBe(200);

    const bRows = await getRecentActivities(env.DB, userB, { to: TODAY });
    expect(bRows).toHaveLength(1);
    expect(bRows[0]!.id).toBe(`intervals:activity:${userB}:shared-7`);
    expect(bRows[0]!.average_watts).toBe(300);
  });
});

// Codex PR #36 P2: the owner env-seed must not be skipped just because
// SOMEONE ELSE happens to have intervals creds. If a newly-invited member
// connected their intervals account before the first post-deploy cron tick,
// the owner row would never get seeded and the owner would silently lose
// ride syncing. The seed gate is OWNER-SPECIFIC.
describe('M1: owner env-seed gate is owner-specific (not global)', () => {
  it('seeds owner even when another user already has intervals creds', async () => {
    await env.DB.prepare('DELETE FROM external_events').run();
    await env.DB.prepare('DELETE FROM external_activities').run();
    await env.DB.prepare('DELETE FROM users').run();
    await env.DB.prepare('DELETE FROM audit_log').run();

    // Owner FIRST by created_at; columns NULL (legacy env-secret deploy
    // that hasn't been seeded yet). Use a hand-picked older created_at to
    // make the ordering deterministic regardless of insert speed.
    const ownerId = crypto.randomUUID();
    await env.DB.prepare(
      'INSERT INTO users (id,apple_sub,email,display_name,created_at) VALUES (?1,?2,?3,?4,?5)',
    )
      .bind(ownerId, 'owner-sub', null, 'Owner', 1000)
      .run();

    // Newly-invited user joined AFTER and connected their own account first.
    await env.DB.prepare(
      `INSERT INTO users (id,apple_sub,email,display_name,created_at,intervals_api_key,intervals_athlete_id)
       VALUES (?1,?2,?3,?4,?5,?6,?7)`,
    )
      .bind(crypto.randomUUID(), 'second-sub', null, 'Second', 2000, 'second-key', 'second-ath')
      .run();

    const r = await syncExternalEvents(env.DB, env as unknown as Env, {
      today: TODAY,
      fetcher: payload([]), // empty success — we care about the seed side-effect, not the sync
    } as any);
    expect(r.status).toBe('ok');

    // Owner row got seeded from env on this same call.
    const post = await env.DB.prepare(
      'SELECT intervals_api_key, intervals_athlete_id FROM users WHERE id = ?1',
    )
      .bind(ownerId)
      .first<{ intervals_api_key: string; intervals_athlete_id: string }>();
    expect(post!.intervals_api_key).toBe(env.INTERVALS_ICU_API_KEY);
    expect(post!.intervals_athlete_id).toBe(env.INTERVALS_ICU_ATHLETE_ID);
  });
});

// Codex PR #36 P1: rides were ordered by synced_at in the group feed, but
// synced_at rewrites on every cron tick. The fix is to populate (and
// order by) start_date_local_ms — the actual activity start time.
describe('M1: ride sync writes start_date_local_ms for ordering', () => {
  it('start_date_local_ms is populated from intervals start_date_local; survives re-sync without bumping', async () => {
    await env.DB.prepare('DELETE FROM external_activities').run();
    const userId = await freshUser();
    await syncExternalActivities(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([act({ id: 'r1', start_date_local: '2026-05-15T07:30:00' })]),
    } as any);
    const before = await env.DB.prepare(
      'SELECT start_date_local_ms, synced_at FROM external_activities WHERE id=?1',
    )
      .bind(`intervals:activity:${userId}:r1`)
      .first<{ start_date_local_ms: number; synced_at: number }>();
    // 2026-05-15T07:30:00Z = epoch-ms 1779341400000
    expect(before!.start_date_local_ms).toBe(Date.parse('2026-05-15T07:30:00Z'));

    // Re-sync the same activity. start_date_local_ms should stay (same
    // upstream time), but synced_at moves forward.
    await new Promise((r) => setTimeout(r, 5));
    await syncExternalActivities(env.DB, env as unknown as Env, {
      userId,
      today: TODAY,
      fetcher: payload([act({ id: 'r1', start_date_local: '2026-05-15T07:30:00' })]),
    } as any);
    const after = await env.DB.prepare(
      'SELECT start_date_local_ms, synced_at FROM external_activities WHERE id=?1',
    )
      .bind(`intervals:activity:${userId}:r1`)
      .first<{ start_date_local_ms: number; synced_at: number }>();
    expect(after!.start_date_local_ms).toBe(before!.start_date_local_ms);
    // synced_at moved forward — proving the ordering proxy USED to bubble
    // this ride on every cron tick. The new start_date_local_ms stays put.
    expect(after!.synced_at).toBeGreaterThanOrEqual(before!.synced_at);
  });
});
