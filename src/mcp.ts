// /mcp route. Dual auth by design (DESIGN.md §6): static bearer (this
// milestone — Claude Code / curl) plus OAuth 2.1 (next, for claude.ai /
// desktop custom connectors). The 401 already advertises the OAuth
// protected-resource metadata location so adding the OAuth path later is
// non-breaking.
import { Hono } from 'hono';
import { cors } from 'hono/cors';
import type { HonoEnv } from './types';
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

// No server-initiated streams: GET stream not supported.
mcpRoutes.get('*', (c) => c.json({ error: 'method_not_allowed' }, 405));

mcpRoutes.post('*', async (c) => {
  const token = bearer(c);
  if (!(await validateBearer(c.env, token))) {
    return unauthorized(c);
  }
  let body: unknown;
  try {
    body = await c.req.json();
  } catch {
    return c.json({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } }, 400);
  }
  const { status, json } = await handleMcp(body, c.env);
  if (json === undefined) return c.body(null, status as any);
  return c.json(json as object, status as any);
});
