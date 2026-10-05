import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { issueAppJwt } from '../src/auth';
import { upsertUser } from '../src/db';
import { deriveStationLinkKey } from '../src/stationLink';

const BASE = 'https://lift-coach.test';
const SECRET = 'test-secret';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

async function session(label: string) {
  const user = await upsertUser(env.DB, `station-${label}-${crypto.randomUUID()}`, `${label}@test`, label);
  return { user, jwt: await issueAppJwt(user.id, SECRET) };
}

async function fetchKey(jwt?: string) {
  return SELF.fetch(`${BASE}/api/me/station-link-key`, {
    headers: jwt ? { Authorization: `Bearer ${jwt}` } : {},
  });
}

describe('GET /api/me/station-link-key', () => {
  it('returns the same uncached key to every session of one account', async () => {
    const { user, jwt } = await session('phone');
    const ipadJwt = await issueAppJwt(user.id, SECRET);

    const phone = await fetchKey(jwt);
    expect(phone.status).toBe(200);
    expect(phone.headers.get('Cache-Control')).toBe('no-store');
    const body = await phone.json<{ version: number; key: string }>();
    expect(body.version).toBe(1);
    expect(atob(body.key)).toHaveLength(32);
    expect(body.key).toBe(await deriveStationLinkKey(SECRET, user.id));

    const ipad = await (await fetchKey(ipadJwt)).json<{ key: string }>();
    expect(ipad.key).toBe(body.key);
  });

  it('gives each account its own key and requires a session', async () => {
    const a = await session('a');
    const b = await session('b');
    const keyA = (await (await fetchKey(a.jwt)).json<{ key: string }>()).key;
    const keyB = (await (await fetchKey(b.jwt)).json<{ key: string }>()).key;
    expect(keyA).not.toBe(keyB);
    expect((await fetchKey()).status).toBe(401);
  });

  it('separates the link key from the session secret and other labels', async () => {
    const { user } = await session('label');
    const key = await deriveStationLinkKey(SECRET, user.id);
    expect(key).not.toBe(await deriveStationLinkKey('other-secret', user.id));
    expect(key).not.toContain(user.id);
  });
});
