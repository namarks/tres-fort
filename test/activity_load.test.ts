import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { issueAppJwt } from '../src/auth';
import { dedupeHealthKitAgainstIntervals, refreshActivityLoads, syncExternalActivities } from '../src/db';
import type { Env } from '../src/types';
import { thresholdSetFor } from '../src/services/activityLoad';

// Effective training load on external activities (migration 0060,
// docs/plans/endurance-training-load P1).

const BASE = 'https://tres-fort.test';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

async function makeUser(label: string): Promise<{ id: string; jwt: string }> {
  const id = crypto.randomUUID();
  await env.DB.prepare('INSERT INTO users (id,apple_sub,email,display_name,created_at) VALUES (?1,?2,?3,?4,?5)')
    .bind(id, `sub-${label}-${id}`, `${label}@test`, label, Date.now())
    .run();
  return { id, jwt: await issueAppJwt(id, 'test-secret') };
}

async function ownerJwt(): Promise<{ id: string; jwt: string }> {
  const r = await SELF.fetch(`${BASE}/auth/dev`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ secret: 'test-dev' }),
  });
  const b = await r.json<{ jwt: string; user: { id: string } }>();
  return { jwt: b.jwt, id: b.user.id };
}

const headers = (jwt: string) => ({ 'content-type': 'application/json', Authorization: `Bearer ${jwt}` });

const setThreshold = async (jwt: string, sport: string, metric: string, value: number, effective_date = '2026-01-01') => {
  const id = crypto.randomUUID();
  const r = await SELF.fetch(`${BASE}/api/me/thresholds`, {
    method: 'POST', headers: headers(jwt), body: JSON.stringify({ id, sport, metric, value, effective_date }),
  });
  expect(r.status).toBe(201);
  return id;
};

const pushHealthRun = async (jwt: string, over: Record<string, unknown> = {}) => {
  const r = await SELF.fetch(`${BASE}/api/activities/healthkit`, {
    method: 'POST',
    headers: headers(jwt),
    body: JSON.stringify({
      id: crypto.randomUUID(),
      date: '2026-10-24',
      start_date_local_ms: Date.parse('2026-10-24T12:14:00Z'),
      kind: 'run',
      name: 'Run',
      moving_time_sec: 3600,
      elapsed_time_sec: 3600,
      distance_m: 10000,
      average_hr: null,
      max_hr: null,
      calories: 600,
      ...over,
    }),
  });
  expect(r.status).toBe(201);
  return r.json<any>();
};

const row = (id: string) =>
  env.DB.prepare('SELECT effective_load, effective_intensity, load_method, synced_at FROM external_activities WHERE id=?1')
    .bind(id).first<any>();

async function insertIntervalsRow(userId: string, over: Record<string, unknown> = {}) {
  const v = {
    external_id: `i${Math.floor(Math.random() * 1e9)}`, date: '2026-09-04', kind: 'ride', moving_time_sec: 3446,
    distance_m: 29733, weighted_avg_watts: 198, average_hr: 127, training_load: 72, intensity: 86.46288, ...over,
  };
  const id = `intervals:activity:${userId}:${v.external_id}`;
  await env.DB.prepare(
    `INSERT INTO external_activities (id,user_id,source,external_id,date,kind,name,moving_time_sec,distance_m,
       weighted_avg_watts,average_hr,training_load,intensity,synced_at)
     VALUES (?1,?2,'intervals',?3,?4,?5,'Ride',?6,?7,?8,?9,?10,?11,1)`,
  ).bind(id, userId, v.external_id, v.date, v.kind, v.moving_time_sec, v.distance_m, v.weighted_avg_watts,
    v.average_hr, v.training_load, v.intensity).run();
  return id;
}

describe('effective training load', () => {
  it('leaves an Apple Health run unknown until a threshold exists, then computes it', async () => {
    const u = await makeUser('health');
    const pushed = await pushHealthRun(u.jwt);
    expect(pushed.training_load).toBeNull();
    expect(pushed.effective_load).toBeNull();
    expect(pushed.load_method).toBeNull();
    const before = await row(pushed.id);

    // 10 km in 60 min against a 5:00/km threshold pace: (300/360)² × 100.
    const thresholdId = await setThreshold(u.jwt, 'run', 'threshold_pace_s_per_km', 300);
    const after = await row(pushed.id);
    expect(after).toMatchObject({ effective_load: 69, effective_intensity: 83.3, load_method: 'pace' });
    expect(after.synced_at).toBeGreaterThan(before.synced_at);

    // The change reaches incremental clients.
    const state = await (await SELF.fetch(`${BASE}/api/state?activities_since=${before.synced_at}`, { headers: headers(u.jwt) })).json<any>();
    expect(state.external_activities.find((a: any) => a.id === pushed.id)).toMatchObject({ effective_load: 69, load_method: 'pace' });

    // Deleting the threshold returns the load to unknown, not zero.
    await SELF.fetch(`${BASE}/api/me/thresholds/${thresholdId}`, { method: 'DELETE', headers: headers(u.jwt) });
    expect(await row(pushed.id)).toMatchObject({ effective_load: null, effective_intensity: null, load_method: null });
  });

  it('computes a new Apple Health workout on push when thresholds already exist', async () => {
    const u = await makeUser('push');
    await setThreshold(u.jwt, 'run', 'threshold_hr', 167.7);
    // No distance, so average heart rate is the best available method.
    const pushed = await pushHealthRun(u.jwt, { distance_m: null, moving_time_sec: 1920, average_hr: 154 });
    expect(pushed).toMatchObject({ effective_load: 45, effective_intensity: 91.8, load_method: 'heart_rate_average' });
  });

  it("keeps the provider's load and fills only missing ones", async () => {
    const u = await makeUser('provider');
    await setThreshold(u.jwt, 'ride', 'ftp_w', 300);
    await setThreshold(u.jwt, 'ride', 'threshold_hr', 160);
    const withLoad = await insertIntervalsRow(u.id);
    const withoutLoad = await insertIntervalsRow(u.id, { weighted_avg_watts: null, training_load: null, intensity: null, average_hr: 125, moving_time_sec: 9948 });
    await refreshActivityLoads(env.DB, u.id);
    expect(await row(withLoad)).toMatchObject({ effective_load: 72, effective_intensity: 86.5, load_method: 'provider' });
    // 2.76 h at 125/160 of threshold heart rate: 2.763 × 0.610 × 100.
    expect(await row(withoutLoad)).toMatchObject({ effective_load: 169, load_method: 'heart_rate_average' });

    // A second pass with nothing changed writes nothing.
    expect(await refreshActivityLoads(env.DB, u.id)).toBe(0);
  });

  it('fills loads during an intervals.icu sync without rewriting provider rows', async () => {
    const id = crypto.randomUUID();
    await env.DB.prepare(
      `INSERT INTO users (id,apple_sub,email,display_name,created_at,intervals_api_key,intervals_athlete_id)
       VALUES (?1,?2,NULL,'Rider',?3,?4,?5)`,
    ).bind(id, `sub-${id}`, Date.now(), `key-${id}`, `athlete-${id}`).run();
    await setThreshold(await issueAppJwt(id, 'test-secret'), 'run', 'threshold_pace_s_per_km', 300);
    const activities = [
      { id: 'zwift', type: 'VirtualRide', start_date_local: '2026-09-04T17:20:00', name: 'Zwift', moving_time: 3446,
        distance: 29733, icu_weighted_avg_watts: 198, average_heartrate: 127, icu_training_load: 72, icu_intensity: 86.46288 },
      { id: 'treadmill', type: 'Run', start_date_local: '2026-09-05T07:00:00', name: 'Treadmill Run', moving_time: 3600,
        distance: 10000, icu_training_load: null, icu_intensity: null },
    ];
    const sync = () => syncExternalActivities(env.DB, env as unknown as Env, {
      userId: id,
      today: '2026-09-06',
      fetcher: async () => ({ ok: true, status: 200, json: async () => activities }),
    });
    expect((await sync()).status).toBe('ok');
    const ride = await row(`intervals:activity:${id}:zwift`);
    const run = await row(`intervals:activity:${id}:treadmill`);
    expect(ride).toMatchObject({ effective_load: 72, effective_intensity: 86.5, load_method: 'provider' });
    expect(run).toMatchObject({ effective_load: 69, load_method: 'pace' });

    // An unchanged second sync rewrites neither row.
    await sync();
    expect((await row(`intervals:activity:${id}:zwift`)).synced_at).toBe(ride.synced_at);
    expect((await row(`intervals:activity:${id}:treadmill`)).synced_at).toBe(run.synced_at);

    // A sport setting corrected in intervals.icu alone still reaches the
    // stored JSON, so threshold suggestions follow it (P7).
    Object.assign(activities[0]!, { icu_ftp: 240, lthr: 165 });
    await sync();
    const corrected = await env.DB.prepare(
      "SELECT json_extract(raw,'$.icu_ftp') AS ftp, json_extract(raw,'$.lthr') AS lthr FROM external_activities WHERE id=?1",
    ).bind(`intervals:activity:${id}:zwift`).first<any>();
    expect(corrected).toEqual({ ftp: 240, lthr: 165 });
    expect((await row(`intervals:activity:${id}:treadmill`)).synced_at).toBe(run.synced_at);
  });

  it('never stores a load overtaken by a concurrent source change', async () => {
    const u = await makeUser('race');
    await setThreshold(u.jwt, 'ride', 'threshold_hr', 160);
    const id = await insertIntervalsRow(u.id, { training_load: null, intensity: null, weighted_avg_watts: null, average_hr: 120 });
    // A sync lands a provider load between the refresh's read and its write.
    let raced = false;
    const racingDb = {
      prepare: (sql: string) => env.DB.prepare(sql),
      batch: async (statements: D1PreparedStatement[]) => {
        if (!raced) {
          raced = true;
          await env.DB.prepare(
            "UPDATE external_activities SET training_load=90, intensity=95, effective_load=90, effective_intensity=95, load_method='provider' WHERE id=?1",
          ).bind(id).run();
        }
        return env.DB.batch(statements);
      },
    } as unknown as D1Database;
    await refreshActivityLoads(racingDb, u.id);
    expect(raced).toBe(true);
    expect(await row(id)).toMatchObject({ effective_load: 90, effective_intensity: 95, load_method: 'provider' });
  });

  it('a retried threshold POST finishes a recompute that failed after the insert', async () => {
    const u = await makeUser('retry');
    const pushed = await pushHealthRun(u.jwt);
    const body = { id: crypto.randomUUID(), sport: 'run', metric: 'threshold_pace_s_per_km', value: 300, effective_date: '2026-01-01' };
    const post = () => SELF.fetch(`${BASE}/api/me/thresholds`, { method: 'POST', headers: headers(u.jwt), body: JSON.stringify(body) });
    expect((await post()).status).toBe(201);
    // Simulate the recompute having failed after the threshold committed.
    await env.DB.prepare('UPDATE external_activities SET effective_load=NULL, effective_intensity=NULL, load_method=NULL WHERE id=?1')
      .bind(pushed.id).run();
    expect((await post()).status).toBe(200);
    expect(await row(pushed.id)).toMatchObject({ effective_load: 69, load_method: 'pace' });
  });

  it('refreshes a revised Apple Health workout on its stored date', async () => {
    const u = await makeUser('revised');
    await setThreshold(u.jwt, 'run', 'threshold_pace_s_per_km', 300);
    const first = await pushHealthRun(u.jwt);
    expect(first).toMatchObject({ date: '2026-10-24', effective_load: 69 });
    // A re-push after travel sends another civil date; the stored date stays,
    // and the halved time must still recompute: 0.5 h × (300/180)² × 100.
    const revised = await pushHealthRun(u.jwt, {
      id: first.external_id,
      date: '2026-10-25',
      start_date_local_ms: Date.parse('2026-10-25T02:14:00Z'),
      moving_time_sec: 1800,
      elapsed_time_sec: 1800,
    });
    expect(revised).toMatchObject({ date: '2026-10-24', moving_time_sec: 1800, effective_load: 139, load_method: 'pace' });
  });

  it('keeps a hidden Apple Health duplicate current so a restore shows the right load', async () => {
    const u = await makeUser('hidden');
    const start = Date.parse('2026-10-24T12:14:00Z');
    const pushed = await pushHealthRun(u.jwt, { start_date_local_ms: start });
    // intervals.icu then delivers the same run without a load, so the Apple
    // Health copy is retired as its duplicate.
    const intervalsId = `intervals:activity:${u.id}:dup`;
    await env.DB.prepare(
      `INSERT INTO external_activities (id,user_id,source,external_id,date,kind,name,moving_time_sec,distance_m,
         start_date_local_ms,synced_at)
       VALUES (?1,?2,'intervals','dup','2026-10-24','run','Run',3600,10000,?3,1)`,
    ).bind(intervalsId, u.id, start).run();
    await dedupeHealthKitAgainstIntervals(env.DB, u.id);
    const hidden = await env.DB.prepare('SELECT deleted_at, duplicate_of, synced_at FROM external_activities WHERE id=?1')
      .bind(pushed.id).first<any>();
    expect(hidden).toMatchObject({ duplicate_of: intervalsId });
    expect(hidden.deleted_at).not.toBeNull();

    // A threshold set while it is hidden updates its load without re-sending
    // the tombstone.
    await setThreshold(u.jwt, 'run', 'threshold_pace_s_per_km', 300);
    expect(await row(pushed.id)).toMatchObject({ effective_load: 69, load_method: 'pace', synced_at: hidden.synced_at });

    // The intervals.icu run goes away; the restored copy already has its load.
    await env.DB.prepare('UPDATE external_activities SET deleted_at=?2 WHERE id=?1').bind(intervalsId, Date.now()).run();
    await dedupeHealthKitAgainstIntervals(env.DB, u.id);
    const restored = await env.DB.prepare('SELECT deleted_at, effective_load, load_method, synced_at FROM external_activities WHERE id=?1')
      .bind(pushed.id).first<any>();
    expect(restored).toMatchObject({ deleted_at: null, effective_load: 69, load_method: 'pace' });
    expect(restored.synced_at).toBeGreaterThan(hidden.synced_at);
  });

  it('uses the threshold in effect on each workout date', async () => {
    const u = await makeUser('dated');
    await setThreshold(u.jwt, 'run', 'threshold_pace_s_per_km', 360, '2026-01-01');
    await setThreshold(u.jwt, 'run', 'threshold_pace_s_per_km', 300, '2026-10-01');
    const older = await pushHealthRun(u.jwt, { date: '2026-09-01', start_date_local_ms: Date.parse('2026-09-01T12:00:00Z') });
    const newer = await pushHealthRun(u.jwt);
    expect(older).toMatchObject({ effective_load: 100, load_method: 'pace' });
    expect(newer).toMatchObject({ effective_load: 69, load_method: 'pace' });
  });

  it('never touches another member’s activities', async () => {
    const a = await makeUser('a');
    const b = await makeUser('b');
    const theirs = await pushHealthRun(b.jwt);
    await setThreshold(a.jwt, 'run', 'threshold_pace_s_per_km', 300);
    expect(await row(theirs.id)).toMatchObject({ effective_load: null, load_method: null });
  });

  it('reports load and its method to the coach', async () => {
    const owner = await ownerJwt();
    await setThreshold(owner.jwt, 'run', 'threshold_pace_s_per_km', 300);
    const today = new Date().toISOString().slice(0, 10);
    await pushHealthRun(owner.jwt, { date: today, start_date_local_ms: Date.parse(`${today}T12:00:00Z`) });
    const r = await SELF.fetch(`${BASE}/mcp`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', Authorization: 'Bearer test-mcp-token' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'get_recent_activities', arguments: { range: 7 } } }),
    });
    const body = await r.json<any>();
    const payload = JSON.parse(body.result.content[0].text);
    expect(payload.activities[0]).toMatchObject({ training_load: null, load: 69, load_method: 'pace' });
  });
});

// Detail streams on Apple Health pushes (migration 0061,
// docs/plans/endurance-training-load P3).
describe('Apple Health detail streams', () => {
  const stream = (value: number, seconds: number, step = 1) => ({
    t: Array.from({ length: Math.round(seconds / step) }, (_, i) => i * step),
    v: Array.from({ length: Math.round(seconds / step) }, () => value),
  });
  const ride = { kind: 'ride', name: 'Ride', distance_m: 30000, average_hr: 140 };
  const stored = (id: string) =>
    env.DB.prepare('SELECT stream_np_w, stream_hr_rms, stream_hr_sec, effective_load, load_method FROM external_activities WHERE id=?1')
      .bind(id).first<any>();

  it('scores a ride from its power and heart-rate samples and rescores when thresholds change', async () => {
    const u = await makeUser('streams');
    await setThreshold(u.jwt, 'ride', 'threshold_hr', 150);
    const hkId = crypto.randomUUID();
    const body = { id: hkId, ...ride, streams: { heart_rate: stream(150, 3600, 5), power: stream(200, 3600) } };
    // An hour at threshold heart rate.
    const pushed = await pushHealthRun(u.jwt, body);
    expect(pushed).toMatchObject({ effective_load: 100, effective_intensity: 100, load_method: 'heart_rate' });
    // Samples every 5 s; the last one holds a single second.
    expect(await stored(pushed.id)).toMatchObject({ stream_np_w: 200, stream_hr_rms: 150, stream_hr_sec: 3596 });

    // FTP 250: an hour at 200 W normalized is (200/250)² × 100.
    const ftp = await setThreshold(u.jwt, 'ride', 'ftp_w', 250);
    expect(await row(pushed.id)).toMatchObject({ effective_load: 64, effective_intensity: 80, load_method: 'power' });
    await SELF.fetch(`${BASE}/api/me/thresholds/${ftp}`, { method: 'DELETE', headers: headers(u.jwt) });
    expect(await row(pushed.id)).toMatchObject({ effective_load: 100, load_method: 'heart_rate' });

    // A push from an app that sends no streams keeps the stored summaries.
    const { streams: _omit, ...withoutStreams } = body;
    await pushHealthRun(u.jwt, { ...withoutStreams, name: 'Morning ride' });
    expect(await stored(pushed.id)).toMatchObject({ stream_hr_rms: 150, load_method: 'heart_rate' });

    // Streams sent as none clear them; average heart rate is what is left.
    await pushHealthRun(u.jwt, { ...body, streams: null });
    expect(await stored(pushed.id)).toMatchObject({
      stream_np_w: null, stream_hr_rms: null, stream_hr_sec: null, load_method: 'heart_rate_average',
    });
  });

  it('keeps a sparse stream out of the load', async () => {
    const u = await makeUser('sparse');
    await setThreshold(u.jwt, 'ride', 'threshold_hr', 150);
    // Heart rate every ten minutes, as Zwift writes it to Apple Health.
    const pushed = await pushHealthRun(u.jwt, { ...ride, streams: { heart_rate: stream(150, 3600, 600) } });
    expect(await stored(pushed.id)).toMatchObject({ stream_hr_rms: null, stream_hr_sec: null });
    expect(pushed).toMatchObject({ load_method: 'heart_rate_average' });
  });

  it('rejects malformed streams before writing', async () => {
    const u = await makeUser('bad-streams');
    for (const streams of [
      { heart_rate: { t: [0, 1], v: [150] } },
      { cadence: { t: [0], v: [90] } },
      { power: { t: [0, -1], v: [200, 200] } },
      { power: { t: [0], v: ['200'] } },
      [1, 2],
    ]) {
      const id = crypto.randomUUID();
      const r = await SELF.fetch(`${BASE}/api/activities/healthkit`, {
        method: 'POST',
        headers: headers(u.jwt),
        body: JSON.stringify({
          id, date: '2026-10-24', start_date_local_ms: Date.parse('2026-10-24T12:14:00Z'), kind: 'ride', streams,
        }),
      });
      expect(r.status).toBe(400);
      expect(await r.json()).toEqual({ error: 'invalid_streams' });
    }
    const count = await env.DB.prepare('SELECT COUNT(*) AS n FROM external_activities WHERE user_id=?1').bind(u.id).first<{ n: number }>();
    expect(count?.n).toBe(0);
  });
});

// Heart-rate load for sports beyond runs and rides
// (docs/plans/sport-activities P1).
describe('heart-rate load for any sport', () => {
  const stream = (value: number, seconds: number, step = 5) => ({
    t: Array.from({ length: Math.round(seconds / step) }, (_, i) => i * step),
    v: Array.from({ length: Math.round(seconds / step) }, () => value),
  });
  const match = (over: Record<string, unknown> = {}) => ({
    kind: 'other', name: 'Workout', moving_time_sec: 3600, elapsed_time_sec: 3600,
    distance_m: 8000, average_hr: 150, raw: JSON.stringify({ hk_activity_type: 41 }), ...over,
  });

  it('borrows only the threshold heart rate from the run thresholds', () => {
    const t = (sport: string, metric: string, value: number) => ({
      id: crypto.randomUUID(), sport, metric, value, effective_date: '2026-01-01', source: 'member', created_at: 1,
    }) as any;
    const all = [t('run', 'threshold_hr', 165), t('run', 'threshold_pace_s_per_km', 300), t('ride', 'ftp_w', 250), t('ride', 'threshold_hr', 158)];
    expect(thresholdSetFor('other', 'soccer', all, '2026-11-02')).toEqual({ threshold_hr: 165 });
    expect(thresholdSetFor('hike', 'hike', all, '2026-11-02')).toEqual({ threshold_hr: 165 });
    expect(thresholdSetFor('other', 'swim', all, '2026-11-02')).toEqual({});
    expect(thresholdSetFor('strength', 'strength', all, '2026-11-02')).toEqual({});
    // Runs and rides keep their whole set, whatever the sport says.
    expect(thresholdSetFor('ride', 'ride', all, '2026-11-02')).toEqual({ ftp_w: 250, threshold_hr: 158 });
    // A sport with only pace thresholds has nothing to borrow.
    expect(thresholdSetFor('other', 'tennis', [all[1]], '2026-11-02')).toEqual({});
  });

  it('scores a soccer match from heart rate, never from its pace', async () => {
    const u = await makeUser('hr-soccer');
    await setThreshold(u.jwt, 'run', 'threshold_pace_s_per_km', 300);
    // Pace alone (8 km in an hour) never scores a match.
    const paced = await pushHealthRun(u.jwt, match({ average_hr: null }));
    expect(paced).toMatchObject({ sport: 'soccer', effective_load: null, load_method: null });

    // An hour at the run threshold heart rate is 100.
    await setThreshold(u.jwt, 'run', 'threshold_hr', 150);
    expect(await row(paced.id)).toMatchObject({ effective_load: null });
    const averaged = await pushHealthRun(u.jwt, match({ start_date_local_ms: Date.parse('2026-10-24T18:00:00Z') }));
    expect(averaged).toMatchObject({ effective_load: 100, effective_intensity: 100, load_method: 'heart_rate_average' });

    // Heart-rate samples from the watch win over the average.
    const sampled = await pushHealthRun(u.jwt, match({
      start_date_local_ms: Date.parse('2026-10-24T20:00:00Z'), average_hr: 140,
      streams: { heart_rate: stream(150, 3600) },
    }));
    expect(sampled).toMatchObject({ effective_load: 100, load_method: 'heart_rate' });
  });

  it('rescores other sports when the run threshold heart rate changes', async () => {
    const u = await makeUser('hr-rescore');
    const tennis = await pushHealthRun(u.jwt, match({ raw: JSON.stringify({ hk_activity_type: 48 }), distance_m: null }));
    expect(tennis).toMatchObject({ sport: 'tennis', effective_load: null });
    const id = await setThreshold(u.jwt, 'run', 'threshold_hr', 150);
    expect(await row(tennis.id)).toMatchObject({ effective_load: 100, load_method: 'heart_rate_average' });
    // A ride threshold does not score an on-foot sport.
    await SELF.fetch(`${BASE}/api/me/thresholds/${id}`, { method: 'DELETE', headers: headers(u.jwt) });
    await setThreshold(u.jwt, 'ride', 'threshold_hr', 150);
    expect(await row(tennis.id)).toMatchObject({ effective_load: null, load_method: null });
  });

  it('leaves swims and strength without a heart-rate load', async () => {
    const u = await makeUser('hr-none');
    await setThreshold(u.jwt, 'run', 'threshold_hr', 150);
    await setThreshold(u.jwt, 'ride', 'threshold_hr', 150);
    const swim = await pushHealthRun(u.jwt, match({ kind: 'swim', name: 'Swim', distance_m: 2000, raw: JSON.stringify({ hk_activity_type: 46 }) }));
    const lift = await pushHealthRun(u.jwt, match({
      kind: 'strength', name: 'Strength', distance_m: null, raw: JSON.stringify({ hk_activity_type: 20 }),
      start_date_local_ms: Date.parse('2026-10-24T18:00:00Z'),
    }));
    expect(swim).toMatchObject({ sport: 'swim', effective_load: null, load_method: null });
    expect(lift).toMatchObject({ sport: 'strength', effective_load: null, load_method: null });
  });
});

// The member's own "How hard was it?" (migration 0066,
// docs/plans/sport-activities P2).
describe('effort rating', () => {
  const soccer = (over: Record<string, unknown> = {}) => ({
    kind: 'other', name: 'Soccer', moving_time_sec: 5400, elapsed_time_sec: 5400,
    distance_m: null, average_hr: null, raw: JSON.stringify({ hk_activity_type: 41 }), ...over,
  });
  const rate = (jwt: string, id: string, body: unknown) =>
    SELF.fetch(`${BASE}/api/activities/${encodeURIComponent(id)}/effort`, {
      method: 'PUT', headers: headers(jwt), body: JSON.stringify(body),
    });
  const effortRow = (id: string) =>
    env.DB.prepare('SELECT effort, effective_load, effective_intensity, load_method, synced_at FROM external_activities WHERE id=?1')
      .bind(id).first<any>();

  it('scores a workout with no data from the rating, labeled effort, and clears back to unknown', async () => {
    const u = await makeUser('effort');
    const match = await pushHealthRun(u.jwt, soccer());
    expect(match).toMatchObject({ sport: 'soccer', effective_load: null, load_method: null, effort: null });

    const r = await rate(u.jwt, match.id, { effort: 6 });
    expect(r.status).toBe(200);
    // 90 minutes at 6: 1.5 × 6/7 × 100.
    expect((await r.json<any>()).activity).toMatchObject({ effort: 6, effective_load: 129, effective_intensity: null, load_method: 'effort' });
    const rated = await effortRow(match.id);
    expect(rated.synced_at).toBeGreaterThan(match.synced_at);

    // Installed apps receive it through the state delta.
    const state = await (await SELF.fetch(`${BASE}/api/state?activities_since=${match.synced_at}`, { headers: headers(u.jwt) })).json<any>();
    expect(state.external_activities.find((a: any) => a.id === match.id)).toMatchObject({ effort: 6, effective_load: 129, load_method: 'effort' });

    // The same rating again changes nothing.
    await rate(u.jwt, match.id, { effort: 6 });
    expect((await effortRow(match.id)).synced_at).toBe(rated.synced_at);

    // Clearing it returns the load to unknown, never zero.
    expect((await rate(u.jwt, match.id, { effort: null })).status).toBe(200);
    expect(await effortRow(match.id)).toMatchObject({ effort: null, effective_load: null, load_method: null });
  });

  it('keeps a measured load over the rating, and uses the rating once that load goes away', async () => {
    const u = await makeUser('effort-measured');
    const id = await setThreshold(u.jwt, 'run', 'threshold_hr', 150);
    const match = await pushHealthRun(u.jwt, soccer({ average_hr: 150, moving_time_sec: 3600, elapsed_time_sec: 3600 }));
    expect(match).toMatchObject({ effective_load: 100, load_method: 'heart_rate_average' });
    await rate(u.jwt, match.id, { effort: 9 });
    expect(await effortRow(match.id)).toMatchObject({ effort: 9, effective_load: 100, load_method: 'heart_rate_average' });
    await SELF.fetch(`${BASE}/api/me/thresholds/${id}`, { method: 'DELETE', headers: headers(u.jwt) });
    expect(await effortRow(match.id)).toMatchObject({ effort: 9, effective_load: 129, load_method: 'effort' });
  });

  it("keeps the rating when the source sends the workout again, and never overrides a provider's load", async () => {
    const u = await makeUser('effort-resend');
    const swimId = crypto.randomUUID();
    const swim = await pushHealthRun(u.jwt, soccer({ id: swimId, kind: 'swim', name: 'Swim', raw: JSON.stringify({ hk_activity_type: 46 }) }));
    await rate(u.jwt, swim.id, { effort: 7 });
    // Apple Health revises the swim: same workout, new totals.
    await pushHealthRun(u.jwt, soccer({ id: swimId, kind: 'swim', name: 'Swim', moving_time_sec: 3600, elapsed_time_sec: 3600, raw: JSON.stringify({ hk_activity_type: 46 }) }));
    expect(await effortRow(swim.id)).toMatchObject({ effort: 7, effective_load: 100, load_method: 'effort' });

    const ride = await insertIntervalsRow(u.id);
    await rate(u.jwt, ride, { effort: 3 });
    expect(await effortRow(ride)).toMatchObject({ effort: 3, effective_load: 72, load_method: 'provider' });
  });

  it('follows the workout when another source takes it over as the shown copy', async () => {
    const u = await makeUser('effort-dedup');
    const start = Date.parse('2026-10-24T12:14:00Z');
    const pushed = await pushHealthRun(u.jwt, soccer({ kind: 'run', name: 'Run', start_date_local_ms: start }));
    await rate(u.jwt, pushed.id, { effort: 8 });

    // intervals.icu then delivers the same run with no load: the Apple Health
    // copy is hidden, and the shown copy takes its rating.
    const intervalsId = `intervals:activity:${u.id}:effort-dup`;
    await env.DB.prepare(
      `INSERT INTO external_activities (id,user_id,source,external_id,date,kind,name,moving_time_sec,
         start_date_local_ms,synced_at)
       VALUES (?1,?2,'intervals','effort-dup','2026-10-24','run','Run',5400,?3,1)`,
    ).bind(intervalsId, u.id, start).run();
    await dedupeHealthKitAgainstIntervals(env.DB, u.id);
    await refreshActivityLoads(env.DB, u.id);
    expect(await effortRow(intervalsId)).toMatchObject({ effort: 8, effective_load: 171, load_method: 'effort' });

    // Clearing it on the shown copy clears the hidden one too, so it stays clear.
    await rate(u.jwt, intervalsId, { effort: null });
    await refreshActivityLoads(env.DB, u.id);
    expect(await effortRow(intervalsId)).toMatchObject({ effort: null, effective_load: null });
    expect(await effortRow(pushed.id)).toMatchObject({ effort: null, effective_load: null });

    // A hidden copy itself can't be rated.
    expect((await rate(u.jwt, pushed.id, { effort: 5 })).status).toBe(404);
  });

  it('keeps a rating given before another copy arrived when that copy is later restored', async () => {
    const u = await makeUser('effort-late-copy');
    const start = Date.parse('2026-10-24T12:14:00Z');
    const intervalsId = `intervals:activity:${u.id}:effort-first`;
    await env.DB.prepare(
      `INSERT INTO external_activities (id,user_id,source,external_id,date,kind,name,moving_time_sec,
         start_date_local_ms,synced_at)
       VALUES (?1,?2,'intervals','effort-first','2026-10-24','run','Run',5400,?3,1)`,
    ).bind(intervalsId, u.id, start).run();
    await rate(u.jwt, intervalsId, { effort: 6 });

    // The Apple Health copy arrives afterwards and is hidden behind it; it
    // takes the rating with it.
    const pushed = await pushHealthRun(u.jwt, soccer({ kind: 'run', name: 'Run', start_date_local_ms: start }));
    await dedupeHealthKitAgainstIntervals(env.DB, u.id);
    await refreshActivityLoads(env.DB, u.id);
    const hidden = await env.DB.prepare('SELECT deleted_at, duplicate_of, effort FROM external_activities WHERE id=?1')
      .bind(pushed.id).first<any>();
    expect(hidden).toMatchObject({ duplicate_of: intervalsId, effort: 6 });
    expect(hidden.deleted_at).not.toBeNull();

    // The intervals.icu run goes away; the restored copy keeps the rating and its load.
    await env.DB.prepare('UPDATE external_activities SET deleted_at=?2 WHERE id=?1').bind(intervalsId, Date.now()).run();
    await dedupeHealthKitAgainstIntervals(env.DB, u.id);
    await refreshActivityLoads(env.DB, u.id);
    expect(await env.DB.prepare('SELECT deleted_at, effort, effective_load, load_method FROM external_activities WHERE id=?1')
      .bind(pushed.id).first<any>()).toMatchObject({ deleted_at: null, effort: 6, effective_load: 129, load_method: 'effort' });
  });

  it('rejects bad ratings and other members’ workouts', async () => {
    const a = await makeUser('effort-a');
    const b = await makeUser('effort-b');
    const theirs = await pushHealthRun(b.jwt, soccer());
    expect((await rate(a.jwt, theirs.id, { effort: 5 })).status).toBe(404);
    for (const body of [{}, { effort: 0 }, { effort: 11 }, { effort: 6.5 }, { effort: '7' }]) {
      const r = await rate(b.jwt, theirs.id, body);
      expect(r.status).toBe(400);
      expect(await r.json()).toMatchObject({ error: 'invalid_fields', fields: ['effort'] });
    }
    expect(await effortRow(theirs.id)).toMatchObject({ effort: null });
    // The column itself refuses anything but a whole 1 to 10.
    await expect(env.DB.prepare('UPDATE external_activities SET effort = 6.5 WHERE id = ?1').bind(theirs.id).run()).rejects.toThrow();
    await expect(env.DB.prepare("UPDATE external_activities SET load_method = 'guess' WHERE id = ?1").bind(theirs.id).run()).rejects.toThrow();
  });

  it('lets the coach record a rating the member gives and reports it', async () => {
    const owner = await ownerJwt();
    const today = new Date().toISOString().slice(0, 10);
    const match = await pushHealthRun(owner.jwt, soccer({ date: today, start_date_local_ms: Date.parse(`${today}T07:00:00Z`) }));
    const call = async (name: string, args: Record<string, unknown>) => {
      const r = await SELF.fetch(`${BASE}/mcp`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', Authorization: 'Bearer test-mcp-token' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: args } }),
      });
      return JSON.parse((await r.json<any>()).result.content[0].text);
    };
    expect(await call('rate_activity', { id: match.id, effort: 11 })).toMatchObject({ error: 'invalid_fields' });
    expect(await call('rate_activity', { id: 'nope', effort: 5 })).toMatchObject({ error: 'not_found' });
    expect(await call('rate_activity', { id: match.id, effort: 7 })).toMatchObject({ ok: true, effort: 7, load: 150, load_method: 'effort' });
    const audit = await env.DB.prepare("SELECT actor FROM audit_log WHERE user_id=?1 AND tool='rate_activity'").bind(owner.id).all<any>();
    expect(audit.results.length).toBeGreaterThanOrEqual(1);
    const recent = await call('get_recent_activities', { range: 2, limit: 200 });
    expect(recent.activities.find((x: any) => x.id === match.id)).toMatchObject({ effort: 7, load: 150, load_method: 'effort' });
  });
});
