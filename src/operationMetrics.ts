import type { Context } from 'hono';
import type { ContentfulStatusCode } from 'hono/utils/http-status';
import type { HonoEnv } from './types';

/** Serialize once into the bytes sent to the client. Measurement never clones
 * or consumes a response stream; Content-Length is the uncompressed JSON size. */
export function measuredJson(c: Context<HonoEnv>, value: unknown, status: ContentfulStatusCode = 200): Response {
  const bytes = new TextEncoder().encode(JSON.stringify(value));
  return c.body(bytes.buffer as ArrayBuffer, status, {
    'Content-Type': 'application/json',
    'Content-Length': String(bytes.byteLength),
  });
}

export function responseBytes(response: Response): number | null {
  const length = response.headers.get('Content-Length');
  return length === null ? null : Number(length);
}

/** Fixed labels only: IDs, query strings and unrecognized tool names cannot
 * create metric dimensions or leak member input into request logs. */
export function measuredHttpOperation(request: Request): string | null {
  const path = new URL(request.url).pathname;
  if (request.method === 'GET' && (path === '/api/state' || path === '/api/me')) return `GET ${path}`;
  if (request.method === 'POST' && path === '/api/sessions') return 'POST /api/sessions';
  if (request.method === 'POST' && /^\/api\/sessions\/[^/]+\/sets$/.test(path)) return 'POST /api/sessions/:id/sets';
  if (request.method === 'POST' && /^\/api\/sessions\/[^/]+\/discard$/.test(path)) return 'POST /api/sessions/:id/discard';
  if (request.method === 'PATCH' && /^\/api\/sessions\/[^/]+$/.test(path)) return 'PATCH /api/sessions/:id';
  if (request.method === 'PATCH' && /^\/api\/sets\/[^/]+$/.test(path)) return 'PATCH /api/sets/:id';
  return null;
}

const measuredTools = new Set([
  'get_history', 'get_coach_brief', 'get_today_workout', 'get_current_session', 'get_session_log',
  'log_set', 'correct_set', 'delete_set', 'log_workout_complete', 'discard_workout',
]);

export function measuredMcpOperation(body: unknown): string | null {
  if (body === null || typeof body !== 'object' || Array.isArray(body)) return null;
  const request = body as { method?: unknown; params?: { name?: unknown } };
  const name = request.params?.name;
  return request.method === 'tools/call' && typeof name === 'string' && measuredTools.has(name)
    ? `MCP ${name}` : null;
}
