import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { verify } from 'hono/jwt';
import { beforeAll, describe, expect, it } from 'vitest';
import { APP_JWT_TTL_SECONDS, issueAppJwt } from '../src/auth';
import { upsertUser } from '../src/db';

const BASE = 'https://lift-coach.test';
const SECRET = 'test-secret';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

async function makeSession(label: string, ttlSeconds = APP_JWT_TTL_SECONDS) {
  const user = await upsertUser(
    env.DB,
    `session-${label}-${crypto.randomUUID()}`,
    `${label}@test`,
    label,
  );
  const jwt = await issueAppJwt(user.id, SECRET, { ttlSeconds });
  return { user, jwt };
}

describe('POST /auth/renew', () => {
  it('rolls a valid app session forward with the same user subject', async () => {
    const { user, jwt } = await makeSession('renew', 60);

    const response = await SELF.fetch(`${BASE}/auth/renew`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${jwt}` },
    });

    expect(response.status).toBe(200);
    const body = await response.json<{ jwt: string }>();
    expect(body.jwt).not.toBe(jwt);
    const payload = await verify(body.jwt, SECRET, 'HS256');
    expect(payload.sub).toBe(user.id);
    expect(Number(payload.exp) - Number(payload.iat)).toBe(APP_JWT_TTL_SECONDS);
  });

  it('requires reauthentication after the existing bearer expires', async () => {
    const { jwt } = await makeSession('expired', -1);
    const response = await SELF.fetch(`${BASE}/auth/renew`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${jwt}` },
    });
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: 'invalid_token' });
  });

});
