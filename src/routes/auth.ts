import { Hono } from 'hono';
import type { HonoEnv, User } from '../types';
import { issueAppJwt, verifyAppleToken } from '../auth';
import {
  claimOrCreateOwner,
  isBootstrapClaimEligible,
  upsertUser,
} from '../db';

export const authRoutes = new Hono<HonoEnv>();

// POST /auth/apple  { identityToken, fullName? } -> { jwt, user }
//
// Open sign-in. Four paths, evaluated in order:
//
//  1. Existing user (apple_sub already in users). Re-issue a JWT.
//  2. OWNER_APPLE_SUB allowlist bootstrap. If OWNER_APPLE_SUB is set
//     AND the verified sub matches, claim/create the owner row.
//  3. Fresh-install / unclaimed-seed bootstrap. If OWNER_APPLE_SUB is
//     UNSET AND `isBootstrapClaimEligible` returns true, this signer
//     becomes the owner (claims the MCP bootstrap row if present).
//  4. Any other new sub. Plain user creation, zero memberships. The user
//     can create or join groups from the iOS Group tab later via
//     POST /api/groups + POST /api/groups/join.
//
// GROUPS REMAIN INVITE-ONLY: a user joins a group exclusively via a
// valid invite code on POST /api/groups/join. Sign-in being open does
// NOT make groups public. The previous "supply invite_code on /auth/apple
// to auto-join in one step" shortcut was removed — it created an
// existing-user vs new-user asymmetry (a later sign-in by an established
// user with a code would be silently ignored on the existing-user fast
// path) and the "in-app join" flow covers the same intent without that
// trap.
authRoutes.post('/apple', async (c) => {
  const body = await c.req.json<{
    identityToken?: string;
    fullName?: string;
  }>();
  if (!body.identityToken) return c.json({ error: 'missing_identityToken' }, 400);
  let claims;
  try {
    claims = await verifyAppleToken(body.identityToken, c.env.APPLE_BUNDLE_ID);
  } catch {
    return c.json({ error: 'apple_verification_failed' }, 401);
  }

  // Path 1: existing user — fast path.
  const existing = await c.env.DB
    .prepare('SELECT * FROM users WHERE apple_sub = ?1')
    .bind(claims.sub)
    .first<User>();
  if (existing) {
    const jwt = await issueAppJwt(existing.id, c.env.APP_JWT_SECRET);
    return c.json({ jwt, user: existing });
  }

  const ownerSub = c.env.OWNER_APPLE_SUB;
  const ownerSubMatches = !!ownerSub && ownerSub === claims.sub;
  const ownerSubLocked = !!ownerSub;

  // Path 2: OWNER_APPLE_SUB bootstrap.
  if (ownerSubMatches) {
    const user = await claimOrCreateOwner(
      c.env.DB,
      claims.sub,
      claims.email,
      body.fullName ?? null,
      ownerSubLocked,
    );
    const jwt = await issueAppJwt(user.id, c.env.APP_JWT_SECRET);
    return c.json({ jwt, user });
  }

  // Path 3: bootstrap / claim. With OWNER_APPLE_SUB unset, the first
  // Apple sub claims the owner row. Eligible when (a) users table is
  // empty OR (b) the only existing row is the MCP-seeded bootstrap
  // sentinel waiting to be bound to a real Apple identity.
  if (!ownerSubLocked && (await isBootstrapClaimEligible(c.env.DB))) {
    const user = await claimOrCreateOwner(
      c.env.DB,
      claims.sub,
      claims.email,
      body.fullName ?? null,
      false,
    );
    const jwt = await issueAppJwt(user.id, c.env.APP_JWT_SECRET);
    return c.json({ jwt, user });
  }

  // Path 4: any other new Apple sub. Open sign-in, zero memberships.
  // upsertUser is safe here because Path 1 already returned for known
  // subs: we reach here only with an unknown apple_sub, so this INSERTs.
  const user = await upsertUser(c.env.DB, claims.sub, claims.email, body.fullName ?? null);
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
