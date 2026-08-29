// OAuth 2.1 authorization server for the MCP resource. Implements the
// subset MCP clients (claude.ai / desktop) need: RFC 9728 protected-resource
// metadata, RFC 8414 AS metadata, RFC 7591 dynamic client registration,
// authorization-code + PKCE (S256) + refresh, single-user consent gate.
import { Hono } from 'hono';
import { cors } from 'hono/cors';
import type { Env, HonoEnv } from './types';
import { ensureOwnerUser, findUserByMcpPassphrase } from './db';

const ACCESS_TTL = 60 * 60 * 24 * 30; // 30 days
const CODE_TTL_MS = 10 * 60 * 1000; // 10 min
const rand = () => crypto.randomUUID().replace(/-/g, '') + crypto.randomUUID().replace(/-/g, '');

function origin(reqUrl: string): string {
  const u = new URL(reqUrl);
  return `${u.protocol}//${u.host}`;
}

async function s256(verifier: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier));
  return btoa(String.fromCharCode(...new Uint8Array(digest)))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

/**
 * Resolve the MCP principal for a bearer token to a user id, or null if the
 * token is invalid/expired. The static bearer (Claude Code / curl) maps to the
 * owner. An OAuth access token maps to the user bound at /authorize; tokens
 * issued before M3 carry no user_id and resolve to the owner (back-compat).
 */
export async function validateBearer(env: Env, token: string): Promise<string | null> {
  if (!token) return null;
  if (env.MCP_STATIC_TOKEN && token === env.MCP_STATIC_TOKEN) {
    return (await ensureOwnerUser(env.DB, env.OWNER_APPLE_SUB))?.id ?? null;
  }
  const row = await env.DB.prepare(
    'SELECT user_id, expires_at FROM oauth_tokens WHERE access_token = ?1',
  )
    .bind(token)
    .first<{ user_id: string | null; expires_at: number }>();
  if (!row || row.expires_at <= Math.floor(Date.now() / 1000)) return null;
  if (row.user_id) return row.user_id;
  return (await ensureOwnerUser(env.DB, env.OWNER_APPLE_SUB))?.id ?? null;
}

export const oauthRoutes = new Hono<HonoEnv>();

// Browser-originated discovery/registration/token need permissive CORS.
oauthRoutes.use('/.well-known/*', cors());
oauthRoutes.use('/oauth/register', cors());
oauthRoutes.use('/oauth/token', cors());

// ---- discovery -----------------------------------------------------------

oauthRoutes.get('/.well-known/oauth-protected-resource', (c) => {
  const o = origin(c.req.url);
  return c.json({
    resource: `${o}/mcp`,
    authorization_servers: [o],
    bearer_methods_supported: ['header'],
    scopes_supported: ['mcp'],
  });
});

const asMetadata = (o: string) => ({
  issuer: o,
  authorization_endpoint: `${o}/oauth/authorize`,
  token_endpoint: `${o}/oauth/token`,
  registration_endpoint: `${o}/oauth/register`,
  response_types_supported: ['code'],
  grant_types_supported: ['authorization_code', 'refresh_token'],
  code_challenge_methods_supported: ['S256'],
  token_endpoint_auth_methods_supported: ['none'],
  scopes_supported: ['mcp'],
});

oauthRoutes.get('/.well-known/oauth-authorization-server', (c) =>
  c.json(asMetadata(origin(c.req.url))),
);
// Some clients probe the OIDC path; serve the same OAuth metadata.
oauthRoutes.get('/.well-known/openid-configuration', (c) =>
  c.json(asMetadata(origin(c.req.url))),
);

// ---- dynamic client registration (RFC 7591) ------------------------------

oauthRoutes.post('/oauth/register', async (c) => {
  const b = await c.req
    .json<{ redirect_uris?: string[]; client_name?: string }>()
    .catch(() => ({}) as { redirect_uris?: string[]; client_name?: string });
  const redirects = Array.isArray(b.redirect_uris) ? b.redirect_uris : [];
  if (redirects.length === 0) return c.json({ error: 'invalid_redirect_uri' }, 400);
  const clientId = rand();
  await c.env.DB.prepare(
    'INSERT INTO oauth_clients (client_id, client_secret, redirect_uris, client_name, created_at) VALUES (?1, NULL, ?2, ?3, ?4)',
  )
    .bind(clientId, JSON.stringify(redirects), b.client_name ?? 'mcp-client', Date.now())
    .run();
  return c.json(
    {
      client_id: clientId,
      client_id_issued_at: Math.floor(Date.now() / 1000),
      redirect_uris: redirects,
      token_endpoint_auth_method: 'none',
      grant_types: ['authorization_code', 'refresh_token'],
      response_types: ['code'],
    },
    201,
  );
});

// ---- authorize (single-user consent gate) --------------------------------

function consentPage(params: Record<string, string>, error?: string): string {
  const hidden = Object.entries(params)
    .map(
      ([k, v]) =>
        `<input type="hidden" name="${k}" value="${v.replace(/"/g, '&quot;')}">`,
    )
    .join('');
  return `<!doctype html><html><head><meta charset="utf-8"><title>tres-fort</title>
<style>body{font-family:-apple-system,system-ui,sans-serif;background:#0a0a0a;color:#eee;
display:flex;min-height:100vh;align-items:center;justify-content:center;margin:0}
form{background:#161616;padding:32px;border-radius:14px;width:320px;border:1px solid #262626}
h1{font-size:18px;margin:0 0 4px}p{color:#9a9a9a;font-size:13px;margin:0 0 20px}
input[type=password]{width:100%;padding:11px;background:#0a0a0a;border:1px solid #333;
color:#fff;border-radius:8px;box-sizing:border-box;font-size:15px}
button{width:100%;margin-top:14px;padding:12px;background:#fff;color:#000;border:0;
border-radius:8px;font-weight:600;font-size:15px;cursor:pointer}
.err{color:#ff6b6b;font-size:13px;margin-top:10px}</style></head>
<body><form method="POST" action="/oauth/authorize">${hidden}
<h1>Connect Très Fort</h1><p>Paste your connect code to link Claude to your training. Get it in the Très Fort app under Profile → Coach.</p>
<input type="password" name="passphrase" placeholder="Connect code" autofocus>
${error ? `<div class="err">${error}</div>` : ''}
<button type="submit">Authorize</button></form></body></html>`;
}

async function loadClient(env: Env, clientId: string) {
  return env.DB.prepare('SELECT * FROM oauth_clients WHERE client_id = ?1')
    .bind(clientId)
    .first<{ client_id: string; redirect_uris: string }>();
}

oauthRoutes.get('/oauth/authorize', async (c) => {
  const q = c.req.query();
  const client = q.client_id ? await loadClient(c.env, q.client_id) : null;
  if (!client) return c.text('invalid client_id', 400);
  const allowed: string[] = JSON.parse(client.redirect_uris);
  if (!q.redirect_uri || !allowed.includes(q.redirect_uri)) {
    return c.text('invalid redirect_uri', 400);
  }
  if (q.response_type !== 'code') return c.text('unsupported_response_type', 400);
  if (q.code_challenge_method !== 'S256' || !q.code_challenge) {
    return c.text('PKCE S256 required', 400);
  }
  return c.html(
    consentPage({
      client_id: q.client_id ?? '',
      redirect_uri: q.redirect_uri ?? '',
      code_challenge: q.code_challenge ?? '',
      code_challenge_method: 'S256',
      state: q.state ?? '',
      scope: q.scope ?? 'mcp',
      resource: q.resource ?? '',
    }),
  );
});

oauthRoutes.post('/oauth/authorize', async (c) => {
  const form = await c.req.formData();
  const f = (k: string) => String(form.get(k) ?? '');
  const client = await loadClient(c.env, f('client_id'));
  if (!client) return c.text('invalid client_id', 400);
  const allowed: string[] = JSON.parse(client.redirect_uris);
  if (!allowed.includes(f('redirect_uri'))) return c.text('invalid redirect_uri', 400);

  const params = {
    client_id: f('client_id'),
    redirect_uri: f('redirect_uri'),
    code_challenge: f('code_challenge'),
    code_challenge_method: 'S256',
    state: f('state'),
    scope: f('scope'),
    resource: f('resource'),
  };
  // Resolve WHICH user is connecting: the owner via OWNER_AUTH_PASSPHRASE, or
  // any user via their personal MCP passphrase. No match → re-prompt. The
  // resolved user id is bound to the code so the issued token is scoped to them.
  // Trim so a connect code pasted with a stray trailing space/newline (common
  // on mobile paste) still matches — the app stores codes without surrounding
  // whitespace, and env passphrases don't carry any either.
  const pass = f('passphrase').trim();
  let userId: string | null = null;
  if (c.env.OWNER_AUTH_PASSPHRASE && pass === c.env.OWNER_AUTH_PASSPHRASE) {
    userId = (await ensureOwnerUser(c.env.DB, c.env.OWNER_APPLE_SUB))?.id ?? null;
  } else if (pass) {
    userId = await findUserByMcpPassphrase(c.env.DB, pass);
  }
  if (!userId) {
    return c.html(
      consentPage(params, 'That code did not match — open Très Fort → Profile → Coach to copy the current one.'),
      401,
    );
  }

  const code = rand();
  await c.env.DB.prepare(
    'INSERT INTO oauth_codes (code, client_id, redirect_uri, code_challenge, code_challenge_method, scope, resource, expires_at, created_at, user_id) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)',
  )
    .bind(
      code,
      params.client_id,
      params.redirect_uri,
      params.code_challenge,
      'S256',
      params.scope || 'mcp',
      params.resource || null,
      Date.now() + CODE_TTL_MS,
      Date.now(),
      userId,
    )
    .run();
  const url = new URL(params.redirect_uri);
  url.searchParams.set('code', code);
  if (params.state) url.searchParams.set('state', params.state);
  return c.redirect(url.toString(), 302);
});

// ---- token ---------------------------------------------------------------

async function issueTokens(env: Env, clientId: string, scope: string, userId: string | null) {
  const access = rand();
  const refresh = rand();
  const nowSec = Math.floor(Date.now() / 1000);
  await env.DB.prepare(
    'INSERT INTO oauth_tokens (access_token, refresh_token, client_id, scope, expires_at, created_at, user_id) VALUES (?1,?2,?3,?4,?5,?6,?7)',
  )
    .bind(access, refresh, clientId, scope, nowSec + ACCESS_TTL, nowSec, userId)
    .run();
  return {
    access_token: access,
    token_type: 'Bearer',
    expires_in: ACCESS_TTL,
    refresh_token: refresh,
    scope,
  };
}

oauthRoutes.post('/oauth/token', async (c) => {
  const form = await c.req.formData();
  const f = (k: string) => String(form.get(k) ?? '');
  const grant = f('grant_type');

  if (grant === 'authorization_code') {
    const code = await c.env.DB.prepare('SELECT * FROM oauth_codes WHERE code = ?1')
      .bind(f('code'))
      .first<any>();
    if (!code) return c.json({ error: 'invalid_grant' }, 400);
    // single-use
    await c.env.DB.prepare('DELETE FROM oauth_codes WHERE code = ?1').bind(f('code')).run();
    if (code.expires_at < Date.now()) return c.json({ error: 'invalid_grant' }, 400);
    if (code.client_id !== f('client_id') || code.redirect_uri !== f('redirect_uri')) {
      return c.json({ error: 'invalid_grant' }, 400);
    }
    if ((await s256(f('code_verifier'))) !== code.code_challenge) {
      return c.json({ error: 'invalid_grant', detail: 'pkce' }, 400);
    }
    return c.json(await issueTokens(c.env, code.client_id, code.scope ?? 'mcp', code.user_id ?? null));
  }

  if (grant === 'refresh_token') {
    const row = await c.env.DB.prepare(
      'SELECT * FROM oauth_tokens WHERE refresh_token = ?1',
    )
      .bind(f('refresh_token'))
      .first<any>();
    if (!row) return c.json({ error: 'invalid_grant' }, 400);
    await c.env.DB.prepare('DELETE FROM oauth_tokens WHERE refresh_token = ?1')
      .bind(f('refresh_token'))
      .run();
    return c.json(await issueTokens(c.env, row.client_id, row.scope ?? 'mcp', row.user_id ?? null));
  }

  return c.json({ error: 'unsupported_grant_type' }, 400);
});
