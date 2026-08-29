import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { sign, verify } from 'hono/jwt';
import { beforeAll, describe, expect, it } from 'vitest';
import {
  APP_JWT_MAX_SESSION_SECONDS,
  APP_JWT_TTL_SECONDS,
  issueAppJwt,
} from '../src/auth';
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
    expect(payload.auth_time).toBeDefined();
  });

  it('preserves the original authentication time, including for legacy tokens', async () => {
    const { user } = await makeSession('legacy');
    const nowSec = Math.floor(Date.now() / 1000);
    const originalAuthTime = nowSec - 30;
    const legacyJwt = await sign(
      {
        sub: user.id,
        iat: originalAuthTime,
        exp: nowSec + 60,
      },
      SECRET,
      'HS256',
    );

    const response = await SELF.fetch(`${BASE}/auth/renew`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${legacyJwt}` },
    });

    expect(response.status).toBe(200);
    const body = await response.json<{ jwt: string }>();
    const payload = await verify(body.jwt, SECRET, 'HS256');
    expect(payload.auth_time).toBe(originalAuthTime);
    expect(Number(payload.exp)).toBeLessThanOrEqual(
      originalAuthTime + APP_JWT_MAX_SESSION_SECONDS,
    );
  });

  it('requires Apple reauthentication at the absolute session ceiling', async () => {
    const { user } = await makeSession('absolute-expiry');
    const nowSec = Math.floor(Date.now() / 1000);
    const jwt = await sign(
      {
        sub: user.id,
        iat: nowSec - 60,
        exp: nowSec + 60,
        auth_time: nowSec - APP_JWT_MAX_SESSION_SECONDS,
      },
      SECRET,
      'HS256',
    );

    const response = await SELF.fetch(`${BASE}/auth/renew`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${jwt}` },
    });

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: 'reauthentication_required' });
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
