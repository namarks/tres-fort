import { env, applyD1Migrations } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { fetchPlannedEvents, type Fetcher } from '../src/intervals';
import {
  ensureOwnerUser,
  getUpcomingRides,
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
      { ...env, INTERVALS_ICU_API_KEY: undefined } as unknown as Env,
      { fetcher: spy, today: TODAY },
    );
    expect(res).toEqual({ ok: false, reason: 'disabled' });
    expect(called).toBe(false);
  });

  it('parses 2xx, filters non-WORKOUT, uses start_date_local verbatim', async () => {
    const res = await fetchPlannedEvents(env as unknown as Env, {
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
    expect(await fetchPlannedEvents(env as unknown as Env, { fetcher: httpErr(500), today: TODAY }))
      .toEqual({ ok: false, reason: 'http', status: 500 });
    expect(
      await fetchPlannedEvents(env as unknown as Env, { fetcher: timeoutFetcher, today: TODAY }),
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
    expect(rows.map((x) => x.id).sort()).toEqual(['intervals:a', 'intervals:b']);
    expect(rows.find((x) => x.id === 'intervals:a')!.date).toBe('2026-05-20');
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
    expect(rows[0]!.id).toBe('intervals:a');
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
    expect(live.map((x) => x.id)).toEqual(['intervals:a']);
    const dead = await env.DB.prepare(
      "SELECT deleted_at FROM external_events WHERE id='intervals:b'",
    ).first<{ deleted_at: number | null }>();
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
    expect(live.map((x) => x.id).sort()).toEqual(['intervals:a', 'intervals:b']);
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
    expect(live.map((x) => x.id)).toEqual(['intervals:a']);
    // Symmetric with the 500-guard test: prove the existing row was NOT
    // soft-deleted by the timed-out sync (deleted_at still NULL).
    const row = await env.DB.prepare(
      "SELECT deleted_at FROM external_events WHERE id='intervals:a'",
    ).first<{ deleted_at: number | null }>();
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
      "SELECT deleted_at FROM external_events WHERE id='intervals:a'",
    ).first<{ deleted_at: number | null }>();
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
    expect(rows.some((x) => x.id === 'intervals:owner-ride')).toBe(true);
  });
});
