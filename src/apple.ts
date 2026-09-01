// Sign in with Apple server-to-server I/O. This module is deliberately
// isolated and fetch-injected: callers own identity resolution and D1 writes,
// while tests can exercise every provider branch without network access.
import { SignJWT, importPKCS8 } from 'jose';
import type { Env } from './types';

const APPLE_ISSUER = 'https://appleid.apple.com';
const APPLE_TOKEN_ENDPOINT = `${APPLE_ISSUER}/auth/token`;
const APPLE_REVOKE_ENDPOINT = `${APPLE_ISSUER}/auth/revoke`;
const DEFAULT_TIMEOUT_MS = 5_000;
const CLIENT_SECRET_TTL_SECONDS = 5 * 60;

export interface AppleProviderConfig {
  clientId: string;
  teamId?: string;
  keyId?: string;
  privateKey?: string;
}

/** Minimal fetch contract used by Apple's form endpoints. */
export type AppleFetcher = (
  input: string,
  init: {
    method: string;
    headers: Record<string, string>;
    body: string;
    signal: AbortSignal;
  },
) => Promise<{
  ok: boolean;
  status: number;
  json: () => Promise<unknown>;
}>;

export interface AppleRequestDeps {
  fetcher?: AppleFetcher;
  /** Test-only clock injection, expressed as epoch seconds. */
  nowSeconds?: number;
  /** Test-only override. Production uses the bounded five-second default. */
  timeoutMs?: number;
}

export type AppleProviderErrorCode =
  | 'configuration_missing'
  | 'client_secret_invalid'
  | 'provider_timeout'
  | 'token_exchange_failed'
  | 'token_response_invalid'
  | 'identity_token_invalid'
  | 'subject_mismatch'
  | 'revocation_failed';

/**
 * A deliberately value-free provider failure. Messages never include an
 * authorization code, token, private key, or Apple response body.
 */
export class AppleProviderError extends Error {
  constructor(readonly code: AppleProviderErrorCode) {
    super(code);
    this.name = 'AppleProviderError';
  }
}

export function appleProviderConfig(env: Env): AppleProviderConfig {
  return {
    clientId: env.APPLE_BUNDLE_ID,
    teamId: env.APPLE_TEAM_ID,
    keyId: env.APPLE_KEY_ID,
    privateKey: env.APPLE_PRIVATE_KEY,
  };
}

export function hasAppleProviderSigningConfig(
  config: AppleProviderConfig,
): config is AppleProviderConfig & {
  teamId: string;
  keyId: string;
  privateKey: string;
} {
  return Boolean(
    config.clientId.trim() &&
      config.teamId?.trim() &&
      config.keyId?.trim() &&
      config.privateKey?.trim(),
  );
}

/** Build Apple's ES256 client-secret JWT from owner-managed signing config. */
export async function createAppleClientSecret(
  config: AppleProviderConfig,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<string> {
  if (!hasAppleProviderSigningConfig(config)) {
    throw new AppleProviderError('configuration_missing');
  }
  try {
    const key = await importPKCS8(config.privateKey, 'ES256');
    return await new SignJWT({})
      .setProtectedHeader({ alg: 'ES256', kid: config.keyId })
      .setIssuer(config.teamId)
      .setIssuedAt(nowSeconds)
      .setExpirationTime(nowSeconds + CLIENT_SECRET_TTL_SECONDS)
      .setAudience(APPLE_ISSUER)
      .setSubject(config.clientId)
      .sign(key);
  } catch (error) {
    if (error instanceof AppleProviderError) throw error;
    throw new AppleProviderError('client_secret_invalid');
  }
}

function defaultFetcher(): AppleFetcher {
  return async (input, init) => fetch(input, init);
}

async function postAppleForm(
  endpoint: string,
  form: URLSearchParams,
  failure: 'token_exchange_failed' | 'revocation_failed',
  deps: AppleRequestDeps,
): Promise<{ json: () => Promise<unknown> }> {
  const controller = new AbortController();
  const timeoutMs = Math.max(1, Math.min(deps.timeoutMs ?? DEFAULT_TIMEOUT_MS, 30_000));
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const request = (deps.fetcher ?? defaultFetcher())(endpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: form.toString(),
        signal: controller.signal,
      });
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(() => {
        controller.abort();
        reject(new AppleProviderError('provider_timeout'));
      }, timeoutMs);
    });
    const response = await Promise.race([request, timeout]);
    if (!response.ok) throw new AppleProviderError(failure);
    return response;
  } catch (error) {
    if (error instanceof AppleProviderError) throw error;
    throw new AppleProviderError(failure);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

export interface AppleAuthorizationGrant {
  refreshToken: string;
  identityToken: string;
}

/** Exchange one single-use native authorization code for a revocable grant. */
export async function exchangeAppleAuthorizationCode(
  config: AppleProviderConfig,
  authorizationCode: string,
  deps: AppleRequestDeps = {},
): Promise<AppleAuthorizationGrant> {
  if (!authorizationCode.trim()) {
    throw new AppleProviderError('token_exchange_failed');
  }
  const clientSecret = await createAppleClientSecret(config, deps.nowSeconds);
  const response = await postAppleForm(
    APPLE_TOKEN_ENDPOINT,
    new URLSearchParams({
      client_id: config.clientId,
      client_secret: clientSecret,
      code: authorizationCode,
      grant_type: 'authorization_code',
    }),
    'token_exchange_failed',
    deps,
  );
  let value: unknown;
  try {
    value = await response.json();
  } catch {
    throw new AppleProviderError('token_response_invalid');
  }
  if (!value || typeof value !== 'object') {
    throw new AppleProviderError('token_response_invalid');
  }
  const refreshToken = (value as Record<string, unknown>).refresh_token;
  const identityToken = (value as Record<string, unknown>).id_token;
  if (
    typeof refreshToken !== 'string' ||
    !refreshToken ||
    typeof identityToken !== 'string' ||
    !identityToken
  ) {
    throw new AppleProviderError('token_response_invalid');
  }
  return { refreshToken, identityToken };
}

/**
 * Exchange and bind the provider grant to the identity token already verified
 * on the request. Apple must independently verify the returned id_token, and
 * its stable subject must match before any caller-scoped token is stored.
 */
export async function exchangeAndVerifyAppleAuthorizationCode(
  config: AppleProviderConfig,
  authorizationCode: string,
  expectedSubject: string,
  verifyIdentityToken: (token: string) => Promise<{ sub: string }>,
  deps: AppleRequestDeps = {},
): Promise<AppleAuthorizationGrant> {
  const grant = await exchangeAppleAuthorizationCode(
    config,
    authorizationCode,
    deps,
  );
  let verified: { sub: string };
  try {
    verified = await verifyIdentityToken(grant.identityToken);
  } catch {
    throw new AppleProviderError('identity_token_invalid');
  }
  if (verified.sub !== expectedSubject) {
    throw new AppleProviderError('subject_mismatch');
  }
  return grant;
}

/** Revoke one caller-scoped Apple refresh token. Any non-2xx is a failure. */
export async function revokeAppleRefreshToken(
  config: AppleProviderConfig,
  refreshToken: string,
  deps: AppleRequestDeps = {},
): Promise<void> {
  if (!refreshToken) throw new AppleProviderError('revocation_failed');
  const clientSecret = await createAppleClientSecret(config, deps.nowSeconds);
  await postAppleForm(
    APPLE_REVOKE_ENDPOINT,
    new URLSearchParams({
      client_id: config.clientId,
      client_secret: clientSecret,
      token: refreshToken,
      token_type_hint: 'refresh_token',
    }),
    'revocation_failed',
    deps,
  );
}
