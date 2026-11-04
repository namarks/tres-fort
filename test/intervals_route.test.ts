// GET /api/activities/:id/route for an intervals.icu run: with no recording
// behind it, the track is read from intervals.icu's streams and served
// without being stored (docs/plans/run-recorder P6). No real network:
// fetchMock.
import { env, applyD1Migrations, fetchMock, SELF } from 'cloudflare:test';
import { afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { decodeRoute } from '../src/activityRoute';
import { issueAppJwt } from '../src/auth';

const BASE = 'https://tres-fort.test';
const ORIGIN = 'https://intervals.icu';
const START_MS = Date.parse('2026-11-01T15:00:00Z');

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

/** The owner, whose intervals.icu connection is the test environment's. */
async function owner(): Promise<{ id: string; jwt: string }> {
  const r = await SELF.fetch(`${BASE}/auth/dev`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ secret: 'test-dev' }),
  });
  expect(r.status).toBe(200);
  const jwt = (await r.json<{ jwt: string }>()).jwt;
  const row = await env.DB.prepare('SELECT id FROM users ORDER BY created_at LIMIT 1').first<{ id: string }>();
  return { id: row!.id, jwt };
}

/** Another member, with no intervals.icu connection. */
async function member(): Promise<{ id: string; jwt: string }> {
  await owner();
  const id = crypto.randomUUID();
  await env.DB.prepare('INSERT INTO users (id,apple_sub,created_at) VALUES (?1,?1,?2)').bind(id, Date.now()).run();
  return { id, jwt: await issueAppJwt(id, 'test-secret') };
}

/** An intervals.icu run as the activity sync caches it. */
async function intervalsRun(userId: string, opts: { deleted?: boolean } = {}): Promise<{ id: string; external: string }> {
  const external = `i${Math.floor(Math.random() * 1e9)}`;
  const id = `intervals:activity:${userId}:${external}`;
  await env.DB.prepare(
    `INSERT INTO external_activities
       (id,user_id,source,external_id,date,start_date_local_ms,start_date_utc_ms,kind,name,moving_time_sec,raw,synced_at,deleted_at)
     VALUES (?1,?2,'intervals',?3,'2026-11-01',?4,?4,'run','Zone 3 Run',1537,?5,?6,?7)`,
  ).bind(id, userId, external, START_MS, JSON.stringify({ id: external }), Date.now(),
    opts.deleted ? Date.now() : null).run();
  return { id, external };
}

const streamsPath = (external: string) => (path: string) => {
  const u = new URL(path, ORIGIN);
  return u.pathname === `/api/v1/activity/${external}/streams`
    && u.searchParams.get('types') === 'time,latlng,altitude';
};

async function route(jwt: string, activityId: string) {
  const r = await SELF.fetch(`${BASE}/api/activities/${encodeURIComponent(activityId)}/route`, {
    headers: { Authorization: `Bearer ${jwt}` },
  });
  return { status: r.status, body: await r.json<any>() };
}

describe('GET /api/activities/:id/route for an intervals.icu run', () => {
  it('reads the track from intervals.icu, split where the watch paused, and stores nothing', async () => {
    const me = await owner();
    const run = await intervalsRun(me.id);
    fetchMock.get(ORIGIN).intercept({ method: 'GET', path: streamsPath(run.external) }).reply(200, [
      { type: 'time', data: [0, 1, 2, 3, 200, 201] },
      {
        type: 'latlng',
        data: [45.519, 45.5191, 45.5192, 45.5193, 45.53, 45.5301],
        data2: [-122.6793, -122.6794, -122.6795, -122.6796, -122.68, -122.6801],
      },
      { type: 'altitude', data: [15, 15.5, 16, 16.5, 20, 20.5] },
      { type: 'heartrate', data: [140, 141, 142, 143, 150, 151] },
    ]);
    const res = await route(me.jwt, run.id);
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ activity_id: run.id, source: 'intervals', recording_id: null });
    const segments = decodeRoute(res.body.route);
    expect(segments.map((s) => s.map((p) => p.t - START_MS))).toEqual([[0, 1_000, 2_000, 3_000], [200_000, 201_000]]);
    expect(segments[0]![0]).toEqual({ t: START_MS, lat: 45.519, lon: -122.6793, alt: 15 });
    fetchMock.assertNoPendingInterceptors();
    const stored = await env.DB.prepare('SELECT COUNT(*) AS n FROM activity_routes WHERE activity_id = ?1')
      .bind(run.id).first<{ n: number }>();
    expect(stored!.n).toBe(0);
  });

  it('answers 404 for a run with no GPS track or one intervals.icu no longer has', async () => {
    const me = await owner();
    const indoor = await intervalsRun(me.id);
    const gone = await intervalsRun(me.id);
    const provider = fetchMock.get(ORIGIN);
    provider.intercept({ method: 'GET', path: streamsPath(indoor.external) })
      .reply(200, [{ type: 'time', data: [0, 1, 2] }, { type: 'altitude', data: [1, 1, 1] }]);
    provider.intercept({ method: 'GET', path: streamsPath(gone.external) }).reply(404, { error: 'Not found' });
    expect(await route(me.jwt, indoor.id)).toEqual({ status: 404, body: { error: 'not_found' } });
    expect(await route(me.jwt, gone.id)).toEqual({ status: 404, body: { error: 'not_found' } });
    fetchMock.assertNoPendingInterceptors();
  });

  it('answers 502 when intervals.icu is busy or down, so the app tries again later', async () => {
    const me = await owner();
    const run = await intervalsRun(me.id);
    const provider = fetchMock.get(ORIGIN);
    provider.intercept({ method: 'GET', path: streamsPath(run.external) }).reply(429, {});
    provider.intercept({ method: 'GET', path: streamsPath(run.external) }).reply(503, {});
    expect(await route(me.jwt, run.id)).toEqual({ status: 502, body: { error: 'intervals_unavailable' } });
    expect(await route(me.jwt, run.id)).toEqual({ status: 502, body: { error: 'intervals_unavailable' } });
    fetchMock.assertNoPendingInterceptors();
  });

  it('asks intervals.icu nothing for a deleted run, another member\'s run or a member with no connection', async () => {
    const me = await owner();
    const deleted = await intervalsRun(me.id, { deleted: true });
    const other = await member();
    const theirs = await intervalsRun(other.id);
    const mine = await intervalsRun(me.id);
    // Any call to intervals.icu would fail the request with a 502.
    expect((await route(me.jwt, deleted.id)).status).toBe(404);
    expect((await route(other.jwt, mine.id)).status).toBe(404);
    expect((await route(me.jwt, theirs.id)).status).toBe(404);
    expect((await route(other.jwt, theirs.id)).status).toBe(404);
  });
});
