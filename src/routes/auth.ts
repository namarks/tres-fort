import { Hono } from 'hono';
import type { HonoEnv, PublicUser, User } from '../types';
import {
  appleProviderConfig,
  exchangeAndVerifyAppleAuthorizationCode,
  hasAppleProviderSigningConfig,
  type AppleAuthorizationGrant,
  type AppleProviderConfig,
} from '../apple';
import {
  APP_JWT_MAX_SESSION_SECONDS,
  issueAppJwt,
  requireAppJwt,
  verifyAppleToken,
} from '../auth';
import {
  acknowledgeAppleGrantExchange,
  beginAppleGrantExchange,
  claimOrCreateOwner,
  finishAppleGrantExchange,
  isAccountDeletionInProgress,
  isBootstrapClaimEligible,
  isDeletedOwnerAppleSub,
  isOwnerDeletionTombstoned,
  markAppleGrantExchangeUncertain,
  redeemInvite,
  upsertUserUnlessDeletedOwner,
} from '../db';

type VerifiedAppleIdentity = { sub: string; email: string | null };

export interface AuthRouteDependencies {
  verifyAppleIdentityToken: (
    identityToken: string,
    bundleId: string,
  ) => Promise<VerifiedAppleIdentity>;
  exchangeAppleAuthorizationCode: (
    config: AppleProviderConfig,
    authorizationCode: string,
    expectedSubject: string,
    verifyIdentityToken: (
      identityToken: string,
    ) => Promise<VerifiedAppleIdentity>,
  ) => Promise<AppleAuthorizationGrant>;
  beginAppleGrantExchange: (
    db: D1Database,
    userId: string,
    reservationId: string,
  ) => Promise<boolean>;
  acknowledgeAppleGrantExchange: (
    db: D1Database,
    userId: string,
    reservationId: string,
  ) => Promise<boolean>;
  finishAppleGrantExchange: (
    db: D1Database,
    userId: string,
    reservationId: string,
    refreshToken: string,
  ) => Promise<boolean>;
  markAppleGrantExchangeUncertain: (
    db: D1Database,
    userId: string,
    reservationId: string,
  ) => Promise<boolean>;
  issueAppJwt: typeof issueAppJwt;
  redeemInvite: typeof redeemInvite;
}

const defaultDependencies: AuthRouteDependencies = {
  verifyAppleIdentityToken: verifyAppleToken,
  exchangeAppleAuthorizationCode: exchangeAndVerifyAppleAuthorizationCode,
  beginAppleGrantExchange,
  acknowledgeAppleGrantExchange,
  finishAppleGrantExchange,
  markAppleGrantExchangeUncertain,
  issueAppJwt,
  redeemInvite,
};

function publicUser(user: User): PublicUser {
  return {
    id: user.id,
    email: user.email,
    display_name: user.display_name,
  };
}

// POST /auth/apple  { identityToken, authorizationCode?, fullName?, invite_code? }
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
export function createAuthRoutes(
  overrides: Partial<AuthRouteDependencies> = {},
): Hono<HonoEnv> {
  const dependencies: AuthRouteDependencies = {
    ...defaultDependencies,
    ...overrides,
  };
  const routes = new Hono<HonoEnv>();

  routes.post('/apple', async (c) => {
    const body = await c.req.json<{
      identityToken?: string;
      authorizationCode?: unknown;
      fullName?: string;
      invite_code?: string;
    }>();
    if (!body.identityToken) {
      return c.json({ error: 'missing_identityToken' }, 400);
    }
    let claims;
    try {
      claims = await dependencies.verifyAppleIdentityToken(
        body.identityToken,
        c.env.APPLE_BUNDLE_ID,
      );
    } catch {
      return c.json({ error: 'apple_verification_failed' }, 401);
    }

    // A deliberately deleted owner is suppressed until an administrator clears
    // the D1 tombstone. Do this before every create/claim path so neither Apple
    // sign-in nor a configured OWNER_APPLE_SUB can silently recreate it.
    if (await isDeletedOwnerAppleSub(c.env.DB, claims.sub)) {
      return c.json({ error: 'owner_account_deleted' }, 410);
    }

    // Resolve an already-known principal without mutating it so a claimed
    // deletion can reject both legacy and current clients before any provider
    // request or new bearer issuance.
    const existing = await c.env.DB
      .prepare('SELECT * FROM users WHERE apple_sub = ?1')
      .bind(claims.sub)
      .first<User>();
    if (
      existing &&
      (await isAccountDeletionInProgress(c.env.DB, existing.id))
    ) {
      return c.json({ error: 'account_deletion_in_progress' }, 409);
    }

    // Native clients send Apple's single-use authorization code so this Worker
    // can retain a caller-scoped refresh token for later account-deletion
    // revocation. Omission remains valid for already-shipped legacy clients.
    // Reject malformed input and missing owner-managed signing configuration
    // before claiming a durable exchange reservation.
    let authorizationCode: string | null = null;
    let providerConfig: AppleProviderConfig | null = null;
    if (body.authorizationCode !== undefined) {
      if (
        typeof body.authorizationCode !== 'string' ||
        body.authorizationCode.trim().length === 0
      ) {
        return c.json({ error: 'apple_authorization_failed' }, 401);
      }
      providerConfig = appleProviderConfig(c.env);
      if (!hasAppleProviderSigningConfig(providerConfig)) {
        return c.json({ error: 'apple_authorization_failed' }, 401);
      }
      authorizationCode = body.authorizationCode;
    }

    let user: User | null = existing;
    let redeemLegacyInvite = false;

    // Path 1: existing user — fast path.
    const ownerSub = c.env.OWNER_APPLE_SUB;
    const ownerSubMatches = !!ownerSub && ownerSub === claims.sub;
    const ownerSubLocked = !!ownerSub;

    // Path 2: OWNER_APPLE_SUB bootstrap.
    if (!user && ownerSubMatches) {
      user = await claimOrCreateOwner(
        c.env.DB,
        claims.sub,
        claims.email,
        body.fullName ?? null,
        ownerSubLocked,
      );
      if (!user) return c.json({ error: 'owner_account_deleted' }, 410);
    }

    // Path 3: bootstrap / claim. With OWNER_APPLE_SUB unset, the first
    // Apple sub claims the owner row. Eligible when (a) users table is
    // empty OR (b) the only existing row is the MCP-seeded bootstrap
    // sentinel waiting to be bound to a real Apple identity.
    if (
      !user &&
      !ownerSubLocked &&
      (await isBootstrapClaimEligible(c.env.DB))
    ) {
      user = await claimOrCreateOwner(
        c.env.DB,
        claims.sub,
        claims.email,
        body.fullName ?? null,
        false,
      );
      if (!user) return c.json({ error: 'owner_account_deleted' }, 410);
    }

    // Path 4: any other new Apple sub. Open sign-in, zero memberships by
    // default. Keep the deletion-tombstone comparison inside the INSERT so an
    // owner deletion racing this request cannot be followed by recreation from
    // the stale pre-deletion check above.
    if (!user) {
      user = await upsertUserUnlessDeletedOwner(
        c.env.DB,
        claims.sub,
        claims.email,
        body.fullName ?? null,
      );
      if (!user) return c.json({ error: 'owner_account_deleted' }, 410);
      redeemLegacyInvite = true;
    }

    // Once deletion owns this principal, neither a legacy sign-in nor a fresh
    // Apple grant may mint another bearer. Supplied-code storage has its own
    // transactional guard as defense in depth, but this explicit gate also
    // closes the code-absent compatibility path.
    if (await isAccountDeletionInProgress(c.env.DB, user.id)) {
      return c.json({ error: 'account_deletion_in_progress' }, 409);
    }

    if (authorizationCode && providerConfig) {
      // Serialize the D1 -> Apple -> D1 gap before the request leaves D1. A
      // deletion intent, receipt, or another fresh exchange makes begin return
      // false, so none of those races can mint a new untracked Apple grant.
      const reservationId = crypto.randomUUID();
      let began = false;
      try {
        began = await dependencies.beginAppleGrantExchange(
          c.env.DB,
          user.id,
          reservationId,
        );
      } catch {
        // A D1 transport failure can be ambiguous. Marking this exact random
        // reservation is a safe no-op if begin never committed, and prevents a
        // committed reservation from being mistaken for clean provider state.
        try {
          await dependencies.markAppleGrantExchangeUncertain(
            c.env.DB,
            user.id,
            reservationId,
          );
        } catch {
          // A still-active reservation remains fail-closed and ages into
          // sticky uncertainty; never disclose storage details to the client.
        }
        return c.json({ error: 'apple_authorization_failed' }, 401);
      }
      if (!began) {
        return c.json({ error: 'apple_authorization_failed' }, 401);
      }

      const markUncertain = async (): Promise<void> => {
        try {
          await dependencies.markAppleGrantExchangeUncertain(
            c.env.DB,
            user.id,
            reservationId,
          );
        } catch {
          // A still-active reservation remains fail-closed and becomes stale
          // uncertainty after the bounded reservation window.
        }
      };

      let authorizationGrant: AppleAuthorizationGrant;
      try {
        // Exchange the exact opaque code, re-verify Apple's returned id_token,
        // and bind it to the initially verified subject.
        authorizationGrant =
          await dependencies.exchangeAppleAuthorizationCode(
            providerConfig,
            authorizationCode,
            claims.sub,
            (identityToken) =>
              dependencies.verifyAppleIdentityToken(
                identityToken,
                c.env.APPLE_BUNDLE_ID,
              ),
          );
      } catch {
        await markUncertain();
        return c.json({ error: 'apple_authorization_failed' }, 401);
      }

      try {
        const finished = await dependencies.finishAppleGrantExchange(
          c.env.DB,
          user.id,
          reservationId,
          authorizationGrant.refreshToken,
        );
        if (!finished) {
          await markUncertain();
          return c.json({ error: 'apple_authorization_failed' }, 401);
        }
      } catch {
        await markUncertain();
        return c.json({ error: 'apple_authorization_failed' }, 401);
      }

      // Storage is now known to have committed. Clear the still-present exact
      // reservation as a second phase. An acknowledgement failure does not
      // invalidate authentication or lose the known token: mark the reservation
      // uncertain when it still exists, then continue. If acknowledgement
      // committed but its response was lost, the exact marker is already gone
      // and the stored refresh token remains sufficient for revocation.
      try {
        const acknowledged =
          await dependencies.acknowledgeAppleGrantExchange(
            c.env.DB,
            user.id,
            reservationId,
          );
        if (!acknowledged) await markUncertain();
      } catch {
        await markUncertain();
      }
    }

    const jwt = await dependencies.issueAppJwt(user.id, c.env.APP_JWT_SECRET);
    // Back-compat shim for pre-open-signin clients (see file header). If
    // a code was posted, best-effort redeem it against the just-created
    // user. We do NOT fail sign-in on a bad code — the legacy UX was
    // "type code → sign in → land in group"; failing the whole sign-in
    // because the code was typo'd would be more hostile than the worst-
    // case quiet success of "signed in but not in a group" (which the
    // in-app Group tab's Join flow resolves).
    const code =
      typeof body.invite_code === 'string' ? body.invite_code.trim() : '';
    if (redeemLegacyInvite && code) {
      const r = await dependencies.redeemInvite(c.env.DB, code, user.id);
      if ('ok' in r) {
        return c.json({ jwt, user: publicUser(user), group_id: r.group_id });
      }
    }
    return c.json({ jwt, user: publicUser(user) });
  });

  // POST /auth/renew -> { jwt }
  //
  // The app renews while its current app JWT is still valid. Renewal preserves
  // the original authentication time and stops at an absolute ceiling, so a
  // copied bearer cannot extend itself forever. Sign in with Apple starts a new
  // session after expiry, revocation, or that ceiling.
  routes.post('/renew', requireAppJwt, async (c) => {
    const nowSec = Math.floor(Date.now() / 1000);
    const authTimeSec = c.get('appAuthTime');
    if (nowSec >= authTimeSec + APP_JWT_MAX_SESSION_SECONDS) {
      return c.json({ error: 'reauthentication_required' }, 401);
    }
    const jwt = await dependencies.issueAppJwt(
      c.get('userId'),
      c.env.APP_JWT_SECRET,
      {
        nowSeconds: nowSec,
        authTimeSeconds: authTimeSec,
      },
    );
    return c.json({ jwt });
  });

  // POST /auth/dev  { secret }  -> { jwt, user }
  // Enabled ONLY when DEV_AUTH_SECRET is set (local + integration tests).
  routes.post('/dev', async (c) => {
    if (!c.env.DEV_AUTH_SECRET) {
      return c.json({ error: 'dev_auth_disabled' }, 404);
    }
    const body = await c.req
      .json<{ secret?: string }>()
      .catch(() => ({}) as { secret?: string });
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
    if (await isAccountDeletionInProgress(c.env.DB, user.id)) {
      return c.json({ error: 'account_deletion_in_progress' }, 409);
    }
    const jwt = await dependencies.issueAppJwt(user.id, c.env.APP_JWT_SECRET);
    return c.json({ jwt, user: publicUser(user) });
  });

  return routes;
}

export const authRoutes = createAuthRoutes();
