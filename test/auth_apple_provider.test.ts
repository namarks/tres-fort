import { applyD1Migrations, env } from 'cloudflare:test';
import { beforeAll, describe, expect, it, vi } from 'vitest';
import type { AppleAuthorizationGrant } from '../src/apple';
import {
  acknowledgeAppleGrantExchange,
  beginAppleGrantExchange,
  deleteUserAccount,
  finishAppleGrantExchange,
  markAppleGrantExchangeUncertain,
} from '../src/db';
import {
  createAuthRoutes,
  type AuthRouteDependencies,
} from '../src/routes/auth';
import type { Env } from '../src/types';

function routeEnv(overrides: Partial<Env> = {}): Env {
  return {
    DB: env.DB,
    APPLE_BUNDLE_ID: 'com.example.tresfort',
    APPLE_TEAM_ID: 'TEAM123456',
    APPLE_KEY_ID: 'KEY1234567',
    APPLE_PRIVATE_KEY: 'test-only-injected-provider-does-not-read-this',
    APP_JWT_SECRET: 'route-test-jwt-secret',
    DEV_AUTH_SECRET: 'route-test-dev-secret',
    // Keep fresh test subjects on Path 4 regardless of other test data.
    OWNER_APPLE_SUB: 'configured-owner-that-never-matches',
    ...overrides,
  };
}

async function post(
  routes: ReturnType<typeof createAuthRoutes>,
  path: '/apple' | '/dev',
  body: Record<string, unknown>,
  bindings = routeEnv(),
): Promise<Response> {
  return routes.request(
    `https://lift-coach.test${path}`,
    {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
    },
    bindings,
  );
}

function validGrant(refreshToken = 'caller-refresh'): AppleAuthorizationGrant {
  return {
    refreshToken,
    identityToken: 'provider-returned-identity-token',
  };
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

describe('/auth/apple provider grant wiring', () => {
  it('keeps authorizationCode optional for legacy clients and returns only PublicUser', async () => {
    const sub = `legacy-code-optional-${crypto.randomUUID()}`;
    const exchange = vi.fn<AuthRouteDependencies['exchangeAppleAuthorizationCode']>();
    const begin = vi.fn<AuthRouteDependencies['beginAppleGrantExchange']>();
    const finish = vi.fn<AuthRouteDependencies['finishAppleGrantExchange']>();
    const mark = vi.fn<
      AuthRouteDependencies['markAppleGrantExchangeUncertain']
    >();
    const issue = vi.fn<AuthRouteDependencies['issueAppJwt']>(async () =>
      'legacy-jwt',
    );
    const routes = createAuthRoutes({
      verifyAppleIdentityToken: async () => ({
        sub,
        email: 'legacy@example.test',
      }),
      exchangeAppleAuthorizationCode: exchange,
      beginAppleGrantExchange: begin,
      finishAppleGrantExchange: finish,
      markAppleGrantExchangeUncertain: mark,
      issueAppJwt: issue,
    });

    const response = await post(routes, '/apple', {
      identityToken: 'initial-identity-token',
      fullName: 'Legacy Client',
    });

    expect(response.status).toBe(200);
    const payload = (await response.json()) as Record<string, unknown>;
    expect(payload.jwt).toBe('legacy-jwt');
    expect(payload.user).toEqual({
      id: expect.any(String),
      email: 'legacy@example.test',
      display_name: 'Legacy Client',
    });
    expect(Object.keys(payload.user as object).sort()).toEqual([
      'display_name',
      'email',
      'id',
    ]);

    const userId = (payload.user as { id: string }).id;
    await env.DB
      .prepare(
        `UPDATE users
            SET intervals_api_key = ?2,
                intervals_oauth_access_token = ?3,
                mcp_passphrase_hash = ?4,
                mcp_passphrase_salt = ?5
          WHERE id = ?1`,
      )
      .bind(
        userId,
        'private-intervals-key',
        'private-intervals-oauth-token',
        'private-mcp-hash',
        'private-mcp-salt',
      )
      .run();
    const repeat = await post(routes, '/apple', {
      identityToken: 'repeat-identity-token',
    });
    expect(repeat.status).toBe(200);
    const repeatPayload = (await repeat.json()) as Record<string, unknown>;
    expect(repeatPayload.user).toEqual({
      id: userId,
      email: 'legacy@example.test',
      display_name: 'Legacy Client',
    });
    expect(JSON.stringify(repeatPayload)).not.toContain('private-');
    expect(exchange).not.toHaveBeenCalled();
    expect(begin).not.toHaveBeenCalled();
    expect(finish).not.toHaveBeenCalled();
    expect(mark).not.toHaveBeenCalled();
    expect(issue).toHaveBeenCalledTimes(2);
  });

  it('subject-binds the exchanged token, stores only the resolved caller refresh token, then issues JWT', async () => {
    const sub = `provider-happy-${crypto.randomUUID()}`;
    const refreshToken = `refresh-${crypto.randomUUID()}`;
    const events: string[] = [];
    const verifyIdentity = vi.fn<
      AuthRouteDependencies['verifyAppleIdentityToken']
    >(async (token) => {
      events.push(
        token === 'initial-identity-token'
          ? 'verify-initial'
          : 'verify-provider-return',
      );
      return { sub, email: 'provider@example.test' };
    });
    const exchange = vi.fn<
      AuthRouteDependencies['exchangeAppleAuthorizationCode']
    >(async (config, code, expectedSubject, verifyReturnedIdentity) => {
      events.push('exchange');
      expect(config).toMatchObject({
        clientId: 'com.example.tresfort',
        teamId: 'TEAM123456',
        keyId: 'KEY1234567',
      });
      expect(code).toBe('opaque-single-use-code');
      expect(expectedSubject).toBe(sub);
      await expect(
        verifyReturnedIdentity('provider-returned-identity-token'),
      ).resolves.toMatchObject({ sub });
      return validGrant(refreshToken);
    });
    let activeReservationId: string | null = null;
    const begin = vi.fn<
      AuthRouteDependencies['beginAppleGrantExchange']
    >(async (db, userId, reservationId) => {
      events.push('begin');
      activeReservationId = reservationId;
      return beginAppleGrantExchange(db, userId, reservationId);
    });
    const finish = vi.fn<
      AuthRouteDependencies['finishAppleGrantExchange']
    >(async (db, userId, reservationId, token) => {
      events.push('finish');
      expect(reservationId).toBe(activeReservationId);
      return finishAppleGrantExchange(db, userId, reservationId, token);
    });
    const acknowledge = vi.fn<
      AuthRouteDependencies['acknowledgeAppleGrantExchange']
    >(async (db, userId, reservationId) => {
      events.push('acknowledge');
      return acknowledgeAppleGrantExchange(db, userId, reservationId);
    });
    const issue = vi.fn<AuthRouteDependencies['issueAppJwt']>(async () => {
      events.push('issue');
      return 'provider-jwt';
    });
    const redeem = vi.fn<AuthRouteDependencies['redeemInvite']>(async () => {
      events.push('redeem');
      return { error: 'unknown' };
    });
    const routes = createAuthRoutes({
      verifyAppleIdentityToken: verifyIdentity,
      exchangeAppleAuthorizationCode: exchange,
      beginAppleGrantExchange: begin,
      finishAppleGrantExchange: finish,
      acknowledgeAppleGrantExchange: acknowledge,
      issueAppJwt: issue,
      redeemInvite: redeem,
    });

    const response = await post(routes, '/apple', {
      identityToken: 'initial-identity-token',
      authorizationCode: 'opaque-single-use-code',
      fullName: 'Provider User',
      invite_code: 'LEGACY-INVITE',
    });

    expect(response.status).toBe(200);
    const payload = (await response.json()) as {
      jwt: string;
      user: { id: string; email: string | null; display_name: string | null };
    };
    expect(payload).toEqual({
      jwt: 'provider-jwt',
      user: {
        id: expect.any(String),
        email: 'provider@example.test',
        display_name: 'Provider User',
      },
    });
    expect(events).toEqual([
      'verify-initial',
      'begin',
      'exchange',
      'verify-provider-return',
      'finish',
      'acknowledge',
      'issue',
      'redeem',
    ]);
    expect(activeReservationId).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
    );
    expect(
      await env.DB
        .prepare(
          'SELECT user_id, refresh_token FROM apple_refresh_tokens WHERE user_id = ?1',
        )
        .bind(payload.user.id)
        .first<{ user_id: string; refresh_token: string }>(),
    ).toEqual({ user_id: payload.user.id, refresh_token: refreshToken });
    expect(
      await env.DB
        .prepare(
          'SELECT reservation_id FROM apple_grant_exchange_state WHERE user_id = ?1',
        )
        .bind(payload.user.id)
        .first(),
    ).toBeNull();
    expect(JSON.stringify(payload)).not.toContain(refreshToken);
    expect(JSON.stringify(payload)).not.toContain('opaque-single-use-code');
  });

  it.each(['before_commit', 'after_commit'] as const)(
    'keeps authentication and deletion fail-closed when acknowledgement throws %s',
    async (failure) => {
      const sub = `provider-ack-${failure}-${crypto.randomUUID()}`;
      const issue = vi.fn<AuthRouteDependencies['issueAppJwt']>(async () =>
        'acknowledged-storage-jwt',
      );
      const acknowledge = vi.fn<
        AuthRouteDependencies['acknowledgeAppleGrantExchange']
      >(async (db, userId, reservationId) => {
        if (failure === 'after_commit') {
          expect(
            await acknowledgeAppleGrantExchange(db, userId, reservationId),
          ).toBe(true);
        }
        throw new Error('ambiguous acknowledgement');
      });
      const routes = createAuthRoutes({
        verifyAppleIdentityToken: async () => ({ sub, email: null }),
        exchangeAppleAuthorizationCode: async () =>
          validGrant(`ack-refresh-${failure}`),
        acknowledgeAppleGrantExchange: acknowledge,
        issueAppJwt: issue,
      });

      const response = await post(routes, '/apple', {
        identityToken: 'initial-identity-token',
        authorizationCode: 'single-use-code',
      });
      expect(response.status).toBe(200);
      const payload = (await response.json()) as {
        jwt: string;
        user: { id: string };
      };
      expect(payload.jwt).toBe('acknowledged-storage-jwt');
      expect(issue).toHaveBeenCalledOnce();
      expect(
        await env.DB
          .prepare(
            'SELECT refresh_token FROM apple_refresh_tokens WHERE user_id = ?1',
          )
          .bind(payload.user.id)
          .first(),
      ).toEqual({ refresh_token: `ack-refresh-${failure}` });

      const state = await env.DB
        .prepare(
          `SELECT reservation_id, active_since, revocation_uncertain
             FROM apple_grant_exchange_state WHERE user_id = ?1`,
        )
        .bind(payload.user.id)
        .first();
      if (failure === 'before_commit') {
        expect(state).toEqual({
          reservation_id: null,
          active_since: null,
          revocation_uncertain: 1,
        });
      } else {
        expect(state).toBeNull();
      }

      let providerCalls = 0;
      const deleted = await deleteUserAccount(
        env.DB,
        payload.user.id,
        'configured-owner-that-never-matches',
        crypto.randomUUID(),
        {
          appleConfig: {
            clientId: 'com.example.tresfort',
            teamId: 'TEAM123456',
            keyId: 'KEY1234567',
            privateKey: 'not-used-by-injected-revoker',
          },
          revokeAppleToken: async () => {
            providerCalls += 1;
          },
        },
      );
      expect(deleted).toMatchObject({
        ok: true,
        apple_revocation:
          failure === 'before_commit' ? 'manual_required' : 'revoked',
      });
      expect(providerCalls).toBe(failure === 'before_commit' ? 0 : 1);
    },
  );

  it.each(['initial_identity', 'signing_config'] as const)(
    'fails %s validation before creating an exchange reservation',
    async (failure) => {
      const sub = `provider-pre-reservation-${failure}-${crypto.randomUUID()}`;
      const begin = vi.fn<AuthRouteDependencies['beginAppleGrantExchange']>();
      const exchange = vi.fn<
        AuthRouteDependencies['exchangeAppleAuthorizationCode']
      >();
      const routes = createAuthRoutes({
        verifyAppleIdentityToken: async () => {
          if (failure === 'initial_identity') {
            throw new Error('invalid initial identity');
          }
          return { sub, email: null };
        },
        beginAppleGrantExchange: begin,
        exchangeAppleAuthorizationCode: exchange,
      });

      const response = await post(
        routes,
        '/apple',
        {
          identityToken: 'initial-identity-token',
          authorizationCode: 'single-use-code',
        },
        failure === 'signing_config'
          ? routeEnv({ APPLE_PRIVATE_KEY: undefined })
          : routeEnv(),
      );

      expect(response.status).toBe(401);
      expect(await response.json()).toEqual({
        error:
          failure === 'initial_identity'
            ? 'apple_verification_failed'
            : 'apple_authorization_failed',
      });
      expect(begin).not.toHaveBeenCalled();
      expect(exchange).not.toHaveBeenCalled();
    },
  );

  it.each(['rejected', 'threw'] as const)(
    'fails before provider, JWT, or invite when reservation begin is %s',
    async (failure) => {
      const sub = `provider-begin-${failure}-${crypto.randomUUID()}`;
      let reservationId: string | null = null;
      const begin = vi.fn<
        AuthRouteDependencies['beginAppleGrantExchange']
      >(async (_db, _userId, candidate) => {
        reservationId = candidate;
        if (failure === 'threw') throw new Error('ambiguous D1 begin');
        return false;
      });
      const mark = vi.fn<
        AuthRouteDependencies['markAppleGrantExchangeUncertain']
      >(async (_db, _userId, candidate) => {
        expect(candidate).toBe(reservationId);
        return true;
      });
      const exchange = vi.fn<
        AuthRouteDependencies['exchangeAppleAuthorizationCode']
      >();
      const finish = vi.fn<
        AuthRouteDependencies['finishAppleGrantExchange']
      >();
      const issue = vi.fn<AuthRouteDependencies['issueAppJwt']>();
      const redeem = vi.fn<AuthRouteDependencies['redeemInvite']>();
      const routes = createAuthRoutes({
        verifyAppleIdentityToken: async () => ({ sub, email: null }),
        beginAppleGrantExchange: begin,
        markAppleGrantExchangeUncertain: mark,
        exchangeAppleAuthorizationCode: exchange,
        finishAppleGrantExchange: finish,
        issueAppJwt: issue,
        redeemInvite: redeem,
      });

      const response = await post(routes, '/apple', {
        identityToken: 'initial-identity-token',
        authorizationCode: 'single-use-code',
        invite_code: 'NEVER-CONSUME',
      });

      expect(response.status).toBe(401);
      expect(await response.json()).toEqual({
        error: 'apple_authorization_failed',
      });
      expect(begin).toHaveBeenCalledOnce();
      if (failure === 'threw') expect(mark).toHaveBeenCalledOnce();
      else expect(mark).not.toHaveBeenCalled();
      expect(exchange).not.toHaveBeenCalled();
      expect(finish).not.toHaveBeenCalled();
      expect(issue).not.toHaveBeenCalled();
      expect(redeem).not.toHaveBeenCalled();
    },
  );

  it('marks its exact reservation uncertain and fails value-free before JWT or invite when exchange fails', async () => {
    const sub = `provider-exchange-fail-${crypto.randomUUID()}`;
    const issue = vi.fn<AuthRouteDependencies['issueAppJwt']>();
    const redeem = vi.fn<AuthRouteDependencies['redeemInvite']>();
    const finish = vi.fn<AuthRouteDependencies['finishAppleGrantExchange']>();
    let reservationId: string | null = null;
    const begin = vi.fn<
      AuthRouteDependencies['beginAppleGrantExchange']
    >(async (db, userId, candidate) => {
      reservationId = candidate;
      return beginAppleGrantExchange(db, userId, candidate);
    });
    const mark = vi.fn<
      AuthRouteDependencies['markAppleGrantExchangeUncertain']
    >(async (db, userId, candidate) => {
      expect(candidate).toBe(reservationId);
      return markAppleGrantExchangeUncertain(db, userId, candidate);
    });
    const routes = createAuthRoutes({
      verifyAppleIdentityToken: async () => ({ sub, email: null }),
      exchangeAppleAuthorizationCode: async () => {
        throw new Error('test provider detail that must not escape');
      },
      beginAppleGrantExchange: begin,
      finishAppleGrantExchange: finish,
      markAppleGrantExchangeUncertain: mark,
      issueAppJwt: issue,
      redeemInvite: redeem,
    });

    const response = await post(routes, '/apple', {
      identityToken: 'initial-identity-token',
      authorizationCode: 'never-return-this-code',
      invite_code: 'NEVER-CONSUME',
    });

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({
      error: 'apple_authorization_failed',
    });
    const user = await env.DB
      .prepare('SELECT id FROM users WHERE apple_sub = ?1')
      .bind(sub)
      .first<{ id: string }>();
    expect(user).not.toBeNull();
    expect(begin).toHaveBeenCalledOnce();
    expect(mark).toHaveBeenCalledOnce();
    expect(finish).not.toHaveBeenCalled();
    expect(
      await env.DB
        .prepare(
          `SELECT reservation_id, active_since, revocation_uncertain
             FROM apple_grant_exchange_state WHERE user_id = ?1`,
        )
        .bind(user!.id)
        .first(),
    ).toEqual({
      reservation_id: null,
      active_since: null,
      revocation_uncertain: 1,
    });
    expect(issue).not.toHaveBeenCalled();
    expect(redeem).not.toHaveBeenCalled();
  });

  it.each(['rejected', 'threw'] as const)(
    'marks uncertainty before JWT or invite when reservation finalization is %s',
    async (failure) => {
      const sub = `provider-store-${failure}-${crypto.randomUUID()}`;
      const issue = vi.fn<AuthRouteDependencies['issueAppJwt']>();
      const redeem = vi.fn<AuthRouteDependencies['redeemInvite']>();
      let reservationId: string | null = null;
      const begin = vi.fn<
        AuthRouteDependencies['beginAppleGrantExchange']
      >(async (db, userId, candidate) => {
        reservationId = candidate;
        return beginAppleGrantExchange(db, userId, candidate);
      });
      const finish = vi.fn<
        AuthRouteDependencies['finishAppleGrantExchange']
      >(async () => {
        if (failure === 'threw') throw new Error('test D1 detail');
        return false;
      });
      const mark = vi.fn<
        AuthRouteDependencies['markAppleGrantExchangeUncertain']
      >(async (db, userId, candidate) => {
        expect(candidate).toBe(reservationId);
        return markAppleGrantExchangeUncertain(db, userId, candidate);
      });
      const routes = createAuthRoutes({
        verifyAppleIdentityToken: async () => ({ sub, email: null }),
        exchangeAppleAuthorizationCode: async () => validGrant(),
        beginAppleGrantExchange: begin,
        finishAppleGrantExchange: finish,
        markAppleGrantExchangeUncertain: mark,
        issueAppJwt: issue,
        redeemInvite: redeem,
      });

      const response = await post(routes, '/apple', {
        identityToken: 'initial-identity-token',
        authorizationCode: 'single-use-code',
        invite_code: 'NEVER-CONSUME',
      });

      expect(response.status).toBe(401);
      expect(await response.json()).toEqual({
        error: 'apple_authorization_failed',
      });
      expect(begin).toHaveBeenCalledOnce();
      expect(finish).toHaveBeenCalledOnce();
      expect(mark).toHaveBeenCalledOnce();
      expect(issue).not.toHaveBeenCalled();
      expect(redeem).not.toHaveBeenCalled();
      const user = await env.DB
        .prepare('SELECT id FROM users WHERE apple_sub = ?1')
        .bind(sub)
        .first<{ id: string }>();
      expect(
        await env.DB
          .prepare(
            `SELECT reservation_id, active_since, revocation_uncertain
               FROM apple_grant_exchange_state WHERE user_id = ?1`,
          )
          .bind(user!.id)
          .first(),
      ).toEqual({
        reservation_id: null,
        active_since: null,
        revocation_uncertain: 1,
      });
    },
  );

  it('keeps commit-then-throw storage fail-closed through a later exchange and deletion', async () => {
    const sub = `provider-ambiguous-store-${crypto.randomUUID()}`;
    let committed!: () => void;
    const storageCommitted = new Promise<void>((resolve) => {
      committed = resolve;
    });
    let release!: () => void;
    const releaseFinish = new Promise<void>((resolve) => {
      release = resolve;
    });
    let userId: string | null = null;
    let reservationId: string | null = null;
    const finish = vi.fn<
      AuthRouteDependencies['finishAppleGrantExchange']
    >(async (db, candidateUserId, candidateReservationId, token) => {
      userId = candidateUserId;
      reservationId = candidateReservationId;
      expect(
        await finishAppleGrantExchange(
          db,
          candidateUserId,
          candidateReservationId,
          token,
        ),
      ).toBe(true);
      committed();
      await releaseFinish;
      // Models D1 committing the phase-one batch while the binding loses its
      // result. The route must still find this exact retained reservation.
      throw new Error('ambiguous committed D1 storage');
    });
    const issue = vi.fn<AuthRouteDependencies['issueAppJwt']>();
    const routes = createAuthRoutes({
      verifyAppleIdentityToken: async () => ({ sub, email: null }),
      exchangeAppleAuthorizationCode: async () =>
        validGrant('ambiguously-stored-refresh'),
      finishAppleGrantExchange: finish,
      issueAppJwt: issue,
    });

    const authResponse = post(routes, '/apple', {
      identityToken: 'initial-identity-token',
      authorizationCode: 'single-use-code',
    });
    await storageCommitted;
    expect(userId).not.toBeNull();
    expect(reservationId).not.toBeNull();
    expect(
      await env.DB
        .prepare(
          `SELECT reservation_id, revocation_uncertain
             FROM apple_grant_exchange_state WHERE user_id = ?1`,
        )
        .bind(userId)
        .first(),
    ).toEqual({ reservation_id: reservationId, revocation_uncertain: 0 });

    let providerCalls = 0;
    expect(
      await deleteUserAccount(
        env.DB,
        userId!,
        'configured-owner-that-never-matches',
        crypto.randomUUID(),
        {
          appleConfig: {
            clientId: 'com.example.tresfort',
            teamId: 'TEAM123456',
            keyId: 'KEY1234567',
            privateKey: 'not-used-by-injected-revoker',
          },
          revokeAppleToken: async () => {
            providerCalls += 1;
          },
        },
      ),
    ).toEqual({ error: 'conflict' });
    expect(providerCalls).toBe(0);

    release();
    const failedAuth = await authResponse;
    expect(failedAuth.status).toBe(401);
    expect(await failedAuth.json()).toEqual({
      error: 'apple_authorization_failed',
    });
    expect(issue).not.toHaveBeenCalled();
    expect(
      await env.DB
        .prepare(
          `SELECT reservation_id, active_since, revocation_uncertain
             FROM apple_grant_exchange_state WHERE user_id = ?1`,
        )
        .bind(userId)
        .first(),
    ).toEqual({
      reservation_id: null,
      active_since: null,
      revocation_uncertain: 1,
    });

    // A later successful exchange cannot erase the earlier ambiguity.
    const laterReservation = crypto.randomUUID();
    expect(
      await beginAppleGrantExchange(env.DB, userId!, laterReservation),
    ).toBe(true);
    expect(
      await finishAppleGrantExchange(
        env.DB,
        userId!,
        laterReservation,
        'later-known-refresh',
      ),
    ).toBe(true);
    expect(
      await acknowledgeAppleGrantExchange(
        env.DB,
        userId!,
        laterReservation,
      ),
    ).toBe(true);
    expect(
      await env.DB
        .prepare(
          `SELECT reservation_id, active_since, revocation_uncertain
             FROM apple_grant_exchange_state WHERE user_id = ?1`,
        )
        .bind(userId)
        .first(),
    ).toEqual({
      reservation_id: null,
      active_since: null,
      revocation_uncertain: 1,
    });

    expect(
      await deleteUserAccount(
        env.DB,
        userId!,
        'configured-owner-that-never-matches',
        crypto.randomUUID(),
        {
          appleConfig: {
            clientId: 'com.example.tresfort',
            teamId: 'TEAM123456',
            keyId: 'KEY1234567',
            privateKey: 'not-used-by-injected-revoker',
          },
          revokeAppleToken: async () => {
            providerCalls += 1;
          },
        },
      ),
    ).toMatchObject({ ok: true, apple_revocation: 'manual_required' });
    expect(providerCalls).toBe(0);
  });

  it('rejects an existing deletion intent before provider exchange or JWT issuance, including legacy code omission', async () => {
    const sub = `provider-deleting-${crypto.randomUUID()}`;
    const userId = crypto.randomUUID();
    await env.DB
      .prepare(
        `INSERT INTO users (id, apple_sub, email, display_name, created_at)
         VALUES (?1, ?2, NULL, NULL, ?3)`,
      )
      .bind(userId, sub, Date.now())
      .run();
    await env.DB
      .prepare(
        `INSERT INTO account_deletion_intents
           (user_id, idempotency_key_sha256, created_at)
         VALUES (?1, ?2, ?3)`,
      )
      .bind(userId, 'a'.repeat(64), Date.now())
      .run();

    const exchange = vi.fn<AuthRouteDependencies['exchangeAppleAuthorizationCode']>();
    const begin = vi.fn<AuthRouteDependencies['beginAppleGrantExchange']>();
    const issue = vi.fn<AuthRouteDependencies['issueAppJwt']>();
    const routes = createAuthRoutes({
      verifyAppleIdentityToken: async () => ({ sub, email: null }),
      exchangeAppleAuthorizationCode: exchange,
      beginAppleGrantExchange: begin,
      issueAppJwt: issue,
    });

    for (const body of [
      { identityToken: 'legacy-token' },
      {
        identityToken: 'current-token',
        authorizationCode: 'unused-code',
      },
    ]) {
      const response = await post(routes, '/apple', body);
      expect(response.status).toBe(409);
      expect(await response.json()).toEqual({
        error: 'account_deletion_in_progress',
      });
    }
    expect(begin).not.toHaveBeenCalled();
    expect(exchange).not.toHaveBeenCalled();
    expect(issue).not.toHaveBeenCalled();
  });

  it('keeps the local-only /auth/dev backdoor closed while its owner deletion is in progress', async () => {
    const ownerSub = `dev-deleting-${crypto.randomUUID()}`;
    const userId = crypto.randomUUID();
    await env.DB
      .prepare(
        `INSERT INTO users (id, apple_sub, email, display_name, created_at)
         VALUES (?1, ?2, NULL, NULL, ?3)`,
      )
      .bind(userId, ownerSub, Date.now())
      .run();
    await env.DB
      .prepare(
        `INSERT INTO account_deletion_intents
           (user_id, idempotency_key_sha256, created_at)
         VALUES (?1, ?2, ?3)`,
      )
      .bind(userId, 'b'.repeat(64), Date.now())
      .run();
    const issue = vi.fn<AuthRouteDependencies['issueAppJwt']>();
    const routes = createAuthRoutes({ issueAppJwt: issue });

    const response = await post(
      routes,
      '/dev',
      { secret: 'route-test-dev-secret' },
      routeEnv({ OWNER_APPLE_SUB: ownerSub }),
    );

    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({
      error: 'account_deletion_in_progress',
    });
    expect(issue).not.toHaveBeenCalled();
  });
});
