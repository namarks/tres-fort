import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { issueAppJwt } from '../src/auth';
import {
  HEALTHKIT_SPORTS, HEART_RATE_THRESHOLDS, INTERVALS_SPORTS, SPORTS, healthKitTypeOf, heartRateThresholdFor,
  isSport, sportForFit, sportForHealthKitType, sportForIntervalsType, sportLabel,
} from '../src/sports';
import { fetchCompletedActivities, type Fetcher } from '../src/intervals';
import { parseFit } from '../src/fitFile';
import fixture from '../ios/TresFortTests/Fixtures/Sports.json';
import { activityFit } from './fitWriter';

// Sport identity (docs/plans/sport-activities P0).

const BASE = 'https://tres-fort.test';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

async function makeUser(label: string) {
  const id = crypto.randomUUID();
  await env.DB.prepare('INSERT INTO users (id,apple_sub,email,display_name,created_at) VALUES (?1,?2,?3,?4,?5)')
    .bind(id, `sub-${label}-${id}`, `${label}@test`, label, Date.now())
    .run();
  return { id, jwt: await issueAppJwt(id, 'test-secret') };
}

const json = (jwt: string) => ({ 'content-type': 'application/json', Authorization: `Bearer ${jwt}` });

const migration0064 = () => {
  const m = (env.TEST_MIGRATIONS as Array<{ name: string; queries: string[] }>)
    .find(x => x.name.startsWith('0064'));
  expect(m, '0064 migration not found').toBeTruthy();
  return m!.queries;
};

describe('the sport vocabulary', () => {
  it('matches the contract the iOS app is tested against', () => {
    expect(SPORTS).toEqual(fixture.sports);
    expect(Object.fromEntries(Object.entries(HEALTHKIT_SPORTS))).toEqual(fixture.healthkit);
    expect(HEART_RATE_THRESHOLDS).toEqual(fixture.heart_rate_thresholds);
  });

  it('names a threshold set only for sports heart rate can score (P1)', () => {
    for (const s of Object.keys(HEART_RATE_THRESHOLDS)) expect(isSport(s), s).toBe(true);
    expect(heartRateThresholdFor('soccer')).toBe('run');
    expect(heartRateThresholdFor('ride')).toBe('ride');
    for (const s of ['swim', 'strength', 'yoga', 'row', 'paddling', 'other', 'toString', null, undefined]) {
      expect(heartRateThresholdFor(s), String(s)).toBeNull();
    }
  });

  it('has unique ids and only maps to known sports', () => {
    expect(new Set(SPORTS.map(s => s.id)).size).toBe(SPORTS.length);
    for (const s of [...Object.values(HEALTHKIT_SPORTS), ...Object.values(INTERVALS_SPORTS)]) {
      expect(isSport(s), s).toBe(true);
    }
    expect(sportLabel('soccer')).toBe('Soccer');
    expect(sportLabel('nope')).toBeNull();
  });

  it('names Apple Health workouts by their activity type', () => {
    expect(sportForHealthKitType(41, 'other')).toBe('soccer');
    expect(sportForHealthKitType(46, 'swim')).toBe('swim');
    expect(sportForHealthKitType(3000, 'other')).toBe('other');
    // No type kept (an import without raw): the kind stands in when it is a sport.
    expect(sportForHealthKitType(null, 'run')).toBe('run');
    expect(sportForHealthKitType(null, 'ski')).toBe('other');
    expect(healthKitTypeOf('{"hk_activity_type":41,"source":"Watch"}')).toBe(41);
    expect(healthKitTypeOf('not json')).toBeNull();
    expect(healthKitTypeOf(null)).toBeNull();
  });

  it('names intervals.icu activities by their type', () => {
    expect(sportForIntervalsType('Soccer', 'other')).toBe('soccer');
    expect(sportForIntervalsType('VirtualRide', 'ride')).toBe('ride');
    expect(sportForIntervalsType('OpenWaterSwim', 'swim')).toBe('swim');
    expect(sportForIntervalsType('SomethingNew', 'run')).toBe('run');
    expect(sportForIntervalsType('toString', 'other')).toBe('other');
  });

  it('names .fit workouts by their sport and sub-sport', () => {
    expect(sportForFit(7, 0, 'other')).toBe('soccer');
    expect(sportForFit(10, 20, 'other')).toBe('strength');
    expect(sportForFit(2, 0, 'ride')).toBe('ride');
    expect(sportForFit(4, 16, 'other')).toBe('stairs');
    expect(sportForFit(99, null, 'other')).toBe('other');
    const fit = parseFit(activityFit({ start: '2026-10-25T03:00:00Z', seconds: 600, sport: 7, hr: 150 }));
    expect(fit).toMatchObject({ kind: 'other', sport: 'soccer' });
  });

  it("keeps migration 0064's backfill tables identical to these maps", () => {
    const sql = migration0064().join('\n');
    const tuples = [...sql.matchAll(/\('(healthkit|intervals)', '([^']*)', '([^']*)'\)/g)]
      .map(m => [m[1], m[2], m[3]]);
    expect(tuples.filter(t => t[0] === 'healthkit').map(t => [t[1], t[2]]))
      .toEqual(Object.entries(HEALTHKIT_SPORTS));
    expect(tuples.filter(t => t[0] === 'intervals').map(t => [t[1], t[2]]))
      .toEqual(Object.entries(INTERVALS_SPORTS));
    const labels = [...sql.matchAll(/^ {2}\('([a-z_]+)', '([^']*)'\)/gm)].map(m => ({ id: m[1], label: m[2] }));
    expect(labels).toEqual(SPORTS);
  });
});

describe('importers record the sport', () => {
  it('an Apple Health soccer match is Soccer, even from an app that called it Workout', async () => {
    const u = await makeUser('hk-soccer');
    const r = await SELF.fetch(`${BASE}/api/activities/healthkit`, {
      method: 'POST',
      headers: json(u.jwt),
      body: JSON.stringify({
        id: crypto.randomUUID(), date: '2026-11-02', start_date_local_ms: Date.parse('2026-11-02T19:00:00Z'),
        kind: 'other', name: 'Workout', moving_time_sec: 5400, elapsed_time_sec: 5400,
        distance_m: null, average_hr: 151, max_hr: 182, calories: 900,
        raw: JSON.stringify({ hk_activity_type: 41, source: 'Apple Watch' }),
      }),
    });
    expect(r.status).toBe(201);
    expect(await r.json()).toMatchObject({ kind: 'other', sport: 'soccer', name: 'Soccer' });
  });

  it('keeps a real name and leaves an unknown type as Other', async () => {
    const u = await makeUser('hk-other');
    const push = async (name: string | null, type: number) => {
      const r = await SELF.fetch(`${BASE}/api/activities/healthkit`, {
        method: 'POST',
        headers: json(u.jwt),
        body: JSON.stringify({
          id: crypto.randomUUID(), date: '2026-11-02', start_date_local_ms: Date.parse('2026-11-02T08:00:00Z'),
          kind: 'other', name, moving_time_sec: 1800, elapsed_time_sec: 1800,
          raw: JSON.stringify({ hk_activity_type: type }),
        }),
      });
      expect(r.status).toBe(201);
      return r.json<any>();
    };
    expect(await push('Tennis', 48)).toMatchObject({ sport: 'tennis', name: 'Tennis' });
    expect(await push('Workout', 3000)).toMatchObject({ sport: 'other', name: 'Workout' });
  });

  it('a .fit soccer file imports as Soccer', async () => {
    const u = await makeUser('fit-soccer');
    const form = new FormData();
    form.set('id', crypto.randomUUID());
    form.set('file', new File([activityFit({ start: '2026-10-25T18:00:00Z', seconds: 1200, sport: 7, hr: 150 })], 'match.fit'));
    const r = await SELF.fetch(`${BASE}/api/activities/fit`, {
      method: 'POST', headers: { Authorization: `Bearer ${u.jwt}` }, body: form,
    });
    expect(r.status).toBe(201);
    expect((await r.json<any>()).activity).toMatchObject({ kind: 'other', sport: 'soccer', name: 'Soccer' });
  });

  it('intervals.icu activities carry their sport from the fetch', async () => {
    const fetcher: Fetcher = async () => ({
      ok: true, status: 200,
      json: async () => [{
        id: 'i1', type: 'Soccer', name: 'Evening Soccer', start_date_local: '2026-11-02T19:00:00',
        moving_time: 5400, elapsed_time: 5400,
      }],
    });
    const res = await fetchCompletedActivities('key', 'i0', { fetcher, today: '2026-11-03' });
    expect(res.ok).toBe(true);
    if (res.ok) expect(res.activities[0]).toMatchObject({ kind: 'other', sport: 'soccer' });
  });
});

describe('migration 0064 backfill', () => {
  it('derives the sport from stored provider JSON and renames Apple Health Workouts', async () => {
    const u = await makeUser('backfill');
    const insert = (id: string, source: string, kind: string, name: string | null, raw: string | null, deleted: number | null = null) =>
      env.DB.prepare(
        `INSERT INTO external_activities (id,user_id,source,external_id,date,kind,name,raw,synced_at,deleted_at)
         VALUES (?1,?2,?3,?1,'2026-10-01',?4,?5,?6,5,?7)`,
      ).bind(id, u.id, source, kind, name, raw, deleted).run();
    const p = `bf-${u.id}`;
    await insert(`${p}-hk-soccer`, 'healthkit', 'other', 'Workout', '{"hk_activity_type":41}');
    await insert(`${p}-hk-unknown`, 'healthkit', 'other', 'Workout', '{"hk_activity_type":3000}');
    await insert(`${p}-hk-noraw`, 'healthkit', 'run', 'Run', null);
    await insert(`${p}-iv-tennis`, 'intervals', 'other', 'Club tennis', '{"type":"Tennis"}');
    await insert(`${p}-iv-new`, 'intervals', 'ride', 'Ride', '{"type":"SomethingNew"}');
    await insert(`${p}-iv-bad`, 'intervals', 'ski', 'Ski', 'not json');
    await insert(`${p}-fit`, 'fit', 'run', 'Run', '{"source":"fit"}');
    await insert(`${p}-gone`, 'healthkit', 'other', 'Workout', '{"hk_activity_type":48}', 1);

    // Re-run 0064's statements after its ALTER TABLE on these rows.
    await env.DB.prepare('UPDATE external_activities SET sport = NULL WHERE user_id = ?1').bind(u.id).run();
    for (const q of migration0064().filter(q => !/ALTER TABLE/i.test(q))) await env.DB.prepare(q).run();

    const rows = await env.DB.prepare(
      'SELECT id, sport, name, synced_at FROM external_activities WHERE user_id = ?1',
    ).bind(u.id).all<{ id: string; sport: string; name: string; synced_at: number }>();
    const by = Object.fromEntries(rows.results.map(r => [r.id.slice(p.length + 1), r]));
    expect(by['hk-soccer']).toMatchObject({ sport: 'soccer', name: 'Soccer' });
    expect(by['hk-unknown']).toMatchObject({ sport: 'other', name: 'Workout' });
    expect(by['hk-noraw']).toMatchObject({ sport: 'run', name: 'Run' });
    expect(by['iv-tennis']).toMatchObject({ sport: 'tennis', name: 'Club tennis' });
    expect(by['iv-new']).toMatchObject({ sport: 'ride' });
    expect(by['iv-bad']).toMatchObject({ sport: 'other' });
    expect(by['fit']).toMatchObject({ sport: 'run' });
    // A deleted row is labeled too (a hidden duplicate can come back) but
    // keeps its cursor; live rows move past every installed app's watermark.
    expect(by['gone']).toMatchObject({ sport: 'tennis', synced_at: 5 });
    expect(by['hk-soccer']!.synced_at).toBeGreaterThan(Date.now() - 60_000);
  });
});
