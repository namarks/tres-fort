import { Hono } from 'hono';
import type { HonoEnv, User } from '../types';
import { issueAppJwt, verifyAppleToken } from '../auth';
import {
  claimOrCreateOwner,
  createUserAndRedeemInvite,
  isBootstrapClaimEligible,
  upsertUser,
} from '../db';

export const authRoutes = new Hono<HonoEnv>();

// POST /auth/apple  { identityToken, fullName?, invite_code? } -> { jwt, user }
//
// Open sign-in. Four paths, evaluated in order:
//
//  1. Existing user (apple_sub already in users). Just re-issue a JWT —
//     no invite needed.
//  2. Bootstrap (OWNER_APPLE_SUB allowlist). If OWNER_APPLE_SUB is set
//     AND the verified sub matches, claim/create the owner row (the
//     original single-user behavior, preserved).
//  3. Bootstrap (fresh install / unclaimed seed). If OWNER_APPLE_SUB is
//     UNSET AND `isBootstrapClaimEligible` returns true (empty users
//     table, or the sole row is the unclaimed MCP bootstrap sentinel),
//     this signer becomes the owner.
//  4. New sub. If an `invite_code` is supplied, atomically create the
//     user AND join the group (createUserAndRedeemInvite either fully
//     succeeds or rolls back the user row). Otherwise just create the
//     user with no group memberships — they can browse the app, log
//     their own workouts, and create/join groups later via the Group
//     tab.
//
// `assertOwner` is preserved in src/auth.ts for callers that still want
// the single-owner allowlist semantic (none in tree today; see comment).
//
// GROUPS remain invite-only: a user can only join a group via a valid
// invite code (POST /api/groups/join). Sign-in being open does NOT make
// groups public.
authRoutes.post('/apple', async (c) => {
  const body = await c.req.json<{
    identityToken?: string;
    fullName?: string;
    invite_code?: string;
  }>();
  if (!body.identityToken) return c.json({ error: 'missing_identityToken' }, 400);
  let claims;
  try {
    claims = await verifyAppleToken(body.identityToken, c.env.APPLE_BUNDLE_ID);
  } catch {
    return c.json({ error: 'apple_verification_failed' }, 401);
  }

  // Path 1: existing user — fast path, no invite required.
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

  // Path 2: OWNER_APPLE_SUB bootstrap (preserved). Claim the MCP-seeded
  // bootstrap row if present, else create.
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
  // Apple sub to sign in is the owner. Eligible when:
  //   (a) users table is empty (fresh deploy), OR
  //   (b) the only existing row is the MCP-seeded `mcp-owner` sentinel
  //       that hasn't been bound to a real Apple identity yet — Claude's
  //       MCP/OAuth path may have created that row before the first iOS
  //       sign-in, and claimOrCreateOwner is built to rebind it.
  // Without (b), the owner is silently locked out and falls through to
  // not_invited even though they're entitled to the bootstrap row.
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

  // Path 4: new Apple sub. Optional invite code auto-joins a group on
  // creation; without one the user is created memberships-empty and can
  // create / join groups from the iOS Group tab later.
  const code = typeof body.invite_code === 'string' ? body.invite_code.trim() : '';
  if (code) {
    const result = await createUserAndRedeemInvite(
      c.env.DB,
      claims.sub,
      claims.email,
      body.fullName ?? null,
      code,
    );
    if ('error' in result) {
      // Invite-validation failure with a code present: surface a distinct
      // error so iOS can prompt for a fresh code, instead of silently
      // dropping into the no-code path (which would create the user but
      // not join the group the inviter expected them to land in).
      return c.json({ error: 'invalid_invite' }, 403);
    }
    const jwt = await issueAppJwt(result.user.id, c.env.APP_JWT_SECRET);
    return c.json({ jwt, user: result.user, group_id: result.group_id });
  }
  // No invite — open sign-in. Plain user creation, no memberships.
  // upsertUser is safe here because Path 1 already returned for known subs:
  // we reach here only with an unknown apple_sub, so this INSERTs.
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
