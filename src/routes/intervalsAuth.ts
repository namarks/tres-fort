// intervals.icu OAuth — the user-facing "Connect with intervals.icu" flow.
//
// Two routes, mounted at /auth/intervals:
//   POST /start    (app-JWT) → mint a single-use state mapped to the caller,
//                  return the intervals.icu authorize URL for the app to open
//                  in ASWebAuthenticationSession.
//   GET  /callback (public)  → intervals.icu redirects the user's browser here
//                  with ?code&state. We resolve state→user, exchange the code
//                  for a bearer token (server-side, with the client secret),
//                  store it, and bounce back to the app via the tresfort://
//                  scheme so the web-auth session closes.
//
// The client SECRET never leaves the Worker — the token exchange is the only
// place it's used. The client ID is non-sensitive (it rides in authorize URLs)
// and lives in wrangler.jsonc vars.
import { Hono } from 'hono';
import type { Env, HonoEnv } from '../types';
import { requireAppJwt } from '../auth';
import {
  consumeIntervalsOAuthAttempt,
  createIntervalsOAuthState,
  setUserIntervalsOAuth,
  reconcileIntervalsConnection,
  writeAudit,
} from '../db';

export const intervalsAuthRoutes = new Hono<HonoEnv>();

/** Scopes we request. WRITE on ACTIVITY so log_activity can create (and
 *  delete) the endurance sessions it routes to intervals.icu; WRITE on
 *  CALENDAR from the old WeightTraining event export. Each WRITE implies READ,
 *  covering completed-activity and planned-event ingestion. Grants made
 *  before ACTIVITY:WRITE was requested stay read-only until the member
 *  reconnects; log_activity reports that as intervals_write_forbidden. */
const SCOPES = 'ACTIVITY:WRITE,CALENDAR:WRITE';

/** Where intervals.icu sends the browser back. MUST exactly match a redirect
 *  URI registered on the app's Manage App page (/oauth/client/<n>) AND be
 *  byte-identical between /start and /callback (intervals rejects a mismatch).
 *  Prefer an explicitly-configured value so a multi-hostname/proxy deployment
 *  can't make the two requests derive different origins; fall back to the
 *  request origin for the common single-host case. */
function callbackUrl(env: Env, reqUrl: string): string {
  return env.INTERVALS_OAUTH_REDIRECT_URI ?? `${new URL(reqUrl).origin}/auth/intervals/callback`;
}

/** Deep-link back into the iOS app; ASWebAuthenticationSession intercepts the
 *  `tresfort` scheme to close the web sheet and hand control back. */
function appReturn(ok: boolean, detail?: string, generation?: number, syncAfter?: number | null): string {
  const q = ok ? 'ok=1' : `error=${encodeURIComponent(detail ?? 'failed')}`;
  return `tresfort://intervals-connected?${q}${generation !== undefined ? `&generation=${generation}` : ''}${syncAfter != null ? `&sync_after=${syncAfter}` : ''}`;
}

// POST /auth/intervals/start — authenticated; returns the authorize URL.
intervalsAuthRoutes.post('/start', requireAppJwt, async (c) => {
  const clientId = c.env.INTERVALS_OAUTH_CLIENT_ID;
  if (!clientId || !c.env.INTERVALS_OAUTH_CLIENT_SECRET) {
    // OAuth not configured on this deployment → the app falls back to the
    // manual API-key form.
    return c.json({ error: 'oauth_not_configured' }, 503);
  }
  const userId = c.get('userId');
  let state: string;
  try { state = await createIntervalsOAuthState(c.env.DB, userId); }
  catch (error) {
    if (error instanceof Error && error.message === 'intervals_connection_changed') {
      return c.json({ error: 'connection_changed' }, 409);
    }
    throw error;
  }
  const authorize = new URL('https://intervals.icu/oauth/authorize');
  authorize.searchParams.set('client_id', clientId);
  authorize.searchParams.set('redirect_uri', callbackUrl(c.env, c.req.url));
  authorize.searchParams.set('scope', SCOPES);
  authorize.searchParams.set('state', state);
  authorize.searchParams.set('response_type', 'code');
  return c.json({ authorize_url: authorize.toString() });
});

// GET /auth/intervals/callback — public browser redirect target.
intervalsAuthRoutes.get('/callback', async (c) => {
  const q = c.req.query();
  // User declined, or intervals returned an error. Truncate the reflected
  // value — it's attacker-influenceable and only needs to be a short hint.
  if (q.error) return c.redirect(appReturn(false, q.error.slice(0, 64)), 302);
  const code = q.code;
  const state = q.state;
  if (!code || !state) return c.redirect(appReturn(false, 'missing_code'), 302);

  // Resolve + consume the state (single-use, expiring) → the connecting user.
  const attempt = await consumeIntervalsOAuthAttempt(c.env.DB, state);
  if (!attempt) return c.redirect(appReturn(false, 'bad_state'), 302);
  const userId = attempt.user_id;

  const clientId = c.env.INTERVALS_OAUTH_CLIENT_ID;
  const clientSecret = c.env.INTERVALS_OAUTH_CLIENT_SECRET;
  if (!clientId || !clientSecret) {
    return c.redirect(appReturn(false, 'oauth_not_configured'), 302);
  }

  // Exchange the code for a bearer token. intervals.icu's documented contract:
  //   POST https://intervals.icu/api/oauth/token  (form: client_id, client_secret, code)
  //   → { token_type, access_token, scope, athlete: { id, name } }
  // (refresh_token / expires_in are not documented — tokens appear long-lived.)
  let tokenRes: Response;
  try {
    tokenRes = await fetch('https://intervals.icu/api/oauth/token', {
      method: 'POST',
      signal: AbortSignal.timeout(10_000),
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: clientId,
        client_secret: clientSecret,
        code,
        // Sent for spec-compliance; intervals.icu's docs omit them but they
        // are harmless and match standard authorization_code exchanges.
        grant_type: 'authorization_code',
        redirect_uri: callbackUrl(c.env, c.req.url),
      }).toString(),
    });
  } catch {
    return c.redirect(appReturn(false, 'exchange_network'), 302);
  }
  if (!tokenRes.ok) return c.redirect(appReturn(false, `exchange_http_${tokenRes.status}`), 302);

  let body: {
    access_token?: unknown;
    refresh_token?: unknown;
    expires_in?: unknown;
    athlete?: { id?: unknown };
  };
  try {
    body = (await tokenRes.json()) as typeof body;
  } catch {
    return c.redirect(appReturn(false, 'exchange_parse'), 302);
  }

  if (!body || typeof body !== 'object') return c.redirect(appReturn(false, 'exchange_parse'), 302);
  const accessToken = typeof body.access_token === 'string' ? body.access_token : null;
  const athleteId =
    body.athlete && body.athlete.id != null ? String(body.athlete.id) : null;
  if (!accessToken || !athleteId) {
    return c.redirect(appReturn(false, 'exchange_incomplete'), 302);
  }
  const refreshToken = typeof body.refresh_token === 'string' ? body.refresh_token : null;
  const expiresAt =
    typeof body.expires_in === 'number' && Number.isFinite(body.expires_in)
      ? Date.now() + body.expires_in * 1000
      : null;

  const receipt = await setUserIntervalsOAuth(
    c.env.DB, userId, accessToken, refreshToken, expiresAt, athleteId,
    attempt.credential_generation,
  );
  if (receipt === null) return c.redirect(appReturn(false, 'connection_changed'), 302);
  // Mirror the API-key path's audit row so the connect is visible/reversible.
  await writeAudit(
    c.env.DB,
    userId,
    'set_intervals_creds',
    { connected: true, via: 'oauth' },
    'connected',
    'ios',
  );
  c.executionCtx.waitUntil(reconcileIntervalsConnection(c.env.DB, c.env, userId, receipt.credential_generation));
  return c.redirect(appReturn(true, undefined, receipt.credential_generation, receipt.activity_sync_after), 302);
});
