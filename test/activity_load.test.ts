import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { issueAppJwt } from '../src/auth';
import { refreshActivityLoads, syncExternalActivities } from '../src/db';
import type { Env } from '../src/types';

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
