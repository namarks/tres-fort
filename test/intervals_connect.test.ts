import { applyD1Migrations, env, fetchMock, createExecutionContext, waitOnExecutionContext } from 'cloudflare:test';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import worker from '../src/index';
import { issueAppJwt } from '../src/auth';
import {
  consumeIntervalsOAuthAttempt, createIntervalsOAuthState, getIntervalsConnectionStatus,
  getUserIntervalsCreds, reconcileIntervalsConnection, setUserIntervalsCreds,
  setUserIntervalsOAuth, type IntervalsImportResult,
} from '../src/db';
import type { ExternalActivityRow } from '../src/types';
import type { Fetcher } from '../src/intervals';

beforeAll(async () => { await applyD1Migrations(env.DB, env.TEST_MIGRATIONS); });
beforeEach(() => { fetchMock.activate(); fetchMock.disableNetConnect(); });
const contexts: ExecutionContext[] = [];
async function settle() { await Promise.all(contexts.splice(0).map(waitOnExecutionContext)); }
afterEach(async () => { await settle(); vi.unstubAllGlobals(); fetchMock.deactivate(); });
async function request(url: string, init?: RequestInit) {
  const context = createExecutionContext();
  contexts.push(context);
  return worker.fetch(new Request(url, init), env, context);
}

const origin = 'https://intervals.icu';
const today = new Date().toISOString().slice(0, 10);
const activity = { id: 'ride-1', type: 'Ride', start_date_local: `${today}T08:00:00`,
  start_date: `${today}T08:00:00Z`, name: 'Morning ride', moving_time: 1800 };
const success: Fetcher = async () => ({ ok: true, status: 200, json: async () => [activity] });

async function member() {
  const id = crypto.randomUUID();
  await env.DB.prepare("INSERT INTO users(id,apple_sub,created_at,timezone) VALUES (?1,?1,1,'UTC')").bind(id).run();
  return { id, jwt: await issueAppJwt(id, 'test-secret') };
}
function headers(jwt: string) { return { Authorization: `Bearer ${jwt}`, 'content-type': 'application/json' }; }
async function connect(jwt: string, api_key: string | null = 'synthetic-key', athlete_id: string | null = 'athlete-a') {
  const response = await request('https://test/api/me/integrations/intervals', {
    method: 'PATCH', headers: headers(jwt), body: JSON.stringify({ api_key, athlete_id }),
  });
  await settle();
  return response;
}
async function startOAuth(jwt: string) {
  const response = await request('https://test/auth/intervals/start', { method: 'POST', headers: headers(jwt) });
  return new URL((await response.json<{ authorize_url: string }>()).authorize_url).searchParams.get('state')!;
}
async function finishOAuth(jwt: string, callback: Response) {
  const completion = new URL(callback.headers.get('Location')!).searchParams.get('completion');
  expect(completion).toMatch(/^[A-Za-z0-9_-]{43}$/);
  return request('https://test/auth/intervals/finish', { method: 'POST', headers: headers(jwt), body: JSON.stringify({ completion }) });
}
function importResponse(status = 200, body: object = [activity]) {
  fetchMock.get(origin).intercept({ path: /\/api\/v1\/athlete\/[^/]+\/activities\?/ })
    .reply(status, body);
}
async function rows(userId: string) {
  return (await env.DB.prepare("SELECT * FROM external_activities WHERE user_id=?1 AND source='intervals'")
    .bind(userId).all<ExternalActivityRow>()).results;
}

describe('Intervals connection reconciliation', () => {
  it('imports immediately after API-key connect and refreshes the same rows on an identical retry', async () => {
    const user = await member();
    importResponse();
    const response = await connect(user.jwt);
    expect(response.status).toBe(200);
    const first = await response.json<{ connected: boolean; credential_generation: number }>();
    expect(first).toMatchObject({ connected: true });
    expect(await getIntervalsConnectionStatus(env.DB, user.id)).toMatchObject({ sync_pending: false });
    expect(await rows(user.id)).toHaveLength(1);
    const saved = (await rows(user.id))[0]!;
    importResponse();
    const retry = await (await connect(user.jwt)).json<typeof first>();
    expect(retry.credential_generation).toBe(first.credential_generation);
    expect((retry as { activity_sync_after?: number }).activity_sync_after).not.toBeNull();
    expect((await rows(user.id))[0]!.synced_at).toBe(saved.synced_at);
    const state = await request('https://test/api/state', { headers: headers(user.jwt) });
    expect((await state.json<{ external_activities: ExternalActivityRow[] }>()).external_activities.map(row => row.id))
      .toEqual([saved.id]);
  });

  it('keeps a successful credential acknowledgement on a provider outage, then retries without resubmitting credentials', async () => {
    const user = await member();
    importResponse(503, { error: 'temporary' });
    const response = await connect(user.jwt);
    expect(response.status).toBe(200);
    const saved = await response.json<{ credential_generation: number; activity_sync_after: number | null }>();
    expect(await getIntervalsConnectionStatus(env.DB, user.id)).toMatchObject({ connected: true, sync_pending: true });
    importResponse();
    const retried = await request('https://test/api/me/integrations/intervals/sync', {
      method: 'POST', headers: headers(user.jwt), body: JSON.stringify({ expected_generation: saved.credential_generation }),
    });
    expect(await retried.json()).toMatchObject({ status: 'synced', connection: { sync_pending: false } });
    expect(await rows(user.id)).toHaveLength(1);
  });

  it('preserves history on rejected credentials, clears the auth error on reconnect, and preserves it on disconnect', async () => {
    const user = await member();
    const stored = await setUserIntervalsCreds(env.DB, user.id, env.CREDENTIAL_ENCRYPTION_KEY, 'old-key', 'athlete-a');
    await reconcileIntervalsConnection(env.DB, env, user.id, stored.credential_generation, { fetcher: success, today });
    const previous = await rows(user.id);
    importResponse(401, {});
    const rejected = await (await connect(user.jwt, 'rejected-key')).json<{ connected: boolean }>();
    expect(rejected).toMatchObject({ connected: true });
    expect(await getIntervalsConnectionStatus(env.DB, user.id)).toMatchObject({ connected: false, needs_reauth: true });
    expect(await rows(user.id)).toEqual(previous);
    importResponse();
    expect(await (await connect(user.jwt, 'new-key')).json()).toMatchObject({ connected: true });
    expect(await getIntervalsConnectionStatus(env.DB, user.id)).toMatchObject({ needs_reauth: false });
    expect(await (await connect(user.jwt, null, null)).json()).toMatchObject({ connected: false });
    expect(await rows(user.id)).toEqual(previous);
    const status = await getIntervalsConnectionStatus(env.DB, user.id);
    const calls: string[] = [];
    const result = await reconcileIntervalsConnection(env.DB, env, user.id, status.credential_generation, {
      fetcher: async (input) => { calls.push(input); return success(input); },
    });
    expect(result.status).toBe('disconnected');
    expect(calls).toEqual([]);
  });

  it.each(['disconnect', 'replace'] as const)('fences an import that finishes after %s', async (change) => {
    const user = await member();
    const stored = await setUserIntervalsCreds(env.DB, user.id, env.CREDENTIAL_ENCRYPTION_KEY, 'old-key', 'athlete-a');
    let started!: () => void;
    const began = new Promise<void>(resolve => { started = resolve; });
    let release!: () => void;
    const gate = new Promise<void>(resolve => { release = resolve; });
    const running = reconcileIntervalsConnection(env.DB, env, user.id, stored.credential_generation, {
      today, fetcher: async () => { started(); await gate; return success(''); },
    });
    await began;
    await setUserIntervalsCreds(env.DB, user.id, env.CREDENTIAL_ENCRYPTION_KEY, change === 'replace' ? 'new-key' : null, change === 'replace' ? 'athlete-b' : null);
    release();
    expect((await running).status).toBe('superseded');
    expect(await rows(user.id)).toEqual([]);
    expect((await getIntervalsConnectionStatus(env.DB, user.id)).last_synced_at).toBeNull();
  });

  it('reconciles only the authenticated member and rejects a stale retry before provider I/O', async () => {
    const a = await member(), b = await member();
    const old = await setUserIntervalsCreds(env.DB, a.id, env.CREDENTIAL_ENCRYPTION_KEY, 'a-key', 'athlete-a');
    await setUserIntervalsCreds(env.DB, b.id, env.CREDENTIAL_ENCRYPTION_KEY, 'b-key', 'athlete-b');
    importResponse();
    await request('https://test/api/me/integrations/intervals/sync', { method: 'POST', headers: headers(a.jwt),
      body: JSON.stringify({ expected_generation: old.credential_generation }) });
    expect(await rows(a.id)).toHaveLength(1);
    expect(await rows(b.id)).toEqual([]);
    await setUserIntervalsCreds(env.DB, a.id, env.CREDENTIAL_ENCRYPTION_KEY, null, null);
    const stale = await request('https://test/api/me/integrations/intervals/sync', { method: 'POST', headers: headers(a.jwt),
      body: JSON.stringify({ expected_generation: old.credential_generation }) });
    expect(await stale.json()).toMatchObject({ status: 'superseded' });
    expect((await getUserIntervalsCreds(env.DB, b.id, env.CREDENTIAL_ENCRYPTION_KEY)).api_key).toBe('b-key');
  });

  it('requires authentication and a valid generation for explicit retry', async () => {
    expect((await request('https://test/api/me/integrations/intervals/sync', { method: 'POST' })).status).toBe(401);
    const user = await member();
    for (const body of [null, {}, { expected_generation: -1 }, { expected_generation: 1.5 }, { expected_generation: 1, userId: 'other' }]) {
      const response = await request('https://test/api/me/integrations/intervals/sync', {
        method: 'POST', headers: headers(user.jwt), body: JSON.stringify(body),
      });
      expect(response.status).toBe(400);
    }
  });

  it('imports through the actual OAuth callback and rejects replay without another exchange', async () => {
    const user = await member();
    const state = await startOAuth(user.jwt);
    fetchMock.get(origin).intercept({ path: '/api/oauth/token', method: 'POST' })
      .reply(200, { access_token: 'synthetic-oauth-token', athlete: { id: 'oauth-athlete' } });
    importResponse();
    const callback = `https://test/auth/intervals/callback?code=synthetic-code&state=${state}`;
    const response = await request(callback, { redirect: 'manual' });
    expect(response.status).toBe(302);
    expect(await (await finishOAuth(user.jwt, response)).json()).toMatchObject({ connected: true, credential_generation: 1 });
    await settle();
    expect(await rows(user.id)).toHaveLength(1);
    const retry = await request(callback, { redirect: 'manual' });
    expect(retry.headers.get('Location')).toContain('error=bad_state');
  });

  it.each([503, 401])('keeps OAuth acceptance separate from initial import HTTP %i', async (status) => {
    const user = await member();
    const state = await startOAuth(user.jwt);
    fetchMock.get(origin).intercept({ path: '/api/oauth/token', method: 'POST' })
      .reply(200, { access_token: 'synthetic-token', athlete: { id: 'oauth-athlete' } });
    importResponse(status, {});
    const response = await request(`https://test/auth/intervals/callback?code=synthetic-code&state=${state}`, { redirect: 'manual' });
    expect(await (await finishOAuth(user.jwt, response)).json()).toMatchObject({ connected: true, credential_generation: 1 });
    await settle();
    expect(await getIntervalsConnectionStatus(env.DB, user.id)).toMatchObject({
      connected: status !== 401, needs_reauth: status === 401,
    });
  });

  it.each(['api-key', 'oauth'] as const)('returns the %s acknowledgement while the provider import is still blocked', async (kind) => {
    const user = await member();
    let started!: () => void;
    const began = new Promise<void>(resolve => { started = resolve; });
    let release!: () => void;
    const gate = new Promise<Response>(resolve => { release = () => resolve(new Response(JSON.stringify([activity]))); });
    vi.stubGlobal('fetch', async (input: string) => {
      if (input.endsWith('/api/oauth/token')) {
        return new Response(JSON.stringify({ access_token: 'synthetic-token', athlete: { id: 'athlete-a' } }));
      }
      started();
      return gate;
    });
    const pending = kind === 'oauth'
      ? request(`https://test/auth/intervals/callback?code=synthetic&state=${await startOAuth(user.jwt)}`).then(response => finishOAuth(user.jwt, response))
      : request('https://test/api/me/integrations/intervals', { method: 'PATCH', headers: headers(user.jwt),
          body: JSON.stringify({ api_key: 'synthetic-key', athlete_id: 'athlete-a' }) });
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      await began;
      const response = await Promise.race([pending, new Promise<null>(resolve => { timer = setTimeout(() => resolve(null), 500); })]);
      expect(response, 'credential acknowledgement must not await provider completion').not.toBeNull();
      if (!response) throw new Error('acknowledgement_blocked');
      expect(response.status).toBe(200);
      expect(await response.json()).toMatchObject({ connected: true, credential_generation: 1 });
      expect(await rows(user.id)).toEqual([]);
    } finally {
      if (timer) clearTimeout(timer);
      release();
      await pending;
      await settle();
    }
    expect(await rows(user.id)).toHaveLength(1);
  });

  it('rejects an OAuth state insertion that crosses disconnect after the attempt read its generation', async () => {
    const user = await member();
    const wrapped = new Proxy(env.DB, { get(target, property) {
      if (property === 'prepare') return (sql: string) => {
        const statement = target.prepare(sql);
        if (!sql.includes('INSERT INTO intervals_oauth_states')) return statement;
        const wrap = (inner: D1PreparedStatement): D1PreparedStatement => new Proxy(inner, { get(item, key) {
          if (key === 'bind') return (...values: unknown[]) => wrap(item.bind(...values));
          if (key === 'run') return async () => {
            await setUserIntervalsCreds(env.DB, user.id, env.CREDENTIAL_ENCRYPTION_KEY, null, null);
            return item.run();
          };
          const value = Reflect.get(item, key);
          return typeof value === 'function' ? value.bind(item) : value;
        } });
        return wrap(statement);
      };
      const value = Reflect.get(target, property);
      return typeof value === 'function' ? value.bind(target) : value;
    } });
    await expect(createIntervalsOAuthState(wrapped, user.id)).rejects.toThrow('intervals_connection_changed');
    expect(await env.DB.prepare('SELECT COUNT(*) AS count FROM intervals_oauth_states WHERE user_id=?1')
      .bind(user.id).first()).toEqual({ count: 0 });
    expect((await getIntervalsConnectionStatus(env.DB, user.id)).connected).toBe(false);
  });

  it('rejects an unbound OAuth state created by an older Worker', async () => {
    const user = await member(), state = crypto.randomUUID();
    await env.DB.prepare('INSERT INTO intervals_oauth_states(state,user_id,created_at,expires_at) VALUES(?1,?2,1,?3)')
      .bind(state, user.id, Date.now() + 60_000).run();
    expect(await consumeIntervalsOAuthAttempt(env.DB, state)).toBeNull();
    expect((await getIntervalsConnectionStatus(env.DB, user.id)).credential_generation).toBe(0);
  });

  it('cancels pending OAuth intents on disconnect and rejects consumed callbacks that cross a credential change', async () => {
    const user = await member();
    const pending = await createIntervalsOAuthState(env.DB, user.id);
    const consumed = await consumeIntervalsOAuthAttempt(env.DB, await createIntervalsOAuthState(env.DB, user.id));
    expect(consumed).toMatchObject({ user_id: user.id, credential_generation: 0 });
    await setUserIntervalsCreds(env.DB, user.id, env.CREDENTIAL_ENCRYPTION_KEY, null, null);
    expect(await consumeIntervalsOAuthAttempt(env.DB, pending)).toBeNull();
    expect(await setUserIntervalsOAuth(env.DB, user.id, env.CREDENTIAL_ENCRYPTION_KEY, 'late-token', null, null, 'late-athlete', consumed!.credential_generation)).toBeNull();
    expect((await getIntervalsConnectionStatus(env.DB, user.id)).connected).toBe(false);
  });
});
