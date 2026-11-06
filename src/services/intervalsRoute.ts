// GPS tracks of the member's intervals.icu runs (docs/plans/run-recorder P6),
// read from intervals.icu when the app or web asks for a run's route. Public
// callers use the db.ts facade. Nothing is stored: the track stays with
// intervals.icu, so a run deleted there, or a connection removed, takes its
// map with it. Only the member's own activities are ever read.
import { routeFromSamples, type EncodedRoute } from '../activityRoute';
import { buildActivityStreams, samplesFromProvider, type ActivityStreams } from '../activityStreams';
import { fetchActivityChartStreams, fetchActivityRouteStreams, type Fetcher } from '../intervals';
import type { Env } from '../types';

interface IntervalsRouteDependencies {
  resolveIntervalsCredential(db: D1Database, env: Env, userId: string): Promise<
    { apiKey: string | null; accessToken: string | null; athleteId: string } | null
  >;
}

export type IntervalsRouteResult =
  | { ok: true; activity_id: string; route: EncodedRoute }
  /** No such activity of the member's, no connection, or no GPS track. */
  | { ok: false; reason: 'not_found' }
  /** intervals.icu couldn't answer now (timeout, 429, 5xx); try again later. */
  | { ok: false; reason: 'unavailable' };

export type IntervalsStreamsResult =
  | { ok: true; activity_id: string; streams: ActivityStreams }
  /** No such activity of the member's, no connection, or nothing to chart. */
  | { ok: false; reason: 'not_found' }
  /** intervals.icu couldn't answer now (timeout, 429, 5xx); try again later. */
  | { ok: false; reason: 'unavailable' };

const NOT_FOUND = { ok: false, reason: 'not_found' } as const;

/** A refusal or a missing activity won't change on a retry; a timeout, a
 * rate limit or a server error might. */
function lastingFailure(r: { reason: string; status?: number }): boolean {
  return r.reason === 'disabled'
    || (r.reason === 'http' && r.status !== undefined && r.status < 500 && r.status !== 429);
}

export function createIntervalsRouteService({ resolveIntervalsCredential }: IntervalsRouteDependencies) {
  /** The GPS track of one of the member's shown intervals.icu activities. */
  async function getIntervalsActivityRoute(
    db: D1Database,
    env: Env,
    userId: string,
    activityId: string,
    deps: { fetcher?: Fetcher } = {},
  ): Promise<IntervalsRouteResult> {
    const row = await db
      .prepare(
        `SELECT external_id, start_date_utc_ms, start_date_local_ms
           FROM external_activities
          WHERE id = ?1 AND user_id = ?2 AND source = 'intervals' AND deleted_at IS NULL`,
      )
      .bind(activityId, userId)
      .first<{ external_id: string; start_date_utc_ms: number | null; start_date_local_ms: number | null }>();
    if (!row) return NOT_FOUND;
    const cred = await resolveIntervalsCredential(db, env, userId);
    if (!cred) return NOT_FOUND;
    const streams = await fetchActivityRouteStreams(cred.apiKey, row.external_id, {
      fetcher: deps.fetcher,
      accessToken: cred.accessToken,
    });
    if (!streams.ok) {
      return lastingFailure(streams) ? NOT_FOUND : { ok: false, reason: 'unavailable' };
    }
    if (!streams.value) return NOT_FOUND;
    const route = routeFromSamples(row.start_date_utc_ms ?? row.start_date_local_ms ?? 0, {
      offsetSec: streams.value.time,
      lat: streams.value.lat,
      lon: streams.value.lon,
      alt: streams.value.altitude,
    });
    return route ? { ok: true, activity_id: activityId, route } : NOT_FOUND;
  }

  /**
   * Pace, heart rate and elevation series of one of the member's shown
   * intervals.icu activities (docs/plans/run-detail-charts P0), read from
   * intervals.icu and not stored.
   */
  async function getIntervalsActivityStreams(
    db: D1Database,
    env: Env,
    userId: string,
    activityId: string,
    deps: { fetcher?: Fetcher } = {},
  ): Promise<IntervalsStreamsResult> {
    const row = await db
      .prepare(
        `SELECT external_id FROM external_activities
          WHERE id = ?1 AND user_id = ?2 AND source = 'intervals' AND deleted_at IS NULL`,
      )
      .bind(activityId, userId)
      .first<{ external_id: string }>();
    if (!row) return NOT_FOUND;
    const cred = await resolveIntervalsCredential(db, env, userId);
    if (!cred) return NOT_FOUND;
    const fetched = await fetchActivityChartStreams(cred.apiKey, row.external_id, {
      fetcher: deps.fetcher,
      accessToken: cred.accessToken,
    });
    if (!fetched.ok) return lastingFailure(fetched) ? NOT_FOUND : { ok: false, reason: 'unavailable' };
    if (!fetched.value) return NOT_FOUND;
    const { track, heartRate } = samplesFromProvider(fetched.value);
    const streams = buildActivityStreams(track, heartRate);
    return streams ? { ok: true, activity_id: activityId, streams } : NOT_FOUND;
  }

  return { getIntervalsActivityRoute, getIntervalsActivityStreams };
}
