import { applyD1Migrations, env } from 'cloudflare:test';
import { Hono } from 'hono';
import { beforeAll, describe, expect, it } from 'vitest';
import { APP_REVIEW_SUB } from '../src/appReview';
import { issueAppJwt } from '../src/auth';
import { ensureOwnerUser, findOwnerRow, isBootstrapClaimEligible } from '../src/db';
import { createAuthRoutes } from '../src/routes/auth';
import { apiRoutes } from '../src/routes/api';
import type { HonoEnv } from '../src/types';

const app = new Hono<HonoEnv>().route('/auth', createAuthRoutes()).route('/api', apiRoutes);
const bindings = { ...env, OWNER_APPLE_SUB: 'owner-sub', APP_REVIEW_PASSWORD_SHA256: 'a'.repeat(64) };
beforeAll(async () => { await applyD1Migrations(env.DB, env.TEST_MIGRATIONS); });

async function historicalSample() {
  const id = crypto.randomUUID();
  await env.DB.prepare('INSERT INTO users (id,apple_sub,display_name,created_at) VALUES (?1,?2,?3,1)')
    .bind(id, APP_REVIEW_SUB, 'Historical sample').run();
  return { id };
}

describe('retired reviewer login', () => {
  it('does not expose a password endpoint even with the old secret configured', async () => {
    const response = await app.request('https://test/auth/review', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'app-review', password: 'synthetic-password' }),
    }, bindings);
    expect(response.status).toBe(404);
    expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM users').first<number>('n')).toBe(0);
  });

  it('revokes old sample tokens, renewal and forged sample claims without affecting personal sessions', async () => {
    const sample = await historicalSample();
    const owner = (await ensureOwnerUser(env.DB, bindings.OWNER_APPLE_SUB))!;
    for (const [id, appReview] of [[sample.id, true], [sample.id, false], [owner.id, true]] as const) {
      const jwt = await issueAppJwt(id, env.APP_JWT_SECRET, { appReview });
      for (const [path, method] of [['/api/state', 'GET'], ['/auth/renew', 'POST']]) {
        const response = await app.request(`https://test${path}`, { method, headers: { Authorization: `Bearer ${jwt}` } }, bindings);
        expect(response.status, `${id}:${path}`).toBe(401);
      }
    }
    const jwt = await issueAppJwt(owner.id, env.APP_JWT_SECRET);
    expect((await app.request('https://test/api/state', { headers: { Authorization: `Bearer ${jwt}` } }, bindings)).status).toBe(200);
  });

  it('keeps historical sample data excluded from owner bootstrap', async () => {
    const sample = await historicalSample();
    expect(await findOwnerRow(env.DB, undefined)).toBeNull();
    expect(await findOwnerRow(env.DB, APP_REVIEW_SUB)).toBeNull();
    expect(await ensureOwnerUser(env.DB, APP_REVIEW_SUB)).toBeNull();
    expect(await isBootstrapClaimEligible(env.DB)).toBe(true);
    expect((await ensureOwnerUser(env.DB, undefined))!.id).not.toBe(sample.id);
  });
});
