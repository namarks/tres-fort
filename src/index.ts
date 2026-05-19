import { Hono } from 'hono';
import type { Env, HonoEnv } from './types';
import { authRoutes } from './routes/auth';
import { apiRoutes } from './routes/api';
import { mcpRoutes } from './mcp';
import { oauthRoutes } from './oauth';
import { syncExternalEvents, retryPendingLoadExports } from './db';

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
 * Cron entrypoint (wrangler triggers.crons). Two independent best-effort
 * jobs, each isolated so one's failure cannot affect the other:
 *  1. reconcile the intervals.icu planned-event cache (ride awareness);
 *  2. retry any still-`pending` one-way lifting-load exports (Option C).
 * Both are dormant no-ops when INTERVALS_ICU_API_KEY is unset and NEVER
 * bump plans.version. exportSessionLoad audits its own attempts; the cache
 * sync is the audited-elsewhere manual path (refresh_rides).
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
        // Idempotent: each retry routes back through the session_id-keyed
        // upsert, so a retry UPDATEs the same intervals activity (never a
        // duplicate). retryPendingLoadExports never throws.
        await retryPendingLoadExports(env.DB, env);
      } catch (e) {
        console.error('scheduled retryPendingLoadExports failed', e);
      }
    })(),
  );
}

// The fetch path is byte-equivalent to the previous bare-app default
// export; `scheduled` is additive (cron only).
export default { fetch: app.fetch, scheduled };
