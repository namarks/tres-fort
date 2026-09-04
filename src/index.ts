import { Hono } from 'hono';
import type { Env, HonoEnv } from './types';
import { authRoutes } from './routes/auth';
import { apiRoutes } from './routes/api';
import { intervalsAuthRoutes } from './routes/intervalsAuth';
import { privacyRoutes } from './routes/privacy';
import { inviteLinkRoutes } from './routes/invites';
import { webhookRoutes } from './routes/webhooks';
import { mcpRoutes } from './mcp';
import { oauthRoutes } from './oauth';
import {
  observeD1Usage,
  syncExternalActivities,
  syncExternalEvents,
} from './db';

const app = new Hono<HonoEnv>();

app.get('/health', (c) => c.json({ ok: true, service: 'tres-fort' }));

app.route('/', oauthRoutes); // /.well-known/* + /oauth/*
app.route('/', privacyRoutes); // GET /privacy (App Store Connect compliance)
app.route('/', inviteLinkRoutes); // AASA + GET /join/:code (Universal Link invites)
app.route('/auth', authRoutes);
app.route('/auth/intervals', intervalsAuthRoutes); // OAuth connect (start + callback)
app.route('/api', apiRoutes);
// PUBLIC — authenticated by the body `secret`, NOT app-JWT/MCP bearer. See
// src/routes/webhooks.ts. Must NOT sit behind requireAppJwt.
app.route('/webhooks', webhookRoutes); // POST /webhooks/intervals (intervals.icu push)
app.route('/mcp', mcpRoutes);

app.onError((err, c) => {
  console.error('unhandled', err);
  return c.json({ error: 'internal', message: err.message }, 500);
});

app.notFound((c) => c.json({ error: 'not_found' }, 404));

async function fetch(
  request: Request,
  env: Env,
  ctx: ExecutionContext,
): Promise<Response> {
  const { pathname } = new URL(request.url);
  const operation =
    request.method === 'GET' && pathname === '/api/state'
      ? 'GET /api/state'
      : request.method === 'GET' && pathname === '/api/me'
        ? 'GET /api/me'
        : null;
  if (!operation) return app.fetch(request, env, ctx);

  // Clone the bindings object for this invocation rather than mutating the
  // shared env. This lets the collector see auth middleware and route queries.
  return observeD1Usage(
    env.DB,
    operation,
    async (db) => app.fetch(request, { ...env, DB: db }, ctx),
    (response) => (response.status >= 500 ? 'error' : 'ok'),
  );
}

/**
 * Cron entrypoint (wrangler triggers.crons). SAFETY NET for intervals.icu
 * sync — real-time reconciliation is push-based (POST /webhooks/intervals);
 * this cron backstops any webhook a user's account didn't deliver. Two
 * independent best-effort jobs, each isolated so one's failure cannot affect
 * the other:
 *  1. reconcile the intervals.icu planned-event cache (ride awareness);
 *  2. reconcile the intervals.icu completed-activity cache (workouts done).
 * Both are dormant no-ops when INTERVALS_ICU_API_KEY is unset and NEVER
 * bump plans.version. The cache syncs are the audited-elsewhere manual path
 * (refresh_rides).
 */
async function scheduled(
  _event: ScheduledController,
  env: Env,
  ctx: ExecutionContext,
): Promise<void> {
  ctx.waitUntil(
    observeD1Usage(
      env.DB,
      'cron tick',
      async (db) => {
        let failed = false;
        try {
          const result = await syncExternalEvents(db, env);
          failed ||= result.status === 'fetch_failed';
        } catch (e) {
          failed = true;
          // A sync failure must never crash the scheduled handler — the
          // failed-fetch guard already left the cache untouched.
          console.error('scheduled syncExternalEvents failed', e);
        }
        try {
          const result = await syncExternalActivities(db, env);
          failed ||= result.status === 'fetch_failed';
        } catch (e) {
          failed = true;
          // Same isolation as the planned-event sync above.
          console.error('scheduled syncExternalActivities failed', e);
        }
        return failed;
      },
      (failed) => (failed ? 'error' : 'ok'),
    ),
  );
}

// HTTP behavior remains delegated to the same Hono app; the wrapper adds D1
// accounting only for the two P0 baseline routes. `scheduled` is additive.
export default { fetch, scheduled };
