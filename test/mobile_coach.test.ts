import { applyD1Migrations, env, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { issueAppJwt } from '../src/auth';
import { decideMobileCoachRequest, purgeExpiredMobileCoachRequests } from '../src/db';

const BASE = 'https://tres-fort.test';
const CALLBACK = 'https://chatgpt.com/connector/oauth/test-callback';
const MEMBER = 'bdc038e2-d217-4976-b2e9-b248e1c34394';
let jwt: string;
beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
  await env.DB.prepare('INSERT INTO users (id, apple_sub, created_at) VALUES (?1, ?2, ?3)')
    .bind(MEMBER, 'mobile-test-member', Date.now()).run();
  jwt = await issueAppJwt(MEMBER, env.APP_JWT_SECRET);
});

async function request(overrides: Record<string, string> = {}) {
  const registered = await SELF.fetch(`${BASE}/oauth/register`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ client_name: '<Unverified app>', redirect_uris: [CALLBACK] }),
  });
  const { client_id } = await registered.json<{ client_id: string }>();
  const verifier = crypto.randomUUID() + crypto.randomUUID();
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier));
  const challenge = btoa(String.fromCharCode(...new Uint8Array(digest)))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  const params = new URLSearchParams({ client_id, redirect_uri: CALLBACK,
    response_type: 'code', code_challenge_method: 'S256', code_challenge: challenge,
    resource: `${BASE}/mcp`, scope: 'mcp', state: 'mobile-state&literal', ...overrides });
  const page = await SELF.fetch(`${BASE}/oauth/authorize?${params}`);
  const html = await page.text();
  const id = /https:\/\/tresfort.app\/coach\/authorize\?request=([a-f0-9]{64})/.exec(html)?.[1];
  return { page, html, id: id!, client_id, verifier };
}

function decision(id: string, value: unknown, token = jwt) {
  return SELF.fetch(`${BASE}/api/coach-requests/${id}`, {
    method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(value),
  });
}

async function exchange(id: string, client: Awaited<ReturnType<typeof request>>, verifier = client.verifier) {
  return SELF.fetch(`${BASE}/oauth/token`, { method: 'POST', body: new URLSearchParams({
    grant_type: 'authorization_code', client_id: client.client_id, redirect_uri: CALLBACK,
    code: id, code_verifier: verifier, resource: `${BASE}/mcp`,
  }) });
}

describe('mobile coach approval', () => {
  it('requires app authentication, discloses the registered destination and never exposes the PKCE challenge', async () => {
    const r = await request();
    expect(r.id).toMatch(/^[a-f0-9]{64}$/);
    expect(r.page.headers.get('cache-control')).toBe('no-store');
    expect(r.page.headers.get('referrer-policy')).toBe('no-referrer');
    expect(r.html).toContain('&lt;Unverified app&gt;');
    expect((await SELF.fetch(`${BASE}/api/coach-requests/${r.id}`)).status).toBe(401);
    const preview = await SELF.fetch(`${BASE}/api/coach-requests/${r.id}`, {
      headers: { Authorization: `Bearer ${jwt}` },
    });
    expect(preview.status).toBe(200);
    expect(await preview.json()).toEqual({
      client_name: '<Unverified app>', redirect_uri: CALLBACK, expires_at: expect.any(Number),
    });
    expect((await env.DB.prepare('SELECT COUNT(*) AS n FROM oauth_codes').first('n'))).toBe(0);
  });

  it('binds approval to the signed-in member, requires PKCE, and consumes the request and code once', async () => {
    const r = await request();
    const approved = await decision(r.id, { decision: 'allow' });
    expect(approved.status).toBe(200);
    const result = await approved.json<{ allowed: boolean; redirect_uri: string }>();
    expect(result.allowed).toBe(true);
    const callback = new URL(result.redirect_uri);
    expect(callback.origin + callback.pathname).toBe(CALLBACK);
    expect(callback.searchParams.get('state')).toBe('mobile-state&literal');
    const code = callback.searchParams.get('code')!;
    expect(await env.DB.prepare('SELECT user_id FROM oauth_codes WHERE code = ?1').bind(code).first('user_id')).toBe(MEMBER);
    expect((await exchange(code, r, 'wrong-verifier')).status).toBe(400);
    const token = await exchange(code, r);
    expect(token.status).toBe(200);
    const { access_token } = await token.json<{ access_token: string }>();
    expect(await env.DB.prepare('SELECT user_id FROM oauth_tokens WHERE access_token = ?1').bind(access_token).first('user_id')).toBe(MEMBER);
    expect((await exchange(code, r)).status).toBe(400);
    expect((await decision(r.id, { decision: 'allow' })).status).toBe(410);
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM audit_log WHERE user_id = ?1 AND tool = 'approve_coach_connection'").bind(MEMBER).first('n')).toBe(1);
  });

  it('disconnects an approved connection before its code is exchanged', async () => {
    const r = await request();
    const approved = await decision(r.id, { decision: 'allow' });
    const result = await approved.json<{ redirect_uri: string }>();
    const code = new URL(result.redirect_uri).searchParams.get('code')!;
    const disconnected = await SELF.fetch(`${BASE}/api/me/coach-grants`, {
      method: 'DELETE', headers: { Authorization: `Bearer ${jwt}` },
    });
    expect(disconnected.status).toBe(200);
    expect((await exchange(code, r)).status).toBe(400);
  });

  it('denies once without issuing any code', async () => {
    const r = await request();
    const denied = await decision(r.id, { decision: 'deny' });
    expect(denied.status).toBe(200);
    const result = await denied.json<{ allowed: boolean; redirect_uri: string }>();
    expect(result.allowed).toBe(false);
    const url = new URL(result.redirect_uri);
    expect(url.searchParams.get('error')).toBe('access_denied');
    expect(url.searchParams.get('code')).toBeNull();
    expect((await decision(r.id, { decision: 'allow' })).status).toBe(410);
    expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM oauth_codes').first('n')).toBe(0);
  });

  it('has exactly one winner when allow and deny race', async () => {
    const r = await request();
    const results = await Promise.all([
      decision(r.id, { decision: 'allow' }), decision(r.id, { decision: 'deny' }),
      decision(r.id, { decision: 'allow' }),
    ]);
    expect(results.map(r => r.status).sort()).toEqual([200, 410, 410]);
    expect(Number(await env.DB.prepare('SELECT COUNT(*) AS n FROM oauth_codes').first('n'))).toBeLessThanOrEqual(1);
  });

  it('rejects expiry, unknown IDs and callback/account overrides without consuming a valid request', async () => {
    const r = await request();
    for (const value of [null, {}, { decision: 'yes' }, { decision: 'allow', user_id: 'owner' },
      { decision: 'allow', redirect_uri: 'https://attacker.test' }]) {
      expect((await decision(r.id, value)).status).toBe(400);
    }
    expect((await decision('0'.repeat(64), { decision: 'allow' })).status).toBe(410);
    await env.DB.prepare('UPDATE oauth_mobile_requests SET expires_at = 0 WHERE id = ?1').bind(r.id).run();
    expect((await decision(r.id, { decision: 'allow' })).status).toBe(410);
    expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM oauth_codes').first('n')).toBe(0);
  });

  it('fences approval as soon as account deletion starts and removes expired navigation', async () => {
    const r = await request();
    await env.DB.prepare(`INSERT INTO account_deletion_intents
      (user_id, idempotency_key_sha256, apple_revocation, created_at)
      VALUES (?1, 'synthetic-digest', NULL, ?2)`).bind(MEMBER, Date.now()).run();
    expect(await decideMobileCoachRequest(env.DB, r.id, MEMBER, true)).toBeNull();
    expect((await decision(r.id, { decision: 'allow' })).status).toBe(401);
    const expired = await request();
    await env.DB.prepare('UPDATE oauth_mobile_requests SET expires_at = 0 WHERE id = ?1').bind(expired.id).run();
    await purgeExpiredMobileCoachRequests(env.DB);
    expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM oauth_mobile_requests WHERE id = ?1').bind(expired.id).first('n')).toBe(0);
    expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM oauth_mobile_requests WHERE id = ?1').bind(r.id).first('n')).toBe(1);
  });

  it('cannot approve with a missing/deleted principal even at the service write boundary', async () => {
    const r = await request();
    expect(await decideMobileCoachRequest(env.DB, r.id, 'absent-account', true)).toBeNull();
    await env.DB.prepare('DELETE FROM users WHERE id = ?1').bind(MEMBER).run();
    expect(await decideMobileCoachRequest(env.DB, r.id, MEMBER, true)).toBeNull();
    expect((await decision(r.id, { decision: 'allow' })).status).toBe(401);
    expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM oauth_codes').first('n')).toBe(0);
  });

  it.each<Record<string, string>>([{ resource: 'https://another-resource.test/mcp' }, { scope: 'admin' },
    { code_challenge: 'invalid' }])('does not offer mobile authorization for unsupported parameters %j', async (override) => {
    expect((await request(override)).id).toBeUndefined();
  });
});
