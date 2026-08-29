import { Hono } from 'hono';
import type { HonoEnv, User } from '../types';
import { issueAppJwt, requireAppJwt, verifyAppleToken } from '../auth';
import {
  claimOrCreateOwner,
  isBootstrapClaimEligible,
  isDeletedOwnerAppleSub,
  isOwnerDeletionTombstoned,
  redeemInvite,
  upsertUserUnlessDeletedOwner,
} from '../db';

export const authRoutes = new Hono<HonoEnv>();

// POST /auth/apple  { identityToken, fullName?, invite_code? }
//   -> { jwt, user, group_id? }
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
// NOT make groups public.
//
// `invite_code` BACK-COMPAT (Codex PR#38 P2): the open-signin iOS UI
// no longer renders an invite-code field on sign-in, but build 12 and
// earlier (already shipped to TestFlight) still POST `invite_code`
// from a "Have an invite code?" reveal. To avoid those clients landing
// "signed in but never joined" after this Worker deploys, Path 4 will
// also redeem a supplied code best-effort against the just-created
// user. Success returns `group_id` (which legacy clients' AuthResponse
// decoder picks up and uses to pre-select the group). Failure does
// NOT block sign-in — the user is signed in normally and can paste a
// fresh code from the in-app Group tab. New clients send no code and
// the redemption step is a no-op for them.
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

  // A deliberately deleted owner is suppressed until an administrator clears
  // the D1 tombstone. Do this before every create/claim path so neither Apple
  // sign-in nor a configured OWNER_APPLE_SUB can silently recreate it.
  if (await isDeletedOwnerAppleSub(c.env.DB, claims.sub)) {
    return c.json({ error: 'owner_account_deleted' }, 410);
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
    if (!user) return c.json({ error: 'owner_account_deleted' }, 410);
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
    if (!user) return c.json({ error: 'owner_account_deleted' }, 410);
    const jwt = await issueAppJwt(user.id, c.env.APP_JWT_SECRET);
    return c.json({ jwt, user });
  }

  // Path 4: any other new Apple sub. Open sign-in, zero memberships by
  // default. Keep the deletion-tombstone comparison inside the INSERT so an
  // owner deletion racing this request cannot be followed by recreation from
  // the stale pre-deletion check above.
  const user = await upsertUserUnlessDeletedOwner(
    c.env.DB,
    claims.sub,
    claims.email,
    body.fullName ?? null,
  );
  if (!user) return c.json({ error: 'owner_account_deleted' }, 410);
  const jwt = await issueAppJwt(user.id, c.env.APP_JWT_SECRET);
  // Back-compat shim for pre-open-signin clients (see file header). If
  // a code was posted, best-effort redeem it against the just-created
  // user. We do NOT fail sign-in on a bad code — the legacy UX was
  // "type code → sign in → land in group"; failing the whole sign-in
  // because the code was typo'd would be more hostile than the worst-
  // case quiet success of "signed in but not in a group" (which the
  // in-app Group tab's Join flow resolves).
  const code = typeof body.invite_code === 'string' ? body.invite_code.trim() : '';
  if (code) {
    const r = await redeemInvite(c.env.DB, code, user.id);
    if ('ok' in r) {
      return c.json({ jwt, user, group_id: r.group_id });
    }
  }
  return c.json({ jwt, user });
});

// POST /auth/renew -> { jwt }
//
// The app renews while its current app JWT is still valid. This deliberately
// remains a rolling stateless session rather than adding refresh-token
// storage: Sign in with Apple is still the recovery path after expiry or
// revocation.
authRoutes.post('/renew', requireAppJwt, async (c) => {
  const jwt = await issueAppJwt(c.get('userId'), c.env.APP_JWT_SECRET);
  return c.json({ jwt });
});

// POST /auth/dev  { secret }  -> { jwt, user }
// Enabled ONLY when DEV_AUTH_SECRET is set (local + integration tests).
authRoutes.post('/dev', async (c) => {
  if (!c.env.DEV_AUTH_SECRET) return c.json({ error: 'dev_auth_disabled' }, 404);
  const body = await c.req.json<{ secret?: string }>().catch(() => ({}) as { secret?: string });
  if (body.secret !== c.env.DEV_AUTH_SECRET) {
    return c.json({ error: 'bad_dev_secret' }, 401);
  }
  // This local/CI-only backdoor always represents the distinguished owner,
  // even when its synthetic sub differs from the MCP bootstrap sentinel.
  if (await isOwnerDeletionTombstoned(c.env.DB)) {
    return c.json({ error: 'owner_account_deleted' }, 410);
  }
  const sub = c.env.OWNER_APPLE_SUB ?? 'dev-owner';
  const user = await claimOrCreateOwner(
    c.env.DB,
    sub,
    'dev@local',
    'Dev Owner',
    true,
  );
  if (!user) return c.json({ error: 'owner_account_deleted' }, 410);
  const jwt = await issueAppJwt(user.id, c.env.APP_JWT_SECRET);
  return c.json({ jwt, user });
});
