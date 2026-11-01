/**
 * Same-origin gateway for the Tres Fort web app (docs/plans/web-app).
 *
 * The page never sees an app JWT. Sign in with Apple finishes here, the JWT
 * lives in an HttpOnly cookie, and `/api/*` is forwarded to the API Worker
 * over a service binding with the bearer added. Nothing here depends on the
 * sign-in provider beyond the two `/auth/apple/*` routes, so another provider
 * later only adds routes.
 */

export interface Fetchable {
  fetch(request: Request): Promise<Response>;
}

export interface GatewayEnv {
  /** Static assets (the built single-page app). */
  ASSETS: Fetchable;
  /** The API Worker (`tres-fort`) over a service binding. */
  API: Fetchable;
  /** Sign in with Apple Services ID (client_id for the web). */
  APPLE_WEB_SERVICES_ID: string;
  /** The public origin, e.g. https://app.tresfort.app. */
  WEB_ORIGIN: string;
  /** Local development only: enables /auth/dev through the API's dev sign-in. */
  DEV_AUTH_SECRET?: string;
}

export const SESSION_COOKIE = '__Host-tf_session';
export const SIGNIN_COOKIE = '__Host-tf_siwa';
/** Matches the API's app JWT lifetime (APP_JWT_TTL_SECONDS). */
export const SESSION_MAX_AGE = 60 * 60 * 24 * 60;
const SIGNIN_MAX_AGE = 60 * 10;
const APPLE_AUTHORIZE = 'https://appleid.apple.com/auth/authorize';
const API_ORIGIN = 'https://api.tres-fort.internal';
/** Header the page sends on every API call; a cross-site form cannot set it. */
export const WEB_HEADER = 'x-tres-fort-web';

/** The web is read-only until the plan-editing phase. */
const FORWARDED_METHODS = new Set(['GET', 'HEAD']);
/** API paths the web has no use for and should never reach. */
const BLOCKED_API_PATHS = new Set(['/api/me/station-link-key']);
/** Request headers passed through to the API; everything else is dropped. */
const FORWARDED_HEADERS = ['accept', 'content-type', 'if-none-match'];

export async function handle(request: Request, env: GatewayEnv): Promise<Response> {
  const url = new URL(request.url);
  const path = url.pathname;

  if (path === '/auth/apple/start' && request.method === 'GET') return startAppleSignIn(env);
  if (path === '/auth/apple/callback' && request.method === 'POST') return finishAppleSignIn(request, env);
  if (path === '/auth/signout' && request.method === 'POST') return signOut(request, env);
  if (path === '/auth/dev' && request.method === 'POST' && env.DEV_AUTH_SECRET) return devSignIn(request, env);
  if (path.startsWith('/auth/')) return json({ error: 'not_found' }, 404);
  if (path === '/api' || path.startsWith('/api/')) return forwardToApi(request, env, url);
  return env.ASSETS.fetch(request);
}

// ---- Sign in with Apple -----------------------------------------------------

function randomToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  let text = '';
  for (const byte of bytes) text += String.fromCharCode(byte);
  return btoa(text).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function callbackUrl(env: GatewayEnv): string {
  return `${env.WEB_ORIGIN}/auth/apple/callback`;
}

function startAppleSignIn(env: GatewayEnv): Response {
  const state = randomToken();
  const nonce = randomToken();
  const authorize = new URL(APPLE_AUTHORIZE);
  authorize.search = new URLSearchParams({
    client_id: env.APPLE_WEB_SERVICES_ID,
    redirect_uri: callbackUrl(env),
    response_type: 'code id_token',
    response_mode: 'form_post',
    scope: 'name email',
    state,
    nonce,
  }).toString();
  const headers = new Headers({ location: authorize.toString(), 'cache-control': 'no-store' });
  // Apple posts the result back cross-site, so this short-lived cookie must be
  // SameSite=None to return with that POST. It holds only the random state
  // and nonce for this one attempt.
  headers.append('set-cookie', cookie(SIGNIN_COOKIE, `${state}.${nonce}`, SIGNIN_MAX_AGE, 'None'));
  return new Response(null, { status: 302, headers });
}

function fullNameFrom(rawUser: unknown): string | undefined {
  if (typeof rawUser !== 'string') return undefined;
  try {
    const parsed = JSON.parse(rawUser) as { name?: { firstName?: unknown; lastName?: unknown } };
    const parts = [parsed.name?.firstName, parsed.name?.lastName]
      .filter((part): part is string => typeof part === 'string' && part.trim().length > 0)
      .map((part) => part.trim());
    return parts.length ? parts.join(' ').slice(0, 200) : undefined;
  } catch {
    return undefined;
  }
}

async function finishAppleSignIn(request: Request, env: GatewayEnv): Promise<Response> {
  const pending = readCookie(request, SIGNIN_COOKIE);
  const clearPending = cookie(SIGNIN_COOKIE, '', 0, 'None');
  let form: FormData;
  try {
    form = await request.formData();
  } catch {
    return redirectHome('failed', [clearPending]);
  }
  const [expectedState, nonce] = (pending ?? '').split('.');
  const state = form.get('state');
  if (!expectedState || !nonce || typeof state !== 'string' || !sameText(state, expectedState)) {
    return redirectHome('failed', [clearPending]);
  }
  if (form.get('error')) return redirectHome('cancelled', [clearPending]);
  const identityToken = form.get('id_token');
  if (typeof identityToken !== 'string' || identityToken.length === 0) {
    return redirectHome('failed', [clearPending]);
  }

  const fullName = fullNameFrom(form.get('user'));
  const apiResponse = await env.API.fetch(new Request(`${API_ORIGIN}/auth/apple`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', accept: 'application/json' },
    body: JSON.stringify({ identityToken, nonce, ...(fullName ? { fullName } : {}) }),
  }));
  if (!apiResponse.ok) {
    const reason = apiResponse.status === 410 || apiResponse.status === 409 ? 'unavailable' : 'failed';
    return redirectHome(reason, [clearPending]);
  }
  const body = (await apiResponse.json().catch(() => null)) as { jwt?: unknown } | null;
  if (!body || typeof body.jwt !== 'string' || body.jwt.length === 0) {
    return redirectHome('failed', [clearPending]);
  }
  return redirectHome(null, [clearPending, cookie(SESSION_COOKIE, body.jwt, SESSION_MAX_AGE, 'Lax')]);
}

async function devSignIn(request: Request, env: GatewayEnv): Promise<Response> {
  if (!isSameOrigin(request, env)) return json({ error: 'forbidden' }, 403);
  const apiResponse = await env.API.fetch(new Request(`${API_ORIGIN}/auth/dev`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ secret: env.DEV_AUTH_SECRET }),
  }));
  const body = (await apiResponse.json().catch(() => null)) as { jwt?: unknown } | null;
  if (!apiResponse.ok || !body || typeof body.jwt !== 'string') return json({ error: 'dev_signin_failed' }, 502);
  return new Response(null, {
    status: 204,
    headers: { 'set-cookie': cookie(SESSION_COOKIE, body.jwt, SESSION_MAX_AGE, 'Lax'), 'cache-control': 'no-store' },
  });
}

function signOut(request: Request, env: GatewayEnv): Response {
  if (!isSameOrigin(request, env)) return json({ error: 'forbidden' }, 403);
  return new Response(null, {
    status: 204,
    headers: { 'set-cookie': cookie(SESSION_COOKIE, '', 0, 'Lax'), 'cache-control': 'no-store' },
  });
}

function redirectHome(problem: string | null, cookies: string[]): Response {
  const headers = new Headers({ location: problem ? `/?signin=${problem}` : '/', 'cache-control': 'no-store' });
  for (const value of cookies) headers.append('set-cookie', value);
  return new Response(null, { status: 303, headers });
}

// ---- API forwarding ---------------------------------------------------------

async function forwardToApi(request: Request, env: GatewayEnv, url: URL): Promise<Response> {
  if (BLOCKED_API_PATHS.has(url.pathname)) return json({ error: 'not_found' }, 404);
  if (!FORWARDED_METHODS.has(request.method)) return json({ error: 'read_only' }, 405);
  // Same-origin GET fetches carry no Origin header, so reads rely on the
  // custom header (a cross-site page cannot send it without a CORS preflight,
  // which this gateway never answers) plus Sec-Fetch-Site when the browser
  // sends it. Writes, when they arrive, must also carry a matching Origin.
  if (!isSameOrigin(request, env, { requireOrigin: false }) || request.headers.get(WEB_HEADER) !== '1') {
    return json({ error: 'forbidden' }, 403);
  }
  const jwt = readCookie(request, SESSION_COOKIE);
  if (!jwt) return json({ error: 'signed_out' }, 401);

  const headers = new Headers();
  for (const name of FORWARDED_HEADERS) {
    const value = request.headers.get(name);
    if (value !== null) headers.set(name, value);
  }
  headers.set('authorization', `Bearer ${jwt}`);
  // Ask for the plan's superset and circuit groups, as the current app does.
  headers.set('x-tresfort-capabilities', 'groups');

  const upstream = await env.API.fetch(new Request(`${API_ORIGIN}${url.pathname}${url.search}`, {
    method: request.method,
    headers,
    redirect: 'manual',
  }));
  const responseHeaders = new Headers(upstream.headers);
  responseHeaders.delete('set-cookie');
  responseHeaders.set('cache-control', 'no-store');
  if (upstream.status === 401) {
    // The stored session is no longer accepted: drop it so the page shows sign-in.
    responseHeaders.append('set-cookie', cookie(SESSION_COOKIE, '', 0, 'Lax'));
  }
  return new Response(upstream.body, { status: upstream.status, headers: responseHeaders });
}

// ---- helpers ----------------------------------------------------------------

/**
 * A request counts as same-origin only when the browser says so: Origin, when
 * sent (and always, for state-changing requests), must be this site, and
 * Sec-Fetch-Site, when sent, must be same-origin.
 */
export function isSameOrigin(
  request: Request,
  env: GatewayEnv,
  { requireOrigin = true }: { requireOrigin?: boolean } = {},
): boolean {
  const origin = request.headers.get('origin');
  if (origin === null ? requireOrigin : origin !== env.WEB_ORIGIN) return false;
  const site = request.headers.get('sec-fetch-site');
  return site === null || site === 'same-origin';
}

function cookie(name: string, value: string, maxAge: number, sameSite: 'Lax' | 'None'): string {
  return `${name}=${value}; Path=/; HttpOnly; Secure; SameSite=${sameSite}; Max-Age=${maxAge}`;
}

export function readCookie(request: Request, name: string): string | null {
  const header = request.headers.get('cookie');
  if (!header) return null;
  for (const part of header.split(';')) {
    const index = part.indexOf('=');
    if (index < 0) continue;
    if (part.slice(0, index).trim() === name) {
      const value = part.slice(index + 1).trim();
      return value.length ? value : null;
    }
  }
  return null;
}

function sameText(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
  });
}
