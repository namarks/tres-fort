import { Hono } from 'hono';
import type { HonoEnv } from '../types';
import { assertOwner, issueAppJwt, verifyAppleToken } from '../auth';
import { claimOrCreateOwner, upsertUser } from '../db';

export const authRoutes = new Hono<HonoEnv>();

// POST /auth/apple  { identityToken, fullName? } -> { jwt, user }
authRoutes.post('/apple', async (c) => {
  const body = await c.req.json<{ identityToken?: string; fullName?: string }>();
  if (!body.identityToken) return c.json({ error: 'missing_identityToken' }, 400);
  let claims;
  try {
    claims = await verifyAppleToken(body.identityToken, c.env.APPLE_BUNDLE_ID);
  } catch {
    return c.json({ error: 'apple_verification_failed' }, 401);
  }
  try {
    assertOwner(claims.sub, c.env.OWNER_APPLE_SUB);
  } catch {
    return c.json({ error: 'not_authorized' }, 403);
  }
  const user = await claimOrCreateOwner(
    c.env.DB,
    claims.sub,
    claims.email,
    body.fullName ?? null,
    !!c.env.OWNER_APPLE_SUB,
  );
  const jwt = await issueAppJwt(user.id, c.env.APP_JWT_SECRET);
  return c.json({ jwt, user });
});

// POST /auth/dev  { secret }  -> { jwt, user }
// Enabled ONLY when DEV_AUTH_SECRET is set (local + integration tests).
authRoutes.post('/dev', async (c) => {
  if (!c.env.DEV_AUTH_SECRET) return c.json({ error: 'dev_auth_disabled' }, 404);
  const body = await c.req.json<{ secret?: string }>().catch(() => ({}) as { secret?: string });
  if (body.secret !== c.env.DEV_AUTH_SECRET) {
    return c.json({ error: 'bad_dev_secret' }, 401);
  }
  const sub = c.env.OWNER_APPLE_SUB ?? 'dev-owner';
  const user = await upsertUser(c.env.DB, sub, 'dev@local', 'Dev Owner');
  const jwt = await issueAppJwt(user.id, c.env.APP_JWT_SECRET);
  return c.json({ jwt, user });
});
