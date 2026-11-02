import { describe, expect, it, vi } from 'vitest';
import { handle, isAllowedWrite, isWebSession, SESSION_COOKIE, SIGNIN_COOKIE, type Fetchable, type GatewayEnv } from '../worker/gateway';

const ORIGIN = 'https://app.tresfort.app';

function base64url(text: string): string {
  return btoa(text).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** An app JWT shape; the gateway reads only its claims, the API checks the signature. */
function fakeJwt(claims: Record<string, unknown>): string {
  return `${base64url('{"alg":"HS256","typ":"JWT"}')}.${base64url(JSON.stringify(claims))}.signature`;
}

const WEB_JWT = fakeJwt({ sub: 'user-1', client: 'web', iat: 1, exp: 2 });
const APP_JWT = fakeJwt({ sub: 'user-1', iat: 1, exp: 2 });

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
  const pageHeaders = { cookie: `${SESSION_COOKIE}=${WEB_JWT}; other=1`, 'x-tres-fort-web': '1', 'sec-fetch-site': 'same-origin' };
  const writeHeaders = { ...pageHeaders, origin: ORIGIN, 'content-type': 'application/json' };

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
    expect(sent.headers.get('authorization')).toBe(`Bearer ${WEB_JWT}`);
    expect(sent.headers.get('x-tresfort-capabilities')).toBe('groups');
    expect(sent.headers.get('accept')).toBe('application/json');
    expect(sent.headers.get('cookie')).toBeNull();
    expect(sent.headers.get('x-forwarded-for')).toBeNull();
  });

  it('refuses calls without the page header, from another site, or without a session', async () => {
    const { env, apiFetch } = makeEnv();
    const noHeader = await handle(new Request(`${ORIGIN}/api/me`, { headers: { cookie: `${SESSION_COOKIE}=${WEB_JWT}` } }), env);
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

  it('allows only the plan edits the page makes, and never the iPad Station link key', async () => {
    expect(isAllowedWrite('POST', '/api/workouts')).toBe(true);
    expect(isAllowedWrite('PUT', '/api/plan/active')).toBe(true);
    expect(isAllowedWrite('PATCH', '/api/workouts/w1')).toBe(true);
    expect(isAllowedWrite('DELETE', '/api/workouts/w1')).toBe(true);
    expect(isAllowedWrite('POST', '/api/workouts/w1/exercises')).toBe(true);
    expect(isAllowedWrite('PATCH', '/api/workouts/w1/exercises/s1')).toBe(true);
    expect(isAllowedWrite('DELETE', '/api/workouts/w1/exercises/s1')).toBe(true);
    expect(isAllowedWrite('POST', '/api/workouts/w1/exercises/s1/swap')).toBe(true);
    expect(isAllowedWrite('PUT', '/api/workouts/w1/groups')).toBe(true);
    expect(isAllowedWrite('PUT', '/api/plan/schedule')).toBe(true);
    expect(isAllowedWrite('POST', '/api/plan/trips')).toBe(true);
    expect(isAllowedWrite('PATCH', '/api/plan/trips/t1')).toBe(true);
    expect(isAllowedWrite('DELETE', '/api/plan/trips/t1')).toBe(true);
    expect(isAllowedWrite('PUT', '/api/calendar/2026-11-03')).toBe(true);
    expect(isAllowedWrite('POST', '/api/calendar/2026-11-03/move')).toBe(true);
    expect(isAllowedWrite('POST', '/api/plan/history/3/restore')).toBe(true);

    const { env, apiFetch } = makeEnv();
    for (const [method, path] of [
      ['PUT', '/api/workouts'],
      ['DELETE', '/api/me'],
      ['POST', '/api/sessions'],
      ['POST', '/api/sessions/s1/sets'],
      ['PATCH', '/api/me/profile'],
      ['POST', '/api/groups/join'],
      ['POST', '/api/groups'],
      ['PUT', '/api/workouts/w1/groups/g1'],
      ['DELETE', '/api/workouts/w1/groups'],
      ['POST', '/api/plan/history/latest/restore'],
      ['POST', '/api/plan/history/3/compare'],
      ['DELETE', '/api/calendar/2026-11-03'],
      ['PUT', '/api/plan/trips'],
      ['POST', '/api/workouts/w1/exercises/s1'],
      ['PATCH', '/api/workouts/w1/extra/segment'],
    ] as const) {
      const response = await handle(new Request(`${ORIGIN}${path}`, { method, headers: writeHeaders, body: '{}' }), env);
      expect(response.status, `${method} ${path}`).toBe(405);
    }
    const key = await handle(new Request(`${ORIGIN}/api/me/station-link-key`, { headers: pageHeaders }), env);
    expect(key.status).toBe(404);
    expect(apiFetch).not.toHaveBeenCalled();
  });

  it('forwards an allowed write with its JSON body', async () => {
    const { env, apiFetch } = makeEnv(() => Response.json({ id: 'slot-1' }, { status: 201 }));
    const body = JSON.stringify({ exercise: 'Bench Press', target_sets: 3, target_reps: 5, expected_version: 4 });
    const response = await handle(new Request(`${ORIGIN}/api/workouts/w1/exercises`, {
      method: 'POST', headers: writeHeaders, body,
    }), env);

    expect(response.status).toBe(201);
    const sent = apiFetch.mock.calls[0]![0] as Request;
    expect(sent.method).toBe('POST');
    expect(new URL(sent.url).pathname).toBe('/api/workouts/w1/exercises');
    expect(sent.headers.get('content-type')).toBe('application/json');
    expect(sent.headers.get('authorization')).toBe(`Bearer ${WEB_JWT}`);
    expect(await sent.text()).toBe(body);

    const removed = await handle(new Request(`${ORIGIN}/api/workouts/w1/exercises/s1?expected_version=5`, {
      method: 'DELETE', headers: { ...pageHeaders, origin: ORIGIN },
    }), env);
    expect(removed.status).toBe(201);
    const deleted = apiFetch.mock.calls[1]![0] as Request;
    expect(deleted.method).toBe('DELETE');
    expect(new URL(deleted.url).search).toBe('?expected_version=5');
  });

  it('requires the page origin, the page header and a JSON body on writes', async () => {
    const { env, apiFetch } = makeEnv();
    const path = `${ORIGIN}/api/workouts`;
    const noOrigin = await handle(new Request(path, {
      method: 'POST', headers: { ...pageHeaders, 'content-type': 'application/json' }, body: '{}',
    }), env);
    expect(noOrigin.status).toBe(403);
    const otherOrigin = await handle(new Request(path, {
      method: 'POST', headers: { ...writeHeaders, origin: 'https://evil.example' }, body: '{}',
    }), env);
    expect(otherOrigin.status).toBe(403);
    const noPageHeader = await handle(new Request(path, {
      method: 'POST', headers: { ...writeHeaders, 'x-tres-fort-web': '' }, body: '{}',
    }), env);
    expect(noPageHeader.status).toBe(403);
    const form = await handle(new Request(path, {
      method: 'POST', headers: { ...writeHeaders, 'content-type': 'text/plain' }, body: '{}',
    }), env);
    expect(form.status).toBe(415);
    const huge = await handle(new Request(path, {
      method: 'POST', headers: writeHeaders, body: JSON.stringify({ name: 'x'.repeat(70 * 1024) }),
    }), env);
    expect(huge.status).toBe(413);
    expect(apiFetch).not.toHaveBeenCalled();
  });

  it('signs out a session from before web sign-ins were marked', async () => {
    expect(isWebSession(WEB_JWT)).toBe(true);
    expect(isWebSession(APP_JWT)).toBe(false);
    expect(isWebSession('not-a-jwt')).toBe(false);
    expect(isWebSession('a.!!!.c')).toBe(false);

    const { env, apiFetch } = makeEnv();
    const response = await handle(new Request(`${ORIGIN}/api/me`, {
      headers: { ...pageHeaders, cookie: `${SESSION_COOKIE}=${APP_JWT}` },
    }), env);
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: 'signed_out' });
    expect(cookieValue(response, SESSION_COOKIE)).toBe('');
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

describe('Apple Maps token', () => {
  const pageHeaders = { cookie: `${SESSION_COOKIE}=${WEB_JWT}`, 'x-tres-fort-web': '1', 'sec-fetch-site': 'same-origin' };
  const tokenRequest = (headers: Record<string, string>, method = 'GET') =>
    new Request(`${ORIGIN}/maps/token`, { method, headers });

  it('gives a signed-in page of this site the MapKit JS token once the API accepts its session', async () => {
    const { env, apiFetch, assetFetch } = makeEnv(() => Response.json({ id: 'user-1' }));
    env.MAPKIT_TOKEN = 'mapkit-token';
    const response = await handle(tokenRequest(pageHeaders), env);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ token: 'mapkit-token' });
    expect(response.headers.get('cache-control')).toBe('no-store');
    const [check] = apiFetch.mock.calls[0]!;
    expect(new URL(check.url).pathname).toBe('/api/me');
    expect(check.method).toBe('GET');
    expect(check.headers.get('authorization')).toBe(`Bearer ${WEB_JWT}`);
    expect(assetFetch).not.toHaveBeenCalled();
  });

  it('refuses a session the API does not accept, such as a forged or expired cookie', async () => {
    const forged = fakeJwt({ sub: 'someone', client: 'web', exp: 1 });
    const { env } = makeEnv(() => Response.json({ error: 'invalid_token' }, { status: 401 }));
    env.MAPKIT_TOKEN = 'mapkit-token';
    const response = await handle(tokenRequest({ ...pageHeaders, cookie: `${SESSION_COOKIE}=${forged}` }), env);
    expect(response.status).toBe(401);
    expect(cookieValue(response, SESSION_COOKIE)).toBe('');
    expect(JSON.stringify(await response.json())).not.toContain('mapkit-token');
    const { env: down } = makeEnv(() => Response.json({ error: 'boom' }, { status: 500 }));
    down.MAPKIT_TOKEN = 'mapkit-token';
    const failed = await handle(tokenRequest(pageHeaders), down);
    expect(failed.status).toBe(502);
    expect(JSON.stringify(await failed.json())).not.toContain('mapkit-token');
  });

  it('says maps are not set up when the site has no token', async () => {
    const { env } = makeEnv();
    const response = await handle(tokenRequest(pageHeaders), env);
    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ error: 'not_configured' });
  });

  it('refuses other sites, calls without the page header, and signed-out or app sessions', async () => {
    const { env, apiFetch } = makeEnv();
    env.MAPKIT_TOKEN = 'mapkit-token';
    const crossSite = await handle(tokenRequest({ ...pageHeaders, 'sec-fetch-site': 'cross-site' }), env);
    expect(crossSite.status).toBe(403);
    const otherOrigin = await handle(tokenRequest({ ...pageHeaders, origin: 'https://evil.example' }), env);
    expect(otherOrigin.status).toBe(403);
    const { 'x-tres-fort-web': _header, ...withoutHeader } = pageHeaders;
    expect((await handle(tokenRequest(withoutHeader), env)).status).toBe(403);
    const { cookie: _cookie, ...signedOut } = pageHeaders;
    expect((await handle(tokenRequest(signedOut), env)).status).toBe(401);
    const appSession = await handle(tokenRequest({ ...pageHeaders, cookie: `${SESSION_COOKIE}=${APP_JWT}` }), env);
    expect(appSession.status).toBe(401);
    expect(cookieValue(appSession, SESSION_COOKIE)).toBe('');
    for (const response of [crossSite, otherOrigin, appSession]) {
      expect(JSON.stringify(await response.json())).not.toContain('mapkit-token');
    }
    expect(apiFetch).not.toHaveBeenCalled();
  });

  it('answers nothing else under /maps', async () => {
    const { env, assetFetch } = makeEnv();
    env.MAPKIT_TOKEN = 'mapkit-token';
    expect((await handle(tokenRequest({ ...pageHeaders, origin: ORIGIN }, 'POST'), env)).status).toBe(404);
    expect((await handle(new Request(`${ORIGIN}/maps/other`, { headers: pageHeaders }), env)).status).toBe(404);
    expect(assetFetch).not.toHaveBeenCalled();
  });
});
