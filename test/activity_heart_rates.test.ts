// Heart-rate series Tres Fort keeps for a member's own workouts
// (docs/plans/run-detail-charts P3, migration 0068): the encoding, charting
// readings already on moving time, and the Apple Health push and .fit
// import that fill the series. The recorder's upload is covered in run_recording.test.ts, account
// deletion in account_deletion.test.ts.
import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { encodeRoute, type RoutePoint } from '../src/activityRoute';
import { buildActivityStreams, type TrackSample } from '../src/activityStreams';
import {
  decodeHeartRate, encodeHeartRate, MAX_HEART_RATE_POINTS, parseStoredHeartRate,
} from '../src/heartRateSeries';
import { issueAppJwt } from '../src/auth';
import { parseFit } from '../src/fitFile';
import { activityFit } from './fitWriter';

const BASE = 'https://tres-fort.test';
const START_MS = Date.parse('2026-11-01T15:00:00Z');

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

describe('heart-rate series encoding', () => {
  it('keeps one whole-bpm reading a second, delta-coded, and decodes it back', () => {
    const encoded = encodeHeartRate([
      { t: 0.2, v: 140 }, { t: 0.7, v: 141 }, { t: 3, v: 150.4 }, { t: 2, v: 145 },
      { t: 5, v: 300 }, { t: 6, v: 10 }, { t: -1, v: 150 }, { t: 7, v: Number.NaN },
    ], START_MS)!;
    expect(encoded).toEqual({ v: 1, start_ms: START_MS, dt: [0, 2, 1], bpm: [141, 145, 150] });
    expect(decodeHeartRate(encoded)).toEqual([{ t: 0, v: 141 }, { t: 2, v: 145 }, { t: 3, v: 150 }]);
    expect(parseStoredHeartRate(JSON.stringify(encoded))).toEqual(encoded);
  });

  it('is null with no usable reading, and caps a series at a day', () => {
    expect(encodeHeartRate([], null)).toBeNull();
    expect(encodeHeartRate([{ t: 1, v: 0 }], null)).toBeNull();
    expect(encodeHeartRate([{ t: MAX_HEART_RATE_POINTS, v: 150 }], null)).toBeNull();
    expect(parseStoredHeartRate('{"v":1,"dt":[1],"bpm":[150]}')).toEqual({ v: 1, start_ms: null, dt: [1], bpm: [150] });
  });

  it('refuses stored text that is not a series', () => {
    for (const text of ['', '{}', 'null', '{"v":1,"dt":[1],"bpm":[]}', '{"v":1,"dt":[-1],"bpm":[150]}',
      '{"v":2,"dt":[1],"bpm":[150]}', '{"v":1,"dt":[1],"bpm":[400]}', '{"v":1,"start_ms":"x","dt":[1],"bpm":[150]}']) {
      expect(parseStoredHeartRate(text)).toBeNull();
    }
  });
});

describe('buildActivityStreams with heart rate on moving time', () => {
  it('lines readings up with the route after a pause, as the source took it out', () => {
    // Five minutes, a two-minute stop, five more minutes; heart rate 140
    // then 160, its clock already without the stop.
    const track: TrackSample[] = [
      ...Array.from({ length: 301 }, (_, i) => ({ t: i, d: i * 3, alt: 10 })),
      ...Array.from({ length: 301 }, (_, i) => ({ t: 420 + i, d: 900 + i * 3, alt: 10 })),
    ];
    const hr = Array.from({ length: 600 }, (_, t) => ({ t, v: t < 300 ? 140 : 160 }));
    const s = buildActivityStreams(track, hr, { heartRateClock: 'moving' })!;
    expect(s.moving_s).toBe(600);
    expect(s.heart_rate![0]).toBe(140);
    expect(s.heart_rate![58]).toBe(140);
    expect(s.heart_rate![61]).toBe(160);
    expect(s.heart_rate![119]).toBe(160);
  });

  it('charts heart rate alone over its own moving time, a strap dropout included', () => {
    const hr = [
      ...Array.from({ length: 200 }, (_, t) => ({ t, v: 150 })),
      ...Array.from({ length: 200 }, (_, i) => ({ t: 400 + i, v: 150 })),
    ];
    const s = buildActivityStreams([], hr, { heartRateClock: 'moving' })!;
    expect(s.moving_s).toBe(599);
    expect(s.heart_rate![50]).toBeNull();
    expect(s.speed_mps).toBeNull();
  });
});

async function member(): Promise<{ id: string; jwt: string }> {
  const id = crypto.randomUUID();
  await env.DB.prepare('INSERT INTO users (id,apple_sub,created_at) VALUES (?1,?1,?2)').bind(id, Date.now()).run();
  return { id, jwt: await issueAppJwt(id, 'test-secret') };
}

const auth = (jwt: string) => ({ Authorization: `Bearer ${jwt}`, 'content-type': 'application/json' });

/** Push an Apple Health workout; `streams` as the app sends it. */
async function push(jwt: string, id: string, extra: Record<string, unknown> = {}) {
  const r = await SELF.fetch(`${BASE}/api/activities/healthkit`, {
    method: 'POST',
    headers: auth(jwt),
    body: JSON.stringify({
      id, date: '2026-11-01', kind: 'run', name: 'Run',
      start_date_local_ms: START_MS - 8 * 3_600_000, start_date_utc_ms: START_MS,
      source_timezone: 'America/Los_Angeles', moving_time_sec: 300, distance_m: 900, ...extra,
    }),
  });
  expect(r.status).toBe(201);
  return (await r.json<any>()).id as string;
}

/** Heart rate from 130 to 159 over five minutes, one reading a second. */
const heartRate = { t: Array.from({ length: 300 }, (_, i) => i), v: Array.from({ length: 300 }, (_, i) => 130 + Math.floor(i / 10)) };

async function streams(jwt: string, activityId: string) {
  const r = await SELF.fetch(`${BASE}/api/activities/${encodeURIComponent(activityId)}/streams`, {
    headers: { Authorization: `Bearer ${jwt}` },
  });
  return { status: r.status, body: await r.json<any>() };
}

const kept = (activityId: string) => env.DB
  .prepare('SELECT point_count FROM activity_heart_rates WHERE activity_id = ?1')
  .bind(activityId).first<{ point_count: number }>();

describe('Apple Health workouts keep their heart rate', () => {
  it('keeps a run\'s pushed heart rate and charts it with the route, for its member only', async () => {
    const me = await member();
    const healthId = crypto.randomUUID().toUpperCase();
    const activityId = await push(me.jwt, healthId, { streams: { heart_rate: heartRate } });
    expect(await kept(activityId)).toEqual({ point_count: 300 });

    // Heart rate alone, before the route arrives.
    const alone = await streams(me.jwt, activityId);
    expect(alone.status).toBe(200);
    expect(alone.body).toMatchObject({ activity_id: activityId, source: 'healthkit' });
    expect(alone.body.streams.heart_rate[0]).toBe(130);
    expect(alone.body.streams.speed_mps).toBeNull();

    const points = Array.from({ length: 301 }, (_, i): RoutePoint =>
      ({ t: START_MS + i * 1_000, lat: 45.519 + i * 0.000027, lon: -122.6793, alt: 15 }));
    const put = await SELF.fetch(`${BASE}/api/activities/healthkit/${healthId}/route`, {
      method: 'PUT', headers: auth(me.jwt), body: JSON.stringify({ route: encodeRoute([points]) }),
    });
    expect(put.status).toBe(200);
    const both = await streams(me.jwt, activityId);
    expect(both.status).toBe(200);
    const s = both.body.streams;
    expect(s.moving_s).toBe(300);
    expect(s.heart_rate[0]).toBe(130);
    expect(s.heart_rate[59]).toBe(159);
    expect(s.speed_mps[30]).toBeCloseTo(3, 0);

    const stranger = await member();
    expect((await streams(stranger.jwt, activityId)).status).toBe(404);
  });

  it('lines heart rate up with a route whose first fix came after the start', async () => {
    // Ten minutes; GPS locks on a minute in. Heart rate goes from 140 to 170
    // at workout second 300, which is route second 240.
    const me = await member();
    const healthId = crypto.randomUUID();
    const hr = { t: Array.from({ length: 600 }, (_, i) => i), v: Array.from({ length: 600 }, (_, i) => (i < 300 ? 140 : 170)) };
    const activityId = await push(me.jwt, healthId, { moving_time_sec: 600, distance_m: 1800, streams: { heart_rate: hr } });
    const points = Array.from({ length: 541 }, (_, i): RoutePoint =>
      ({ t: START_MS + 60_000 + i * 1_000, lat: 45.519 + i * 0.000027, lon: -122.6793, alt: 15 }));
    const put = await SELF.fetch(`${BASE}/api/activities/healthkit/${healthId}/route`, {
      method: 'PUT', headers: auth(me.jwt), body: JSON.stringify({ route: encodeRoute([points]) }),
    });
    expect(put.status).toBe(200);
    const s = (await streams(me.jwt, activityId)).body.streams;
    expect(s.moving_s).toBe(540);
    // Five-second points: 240 s is the start of point 48.
    expect(s.heart_rate[46]).toBe(140);
    expect(s.heart_rate[49]).toBe(170);
    expect(s.heart_rate[107]).toBe(170);
  });

  it('replaces the series on a later push, keeps it when streams are left out and clears it when they have none', async () => {
    const me = await member();
    const healthId = crypto.randomUUID();
    const activityId = await push(me.jwt, healthId, { streams: { heart_rate: heartRate } });
    await push(me.jwt, healthId, { streams: { heart_rate: { t: [0, 1, 2], v: [120, 121, 122] } } });
    expect(await kept(activityId)).toEqual({ point_count: 3 });
    await push(me.jwt, healthId, { distance_m: 950 });
    expect(await kept(activityId)).toEqual({ point_count: 3 });
    await push(me.jwt, healthId, { streams: {} });
    expect(await kept(activityId)).toBeNull();
  });

  it('keeps any workout\'s heart rate and charts it over moving time', async () => {
    const me = await member();
    const soccer = await push(me.jwt, crypto.randomUUID(), {
      kind: 'other', name: 'Soccer', distance_m: null, streams: { heart_rate: heartRate },
    });
    expect(await kept(soccer)).toEqual({ point_count: 300 });
    const res = await streams(me.jwt, soccer);
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ activity_id: soccer, source: 'healthkit' });
    expect(res.body.streams).toMatchObject({ moving_s: 299, distance_m: null, speed_mps: null, elevation_m: null });
    expect(res.body.streams.heart_rate[0]).toBe(130);
  });

  it('keeps a .fit workout\'s heart rate, and forgets it when the import is deleted', async () => {
    const me = await member();
    const clientId = crypto.randomUUID();
    const form = new FormData();
    form.set('id', clientId);
    form.set('file', new File([activityFit({ start: '2026-10-25T03:00:00Z', seconds: 600, hr: 150, power: 200, distanceM: 5000 })], 'ride.fit'));
    const r = await SELF.fetch(`${BASE}/api/activities/fit`, { method: 'POST', headers: { Authorization: `Bearer ${me.jwt}` }, body: form });
    expect(r.status).toBe(201);
    const activityId = (await r.json<any>()).activity.id as string;
    expect((await kept(activityId))?.point_count).toBeGreaterThan(500);
    const res = await streams(me.jwt, activityId);
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ activity_id: activityId, source: 'fit' });
    expect(res.body.streams.heart_rate.filter((v: number | null) => v !== null).length).toBeGreaterThan(100);

    const del = await SELF.fetch(`${BASE}/api/activities/fit/${clientId}`, {
      method: 'DELETE', headers: { Authorization: `Bearer ${me.jwt}` },
    });
    expect(del.status).toBeLessThan(300);
    expect(await kept(activityId)).toBeNull();
  });

  it('takes a .fit workout\'s average heart rate from its records when the session leaves it out', () => {
    // The app and web offer a chart by the workout's average heart rate.
    const fit = parseFit(activityFit({ start: '2026-10-25T03:00:00Z', seconds: 600, hr: 150, sessionHr: false }));
    expect(fit).toMatchObject({ avg_hr: 150, max_hr: 150 });
    expect(parseFit(activityFit({ start: '2026-10-25T03:00:00Z', seconds: 600, hr: 150 }))).toMatchObject({ avg_hr: 150, max_hr: 160 });
  });

  it('includes the series in the account export', async () => {
    const me = await member();
    const activityId = await push(me.jwt, crypto.randomUUID(), { streams: { heart_rate: heartRate } });
    const r = await SELF.fetch(`${BASE}/api/me/export`, { headers: { Authorization: `Bearer ${me.jwt}` } });
    expect(r.status).toBe(200);
    const exported = await r.json<any>();
    const row = exported.training.activity_heart_rates.find((x: any) => x.activity_id === activityId);
    expect(row.point_count).toBe(300);
    expect(row.series.bpm[0]).toBe(130);
  });
});
