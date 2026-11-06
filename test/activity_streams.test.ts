// Chart series for an activity's detail view (docs/plans/run-detail-charts
// P0): the pure series builder, and GET /api/activities/:id/streams for an
// intervals.icu run (read live, stored nowhere) and an Apple Health run (from
// the route Tres Fort keeps). No real network: fetchMock.
import { env, applyD1Migrations, fetchMock, SELF } from 'cloudflare:test';
import { afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { encodeRoute, type RoutePoint } from '../src/activityRoute';
import {
  buildActivityStreams, elevationGain, haversineMeters, MAX_POINTS, samplesFromProvider, trackFromRoute,
  type TrackSample,
} from '../src/activityStreams';
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

/** `seconds` of steady running at `mps`, one sample a second. */
function steady(seconds: number, mps: number, from = { t: 0, d: 0 }): TrackSample[] {
  return Array.from({ length: seconds + 1 }, (_, i) => ({ t: from.t + i, d: from.d + i * mps, alt: 10 }));
}

describe('buildActivityStreams', () => {
  it('draws steady pace, heart rate and flat elevation in five-second points', () => {
    const track = steady(600, 3);
    const hr = track.map((s) => ({ t: s.t, v: 150 }));
    const s = buildActivityStreams(track, hr)!;
    expect(s.moving_s).toBe(600);
    expect(s.t).toHaveLength(120);
    expect(s.t[0]).toBe(3);
    expect(s.total_distance_m).toBe(1800);
    expect(s.speed_mps!.every((v) => v !== null && Math.abs(v - 3) < 0.05)).toBe(true);
    expect(s.heart_rate!.every((v) => v === 150)).toBe(true);
    expect(s.elevation_m!.every((v) => v === 10)).toBe(true);
    expect(s.elevation_gain_m).toBe(0);
  });

  it('cuts a pause out of the clock, so it neither slows the pace nor draws a gap', () => {
    // 5 min at 3 m/s, a 4 min stop with no samples, 5 min at 4 m/s.
    const first = steady(300, 3);
    const second = steady(300, 4, { t: 540, d: 900 });
    const s = buildActivityStreams([...first, ...second])!;
    expect(s.moving_s).toBe(600);
    expect(s.total_distance_m).toBe(2100);
    const speeds = s.speed_mps!;
    expect(Math.abs(speeds[10]! - 3)).toBeLessThan(0.05);
    expect(Math.abs(speeds[110]! - 4)).toBeLessThan(0.05);
    expect(speeds.every((v) => v !== null && v > 2.9 && v < 4.1)).toBe(true);
  });

  it('treats a route segment break as a pause even when it is short', () => {
    const first = steady(100, 3);
    const second = steady(100, 3, { t: 110, d: 300 }).map((p, i) => ({ ...p, newSegment: i === 0 }));
    expect(buildActivityStreams([...first, ...second])!.moving_s).toBe(200);
  });

  it('keeps a long activity to at most MAX_POINTS points', () => {
    const s = buildActivityStreams(steady(4 * 3600, 2.5))!;
    expect(s.t.length).toBeLessThanOrEqual(MAX_POINTS);
    expect(s.t.length).toBeGreaterThan(MAX_POINTS - 5);
  });

  it('leaves out a series the activity has no data for', () => {
    // Heart rate only: a strength session or an indoor workout with no distance.
    const hr = Array.from({ length: 300 }, (_, i) => ({ t: i, v: 120 + (i % 10) }));
    const s = buildActivityStreams([], hr)!;
    expect(s.distance_m).toBeNull();
    expect(s.speed_mps).toBeNull();
    expect(s.elevation_m).toBeNull();
    expect(s.total_distance_m).toBeNull();
    expect(s.heart_rate).toHaveLength(60);
  });

  it('ignores impossible heart rates', () => {
    const track = steady(120, 3);
    const hr = track.map((s) => ({ t: s.t, v: s.t < 60 ? 300 : 140 }));
    const s = buildActivityStreams(track, hr)!;
    expect(s.heart_rate!.slice(0, 12).every((v) => v === null)).toBe(true);
    expect(s.heart_rate!.slice(13).every((v) => v === 140)).toBe(true);
  });

  it('skips a one-sample GPS jump instead of carrying it to the end', () => {
    const track = steady(600, 3);
    track[60] = { ...track[60]!, d: track[60]!.d! + 5000 };
    const s = buildActivityStreams(track)!;
    expect(s.total_distance_m).toBe(1800);
    expect(s.speed_mps!.every((v) => v !== null && Math.abs(v - 3) < 0.05)).toBe(true);
  });

  it('is null for a blip too short to chart', () => {
    expect(buildActivityStreams(steady(5, 3))).toBeNull();
    expect(buildActivityStreams([])).toBeNull();
  });
});

describe('elevationGain', () => {
  it('counts real climbs and ignores noise under three meters', () => {
    expect(elevationGain([10, 11, 10, 12, 10, 11])).toBe(0);
    expect(elevationGain([10, 20, 15, 25])).toBe(20);
    expect(elevationGain([null, 5])).toBeNull();
  });
});

describe('route and provider samples', () => {
  it('walks a stored route point to point, with no distance across a pause', () => {
    const point = (i: number): RoutePoint => ({ t: START_MS + i * 1_000, lat: 45.519 + i * 0.0001, lon: -122.6793, alt: 15 });
    const route = encodeRoute([[point(0), point(1), point(2)], [point(90), point(91)]])!;
    const track = trackFromRoute(route);
    const step = haversineMeters(45.519, -122.6793, 45.5191, -122.6793);
    expect(track.map((s) => s.t)).toEqual([0, 1, 2, 90, 91]);
    expect(track[3]!.newSegment).toBe(true);
    expect(track[3]!.d).toBeCloseTo(2 * step, 1);
    expect(track[4]!.d).toBeCloseTo(3 * step, 1);
  });

  it('skips a bad GPS fix in a route, both the jump and the return', () => {
    // About 3 m/s due north for ten minutes, one fix 5 km off.
    const points = Array.from({ length: 601 }, (_, i): RoutePoint =>
      ({ t: START_MS + i * 1_000, lat: 45.519 + i * 0.000027 + (i === 300 ? 0.045 : 0), lon: -122.6793, alt: 15 }));
    const s = buildActivityStreams(trackFromRoute(encodeRoute([points])!))!;
    expect(s.total_distance_m).toBeGreaterThan(1790);
    expect(s.total_distance_m).toBeLessThan(1810);
    expect(s.speed_mps!.every((v) => v !== null && Math.abs(v - 3) < 0.1)).toBe(true);
  });

  it('starts again from new fixes when they keep disagreeing with an early bad one', () => {
    // The first fix is 5 km off; the rest are a steady run.
    const points = Array.from({ length: 301 }, (_, i): RoutePoint =>
      ({ t: START_MS + i * 1_000, lat: 45.519 + i * 0.000027 + (i === 0 ? 0.045 : 0), lon: -122.6793, alt: 15 }));
    const track = trackFromRoute(encodeRoute([points])!);
    const total = track[track.length - 1]!.d!;
    expect(total).toBeGreaterThan(800);
    expect(total).toBeLessThan(900);
  });

  it('walks no GPS distance across a recording gap, as the clock counts no time', () => {
    // 300 s at 3 m/s, a 240 s gap moving 500 m, then 300 s at 3 m/s; no
    // distance stream, so distance comes from the positions.
    const meters = (m: number) => m / 111_195;
    const time: number[] = [];
    const lat: number[] = [];
    for (let i = 0; i <= 300; i++) { time.push(i); lat.push(45 + meters(3 * i)); }
    for (let i = 0; i <= 300; i++) { time.push(540 + i); lat.push(45 + meters(900 + 500 + 3 * i)); }
    const { track } = samplesFromProvider({
      time, distance: null, heartrate: null, altitude: null, lat, lon: lat.map(() => -122),
    });
    const s = buildActivityStreams(track)!;
    expect(s.moving_s).toBe(600);
    expect(s.total_distance_m).toBeGreaterThan(1790);
    expect(s.total_distance_m).toBeLessThan(1810);
    expect(s.speed_mps!.every((v) => v !== null && v < 3.2)).toBe(true);
  });

  it('drops distance a provider counted across a pause', () => {
    const first = steady(300, 3);
    const second = steady(300, 3, { t: 540, d: 1400 });
    const s = buildActivityStreams([...first, ...second])!;
    expect(s.total_distance_m).toBe(1800);
    expect(s.speed_mps!.every((v) => v !== null && Math.abs(v - 3) < 0.05)).toBe(true);
  });

  it('prefers the provider distance stream and falls back to GPS positions', () => {
    const withDistance = samplesFromProvider({
      time: [0, 1, 2], distance: [0, 3, 6], heartrate: [140, null, 142], altitude: null,
      lat: [45.5, 45.6, 45.7], lon: [-122, -122, -122],
    });
    expect(withDistance.track.map((s) => s.d)).toEqual([0, 3, 6]);
    expect(withDistance.heartRate).toEqual([{ t: 0, v: 140 }, { t: 2, v: 142 }]);
    const gpsOnly = samplesFromProvider({
      time: null, distance: null, heartrate: null, altitude: [1, 2],
      lat: [45.519, 45.5191], lon: [-122.6793, -122.6793],
    });
    expect(gpsOnly.track[0]).toEqual({ t: 0, d: 0, alt: 1 });
    expect(gpsOnly.track[1]!.d).toBeCloseTo(11.1, 1);
  });
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

async function member(): Promise<{ id: string; jwt: string }> {
  await owner();
  const id = crypto.randomUUID();
  await env.DB.prepare('INSERT INTO users (id,apple_sub,created_at) VALUES (?1,?1,?2)').bind(id, Date.now()).run();
  return { id, jwt: await issueAppJwt(id, 'test-secret') };
}

async function intervalsRun(userId: string): Promise<{ id: string; external: string }> {
  const external = `i${Math.floor(Math.random() * 1e9)}`;
  const id = `intervals:activity:${userId}:${external}`;
  await env.DB.prepare(
    `INSERT INTO external_activities
       (id,user_id,source,external_id,date,start_date_local_ms,start_date_utc_ms,kind,name,moving_time_sec,raw,synced_at)
     VALUES (?1,?2,'intervals',?3,'2026-11-01',?4,?4,'run','Zone 3 Run',600,?5,?6)`,
  ).bind(id, userId, external, START_MS, JSON.stringify({ id: external }), Date.now()).run();
  return { id, external };
}

const streamsPath = (external: string) => (path: string) => {
  const u = new URL(path, ORIGIN);
  return u.pathname === `/api/v1/activity/${external}/streams`
    && u.searchParams.get('types') === 'time,distance,heartrate,altitude,latlng';
};

async function streams(jwt: string, activityId: string) {
  const r = await SELF.fetch(`${BASE}/api/activities/${encodeURIComponent(activityId)}/streams`, {
    headers: { Authorization: `Bearer ${jwt}` },
  });
  return { status: r.status, body: await r.json<any>() };
}

describe('GET /api/activities/:id/streams', () => {
  it('charts an intervals.icu run from its streams, heart rate included, and stores nothing', async () => {
    const me = await owner();
    const run = await intervalsRun(me.id);
    const n = 601;
    fetchMock.get(ORIGIN).intercept({ method: 'GET', path: streamsPath(run.external) }).reply(200, [
      { type: 'time', data: Array.from({ length: n }, (_, i) => i) },
      { type: 'distance', data: Array.from({ length: n }, (_, i) => i * 3) },
      { type: 'heartrate', data: Array.from({ length: n }, (_, i) => 130 + Math.floor(i / 20)) },
      { type: 'altitude', data: Array.from({ length: n }, (_, i) => 20 + i / 20) },
    ]);
    const res = await streams(me.jwt, run.id);
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ activity_id: run.id, source: 'intervals' });
    const s = res.body.streams;
    expect(s).toMatchObject({ v: 1, moving_s: 600, total_distance_m: 1800 });
    expect(s.t).toHaveLength(120);
    expect(s.heart_rate[0]).toBe(130);
    expect(s.heart_rate[119]).toBe(159);
    expect(s.elevation_gain_m).toBeGreaterThanOrEqual(27);
    fetchMock.assertNoPendingInterceptors();
    const stored = await env.DB.prepare('SELECT COUNT(*) AS n FROM activity_routes WHERE activity_id = ?1')
      .bind(run.id).first<{ n: number }>();
    expect(stored!.n).toBe(0);
  });

  it('answers 404 when intervals.icu has nothing to chart, 502 when it is down', async () => {
    const me = await owner();
    const manual = await intervalsRun(me.id);
    const busy = await intervalsRun(me.id);
    const provider = fetchMock.get(ORIGIN);
    provider.intercept({ method: 'GET', path: streamsPath(manual.external) }).reply(200, []);
    provider.intercept({ method: 'GET', path: streamsPath(busy.external) }).reply(503, {});
    expect(await streams(me.jwt, manual.id)).toEqual({ status: 404, body: { error: 'not_found' } });
    expect(await streams(me.jwt, busy.id)).toEqual({ status: 502, body: { error: 'intervals_unavailable' } });
    fetchMock.assertNoPendingInterceptors();
  });

  it('charts an Apple Health run from the route Tres Fort keeps, for its member only', async () => {
    const me = await member();
    const healthId = crypto.randomUUID().toUpperCase();
    const pushed = await SELF.fetch(`${BASE}/api/activities/healthkit`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${me.jwt}`, 'content-type': 'application/json' },
      body: JSON.stringify({
        id: healthId, date: '2026-11-01', kind: 'run', name: 'Run',
        start_date_local_ms: START_MS - 8 * 3_600_000, start_date_utc_ms: START_MS,
        source_timezone: 'America/Los_Angeles', moving_time_sec: 300, distance_m: 900,
      }),
    });
    expect(pushed.status).toBe(201);
    const activityId = (await pushed.json<any>()).id as string;
    // Due north at about 3 m/s, climbing ten meters.
    const points = Array.from({ length: 301 }, (_, i): RoutePoint =>
      ({ t: START_MS + i * 1_000, lat: 45.519 + i * 0.000027, lon: -122.6793, alt: 15 + i / 30 }));
    const put = await SELF.fetch(`${BASE}/api/activities/healthkit/${healthId}/route`, {
      method: 'PUT',
      headers: { Authorization: `Bearer ${me.jwt}`, 'content-type': 'application/json' },
      body: JSON.stringify({ route: encodeRoute([points]) }),
    });
    expect(put.status).toBe(200);

    const res = await streams(me.jwt, activityId);
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ activity_id: activityId, source: 'healthkit' });
    const s = res.body.streams;
    expect(s.moving_s).toBe(300);
    expect(s.heart_rate).toBeNull();
    expect(Math.abs(s.speed_mps[30] - 3)).toBeLessThan(0.1);
    expect(s.elevation_gain_m).toBeGreaterThanOrEqual(8);

    const other = await member();
    expect(await streams(other.jwt, activityId)).toEqual({ status: 404, body: { error: 'not_found' } });
  });
});
