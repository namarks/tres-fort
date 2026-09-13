// OAuth 2.1 authorization server for the MCP resource. Implements the
// features used by external AI apps: RFC 9728 protected-resource
// metadata, RFC 8414 AS metadata, RFC 7591 dynamic client registration,
// authorization-code + PKCE (S256) + refresh, per-account consent.
import { Hono } from 'hono';
import { cors } from 'hono/cors';
import type { Env, HonoEnv } from './types';
import {
  ensureOwnerUser,
  findUserByMcpPassphrase,
  isAccountDeletionInProgress,
  redeemOAuthAuthorizationCode,
  refreshOAuthGrant,
  revokeOAuthGrantOnRefreshReplay,
} from './db';

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

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('');
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
    const owner = await ensureOwnerUser(env.DB, env.OWNER_APPLE_SUB);
    return owner && !(await isAccountDeletionInProgress(env.DB, owner.id))
      ? owner.id
      : null;
  }
  const row = await env.DB.prepare(
    `SELECT t.user_id, t.expires_at
       FROM oauth_tokens t
       LEFT JOIN oauth_grants g ON g.id = t.grant_id
       LEFT JOIN oauth_grant_lifecycle_policy p ON p.id = 1
      WHERE t.access_token = ?1
        AND t.expires_at > unixepoch('now')
        AND (
          (p.id = 1 AND p.activated_at IS NULL
           AND (t.grant_id IS NULL
                OR (g.revoked_at IS NULL
                    AND g.inactivity_expires_at IS NULL
                    AND g.absolute_expires_at IS NULL)))
          OR
          (p.activated_at IS NOT NULL
           AND g.revoked_at IS NULL
           AND g.inactivity_expires_at > CAST(unixepoch('subsec') * 1000 AS INTEGER)
           AND g.absolute_expires_at > CAST(unixepoch('subsec') * 1000 AS INTEGER))
        )`,
  )
    .bind(token)
    .first<{ user_id: string | null; expires_at: number }>();
  if (!row) return null;
  if (row.user_id) {
    const principal = await env.DB
      .prepare(
        `SELECT 1 AS x FROM users
          WHERE id = ?1
            AND NOT EXISTS (
                  SELECT 1 FROM account_deletion_intents
                   WHERE user_id = ?1
                )
            AND NOT EXISTS (
                  SELECT 1 FROM account_deletion_receipts
                   WHERE user_id = ?1
                )`,
      )
      .bind(row.user_id)
      .first<{ x: number }>();
    return principal ? row.user_id : null;
  }
  const owner = await ensureOwnerUser(env.DB, env.OWNER_APPLE_SUB);
  return owner && !(await isAccountDeletionInProgress(env.DB, owner.id))
    ? owner.id
    : null;
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

function escapeHtml(value: string): string {
  return value.replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function consentPage(params: Record<string, string>, clientName: string | null, error?: string): string {
  const hidden = Object.entries(params)
    .map(
      ([k, v]) =>
        `<input type="hidden" name="${k}" value="${escapeHtml(v)}">`,
    )
    .join('');
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>tres-fort</title>
<style>body{font-family:-apple-system,system-ui,sans-serif;background:#0a0a0a;color:#eee;
display:flex;min-height:100vh;align-items:center;justify-content:center;margin:0}
form{background:#161616;padding:24px;border-radius:14px;width:min(440px,calc(100% - 32px));box-sizing:border-box;margin:16px 0;border:1px solid #262626}
h1{font-size:18px;margin:0 0 4px}p{color:#b0b0b0;font-size:14px;line-height:1.5;margin:0 0 20px}a{color:#ddd}
input[type=password]{width:100%;padding:11px;background:#0a0a0a;border:1px solid #333;
color:#fff;border-radius:8px;box-sizing:border-box;font-size:15px}
button{width:100%;margin-top:14px;padding:12px;background:#fff;color:#000;border:0;
border-radius:8px;font-weight:600;font-size:15px;cursor:pointer}
.err{color:#ff6b6b;font-size:13px;margin-top:10px}</style></head>
<body><form method="POST" action="/oauth/authorize">${hidden}
<h1>Connect Très Fort</h1><p>Paste your connect code to link your AI app to your training. Get it in the Très Fort app under Profile → Coach.</p>
<p>App name supplied by the connecting client: <strong>${escapeHtml(clientName || 'AI app')}</strong>. Only continue if you started this connection in an app you trust.</p>
<p>Allowing access lets this app and its configured AI provider read your training plan, workout history, saved feedback and available group information, including imported Apple Health and Intervals.icu workouts. It also lets the app change your plan and record training updates.</p>
<p>You can disconnect all AI apps in Profile to stop future access through these connections. This does not delete information already retrieved into AI conversations. The Apple Health group-sharing switch does not limit your own coach’s access. Review the <a href="https://tresfort.app/privacy">Très Fort privacy policy</a> and your chosen app and model provider’s privacy policies before approving.</p>
<input type="password" name="passphrase" placeholder="Connect code" autofocus>
${error ? `<div class="err">${escapeHtml(error)}</div>` : ''}
<button type="submit">Allow access</button></form></body></html>`;
}

async function loadClient(env: Env, clientId: string) {
  return env.DB.prepare('SELECT * FROM oauth_clients WHERE client_id = ?1')
    .bind(clientId)
    .first<{ client_id: string; redirect_uris: string; client_name: string | null }>();
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
    }, client.client_name),
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
      consentPage(params, client.client_name, 'That code did not match — open Très Fort → Profile → Coach to copy the current one.'),
      401,
    );
  }
  if (await isAccountDeletionInProgress(c.env.DB, userId)) {
    return c.html(
      consentPage(params, client.client_name, 'That account is being deleted and cannot be connected.'),
      401,
    );
  }

  const code = rand();
  const inserted = await c.env.DB.prepare(
    `INSERT INTO oauth_codes
       (code, client_id, redirect_uri, code_challenge, code_challenge_method,
        scope, resource, expires_at, created_at, user_id)
     SELECT ?1,?2,?3,?4,?5,?6,?7,?8,?9,?10
      WHERE EXISTS (SELECT 1 FROM users WHERE id = ?10)
        AND NOT EXISTS (
              SELECT 1 FROM account_deletion_intents WHERE user_id = ?10
            )
        AND NOT EXISTS (
              SELECT 1 FROM account_deletion_receipts WHERE user_id = ?10
            )`,
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
  if (inserted.meta.changes !== 1) {
    return c.html(
      consentPage(params, client.client_name, 'That account is being deleted and cannot be connected.'),
      401,
    );
  }
  const url = new URL(params.redirect_uri);
  url.searchParams.set('code', code);
  if (params.state) url.searchParams.set('state', params.state);
  return c.redirect(url.toString(), 302);
});

// ---- token ---------------------------------------------------------------

oauthRoutes.post('/oauth/token', async (c) => {
  const form = await c.req.formData();
  const f = (k: string) => String(form.get(k) ?? '');
  const grant = f('grant_type');

  if (grant === 'authorization_code') {
    const code = await c.env.DB.prepare('SELECT * FROM oauth_codes WHERE code = ?1')
      .bind(f('code'))
      .first<any>();
    if (!code) return c.json({ error: 'invalid_grant' }, 400);
    if (code.expires_at < Date.now()) return c.json({ error: 'invalid_grant' }, 400);
    if (code.client_id !== f('client_id') || code.redirect_uri !== f('redirect_uri')) {
      return c.json({ error: 'invalid_grant' }, 400);
    }
    if ((await s256(f('code_verifier'))) !== code.code_challenge) {
      return c.json({ error: 'invalid_grant', detail: 'pkce' }, 400);
    }
    const tokens = await redeemOAuthAuthorizationCode(c.env.DB, {
      ...code,
      access_token: rand(),
      refresh_token: rand(),
      access_expires_at: Math.floor(Date.now() / 1000) + ACCESS_TTL,
      grant_id: crypto.randomUUID(),
      owner_apple_sub: c.env.OWNER_APPLE_SUB,
    }).catch(() => undefined);
    if (tokens === undefined) return c.json({ error: 'server_error' }, 500);
    if (!tokens) return c.json({ error: 'invalid_grant' }, 400);
    return c.json({
      access_token: tokens.access_token,
      refresh_token: tokens.refresh_token,
      scope: tokens.scope,
      token_type: 'Bearer',
      expires_in: Math.max(0, tokens.access_expires_at - Math.floor(Date.now() / 1000)),
    });
  }

  if (grant === 'refresh_token') {
    const row = await c.env.DB.prepare(
      'SELECT * FROM oauth_tokens WHERE refresh_token = ?1',
    )
      .bind(f('refresh_token'))
      .first<any>();
    if (!row) {
      if (f('client_id')) {
        await revokeOAuthGrantOnRefreshReplay(
          c.env.DB,
          await sha256Hex(f('refresh_token')),
          f('client_id'),
          c.env.OWNER_APPLE_SUB,
        );
      }
      return c.json({ error: 'invalid_grant' }, 400);
    }
    if (!f('client_id') || row.client_id !== f('client_id')) {
      return c.json({ error: 'invalid_grant' }, 400);
    }
    const tokens = await refreshOAuthGrant(c.env.DB, {
      ...row,
      presented_refresh_token: f('refresh_token'),
      presented_client_id: f('client_id'),
      access_token: rand(),
      refresh_token: rand(),
      access_expires_at: Math.floor(Date.now() / 1000) + ACCESS_TTL,
      grant_id: row.grant_id ?? null,
      consumed_refresh_sha256: await sha256Hex(f('refresh_token')),
      owner_apple_sub: c.env.OWNER_APPLE_SUB,
    }).catch(() => undefined);
    if (tokens === undefined) return c.json({ error: 'server_error' }, 500);
    if (!tokens) return c.json({ error: 'invalid_grant' }, 400);
    return c.json({
      access_token: tokens.access_token,
      refresh_token: tokens.refresh_token,
      scope: tokens.scope,
      token_type: 'Bearer',
      expires_in: Math.max(0, tokens.access_expires_at - Math.floor(Date.now() / 1000)),
    });
  }

  return c.json({ error: 'unsupported_grant_type' }, 400);
});
