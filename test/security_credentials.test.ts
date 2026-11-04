import { env, applyD1Migrations, createExecutionContext, waitOnExecutionContext, fetchMock } from 'cloudflare:test';
import { afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { sign } from 'hono/jwt';
import worker from '../src/index';
import { issueAppJwt } from '../src/auth';
import { createCoachConnectCode, getUserIntervalsCreds, setUserIntervalsCreds, setUserIntervalsOAuth } from '../src/db';
import { credentialDigest, oauthTokenDigest, openCredential, sealCredential } from '../src/credentials';
import { validateBearer } from '../src/oauth';

beforeAll(async () => { await applyD1Migrations(env.DB, env.TEST_MIGRATIONS); });
beforeEach(() => { fetchMock.activate(); fetchMock.disableNetConnect(); });
const contexts: ExecutionContext[] = [];
async function settle() { await Promise.all(contexts.splice(0).map(waitOnExecutionContext)); }
afterEach(async () => { await settle(); fetchMock.deactivate(); });
async function request(path: string, jwt?: string, body?: object) {
  const ctx = createExecutionContext(); contexts.push(ctx);
  return worker.fetch(new Request(`https://security.test${path}`, {
    method: body ? 'POST' : 'GET', headers: { 'content-type': 'application/json', ...(jwt ? { Authorization: `Bearer ${jwt}` } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {}),
  }), env, ctx);
}
async function member() {
  const id = crypto.randomUUID();
  await env.DB.prepare('INSERT INTO users(id,apple_sub,created_at) VALUES (?1,?1,1)').bind(id).run();
  return { id, jwt: await issueAppJwt(id, env.APP_JWT_SECRET) };
}
async function pending(jwt: string) {
  const start = await request('/auth/intervals/start',jwt,{});
  const { authorize_url } = await start.json<{ authorize_url: string }>();
  const state = new URL(authorize_url).searchParams.get('state')!;
  fetchMock.get('https://intervals.icu').intercept({ path: '/api/oauth/token', method: 'POST' })
    .reply(200,{ access_token: 'victim-provider-secret', athlete: { id: 'victim-athlete' } });
  const callback = await request(`/auth/intervals/callback?code=victim-code&state=${state}`);
  expect(callback.status).toBe(302);
  return new URL(callback.headers.get('location')!).searchParams.get('completion')!;
}
function providerImport() {
  fetchMock.get('https://intervals.icu').intercept({ path: /\/api\/v1\/athlete\/victim-athlete\/activities\?/,
    headers: { authorization: 'Bearer victim-provider-secret' } }).reply(200,[]);
}
async function client() {
  const registered = await request('/oauth/register',undefined,{ redirect_uris: ['https://client.example/callback'] });
  const { client_id } = await registered.json<{ client_id: string }>();
  const verifier = 'v'.repeat(64);
  const digest = await crypto.subtle.digest('SHA-256',new TextEncoder().encode(verifier));
  const challenge = btoa(String.fromCharCode(...new Uint8Array(digest))).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
  return { client_id, verifier, challenge };
}
async function authorize(c: Awaited<ReturnType<typeof client>>, code: string) {
  const ctx = createExecutionContext(); contexts.push(ctx);
  return worker.fetch(new Request('https://security.test/oauth/authorize',{ method:'POST',body:new URLSearchParams({
    client_id:c.client_id,redirect_uri:'https://client.example/callback',code_challenge:c.challenge,
    code_challenge_method:'S256',scope:'mcp',passphrase:code,
  }) }),env,ctx);
}
async function exchange(c: Awaited<ReturnType<typeof client>>, response: Response) {
  const code = new URL(response.headers.get('location')!).searchParams.get('code')!;
  const ctx = createExecutionContext(); contexts.push(ctx);
  const result = await worker.fetch(new Request('https://security.test/oauth/token',{ method:'POST',body:new URLSearchParams({
    grant_type:'authorization_code',code,client_id:c.client_id,redirect_uri:'https://client.example/callback',code_verifier:c.verifier,
  }) }),env,ctx);
  expect(result.status).toBe(200);
  return result.json<{ access_token: string; refresh_token: string }>();
}

describe('SEC-01: authenticated Intervals completion', () => {
  it('cannot activate a forwarded URL in another member or session, and only the original session can finish once', async () => {
    const a = await member(), b = await member(), completion = await pending(a.jwt);
    expect(completion).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect((await getUserIntervalsCreds(env.DB,a.id,env.CREDENTIAL_ENCRYPTION_KEY)).access_token).toBeNull();
    const row = await env.DB.prepare('SELECT * FROM intervals_oauth_completions').first();
    expect(JSON.stringify(row)).not.toContain('victim-provider-secret');
    expect(JSON.stringify(row)).not.toContain(completion);
    expect((await request('/auth/intervals/finish',undefined,{completion})).status).toBe(401);
    expect((await request('/auth/intervals/finish',b.jwt,{completion})).status).toBe(400);
    expect((await request('/auth/intervals/finish',await issueAppJwt(a.id,env.APP_JWT_SECRET),{completion})).status).toBe(400);
    expect((await request('/auth/intervals/finish',a.jwt,{completion:'wrong'})).status).toBe(400);
    providerImport();
    expect((await request('/auth/intervals/finish',a.jwt,{completion})).status).toBe(200);
    await settle();
    expect((await getUserIntervalsCreds(env.DB,a.id,env.CREDENTIAL_ENCRYPTION_KEY)).access_token).toBe('victim-provider-secret');
    expect((await request('/auth/intervals/finish',a.jwt,{completion})).status).toBe(400);
    expect((await getUserIntervalsCreds(env.DB,b.id,env.CREDENTIAL_ENCRYPTION_KEY)).access_token).toBeNull();
  });

  it.each(['logout','disconnect','expiry'] as const)('cannot finish after %s', async (change) => {
    const a = await member(), completion = await pending(a.jwt);
    if (change === 'logout') expect((await request('/auth/logout',a.jwt,{})).status).toBe(200);
    if (change === 'disconnect') await setUserIntervalsCreds(env.DB,a.id,env.CREDENTIAL_ENCRYPTION_KEY,null,null);
    if (change === 'expiry') await env.DB.prepare('UPDATE intervals_oauth_completions SET expires_at=1').run();
    expect((await request('/auth/intervals/finish',a.jwt,{completion})).status).toBe(change === 'logout' ? 401 : 400);
    expect((await getUserIntervalsCreds(env.DB,a.id,env.CREDENTIAL_ENCRYPTION_KEY)).access_token).toBeNull();
  });

  it('serializes concurrent completion attempts into a single credential activation', async () => {
    const a = await member(), completion = await pending(a.jwt);
    providerImport();
    const responses = await Promise.all([request('/auth/intervals/finish',a.jwt,{completion}),request('/auth/intervals/finish',a.jwt,{completion})]);
    expect(responses.map(r=>r.status).sort()).toEqual([200,400]);
    await settle();
    expect((await getUserIntervalsCreds(env.DB,a.id,env.CREDENTIAL_ENCRYPTION_KEY)).credential_generation).toBe(1);
  });
});

describe('SEC-02: server-issued coach codes', () => {
  it('rejects caller-chosen passwords and consumes a generated member-bound code once', async () => {
    const a = await member(), c = await client();
    expect((await request('/api/me/mcp-passphrase',a.jwt,{passphrase:'password1'})).status).toBe(400);
    const created = await request('/api/me/mcp-passphrase',a.jwt,{});
    expect(created.headers.get('cache-control')).toBe('no-store');
    const {code} = await created.json<{code:string}>();
    expect(code).toMatch(/^[A-Za-z0-9_-]{43}$/);
    const stored = await env.DB.prepare('SELECT code_sha256 FROM coach_connect_codes WHERE user_id=?1').bind(a.id).first<{code_sha256:string}>();
    expect(stored!.code_sha256).toBe(await credentialDigest(code));
    const accepted = await authorize(c,code);
    expect(accepted.status).toBe(302);
    const tokens = await exchange(c,accepted);
    expect(await validateBearer(env,tokens.access_token)).toBe(a.id);
    expect((await authorize(c,code)).status).toBe(401);
  });

  it('rejects legacy owner passwords, expired codes and replaced codes', async () => {
    const a = await member(), c = await client();
    expect((await authorize(c,env.OWNER_AUTH_PASSPHRASE)).status).toBe(401);
    const first = await createCoachConnectCode(env.DB,a.id), second = await createCoachConnectCode(env.DB,a.id);
    expect((await authorize(c,first.code)).status).toBe(401);
    await env.DB.prepare('UPDATE coach_connect_codes SET expires_at=1').run();
    expect((await authorize(c,second.code)).status).toBe(401);
  });

  it('limits guesses across OAuth client registrations and resets only in a new time window', async () => {
    const c = await client();
    for (let i=0;i<10;i++) expect((await authorize(c,'password1')).status).toBe(401);
    const blocked = await authorize(await client(),'password1');
    expect(blocked.status).toBe(429);
    expect(Number(blocked.headers.get('retry-after'))).toBeGreaterThan(0);
    await env.DB.prepare('UPDATE auth_rate_limits SET window_start=1').run();
    expect((await authorize(c,'password1')).status).toBe(401);
  });
});

describe('SEC-03: session revocation', () => {
  it.each(['ios','web'] as const)('revokes a valid successor using an expired original %s token, only at logout', async client => {
    const a = await member(), now = Math.floor(Date.now()/1000), day = 86400;
    const sessionId = 's'.repeat(43), authTimeSeconds = now - 61*day;
    const original = await issueAppJwt(a.id,env.APP_JWT_SECRET,{client,sessionId,nowSeconds:authTimeSeconds});
    // The copied bearer was renewed before the original expired.
    const successor = await issueAppJwt(a.id,env.APP_JWT_SECRET,{client,sessionId,authTimeSeconds,nowSeconds:now-2*day});
    expect((await request('/api/me',successor)).status).toBe(200);
    expect((await request('/api/me',original)).status).toBe(401);
    expect((await request('/auth/renew',original,{})).status).toBe(401);
    const tampered = original.slice(0,original.lastIndexOf('.')+1) + 'invalid-signature';
    expect((await request('/auth/logout',tampered,{})).status).toBe(401);
    expect((await request('/api/me',successor)).status).toBe(200);
    expect((await request('/auth/logout',original,{})).status).toBe(200);
    expect((await request('/api/me',successor)).status).toBe(401);
    expect((await request('/auth/renew',successor,{})).status).toBe(401);
    expect((await request('/api/me',a.jwt)).status).toBe(200);
  });

  it.each([false,true])('revokes original and renewed bearers together (legacy=%s), without revoking another session', async (legacy) => {
    const a=await member(),b=await member();
    const now=Math.floor(Date.now()/1000);
    const token=legacy ? await sign({sub:a.id,iat:now,exp:now+600},env.APP_JWT_SECRET,'HS256') : a.jwt;
    const other=await issueAppJwt(a.id,env.APP_JWT_SECRET);
    const renewal=await request('/auth/renew',token,{});
    const renewed=(await renewal.json<{jwt:string}>()).jwt;
    expect((await request('/auth/logout',renewed,{})).status).toBe(200);
    for(const bearer of [token,renewed]) {
      expect((await request('/api/me',bearer)).status).toBe(401);
      expect((await request('/auth/renew',bearer,{})).status).toBe(401);
    }
    expect((await request('/api/me',other)).status).toBe(200);
    expect((await request('/api/me',b.jwt)).status).toBe(200);
  });
});

describe('SEC-04: credential storage', () => {
  it('stores token digests that cannot themselves authenticate or refresh', async () => {
    const a=await member(),c=await client(),code=await createCoachConnectCode(env.DB,a.id);
    const tokens=await exchange(c,await authorize(c,code.code));
    const row=await env.DB.prepare('SELECT access_token,refresh_token FROM oauth_tokens WHERE user_id=?1').bind(a.id)
      .first<{access_token:string;refresh_token:string}>();
    expect(row!.access_token).toBe(await oauthTokenDigest(tokens.access_token));
    expect(row!.refresh_token).toBe(await oauthTokenDigest(tokens.refresh_token));
    expect(await validateBearer(env,row!.access_token)).toBeNull();
    const ctx=createExecutionContext();contexts.push(ctx);
    const refresh=await worker.fetch(new Request('https://security.test/oauth/token',{method:'POST',body:new URLSearchParams({
      grant_type:'refresh_token',client_id:c.client_id,refresh_token:row!.refresh_token,
    })}),env,ctx);
    expect(refresh.status).toBe(400);
    expect(await validateBearer(env,tokens.access_token)).toBe(a.id);
  });

  it('encrypts provider credentials with account and purpose binding, and preserves identical-retry generation', async () => {
    const a=await member();
    await setUserIntervalsOAuth(env.DB,a.id,env.CREDENTIAL_ENCRYPTION_KEY,'access-secret','refresh-secret',null,'athlete');
    const stored=await env.DB.prepare('SELECT intervals_oauth_access_token AS token FROM users WHERE id=?1').bind(a.id).first<{token:string}>();
    expect(stored!.token).toMatch(/^sealed:v1:/);
    expect(stored!.token).not.toContain('access-secret');
    expect(await openCredential(stored!.token,env.CREDENTIAL_ENCRYPTION_KEY,a.id,'intervals-access-token')).toBe('access-secret');
    await expect(openCredential(stored!.token,env.CREDENTIAL_ENCRYPTION_KEY,'another','intervals-access-token')).rejects.toThrow('credential_decryption_failed');
    await expect(openCredential(stored!.token,env.CREDENTIAL_ENCRYPTION_KEY,a.id,'intervals-refresh-token')).rejects.toThrow('credential_decryption_failed');
    await expect(sealCredential('secret',undefined,a.id,'test')).rejects.toThrow('credential_encryption_unavailable');
    await setUserIntervalsOAuth(env.DB,a.id,env.CREDENTIAL_ENCRYPTION_KEY,'access-secret','refresh-secret',null,'athlete');
    expect((await getUserIntervalsCreds(env.DB,a.id,env.CREDENTIAL_ENCRYPTION_KEY)).credential_generation).toBe(1);
    await env.DB.prepare('UPDATE credential_storage_policy SET enforced=1 WHERE id=1').run();
    await expect(env.DB.prepare("UPDATE users SET intervals_oauth_access_token='plaintext' WHERE id=?1").bind(a.id).run()).rejects.toThrow('plaintext_provider_credential');
  });
});
