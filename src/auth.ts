// Two credentials, one user_id. iOS -> Sign in with Apple -> app JWT.
// MCP (milestone b) -> OAuth or static bearer. This file owns the app-JWT
// side + the iOS auth middleware.
import { sign, verify } from 'hono/jwt';
import { createMiddleware } from 'hono/factory';
import { createRemoteJWKSet, jwtVerify } from 'jose';
import type { HonoEnv } from './types';

const APPLE_ISS = 'https://appleid.apple.com';
const APP_JWT_TTL_SECONDS = 60 * 60 * 24 * 60; // 60 days

let appleJwks: ReturnType<typeof createRemoteJWKSet> | null = null;
function jwks() {
  if (!appleJwks) appleJwks = createRemoteJWKSet(new URL(`${APPLE_ISS}/auth/keys`));
  return appleJwks;
}

/** Verify Apple's identity token; return the stable subject + email. */
export async function verifyAppleToken(
  identityToken: string,
  bundleId: string,
): Promise<{ sub: string; email: string | null }> {
  const { payload } = await jwtVerify(identityToken, jwks(), {
    issuer: APPLE_ISS,
    audience: bundleId,
  });
  if (!payload.sub) throw new Error('apple_token_missing_sub');
  return { sub: payload.sub, email: (payload.email as string) ?? null };
}

export async function issueAppJwt(userId: string, secret: string): Promise<string> {
  const nowSec = Math.floor(Date.now() / 1000);
  return sign(
    { sub: userId, iat: nowSec, exp: nowSec + APP_JWT_TTL_SECONDS },
    secret,
    'HS256',
  );
}

/** Bearer-app-JWT middleware for /api/*. Sets `userId` on the context. */
export const requireAppJwt = createMiddleware<HonoEnv>(async (c, next) => {
  const header = c.req.header('Authorization') ?? '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : '';
  if (!token) return c.json({ error: 'missing_bearer' }, 401);
  try {
    const payload = await verify(token, c.env.APP_JWT_SECRET, 'HS256');
    if (!payload.sub || typeof payload.sub !== 'string') {
      return c.json({ error: 'invalid_token' }, 401);
    }
    c.set('userId', payload.sub);
  } catch {
    return c.json({ error: 'invalid_token' }, 401);
  }
  await next();
});

/** Owner allowlist: if OWNER_APPLE_SUB is set, only that sub may sign in. */
export function assertOwner(sub: string, ownerSub: string | undefined) {
  if (ownerSub && ownerSub !== sub) {
    throw new Error('not_owner');
  }
}
