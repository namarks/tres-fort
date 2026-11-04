// PUT /api/activities/healthkit/:id/route keeps the GPS route Apple Health
// saved with a run another app recorded, and GET /api/activities/:id/route
// serves it to its member only (docs/plans/run-recorder P6(b)). No real
// network: fetchMock, so a call to intervals.icu would fail the read.
import { env, applyD1Migrations, fetchMock, SELF } from 'cloudflare:test';
import { afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { decodeRoute, encodeRoute, type RoutePoint } from '../src/activityRoute';
import { dedupeHealthKitAgainstIntervals } from '../src/db';
import { issueAppJwt } from '../src/auth';

const BASE = 'https://tres-fort.test';
const START_MS = Date.parse('2026-10-24T15:00:00Z');

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});
beforeEach(() => {
  fetchMock.activate();
  fetchMock.disableNetConnect();
});
afterEach(() => {
  fetchMock.deactivate();
  fetchMock.enableNetConnect();
});

async function member(): Promise<{ id: string; jwt: string }> {
  const r = await SELF.fetch(`${BASE}/auth/dev`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ secret: 'test-dev' }),
  });
  expect(r.status).toBe(200);
  const id = crypto.randomUUID();
  await env.DB.prepare('INSERT INTO users (id,apple_sub,created_at) VALUES (?1,?1,?2)').bind(id, Date.now()).run();
  return { id, jwt: await issueAppJwt(id, 'test-secret') };
}

const auth = (jwt: string) => ({ Authorization: `Bearer ${jwt}` });

/** A Health workout as the app pushes it; its id is the HKWorkout UUID. */
async function pushHealth(jwt: string, kind = 'run', laterMs = 0): Promise<{ healthId: string; activityId: string }> {
  const healthId = crypto.randomUUID().toUpperCase();
  const r = await SELF.fetch(`${BASE}/api/activities/healthkit`, {
    method: 'POST',
    headers: { ...auth(jwt), 'content-type': 'application/json' },
    body: JSON.stringify({
      id: healthId, date: '2026-10-24', kind, name: 'Run',
      start_date_local_ms: START_MS - 7 * 3_600_000 + laterMs, start_date_utc_ms: START_MS + laterMs,
      source_timezone: 'America/Los_Angeles', moving_time_sec: 1602, distance_m: 5103.6,
    }),
  });
  expect(r.status).toBe(201);
  return { healthId, activityId: (await r.json<any>()).id as string };
}

/** Two segments, as a pause in Strava splits a run. */
function route() {
  const point = (i: number): RoutePoint =>
    ({ t: START_MS + i * 1_000, lat: 45.519 + i * 0.0001, lon: -122.6793, alt: 15 + i * 0.1 });
  return encodeRoute([[point(0), point(1), point(2)], [point(90), point(91)]])!;
}

async function putRoute(jwt: string, healthId: string, body: unknown) {
  const r = await SELF.fetch(`${BASE}/api/activities/healthkit/${healthId}/route`, {
    method: 'PUT',
    headers: { ...auth(jwt), 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  return { status: r.status, body: await r.json<any>() };
}

async function getRoute(jwt: string, activityId: string) {
  const r = await SELF.fetch(`${BASE}/api/activities/${encodeURIComponent(activityId)}/route`, { headers: auth(jwt) });
  return { status: r.status, body: await r.json<any>() };
}

describe('Apple Health run routes', () => {
  it('keeps the route of a Health run and serves it to its member only', async () => {
    const me = await member();
    const other = await member();
    const run = await pushHealth(me.jwt);
    expect((await getRoute(me.jwt, run.activityId)).status).toBe(404);

    const saved = await putRoute(me.jwt, run.healthId.toLowerCase(), { route: route() });
    expect(saved).toEqual({ status: 200, body: { ok: true, activity_id: run.activityId, point_count: 5 } });

    const served = await getRoute(me.jwt, run.activityId);
    expect(served.status).toBe(200);
    expect(served.body).toMatchObject({ activity_id: run.activityId, source: 'healthkit', recording_id: null });
    expect(decodeRoute(served.body.route).map((s) => s.length)).toEqual([3, 2]);

    expect((await getRoute(other.jwt, run.activityId)).status).toBe(404);
    expect((await putRoute(other.jwt, run.healthId, { route: route() })).status).toBe(404);
  });

  it('replaces the route on a later send and drops invalid points', async () => {
    const me = await member();
    const run = await pushHealth(me.jwt);
    expect((await putRoute(me.jwt, run.healthId, { route: route() })).status).toBe(200);
    const shorter = encodeRoute([[{ t: START_MS, lat: 45.5, lon: -122.6, alt: null },
      { t: START_MS + 1_000, lat: 45.5001, lon: -122.6, alt: null }]])!;
    // A latitude past the pole is no position.
    const withBadPoint = { ...shorter, dt: [...shorter.dt, 1_000], dlat: [...shorter.dlat, 90_000_000],
      dlon: [...shorter.dlon, 0], alt: [...shorter.alt, null] };
    expect(await putRoute(me.jwt, run.healthId, { route: withBadPoint }))
      .toEqual({ status: 200, body: { ok: true, activity_id: run.activityId, point_count: 2 } });
    const served = await getRoute(me.jwt, run.activityId);
    expect(decodeRoute(served.body.route)).toEqual([[
      { t: START_MS, lat: 45.5, lon: -122.6, alt: null },
      { t: START_MS + 1_000, lat: 45.5001, lon: -122.6, alt: null },
    ]]);
  });

  it('refuses a workout not stored yet, one that is not a run, a deleted run and a malformed route', async () => {
    const me = await member();
    expect((await putRoute(me.jwt, crypto.randomUUID(), { route: route() })).status).toBe(404);
    const ride = await pushHealth(me.jwt, 'ride');
    expect(await putRoute(me.jwt, ride.healthId, { route: route() }))
      .toEqual({ status: 422, body: { error: 'not_a_run' } });
    const run = await pushHealth(me.jwt);
    expect(await putRoute(me.jwt, run.healthId, { route: { ...route(), v: 2 } }))
      .toEqual({ status: 400, body: { error: 'invalid_route' } });
    expect(await putRoute(me.jwt, run.healthId, { route: encodeRoute([[{ t: 0, lat: 1, lon: 1, alt: null }]]) }))
      .toMatchObject({ status: 200 });
    expect((await putRoute(me.jwt, 'not-a-uuid', { route: route() })).status).toBe(400);

    // A later run, so it is not an Apple Health copy of the one above.
    const deleted = await pushHealth(me.jwt, 'run', 3_600_000);
    await env.DB.prepare('UPDATE external_activities SET deleted_at = ?2 WHERE id = ?1')
      .bind(deleted.activityId, Date.now()).run();
    expect((await putRoute(me.jwt, deleted.healthId, { route: route() })).status).toBe(404);
    const kept = await env.DB.prepare('SELECT COUNT(*) AS n FROM activity_routes WHERE activity_id = ?1')
      .bind(deleted.activityId).first<{ n: number }>();
    expect(kept!.n).toBe(0);
  });

  it('serves the Health route for the intervals.icu copy it hides behind, without asking intervals.icu', async () => {
    const me = await member();
    const run = await pushHealth(me.jwt);
    expect((await putRoute(me.jwt, run.healthId, { route: route() })).status).toBe(200);
    const intervals = `intervals:activity:${me.id}:i4242`;
    await env.DB.prepare(
      `INSERT INTO external_activities
         (id,user_id,source,external_id,date,start_date_local_ms,start_date_utc_ms,kind,name,moving_time_sec,raw,synced_at)
       VALUES (?1,?2,'intervals','i4242','2026-10-24',?3,?4,'run','Run',1602,'{}',?5)`,
    ).bind(intervals, me.id, START_MS - 7 * 3_600_000, START_MS, Date.now()).run();
    await dedupeHealthKitAgainstIntervals(env.DB, me.id);
    const hidden = await env.DB.prepare('SELECT duplicate_of FROM external_activities WHERE id = ?1')
      .bind(run.activityId).first<{ duplicate_of: string | null }>();
    expect(hidden!.duplicate_of).toBe(intervals);

    const served = await getRoute(me.jwt, intervals);
    expect(served.status).toBe(200);
    expect(served.body).toMatchObject({ activity_id: run.activityId, source: 'healthkit', recording_id: null });
  });
});
