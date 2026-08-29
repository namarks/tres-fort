import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';

const BASE = 'https://tres-fort.test';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

async function pkce() {
  const verifier = 'verifier-' + crypto.randomUUID() + crypto.randomUUID();
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier));
  const challenge = btoa(String.fromCharCode(...new Uint8Array(digest)))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
  return { verifier, challenge };
}

describe('oauth discovery', () => {
  it('protected-resource metadata points at the AS', async () => {
    const r = await SELF.fetch(`${BASE}/.well-known/oauth-protected-resource`);
    expect(r.status).toBe(200);
    const j = await r.json<any>();
    expect(j.resource).toBe(`${BASE}/mcp`);
    expect(j.authorization_servers).toEqual([BASE]);
    expect(r.headers.get('access-control-allow-origin')).toBe('*');
  });

  it('AS metadata advertises PKCE + endpoints', async () => {
    const j = await (await SELF.fetch(`${BASE}/.well-known/oauth-authorization-server`)).json<any>();
    expect(j.issuer).toBe(BASE);
    expect(j.authorization_endpoint).toBe(`${BASE}/oauth/authorize`);
    expect(j.token_endpoint).toBe(`${BASE}/oauth/token`);
    expect(j.registration_endpoint).toBe(`${BASE}/oauth/register`);
    expect(j.code_challenge_methods_supported).toEqual(['S256']);
  });
});

describe('oauth full PKCE flow', () => {
  it('register -> authorize (passphrase) -> token -> call /mcp -> refresh', async () => {
    const redirect = 'https://claude.ai/api/mcp/auth_callback';

    // 1. dynamic client registration
    const reg = await SELF.fetch(`${BASE}/oauth/register`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ redirect_uris: [redirect], client_name: 'Claude' }),
    });
    expect(reg.status).toBe(201);
    const { client_id } = await reg.json<{ client_id: string }>();

    const { verifier, challenge } = await pkce();
    const authUrl =
      `${BASE}/oauth/authorize?response_type=code&client_id=${client_id}` +
      `&redirect_uri=${encodeURIComponent(redirect)}&code_challenge=${challenge}` +
      `&code_challenge_method=S256&state=xyz&scope=mcp`;

    // 2a. consent page renders
    const page = await SELF.fetch(authUrl);
    expect(page.status).toBe(200);
    expect(await page.text()).toContain('passphrase');

    // 2b. wrong passphrase is rejected
    const bad = new FormData();
    bad.set('client_id', client_id);
    bad.set('redirect_uri', redirect);
    bad.set('code_challenge', challenge);
    bad.set('state', 'xyz');
    bad.set('scope', 'mcp');
    bad.set('passphrase', 'nope');
    const badRes = await SELF.fetch(`${BASE}/oauth/authorize`, { method: 'POST', body: bad });
    expect(badRes.status).toBe(401);

    // 2c. correct passphrase -> 302 with code
    const good = new FormData();
    good.set('client_id', client_id);
    good.set('redirect_uri', redirect);
    good.set('code_challenge', challenge);
    good.set('state', 'xyz');
    good.set('scope', 'mcp');
    good.set('passphrase', 'test-pass');
    const authRes = await SELF.fetch(`${BASE}/oauth/authorize`, {
      method: 'POST',
      body: good,
      redirect: 'manual',
    });
    expect(authRes.status).toBe(302);
    const loc = new URL(authRes.headers.get('location')!);
    expect(loc.searchParams.get('state')).toBe('xyz');
    const code = loc.searchParams.get('code')!;
    expect(code).toBeTruthy();

    // 3. token exchange with PKCE verifier
    const tokForm = new FormData();
    tokForm.set('grant_type', 'authorization_code');
    tokForm.set('code', code);
    tokForm.set('redirect_uri', redirect);
    tokForm.set('client_id', client_id);
    tokForm.set('code_verifier', verifier);
    const tok = await SELF.fetch(`${BASE}/oauth/token`, { method: 'POST', body: tokForm });
    expect(tok.status).toBe(200);
    const t = await tok.json<{ access_token: string; refresh_token: string; token_type: string }>();
    expect(t.token_type).toBe('Bearer');

    // 3b. the code is single-use
    const replay = await SELF.fetch(`${BASE}/oauth/token`, { method: 'POST', body: tokForm });
    expect(replay.status).toBe(400);

    // 4. OAuth access token is accepted at /mcp
    const mcp = await SELF.fetch(`${BASE}/mcp`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', Authorization: `Bearer ${t.access_token}` },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list' }),
    });
    expect(mcp.status).toBe(200);
    expect((await mcp.json<any>()).result.tools.length).toBe(34);

    // 5. refresh rotates the token
    const rf = new FormData();
    rf.set('grant_type', 'refresh_token');
    rf.set('refresh_token', t.refresh_token);
    const refreshed = await SELF.fetch(`${BASE}/oauth/token`, { method: 'POST', body: rf });
    expect(refreshed.status).toBe(200);
    const t2 = await refreshed.json<{ access_token: string }>();
    expect(t2.access_token).not.toBe(t.access_token);

    const mcp2 = await SELF.fetch(`${BASE}/mcp`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', Authorization: `Bearer ${t2.access_token}` },
      body: JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'ping' }),
    });
    expect(mcp2.status).toBe(200);
  });

  it('rejects a tampered PKCE verifier', async () => {
    const redirect = 'https://claude.ai/cb';
    const { client_id } = await (
      await SELF.fetch(`${BASE}/oauth/register`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ redirect_uris: [redirect] }),
      })
    ).json<{ client_id: string }>();
    const { challenge } = await pkce();
    const form = new FormData();
    form.set('client_id', client_id);
    form.set('redirect_uri', redirect);
    form.set('code_challenge', challenge);
    form.set('scope', 'mcp');
    form.set('passphrase', 'test-pass');
    const authRes = await SELF.fetch(`${BASE}/oauth/authorize`, {
      method: 'POST',
      body: form,
      redirect: 'manual',
    });
    const code = new URL(authRes.headers.get('location')!).searchParams.get('code')!;
    const tok = new FormData();
    tok.set('grant_type', 'authorization_code');
    tok.set('code', code);
    tok.set('redirect_uri', redirect);
    tok.set('client_id', client_id);
    tok.set('code_verifier', 'wrong-verifier');
    const r = await SELF.fetch(`${BASE}/oauth/token`, { method: 'POST', body: tok });
    expect(r.status).toBe(400);
  });
});
