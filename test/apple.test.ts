import { applyD1Migrations, env } from 'cloudflare:test';
import {
  decodeJwt,
  decodeProtectedHeader,
  exportPKCS8,
  generateKeyPair,
  jwtVerify,
} from 'jose';
import { beforeAll, describe, expect, it, vi } from 'vitest';
import {
  AppleProviderError,
  createAppleClientSecret,
  exchangeAndVerifyAppleAuthorizationCode,
  exchangeAppleAuthorizationCode,
  revokeAppleRefreshToken,
  type AppleFetcher,
  type AppleProviderConfig,
} from '../src/apple';
import {
  accountDeletionContinuationMatches,
  exportUserData,
  storeAppleRefreshToken,
  upsertUser,
} from '../src/db';

const NOW_SECONDS = 1_788_000_000;

let config: AppleProviderConfig;
let publicKey: CryptoKey;

function jsonResponse(value: unknown, ok = true, status = ok ? 200 : 400) {
  return {
    ok,
    status,
    json: async () => value,
  };
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
  const pair = await generateKeyPair('ES256', { extractable: true });
  publicKey = pair.publicKey as CryptoKey;
  config = {
    clientId: 'com.example.tresfort',
    teamId: 'TEAM123456',
    keyId: 'KEY1234567',
    privateKey: await exportPKCS8(pair.privateKey),
  };
});

describe('Sign in with Apple provider client', () => {
  it('signs the exact ES256 client-secret header and claims', async () => {
    const token = await createAppleClientSecret(config, NOW_SECONDS);
    expect(decodeProtectedHeader(token)).toEqual({
      alg: 'ES256',
      kid: 'KEY1234567',
    });
    expect(decodeJwt(token)).toMatchObject({
      iss: 'TEAM123456',
      sub: 'com.example.tresfort',
      aud: 'https://appleid.apple.com',
      iat: NOW_SECONDS,
      exp: NOW_SECONDS + 5 * 60,
    });
    await expect(
      jwtVerify(token, publicKey, {
        issuer: 'TEAM123456',
        subject: 'com.example.tresfort',
        audience: 'https://appleid.apple.com',
        currentDate: new Date(NOW_SECONDS * 1000),
      }),
    ).resolves.toBeDefined();
  });

  it('posts the authorization-code form and returns only the revocation grant', async () => {
    const fetcher = vi.fn<AppleFetcher>(async (_input, _init) =>
      jsonResponse({
        access_token: 'not-retained',
        refresh_token: 'caller-refresh',
        id_token: 'provider-identity-token',
        expires_in: 3600,
      }),
    );
    const grant = await exchangeAppleAuthorizationCode(
      config,
      'single-use-code',
      { fetcher, nowSeconds: NOW_SECONDS },
    );
    expect(grant).toEqual({
      refreshToken: 'caller-refresh',
      identityToken: 'provider-identity-token',
    });
    expect(fetcher).toHaveBeenCalledOnce();
    const [url, init] = fetcher.mock.calls[0]!;
    expect(url).toBe('https://appleid.apple.com/auth/token');
    expect(init.method).toBe('POST');
    expect(init.headers).toEqual({
      'Content-Type': 'application/x-www-form-urlencoded',
    });
    const form = new URLSearchParams(init.body);
    expect(Object.fromEntries(form.entries())).toMatchObject({
      client_id: 'com.example.tresfort',
      code: 'single-use-code',
      grant_type: 'authorization_code',
    });
    expect(form.get('client_secret')).toBeTruthy();
    expect(form.get('client_secret')).not.toContain('single-use-code');
  });

  it('verifies the exchanged id_token subject against the initial identity', async () => {
    const fetcher: AppleFetcher = async () =>
      jsonResponse({
        refresh_token: 'caller-refresh',
        id_token: 'provider-identity-token',
      });
    const verifier = vi.fn(async (token: string) => {
      expect(token).toBe('provider-identity-token');
      return { sub: 'same-apple-sub' };
    });
    await expect(
      exchangeAndVerifyAppleAuthorizationCode(
        config,
        'single-use-code',
        'same-apple-sub',
        verifier,
        { fetcher, nowSeconds: NOW_SECONDS },
      ),
    ).resolves.toMatchObject({ refreshToken: 'caller-refresh' });

    await expect(
      exchangeAndVerifyAppleAuthorizationCode(
        config,
        'single-use-code',
        'different-apple-sub',
        verifier,
        { fetcher, nowSeconds: NOW_SECONDS },
      ),
    ).rejects.toMatchObject({ code: 'subject_mismatch' });
  });

  it('fails closed on missing signing config, provider errors, and invalid responses', async () => {
    const fetcher = vi.fn<AppleFetcher>(async () =>
      jsonResponse({}, false, 503),
    );
    await expect(
      exchangeAppleAuthorizationCode(
        { clientId: config.clientId },
        'single-use-code',
        { fetcher },
      ),
    ).rejects.toEqual(new AppleProviderError('configuration_missing'));
    expect(fetcher).not.toHaveBeenCalled();

    await expect(
      exchangeAppleAuthorizationCode(config, 'single-use-code', {
        fetcher,
        nowSeconds: NOW_SECONDS,
      }),
    ).rejects.toMatchObject({ code: 'token_exchange_failed' });

    await expect(
      exchangeAppleAuthorizationCode(config, 'single-use-code', {
        fetcher: async () => jsonResponse({ id_token: 'missing-refresh' }),
        nowSeconds: NOW_SECONDS,
      }),
    ).rejects.toMatchObject({ code: 'token_response_invalid' });
  });

  it('bounds a provider request even when the injected fetcher never settles', async () => {
    await expect(
      exchangeAppleAuthorizationCode(config, 'single-use-code', {
        fetcher: async () => new Promise(() => undefined),
        nowSeconds: NOW_SECONDS,
        timeoutMs: 1,
      }),
    ).rejects.toMatchObject({ code: 'provider_timeout' });
  });

  it('posts the exact refresh-token revocation form', async () => {
    const fetcher = vi.fn<AppleFetcher>(async () => jsonResponse({}));
    await revokeAppleRefreshToken(config, 'refresh-to-revoke', {
      fetcher,
      nowSeconds: NOW_SECONDS,
    });
    const [url, init] = fetcher.mock.calls[0]!;
    expect(url).toBe('https://appleid.apple.com/auth/revoke');
    const form = new URLSearchParams(init.body);
    expect(Object.fromEntries(form.entries())).toMatchObject({
      client_id: 'com.example.tresfort',
      token: 'refresh-to-revoke',
      token_type_hint: 'refresh_token',
    });
    expect(form.get('client_secret')).toBeTruthy();

    await expect(
      revokeAppleRefreshToken(config, 'refresh-to-revoke', {
        fetcher: async () => jsonResponse({}, false, 500),
        nowSeconds: NOW_SECONDS,
      }),
    ).rejects.toMatchObject({ code: 'revocation_failed' });
  });
});

describe('caller-scoped Apple refresh-token storage', () => {
  it('isolates tokens, excludes them from export, and blocks replacement after intent', async () => {
    const a = await upsertUser(
      env.DB,
      `apple-token-a-${crypto.randomUUID()}`,
      'a@example.test',
      'A',
    );
    const b = await upsertUser(
      env.DB,
      `apple-token-b-${crypto.randomUUID()}`,
      'b@example.test',
      'B',
    );
    expect(await storeAppleRefreshToken(env.DB, a.id, 'private-refresh-a')).toBe(
      true,
    );
    expect(await storeAppleRefreshToken(env.DB, b.id, 'private-refresh-b')).toBe(
      true,
    );
    expect(
      await env.DB
        .prepare(
          'SELECT refresh_token FROM apple_refresh_tokens WHERE user_id = ?1',
        )
        .bind(a.id)
        .first<{ refresh_token: string }>(),
    ).toEqual({ refresh_token: 'private-refresh-a' });
    expect(JSON.stringify(await exportUserData(env.DB, a.id))).not.toContain(
      'private-refresh-a',
    );
    expect(JSON.stringify(await exportUserData(env.DB, a.id))).not.toContain(
      'private-refresh-b',
    );

    const key = crypto.randomUUID();
    const digest = await crypto.subtle.digest(
      'SHA-256',
      new TextEncoder().encode(key),
    );
    const keyHash = [...new Uint8Array(digest)]
      .map((byte) => byte.toString(16).padStart(2, '0'))
      .join('');
    await env.DB
      .prepare(
        `INSERT INTO account_deletion_intents
           (user_id, idempotency_key_sha256, created_at)
         VALUES (?1, ?2, ?3)`,
      )
      .bind(a.id, keyHash, Date.now())
      .run();

    expect(
      await accountDeletionContinuationMatches(env.DB, a.id, key),
    ).toBe(true);
    expect(
      await accountDeletionContinuationMatches(
        env.DB,
        a.id,
        crypto.randomUUID(),
      ),
    ).toBe(false);
    expect(
      await storeAppleRefreshToken(env.DB, a.id, 'stale-replacement'),
    ).toBe(false);
    expect(
      await env.DB
        .prepare(
          'SELECT refresh_token FROM apple_refresh_tokens WHERE user_id = ?1',
        )
        .bind(a.id)
        .first<{ refresh_token: string }>(),
    ).toEqual({ refresh_token: 'private-refresh-a' });
  });
});
