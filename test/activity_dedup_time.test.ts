import { applyD1Migrations, env } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { dedupeHealthKitAgainstIntervals, getRecentActivities, getState,
  syncExternalActivities, upsertHealthKitActivity, type HealthKitActivityInput } from '../src/db';
import type { ExternalActivityRow } from '../src/types';

beforeAll(async () => { await applyD1Migrations(env.DB, env.TEST_MIGRATIONS); });

const instant = Date.parse('2026-06-18T17:00:00Z');
const hour = 3_600_000;
async function user() {
  const id = crypto.randomUUID();
  await env.DB.prepare(`INSERT INTO users (id,apple_sub,created_at,intervals_api_key,intervals_athlete_id)
    VALUES (?1,?1,1,'test-key','test-athlete')`).bind(id).run();
  return id;
}
function health(kind = 'ride', overrides: Partial<HealthKitActivityInput> = {}): HealthKitActivityInput {
  return { id: crypto.randomUUID(), date: '2026-06-18', kind, name: 'Health workout',
    start_date_local_ms: instant - 3 * hour, start_date_utc_ms: instant, source_timezone: null,
    moving_time_sec: 2400, elapsed_time_sec: 2400, distance_m: 15000, average_watts: null,
    average_hr: null, max_hr: null, calories: null, elevation_gain_m: null, raw: null, ...overrides };
}
function sync(userId: string, kind = 'ride', activities?: unknown[]) {
  return syncExternalActivities(env.DB, env, { userId, today: '2026-06-18', pastDays: 0,
    fetcher: async () => ({ ok: true, status: 200, json: async () => activities ?? [{
      id: 'provider-workout', type: kind === 'ride' ? 'VirtualRide' : 'Run',
      name: 'Provider workout', start_date_local: '2026-06-18T10:00:00',
      start_date: new Date(instant).toISOString(), moving_time: 2400,
    }] }) });
}
async function read(id: string) {
  return (await env.DB.prepare('SELECT * FROM external_activities WHERE id=?1').bind(id)
    .first<ExternalActivityRow>())!;
}
async function interval(userId: string, local: number, utc: number | null, suffix = 'interval') {
  const id = `intervals:activity:${userId}:${suffix}`;
  await env.DB.prepare(`INSERT INTO external_activities
    (id,user_id,source,external_id,date,kind,start_date_local_ms,start_date_utc_ms,synced_at)
    VALUES (?1,?2,'intervals',?3,?4,'ride',?5,?6,1)`)
    .bind(id, userId, suffix, new Date(local).toISOString().slice(0,10), local, utc).run();
  return id;
}

describe('Intervals and HealthKit match source instants', () => {
  it.each(['ride', 'run'])('collapses %s imports with a four-hour civil offset in both arrival orders', async kind => {
    for (const healthFirst of [true, false]) {
      const userId = await user();
      const input = health(kind);
      if (!healthFirst) expect((await sync(userId, kind)).status).toBe('ok');
      const pushed = await upsertHealthKitActivity(env.DB, userId, input);
      if (healthFirst) expect((await sync(userId, kind)).status).toBe('ok');
      const retired = await read(pushed.id);
      expect(retired.deleted_at).not.toBeNull();
      expect(retired.duplicate_of).toBe(`intervals:activity:${userId}:provider-workout`);
      expect(await getRecentActivities(env.DB,userId,{to:'2026-06-18'})).toHaveLength(1);
      expect((await getState(env.DB,userId,0,0,0,0)).external_activities.map(a => a.id))
        .toEqual([retired.duplicate_of]);
      if (healthFirst) {
        expect(retired.synced_at).toBeGreaterThan(pushed.synced_at);
        expect((await getState(env.DB,userId,0,0,0,pushed.synced_at)).external_activities)
          .toContainEqual(retired);
      }
      expect((await upsertHealthKitActivity(env.DB,userId,input)).synced_at).toBe(retired.synced_at);
      expect(await dedupeHealthKitAgainstIntervals(env.DB,userId)).toBe(0);
      expect((await sync(userId,kind,[])).status).toBe('ok');
      expect(await read(pushed.id)).toMatchObject({deleted_at:null,canonical:1,duplicate_of:null});
    }
  });

  it.each([120000, 120001])('uses the two-minute limit on absolute timestamps (%i ms)', async delta => {
    const userId = await user();
    await interval(userId,instant-7*hour,instant+delta);
    const row = await upsertHealthKitActivity(env.DB,userId,health());
    expect(row.deleted_at !== null).toBe(delta <= 120000);
  });

  it('does not collapse distinct DST occurrences with identical local clocks', async () => {
    const userId = await user();
    const local = Date.parse('2026-11-01T01:30:00Z');
    const utc = Date.parse('2026-11-01T08:30:00Z');
    await interval(userId,local,utc);
    const row = await upsertHealthKitActivity(env.DB,userId,health('ride',{
      date:'2026-11-01',start_date_local_ms:local,start_date_utc_ms:utc+hour,
    }));
    expect(row.deleted_at).toBeNull();
  });

  it.each(['healthkit','intervals','both'])('retains local-clock fallback when %s lacks an instant', async missing => {
    const userId = await user();
    const local = instant-3*hour;
    const id = await interval(userId,local,missing === 'healthkit' ? instant : null);
    const row = await upsertHealthKitActivity(env.DB,userId,health('ride',{
      start_date_utc_ms:missing === 'intervals' ? instant : null,
    }));
    expect(row.duplicate_of).toBe(id);
  });

  it('prefers an absolute match over a closer legacy local-clock candidate', async () => {
    const userId = await user();
    await interval(userId,instant-3*hour,null,'legacy');
    const id = await interval(userId,instant-7*hour,instant+30000,'absolute');
    expect((await upsertHealthKitActivity(env.DB,userId,health())).duplicate_of).toBe(id);
  });

  it('breaks absolute-clock ties by instant then id, independently of the local clock', async () => {
    const userId = await user();
    await interval(userId,instant-10*hour,instant+30000,'a-later');
    await interval(userId,instant-8*hour,instant-30000,'z-earlier');
    const id = await interval(userId,instant-7*hour,instant-30000,'a-earlier');
    expect((await upsertHealthKitActivity(env.DB,userId,health())).duplicate_of).toBe(id);
  });

  it('keeps other users and different activity kinds isolated', async () => {
    await interval(await user(),instant-3*hour,instant);
    const userId = await user();
    expect((await upsertHealthKitActivity(env.DB,userId,health())).deleted_at).toBeNull();
    await interval(userId,instant-3*hour,instant);
    expect((await upsertHealthKitActivity(env.DB,userId,health('run'))).deleted_at).toBeNull();
  });

  it('bounded sync includes the same instant two civil dates away across the date line', async () => {
    const userId = await user();
    const utc = Date.parse('2026-06-19T11:30:00Z');
    const row = await upsertHealthKitActivity(env.DB,userId,health('ride',{
      date:'2026-06-20',start_date_local_ms:utc+14*hour,start_date_utc_ms:utc,
    }));
    expect((await sync(userId,'ride',[{id:'provider-workout',type:'Ride',
      start_date_local:'2026-06-18T23:30:00',start_date:new Date(utc).toISOString(),moving_time:2400,
    }])).status).toBe('ok');
    expect((await read(row.id)).duplicate_of).toBe(`intervals:activity:${userId}:provider-workout`);
    expect((await sync(userId,'ride',[])).status).toBe('ok');
    expect((await read(row.id)).deleted_at).toBeNull();
  });
});
