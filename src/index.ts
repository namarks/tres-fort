import { Hono } from 'hono';
import type { Env, HonoEnv } from './types';
import { authRoutes } from './routes/auth';
import { apiRoutes } from './routes/api';
import { mcpRoutes } from './mcp';
import { oauthRoutes } from './oauth';
import { syncExternalEvents } from './db';

const app = new Hono<HonoEnv>();

app.get('/health', (c) => c.json({ ok: true, service: 'lift-coach' }));

app.route('/', oauthRoutes); // /.well-known/* + /oauth/*
app.route('/auth', authRoutes);
app.route('/api', apiRoutes);
app.route('/mcp', mcpRoutes);

app.onError((err, c) => {
  console.error('unhandled', err);
  return c.json({ error: 'internal', message: err.message }, 500);
});

app.notFound((c) => c.json({ error: 'not_found' }, 404));

/**
 * Cron entrypoint (wrangler triggers.crons). Reconciles the intervals.icu
 * planned-event cache. Dormant no-op when INTERVALS_ICU_API_KEY is unset.
 * NEVER bumps plans.version; not an MCP action so no audit row here (the
 * MCP refresh_rides tool is the audited manual path).
 */
async function scheduled(
  _event: ScheduledController,
  env: Env,
  ctx: ExecutionContext,
): Promise<void> {
  ctx.waitUntil(
    (async () => {
      try {
        await syncExternalEvents(env.DB, env);
      } catch (e) {
        // A sync failure must never crash the scheduled handler — the
        // failed-fetch guard already left the cache untouched.
        console.error('scheduled syncExternalEvents failed', e);
      }
    })(),
  );
}

// The fetch path is byte-equivalent to the previous bare-app default
// export; `scheduled` is additive (cron only).
export default { fetch: app.fetch, scheduled };
