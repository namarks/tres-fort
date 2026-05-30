// intervals.icu OAuth — Bearer auth in the fetchers + the /auth/intervals
// start/callback routes + the per-user OAuth credential storage.
//
// Everything here is OFFLINE: the fetchers take an injected capturing fetcher,
// and the callback tests only exercise the pre-exchange branches (error param,
// missing code, bad/used state). The live code→token exchange in /callback
// hits intervals.icu and is verified manually, not in the suite.
import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { fetchPlannedEvents, type Fetcher } from '../src/intervals';
import {
  consumeIntervalsOAuthState,
  createIntervalsOAuthState,
  getMeProfile,
  getUserIntervalsCreds,
  setUserIntervalsCreds,
  setUserIntervalsOAuth,
  syncExternalEvents,
} from '../src/db';

const BASE = 'https://lift-coach.test';
const TODAY = '2026-05-18';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

/** A fetcher that records the Authorization header it was called with. */
function capturingFetcher(): { fetcher: Fetcher; auth: () => string | undefined; calls: () => number } {
  let lastAuth: string | undefined;
  let n = 0;
  const fetcher: Fetcher = async (_input, init) => {
    n += 1;
    lastAuth = init?.headers?.Authorization;
    return { ok: true, status: 200, json: async () => [] };
  };
  return { fetcher, auth: () => lastAuth, calls: () => n };
}

async function devJwt(): Promise<{ id: string; jwt: string }> {
  const r = await SELF.fetch(`${BASE}/auth/dev`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ secret: 'test-dev' }),
  });
  expect(r.status).toBe(200);
  const b = await r.json<{ jwt: string; user: { id: string } }>();
  return { id: b.user.id, jwt: b.jwt };
}

describe('intervals.ts auth: Bearer (OAuth) vs Basic (API key)', () => {
  it('uses Bearer when an access token is supplied', async () => {
    const cap = capturingFetcher();
    const res = await fetchPlannedEvents(null, 'i999', {
      fetcher: cap.fetcher,
      accessToken: 'tok-abc',
      today: TODAY,
    });
    expect(res.ok).toBe(true);
    expect(cap.auth()).toBe('Bearer tok-abc');
  });

  it('falls back to Basic API_KEY auth when only an api key is supplied', async () => {
    const cap = capturingFetcher();
    await fetchPlannedEvents('mykey', 'i999', { fetcher: cap.fetcher, today: TODAY });
    expect(cap.auth()).toBe(`Basic ${btoa('API_KEY:mykey')}`);
  });

  it('Bearer wins when both are present', async () => {
    const cap = capturingFetcher();
    await fetchPlannedEvents('mykey', 'i999', {
      fetcher: cap.fetcher,
      accessToken: 'tok-xyz',
      today: TODAY,
    });
    expect(cap.auth()).toBe('Bearer tok-xyz');
  });

  it('dormant (no fetch) when neither credential is present', async () => {
    const cap = capturingFetcher();
    const res = await fetchPlannedEvents(null, 'i999', { fetcher: cap.fetcher, today: TODAY });
    expect(res.ok).toBe(false);
    expect(cap.calls()).toBe(0);
  });
});

describe('OAuth state: single-use + expiry', () => {
  it('round-trips create → consume → userId, then null on reuse', async () => {
    const a = await devJwt();
    const state = await createIntervalsOAuthState(env.DB, a.id);
    expect(await consumeIntervalsOAuthState(env.DB, state)).toBe(a.id);
    // single-use: a replay returns null
    expect(await consumeIntervalsOAuthState(env.DB, state)).toBeNull();
  });

  it('unknown state → null', async () => {
    expect(await consumeIntervalsOAuthState(env.DB, 'never-issued')).toBeNull();
  });

  it('expired state → null (and is swept)', async () => {
    const a = await devJwt();
    const state = await createIntervalsOAuthState(env.DB, a.id, -1); // already expired
    expect(await consumeIntervalsOAuthState(env.DB, state)).toBeNull();
  });
});

describe('setUserIntervalsOAuth + mutual exclusivity with the API key', () => {
  it('stores the bearer token + athlete id, clears any api key, reports connected', async () => {
    const a = await devJwt();
    await setUserIntervalsCreds(env.DB, a.id, 'old-key', 'i111'); // start on the API-key path
    await setUserIntervalsOAuth(env.DB, a.id, 'tok', 'refresh', null, 'i777');
    const creds = await getUserIntervalsCreds(env.DB, a.id);
    expect(creds.access_token).toBe('tok');
    expect(creds.athlete_id).toBe('i777');
    expect(creds.api_key).toBeNull(); // OAuth cleared the API key
    const me = await getMeProfile(env.DB, a.id, env.OWNER_APPLE_SUB);
    expect(me.intervals.connected).toBe(true);
    expect(me.intervals.athlete_id).toBe('i777');
  });

  it('disconnect (setUserIntervalsCreds null) clears BOTH schemes', async () => {
    const a = await devJwt();
    await setUserIntervalsOAuth(env.DB, a.id, 'tok', null, null, 'i777');
    await setUserIntervalsCreds(env.DB, a.id, null, null);
    const creds = await getUserIntervalsCreds(env.DB, a.id);
    expect(creds.access_token).toBeNull();
    expect(creds.api_key).toBeNull();
    expect(creds.athlete_id).toBeNull();
  });
});

describe('sync uses the stored OAuth token end-to-end', () => {
  it('an OAuth-connected user syncs with a Bearer header', async () => {
    const a = await devJwt();
    await setUserIntervalsOAuth(env.DB, a.id, 'sync-tok', null, null, 'i555');
    const cap = capturingFetcher();
    await syncExternalEvents(env.DB, env, { userId: a.id, fetcher: cap.fetcher, today: TODAY });
    expect(cap.auth()).toBe('Bearer sync-tok');
  });
});

describe('POST /auth/intervals/start', () => {
  it('requires app auth', async () => {
    const r = await SELF.fetch(`${BASE}/auth/intervals/start`, { method: 'POST' });
    expect(r.status).toBe(401);
  });

  it('returns a well-formed authorize URL and records a state row', async () => {
    const a = await devJwt();
    const r = await SELF.fetch(`${BASE}/auth/intervals/start`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${a.jwt}` },
    });
    expect(r.status).toBe(200);
    const { authorize_url } = await r.json<{ authorize_url: string }>();
    const u = new URL(authorize_url);
    expect(`${u.origin}${u.pathname}`).toBe('https://intervals.icu/oauth/authorize');
    expect(u.searchParams.get('client_id')).toBe('431');
    expect(u.searchParams.get('redirect_uri')).toBe(`${BASE}/auth/intervals/callback`);
    expect(u.searchParams.get('scope')).toBe('ACTIVITY:READ,CALENDAR:WRITE');
    expect(u.searchParams.get('response_type')).toBe('code');
    const state = u.searchParams.get('state')!;
    expect(state.length).toBeGreaterThan(20);
    const row = await env.DB.prepare(
      'SELECT user_id FROM intervals_oauth_states WHERE state = ?1',
    )
      .bind(state)
      .first<{ user_id: string }>();
    expect(row?.user_id).toBe(a.id);
  });
});

describe('GET /auth/intervals/callback (pre-exchange branches)', () => {
  it('user-declined error param → bounces back with the error', async () => {
    const r = await SELF.fetch(`${BASE}/auth/intervals/callback?error=access_denied`, {
      redirect: 'manual',
    });
    expect(r.status).toBe(302);
    expect(r.headers.get('location')).toBe('tresfort://intervals-connected?error=access_denied');
  });

  it('missing code → error', async () => {
    const r = await SELF.fetch(`${BASE}/auth/intervals/callback?state=x`, { redirect: 'manual' });
    expect(r.status).toBe(302);
    expect(r.headers.get('location')).toContain('error=missing_code');
  });

  it('unknown state → bad_state (before any token exchange)', async () => {
    const r = await SELF.fetch(`${BASE}/auth/intervals/callback?code=abc&state=bogus`, {
      redirect: 'manual',
    });
    expect(r.status).toBe(302);
    expect(r.headers.get('location')).toContain('error=bad_state');
  });
});
