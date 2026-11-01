import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { issueAppJwt } from '../src/auth';
import { exportUserData } from '../src/db';

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
