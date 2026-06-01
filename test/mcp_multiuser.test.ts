import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { createPlan, findUserByMcpPassphrase, setUserMcpPassphrase } from '../src/db';
import type { Env } from '../src/types';

// M3 (multi-tenant MCP): the /mcp bearer resolves to a SPECIFIC user.
//  - static MCP_STATIC_TOKEN  → the owner (Claude Code / curl).
//  - OAuth access token       → the user bound at /oauth/authorize.
// A non-owner authenticates /authorize with their per-user passphrase and gets
// a token scoped to THEM; they must see only their own data (owner-isolation).

const BASE = 'https://tres-fort.test';
const STATIC_TOKEN = 'test-mcp-token';
const OWNER_PASS = 'test-pass'; // = OWNER_AUTH_PASSPHRASE in vitest.config

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

let rpcId = 0;
async function mcp(token: string, name: string, args: unknown = {}) {
  const r = await SELF.fetch(`${BASE}/mcp`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify({ jsonrpc: '2.0', id: ++rpcId, method: 'tools/call', params: { name, arguments: args } }),
  });
  const body = await r.json<any>().catch(() => null);
  return { status: r.status, json: body?.result ? JSON.parse(body.result.content[0].text) : body };
}

async function s256(verifier: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier));
  return btoa(String.fromCharCode(...new Uint8Array(digest)))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

const REDIRECT = 'https://claude.ai/callback';

/** Full PKCE authorize→token flow with the given passphrase. Returns the
 *  access_token, or the authorize HTTP status when the passphrase is rejected. */
async function oauthConnect(passphrase: string): Promise<{ token?: string; authorizeStatus: number }> {
  const reg = await (
    await SELF.fetch(`${BASE}/oauth/register`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ redirect_uris: [REDIRECT], client_name: 'test' }),
    })
  ).json<{ client_id: string }>();

  const verifier = 'verifier-' + Math.random().toString(36).slice(2) + 'padpadpadpadpad';
  const challenge = await s256(verifier);

  const form = new URLSearchParams({
    client_id: reg.client_id,
    redirect_uri: REDIRECT,
    code_challenge: challenge,
    code_challenge_method: 'S256',
    state: 'xyz',
    scope: 'mcp',
    passphrase,
  });
  const authResp = await SELF.fetch(`${BASE}/oauth/authorize`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: form.toString(),
    redirect: 'manual',
  });
  if (authResp.status !== 302) return { authorizeStatus: authResp.status };
  const code = new URL(authResp.headers.get('location')!).searchParams.get('code')!;

  const tokenResp = await (
    await SELF.fetch(`${BASE}/oauth/token`, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'authorization_code',
        code,
        client_id: reg.client_id,
        redirect_uri: REDIRECT,
        code_verifier: verifier,
      }).toString(),
    })
  ).json<{ access_token: string }>();
  return { token: tokenResp.access_token, authorizeStatus: 302 };
}

describe('mcp multi-tenant auth (M3)', () => {
  it('routes each principal to its own user and isolates data across users', async () => {
    // Owner created via dev auth (earliest row → the owner), with an owner plan.
    const ownerJwt = (
      await (
        await SELF.fetch(`${BASE}/auth/dev`, {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ secret: 'test-dev' }),
        })
      ).json<{ jwt: string; user: { id: string } }>()
    );
    await SELF.fetch(`${BASE}/api/plan`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', Authorization: `Bearer ${ownerJwt.jwt}` },
      body: JSON.stringify({ name: 'Owner Plan' }),
    });

    // A SECOND user ("dad"), created AFTER the owner so the owner stays
    // earliest-by-created_at. Seed his own plan + a personal MCP passphrase.
    const dadId = crypto.randomUUID();
    await env.DB.prepare(
      'INSERT INTO users (id, apple_sub, display_name, created_at) VALUES (?1,?2,?3,?4)',
    )
      .bind(dadId, 'apple-dad', 'Dad', Date.now() + 10_000)
      .run();
    await createPlan(env.DB as unknown as D1Database, dadId, 'Dad Plan');
    await setUserMcpPassphrase(env.DB as unknown as D1Database, dadId, 'dad-passphrase');

    // 1. Static token → owner.
    const ownerStatic = await mcp(STATIC_TOKEN, 'get_current_plan');
    expect(ownerStatic.json.name).toBe('Owner Plan');

    // 2. OAuth with the OWNER passphrase → owner.
    const ownerOauth = await oauthConnect(OWNER_PASS);
    expect(ownerOauth.token).toBeTruthy();
    expect((await mcp(ownerOauth.token!, 'get_current_plan')).json.name).toBe('Owner Plan');

    // 3. OAuth with DAD's passphrase → dad. THE ISOLATION GUARANTEE.
    const dadOauth = await oauthConnect('dad-passphrase');
    expect(dadOauth.token).toBeTruthy();
    const dadView = await mcp(dadOauth.token!, 'get_current_plan');
    expect(dadView.json.name).toBe('Dad Plan');
    expect(dadView.json.name).not.toBe('Owner Plan');

    // …and the static (owner) token still sees ONLY the owner's plan.
    expect((await mcp(STATIC_TOKEN, 'get_current_plan')).json.name).toBe('Owner Plan');

    // 4. Wrong passphrase → authorize rejects (401), no token issued.
    const bad = await oauthConnect('not-a-real-passphrase');
    expect(bad.authorizeStatus).toBe(401);
    expect(bad.token).toBeUndefined();

    // 5. Bad bearer → 401 from /mcp.
    expect((await mcp('garbage-token', 'get_current_plan')).status).toBe(401);
  });

  it('back-compat: a pre-M3 token (user_id NULL) resolves to the owner', async () => {
    // Ensure the owner exists + has a plan (storage is isolated per test).
    const jwt = (
      await (
        await SELF.fetch(`${BASE}/auth/dev`, {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ secret: 'test-dev' }),
        })
      ).json<{ jwt: string }>()
    ).jwt;
    await SELF.fetch(`${BASE}/api/plan`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', Authorization: `Bearer ${jwt}` },
      body: JSON.stringify({ name: 'Owner Plan' }),
    });
    // Insert a legacy token row with NO user_id, as the old flow would have.
    const legacy = 'legacy-token-' + crypto.randomUUID().replace(/-/g, '');
    await env.DB.prepare(
      'INSERT INTO oauth_tokens (access_token, refresh_token, client_id, scope, expires_at, created_at) VALUES (?1,?2,?3,?4,?5,?6)',
    )
      .bind(legacy, 'r-' + legacy, 'c', 'mcp', Math.floor(Date.now() / 1000) + 3600, Math.floor(Date.now() / 1000))
      .run();
    const res = await mcp(legacy, 'get_current_plan');
    expect(res.status).toBe(200);
    expect(res.json.name).toBe('Owner Plan');
  });

  // Codex P1 (#63): a passphrase shared by two users would let the second
  // user's OAuth token resolve to the FIRST user's account at /authorize.
  it('rejects an MCP passphrase already used by another user (no cross-user binding)', async () => {
    const D = env.DB as unknown as D1Database;
    const aId = crypto.randomUUID();
    const bId = crypto.randomUUID();
    await env.DB.prepare('INSERT INTO users (id, apple_sub, display_name, created_at) VALUES (?1,?2,?3,?4)')
      .bind(aId, 'apple-a', 'A', Date.now()).run();
    await env.DB.prepare('INSERT INTO users (id, apple_sub, display_name, created_at) VALUES (?1,?2,?3,?4)')
      .bind(bId, 'apple-b', 'B', Date.now() + 1000).run();

    // A claims it.
    expect(await setUserMcpPassphrase(D, aId, 'shared-secret-x')).toEqual({ ok: true });
    // B cannot take the same passphrase.
    expect(await setUserMcpPassphrase(D, bId, 'shared-secret-x')).toEqual({ error: 'passphrase_taken' });
    // The resolver maps it to A only — B never gets bound to A.
    expect(await findUserByMcpPassphrase(D, 'shared-secret-x')).toBe(aId);
    // A may re-set its OWN passphrase to the same value.
    expect(await setUserMcpPassphrase(D, aId, 'shared-secret-x')).toEqual({ ok: true });
    // B keeps its own distinct passphrase fine.
    expect(await setUserMcpPassphrase(D, bId, 'b-distinct-secret')).toEqual({ ok: true });
    expect(await findUserByMcpPassphrase(D, 'b-distinct-secret')).toBe(bId);

    // The env OWNER_AUTH_PASSPHRASE is reserved: a personal passphrase equal to
    // it would resolve to the owner at /authorize (which checks the env secret
    // first), so set-time must reject it (Codex #64 P2).
    expect(await setUserMcpPassphrase(D, bId, 'owner-env-secret', 'owner-env-secret'))
      .toEqual({ error: 'passphrase_taken' });
  });
});
