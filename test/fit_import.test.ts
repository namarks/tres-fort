import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { issueAppJwt } from '../src/auth';
import { dedupeHealthKitAgainstIntervals, fitLocalTime } from '../src/db';
import { validActivitySourceTime } from '../src/activityTime';
import { activityFit } from './fitWriter';

// .fit file import (docs/plans/endurance-training-load P4).

const BASE = 'https://tres-fort.test';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

async function makeUser(label: string, timezone: string | null = null) {
  const id = crypto.randomUUID();
  await env.DB.prepare('INSERT INTO users (id,apple_sub,email,display_name,created_at,timezone) VALUES (?1,?2,?3,?4,?5,?6)')
    .bind(id, `sub-${label}-${id}`, `${label}@test`, label, Date.now(), timezone)
    .run();
  return { id, jwt: await issueAppJwt(id, 'test-secret') };
}

const auth = (jwt: string) => ({ Authorization: `Bearer ${jwt}` });

const setThreshold = async (jwt: string, sport: string, metric: string, value: number) => {
  const r = await SELF.fetch(`${BASE}/api/me/thresholds`, {
    method: 'POST',
    headers: { ...auth(jwt), 'content-type': 'application/json' },
    body: JSON.stringify({ id: crypto.randomUUID(), sport, metric, value, effective_date: '2026-01-01' }),
  });
  expect(r.status).toBe(201);
};

const upload = (jwt: string, bytes: Uint8Array, id = crypto.randomUUID(), name?: string) => {
  const form = new FormData();
  form.set('id', id);
  form.set('file', new File([bytes], 'ride.fit'));
  if (name) form.set('name', name);
  return SELF.fetch(`${BASE}/api/activities/fit`, { method: 'POST', headers: auth(jwt), body: form });
};

const ride = (over: Partial<Parameters<typeof activityFit>[0]> = {}) =>
  activityFit({ start: '2026-10-25T03:00:00Z', seconds: 3600, hr: 150, power: 200, distanceM: 30000, ...over });

const stored = (id: string) =>
  env.DB.prepare('SELECT * FROM external_activities WHERE id = ?1').bind(id).first<any>();

describe('POST /api/activities/fit', () => {
  it('imports a ride on the device’s local day and scores it from its power', async () => {
    const u = await makeUser('fit-ride');
    await setThreshold(u.jwt, 'ride', 'ftp_w', 250);
    const r = await upload(u.jwt, ride(), undefined, 'Zwift: Watopia');
    expect(r.status).toBe(201);
    const { activity, deduplicated } = await r.json<any>();
    expect(deduplicated).toBe(false);
    // 03:00 UTC at UTC−7 is the evening before.
    expect(activity).toMatchObject({
      source: 'fit', kind: 'ride', name: 'Zwift: Watopia', date: '2026-10-24',
      start_date_utc_ms: Date.parse('2026-10-25T03:00:00Z'), source_timezone: 'GMT-0700',
      moving_time_sec: 3600, distance_m: 30000, average_hr: 150, max_hr: 160, calories: 600,
      stream_np_w: 200, stream_hr_rms: 150, stream_hr_sec: 3600,
      effective_load: 64, effective_intensity: 80, load_method: 'power',
      training_load: null, deleted_at: null,
    });
    expect(validActivitySourceTime(activity.start_date_utc_ms, activity.source_timezone, activity.date,
      activity.start_date_local_ms)).toBe(true);

    // It reaches the app through the sync pull.
    const state = await (await SELF.fetch(`${BASE}/api/state`, { headers: auth(u.jwt) })).json<any>();
    expect(state.external_activities.map((a: any) => a.id)).toContain(activity.id);
  });

  it('is idempotent on the client id and on the workout itself', async () => {
    const u = await makeUser('fit-retry');
    const id = crypto.randomUUID();
    const first = await (await upload(u.jwt, ride(), id)).json<any>();
    const retry = await upload(u.jwt, ride(), id);
    expect(retry.status).toBe(200);
    expect((await retry.json<any>()).activity.id).toBe(first.activity.id);
    // The same file under another id is the same workout.
    const again = await upload(u.jwt, ride());
    expect(again.status).toBe(200);
    expect(await again.json<any>()).toMatchObject({ deduplicated: true, activity: { id: first.activity.id } });
    const count = await env.DB.prepare("SELECT COUNT(*) AS n FROM external_activities WHERE user_id = ?1 AND source = 'fit'")
      .bind(u.id).first<{ n: number }>();
    expect(count?.n).toBe(1);
  });

  it('finishes scoring on a retry when the first attempt stopped after storing the row', async () => {
    const u = await makeUser('fit-unfinished');
    await setThreshold(u.jwt, 'ride', 'ftp_w', 250);
    const id = crypto.randomUUID();
    const first = await (await upload(u.jwt, ride(), id)).json<any>();
    // As if the load refresh had failed after the insert.
    await env.DB.prepare('UPDATE external_activities SET effective_load = NULL, effective_intensity = NULL, load_method = NULL WHERE id = ?1')
      .bind(first.activity.id).run();
    const retry = await (await upload(u.jwt, ride(), id)).json<any>();
    expect(retry).toMatchObject({ deduplicated: true, activity: { effective_load: 64, load_method: 'power' } });
  });

  it('uses the member’s timezone when the file has no local time, and heart rate without power', async () => {
    const u = await makeUser('fit-zone', 'Europe/Paris');
    await setThreshold(u.jwt, 'run', 'threshold_hr', 150);
    const run = activityFit({ start: '2026-10-24T22:30:00Z', seconds: 1800, sport: 1, hr: 150, power: null, localOffsetSec: null });
    const { activity } = await (await upload(u.jwt, run)).json<any>();
    // 22:30 UTC is 00:30 the next day in Paris (CEST, UTC+2, until Oct 25).
    expect(activity).toMatchObject({ kind: 'run', date: '2026-10-25', source_timezone: 'Europe/Paris', load_method: 'heart_rate', effective_load: 50 });
    expect(validActivitySourceTime(activity.start_date_utc_ms, activity.source_timezone, activity.date,
      activity.start_date_local_ms)).toBe(true);
  });

  it('rejects files it cannot read, without storing anything', async () => {
    const u = await makeUser('fit-bad');
    const notFit = await upload(u.jwt, new TextEncoder().encode('<?xml version="1.0"?><gpx></gpx>'));
    expect(notFit.status).toBe(400);
    expect(await notFit.json()).toEqual({ error: 'not_fit' });
    const cut = await upload(u.jwt, ride().slice(0, 500));
    expect(cut.status).toBe(400);
    expect(await cut.json()).toEqual({ error: 'truncated' });
    const badId = new FormData();
    badId.set('id', 'nope');
    badId.set('file', new File([ride()], 'ride.fit'));
    expect((await SELF.fetch(`${BASE}/api/activities/fit`, { method: 'POST', headers: auth(u.jwt), body: badId })).status).toBe(400);
    const count = await env.DB.prepare('SELECT COUNT(*) AS n FROM external_activities WHERE user_id = ?1').bind(u.id).first<{ n: number }>();
    expect(count?.n).toBe(0);
  });
});

describe('.fit imports across sources', () => {
  const start = Date.parse('2026-10-25T03:00:00Z');

  const insertIntervals = async (userId: string) => {
    const id = `intervals:activity:${userId}:i${Math.floor(Math.random() * 1e9)}`;
    await env.DB.prepare(
      `INSERT INTO external_activities (id,user_id,source,external_id,date,start_date_local_ms,start_date_utc_ms,kind,name,
         moving_time_sec,training_load,intensity,effective_load,effective_intensity,load_method,synced_at)
       VALUES (?1,?2,'intervals',?3,'2026-10-24',?4,?5,'ride','Zwift',3600,70,84,70,84,'provider',1)`,
    ).bind(id, userId, id.split(':').pop(), start - 7 * 3_600_000, start + 30_000).run();
    return id;
  };

  const pushHealth = async (jwt: string) => {
    const r = await SELF.fetch(`${BASE}/api/activities/healthkit`, {
      method: 'POST',
      headers: { ...auth(jwt), 'content-type': 'application/json' },
      body: JSON.stringify({
        id: crypto.randomUUID(), date: '2026-10-24', kind: 'ride', name: 'Ride',
        start_date_local_ms: start - 7 * 3_600_000 + 20_000, start_date_utc_ms: start + 20_000,
        source_timezone: 'America/Los_Angeles', moving_time_sec: 3600,
      }),
    });
    expect(r.status).toBe(201);
    return (await r.json<any>()).id as string;
  };

  it('keeps the intervals.icu copy and restores the .fit copy when that goes away', async () => {
    const u = await makeUser('fit-intervals');
    const intervalsId = await insertIntervals(u.id);
    const { activity } = await (await upload(u.jwt, ride())).json<any>();
    expect(activity).toMatchObject({ duplicate_of: intervalsId, canonical: 0 });
    expect(activity.deleted_at).not.toBeNull();

    await env.DB.prepare('UPDATE external_activities SET deleted_at = 5, synced_at = 5 WHERE id = ?1').bind(intervalsId).run();
    await dedupeHealthKitAgainstIntervals(env.DB, u.id);
    expect(await stored(activity.id)).toMatchObject({ deleted_at: null, duplicate_of: null, canonical: 1 });
  });

  it('hides the Apple Health copy behind the .fit copy, and brings it back when the import is deleted', async () => {
    const u = await makeUser('fit-health');
    const healthId = await pushHealth(u.jwt);
    const clientId = crypto.randomUUID();
    const { activity } = await (await upload(u.jwt, ride(), clientId)).json<any>();
    expect(activity.deleted_at).toBeNull();
    expect(await stored(healthId)).toMatchObject({ duplicate_of: activity.id, canonical: 0 });

    // A later Apple Health push of the same workout stays hidden.
    expect(await pushHealth(u.jwt)).not.toBe(activity.id);
    const live = await env.DB.prepare('SELECT source FROM external_activities WHERE user_id = ?1 AND deleted_at IS NULL')
      .bind(u.id).all<{ source: string }>();
    expect(live.results.map(r => r.source)).toEqual(['fit']);

    const del = await SELF.fetch(`${BASE}/api/activities/fit/${clientId}`, { method: 'DELETE', headers: auth(u.jwt) });
    expect(del.status).toBe(200);
    expect((await stored(activity.id)).deleted_at).not.toBeNull();
    expect(await stored(healthId)).toMatchObject({ deleted_at: null, duplicate_of: null });
    // Deleting it again, or someone else's, finds nothing.
    expect((await SELF.fetch(`${BASE}/api/activities/fit/${clientId}`, { method: 'DELETE', headers: auth(u.jwt) })).status).toBe(404);
  });

  it('never lets one member delete another’s import', async () => {
    const a = await makeUser('fit-a');
    const b = await makeUser('fit-b');
    const clientId = crypto.randomUUID();
    const { activity } = await (await upload(a.jwt, ride(), clientId)).json<any>();
    expect((await SELF.fetch(`${BASE}/api/activities/fit/${clientId}`, { method: 'DELETE', headers: auth(b.jwt) })).status).toBe(404);
    expect((await stored(activity.id)).deleted_at).toBeNull();
  });
});

describe('fitLocalTime', () => {
  it('turns a device offset into a fixed-offset zone', () => {
    expect(fitLocalTime(Date.parse('2026-10-25T03:00:00Z'), 19_800, null))
      .toEqual({ date: '2026-10-25', localMs: Date.parse('2026-10-25T08:30:00Z'), zone: 'GMT+0530' });
    expect(fitLocalTime(Date.parse('2026-10-25T03:00:00Z'), null, 'Not/AZone'))
      .toEqual({ date: '2026-10-25', localMs: Date.parse('2026-10-25T03:00:00Z'), zone: 'GMT+0000' });
  });
});
