// MCP server lives here. Milestone (b) implements read tools + the
// coach://state/current resource over Streamable HTTP, with dual auth
// (OAuth 2.1 for claude.ai/desktop, static bearer for Claude Code/curl).
// For milestone (a) this is an authenticated health stub so the route
// shape + bearer check are exercised by tests.
import { Hono } from 'hono';
import type { HonoEnv } from './types';

export const mcpRoutes = new Hono<HonoEnv>();

mcpRoutes.all('*', async (c) => {
  const header = c.req.header('Authorization') ?? '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : '';
  if (!c.env.MCP_STATIC_TOKEN || token !== c.env.MCP_STATIC_TOKEN) {
    return c.json({ error: 'unauthorized' }, 401);
  }
  return c.json({ status: 'mcp_not_implemented', milestone: 'b' }, 501);
});
