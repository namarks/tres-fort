import { applyD1Migrations, env, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { issueAppJwt } from '../src/auth';
import { createPlan, setUserMcpPassphrase } from '../src/db';

const BASE = 'https://tres-fort.test';
const MEMBER = '74794029-c461-43b4-9021-5f29d544dc60';
const OTHER = '7a56e10e-4120-41d0-a1d1-f508f0c736aa';
const clients = [
  { name: 'Codex', redirect: 'http://127.0.0.1:45213/callback/tres-fort-test', registeredRedirect: 'http://127.0.0.1/callback/tres-fort-test' },
  { name: 'IPv6 native app', redirect: 'http://[::1]:45213/callback/tres-fort-test', registeredRedirect: 'http://[::1]/callback/tres-fort-test' },
  { name: 'Claude', redirect: 'https://claude.ai/api/mcp/auth_callback' },
  { name: 'Other AI app', redirect: 'http://127.0.0.1:39117/oauth/callback' },
];
type Connection = { access_token: string; refresh_token: string; client_id: string };
const connections = new Map<string, Connection>();
let otherConnection: Connection;
let jwt: string;
let otherJwt: string;

async function connect(name: string, redirect: string, passphrase: string, registeredRedirect = redirect): Promise<Connection> {
  const registration = await SELF.fetch(`${BASE}/oauth/register`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ client_name: name, redirect_uris: [registeredRedirect] }),
  });
  expect(registration.status).toBe(201);
  const { client_id } = await registration.json<{ client_id: string }>();
  const verifier = crypto.randomUUID() + crypto.randomUUID();
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier));
  const challenge = btoa(String.fromCharCode(...new Uint8Array(digest)))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  const params = new URLSearchParams({
    client_id, redirect_uri: redirect, response_type: 'code',
    code_challenge: challenge, code_challenge_method: 'S256', scope: 'mcp',
    resource: `${BASE}/mcp`, state: 'state&<literal>',
  });
  const page = await SELF.fetch(`${BASE}/oauth/authorize?${params}`);
  expect(page.status).toBe(200);
  const ipv6 = new URL(redirect).hostname.startsWith('[');
  expect(page.headers.get('Content-Security-Policy')).toContain(ipv6
    ? "form-action 'self';" : `form-action 'self' ${new URL(redirect).origin};`);
  const html = await page.text();
  expect(html).toContain('this app and its configured AI provider');
  expect(html).toContain('App name supplied by the connecting client');
  expect(html).toContain('value="state&amp;&lt;literal&gt;"');
  expect(html).not.toContain('operated by Anthropic');
  params.set('passphrase', passphrase);
  const authorized = await SELF.fetch(`${BASE}/oauth/authorize`, {
    method: 'POST', body: params, redirect: 'manual',
  });
  expect(authorized.status).toBe(ipv6 ? 200 : 302);
  expect(authorized.headers.get('Cache-Control')).toBe('no-store');
  expect(authorized.headers.get('Referrer-Policy')).toBe('no-referrer');
  let destination = authorized.headers.get('location');
  if (ipv6) {
    const navigation = await authorized.text();
    expect(navigation).toContain('<meta http-equiv="refresh"');
    expect(navigation).not.toContain('<script');
    destination = navigation.match(/<a href="([^"]+)"/)![1]!.replaceAll('&amp;', '&');
  }
  const callback = new URL(destination!);
  expect(callback.origin + callback.pathname).toBe(redirect);
  expect(callback.searchParams.get('state')).toBe('state&<literal>');
  if (registeredRedirect !== redirect) {
    // Port flexibility ends at consent: redemption stays bound to the exact
    // redirect URI the user authorized, including the chosen listener port.
    const wrongRedirect = await SELF.fetch(`${BASE}/oauth/token`, {
      method: 'POST', body: new URLSearchParams({
        grant_type: 'authorization_code', code: callback.searchParams.get('code')!,
        client_id, redirect_uri: registeredRedirect, code_verifier: verifier,
      }),
    });
    expect(wrongRedirect.status).toBe(400);
  }
  const exchanged = await SELF.fetch(`${BASE}/oauth/token`, {
    method: 'POST', body: new URLSearchParams({
      grant_type: 'authorization_code', code: callback.searchParams.get('code')!,
      client_id, redirect_uri: redirect, code_verifier: verifier,
    }),
  });
  expect(exchanged.status).toBe(200);
  return { ...(await exchanged.json<Omit<Connection, 'client_id'>>()), client_id };
}

async function rpc(access: string, method: string, params = {}) {
  return SELF.fetch(`${BASE}/mcp`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', Authorization: `Bearer ${access}` },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  });
}
async function tool(access: string, name: string, args = {}) {
  const response = await rpc(access, 'tools/call', { name, arguments: args });
  expect(response.status).toBe(200);
  const body = await response.json<any>();
  expect(body.result.isError).not.toBe(true);
  return JSON.parse(body.result.content[0].text);
}
async function profile(bearer = jwt) {
  return (await SELF.fetch(`${BASE}/api/me`, { headers: { Authorization: `Bearer ${bearer}` } })).json<any>();
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
  for (const userId of [MEMBER, OTHER]) {
    await env.DB.prepare('INSERT INTO users (id, apple_sub, created_at) VALUES (?1, ?2, ?3)')
      .bind(userId, `synthetic-${userId}`, Date.now()).run();
    await createPlan(env.DB, userId, userId === MEMBER ? 'Member plan' : 'Other private plan');
    await setUserMcpPassphrase(env.DB, userId, `synthetic-code-${userId}`);
  }
  jwt = await issueAppJwt(MEMBER, env.APP_JWT_SECRET);
  otherJwt = await issueAppJwt(OTHER, env.APP_JWT_SECRET);
  for (const client of clients) {
    connections.set(client.name, await connect(client.name, client.redirect, `synthetic-code-${MEMBER}`, client.registeredRedirect));
  }
  otherConnection = await connect('Another member’s app', 'http://127.0.0.1:41234/callback', `synthetic-code-${OTHER}`);
});

describe('external AI client compatibility', () => {
  it.each(clients)('$name initializes and reads the same account-scoped brief without mutations', async ({ name }) => {
    const access = connections.get(name)!.access_token;
    const initialized = await (await rpc(access, 'initialize', { protocolVersion: '2025-06-18' })).json<any>();
    expect(initialized.result.instructions).toContain('get_coach_brief');
    expect(initialized.result.instructions.slice(0, 512)).toContain('Do NOT call');
    const catalog = await (await rpc(access, 'tools/list')).json<any>();
    expect(catalog.result.tools.find((t: any) => t.name === 'get_coach_brief').annotations.readOnlyHint).toBe(true);
    for (const tool of catalog.result.tools) {
      expect(tool.annotations).toEqual({ readOnlyHint: expect.any(Boolean),
        destructiveHint: expect.any(Boolean), openWorldHint: false });
      if (tool.annotations.readOnlyHint) expect(tool.annotations.destructiveHint).toBe(false);
    }
    expect(catalog.result.tools.find((t: any) => t.name === 'update_plan').annotations)
      .toMatchObject({ readOnlyHint: false, destructiveHint: true });
    expect(catalog.result.tools.find((t: any) => t.name === 'log_set').annotations)
      .toMatchObject({ readOnlyHint: false, destructiveHint: true });
    expect(catalog.result.tools.find((t: any) => t.name === 'add_note').annotations)
      .toMatchObject({ readOnlyHint: false, destructiveHint: false });
    const before = await env.DB.prepare('SELECT COUNT(*) AS n FROM audit_log WHERE user_id = ?1').bind(MEMBER).first('n');
    const brief = await tool(access, 'get_coach_brief');
    expect(brief.brief).toContain('Member plan');
    expect(brief.brief).not.toContain('Other private plan');
    expect(brief.instructions).toContain('Do NOT call');
    const resource = await (await rpc(access, 'resources/read', { uri: 'coach://state/current' })).json<any>();
    expect(brief.brief).toBe(resource.result.contents[0].text);
    const prompt = await (await rpc(access, 'prompts/get', { name: 'coach_brief' })).json<any>();
    expect(prompt.result.messages[0].content.text).toContain(brief.brief);
    expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM audit_log WHERE user_id = ?1').bind(MEMBER).first('n')).toBe(before);
    const me = await profile();
    expect(me.coach).toEqual(me.claude);
    expect(me.coach.connected).toBe(true);
  });

  it('warns that log_set can clear old feedback when reopening a discarded legacy session', async () => {
    const access = connections.get('Codex')!.access_token;
    const catalog = await (await rpc(access, 'tools/list')).json<any>();
    expect(catalog.result.tools.find((t: any) => t.name === 'log_set').annotations.destructiveHint).toBe(true);
    const plan = await tool(access, 'get_current_plan');
    const session = crypto.randomUUID();
    await env.DB.prepare(`INSERT INTO sessions
      (id, user_id, plan_id, date, status, notes, perceived_fatigue, attempt, write_protocol, created_at, updated_at)
      VALUES (?1, ?2, ?3, '2020-01-01', 'discarded', 'old feedback', 7, 0, 'legacy', ?4, ?4)`)
      .bind(session, MEMBER, plan.id, Date.now()).run();
    const result = await tool(access, 'log_set', {
      exercise: 'back squat', weight: 100, reps: 5, session_date: '2020-01-01',
    });
    expect(result.session_id).toBe(session);
    expect(await env.DB.prepare('SELECT status, notes, perceived_fatigue FROM sessions WHERE id = ?1')
      .bind(session).first()).toEqual({ status: 'in_progress', notes: null, perceived_fatigue: null });
  });

  it.each(clients)('$name updates the shared plan with neutral notes and rejects a stale version', async ({ name }) => {
    const access = connections.get(name)!.access_token;
    const current = await tool(access, 'get_current_plan');
    const updated = await tool(access, 'update_plan', {
      expected_version: current.version, name: 'Updated member plan',
      workouts: [{ name: 'Workout A', day_label: 'A', exercises: [] }],
    });
    expect(updated.conflict).toBe(false);
    const fromApp = await (await SELF.fetch(`${BASE}/api/state`, { headers: { Authorization: `Bearer ${jwt}` } })).json<any>();
    expect(fromApp.plan.name).toBe('Updated member plan');
    expect(await tool(access, 'update_plan', { expected_version: current.version, name: 'Stale', workouts: [] }))
      .toMatchObject({ conflict: true, current_version: updated.plan.version });
    const notes = await env.DB.prepare('SELECT author FROM notes WHERE user_id = ?1').bind(MEMBER).all<{ author: string }>();
    expect(notes.results).toEqual([{ author: 'coach' }]);
    expect((await tool(otherConnection.access_token, 'get_current_plan')).name).toBe('Other private plan');
  });

  it('refreshes Codex access and disconnects all member apps without revoking another member', async () => {
    const codex = connections.get('Codex')!;
    const refresh = await SELF.fetch(`${BASE}/oauth/token`, { method: 'POST', body: new URLSearchParams({
      grant_type: 'refresh_token', refresh_token: codex.refresh_token, client_id: codex.client_id,
    }) });
    expect(refresh.status).toBe(200);
    const fresh = await refresh.json<Connection>();
    expect((await rpc(fresh.access_token, 'ping')).status).toBe(200);
    const disconnected = await SELF.fetch(`${BASE}/api/me/coach-grants`, {
      method: 'DELETE', headers: { Authorization: `Bearer ${jwt}` },
    });
    expect(disconnected.status).toBe(200);
    for (const access of [fresh.access_token, ...[...connections.values()].map(c => c.access_token)]) {
      expect((await rpc(access, 'ping')).status).toBe(401);
    }
    expect((await rpc(otherConnection.access_token, 'ping')).status).toBe(200);
    expect((await profile()).coach.connected).toBe(false);
    expect((await profile(otherJwt)).coach.connected).toBe(true);
    expect(await env.DB.prepare('SELECT name FROM plans WHERE user_id = ?1').bind(MEMBER).first('name')).toBe('Member plan');
  });

  it('escapes self-reported client names on consent and error pages', async () => {
    const name = '<img src=x onerror="alert(1)">&quot;';
    const reg = await (await SELF.fetch(`${BASE}/oauth/register`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ client_name: name, redirect_uris: ['http://127.0.0.1:44321/callback'] }),
    })).json<{ client_id: string }>();
    const params = new URLSearchParams({ client_id: reg.client_id, redirect_uri: 'http://127.0.0.1:44321/callback',
      response_type: 'code', code_challenge: 'test', code_challenge_method: 'S256' });
    for (const response of [
      await SELF.fetch(`${BASE}/oauth/authorize?${params}`),
      await SELF.fetch(`${BASE}/oauth/authorize`, { method: 'POST', body: params }),
    ]) {
      const html = await response.text();
      expect(html).toContain('&lt;img src=x onerror=&quot;alert(1)&quot;&gt;&amp;quot;');
      expect(html).not.toContain('<img');
    }
  });
});
