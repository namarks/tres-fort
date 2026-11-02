import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { issueAppJwt } from '../src/auth';
import { exportUserData } from '../src/db';
import { intervalsThresholdValue, thresholdSuggestions } from '../src/services/athleteThresholds';

// Athlete thresholds REST surface (migration 0059,
// docs/plans/endurance-training-load P0).

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

const headers = (jwt: string) => ({ 'content-type': 'application/json', Authorization: `Bearer ${jwt}` });

const post = (jwt: string, body: unknown) =>
  SELF.fetch(`${BASE}/api/me/thresholds`, { method: 'POST', headers: headers(jwt), body: JSON.stringify(body) });

const get = (jwt: string, query = '') => SELF.fetch(`${BASE}/api/me/thresholds${query}`, { headers: headers(jwt) });

const ftp = (over: Record<string, unknown> = {}) => ({
  id: crypto.randomUUID(), sport: 'ride', metric: 'ftp_w', value: 229, effective_date: '2026-06-01', ...over,
});

describe('athlete thresholds', () => {
  it('requires auth', async () => {
    expect((await SELF.fetch(`${BASE}/api/me/thresholds`)).status).toBe(401);
  });

  it('starts empty', async () => {
    const u = await makeUser('empty');
    const body = await (await get(u.jwt)).json<any>();
    expect(body.thresholds).toEqual([]);
    expect(body.current).toEqual({
      ride: { ftp_w: null, threshold_hr: null },
      run: { threshold_hr: null, threshold_pace_s_per_km: null },
    });
  });

  it('adds a threshold idempotently and rejects a reused id with a different value', async () => {
    const u = await makeUser('add');
    const input = ftp();
    const first = await post(u.jwt, input);
    expect(first.status).toBe(201);
    const created = await first.json<any>();
    expect(created.deduplicated).toBe(false);
    expect(created.threshold).toMatchObject({ id: input.id, sport: 'ride', metric: 'ftp_w', value: 229, source: 'member' });

    const retry = await post(u.jwt, input);
    expect(retry.status).toBe(200);
    expect((await retry.json<any>()).deduplicated).toBe(true);

    expect((await post(u.jwt, { ...input, value: 240 })).status).toBe(409);
    const other = await makeUser('thief');
    expect((await post(other.jwt, input)).status).toBe(409);
  });

  it('validates sport, metric, value range, date and unknown fields', async () => {
    const u = await makeUser('invalid');
    const fieldsOf = async (body: unknown) => {
      const r = await post(u.jwt, body);
      expect(r.status).toBe(400);
      return (await r.json<any>()).fields;
    };
    expect(await fieldsOf(ftp({ metric: 'threshold_pace_s_per_km' }))).toEqual(['metric']);
    expect(await fieldsOf(ftp({ sport: 'swim' }))).toEqual(['sport', 'metric']);
    expect(await fieldsOf(ftp({ value: 5000 }))).toEqual(['value']);
    expect(await fieldsOf(ftp({ value: '229' }))).toEqual(['value']);
    expect(await fieldsOf(ftp({ effective_date: '2026-02-30' }))).toEqual(['effective_date']);
    expect(await fieldsOf(ftp({ id: 'not-a-uuid' }))).toEqual(['id']);
    expect(await fieldsOf(ftp({ source: 'coach' }))).toEqual(['source']);
    expect((await get(u.jwt, '?as_of=yesterday')).status).toBe(400);
  });

  it('reports the values in effect on a date, and the latest without one', async () => {
    const u = await makeUser('current');
    await post(u.jwt, ftp({ value: 220, effective_date: '2026-05-01' }));
    await post(u.jwt, ftp({ value: 229, effective_date: '2026-09-01' }));
    await post(u.jwt, { id: crypto.randomUUID(), sport: 'run', metric: 'threshold_hr', value: 168, effective_date: '2026-07-01' });
    await post(u.jwt, { id: crypto.randomUUID(), sport: 'run', metric: 'threshold_pace_s_per_km', value: 290, effective_date: '2026-07-01' });

    const latest = await (await get(u.jwt)).json<any>();
    expect(latest.thresholds).toHaveLength(4);
    expect(latest.current).toEqual({
      ride: { ftp_w: 229, threshold_hr: null },
      run: { threshold_hr: 168, threshold_pace_s_per_km: 290 },
    });
    const august = await (await get(u.jwt, '?as_of=2026-08-15')).json<any>();
    expect(august.current.ride.ftp_w).toBe(220);
    expect(august.as_of).toBe('2026-08-15');
  });

  it('soft-deletes only the caller’s own rows', async () => {
    const u = await makeUser('delete');
    const other = await makeUser('other');
    const input = ftp();
    await post(u.jwt, input);

    const foreign = await SELF.fetch(`${BASE}/api/me/thresholds/${input.id}`, { method: 'DELETE', headers: headers(other.jwt) });
    expect(foreign.status).toBe(404);
    expect((await (await get(u.jwt)).json<any>()).thresholds).toHaveLength(1);

    const del = () => SELF.fetch(`${BASE}/api/me/thresholds/${input.id}`, { method: 'DELETE', headers: headers(u.jwt) });
    expect((await del()).status).toBe(200);
    expect((await del()).status).toBe(200);
    expect((await (await get(u.jwt)).json<any>()).thresholds).toEqual([]);
    const row = await env.DB.prepare('SELECT deleted_at FROM athlete_thresholds WHERE id=?1').bind(input.id).first<any>();
    expect(row.deleted_at).toBeGreaterThan(0);

    // The id stays taken: re-adding it after deletion is a conflict.
    expect((await post(u.jwt, input)).status).toBe(409);
  });

  it('is included in the account export', async () => {
    const u = await makeUser('export');
    const input = ftp();
    await post(u.jwt, input);
    const exported = await exportUserData(env.DB, u.id);
    expect((exported?.training as any).athlete_thresholds).toEqual([
      expect.objectContaining({ id: input.id, metric: 'ftp_w', value: 229, deleted_at: null }),
    ]);
  });
});

// Suggestions from intervals.icu (P7): each synced activity carries the sport
// settings intervals.icu scored it with.
async function intervalsActivity(userId: string, kind: string, date: string, raw: Record<string, unknown>, source = 'intervals') {
  const ext = crypto.randomUUID();
  await env.DB.prepare(
    `INSERT INTO external_activities (id,user_id,source,external_id,date,start_date_local_ms,kind,name,raw,synced_at)
     VALUES (?1,?2,?3,?4,?5,?6,?7,'Workout',?8,1)`,
  ).bind(`${source}:activity:${userId}:${ext}`, userId, source, ext, date, Date.parse(`${date}T07:00:00Z`), kind,
    JSON.stringify(raw)).run();
}

const suggestions = async (jwt: string) => {
  const r = await SELF.fetch(`${BASE}/api/me/thresholds/suggestions`, { headers: headers(jwt) });
  expect(r.status).toBe(200);
  return (await r.json<any>()).suggestions;
};

describe('threshold suggestions from intervals.icu', () => {
  it('requires auth and is empty without intervals.icu workouts', async () => {
    expect((await SELF.fetch(`${BASE}/api/me/thresholds/suggestions`)).status).toBe(401);
    const u = await makeUser('nosuggest');
    expect(await suggestions(u.jwt)).toEqual([]);
  });

  it('suggests the newest settings per sport, and saving one as intervals clears it', async () => {
    const u = await makeUser('suggest');
    await intervalsActivity(u.id, 'ride', '2026-10-01', { icu_ftp: 240, lthr: 160 });
    await intervalsActivity(u.id, 'ride', '2026-10-20', { icu_ftp: 251, lthr: null });
    await intervalsActivity(u.id, 'run', '2026-10-25', { lthr: 171, threshold_pace: 3.7 });
    // Another source's row and a deleted row are ignored.
    await intervalsActivity(u.id, 'ride', '2026-10-30', { icu_ftp: 400 }, 'healthkit');
    await intervalsActivity(u.id, 'ride', '2026-10-31', { icu_ftp: 300 });
    await env.DB.prepare("UPDATE external_activities SET deleted_at = 1 WHERE user_id = ?1 AND date = '2026-10-31'").bind(u.id).run();

    expect(await suggestions(u.jwt)).toEqual([
      { sport: 'ride', metric: 'ftp_w', value: 251, as_of: '2026-10-20' },
      { sport: 'ride', metric: 'threshold_hr', value: 160, as_of: '2026-10-01' },
      { sport: 'run', metric: 'threshold_hr', value: 171, as_of: '2026-10-25' },
      // 3.7 m/s is 270 s per km (4:30 /km).
      { sport: 'run', metric: 'threshold_pace_s_per_km', value: 270, as_of: '2026-10-25' },
    ]);

    const saved = await post(u.jwt, ftp({ value: 251, effective_date: '2026-10-20', source: 'intervals' }));
    expect(saved.status).toBe(201);
    expect((await saved.json<any>()).threshold.source).toBe('intervals');
    expect((await suggestions(u.jwt)).map((s: any) => s.metric)).toEqual(['threshold_hr', 'threshold_hr', 'threshold_pace_s_per_km']);
  });

  it('never second-guesses a value the member set after the workout', async () => {
    const u = await makeUser('later');
    await intervalsActivity(u.id, 'ride', '2026-10-20', { icu_ftp: 251 });
    await post(u.jwt, ftp({ value: 265, effective_date: '2026-10-28' }));
    expect(await suggestions(u.jwt)).toEqual([]);
  });

  it('suggests a newer value even when the member has an older one', async () => {
    const u = await makeUser('newer');
    await post(u.jwt, ftp({ value: 229, effective_date: '2026-06-01' }));
    await intervalsActivity(u.id, 'ride', '2026-10-20', { icu_ftp: 251 });
    expect(await suggestions(u.jwt)).toEqual([{ sport: 'ride', metric: 'ftp_w', value: 251, as_of: '2026-10-20' }]);
  });

  it('reads values in range only', () => {
    expect(intervalsThresholdValue('ftp_w', 250.4)).toBe(250);
    expect(intervalsThresholdValue('ftp_w', 0)).toBeNull();
    expect(intervalsThresholdValue('ftp_w', '250')).toBeNull();
    expect(intervalsThresholdValue('threshold_hr', 300)).toBeNull();
    expect(intervalsThresholdValue('threshold_pace_s_per_km', 3.7)).toBe(270);
    // Slower than 20:00 per km is out of range.
    expect(intervalsThresholdValue('threshold_pace_s_per_km', 0.5)).toBeNull();
    expect(thresholdSuggestions([{ kind: 'ride', date: 'bad', icu_ftp: 250, lthr: null, threshold_pace: null }], [])).toEqual([]);
  });

  it('rejects any other source', async () => {
    const u = await makeUser('badsource');
    const r = await post(u.jwt, ftp({ source: 'garmin' }));
    expect(r.status).toBe(400);
    expect((await r.json<any>()).fields).toEqual(['source']);
  });
});

