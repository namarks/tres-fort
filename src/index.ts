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
    (async () => {
      try {
        await syncExternalEvents(env.DB, env);
      } catch (e) {
        // A sync failure must never crash the scheduled handler — the
        // failed-fetch guard already left the cache untouched.
        console.error('scheduled syncExternalEvents failed', e);
      }
      try {
        await syncExternalActivities(env.DB, env);
      } catch (e) {
        // Same isolation as the planned-event sync above.
        console.error('scheduled syncExternalActivities failed', e);
      }
    })(),
  );
}

// The fetch path is byte-equivalent to the previous bare-app default
// export; `scheduled` is additive (cron only).
export default { fetch: app.fetch, scheduled };
