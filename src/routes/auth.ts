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
// M2 invite-gated sign-in. Four paths, evaluated in order:
//
//  1. Existing user (apple_sub already in users). Just re-issue a JWT —
//     no invite needed, regardless of OWNER_APPLE_SUB.
//  2. Bootstrap (OWNER_APPLE_SUB allowlist). If OWNER_APPLE_SUB is set
//     AND the verified sub matches, claim/create the owner row (the
//     original single-user behavior, preserved). Other subs are rejected
//     here UNLESS they have a valid invite (path 4).
//  3. Bootstrap (fresh install). If OWNER_APPLE_SUB is UNSET AND the
//     users table is empty, the very first signer becomes the owner.
//     This is the "I just deployed, no MCP bootstrap row exists" path.
//  4. Invite. A new sub with a valid `invite_code` is created atomically
//     alongside redemption — createUserAndRedeemInvite either fully
//     succeeds (user + membership + audit) or rolls back the user row.
//
// Anything else → 403 not_invited. Critically: assertOwner is no longer
// called here. With invites as the gate, a sub mismatching OWNER_APPLE_SUB
// is not automatically forbidden — they just need a valid invite.
// `assertOwner` is preserved in src/auth.ts for callers that still want
// the single-owner allowlist semantic (none in tree today; see comment).
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

  // Path 4: invite. New Apple sub presenting a code.
  const code = typeof body.invite_code === 'string' ? body.invite_code.trim() : '';
  if (!code) {
    return c.json({ error: 'not_invited' }, 403);
  }
  const result = await createUserAndRedeemInvite(
    c.env.DB,
    claims.sub,
    claims.email,
    body.fullName ?? null,
    code,
  );
  if ('error' in result) {
    // Any invite-validation failure surfaces as not_invited at the auth
    // layer — we never tell an unauthenticated caller WHICH way the code
    // was bad (used vs expired vs unknown). The iOS client treats all
    // three as "ask for a fresh code."
    return c.json({ error: 'not_invited' }, 403);
  }
  const jwt = await issueAppJwt(result.user.id, c.env.APP_JWT_SECRET);
  return c.json({ jwt, user: result.user, group_id: result.group_id });
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
