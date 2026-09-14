// Internal provider reconciliation. Public callers use the db.ts facade.
import { deviceNameSQL, withActivityAttribution } from '../dataAttribution';

import { addDays } from '../calendarProjection';
import { diagnosticErrorType } from '../errors';
import { fetchCompletedActivities, fetchPlannedEvents, type ActivityFetchDeps, type FetchDeps, type Fetcher } from '../intervals';
import type { User, Env, ExternalActivityRow, ExternalEventRow } from '../types';
const now = () => Date.now();
const uuid = () => crypto.randomUUID();
// ---- external events (cycling-awareness; own consistency class) ----------
//
// `external_events` is a SERVER-OWNED RECONCILED CACHE. It is not the
// versioned plan tree and not the append-only client-UUID log. A sync
// MUST NOT bump plans.version. Rows are soft-deleted, never hard-deleted.

export type SyncStatus =
  | 'disabled' // INTERVALS_ICU_API_KEY/ATHLETE_ID unset — dormant no-op
  | 'ok' // 2xx + parse: cache reconciled
  | 'superseded' // a newer attempt or credential identity won while work was in flight
  | 'fetch_failed'; // non-2xx/timeout/parse: cache left COMPLETELY untouched

export interface SyncResult {
  status: SyncStatus;
  /** Count of non-deleted in-window rows after a successful sync (else 0). */
  synced: number;
  /** Diagnostic only (http status / reason) on a failed fetch. */
  detail?: string;
  /** Parsed Retry-After delay on a rate-limited fetch, for tick-local suppression. */
  retryAfterMs?: number;
}

export interface SyncDeps extends FetchDeps {
  /** Override the user id (defaults to the single owner). */
  userId?: string;
  /** Allow injecting the env-resolved owner sub (tests). */
  ownerSub?: string;
  /** Server-owned successful-sync stamp override for deterministic tests. */
  syncedAt?: number;
}

type IntervalsCache = 'events' | 'activities';

type IntervalsCredentialIdentity =
  | { kind: 'api_key'; apiKey: string; athleteId: string; generation: number }
  | {
      kind: 'oauth';
      accessToken: string;
      refreshToken: string | null;
      expiresAt: number | null;
      athleteId: string;
      generation: number;
    };

interface IntervalsSyncAttemptTuple {
  eventsAttempt: number;
  activitiesAttempt: number;
}

const MAX_INTERVALS_SYNC_ATTEMPT = Number.MAX_SAFE_INTEGER;

type IntervalsOAuthCredential = Extract<
  IntervalsCredentialIdentity,
  { kind: 'oauth' }
>;

type IntervalsOAuthRefreshResult =
  | { status: 'refreshed'; credential: IntervalsOAuthCredential }
  | { status: 'unavailable' }
  | { status: 'superseded' };

// ---- completed activities (own consistency class; see migrations/0015) ----
//
// PARALLEL to syncExternalEvents/getUpcomingRides but for COMPLETED, PAST
// recorded activities (the intervals.icu actuals) instead of planned events.
// Same server-owned reconciled-cache discipline: failed/disabled fetch =>
// cache left COMPLETELY untouched; only a successful window soft-deletes the
// in-window rows that vanished. Never bumps plans.version; never writes notes.

export interface ActivitySyncDeps extends ActivityFetchDeps {
  /** Override the user id (defaults to the single owner). */
  userId?: string;
  /** Allow injecting the env-resolved owner sub (tests). */
  ownerSub?: string;
  /** Server-owned successful-sync stamp override for deterministic tests. */
  syncedAt?: number;
  /** Connect/retry work may only use the credential the member selected. */
  expectedCredentialGeneration?: number;
}

export interface IntervalsImportResult {
  status: 'synced' | 'retry' | 'reconnect' | 'disconnected' | 'superseded';
  connection: IntervalsConnectionStatus | null;
}


// ---- intervals.icu credentials (per-user; M1 multi-user foundation) ------

/**
 * P4.6 dual-mode SQL. Migration 0039 keeps the shadow column NULL until its
 * monotonic fence is activated, then atomically moves every durable athlete id
 * into it and clears the legacy column. COALESCE is therefore unambiguous on
 * both sides of the cutover.
 */
export const INTERVALS_EFFECTIVE_ATHLETE_SQL =
  'COALESCE(intervals_cutover_athlete_id, intervals_athlete_id)';

export const INTERVALS_SOURCE_FENCE_ENABLED_SQL =
  'COALESCE((SELECT enabled FROM intervals_source_fence WHERE singleton = 1), 0)';


export interface IntervalsConnectionStatus {
  connected: boolean;
  athlete_id: string | null;
  needs_reauth: boolean;
  credential_generation: number;
  sync_pending: boolean;
  last_synced_at: number | null;
}


export interface ActivityDedupeWindow {
  /** Inclusive device-local range containing HealthKit rows that may change. */
  healthKitFromDate: string;
  healthKitToDate: string;
  /** Inclusive wider range containing every possible intervals winner. */
  intervalsFromDate: string;
  intervalsToDate: string;
}


/**
 * A user paired with their intervals.icu credentials. `athlete_id` is always
 * present; auth is EITHER `api_key` (HTTP Basic) OR `access_token` (OAuth
 * Bearer) — for a connected user exactly one is non-null (intervals.ts
 * prefers Bearer if both ever co-exist).
 */
export interface IntervalsUserCreds {
  user_id: string;
  api_key: string | null;
  access_token: string | null;
  refresh_token: string | null;
  expires_at: number | null;
  athlete_id: string;
  credential_generation: number;
  events_synced_at: number | null;
  activities_synced_at: number | null;
}
interface IntervalsSyncDependencies {
  getUserIntervalsCreds(db: D1Database, userId: string): Promise<{
    api_key: string | null; access_token: string | null; refresh_token: string | null;
    expires_at: number | null; athlete_id: string | null; auth_error_at: number | null;
    credential_generation: number;
  }>;
  findOwnerRow(db: D1Database, ownerAppleSub: string | undefined): Promise<User | null>;
  userHasTouchedIntervalsCreds(db: D1Database, userId: string): Promise<boolean>;
  seedOwnerIntervalsCredsFromEnv(db: D1Database, apiKey: string | null | undefined,
    athleteId: string | null | undefined, ownerAppleSub: string | undefined): Promise<IntervalsUserCreds[]>;
  ensureOwnerUser(db: D1Database, ownerAppleSub: string | undefined): Promise<User | null>;
  getIntervalsConnectionStatus(db: D1Database, userId: string): Promise<IntervalsConnectionStatus>;
  getUserTimezone(db: D1Database, userId: string): Promise<string | null>;
  todayInTz(tz: string | null | undefined): string;
  dedupeHealthKitAgainstIntervals(db: D1Database, userId: string, window?: ActivityDedupeWindow,
    expectedIntervalsFence?: { generation: number; attempt: number }): Promise<number>;
}

/** Identity selection and cross-source matching stay with their existing
 * owners. This service owns provider attempts, credential CAS and reconciliation. */
export function createIntervalsSyncService({
  getUserIntervalsCreds, findOwnerRow, userHasTouchedIntervalsCreds,
  seedOwnerIntervalsCredsFromEnv, ensureOwnerUser, getIntervalsConnectionStatus,
  getUserTimezone, todayInTz, dedupeHealthKitAgainstIntervals,
}: IntervalsSyncDependencies) {
  function intervalsSyncAttemptColumn(cache: IntervalsCache): string {
    return cache === 'events'
      ? 'intervals_events_sync_attempt'
      : 'intervals_activities_sync_attempt';
  }

  function usedIntervalsCredentialIdentity(
    apiKey: string | null | undefined,
    athleteId: string | null | undefined,
    accessToken: string | null | undefined,
    refreshToken: string | null | undefined,
    expiresAt: number | null | undefined,
    generation: number,
  ): IntervalsCredentialIdentity | null {
    if (!athleteId) return null;
    if (accessToken) {
      return {
        kind: 'oauth',
        accessToken,
        refreshToken: refreshToken ?? null,
        expiresAt: expiresAt ?? null,
        athleteId,
        generation,
      };
    }
    if (!apiKey) return null;
    return { kind: 'api_key', apiKey, athleteId, generation };
  }

  /**
   * Atomically start one cache poll. The UPDATE both verifies the exact durable
   * credential identity and advances only that cache's counter; RETURNING
   * captures the full cross-cache attempt tuple used by every later auth CAS.
   * A post-failure read only distinguishes exhaustion from supersession and is
   * never used to choose the value written by a claim.
   */
  async function claimIntervalsSyncAttempt(
    db: D1Database,
    userId: string,
    cache: IntervalsCache,
    credential: IntervalsCredentialIdentity,
  ): Promise<
    | { status: 'claimed'; attempts: IntervalsSyncAttemptTuple }
    | { status: 'superseded' }
    | { status: 'attempt_exhausted' }
  > {
    const column = intervalsSyncAttemptColumn(cache);
    const returning = `RETURNING intervals_events_sync_attempt AS eventsAttempt,
                                 intervals_activities_sync_attempt AS activitiesAttempt`;
    const statement =
      credential.kind === 'oauth'
        ? db.prepare(
            `UPDATE users
                SET ${column} = ${column} + 1,
                    intervals_protocol_write_seq = intervals_protocol_write_seq
                      + ${INTERVALS_SOURCE_FENCE_ENABLED_SQL}
              WHERE id = ?1
                AND intervals_credential_generation = ?2
                AND intervals_oauth_access_token = ?3
                AND intervals_oauth_refresh_token IS ?4
                AND intervals_oauth_expires_at IS ?5
                AND ${INTERVALS_EFFECTIVE_ATHLETE_SQL} = ?6
                AND intervals_api_key IS NULL
                AND ${column} < ${MAX_INTERVALS_SYNC_ATTEMPT}
              ${returning}`,
          )
        : db.prepare(
            `UPDATE users
                SET ${column} = ${column} + 1,
                    intervals_protocol_write_seq = intervals_protocol_write_seq
                      + ${INTERVALS_SOURCE_FENCE_ENABLED_SQL}
              WHERE id = ?1
                AND intervals_credential_generation = ?2
                AND intervals_api_key = ?3
                AND ${INTERVALS_EFFECTIVE_ATHLETE_SQL} = ?4
                AND intervals_oauth_access_token IS NULL
                AND intervals_oauth_refresh_token IS NULL
                AND intervals_oauth_expires_at IS NULL
                AND ${column} < ${MAX_INTERVALS_SYNC_ATTEMPT}
              ${returning}`,
          );
    const claimed = await (credential.kind === 'oauth'
      ? statement
          .bind(
            userId,
            credential.generation,
            credential.accessToken,
            credential.refreshToken,
            credential.expiresAt,
            credential.athleteId,
          )
          .first<IntervalsSyncAttemptTuple>()
      : statement
          .bind(userId, credential.generation, credential.apiKey, credential.athleteId)
          .first<IntervalsSyncAttemptTuple>());
    if (claimed) return { status: 'claimed', attempts: claimed };

    const diagnostic =
      credential.kind === 'oauth'
        ? await db
            .prepare(
              `SELECT ${column} AS attempt FROM users
                WHERE id = ?1
                  AND intervals_credential_generation = ?2
                  AND intervals_oauth_access_token = ?3
                  AND intervals_oauth_refresh_token IS ?4
                  AND intervals_oauth_expires_at IS ?5
                  AND ${INTERVALS_EFFECTIVE_ATHLETE_SQL} = ?6
                  AND intervals_api_key IS NULL`,
            )
            .bind(
              userId,
              credential.generation,
              credential.accessToken,
              credential.refreshToken,
              credential.expiresAt,
              credential.athleteId,
            )
            .first<{ attempt: number }>()
        : await db
            .prepare(
              `SELECT ${column} AS attempt FROM users
                WHERE id = ?1
                  AND intervals_credential_generation = ?2
                  AND intervals_api_key = ?3
                  AND ${INTERVALS_EFFECTIVE_ATHLETE_SQL} = ?4
                  AND intervals_oauth_access_token IS NULL
                  AND intervals_oauth_refresh_token IS NULL
                  AND intervals_oauth_expires_at IS NULL`,
            )
            .bind(userId, credential.generation, credential.apiKey, credential.athleteId)
            .first<{ attempt: number }>();
    return diagnostic?.attempt === MAX_INTERVALS_SYNC_ATTEMPT
      ? { status: 'attempt_exhausted' }
      : { status: 'superseded' };
  }

  async function isCurrentIntervalsSyncAttempt(
    db: D1Database,
    userId: string,
    cache: IntervalsCache,
    credential: IntervalsCredentialIdentity,
    attempts: IntervalsSyncAttemptTuple,
  ): Promise<boolean> {
    const column = intervalsSyncAttemptColumn(cache);
    const ownAttempt = cache === 'events' ? attempts.eventsAttempt : attempts.activitiesAttempt;
    const row = await db
      .prepare(
        `SELECT EXISTS(
                  SELECT 1 FROM users
                   WHERE id = ?1
                     AND intervals_credential_generation = ?2
                     AND ${column} = ?3
                ) AS current_attempt`,
      )
      .bind(userId, credential.generation, ownAttempt)
      .first<{ current_attempt: number }>();
    return row?.current_attempt === 1;
  }

  /**
   * Advance one cache's freshness only after its complete reconcile succeeds.
   * The CASE keeps the stamp strictly monotonic when two webhook/manual/cron
   * calls finish in the same millisecond. This intentional users-row write is
   * separate from P2's cache-change cursor: an executed no-change poll writes
   * its attempt claim plus this freshness row, while a skipped cron poll writes
   * nothing.
   * The credential predicate is part of the same UPDATE: a completion racing a
   * replacement/disconnect changes zero rows and leaves the reset stamp NULL so
   * a later cron repairs the cache with the current identity.
   */
  async function stampIntervalsSyncSuccess(
    db: D1Database,
    userId: string,
    cache: IntervalsCache,
    timestamp: number,
    credential: IntervalsCredentialIdentity,
    attempts: IntervalsSyncAttemptTuple,
  ): Promise<boolean> {
    const freshnessColumn =
      cache === 'events'
        ? 'intervals_events_synced_at'
        : 'intervals_activities_synced_at';
    const attemptColumn = intervalsSyncAttemptColumn(cache);
    const ownAttempt = cache === 'events' ? attempts.eventsAttempt : attempts.activitiesAttempt;
    const statement =
      credential.kind === 'oauth'
        ? db.prepare(
            `UPDATE users
            SET ${freshnessColumn} = CASE
                  WHEN ${freshnessColumn} IS NULL OR ${freshnessColumn} < ?2 THEN ?2
                  ELSE ${freshnessColumn} + 1
                END,
                intervals_protocol_write_seq = intervals_protocol_write_seq
                  + ${INTERVALS_SOURCE_FENCE_ENABLED_SQL}
          WHERE id = ?1
            AND intervals_credential_generation = ?3
            AND intervals_oauth_access_token = ?4
            AND intervals_oauth_refresh_token IS ?5
            AND intervals_oauth_expires_at IS ?6
            AND ${INTERVALS_EFFECTIVE_ATHLETE_SQL} = ?7
            AND intervals_api_key IS NULL
            AND ${attemptColumn} = ?8`,
          )
        : db.prepare(
            `UPDATE users
            SET ${freshnessColumn} = CASE
                  WHEN ${freshnessColumn} IS NULL OR ${freshnessColumn} < ?2 THEN ?2
                  ELSE ${freshnessColumn} + 1
                END,
                intervals_protocol_write_seq = intervals_protocol_write_seq
                  + ${INTERVALS_SOURCE_FENCE_ENABLED_SQL}
          WHERE id = ?1
            AND intervals_credential_generation = ?3
            AND intervals_api_key = ?4
            AND ${INTERVALS_EFFECTIVE_ATHLETE_SQL} = ?5
            AND intervals_oauth_access_token IS NULL
            AND intervals_oauth_refresh_token IS NULL
            AND intervals_oauth_expires_at IS NULL
            AND ${attemptColumn} = ?6`,
          );
    const stamped = await (credential.kind === 'oauth'
      ? statement
          .bind(
            userId,
            timestamp,
            credential.generation,
            credential.accessToken,
            credential.refreshToken,
            credential.expiresAt,
            credential.athleteId,
            ownAttempt,
          )
          .run()
      : statement
          .bind(
            userId,
            timestamp,
            credential.generation,
            credential.apiKey,
            credential.athleteId,
            ownAttempt,
          )
          .run());
    return (stamped.meta.changes ?? 0) === 1;
  }

  /** Legacy env credentials may stand in only for the distinguished owner. */
  async function canUseOwnerIntervalsEnvFallback(
    db: D1Database,
    userId: string,
    ownerAppleSub: string | undefined,
    creds: Awaited<ReturnType<typeof getUserIntervalsCreds>>,
  ): Promise<boolean> {
    if (
      creds.api_key !== null ||
      creds.access_token !== null ||
      creds.athlete_id !== null ||
      creds.auth_error_at !== null ||
      creds.credential_generation !== 0
    ) {
      return false;
    }
    const owner = await findOwnerRow(db, ownerAppleSub);
    return owner?.id === userId && !(await userHasTouchedIntervalsCreds(db, userId));
  }

  // ── intervals.icu auth-failure recovery ──────────────────────────────────
  // A 401/403 from intervals.icu means the credential is DEAD (expired or
  // revoked), not a transient outage — so it must NOT be swallowed as the
  // "leave the cache untouched and retry forever" fetch_failed (which is right
  // for a 5xx/timeout). Instead: try a token refresh once; if that is impossible
  // or also rejected, clear the credential and stamp `intervals_auth_error_at`
  // so the cron stops polling and iOS prompts a reconnect. The cache is still
  // left intact — we disconnect, we don't wipe ride history.

  /** True for a 401/403 auth rejection (vs disabled / 5xx / timeout / parse). */
  function isIntervalsAuthError(r: { ok: boolean; reason?: string; status?: number }): boolean {
    return !r.ok && r.reason === 'http' && (r.status === 401 || r.status === 403);
  }

  /**
   * Clear a user's intervals.icu credentials and stamp `intervals_auth_error_at`.
   * Nulls BOTH auth schemes + the athlete id (canonical "disconnected") so the
   * per-user sync enumeration drops them and getMeProfile reports needs_reauth.
   * The cache rows are deliberately left intact.
   *
   * The credential clear and the system audit row go in ONE D1 batch (a
   * transaction) so we can never end up disconnected-without-audit. This is the
   * sole place the sync layer mutates user/audit state — a credential-lifecycle
   * event (only a 401/403 reaches here; a 5xx/timeout never does), NOT a cache
   * write, so the critical "leave the cache untouched on a failed fetch" guard is
   * unaffected. actor='system' marks it as the auto-disconnect, distinct from a
   * user PATCH.
   */
  async function markIntervalsAuthError(
    db: D1Database,
    userId: string,
    credential: IntervalsCredentialIdentity,
    attempts: IntervalsSyncAttemptTuple,
  ): Promise<boolean> {
    const ts = now();
    const clearStatement =
      credential.kind === 'oauth'
        ? db.prepare(
            `UPDATE users
              SET intervals_api_key = NULL,
                  intervals_oauth_access_token = NULL,
                  intervals_oauth_refresh_token = NULL,
                  intervals_oauth_expires_at = NULL,
                  intervals_athlete_id = NULL,
                  intervals_cutover_athlete_id = NULL,
                  intervals_auth_error_at = ?2,
                  intervals_credential_generation = intervals_credential_generation + 1,
                  intervals_events_synced_at = NULL,
                  intervals_activities_synced_at = NULL,
                  intervals_events_sync_attempt = 0,
                  intervals_activities_sync_attempt = 0,
                  intervals_protocol_write_seq = intervals_protocol_write_seq
                    + ${INTERVALS_SOURCE_FENCE_ENABLED_SQL}
            WHERE id = ?1
              AND intervals_credential_generation = ?3
              AND intervals_oauth_access_token = ?4
              AND intervals_oauth_refresh_token IS ?5
              AND intervals_oauth_expires_at IS ?6
              AND ${INTERVALS_EFFECTIVE_ATHLETE_SQL} = ?7
              AND intervals_api_key IS NULL
              AND intervals_events_sync_attempt = ?8
              AND intervals_activities_sync_attempt = ?9`,
          )
        : db.prepare(
            `UPDATE users
              SET intervals_api_key = NULL,
                  intervals_oauth_access_token = NULL,
                  intervals_oauth_refresh_token = NULL,
                  intervals_oauth_expires_at = NULL,
                  intervals_athlete_id = NULL,
                  intervals_cutover_athlete_id = NULL,
                  intervals_auth_error_at = ?2,
                  intervals_credential_generation = intervals_credential_generation + 1,
                  intervals_events_synced_at = NULL,
                  intervals_activities_synced_at = NULL,
                  intervals_events_sync_attempt = 0,
                  intervals_activities_sync_attempt = 0,
                  intervals_protocol_write_seq = intervals_protocol_write_seq
                    + ${INTERVALS_SOURCE_FENCE_ENABLED_SQL}
            WHERE id = ?1
              AND intervals_credential_generation = ?3
              AND intervals_api_key = ?4
              AND ${INTERVALS_EFFECTIVE_ATHLETE_SQL} = ?5
              AND intervals_oauth_access_token IS NULL
              AND intervals_oauth_refresh_token IS NULL
              AND intervals_oauth_expires_at IS NULL
              AND intervals_events_sync_attempt = ?6
              AND intervals_activities_sync_attempt = ?7`,
          );
    const clear = credential.kind === 'oauth'
      ? clearStatement.bind(
          userId,
          ts,
          credential.generation,
          credential.accessToken,
          credential.refreshToken,
          credential.expiresAt,
          credential.athleteId,
          attempts.eventsAttempt,
          attempts.activitiesAttempt,
        )
      : clearStatement.bind(
          userId,
          ts,
          credential.generation,
          credential.apiKey,
          credential.athleteId,
          attempts.eventsAttempt,
          attempts.activitiesAttempt,
        );
    const [cleared] = await db.batch([
      clear,
      db
        .prepare(
          `INSERT INTO audit_log (id,user_id,actor,tool,args,result,created_at)
           SELECT ?1,?2,'system','intervals_auth_error',?3,'disconnected',?4
            WHERE changes() = 1`,
        )
        .bind(
          uuid(),
          userId,
          JSON.stringify({ disconnected: true, reason: 'auth_rejected' }),
          ts,
        ),
    ]);
    return (cleared?.meta.changes ?? 0) === 1;
  }

  /**
   * Best-effort OAuth refresh against intervals.icu's token endpoint. DORMANT:
   * intervals.icu's documented token response carries no refresh_token (tokens
   * "appear long-lived" — intervalsAuth.ts), so a stored refresh_token is
   * typically null and this returns unavailable with NO network call. The D1
   * write exact-CASes the generation and every credential value it read before
   * provider I/O; a concurrent replacement therefore cannot be overwritten or
   * resurrected by the stale refresh response.
   */
  async function tryRefreshIntervalsOAuth(
    db: D1Database,
    env: Env,
    userId: string,
    credential: IntervalsOAuthCredential,
    attempts: IntervalsSyncAttemptTuple,
    fetcher?: Fetcher,
  ): Promise<IntervalsOAuthRefreshResult> {
    const clientId = env.INTERVALS_OAUTH_CLIENT_ID;
    const clientSecret = env.INTERVALS_OAUTH_CLIENT_SECRET;
    if (!clientId || !clientSecret) return { status: 'unavailable' };
    if (!credential.refreshToken) return { status: 'unavailable' };
    const row = await db
      .prepare(
        `SELECT 1 AS current_credential
           FROM users
          WHERE id = ?1
            AND intervals_credential_generation = ?2
            AND intervals_oauth_access_token = ?3
            AND intervals_oauth_refresh_token IS ?4
            AND intervals_oauth_expires_at IS ?5
            AND ${INTERVALS_EFFECTIVE_ATHLETE_SQL} = ?6
            AND intervals_api_key IS NULL
            AND intervals_events_sync_attempt = ?7
            AND intervals_activities_sync_attempt = ?8`,
      )
      .bind(
        userId,
        credential.generation,
        credential.accessToken,
        credential.refreshToken,
        credential.expiresAt,
        credential.athleteId,
        attempts.eventsAttempt,
        attempts.activitiesAttempt,
      )
      .first<{ current_credential: number }>();
    if (!row) return { status: 'superseded' };
    const refreshToken = credential.refreshToken;

    const f: Fetcher = fetcher ?? ((input, init) => globalThis.fetch(input, init));
    let res: { ok: boolean; status: number; json: () => Promise<unknown> };
    try {
      res = await f('https://intervals.icu/api/oauth/token', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
          client_id: clientId,
          client_secret: clientSecret,
          grant_type: 'refresh_token',
          refresh_token: refreshToken,
        }).toString(),
      });
    } catch {
      return { status: 'unavailable' };
    }
    if (!res.ok) return { status: 'unavailable' };
    let body: { access_token?: unknown; refresh_token?: unknown; expires_in?: unknown };
    try {
      body = (await res.json()) as typeof body;
    } catch {
      return { status: 'unavailable' };
    }
    const accessToken = typeof body.access_token === 'string' ? body.access_token : null;
    if (!accessToken) return { status: 'unavailable' };
    // Keep the old refresh token if the response rotates none; honour expiry if given.
    const newRefresh = typeof body.refresh_token === 'string' ? body.refresh_token : refreshToken;
    const expiresAt =
      typeof body.expires_in === 'number' && Number.isFinite(body.expires_in)
        ? now() + body.expires_in * 1000
        : null;
    const stored = await db
      .prepare(
        `UPDATE users
            SET intervals_oauth_access_token = ?9,
                intervals_oauth_refresh_token = ?10,
                intervals_oauth_expires_at = ?11,
                intervals_auth_error_at = NULL,
                intervals_protocol_write_seq = intervals_protocol_write_seq
                  + ${INTERVALS_SOURCE_FENCE_ENABLED_SQL}
          WHERE id = ?1
            AND intervals_credential_generation = ?2
            AND intervals_oauth_access_token = ?3
            AND intervals_oauth_refresh_token IS ?4
            AND intervals_oauth_expires_at IS ?5
            AND ${INTERVALS_EFFECTIVE_ATHLETE_SQL} = ?6
            AND intervals_api_key IS NULL
            AND intervals_events_sync_attempt = ?7
            AND intervals_activities_sync_attempt = ?8`,
      )
      .bind(
        userId,
        credential.generation,
        credential.accessToken,
        refreshToken,
        credential.expiresAt,
        credential.athleteId,
        attempts.eventsAttempt,
        attempts.activitiesAttempt,
        accessToken,
        newRefresh,
        expiresAt,
      )
      .run();
    if ((stored.meta.changes ?? 0) !== 1) return { status: 'superseded' };
    return {
      status: 'refreshed',
      credential: {
        ...credential,
        accessToken,
        refreshToken: newRefresh,
        expiresAt,
      },
    };
  }

  /**
   * Run an intervals.icu fetch with auth recovery. Runs `run(token)` once; on a
   * 401/403 attempts ONE token refresh and retries; if still rejected (or no
   * refresh possible) clears the credential and reports `reauthRequired`. Any
   * other outcome (disabled / 5xx / timeout / success) passes straight through.
   * Never throws into the sync path.
   */
  async function fetchIntervalsWithAuthRecovery<
    T extends { ok: boolean; reason?: string; status?: number },
  >(
    db: D1Database,
    env: Env,
    userId: string,
    credential: IntervalsCredentialIdentity,
    attempts: IntervalsSyncAttemptTuple,
    fetcher: Fetcher | undefined,
    run: (token: string | null | undefined) => Promise<T>,
  ): Promise<{
    result: T;
    reauthRequired: boolean;
    superseded: boolean;
    effectiveCredential: IntervalsCredentialIdentity;
  }> {
    let effectiveCredential = credential;
    let result = await run(
      effectiveCredential?.kind === 'oauth' ? effectiveCredential.accessToken : null,
    );
    if (!isIntervalsAuthError(result)) {
      return { result, reauthRequired: false, superseded: false, effectiveCredential };
    }
    if (effectiveCredential?.kind === 'oauth') {
      const refreshed = await tryRefreshIntervalsOAuth(
        db,
        env,
        userId,
        effectiveCredential,
        attempts,
        fetcher,
      );
      if (refreshed.status === 'superseded') {
        return { result, reauthRequired: false, superseded: true, effectiveCredential };
      }
      if (refreshed.status === 'refreshed') {
        effectiveCredential = refreshed.credential;
        result = await run(effectiveCredential.accessToken);
      }
      if (!isIntervalsAuthError(result)) {
        return { result, reauthRequired: false, superseded: false, effectiveCredential };
      }
    }
    const cleared = await markIntervalsAuthError(
      db,
      userId,
      effectiveCredential,
      attempts,
    );
    return {
      result,
      reauthRequired: cleared,
      superseded: !cleared,
      effectiveCredential,
    };
  }

  /**
   * Pull intervals.icu planned events and reconcile the cache.
   *
   * THE critical correctness guard: on a failed/disabled fetch the cache is
   * left COMPLETELY untouched (no upsert, NO soft-delete) — a transient
   * intervals.icu outage must NEVER wipe the user's ride awareness. Only a
   * genuinely-empty *successful* window soft-deletes the in-window rows.
   *
   * Reconcile (on {ok:true}):
   *  - upsert each event by (source, external_id) — id = "intervals:{ext}";
   *    reschedules just update `date` (+ other fields) on the same row.
   *  - soft-delete (set deleted_at) any non-deleted row whose date is inside
   *    the synced [today, today+window] window but is no longer present in
   *    the fetched set (the source removed/cancelled it).
   *  - rows OUTSIDE the window are never touched (we didn't ask about them).
   *
   * Never bumps plans.version. Never writes a notes row. (The MCP action
   * wrapper writes the audit_log row — this layer stays pure data.) The ONE
   * exception is an upstream 401/403: that clears the dead credential and writes
   * a system audit row via markIntervalsAuthError, because the cron has no MCP
   * wrapper to record the auto-disconnect. The cache itself is still untouched.
   */
  async function syncExternalEvents(
    db: D1Database,
    env: Env,
    deps: SyncDeps = {},
  ): Promise<SyncResult> {
    const today = deps.today ?? new Date().toISOString().slice(0, 10);
    const windowDays = deps.windowDays ?? 90;

    // Resolve creds for THIS sync. Two call modes (M1 multi-user):
    //   (a) deps.userId given (refresh_rides MCP tool / tests): sync that one
    //       user, reading creds off their row. For the untouched owner only,
    //       legacy env values are first persisted as a versioned DB identity.
    //   (b) no userId: cron entrypoint. Run the env→DB seed (idempotent), then
    //       iterate ALL users with creds. Aggregate the SyncResult.
    let userId: string;
    let apiKey: string | null | undefined;
    let athleteId: string | null | undefined;
    let accessToken: string | null | undefined;
    let refreshToken: string | null | undefined;
    let expiresAt: number | null | undefined;
    let credentialGeneration = 0;
    if (deps.userId) {
      userId = deps.userId;
      let creds = await getUserIntervalsCreds(db, userId);
      // Legacy env credentials belong to the distinguished owner only. A newly
      // invited member with empty columns must never inherit the owner's athlete
      // merely because this explicit-user path was called. Require a completely
      // empty stored identity as well, so partial rows cannot mix DB and env
      // credential halves.
      const envFallbackOk = await canUseOwnerIntervalsEnvFallback(
        db,
        userId,
        deps.ownerSub ?? env.OWNER_APPLE_SUB,
        creds,
      );
      if (envFallbackOk) {
        // Store/version the legacy owner env identity before provider I/O. This
        // removes the unversioned generation-zero secret-rotation corner and
        // lets every later cache/auth mutation fence on one durable generation.
        await seedOwnerIntervalsCredsFromEnv(
          db,
          env.INTERVALS_ICU_API_KEY,
          env.INTERVALS_ICU_ATHLETE_ID,
          deps.ownerSub ?? env.OWNER_APPLE_SUB,
        );
        creds = await getUserIntervalsCreds(db, userId);
      }
      credentialGeneration = creds.credential_generation;
      apiKey = creds.api_key;
      athleteId = creds.athlete_id;
      // OAuth bearer token rides alongside (no env fallback — env is the
      // legacy API-key path only). intervals.ts prefers it over the API key.
      accessToken = creds.access_token;
      refreshToken = creds.refresh_token;
      expiresAt = creds.expires_at;
    } else {
      const owner = await ensureOwnerUser(db, deps.ownerSub ?? env.OWNER_APPLE_SUB);
      const seeded = await seedOwnerIntervalsCredsFromEnv(
        db,
        env.INTERVALS_ICU_API_KEY,
        env.INTERVALS_ICU_ATHLETE_ID,
        deps.ownerSub ?? env.OWNER_APPLE_SUB,
      );
      if (seeded.length === 0) {
        // No user has creds AND env is unset → dormant no-op for everyone.
        return { status: 'disabled', synced: 0, detail: 'disabled' };
      }
      if (seeded.length === 1) {
        userId = seeded[0]!.user_id;
        apiKey = seeded[0]!.api_key;
        athleteId = seeded[0]!.athlete_id;
        accessToken = seeded[0]!.access_token;
        refreshToken = seeded[0]!.refresh_token;
        expiresAt = seeded[0]!.expires_at;
        credentialGeneration = seeded[0]!.credential_generation;
      } else {
        // Multi-user fan-out. Sync each user's cache against THEIR creds; tag
        // the per-user user_id everywhere. Aggregate sums + worst-status semantics:
        //   any 'fetch_failed' wins (operator signal); else 'ok' if any ok'd;
        //   else 'disabled'. `synced` is the sum across users.
        let total = 0;
        let agg: SyncStatus = 'disabled';
        const details: string[] = [];
        for (const c of seeded) {
          const r = await syncExternalEvents(db, env, {
            ...deps,
            userId: c.user_id,
            today,
            windowDays,
          });
          total += r.synced;
          if (r.status === 'fetch_failed') agg = 'fetch_failed';
          else if (r.status === 'superseded' && agg !== 'fetch_failed') agg = 'superseded';
          else if (r.status === 'ok' && agg === 'disabled') agg = 'ok';
          if (r.detail) details.push(r.detail);
        }
        return {
          status: agg,
          synced: total,
          ...(details.length ? { detail: details.join(',') } : {}),
        };
      }
      // Single-user path: reference owner.id for downstream logic (it equals
      // the single seeded row, but be explicit so the linter doesn't flag a
      // possibly-unused binding when the multi-user branch returns early).
      void owner;
    }

    const initialCredential = usedIntervalsCredentialIdentity(
      apiKey,
      athleteId,
      accessToken,
      refreshToken,
      expiresAt,
      credentialGeneration,
    );
    if (!initialCredential) {
      return { status: 'disabled', synced: 0, detail: 'disabled' };
    }
    const claim = await claimIntervalsSyncAttempt(db, userId, 'events', initialCredential);
    if (claim.status === 'attempt_exhausted') {
      return { status: 'fetch_failed', synced: 0, detail: 'attempt_exhausted' };
    }
    if (claim.status === 'superseded') {
      return { status: 'superseded', synced: 0, detail: 'superseded' };
    }
    const attempts = claim.attempts;
    const {
      result: fetched,
      reauthRequired,
      superseded,
      effectiveCredential,
    } = await fetchIntervalsWithAuthRecovery(
      db,
      env,
      userId,
      initialCredential,
      attempts,
      deps.fetcher,
      (token) =>
        fetchPlannedEvents(apiKey, athleteId, { ...deps, today, windowDays, accessToken: token }),
    );
    if (superseded) {
      return { status: 'superseded', synced: 0, detail: 'superseded' };
    }
    if (!fetched.ok) {
      if (
        !reauthRequired &&
        !(await isCurrentIntervalsSyncAttempt(
          db,
          userId,
          'events',
          effectiveCredential,
          attempts,
        ))
      ) {
        return { status: 'superseded', synced: 0, detail: 'superseded' };
      }
      // Disabled OR transient failure → DO NOT TOUCH the cache at all. A dead
      // credential (401/403) was just disconnected inside the recovery helper;
      // `reauthRequired` tags the operator detail so the reconnect is visible.
      return {
        status: fetched.reason === 'disabled' ? 'disabled' : 'fetch_failed',
        synced: 0,
        detail:
          fetched.reason +
          (fetched.reason === 'http' && 'status' in fetched ? `:${fetched.status}` : '') +
          (reauthRequired ? ':reauth_required' : ''),
        ...('retryAfterMs' in fetched && fetched.retryAfterMs !== undefined
          ? { retryAfterMs: fetched.retryAfterMs }
          : {}),
      };
    }
    // Window upper bound, inclusive, as a YYYY-MM-DD string (string compare is
    // valid for zero-padded ISO dates).
    const newest = addDays(today, windowDays);
    const ts = now();
    const seen = new Set<string>();
    const stmts: D1PreparedStatement[] = [];

    for (const ev of fetched.events) {
      // Per-user PK. The old "intervals:{external_id}" format collided when
      // two users returned the same upstream id; migration 0019 re-keys
      // legacy rows to the new format so this UPDATE path matches them.
      const id = `intervals:${userId}:${ev.external_id}`;
      seen.add(id);
      // Upsert by PK (id is deterministic from source+user+external_id). A
      // reschedule (same external_id, new date) just updates `date` on the
      // same row and clears any prior soft-delete (the event came back).
      stmts.push(
        db
          .prepare(
            `INSERT INTO external_events
               (id,user_id,source,external_id,date,start_date_local_ms,kind,title,description,
                planned_duration_sec,training_load,intensity,raw,synced_at,deleted_at)
             SELECT ?1,?2,'intervals',?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,NULL
              WHERE EXISTS (
                    SELECT 1 FROM users
                     WHERE id = ?2 AND intervals_credential_generation = ?14
                       AND intervals_events_sync_attempt = ?15
                  )
             ON CONFLICT(id) DO UPDATE SET
               date=excluded.date,
               start_date_local_ms=excluded.start_date_local_ms,
               kind=excluded.kind,
               title=excluded.title,
               description=excluded.description,
               planned_duration_sec=excluded.planned_duration_sec,
               training_load=excluded.training_load,
               intensity=excluded.intensity,
               raw=CASE WHEN
                 external_events.date IS NOT excluded.date OR
                 external_events.start_date_local_ms IS NOT excluded.start_date_local_ms OR
                 external_events.kind IS NOT excluded.kind OR
                 external_events.title IS NOT excluded.title OR
                 external_events.description IS NOT excluded.description OR
                 external_events.planned_duration_sec IS NOT excluded.planned_duration_sec OR
                 external_events.training_load IS NOT excluded.training_load OR
                 external_events.intensity IS NOT excluded.intensity
               THEN excluded.raw ELSE external_events.raw END,
               synced_at=CASE
                 WHEN excluded.synced_at > external_events.synced_at THEN excluded.synced_at
                 ELSE external_events.synced_at + 1
               END,
               deleted_at=NULL
             WHERE EXISTS (
                     SELECT 1 FROM users
                      WHERE id = ?2 AND intervals_credential_generation = ?14
                        AND intervals_events_sync_attempt = ?15
                   )
               AND (
                 external_events.deleted_at IS NOT NULL OR
                 external_events.date IS NOT excluded.date OR
                 external_events.start_date_local_ms IS NOT excluded.start_date_local_ms OR
                 external_events.kind IS NOT excluded.kind OR
                 external_events.title IS NOT excluded.title OR
                 external_events.description IS NOT excluded.description OR
                 external_events.planned_duration_sec IS NOT excluded.planned_duration_sec OR
                 external_events.training_load IS NOT excluded.training_load OR
                 external_events.intensity IS NOT excluded.intensity
               )`,
          )
          .bind(
            id,
            userId,
            ev.external_id,
            ev.date,
            ev.start_date_local_ms,
            ev.kind,
            ev.title,
            ev.description,
            ev.planned_duration_sec,
            ev.training_load,
            ev.intensity,
            ev.raw,
            ts,
            effectiveCredential.generation,
            attempts.eventsAttempt,
          ),
      );
    }

    // Soft-delete in-window rows that were NOT seen this sync. Rows outside
    // [today,newest] are intentionally left alone (we didn't query them).
    // Done as a single statement excluding the seen ids. Pass the set as one
    // JSON value: expanding one placeholder per provider row exceeds D1's
    // 100-bound-parameter ceiling for ordinary-sized calendars.
    const seenIds = [...seen];
    stmts.push(
      db
        .prepare(
          // Advance synced_at to the deletion time alongside deleted_at:
          // /api/state?events_since= filters `synced_at > cursor`, so a
          // tombstone that kept its old synced_at would never reach an
          // incremental client (it would keep showing the deleted ride).
          `UPDATE external_events
              SET deleted_at = CASE WHEN ?3 > synced_at THEN ?3 ELSE synced_at + 1 END,
                  synced_at = CASE WHEN ?3 > synced_at THEN ?3 ELSE synced_at + 1 END
            WHERE user_id = ?1
              AND deleted_at IS NULL
              AND date >= ?2 AND date <= ?5
              AND id NOT IN (SELECT CAST(value AS TEXT) FROM json_each(?4))
              AND EXISTS (
                    SELECT 1 FROM users
                     WHERE id = ?1 AND intervals_credential_generation = ?6
                       AND intervals_events_sync_attempt = ?7
                  )`,
        )
        .bind(
          userId,
          today,
          ts,
          JSON.stringify(seenIds),
          newest,
          effectiveCredential.generation,
          attempts.eventsAttempt,
        ),
    );
    stmts.push(
      db
        .prepare(
          `SELECT EXISTS(
                    SELECT 1 FROM users
                     WHERE id = ?1 AND intervals_credential_generation = ?2
                       AND intervals_events_sync_attempt = ?3
                  ) AS current_identity`,
        )
        .bind(userId, effectiveCredential.generation, attempts.eventsAttempt),
    );

    const reconcileResults = await db.batch(stmts);
    const generationCheck = reconcileResults.at(-1)?.results[0] as
      | { current_identity: number }
      | undefined;
    if (generationCheck?.current_identity !== 1) {
      return { status: 'superseded', synced: 0, detail: 'superseded' };
    }

    const cnt = await db
      .prepare(
        `SELECT COUNT(*) AS c FROM external_events
          WHERE user_id = ?1 AND deleted_at IS NULL
            AND date >= ?2 AND date <= ?3`,
      )
      .bind(userId, today, newest)
      .first<{ c: number }>();
    const stamped = await stampIntervalsSyncSuccess(
      db,
      userId,
      'events',
      deps.syncedAt ?? now(),
      effectiveCredential,
      attempts,
    );
    if (!stamped) return { status: 'superseded', synced: 0, detail: 'superseded' };
    return { status: 'ok', synced: cnt?.c ?? 0 };
  }

  /**
   * Non-deleted upcoming external events for a user. `range` is an inclusive
   * day count from `from` (default: today .. +90d).
   */
  async function getUpcomingRides(
    db: D1Database,
    userId: string,
    opts: { from?: string; range?: number } = {},
  ): Promise<ExternalEventRow[]> {
    const from = opts.from ?? new Date().toISOString().slice(0, 10);
    const to = addDays(from, opts.range ?? 90);
    const r = await db
      .prepare(
        `SELECT * FROM external_events
          WHERE user_id = ?1 AND deleted_at IS NULL
            AND date >= ?2 AND date <= ?3
          ORDER BY date`,
      )
      .bind(userId, from, to)
      .all<ExternalEventRow>();
    return r.results;
  }

  /** Recent-activity import after an acknowledged connect, or an explicit retry.
   * Failures describe the import and never turn a saved credential into a failed
   * connect acknowledgement. All provider/cache writes retain the existing fence. */
  async function reconcileIntervalsConnection(
    db: D1Database,
    env: Env,
    userId: string,
    expectedGeneration: number,
    deps: Pick<ActivitySyncDeps, 'fetcher' | 'today' | 'timeoutMs'> = {},
  ): Promise<IntervalsImportResult> {
    try {
      const before = await getIntervalsConnectionStatus(db, userId);
      if (before.credential_generation !== expectedGeneration) {
        return { status: 'superseded', connection: before };
      }
      if (!before.connected) {
        return { status: before.needs_reauth ? 'reconnect' : 'disconnected', connection: before };
      }
      const timeoutMs = deps.timeoutMs ?? 10_000;
      // This deadline covers response bodies and an optional OAuth refresh too;
      // the existing adapter's fetch timeout ends once headers arrive.
      const signal = AbortSignal.timeout(timeoutMs);
      const fetcher: Fetcher = deps.fetcher ?? ((input, init) => globalThis.fetch(input, {
        ...init, signal,
      }));
      const result = await syncExternalActivities(db, env, {
        ...deps, fetcher, timeoutMs, userId,
        today: deps.today ?? todayInTz(await getUserTimezone(db, userId)),
        expectedCredentialGeneration: expectedGeneration,
      });
      const connection = await getIntervalsConnectionStatus(db, userId);
      if (connection.needs_reauth) return { status: 'reconnect', connection };
      if (connection.credential_generation !== expectedGeneration || result.status === 'superseded') {
        return { status: 'superseded', connection };
      }
      return { status: result.status === 'ok' ? 'synced' : 'retry', connection };
    } catch (error) {
      console.warn({ event: 'intervals_connection_import_failed',
        error_type: diagnosticErrorType(error) });
      return { status: 'retry', connection: null };
    }
  }

  /**
   * Pull intervals.icu completed activities and reconcile the cache.
   *
   * Window is BACKWARD: [today-pastDays, today]. On a failed/disabled fetch the
   * cache is left untouched (a transient outage must never wipe completed-
   * activity history). On a successful sync, in-window rows not present in the
   * fetched set are soft-deleted (an activity deleted in intervals.icu) — with
   * synced_at advanced to the deletion time so incremental clients see it
   * (the FIX 3 tombstone rule, same as external_events).
   */
  async function syncExternalActivities(
    db: D1Database,
    env: Env,
    deps: ActivitySyncDeps = {},
  ): Promise<SyncResult> {
    const today = deps.today ?? new Date().toISOString().slice(0, 10);
    const pastDays = deps.pastDays ?? 90;

    // Mirror of syncExternalEvents: per-user credentials (M1). See that
    // function for the full rationale on explicit-user sync versus cron fan-out;
    // an eligible legacy owner env identity is persisted before either fetches.
    let userId: string;
    let apiKey: string | null | undefined;
    let athleteId: string | null | undefined;
    let accessToken: string | null | undefined;
    let refreshToken: string | null | undefined;
    let expiresAt: number | null | undefined;
    let credentialGeneration = 0;
    if (deps.userId) {
      userId = deps.userId;
      let creds = await getUserIntervalsCreds(db, userId);
      if (deps.expectedCredentialGeneration !== undefined &&
          creds.credential_generation !== deps.expectedCredentialGeneration) {
        return { status: 'superseded', synced: 0, detail: 'superseded' };
      }
      const envFallbackOk = deps.expectedCredentialGeneration === undefined && await canUseOwnerIntervalsEnvFallback(
        db,
        userId,
        deps.ownerSub ?? env.OWNER_APPLE_SUB,
        creds,
      );
      if (envFallbackOk) {
        await seedOwnerIntervalsCredsFromEnv(
          db,
          env.INTERVALS_ICU_API_KEY,
          env.INTERVALS_ICU_ATHLETE_ID,
          deps.ownerSub ?? env.OWNER_APPLE_SUB,
        );
        creds = await getUserIntervalsCreds(db, userId);
      }
      credentialGeneration = creds.credential_generation;
      apiKey = creds.api_key;
      athleteId = creds.athlete_id;
      // OAuth bearer token rides alongside (no env fallback — env is the
      // legacy API-key path only). intervals.ts prefers it over the API key.
      accessToken = creds.access_token;
      refreshToken = creds.refresh_token;
      expiresAt = creds.expires_at;
    } else {
      const owner = await ensureOwnerUser(db, deps.ownerSub ?? env.OWNER_APPLE_SUB);
      const seeded = await seedOwnerIntervalsCredsFromEnv(
        db,
        env.INTERVALS_ICU_API_KEY,
        env.INTERVALS_ICU_ATHLETE_ID,
        deps.ownerSub ?? env.OWNER_APPLE_SUB,
      );
      if (seeded.length === 0) {
        return { status: 'disabled', synced: 0, detail: 'disabled' };
      }
      if (seeded.length === 1) {
        userId = seeded[0]!.user_id;
        apiKey = seeded[0]!.api_key;
        athleteId = seeded[0]!.athlete_id;
        accessToken = seeded[0]!.access_token;
        refreshToken = seeded[0]!.refresh_token;
        expiresAt = seeded[0]!.expires_at;
        credentialGeneration = seeded[0]!.credential_generation;
      } else {
        let total = 0;
        let agg: SyncStatus = 'disabled';
        const details: string[] = [];
        for (const c of seeded) {
          const r = await syncExternalActivities(db, env, {
            ...deps,
            userId: c.user_id,
            today,
            pastDays,
          });
          total += r.synced;
          if (r.status === 'fetch_failed') agg = 'fetch_failed';
          else if (r.status === 'superseded' && agg !== 'fetch_failed') agg = 'superseded';
          else if (r.status === 'ok' && agg === 'disabled') agg = 'ok';
          if (r.detail) details.push(r.detail);
        }
        return {
          status: agg,
          synced: total,
          ...(details.length ? { detail: details.join(',') } : {}),
        };
      }
      void owner;
    }

    const initialCredential = usedIntervalsCredentialIdentity(
      apiKey,
      athleteId,
      accessToken,
      refreshToken,
      expiresAt,
      credentialGeneration,
    );
    if (!initialCredential) {
      return { status: 'disabled', synced: 0, detail: 'disabled' };
    }
    const claim = await claimIntervalsSyncAttempt(
      db,
      userId,
      'activities',
      initialCredential,
    );
    if (claim.status === 'attempt_exhausted') {
      return { status: 'fetch_failed', synced: 0, detail: 'attempt_exhausted' };
    }
    if (claim.status === 'superseded') {
      return { status: 'superseded', synced: 0, detail: 'superseded' };
    }
    const attempts = claim.attempts;
    const {
      result: fetched,
      reauthRequired,
      superseded,
      effectiveCredential,
    } = await fetchIntervalsWithAuthRecovery(
      db,
      env,
      userId,
      initialCredential,
      attempts,
      deps.fetcher,
      (token) =>
        fetchCompletedActivities(apiKey, athleteId, { ...deps, today, pastDays, accessToken: token }),
    );
    if (superseded) {
      return { status: 'superseded', synced: 0, detail: 'superseded' };
    }
    if (!fetched.ok) {
      if (
        !reauthRequired &&
        !(await isCurrentIntervalsSyncAttempt(
          db,
          userId,
          'activities',
          effectiveCredential,
          attempts,
        ))
      ) {
        return { status: 'superseded', synced: 0, detail: 'superseded' };
      }
      // Same guard as syncExternalEvents: transient/disabled leaves the cache
      // untouched; a 401/403 was just disconnected inside the recovery helper.
      return {
        status: fetched.reason === 'disabled' ? 'disabled' : 'fetch_failed',
        synced: 0,
        detail:
          fetched.reason +
          (fetched.reason === 'http' && 'status' in fetched ? `:${fetched.status}` : '') +
          (reauthRequired ? ':reauth_required' : ''),
        ...('retryAfterMs' in fetched && fetched.retryAfterMs !== undefined
          ? { retryAfterMs: fetched.retryAfterMs }
          : {}),
      };
    }
    const oldest = addDays(today, -pastDays);
    const ts = now();
    const seen = new Set<string>();
    const stmts: D1PreparedStatement[] = [];

    for (const a of fetched.activities) {
      // Per-user PK — see note in syncExternalEvents and migration 0019.
      const id = `intervals:activity:${userId}:${a.external_id}`;
      seen.add(id);
      stmts.push(
        db
          .prepare(
            `INSERT INTO external_activities
               (id,user_id,source,external_id,date,start_date_local_ms,kind,name,
                moving_time_sec,elapsed_time_sec,distance_m,average_watts,
                weighted_avg_watts,average_hr,max_hr,training_load,intensity,
                calories,elevation_gain_m,raw,synced_at,deleted_at,start_date_utc_ms)
             SELECT ?1,?2,'intervals',?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,
                    ?15,?16,?17,?18,?19,?20,NULL,?23
              WHERE EXISTS (
                    SELECT 1 FROM users
                     WHERE id = ?2 AND intervals_credential_generation = ?21
                       AND intervals_activities_sync_attempt = ?22
                  )
             ON CONFLICT(id) DO UPDATE SET
               date=excluded.date,
               start_date_local_ms=excluded.start_date_local_ms,
               start_date_utc_ms=CASE
                 WHEN excluded.start_date_utc_ms IS NOT NULL THEN excluded.start_date_utc_ms
                 WHEN external_activities.start_date_local_ms IS excluded.start_date_local_ms
                   THEN external_activities.start_date_utc_ms
                 ELSE NULL
               END,
               kind=excluded.kind,
               name=excluded.name,
               moving_time_sec=excluded.moving_time_sec,
               elapsed_time_sec=excluded.elapsed_time_sec,
               distance_m=excluded.distance_m,
               average_watts=excluded.average_watts,
               weighted_avg_watts=excluded.weighted_avg_watts,
               average_hr=excluded.average_hr,
               max_hr=excluded.max_hr,
               training_load=excluded.training_load,
               intensity=excluded.intensity,
               calories=excluded.calories,
               elevation_gain_m=excluded.elevation_gain_m,
               raw=CASE WHEN
                 (excluded.start_date_utc_ms IS NOT NULL AND external_activities.start_date_utc_ms IS NOT excluded.start_date_utc_ms) OR
                 external_activities.date IS NOT excluded.date OR
                 external_activities.start_date_local_ms IS NOT excluded.start_date_local_ms OR
                 external_activities.kind IS NOT excluded.kind OR
                 external_activities.name IS NOT excluded.name OR
                 external_activities.moving_time_sec IS NOT excluded.moving_time_sec OR
                 external_activities.elapsed_time_sec IS NOT excluded.elapsed_time_sec OR
                 external_activities.distance_m IS NOT excluded.distance_m OR
                 external_activities.average_watts IS NOT excluded.average_watts OR
                 external_activities.weighted_avg_watts IS NOT excluded.weighted_avg_watts OR
                 external_activities.average_hr IS NOT excluded.average_hr OR
                 external_activities.max_hr IS NOT excluded.max_hr OR
                 external_activities.training_load IS NOT excluded.training_load OR
                 external_activities.intensity IS NOT excluded.intensity OR
                 external_activities.calories IS NOT excluded.calories OR
                 external_activities.elevation_gain_m IS NOT excluded.elevation_gain_m OR
                 ${deviceNameSQL('external_activities.raw')} IS NOT ${deviceNameSQL('excluded.raw')}
               THEN excluded.raw ELSE external_activities.raw END,
               synced_at=CASE
                 WHEN excluded.synced_at > external_activities.synced_at THEN excluded.synced_at
                 ELSE external_activities.synced_at + 1
               END,
               deleted_at=NULL
             WHERE EXISTS (
                     SELECT 1 FROM users
                      WHERE id = ?2 AND intervals_credential_generation = ?21
                        AND intervals_activities_sync_attempt = ?22
                   )
               AND (
                 external_activities.deleted_at IS NOT NULL OR
                 (excluded.start_date_utc_ms IS NOT NULL AND external_activities.start_date_utc_ms IS NOT excluded.start_date_utc_ms) OR
                 external_activities.date IS NOT excluded.date OR
                 external_activities.start_date_local_ms IS NOT excluded.start_date_local_ms OR
                 external_activities.kind IS NOT excluded.kind OR
                 external_activities.name IS NOT excluded.name OR
                 external_activities.moving_time_sec IS NOT excluded.moving_time_sec OR
                 external_activities.elapsed_time_sec IS NOT excluded.elapsed_time_sec OR
                 external_activities.distance_m IS NOT excluded.distance_m OR
                 external_activities.average_watts IS NOT excluded.average_watts OR
                 external_activities.weighted_avg_watts IS NOT excluded.weighted_avg_watts OR
                 external_activities.average_hr IS NOT excluded.average_hr OR
                 external_activities.max_hr IS NOT excluded.max_hr OR
                 external_activities.training_load IS NOT excluded.training_load OR
                 external_activities.intensity IS NOT excluded.intensity OR
                 external_activities.calories IS NOT excluded.calories OR
                 external_activities.elevation_gain_m IS NOT excluded.elevation_gain_m OR
                 ${deviceNameSQL('external_activities.raw')} IS NOT ${deviceNameSQL('excluded.raw')}
               )`,
          )
          .bind(
            id,
            userId,
            a.external_id,
            a.date,
            a.start_date_local_ms,
            a.kind,
            a.name,
            a.moving_time_sec,
            a.elapsed_time_sec,
            a.distance_m,
            a.average_watts,
            a.weighted_avg_watts,
            a.average_hr,
            a.max_hr,
            a.training_load,
            a.intensity,
            a.calories,
            a.elevation_gain_m,
            a.raw,
            ts,
            effectiveCredential.generation,
            attempts.activitiesAttempt,
            a.start_date_utc_ms ?? null,
          ),
      );
    }

    // Soft-delete in-window rows not seen this sync (advancing synced_at so the
    // tombstone reaches incremental clients). Rows outside [oldest,today] are
    // left alone (we didn't query them). SOURCE-SCOPED to 'intervals' (Phase 0,
    // migration 0027): external_activities is now multi-source, so this reconcile
    // must only tombstone rows IT owns — without the source filter an Apple-Health
    // (or Polar/Wahoo) row would be wiped on every intervals cron tick because it
    // is never in `seen`.
    const seenIds = [...seen];
    stmts.push(
      db
        .prepare(
          `UPDATE external_activities
              SET deleted_at = CASE WHEN ?3 > synced_at THEN ?3 ELSE synced_at + 1 END,
                  synced_at = CASE WHEN ?3 > synced_at THEN ?3 ELSE synced_at + 1 END
            WHERE user_id = ?1
              AND source = 'intervals'
              AND deleted_at IS NULL
              AND date >= ?2 AND date <= ?5
              AND id NOT IN (SELECT CAST(value AS TEXT) FROM json_each(?4))
              AND EXISTS (
                    SELECT 1 FROM users
                     WHERE id = ?1 AND intervals_credential_generation = ?6
                       AND intervals_activities_sync_attempt = ?7
                  )`,
        )
        .bind(
          userId,
          oldest,
          ts,
          JSON.stringify(seenIds),
          today,
          effectiveCredential.generation,
          attempts.activitiesAttempt,
        ),
    );
    stmts.push(
      db
        .prepare(
          `SELECT EXISTS(
                    SELECT 1 FROM users
                     WHERE id = ?1 AND intervals_credential_generation = ?2
                       AND intervals_activities_sync_attempt = ?3
                  ) AS current_identity`,
        )
        .bind(userId, effectiveCredential.generation, attempts.activitiesAttempt),
    );

    const reconcileResults = await db.batch(stmts);
    const generationCheck = reconcileResults.at(-1)?.results[0] as
      | { current_identity: number }
      | undefined;
    if (generationCheck?.current_identity !== 1) {
      return { status: 'superseded', synced: 0, detail: 'superseded' };
    }

    // Cross-source dedup (Codex P2): intervals rows just changed, so retire any
    // HealthKit copies that now duplicate one — handles the ordering where the
    // HealthKit push arrived BEFORE the intervals activity synced in.
    // This reconcile can only change intervals rows in [oldest,today]. Expand
    // the dedup scope by two civil days on each side: source clocks on opposite
    // sides of the date line can differ by two dates for the same instant. Historical rows
    // outside this affected window cannot have changed during this sync.
    await dedupeHealthKitAgainstIntervals(
      db,
      userId,
      {
        healthKitFromDate: addDays(oldest, -2),
        healthKitToDate: addDays(today, 2),
        // A boundary HealthKit candidate can have a still-live winner on the
        // other side of the date line. Look two days beyond the candidate range so that
        // winner is present and the duplicate is not incorrectly restored.
        intervalsFromDate: addDays(oldest, -4),
        intervalsToDate: addDays(today, 4),
      },
      {
        generation: effectiveCredential.generation,
        attempt: attempts.activitiesAttempt,
      },
    );

    const cnt = await db
      .prepare(
        `SELECT COUNT(*) AS c FROM external_activities
          WHERE user_id = ?1 AND source = 'intervals' AND deleted_at IS NULL
            AND date >= ?2 AND date <= ?3`,
      )
      .bind(userId, oldest, today)
      .first<{ c: number }>();
    const stamped = await stampIntervalsSyncSuccess(
      db,
      userId,
      'activities',
      deps.syncedAt ?? now(),
      effectiveCredential,
      attempts,
    );
    if (!stamped) return { status: 'superseded', synced: 0, detail: 'superseded' };
    return { status: 'ok', synced: cnt?.c ?? 0 };
  }

  /**
   * Non-deleted completed activities for a user, most-recent first. `range` is
   * an inclusive day count back from `to` (default: last 90 days). `limit`
   * caps the result (default 50).
   */
  async function getRecentActivities(
    db: D1Database,
    userId: string,
    opts: { to?: string; range?: number; limit?: number } = {},
  ): Promise<Array<ExternalActivityRow & { source_attribution: string | null; attribution_version: number }>> {
    const to = opts.to ?? new Date().toISOString().slice(0, 10);
    const from = addDays(to, -(opts.range ?? 90));
    const limit = Math.max(1, Math.min(500, opts.limit ?? 50));
    const r = await db
      .prepare(
        `SELECT * FROM external_activities
          WHERE user_id = ?1 AND deleted_at IS NULL
            AND date >= ?2 AND date <= ?3
          ORDER BY date DESC
          LIMIT ?4`,
      )
      .bind(userId, from, to, limit)
      .all<ExternalActivityRow>();
    return r.results.map(withActivityAttribution);
  }
 return { syncExternalEvents, getUpcomingRides, reconcileIntervalsConnection, syncExternalActivities, getRecentActivities };
}
