import { describe, expect, it, vi } from 'vitest';
import { handle, SESSION_COOKIE, SIGNIN_COOKIE, type Fetchable, type GatewayEnv } from '../worker/gateway';

const ORIGIN = 'https://app.tresfort.app';

function makeEnv(api: (request: Request) => Promise<Response> | Response = () => new Response('{}')) {
  const apiFetch = vi.fn(async (request: Request) => api(request));
  const assetFetch = vi.fn(async () => new Response('<!doctype html>', { headers: { 'content-type': 'text/html' } }));
  const env: GatewayEnv = {
    API: { fetch: apiFetch } as Fetchable,
    ASSETS: { fetch: assetFetch } as Fetchable,
    APPLE_WEB_SERVICES_ID: 'com.example.tresfort.web',
    WEB_ORIGIN: ORIGIN,
  };
  return { env, apiFetch, assetFetch };
}

function setCookies(response: Response): string[] {
  return response.headers.getSetCookie();
}

function cookieValue(response: Response, name: string): string | undefined {
  for (const header of setCookies(response)) {
    const [pair] = header.split(';');
    const [key, value] = pair!.split('=');
    if (key === name) return value;
  }
  return undefined;
}

async function startSignIn(env: GatewayEnv) {
  const response = await handle(new Request(`${ORIGIN}/auth/apple/start`), env);
  const location = new URL(response.headers.get('location')!);
  const pending = cookieValue(response, SIGNIN_COOKIE)!;
  return { response, location, pending, state: location.searchParams.get('state')!, nonce: location.searchParams.get('nonce')! };
}

function callback(fields: Record<string, string>, cookie?: string) {
  return new Request(`${ORIGIN}/auth/apple/callback`, {
    method: 'POST',
    headers: {
      'content-type': 'application/x-www-form-urlencoded',
      origin: 'https://appleid.apple.com',
      ...(cookie ? { cookie } : {}),
    },
    body: new URLSearchParams(fields).toString(),
  });
}

describe('Sign in with Apple', () => {
  it('starts with a fresh state and nonce bound to a short-lived cookie', async () => {
    const { env } = makeEnv();
    const { response, location, pending, state, nonce } = await startSignIn(env);

    expect(response.status).toBe(302);
    expect(location.origin + location.pathname).toBe('https://appleid.apple.com/auth/authorize');
    expect(location.searchParams.get('client_id')).toBe('com.example.tresfort.web');
    expect(location.searchParams.get('redirect_uri')).toBe(`${ORIGIN}/auth/apple/callback`);
    expect(location.searchParams.get('response_mode')).toBe('form_post');
    expect(state).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(nonce).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(state).not.toBe(nonce);
    expect(pending).toBe(`${state}.${nonce}`);
    const header = setCookies(response).find((c) => c.startsWith(SIGNIN_COOKIE))!;
    expect(header).toContain('HttpOnly');
    expect(header).toContain('Secure');
    expect(header).toContain('SameSite=None');
    expect(header).toContain('Max-Age=600');

    const second = await startSignIn(env);
    expect(second.state).not.toBe(state);
  });

  it('finishes with the API, passing the cookie nonce, and stores the JWT only in an HttpOnly cookie', async () => {
    const { env, apiFetch } = makeEnv(() => Response.json({ jwt: 'app-jwt', user: { id: 'u1' } }));
    const { pending, state, nonce } = await startSignIn(env);

    const response = await handle(callback({
      state,
      code: 'ignored-code',
      id_token: 'apple-id-token',
      user: JSON.stringify({ name: { firstName: 'Ada', lastName: 'Lovelace' }, email: 'a@example.com' }),
    }, `${SIGNIN_COOKIE}=${pending}`), env);

    expect(response.status).toBe(303);
    expect(response.headers.get('location')).toBe('/');
    expect(cookieValue(response, SESSION_COOKIE)).toBe('app-jwt');
    const session = setCookies(response).find((c) => c.startsWith(SESSION_COOKIE))!;
    expect(session).toMatch(/HttpOnly; Secure; SameSite=Lax; Max-Age=5184000/);
    expect(cookieValue(response, SIGNIN_COOKIE)).toBe('');

    const sent = apiFetch.mock.calls[0]![0] as Request;
    expect(new URL(sent.url).pathname).toBe('/auth/apple');
    expect(await sent.json()).toEqual({ identityToken: 'apple-id-token', nonce, fullName: 'Ada Lovelace' });
  });

  it('rejects a callback whose state does not match the cookie, without calling the API', async () => {
    const { env, apiFetch } = makeEnv();
    const { pending } = await startSignIn(env);

    for (const request of [
      callback({ state: 'forged', id_token: 't' }, `${SIGNIN_COOKIE}=${pending}`),
      callback({ id_token: 't' }, `${SIGNIN_COOKIE}=${pending}`),
      callback({ state: pending.split('.')[0]!, id_token: 't' }),
    ]) {
      const response = await handle(request, env);
      expect(response.status).toBe(303);
      expect(response.headers.get('location')).toBe('/?signin=failed');
      expect(cookieValue(response, SESSION_COOKIE)).toBeUndefined();
    }
    expect(apiFetch).not.toHaveBeenCalled();
  });

  it('reports a cancelled sign-in and an API refusal without setting a session', async () => {
    const { env } = makeEnv(() => Response.json({ error: 'apple_verification_failed' }, { status: 401 }));
    const { pending, state } = await startSignIn(env);

    const cancelled = await handle(callback({ state, error: 'user_cancelled_authorize' }, `${SIGNIN_COOKIE}=${pending}`), env);
    expect(cancelled.headers.get('location')).toBe('/?signin=cancelled');

    const refused = await handle(callback({ state, id_token: 't' }, `${SIGNIN_COOKIE}=${pending}`), env);
    expect(refused.headers.get('location')).toBe('/?signin=failed');
    expect(cookieValue(refused, SESSION_COOKIE)).toBeUndefined();
  });

  it('signs out only from the page itself', async () => {
    const { env } = makeEnv();
    const crossSite = await handle(new Request(`${ORIGIN}/auth/signout`, {
      method: 'POST', headers: { origin: 'https://evil.example' },
    }), env);
    expect(crossSite.status).toBe(403);

    const ok = await handle(new Request(`${ORIGIN}/auth/signout`, {
      method: 'POST', headers: { origin: ORIGIN, 'sec-fetch-site': 'same-origin' },
    }), env);
    expect(ok.status).toBe(204);
    expect(cookieValue(ok, SESSION_COOKIE)).toBe('');
  });

  it('has no dev sign-in unless a dev secret is configured', async () => {
    const { env, apiFetch } = makeEnv();
    const response = await handle(new Request(`${ORIGIN}/auth/dev`, { method: 'POST', headers: { origin: ORIGIN } }), env);
    expect(response.status).toBe(404);
    expect(apiFetch).not.toHaveBeenCalled();
  });
});

describe('API forwarding', () => {
  const pageHeaders = { cookie: `${SESSION_COOKIE}=app-jwt; other=1`, 'x-tres-fort-web': '1', 'sec-fetch-site': 'same-origin' };

  it('adds the bearer from the cookie and forwards only safe headers', async () => {
    const { env, apiFetch } = makeEnv(() => Response.json({ ok: true }, { headers: { 'set-cookie': 'leak=1' } }));
    const response = await handle(new Request(`${ORIGIN}/api/state?since=0`, {
      headers: { ...pageHeaders, accept: 'application/json', 'x-forwarded-for': '1.2.3.4', authorization: 'Bearer spoofed' },
    }), env);

    expect(response.status).toBe(200);
    expect(response.headers.get('set-cookie')).toBeNull();
    expect(response.headers.get('cache-control')).toBe('no-store');
    const sent = apiFetch.mock.calls[0]![0] as Request;
    expect(new URL(sent.url).pathname + new URL(sent.url).search).toBe('/api/state?since=0');
    expect(sent.headers.get('authorization')).toBe('Bearer app-jwt');
    expect(sent.headers.get('x-tresfort-capabilities')).toBe('groups');
    expect(sent.headers.get('accept')).toBe('application/json');
    expect(sent.headers.get('cookie')).toBeNull();
    expect(sent.headers.get('x-forwarded-for')).toBeNull();
  });

  it('refuses calls without the page header, from another site, or without a session', async () => {
    const { env, apiFetch } = makeEnv();
    const noHeader = await handle(new Request(`${ORIGIN}/api/me`, { headers: { cookie: `${SESSION_COOKIE}=app-jwt` } }), env);
    expect(noHeader.status).toBe(403);
    const crossSite = await handle(new Request(`${ORIGIN}/api/me`, {
      headers: { ...pageHeaders, 'sec-fetch-site': 'cross-site' },
    }), env);
    expect(crossSite.status).toBe(403);
    const otherOrigin = await handle(new Request(`${ORIGIN}/api/me`, {
      headers: { ...pageHeaders, origin: 'https://evil.example' },
    }), env);
    expect(otherOrigin.status).toBe(403);
    const signedOut = await handle(new Request(`${ORIGIN}/api/me`, { headers: { 'x-tres-fort-web': '1' } }), env);
    expect(signedOut.status).toBe(401);
    expect(apiFetch).not.toHaveBeenCalled();
  });

  it('stays read-only and never exposes the iPad Station link key', async () => {
    const { env, apiFetch } = makeEnv();
    for (const method of ['POST', 'PUT', 'PATCH', 'DELETE']) {
      const response = await handle(new Request(`${ORIGIN}/api/workouts`, {
        method, headers: { ...pageHeaders, origin: ORIGIN },
      }), env);
      expect(response.status).toBe(405);
    }
    const key = await handle(new Request(`${ORIGIN}/api/me/station-link-key`, { headers: pageHeaders }), env);
    expect(key.status).toBe(404);
    expect(apiFetch).not.toHaveBeenCalled();
  });

  it('clears the session cookie when the API no longer accepts it', async () => {
    const { env } = makeEnv(() => Response.json({ error: 'invalid_token' }, { status: 401 }));
    const response = await handle(new Request(`${ORIGIN}/api/me`, { headers: pageHeaders }), env);
    expect(response.status).toBe(401);
    expect(cookieValue(response, SESSION_COOKIE)).toBe('');
  });

  it('serves everything else from the static assets', async () => {
    const { env, assetFetch, apiFetch } = makeEnv();
    const response = await handle(new Request(`${ORIGIN}/calendar`), env);
    expect(response.status).toBe(200);
    expect(assetFetch).toHaveBeenCalledOnce();
    expect(apiFetch).not.toHaveBeenCalled();
    const unknownAuth = await handle(new Request(`${ORIGIN}/auth/whatever`), env);
    expect(unknownAuth.status).toBe(404);
  });
});
