// POST /api/activities/endurance: a run, ride, swim or walk entered by hand in
// the app goes to intervals.icu like the coach's log_activity, never the local
// activities log. Retries are idempotent on the client id, and provider
// failures are errors with nothing saved. No real network: fetchMock.
import { env, applyD1Migrations, fetchMock, SELF } from 'cloudflare:test';
import { afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { getUserIntervalsCreds } from '../src/db';
import { issueAppJwt } from '../src/auth';

const BASE = 'https://tres-fort.test';
const ORIGIN = 'https://intervals.icu';
const ATHLETE = 'i12345';
const DATE = '2026-10-27';
const ACTIVITIES = `/api/v1/athlete/${ATHLETE}/activities`;

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

async function devJwt(): Promise<string> {
  const r = await SELF.fetch(`${BASE}/auth/dev`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ secret: 'test-dev' }),
  });
  expect(r.status).toBe(200);
  return (await r.json<{ jwt: string }>()).jwt;
}

async function post(jwt: string | null, body: unknown) {
  const r = await SELF.fetch(`${BASE}/api/activities/endurance`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...(jwt ? { Authorization: `Bearer ${jwt}` } : {}) },
    body: JSON.stringify(body),
  });
  return { status: r.status, body: await r.json<any>() };
}

async function localCount(): Promise<number> {
  return (await env.DB.prepare('SELECT COUNT(*) AS c FROM activities').first<{ c: number }>())!.c;
}

const activitiesPath = (pred: (q: URLSearchParams) => boolean) => (path: string) => {
  const u = new URL(path, ORIGIN);
  return u.pathname === ACTIVITIES && pred(u.searchParams);
};
/** The duplicate check asks for exactly the activity's date. */
const dayLookup = activitiesPath((q) => q.get('oldest') === DATE && q.get('newest') === DATE);
/** The post-write refresh asks for a wider window. */
const refreshWindow = activitiesPath((q) => q.get('oldest') !== q.get('newest'));

function created(body: any, id = 'i990') {
  return {
    id,
    type: body.type,
    name: body.name,
    start_date_local: body.start_date_local,
    start_date: `${body.start_date_local}Z`,
    moving_time: body.moving_time,
    elapsed_time: body.elapsed_time,
    distance: body.distance ?? null,
    external_id: body.external_id,
  };
}

describe('POST /api/activities/endurance', () => {
  beforeEach(() => {
    fetchMock.activate();
    fetchMock.disableNetConnect();
  });
  afterEach(() => {
    fetchMock.deactivate();
    fetchMock.enableNetConnect();
  });

  it('creates the run on intervals.icu with its distance and time and writes nothing locally', async () => {
    const jwt = await devJwt();
    const before = await localCount();
    const id = crypto.randomUUID();
    const provider = fetchMock.get(ORIGIN);
    provider.intercept({ method: 'GET', path: dayLookup }).reply(200, []);
    let sent: any = null;
    provider.intercept({ method: 'POST', path: `${ACTIVITIES}/manual` }).reply(200, (opts) => {
      sent = JSON.parse(String(opts.body));
      return created(sent);
    });
    provider.intercept({ method: 'GET', path: refreshWindow }).reply(200, []);

    const res = await post(jwt, {
      id, date: DATE, type: 'run', duration_s: 1447.4, distance_m: 4844.1,
      start_time: '7:30', title: ' Lunch loop ', notes: 'Easy effort', avg_hr: 151,
    });

    expect(res.status).toBe(201);
    expect(res.body).toMatchObject({
      ok: true,
      destination: 'intervals.icu',
      deduplicated: false,
      activity_id: id,
      intervals_activity: { id: 'i990' },
      refresh: { status: 'ok' },
    });
    expect(sent).toEqual({
      name: 'Lunch loop',
      type: 'Run',
      trainer: false,
      start_date_local: `${DATE}T07:30:00`,
      moving_time: 1447,
      elapsed_time: 1447,
      distance: 4844.1,
      average_heartrate: 151,
      description: 'Easy effort',
      external_id: `tresfort:activity:${id}`,
    });
    fetchMock.assertNoPendingInterceptors();
    expect(await localCount()).toBe(before);
  });

  it('marks an indoor ride as a trainer ride and names it after its type', async () => {
    const jwt = await devJwt();
    const provider = fetchMock.get(ORIGIN);
    provider.intercept({ method: 'GET', path: dayLookup }).reply(200, []);
    let sent: any = null;
    provider.intercept({ method: 'POST', path: `${ACTIVITIES}/manual` }).reply(200, (opts) => {
      sent = JSON.parse(String(opts.body));
      return created(sent);
    });
    provider.intercept({ method: 'GET', path: refreshWindow }).reply(200, []);
    const res = await post(jwt, {
      id: crypto.randomUUID(), date: DATE, type: 'ride', duration_s: 2700, indoor: true, start_time: '18:00',
    });
    expect(res.status).toBe(201);
    expect(sent).toMatchObject({ type: 'VirtualRide', trainer: true, moving_time: 2700 });
    expect(sent.distance).toBeUndefined();
    expect(sent.name).toBe(res.body.intervals_activity.name);
  });

  it('returns the activity the first attempt created when retried', async () => {
    const jwt = await devJwt();
    const id = crypto.randomUUID();
    const provider = fetchMock.get(ORIGIN);
    provider.intercept({ method: 'GET', path: dayLookup }).reply(200, [{
      id: 'i991', type: 'Swim', start_date_local: `${DATE}T06:00:00`, moving_time: 900,
      elapsed_time: 900, external_id: `tresfort:activity:${id}`,
    }]);
    provider.intercept({ method: 'GET', path: refreshWindow }).reply(200, []);
    // No create interceptor: a second create would fail closed.
    const res = await post(jwt, { id, date: DATE, type: 'swim', duration_s: 1800, distance_m: 1500 });
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ ok: true, deduplicated: true, activity_id: id });
  });

  it('reports a write rejection without disconnecting the read credential', async () => {
    const jwt = await devJwt();
    const provider = fetchMock.get(ORIGIN);
    provider.intercept({ method: 'GET', path: dayLookup }).reply(200, []);
    provider.intercept({ method: 'POST', path: `${ACTIVITIES}/manual` }).reply(403, { error: 'insufficient scope' });
    const res = await post(jwt, { id: crypto.randomUUID(), date: DATE, type: 'walk', duration_s: 1800 });
    expect(res.status).toBe(409);
    expect(res.body).toMatchObject({ error: 'intervals_write_forbidden', status: 403 });
    const owner = await env.DB.prepare('SELECT id FROM users ORDER BY created_at LIMIT 1').first<{ id: string }>();
    const creds = await getUserIntervalsCreds(env.DB, owner!.id);
    expect(creds.athlete_id).toBe(ATHLETE);
  });

  it('reports an unreachable provider as an error with nothing saved', async () => {
    const jwt = await devJwt();
    const before = await localCount();
    fetchMock.get(ORIGIN).intercept({ method: 'GET', path: dayLookup }).reply(503, {});
    const res = await post(jwt, { id: crypto.randomUUID(), date: DATE, type: 'run', duration_s: 1800 });
    expect(res.status).toBe(502);
    expect(res.body).toMatchObject({ error: 'intervals_unavailable' });
    expect(await localCount()).toBe(before);
  });

  it('tells a member without an intervals.icu connection that nothing was saved', async () => {
    await devJwt(); // The owner row exists, so the env credential stays the owner's.
    const id = crypto.randomUUID();
    await env.DB.prepare('INSERT INTO users (id,apple_sub,created_at) VALUES (?1,?1,?2)').bind(id, Date.now()).run();
    const jwt = await issueAppJwt(id, 'test-secret');
    const res = await post(jwt, { id: crypto.randomUUID(), date: DATE, type: 'run', duration_s: 1800 });
    expect(res.status).toBe(409);
    expect(res.body).toMatchObject({ error: 'intervals_not_connected' });
  });

  it('validates the body before contacting intervals.icu', async () => {
    const jwt = await devJwt();
    const ok = { id: crypto.randomUUID(), date: DATE, type: 'run', duration_s: 1800 };
    expect(await post(null, ok)).toMatchObject({ status: 401 });
    expect(await post(jwt, { ...ok, type: 'pilates' })).toMatchObject({
      status: 400, body: { error: 'invalid_fields', fields: ['type'] },
    });
    expect(await post(jwt, { ...ok, id: 'nope', duration_s: 0 })).toMatchObject({
      status: 400, body: { error: 'invalid_fields', fields: ['id', 'duration_s'] },
    });
    expect(await post(jwt, { ...ok, date: '10/27/2026', distance_m: -1, start_time: '25:00', avg_hr: 300 })).toMatchObject({
      status: 400, body: { error: 'invalid_fields', fields: ['date', 'distance_m', 'start_time', 'avg_hr'] },
    });
    expect(await post(jwt, { ...ok, title: 'x'.repeat(201), indoor: 'yes' })).toMatchObject({
      status: 400, body: { error: 'invalid_fields', fields: ['indoor', 'title'] },
    });
  });
});
