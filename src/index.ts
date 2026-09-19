import { isArchivedWorkoutAssignment } from './workoutMetadata';
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
import type { Fetcher } from './intervals';
import { diagnosticErrorType, internalErrorResponse, logUnexpectedError } from './errors';
import {
  purgeExpiredMobileCoachRequests,
  ensureOwnerUser,
  observeD1Usage,
  seedOwnerIntervalsCredsFromEnv,
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

app.onError((err) => {
  if (err.message === 'session_kind_conflict') return Response.json({error:'session_kind_conflict'}, {status:409});
  if (isArchivedWorkoutAssignment(err)) return Response.json({ error: 'unknown_day' }, { status: 422 });
  logUnexpectedError('http', err);
  return internalErrorResponse();
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
  try {
    if (!operation) return await app.fetch(request, env, ctx);

    // Clone the bindings object for this invocation rather than mutating the
    // shared env. This lets the collector see auth middleware and route queries.
    return await observeD1Usage(
      env.DB,
      operation,
      async (db) => app.fetch(request, { ...env, DB: db }, ctx),
      (response) => (response.status >= 500 ? 'error' : 'ok'),
    );
  } catch (error: unknown) {
    // Hono's onError handles Error instances. A non-Error rejection must not
    // escape this last boundary into a raw platform exception log either.
    logUnexpectedError('http', error);
    return internalErrorResponse();
  }
}

const CRON_FRESHNESS_MS = 2 * 60 * 60 * 1000;
const CRON_MEMBER_CONCURRENCY = 4;

export interface IntervalsCronResult {
  failed: boolean;
  connected_members: number;
  events_polled: number;
  activities_polled: number;
  provider_calls: number;
  rate_limited_members: number;
}

function cronCacheIsStale(stamp: number | null, scheduledTime: number): boolean {
  return stamp === null || stamp < scheduledTime - CRON_FRESHNESS_MS;
}

/**
 * Webhook-primary intervals.icu backstop. Members run concurrently in a
 * bounded worker pool, while each member's two caches remain sequenced so a
 * Retry-After-bearing 429 can suppress that member's second provider call.
 * Every promise created here is awaited by Promise.all; scheduled() places
 * the single aggregate promise under its existing waitUntil lifetime.
 */
export async function runIntervalsCron(
  db: D1Database,
  env: Env,
  scheduledTime: number,
  deps: { fetcher?: Fetcher } = {},
): Promise<IntervalsCronResult> {
  await ensureOwnerUser(db, env.OWNER_APPLE_SUB);
  const members = await seedOwnerIntervalsCredsFromEnv(
    db,
    env.INTERVALS_ICU_API_KEY,
    env.INTERVALS_ICU_ATHLETE_ID,
    env.OWNER_APPLE_SUB,
  );
  const result: IntervalsCronResult = {
    failed: false,
    connected_members: members.length,
    events_polled: 0,
    activities_polled: 0,
    provider_calls: 0,
    rate_limited_members: 0,
  };
  const fetcher: Fetcher =
    deps.fetcher ?? ((input, init) => globalThis.fetch(input, init));
  const countedFetcher: Fetcher = async (input, init) => {
    result.provider_calls += 1;
    return fetcher(input, init);
  };
  let nextMember = 0;

  const runMember = async (): Promise<void> => {
    while (true) {
      const index = nextMember++;
      const member = members[index];
      if (!member) return;

      let suppressRemainingCaches = false;
      if (cronCacheIsStale(member.events_synced_at, scheduledTime)) {
        result.events_polled += 1;
        try {
          const events = await syncExternalEvents(db, env, {
            userId: member.user_id,
            fetcher: countedFetcher,
          });
          result.failed ||= events.status === 'fetch_failed';
          if (events.retryAfterMs !== undefined) {
            suppressRemainingCaches = true;
            result.rate_limited_members += 1;
            console.warn({
              event: 'intervals_cron_rate_limited',
              cache: 'events',
              retry_after_ms: events.retryAfterMs,
            });
          }
        } catch (error) {
          result.failed = true;
          console.error({
            event: 'intervals_cron_member_sync_failed',
            cache: 'events',
            error_type: diagnosticErrorType(error),
          });
        }
      }

      if (
        !suppressRemainingCaches &&
        cronCacheIsStale(member.activities_synced_at, scheduledTime)
      ) {
        result.activities_polled += 1;
        try {
          const activities = await syncExternalActivities(db, env, {
            userId: member.user_id,
            fetcher: countedFetcher,
          });
          result.failed ||= activities.status === 'fetch_failed';
          if (activities.retryAfterMs !== undefined) {
            result.rate_limited_members += 1;
            console.warn({
              event: 'intervals_cron_rate_limited',
              cache: 'activities',
              retry_after_ms: activities.retryAfterMs,
            });
          }
        } catch (error) {
          result.failed = true;
          console.error({
            event: 'intervals_cron_member_sync_failed',
            cache: 'activities',
            error_type: diagnosticErrorType(error),
          });
        }
      }
    }
  };

  await Promise.all(
    Array.from(
      { length: Math.min(CRON_MEMBER_CONCURRENCY, members.length) },
      () => runMember(),
    ),
  );
  console.log({
    event: 'intervals_cron_sync',
    outcome: result.failed ? 'error' : 'ok',
    connected_members: result.connected_members,
    events_polled: result.events_polled,
    activities_polled: result.activities_polled,
    provider_calls: result.provider_calls,
    rate_limited_members: result.rate_limited_members,
  });
  return result;
}

/** Cron entrypoint (wrangler triggers.crons); see runIntervalsCron. */
async function scheduled(
  event: ScheduledController,
  env: Env,
  ctx: ExecutionContext,
): Promise<void> {
  ctx.waitUntil(
    observeD1Usage(
      env.DB,
      'cron tick',
      async (db) => {
        await purgeExpiredMobileCoachRequests(db);
        return runIntervalsCron(db, env, event.scheduledTime);
      },
      (result) => (result.failed ? 'error' : 'ok'),
    ).catch((error: unknown) => {
      logUnexpectedError('scheduled', error);
      // Preserve the failed-tick signal without giving the platform the
      // original Error, message, stack or cause to retain in exception logs.
      throw new Error('Scheduled task failed');
    }),
  );
}

// HTTP behavior remains delegated to the same Hono app; the wrapper adds D1
// accounting only for the two P0 baseline routes. `scheduled` is additive.
export default { fetch, scheduled };
