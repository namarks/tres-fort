// Two credentials, one user_id. iOS -> Sign in with Apple -> app JWT.
// MCP (milestone b) -> OAuth or static bearer. This file owns the app-JWT
// side + the iOS auth middleware.
import { sign, verify } from 'hono/jwt';
import { createMiddleware } from 'hono/factory';
import { createRemoteJWKSet, jwtVerify } from 'jose';
import type { HonoEnv } from './types';
import {
  accountDeletionContinuationMatches,
  setUserTimezoneIfChanged,
} from './db';

const APPLE_ISS = 'https://appleid.apple.com';
export const APP_JWT_TTL_SECONDS = 60 * 60 * 24 * 60; // 60 days
export const APP_JWT_MAX_SESSION_SECONDS = 60 * 60 * 24 * 180; // 180 days

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

export async function issueAppJwt(
  userId: string,
  secret: string,
  options: {
    nowSeconds?: number;
    ttlSeconds?: number;
    authTimeSeconds?: number;
  } = {},
): Promise<string> {
  const nowSec = options.nowSeconds ?? Math.floor(Date.now() / 1000);
  const ttlSeconds = options.ttlSeconds ?? APP_JWT_TTL_SECONDS;
  const authTimeSec = options.authTimeSeconds ?? nowSec;
  return sign(
    {
      sub: userId,
      iat: nowSec,
      auth_time: authTimeSec,
      exp: Math.min(
        nowSec + ttlSeconds,
        authTimeSec + APP_JWT_MAX_SESSION_SECONDS,
      ),
    },
    secret,
    'HS256',
  );
}

type AppJwtPayload = Awaited<ReturnType<typeof verify>>;

function appJwtPrincipal(
  payload: AppJwtPayload,
): { userId: string; authTime: number } | null {
  if (!payload.sub || typeof payload.sub !== 'string') return null;
  // Tokens issued before auth_time shipped fall back to their original iat.
  // Renewal then stamps that value into auth_time, so a legacy bearer cannot
  // reset the absolute session lifetime merely by crossing the rollout.
  const authTime =
    typeof payload.auth_time === 'number'
      ? payload.auth_time
      : typeof payload.iat === 'number'
        ? payload.iat
        : null;
  if (authTime === null || !Number.isFinite(authTime)) return null;
  return { userId: payload.sub, authTime };
}

/** Bearer-app-JWT middleware for /api/*. Sets `userId` on the context. */
export const requireAppJwt = createMiddleware<HonoEnv>(async (c, next) => {
  const header = c.req.header('Authorization') ?? '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : '';
  if (!token) return c.json({ error: 'missing_bearer' }, 401);
  const isDeletionRequest =
    c.req.method === 'DELETE' && new URL(c.req.url).pathname === '/api/me';
  let payload: AppJwtPayload;
  try {
    payload = await verify(token, c.env.APP_JWT_SECRET, 'HS256');
  } catch {
    // A deletion can commit while its success response is lost. The account
    // and renewal path are then gone, so a later receipt retry must be able to
    // finish local cleanup even if the original app JWT has expired. Accept an
    // expired bearer only when its signature/iat/nbf remain valid, this is the
    // exact DELETE endpoint, and the high-entropy key matches that subject's
    // already-claimed intent or committed receipt. It cannot authorize an
    // initial deletion or any other feature request.
    if (!isDeletionRequest) return c.json({ error: 'invalid_token' }, 401);
    try {
      payload = await verify(token, c.env.APP_JWT_SECRET, {
        alg: 'HS256',
        exp: false,
      });
      const principal = appJwtPrincipal(payload);
      const exp = payload.exp;
      const key = c.req.header('X-Account-Deletion-Key') ?? '';
      if (
        !principal ||
        typeof exp !== 'number' ||
        !Number.isFinite(exp) ||
        exp > Math.floor(Date.now() / 1000) ||
        !(await accountDeletionContinuationMatches(
          c.env.DB,
          principal.userId,
          key,
        ))
      ) {
        return c.json({ error: 'invalid_token' }, 401);
      }
    } catch {
      return c.json({ error: 'invalid_token' }, 401);
    }
  }
  const principal = appJwtPrincipal(payload);
  if (!principal) return c.json({ error: 'invalid_token' }, 401);
  c.set('userId', principal.userId);
  c.set('appAuthTime', principal.authTime);
  // App JWTs are stateless, so deleting an account cannot revoke one bearer
  // from a token table. Requiring the subject row on every authenticated call
  // makes all outstanding app tokens unusable immediately after DELETE /api/me
  // commits (and prevents rolling renewal from resurrecting the session).
  const livePrincipal = await c.env.DB
    .prepare(
      `SELECT 1 AS x FROM users
        WHERE id = ?1
          AND NOT EXISTS (
                SELECT 1 FROM account_deletion_intents
                 WHERE user_id = ?1
              )
          AND NOT EXISTS (
                SELECT 1 FROM account_deletion_receipts
                 WHERE user_id = ?1
              )`,
    )
    .bind(c.get('userId'))
    .first<{ x: number }>();
  if (!livePrincipal) {
    // Once deletion is claimed, a signed JWT is accepted only for an exact
    // continuation of that same DELETE. The service verifies the durable
    // high-entropy key; every other endpoint remains revoked immediately.
    if (!isDeletionRequest) return c.json({ error: 'invalid_token' }, 401);
    await next();
    return;
  }
  // The device sends its IANA timezone on EVERY authenticated request, so
  // "today" on the MCP side tracks the user across zones even when they only
  // do non-/state actions (logging sets) after travelling. Best-effort:
  // setUserTimezoneIfChanged only writes on change and ignores invalid values.
  const tz = c.req.header('X-Device-TZ');
  if (tz) await setUserTimezoneIfChanged(c.env.DB, c.get('userId'), tz);
  await next();
});

/**
 * @deprecated M2: the single-owner allowlist is no longer the auth gate.
 * `/auth/apple` now handles multi-user-with-invite-gating explicitly (see
 * `src/routes/auth.ts`) and does NOT call this helper. Retained as a
 * no-op-on-match / throw-on-mismatch utility for any future single-owner
 * path (and to keep the export stable for older callers in tree). New
 * code should not introduce uses.
 */
export function assertOwner(sub: string, ownerSub: string | undefined) {
  if (ownerSub && ownerSub !== sub) {
    throw new Error('not_owner');
  }
}
