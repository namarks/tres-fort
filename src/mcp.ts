// /mcp route. Dual auth by design (DESIGN.md §6): static bearer (this
// milestone — Claude Code / curl) plus OAuth 2.1 (next, for claude.ai /
// desktop custom connectors). The 401 already advertises the OAuth
// protected-resource metadata location so adding the OAuth path later is
// non-breaking.
import { Hono } from 'hono';
import { cors } from 'hono/cors';
import type { HonoEnv } from './types';
import { createD1UsageObserver, logD1Usage } from './db';
import { handleMcp } from './mcp/server';
import { validateBearer } from './oauth';

export const mcpRoutes = new Hono<HonoEnv>();

// claude.ai web posts cross-origin; expose the auth-discovery header.
mcpRoutes.use(
  '*',
  cors({
    origin: '*',
    allowHeaders: ['Authorization', 'Content-Type', 'Mcp-Session-Id', 'MCP-Protocol-Version'],
    exposeHeaders: ['WWW-Authenticate', 'Mcp-Session-Id'],
  }),
);

function bearer(c: { req: { header: (k: string) => string | undefined } }) {
  const h = c.req.header('Authorization') ?? '';
  return h.startsWith('Bearer ') ? h.slice(7) : '';
}

function unauthorized(c: any) {
  // RFC 9728 pointer so OAuth-capable clients can discover the AS later.
  c.header(
    'WWW-Authenticate',
    `Bearer resource_metadata="${new URL('/.well-known/oauth-protected-resource', c.req.url).href}"`,
  );
  return c.json({ error: 'unauthorized' }, 401);
}

function isGetHistoryCall(body: unknown): boolean {
  if (body === null || typeof body !== 'object' || Array.isArray(body)) return false;
  const request = body as { method?: unknown; params?: unknown };
  if (
    request.method !== 'tools/call' ||
    request.params === null ||
    typeof request.params !== 'object'
  ) {
    return false;
  }
  return (request.params as { name?: unknown }).name === 'get_history';
}

// No server-initiated streams: GET stream not supported.
mcpRoutes.get('*', (c) => c.json({ error: 'method_not_allowed' }, 405));

mcpRoutes.post('*', async (c) => {
  // Start the request-local collector before bearer resolution so the
  // get_history total includes its authentication/owner reads. We identify
  // the tool only after successful authentication and body parsing, preserving
  // the existing boundary that rejects unauthenticated bodies without reading
  // them. Other MCP calls discard their unused collector without logging.
  const observer = createD1UsageObserver(c.env.DB);
  const measuredEnv = { ...c.env, DB: observer.db };
  const token = bearer(c);
  const userId = await validateBearer(measuredEnv, token);
  if (!userId) {
    return unauthorized(c);
  }
  let body: unknown;
  try {
    body = await c.req.json();
  } catch {
    return c.json({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } }, 400);
  }
  // Plumb the Cloudflare execution context so best-effort work (the
  // intervals.icu load export) runs via waitUntil AFTER the response is
  // sent — log_workout_complete must not be blocked by an intervals
  // round-trip (BLOCKER-2). executionCtx can throw if unavailable; guard.
  let bg: { waitUntil(p: Promise<unknown>): void } | undefined;
  try {
    const ec = c.executionCtx;
    if (ec && typeof ec.waitUntil === 'function') {
      bg = { waitUntil: (p) => ec.waitUntil(p) };
    }
  } catch {
    bg = undefined;
  }
  const measuresHistory = isGetHistoryCall(body);
  let outcome: 'ok' | 'error' = 'ok';
  try {
    const { status, json } = await handleMcp(
      body,
      measuresHistory ? measuredEnv : c.env,
      userId,
      bg,
    );
    if (json === undefined) return c.body(null, status as any);
    return c.json(json as object, status as any);
  } catch (error) {
    outcome = 'error';
    throw error;
  } finally {
    if (measuresHistory) logD1Usage('MCP get_history', outcome, observer.usage);
  }
});
