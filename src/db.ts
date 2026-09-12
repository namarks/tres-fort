import { applicableSessionSwap, parseSessionExerciseSwaps } from './sessionExerciseSwaps';
import { sharedText, type GroupReportReason } from './groupSafety';
import { APP_REVIEW_SUB } from './appReview';
import { shareWorkoutSchemaCache, workoutDB } from './workoutSchema';
import { validActivitySourceTime } from './activityTime';
import { diagnosticErrorType } from './errors';
// Service layer: all D1 access goes through here so REST (now) and MCP
// (milestone b) share identical behavior. Timestamps are epoch-ms integers.
import { parseRunnerTargets, summarizeWorkout, type SummaryExercise, type SummarySet, type RunnerTargetSnapshot, type WorkoutSummary } from './workoutSummary';
import { metricCohorts, estimatedOneRepMax, positiveSetTonnage, type MetricExercise } from './metrics';
import type {
  ActivityRow,
  DayConflict,
  WorkoutRow,
  EnrichedTemplateExercise,
  Env,
  ExternalActivityRow,
  ExternalEventRow,
  Group,
  GroupInvite,
  GroupMember,
  PeriodizationPhase,
  PlanMeta,
  PlanRow,
  PlanTree,
  RaceGoal,
  ResolvedGroupMember,
  ScheduleWeek,
  SessionRow,
  SetLogRow,
  StressModel,
  TemplateExerciseRow,
  Trip,
  TripType,
  User,
  Weekday,
  WeeklySchedule,
} from './types';
import { WEEKDAYS, parsePlanMeta, serializePlanMeta } from './types';
import {
  comparePlanSnapshots,
  parsePlanSnapshot,
  serializePlanSnapshot,
  type PlanSnapshotDocument,
} from './planSnapshots';
import {
  fetchCompletedActivities,
  fetchPlannedEvents,
  type ActivityFetchDeps,
  type FetchDeps,
  type Fetcher,
} from './intervals';
import {
  hasAppleProviderSigningConfig,
  revokeAppleRefreshToken,
  type AppleProviderConfig,
} from './apple';
import {
  runWorkoutWriteBatch,
  runWorkoutWriteStatement,
} from './workout-write-fence';
import { emptyExerciseGroup, isGroupId, normalizeRemovedGroupMember, validateExerciseGroups, validatePlanExerciseGroups, type ExerciseGroupFields, type GroupConflict } from './exerciseGroups';
export type { GroupConflict } from './exerciseGroups';
const now = () => Date.now();
const uuid = () => crypto.randomUUID();

/** Snapshot the selected slot's day at the same write boundary as its first
 * accepted set. In-session overrides can differ from the session's day pin. */
function runnerTargetSnapshotSQL(dayExpression: string, timestamp: string): string {
  return `(SELECT json_object('version', 1, 'captured_at', ${timestamp}, 'plan_version', p.version,
    'slots', json((SELECT json_group_array(json_object(
      'slot_id', te.id, 'exercise_id', te.exercise_id, 'name', e.name,
      'is_warmup', te.is_warmup,
      'is_timed', CASE WHEN e.modality IN ('timed','cardio') OR te.target_duration_s IS NOT NULL THEN 1 ELSE 0 END,
      'sets', te.target_sets, 'reps', te.target_reps, 'reps_max', te.target_reps_max,
      'weight', te.target_weight, 'duration_s', te.target_duration_s, 'rpe', te.target_rpe))
      FROM template_exercises te JOIN exercises e ON e.id=te.exercise_id
      WHERE te.workout_id=d.id)))
    FROM workouts d JOIN plans p ON p.id=d.plan_id
    WHERE d.id=${dayExpression} AND p.user_id=sessions.user_id)`;
}

interface SetPrescriptionContext { plan_id: string; version: number; day_id: string }

/** Offline log intents name an immutable, owner-scoped plan snapshot. Missing
 * history stays unavailable; never substitute a newer prescription. */
async function targetsForSetPrescription(
  db: D1Database, userId: string, context: SetPrescriptionContext, capturedAt: number,
): Promise<string | null> {
  const stored = await workoutDB(db).prepare(
    'SELECT document FROM plan_snapshots WHERE user_id=?1 AND plan_id=?2 AND version=?3')
    .bind(userId, context.plan_id, context.version).first<{ document: string }>();
  if (!stored) return null;
  let day;
  try { day = parsePlanSnapshot(stored.document).workouts.find((day) => day.id === context.day_id); }
  catch { return null; }
  if (!day) return null;
  const catalog = await getExercises(db) as unknown as SummaryExercise[];
  const targets: RunnerTargetSnapshot = { version: 1, captured_at: capturedAt,
    plan_version: context.version, slots: [] };
  for (const slot of day.exercises) {
    const exercise = catalog.find((exercise) => exercise.id === slot.exercise_id);
    if (!exercise) return null;
    targets.slots.push({ slot_id: slot.id, exercise_id: slot.exercise_id, name: exercise.name,
      is_warmup: slot.is_warmup, is_timed: ['timed', 'cardio'].includes(exercise.modality)
        || slot.target_duration_s != null ? 1 : 0,
      sets: slot.target_sets, reps: slot.target_reps, reps_max: slot.target_reps_max,
      weight: slot.target_weight, duration_s: slot.target_duration_s, rpe: slot.target_rpe });
  }
  return JSON.stringify(targets);
}

// ---- D1 usage observability ---------------------------------------------

export interface D1Usage {
  query_count: number;
  rows_read: number;
  rows_written: number;
}

export interface D1UsageObserver {
  db: D1Database;
  usage: D1Usage;
}

/** Add one completed D1 query's billing counters to a request-local total. */
function addD1Usage(usage: D1Usage, result: D1Result<unknown>): void {
  usage.query_count += 1;
  usage.rows_read += result.meta.rows_read;
  usage.rows_written += result.meta.rows_written;
}

/**
 * Wrap a prepared statement so all()/run() metadata contributes to `usage`.
 * D1 first() deliberately returns no metadata, so measured paths execute the
 * same prepared query through all() and project its first row locally.
 */
function measuredStatement(
  statement: D1PreparedStatement,
  usage: D1Usage,
  originals: WeakMap<D1PreparedStatement, D1PreparedStatement>,
): D1PreparedStatement {
  const measured = new Proxy(statement, {
    get(target, property) {
      if (property === 'bind') {
        return (...values: unknown[]) => measuredStatement(target.bind(...values), usage, originals);
      }
      if (property === 'first') {
        return async (columnName?: string): Promise<unknown> => {
          const result = await target.all<Record<string, unknown>>();
          addD1Usage(usage, result);
          const first = result.results[0];
          if (first === undefined) return null;
          if (columnName === undefined) return first;
          if (!Object.prototype.hasOwnProperty.call(first, columnName)) {
            throw new Error(`D1_ERROR: column not found: ${columnName}`);
          }
          return first[columnName];
        };
      }
      if (property === 'run') {
        return async <T = Record<string, unknown>>(): Promise<D1Result<T>> => {
          const result = await target.run<T>();
          addD1Usage(usage, result);
          return result;
        };
      }
      if (property === 'all') {
        return async <T = Record<string, unknown>>(): Promise<D1Result<T>> => {
          const result = await target.all<T>();
          addD1Usage(usage, result);
          return result;
        };
      }
      const value = Reflect.get(target, property, target);
      return typeof value === 'function' ? value.bind(target) : value;
    },
  });
  originals.set(measured, statement);
  return measured;
}

/**
 * Run one request/tool/tick with a request-local D1 collector and emit one
 * searchable JSON line. The wrapper also unwraps statements before batch(),
 * then totals each result's metadata without double-counting prepared calls.
 */
export function createD1UsageObserver(db: D1Database): D1UsageObserver {
  const usage: D1Usage = { query_count: 0, rows_read: 0, rows_written: 0 };
  const originals = new WeakMap<D1PreparedStatement, D1PreparedStatement>();
  const measuredDb = new Proxy(db, {
    get(target, property) {
      if (property === 'prepare') {
        return (query: string) => measuredStatement(target.prepare(query), usage, originals);
      }
      if (property === 'batch') {
        return async <TResult = unknown>(
          statements: D1PreparedStatement[],
        ): Promise<D1Result<TResult>[]> => {
          const results = await target.batch<TResult>(
            statements.map((statement) => originals.get(statement) ?? statement),
          );
          for (const result of results) addD1Usage(usage, result);
          return results;
        };
      }
      const value = Reflect.get(target, property, target);
      return typeof value === 'function' ? value.bind(target) : value;
    },
  });
  shareWorkoutSchemaCache(measuredDb, db);
  return { db: measuredDb, usage };
}

export function logD1Usage(
  operation: string,
  outcome: 'ok' | 'error',
  usage: D1Usage,
): void {
  console.log({ event: 'd1_usage', operation, outcome, ...usage });
}

export async function observeD1Usage<T>(
  db: D1Database,
  operation: string,
  task: (measuredDb: D1Database) => Promise<T>,
  outcomeForResult?: (result: T) => 'ok' | 'error',
): Promise<T> {
  const observer = createD1UsageObserver(db);
  let outcome: 'ok' | 'error' = 'ok';
  try {
    const result = await task(observer.db);
    outcome = outcomeForResult?.(result) ?? 'ok';
    return result;
  } catch (error) {
    outcome = 'error';
    throw error;
  } finally {
    logD1Usage(operation, outcome, observer.usage);
  }
}

// ---- users ---------------------------------------------------------------

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    'SHA-256',
    new TextEncoder().encode(value),
  );
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('');
}

export function isAccountDeletionKey(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
    value,
  );
}

/**
 * Match the second half of a durable deletion-receipt credential without
 * exposing the stored digest. Used by app-JWT middleware only for the narrow
 * case where the signed bearer has expired after deletion already committed.
 */
export async function accountDeletionReceiptMatches(
  db: D1Database,
  userId: string,
  idempotencyKey: string,
): Promise<boolean> {
  if (!isAccountDeletionKey(idempotencyKey)) return false;
  const receipt = await workoutDB(db)
    .prepare(
      `SELECT idempotency_key_sha256
         FROM account_deletion_receipts WHERE user_id = ?1`,
    )
    .bind(userId)
    .first<{ idempotency_key_sha256: string }>();
  if (!receipt) return false;
  return receipt.idempotency_key_sha256 === (await sha256Hex(idempotencyKey));
}

/**
 * A signed, expired app bearer may continue only a deletion that was already
 * claimed while authentication was recent, or acknowledge its committed
 * receipt. The exact high-entropy key must match either durable row.
 */
export async function accountDeletionContinuationMatches(
  db: D1Database,
  userId: string,
  idempotencyKey: string,
): Promise<boolean> {
  if (!isAccountDeletionKey(idempotencyKey)) return false;
  const row = await workoutDB(db)
    .prepare(
      `SELECT idempotency_key_sha256
         FROM account_deletion_intents WHERE user_id = ?1
       UNION ALL
       SELECT idempotency_key_sha256
         FROM account_deletion_receipts WHERE user_id = ?1
       LIMIT 1`,
    )
    .bind(userId)
    .first<{ idempotency_key_sha256: string }>();
  return Boolean(
    row && row.idempotency_key_sha256 === (await sha256Hex(idempotencyKey)),
  );
}

/** True while the provider/local deletion operation owns this principal. */
export async function isAccountDeletionInProgress(
  db: D1Database,
  userId: string,
): Promise<boolean> {
  return (
    (await workoutDB(db)
      .prepare(
        'SELECT 1 AS x FROM account_deletion_intents WHERE user_id = ?1',
      )
      .bind(userId)
      .first<{ x: number }>()) !== null
  );
}

/**
 * Store only the caller-scoped Apple refresh token. The conditional upsert and
 * migration triggers serialize replacement against deletion intent creation.
 */
export async function storeAppleRefreshToken(
  db: D1Database,
  userId: string,
  refreshToken: string,
): Promise<boolean> {
  if (!refreshToken) return false;
  const result = await workoutDB(db)
    .prepare(
      `INSERT INTO apple_refresh_tokens (user_id, refresh_token, updated_at)
       SELECT ?1, ?2, ?3
        WHERE EXISTS (SELECT 1 FROM users WHERE id = ?1)
          AND NOT EXISTS (
                SELECT 1 FROM account_deletion_intents WHERE user_id = ?1
              )
          AND NOT EXISTS (
                SELECT 1 FROM account_deletion_receipts WHERE user_id = ?1
              )
          AND NOT EXISTS (
                SELECT 1 FROM apple_grant_exchange_state WHERE user_id = ?1
              )
       ON CONFLICT(user_id) DO UPDATE SET
         refresh_token = excluded.refresh_token,
         updated_at = excluded.updated_at`,
    )
    .bind(userId, refreshToken, now())
    .run();
  return (result.meta.changes ?? 0) === 1;
}

const APPLE_GRANT_EXCHANGE_FRESH_MS = 60_000;

/**
 * Reserve the provider-I/O gap for one Sign in with Apple code exchange.
 * A fresh active reservation wins. An abandoned active reservation may be
 * replaced after 60 seconds, but doing so permanently records revocation
 * uncertainty because Apple may have issued a grant to the abandoned call.
 */
export async function beginAppleGrantExchange(
  db: D1Database,
  userId: string,
  reservationId: string,
  nowMs = now(),
): Promise<boolean> {
  if (!isAccountDeletionKey(reservationId)) return false;
  const staleBefore = nowMs - APPLE_GRANT_EXCHANGE_FRESH_MS;
  const result = await workoutDB(db)
    .prepare(
      `INSERT INTO apple_grant_exchange_state
         (user_id, reservation_id, active_since, revocation_uncertain)
       SELECT id, ?2, ?3, 0 FROM users
        WHERE id = ?1
          AND NOT EXISTS (
                SELECT 1 FROM account_deletion_intents WHERE user_id = ?1
              )
          AND NOT EXISTS (
                SELECT 1 FROM account_deletion_receipts WHERE user_id = ?1
              )
       ON CONFLICT(user_id) DO UPDATE SET
         reservation_id = excluded.reservation_id,
         active_since = excluded.active_since,
         revocation_uncertain = CASE
           WHEN apple_grant_exchange_state.reservation_id IS NOT NULL
            AND apple_grant_exchange_state.active_since < ?4
           THEN 1
           ELSE apple_grant_exchange_state.revocation_uncertain
         END
       WHERE (
               apple_grant_exchange_state.reservation_id IS NULL
            OR apple_grant_exchange_state.active_since < ?4
             )
         AND NOT EXISTS (
               SELECT 1 FROM account_deletion_intents WHERE user_id = ?1
             )
         AND NOT EXISTS (
               SELECT 1 FROM account_deletion_receipts WHERE user_id = ?1
             )`,
    )
    .bind(userId, reservationId, nowMs, staleBefore)
    .run();
  return (result.meta.changes ?? 0) === 1;
}

/**
 * Record that Apple may have accepted the matching exchange even though the
 * caller did not receive a trustworthy token response. Uncertainty survives
 * every later exchange and forces manual provider cleanup at deletion.
 */
export async function markAppleGrantExchangeUncertain(
  db: D1Database,
  userId: string,
  reservationId: string,
): Promise<boolean> {
  if (!isAccountDeletionKey(reservationId)) return false;
  const result = await workoutDB(db)
    .prepare(
      `UPDATE apple_grant_exchange_state
          SET reservation_id = NULL,
              active_since = NULL,
              revocation_uncertain = 1
        WHERE user_id = ?1 AND reservation_id = ?2`,
    )
    .bind(userId, reservationId)
    .run();
  return (result.meta.changes ?? 0) === 1;
}

/**
 * Store the newly returned refresh token while retaining exactly its active
 * reservation. Keeping that row through the storage commit is deliberate: if
 * D1 commits and the binding then throws, the route can still mark the exact
 * exchange uncertain and deletion remains blocked until it does. A separate
 * acknowledgement clears the reservation only after this call returns.
 */
export async function finishAppleGrantExchange(
  db: D1Database,
  userId: string,
  reservationId: string,
  refreshToken: string,
): Promise<boolean> {
  if (!isAccountDeletionKey(reservationId) || !refreshToken) return false;
  const ts = now();
  const [stored, retained] = await workoutDB(db).batch([
    workoutDB(db)
      .prepare(
        `INSERT INTO apple_refresh_tokens (user_id, refresh_token, updated_at)
         SELECT s.user_id, ?3, ?4
           FROM apple_grant_exchange_state s
          WHERE s.user_id = ?1
            AND s.reservation_id = ?2
            AND EXISTS (SELECT 1 FROM users WHERE id = ?1)
            AND NOT EXISTS (
                  SELECT 1 FROM account_deletion_intents WHERE user_id = ?1
                )
            AND NOT EXISTS (
                  SELECT 1 FROM account_deletion_receipts WHERE user_id = ?1
                )
         ON CONFLICT(user_id) DO UPDATE SET
           refresh_token = excluded.refresh_token,
           updated_at = excluded.updated_at`,
      )
      .bind(userId, reservationId, refreshToken, ts),
    workoutDB(db)
      .prepare(
        `UPDATE apple_grant_exchange_state
            SET active_since = ?3
          WHERE user_id = ?1
            AND reservation_id = ?2
            AND changes() = 1`,
      )
      .bind(userId, reservationId, ts),
  ]);
  return (
    (stored?.meta.changes ?? 0) === 1 &&
    (retained?.meta.changes ?? 0) === 1
  );
}

/**
 * Acknowledge a refresh-token store that the caller observed as successful.
 * Clearing and clean-row deletion remain exact-reservation conditional; any
 * prior sticky uncertainty survives for deletion to consume. If this call is
 * ambiguous, the route can safely attempt the exact uncertainty marker: a
 * committed acknowledgement means the token is known, while an uncommitted
 * acknowledgement still has the reservation available to mark fail-closed.
 */
export async function acknowledgeAppleGrantExchange(
  db: D1Database,
  userId: string,
  reservationId: string,
): Promise<boolean> {
  if (!isAccountDeletionKey(reservationId)) return false;
  const [cleared, removed] = await workoutDB(db).batch([
    workoutDB(db)
      .prepare(
        `UPDATE apple_grant_exchange_state
            SET reservation_id = NULL, active_since = NULL
          WHERE user_id = ?1 AND reservation_id = ?2`,
      )
      .bind(userId, reservationId),
    workoutDB(db)
      .prepare(
        `DELETE FROM apple_grant_exchange_state
          WHERE user_id = ?1
            AND reservation_id IS NULL
            AND revocation_uncertain = 0
            AND changes() = 1`,
      )
      .bind(userId),
  ]);
  const clearedCount = cleared?.meta.changes ?? 0;
  const removedCount = removed?.meta.changes ?? 0;
  return clearedCount === 1 && (removedCount === 0 || removedCount === 1);
}

/**
 * Account deletion is terminal for the distinguished owner until an
 * administrator deliberately clears the singleton tombstone. Keeping this
 * check independent of the users table prevents static MCP/bootstrap traffic
 * from recreating the owner or promoting the earliest surviving member.
 */
export async function isOwnerDeletionTombstoned(
  db: D1Database,
): Promise<boolean> {
  const row = await workoutDB(db)
    .prepare('SELECT 1 AS x FROM owner_deletion_tombstone WHERE singleton = 1')
    .first<{ x: number }>();
  return row !== null;
}

/**
 * Durable owner-deletion history survives administrative removal of the
 * identity tombstone. It prevents the legacy OWNER_APPLE_SUB-unset fallback
 * from treating the earliest surviving member as the new distinguished owner.
 */
async function hasOwnerDeletionReceipt(db: D1Database): Promise<boolean> {
  const row = await workoutDB(db)
    .prepare(
      `SELECT 1 AS x FROM account_deletion_receipts
        WHERE owner_tombstoned = 1 LIMIT 1`,
    )
    .first<{ x: number }>();
  return row !== null;
}

/** True only for the Apple identity that deleted the owner account. */
export async function isDeletedOwnerAppleSub(
  db: D1Database,
  appleSub: string,
): Promise<boolean> {
  const row = await workoutDB(db)
    .prepare(
      'SELECT apple_sub_sha256 FROM owner_deletion_tombstone WHERE singleton = 1',
    )
    .first<{ apple_sub_sha256: string }>();
  if (!row) return false;
  return row.apple_sub_sha256 === (await sha256Hex(appleSub));
}

export async function upsertUser(
  db: D1Database,
  appleSub: string,
  email: string | null,
  displayName: string | null,
): Promise<User> {
  const existing = await workoutDB(db)
    .prepare('SELECT * FROM users WHERE apple_sub = ?1')
    .bind(appleSub)
    .first<User>();
  if (existing) {
    if (displayName && !existing.display_name) {
      await workoutDB(db)
        .prepare('UPDATE users SET display_name = ?2 WHERE id = ?1')
        .bind(existing.id, displayName)
        .run();
      existing.display_name = displayName;
    }
    return existing;
  }
  const user: User = {
    id: uuid(),
    apple_sub: appleSub,
    email,
    display_name: displayName,
    created_at: now(),
    timezone: null,
    intervals_api_key: null,
    intervals_athlete_id: null,
    intervals_cutover_athlete_id: null,
    intervals_oauth_access_token: null,
    intervals_oauth_refresh_token: null,
    intervals_oauth_expires_at: null,
    intervals_auth_error_at: null,
    intervals_credential_generation: 0,
    intervals_events_synced_at: null,
    intervals_activities_synced_at: null,
    intervals_events_sync_attempt: 0,
    intervals_activities_sync_attempt: 0,
    intervals_protocol_write_seq: 0,
    mcp_passphrase_hash: null,
    mcp_passphrase_salt: null,
  };
  await workoutDB(db)
    .prepare(
      'INSERT INTO users (id, apple_sub, email, display_name, created_at) VALUES (?1,?2,?3,?4,?5)',
    )
    .bind(user.id, user.apple_sub, user.email, user.display_name, user.created_at)
    .run();
  return user;
}

/**
 * Open-sign-in creation path that cannot recreate the deliberately deleted
 * owner identity. The one-way identity comparison and INSERT share one SQLite
 * statement, so a concurrent owner deletion that wins the write lock also
 * prevents a stale sign-in request from inserting the same Apple subject.
 */
export async function upsertUserUnlessDeletedOwner(
  db: D1Database,
  appleSub: string,
  email: string | null,
  displayName: string | null,
): Promise<User | null> {
  const candidateId = uuid();
  const createdAt = now();
  const appleSubHash = await sha256Hex(appleSub);
  await workoutDB(db)
    .prepare(
      `INSERT INTO users (id, apple_sub, email, display_name, created_at)
       SELECT ?1, ?2, ?3, ?4, ?5
        WHERE NOT EXISTS (
                SELECT 1 FROM owner_deletion_tombstone
                 WHERE singleton = 1 AND apple_sub_sha256 = ?6
              )
       ON CONFLICT(apple_sub) DO NOTHING`,
    )
    .bind(candidateId, appleSub, email, displayName, createdAt, appleSubHash)
    .run();
  return workoutDB(db)
    .prepare(
      `SELECT u.* FROM users u
        WHERE u.apple_sub = ?1
          AND NOT EXISTS (
                SELECT 1 FROM owner_deletion_tombstone
                 WHERE singleton = 1 AND apple_sub_sha256 = ?2
              )`,
    )
    .bind(appleSub, appleSubHash)
    .first<User>();
}

/**
 * Create the distinguished owner only while no terminal owner tombstone
 * exists. The predicate and INSERT share one SQLite statement, so a deletion
 * that wins the write lock cannot be followed by a stale bootstrap request
 * recreating the owner.
 */
async function insertOwnerUnlessTombstoned(
  db: D1Database,
  appleSub: string,
  email: string | null,
  displayName: string | null,
  requireEmptyUsers: boolean,
): Promise<User | null> {
  if (appleSub === APP_REVIEW_SUB) return null;
  const candidate: User = {
    id: uuid(),
    apple_sub: appleSub,
    email,
    display_name: displayName,
    created_at: now(),
    timezone: null,
    intervals_api_key: null,
    intervals_athlete_id: null,
    intervals_cutover_athlete_id: null,
    intervals_oauth_access_token: null,
    intervals_oauth_refresh_token: null,
    intervals_oauth_expires_at: null,
    intervals_auth_error_at: null,
    intervals_credential_generation: 0,
    intervals_events_synced_at: null,
    intervals_activities_synced_at: null,
    intervals_events_sync_attempt: 0,
    intervals_activities_sync_attempt: 0,
    intervals_protocol_write_seq: 0,
    mcp_passphrase_hash: null,
    mcp_passphrase_salt: null,
  };
  await workoutDB(db)
    .prepare(
      `INSERT INTO users (id, apple_sub, email, display_name, created_at)
       SELECT ?1, ?2, ?3, ?4, ?5
        WHERE NOT EXISTS (
                SELECT 1 FROM owner_deletion_tombstone WHERE singleton = 1
              )
          AND (?6 = 0 OR NOT EXISTS (SELECT 1 FROM users WHERE apple_sub != ?7))
       ON CONFLICT(apple_sub) DO NOTHING`,
    )
    .bind(
      candidate.id,
      candidate.apple_sub,
      candidate.email,
      candidate.display_name,
      candidate.created_at,
      requireEmptyUsers ? 1 : 0,
      APP_REVIEW_SUB,
    )
    .run();
  return workoutDB(db)
    .prepare(
      `SELECT u.* FROM users u
        WHERE u.apple_sub = ?1
          AND NOT EXISTS (
                SELECT 1 FROM owner_deletion_tombstone WHERE singleton = 1
              )`,
    )
    .bind(appleSub)
    .first<User>();
}

/**
 * Sign in with Apple owner resolution. Single-user invariant: there is
 * exactly one user row. If this Apple sub is unseen and the only existing
 * user is the MCP bootstrap sentinel, *claim* that row — rebinding it to the
 * real Apple identity — so MCP-seeded data and iOS stay on one user_id.
 * The claim is a compare-and-swap: a concurrent sign-in that loses the
 * sentinel creates an ordinary user instead of stealing the winner's row.
 */
export async function claimOrCreateOwner(
  db: D1Database,
  appleSub: string,
  email: string | null,
  displayName: string | null,
  ownerSubLocked: boolean,
): Promise<User | null> {
  if (appleSub === APP_REVIEW_SUB) return null;
  const byApple = await workoutDB(db)
    .prepare(
      `SELECT u.* FROM users u
        WHERE u.apple_sub = ?1
          AND NOT EXISTS (
                SELECT 1 FROM owner_deletion_tombstone WHERE singleton = 1
              )`,
    )
    .bind(appleSub)
    .first<User>();
  if (byApple) return byApple;

  if (!ownerSubLocked) {
    const bootstrap = await workoutDB(db)
      .prepare('SELECT * FROM users WHERE apple_sub = ?1')
      .bind(BOOTSTRAP_APPLE_SUB)
      .first<User>();
    if (bootstrap) {
      const claimed = await workoutDB(db)
        .prepare(
          `UPDATE users
              SET apple_sub = ?2, email = ?3, display_name = ?4
            WHERE id = ?1
              AND apple_sub = ?5
              AND NOT EXISTS (
                    SELECT 1 FROM owner_deletion_tombstone WHERE singleton = 1
                  )`,
        )
        .bind(
          bootstrap.id,
          appleSub,
          email ?? bootstrap.email,
          displayName ?? bootstrap.display_name,
          BOOTSTRAP_APPLE_SUB,
        )
        .run();
      if ((claimed.meta.changes ?? 0) === 1) {
        return workoutDB(db)
          .prepare(
            `SELECT u.* FROM users u
              WHERE u.id = ?1 AND u.apple_sub = ?2
                AND NOT EXISTS (
                      SELECT 1 FROM owner_deletion_tombstone WHERE singleton = 1
                    )`,
          )
          .bind(bootstrap.id, appleSub)
          .first<User>();
      }
    }
  }
  return insertOwnerUnlessTombstoned(db, appleSub, email, displayName, false);
}

/**
 * Sentinel apple_sub the MCP bootstrap path stamps on the seeded owner row
 * when OWNER_APPLE_SUB is unset. iOS sign-in detects this value to decide
 * whether the sole users row is an unclaimed bootstrap (safe to claim) vs.
 * a real Apple-bound account (must NOT be re-claimed by a different sub).
 */
export const BOOTSTRAP_APPLE_SUB = 'mcp-owner';

/**
 * Resolve the single owner user for MCP calls. The MCP principal is "Claude
 * acting as the owner", not an end-user login — so it maps to the one user
 * row. If none exists yet (iOS app not built), bootstrap it so Claude can
 * start building a plan in chat before milestone (d).
 */
export async function ensureOwnerUser(
  db: D1Database,
  ownerAppleSub: string | undefined,
): Promise<User | null> {
  const existing = await findOwnerRow(db, ownerAppleSub);
  if (existing) return existing;
  // Clearing the identity tombstone re-enables explicit recovery, but it must
  // not restore the old implicit bootstrap/earliest-user behavior. Configure
  // a replacement OWNER_APPLE_SUB or deliberately insert the bootstrap
  // sentinel before calling this path.
  if (!ownerAppleSub && (await hasOwnerDeletionReceipt(db))) return null;
  return insertOwnerUnlessTombstoned(
    db,
    ownerAppleSub ?? BOOTSTRAP_APPLE_SUB,
    null,
    'Owner',
    !ownerAppleSub,
  );
}

/**
 * Find the owner user row. Two semantics depending on whether the
 * deployment has configured an OWNER_APPLE_SUB allowlist:
 *
 *  - ownerAppleSub SET → look up by apple_sub. The owner is specifically
 *    the row whose apple_sub matches the configured allowlist; "earliest
 *    user by created_at" would be wrong here because open sign-in (Path
 *    4 in /auth/apple) can create non-owner accounts before the owner
 *    ever signs in or MCP seeds the row. Treating a reviewer/new-user
 *    row as the owner would attribute Claude's plan + sets + intervals
 *    creds to the wrong user. (Codex PR #38 P1.)
 *  - ownerAppleSub UNSET → fall back to "earliest by created_at" only before
 *    any distinguished-owner deletion. After deletion history exists, an
 *    explicitly inserted bootstrap sentinel is the only owner row this mode
 *    will resolve; ordinary surviving members are never promoted.
 *
 * Returns null when no matching row exists; the caller chooses whether
 * to seed (ensureOwnerUser) or no-op (seedOwnerIntervalsCredsFromEnv).
 */
export async function findOwnerRow(
  db: D1Database,
  ownerAppleSub: string | undefined,
): Promise<User | null> {
  if (ownerAppleSub === APP_REVIEW_SUB) return null;
  if (ownerAppleSub) {
    return await workoutDB(db)
      .prepare(
        `SELECT u.* FROM users u
          WHERE u.apple_sub = ?1
            AND NOT EXISTS (
                  SELECT 1 FROM owner_deletion_tombstone WHERE singleton = 1
                )`,
      )
      .bind(ownerAppleSub)
      .first<User>();
  }
  if (await hasOwnerDeletionReceipt(db)) {
    return await workoutDB(db)
      .prepare(
        `SELECT u.* FROM users u
          WHERE u.apple_sub = ?1
            AND NOT EXISTS (
                  SELECT 1 FROM owner_deletion_tombstone WHERE singleton = 1
                )
          LIMIT 1`,
      )
      .bind(BOOTSTRAP_APPLE_SUB)
      .first<User>();
  }
  return await workoutDB(db)
    .prepare(
      `SELECT u.* FROM users u
        WHERE u.apple_sub != ?1 AND NOT EXISTS (
                SELECT 1 FROM owner_deletion_tombstone WHERE singleton = 1
              )
        ORDER BY u.created_at LIMIT 1`,
    )
    .bind(APP_REVIEW_SUB)
    .first<User>();
}

/** Create the shared sample principal and its initial plan in one transaction.
 * Repeat/concurrent sign-in never resets edits. After deletion a fresh UUID
 * prevents old bearers regaining access. No owner/provider data is copied. */
export async function ensureAppReviewUser(db: D1Database): Promise<User | null> {
  const userId = uuid(), planId = uuid(), workoutId = uuid(), ts = now();
  const sql = workoutDB(db);
  const statements = [
    sql.prepare(`INSERT INTO users (id,apple_sub,display_name,created_at)
      VALUES (?1,?2,'App Review',?3) ON CONFLICT(apple_sub) DO NOTHING`)
      .bind(userId, APP_REVIEW_SUB, ts),
    sql.prepare(`INSERT INTO plans (id,user_id,name,status,version,meta,created_at,updated_at)
      SELECT ?1,id,'Sample training','active',1,?3,?4,?4 FROM users WHERE id=?2`)
      .bind(planId, userId, JSON.stringify({ schedule: { version: 1, week: {
        mon: workoutId, tue: null, wed: workoutId, thu: null, fri: workoutId, sat: null, sun: null,
      } } }), ts),
    sql.prepare(`INSERT INTO workouts (id,plan_id,name,day_label,order_index,created_at,updated_at)
      SELECT ?1,id,'Sample strength','Strength A',0,?3,?3 FROM plans WHERE id=?2`)
      .bind(workoutId, planId, ts),
  ];
  for (const [index, exercise] of ['ex_back_squat', 'ex_bench', 'ex_barbell_row'].entries()) {
    statements.push(sql.prepare(`INSERT INTO template_exercises
      (id,workout_id,exercise_id,order_index,target_sets,target_reps,rest_seconds,created_at,updated_at)
      SELECT ?1,id,?3,?4,3,5,90,?5,?5 FROM workouts WHERE id=?2`)
      .bind(uuid(), workoutId, exercise, index, ts));
  }
  statements.push(preparePlanSnapshotInsert(db, {
    userId, planId, actor: 'system', operation: 'app_review_sample', createdAt: ts,
  }));
  statements.push(sql.prepare(`INSERT INTO audit_log (id,user_id,actor,tool,args,result,created_at)
    SELECT ?1,id,'system','app_review_sample','{}','created',?3 FROM users WHERE id=?2`)
    .bind(uuid(), userId, ts));
  await sql.batch(statements);
  const user = await sql.prepare('SELECT * FROM users WHERE apple_sub=?1').bind(APP_REVIEW_SUB).first<User>();
  return user && !(await isAccountDeletionInProgress(db, user.id)) ? user : null;
}

/**
 * Sign-in bootstrap eligibility for the OWNER_APPLE_SUB-unset path: true
 * when (a) the users table is empty (fresh deploy) OR (b) the only row is
 * the MCP-seeded bootstrap sentinel still waiting to be claimed by a real
 * Apple identity. A second case must NEVER claim a row that's already been
 * bound to a real apple_sub, hence the strict sentinel match.
 */
export async function isBootstrapClaimEligible(db: D1Database): Promise<boolean> {
  if (
    (await isOwnerDeletionTombstoned(db)) ||
    (await hasOwnerDeletionReceipt(db))
  ) {
    return false;
  }
  const rows = await workoutDB(db)
    .prepare('SELECT apple_sub FROM users WHERE apple_sub != ?1')
    .bind(APP_REVIEW_SUB)
    .all<{ apple_sub: string }>();
  if (rows.results.length === 0) return true;
  if (rows.results.length === 1) {
    return rows.results[0]!.apple_sub === BOOTSTRAP_APPLE_SUB;
  }
  return false;
}

export type AppleRevocationOutcome = 'revoked' | 'manual_required';

export type DeleteUserAccountResult =
  | {
      ok: true;
      owner_tombstoned: boolean;
      apple_revocation: AppleRevocationOutcome;
    }
  | { error: 'not_found' | 'conflict' };

export interface DeleteUserAccountDeps {
  appleConfig?: AppleProviderConfig;
  /** Test seam for deterministic provider success, failure, and race cases. */
  revokeAppleToken?: (
    config: AppleProviderConfig,
    refreshToken: string,
  ) => Promise<void>;
}

interface AccountDeletionReceiptRow {
  idempotency_key_sha256: string;
  owner_tombstoned: number;
  apple_revocation: AppleRevocationOutcome;
}

async function getAccountDeletionReceipt(
  db: D1Database,
  userId: string,
): Promise<AccountDeletionReceiptRow | null> {
  return workoutDB(db)
    .prepare(
      `SELECT idempotency_key_sha256, owner_tombstoned, apple_revocation
         FROM account_deletion_receipts WHERE user_id = ?1`,
    )
    .bind(userId)
    .first<AccountDeletionReceiptRow>();
}

function receiptResult(
  receipt: AccountDeletionReceiptRow,
): Extract<DeleteUserAccountResult, { ok: true }> {
  return {
    ok: true,
    owner_tombstoned: receipt.owner_tombstoned === 1,
    apple_revocation: receipt.apple_revocation,
  };
}

/**
 * Permanently remove one authenticated account and every row it owns.
 *
 * D1 batch execution is transactional: the owner tombstone, group transfer,
 * descendant cleanup, credential/token revocation, and final users-row delete
 * either all commit or none do. Exercises and shared groups/member data are
 * intentionally retained. A creator's surviving group transfers to its
 * longest-tenured remaining member (user id is the deterministic tie-breaker);
 * a group with no remaining member is removed.
 */
export async function deleteUserAccount(
  db: D1Database,
  userId: string,
  ownerAppleSub: string | undefined,
  idempotencyKey: string,
  deps: DeleteUserAccountDeps = {},
): Promise<DeleteUserAccountResult> {
  const idempotencyKeyHash = await sha256Hex(idempotencyKey);
  const claimTime = now();
  const staleExchangeBefore =
    claimTime - APPLE_GRANT_EXCHANGE_FRESH_MS;
  // Claim the destructive operation under D1's write lock before provider
  // I/O. INSERT OR IGNORE makes a different key lose without changing the
  // winner; a matching key may safely resume an interrupted intent. A fresh
  // Apple exchange reservation blocks the claim. Sticky uncertainty or a
  // stale active exchange is consumed into an immediately-sticky manual
  // outcome, so deletion can never report revocation of only an older grant.
  await workoutDB(db).batch([
    workoutDB(db)
      .prepare(
        `INSERT OR IGNORE INTO account_deletion_intents
           (user_id, idempotency_key_sha256, apple_revocation, created_at)
         SELECT u.id,
                ?2,
                CASE
                  WHEN COALESCE(s.revocation_uncertain, 0) = 1
                    OR (
                      s.reservation_id IS NOT NULL
                      AND s.active_since < ?4
                    )
                  THEN 'manual_required'
                  ELSE NULL
                END,
                ?3
           FROM users u
           LEFT JOIN apple_grant_exchange_state s ON s.user_id = u.id
          WHERE u.id = ?1
            AND NOT EXISTS (
                  SELECT 1 FROM account_deletion_receipts WHERE user_id = ?1
                )
            AND NOT (
                  s.reservation_id IS NOT NULL
                  AND s.active_since >= ?4
                )`,
      )
      .bind(userId, idempotencyKeyHash, claimTime, staleExchangeBefore),
    workoutDB(db)
      .prepare(
        `DELETE FROM apple_grant_exchange_state
          WHERE user_id = ?1
            AND EXISTS (
                  SELECT 1 FROM account_deletion_intents
                   WHERE user_id = ?1
                     AND idempotency_key_sha256 = ?2
                )`,
      )
      .bind(userId, idempotencyKeyHash),
  ]);

  const priorReceipt = await getAccountDeletionReceipt(db, userId);
  if (priorReceipt) {
    return priorReceipt.idempotency_key_sha256 === idempotencyKeyHash
      ? receiptResult(priorReceipt)
      : { error: 'not_found' };
  }

  let intent = await workoutDB(db)
    .prepare(
      `SELECT idempotency_key_sha256, apple_revocation
         FROM account_deletion_intents WHERE user_id = ?1`,
    )
    .bind(userId)
    .first<{
      idempotency_key_sha256: string;
      apple_revocation: AppleRevocationOutcome | null;
    }>();
  if (!intent || intent.idempotency_key_sha256 !== idempotencyKeyHash) {
    // A live intent bound to another high-entropy key is a collision, not
    // proof that the account disappeared. iOS reserves 404 for cross-device
    // completion and must not erase local state for this case.
    if (intent) return { error: 'conflict' };
    const liveUser = await workoutDB(db)
      .prepare('SELECT 1 AS x FROM users WHERE id = ?1')
      .bind(userId)
      .first<{ x: number }>();
    return liveUser ? { error: 'conflict' } : { error: 'not_found' };
  }

  let appleRevocation = intent.apple_revocation;
  if (appleRevocation === null) {
    const credential = await workoutDB(db)
      .prepare(
        'SELECT refresh_token FROM apple_refresh_tokens WHERE user_id = ?1',
      )
      .bind(userId)
      .first<{ refresh_token: string }>();
    appleRevocation = 'manual_required';
    if (
      credential &&
      deps.appleConfig &&
      hasAppleProviderSigningConfig(deps.appleConfig)
    ) {
      try {
        await (deps.revokeAppleToken ?? revokeAppleRefreshToken)(
          deps.appleConfig,
          credential.refresh_token,
        );
        appleRevocation = 'revoked';
      } catch {
        // Provider unavailability must never retain the user's local account.
        // The value-free outcome sends iOS to Apple's manual revocation path.
        appleRevocation = 'manual_required';
      }
    }

    // Persist provider truth on the intent immediately. If local finalization
    // is interrupted, a matching retry skips provider I/O and carries this
    // exact outcome into the durable receipt.
    await workoutDB(db)
      .prepare(
        `UPDATE account_deletion_intents
            SET apple_revocation = ?3
          WHERE user_id = ?1
            AND idempotency_key_sha256 = ?2
            AND apple_revocation IS NULL`,
      )
      .bind(userId, idempotencyKeyHash, appleRevocation)
      .run();
    intent = await workoutDB(db)
      .prepare(
        `SELECT idempotency_key_sha256, apple_revocation
           FROM account_deletion_intents WHERE user_id = ?1`,
      )
      .bind(userId)
      .first<{
        idempotency_key_sha256: string;
        apple_revocation: AppleRevocationOutcome | null;
      }>();
    if (!intent) {
      const committed = await getAccountDeletionReceipt(db, userId);
      return committed?.idempotency_key_sha256 === idempotencyKeyHash
        ? receiptResult(committed)
        : { error: 'not_found' };
    }
    if (
      intent.idempotency_key_sha256 !== idempotencyKeyHash ||
      intent.apple_revocation === null
    ) {
      return { error: 'not_found' };
    }
    appleRevocation = intent.apple_revocation;
  }

  const user = await workoutDB(db)
    .prepare('SELECT * FROM users WHERE id = ?1')
    .bind(userId)
    .first<User>();
  if (!user) {
    const committed = await getAccountDeletionReceipt(db, userId);
    return committed?.idempotency_key_sha256 === idempotencyKeyHash
      ? receiptResult(committed)
      : { error: 'not_found' };
  }

  const owner = await findOwnerRow(db, ownerAppleSub);
  const deletingOwner = owner?.id === userId;
  const deletionTime = now();
  const statements: D1PreparedStatement[] = [
    workoutDB(db)
      .prepare(
        `INSERT OR IGNORE INTO account_deletion_receipts
           (user_id, idempotency_key_sha256, owner_tombstoned, deleted_at,
            apple_revocation)
         VALUES (?1, ?2, ?3, ?4, ?5)`,
      )
      .bind(
        userId,
        idempotencyKeyHash,
        deletingOwner ? 1 : 0,
        deletionTime,
        appleRevocation,
      ),
  ];

  if (deletingOwner) {
    statements.push(
      workoutDB(db)
        .prepare(
          `INSERT INTO owner_deletion_tombstone
             (singleton, apple_sub_sha256, deleted_at)
           VALUES (1, ?1, ?2)
           ON CONFLICT(singleton) DO UPDATE SET
             apple_sub_sha256 = excluded.apple_sub_sha256,
             deleted_at = excluded.deleted_at`,
        )
        .bind(await sha256Hex(user.apple_sub), deletionTime),
    );
  }

  // Empty groups owned by the caller have no shared state to preserve.
  statements.push(
    workoutDB(db)
      .prepare(
        `DELETE FROM group_invites
          WHERE group_id IN (
            SELECT g.id FROM groups g
             WHERE g.created_by = ?1
               AND NOT EXISTS (
                 SELECT 1 FROM group_members gm
                  WHERE gm.group_id = g.id AND gm.user_id <> ?1
               )
          )`,
      )
      .bind(userId),
    workoutDB(db)
      .prepare(
        `DELETE FROM group_members
          WHERE group_id IN (
            SELECT g.id FROM groups g
             WHERE g.created_by = ?1
               AND NOT EXISTS (
                 SELECT 1 FROM group_members gm
                  WHERE gm.group_id = g.id AND gm.user_id <> ?1
               )
          )`,
      )
      .bind(userId),
    workoutDB(db)
      .prepare(
        `DELETE FROM groups
          WHERE created_by = ?1
            AND NOT EXISTS (
              SELECT 1 FROM group_members gm
               WHERE gm.group_id = groups.id AND gm.user_id <> ?1
            )`,
      )
      .bind(userId),

    // Preserve a shared group by transferring its creator anchor before the
    // deleting user's membership and users row disappear.
    workoutDB(db)
      .prepare(
        `UPDATE groups
            SET created_by = (
              SELECT gm.user_id FROM group_members gm
               WHERE gm.group_id = groups.id AND gm.user_id <> ?1
               ORDER BY gm.joined_at, gm.user_id
               LIMIT 1
            )
          WHERE created_by = ?1
            AND EXISTS (
              SELECT 1 FROM group_members gm
               WHERE gm.group_id = groups.id AND gm.user_id <> ?1
            )`,
      )
      .bind(userId),

    // Invites created by the account are credentials and are revoked. Invites
    // another member created remain, but no longer retain used_by attribution
    // to the deleted account.
    workoutDB(db).prepare('DELETE FROM group_invites WHERE created_by = ?1').bind(userId),
    workoutDB(db).prepare('UPDATE group_invites SET used_by = NULL WHERE used_by = ?1').bind(userId),
    workoutDB(db).prepare('DELETE FROM group_members WHERE user_id = ?1').bind(userId),

    // Session-dependent ledgers and logs must go before their canonical
    // sessions; the plan tree follows sessions because those rows hold plan/day
    // references under strict foreign keys.
    workoutDB(db)
      .prepare(
        `DELETE FROM session_aliases
          WHERE canonical_session_id IN (
            SELECT id FROM sessions WHERE user_id = ?1
          )`,
      )
      .bind(userId),
    workoutDB(db)
      .prepare(
        `DELETE FROM session_load_exports
          WHERE session_id IN (SELECT id FROM sessions WHERE user_id = ?1)`,
      )
      .bind(userId),
    workoutDB(db)
      .prepare(
        `DELETE FROM set_logs
          WHERE session_id IN (SELECT id FROM sessions WHERE user_id = ?1)`,
      )
      .bind(userId),
    workoutDB(db).prepare('DELETE FROM sessions WHERE user_id = ?1').bind(userId),
    workoutDB(db).prepare('DELETE FROM plan_snapshots WHERE user_id = ?1').bind(userId),
    workoutDB(db)
      .prepare(
        `DELETE FROM template_exercises
          WHERE workout_id IN (
            SELECT d.id FROM workouts d
            JOIN plans p ON p.id = d.plan_id
            WHERE p.user_id = ?1
          )`,
      )
      .bind(userId),
    workoutDB(db)
      .prepare(
        `DELETE FROM workouts
          WHERE plan_id IN (SELECT id FROM plans WHERE user_id = ?1)`,
      )
      .bind(userId),
    workoutDB(db).prepare('DELETE FROM plans WHERE user_id = ?1').bind(userId),

    workoutDB(db).prepare('DELETE FROM activities WHERE user_id = ?1').bind(userId),
    workoutDB(db).prepare('DELETE FROM external_events WHERE user_id = ?1').bind(userId),
    workoutDB(db).prepare('DELETE FROM external_activities WHERE user_id = ?1').bind(userId),
    workoutDB(db).prepare('DELETE FROM notes WHERE user_id = ?1').bind(userId),
    workoutDB(db).prepare('DELETE FROM audit_log WHERE user_id = ?1').bind(userId),
    workoutDB(db).prepare('DELETE FROM intervals_oauth_states WHERE user_id = ?1').bind(userId),
    workoutDB(db).prepare('DELETE FROM oauth_codes WHERE user_id = ?1').bind(userId),
    workoutDB(db).prepare('DELETE FROM oauth_tokens WHERE user_id = ?1').bind(userId),
    workoutDB(db).prepare('DELETE FROM oauth_grants WHERE user_id = ?1').bind(userId),
  );

  // Tokens issued before multi-user MCP have a NULL principal and resolve to
  // the owner. Revoke them only when the distinguished owner is deleted.
  if (deletingOwner) {
    statements.push(
      workoutDB(db).prepare('DELETE FROM oauth_codes WHERE user_id IS NULL'),
      workoutDB(db).prepare('DELETE FROM oauth_tokens WHERE user_id IS NULL'),
      workoutDB(db).prepare('DELETE FROM oauth_grants WHERE user_id IS NULL'),
    );
  }

  statements.push(workoutDB(db).prepare('DELETE FROM users WHERE id = ?1').bind(userId));
  await workoutDB(db).batch(statements);
  const receipt = await getAccountDeletionReceipt(db, userId);
  if (!receipt || receipt.idempotency_key_sha256 !== idempotencyKeyHash) {
    return { error: 'not_found' };
  }
  return receiptResult(receipt);
}

// ---- per-user MCP passphrase (M3 multi-tenant auth) -----------------------
// Non-owner users authenticate the OAuth /authorize step with a personal
// passphrase (the owner also has the OWNER_AUTH_PASSPHRASE env path). Stored
// PBKDF2-SHA256 with a per-user random salt — never in plaintext.

const PBKDF2_ITERS = 100_000;

async function pbkdf2(passphrase: string, saltB64: string): Promise<string> {
  const salt = Uint8Array.from(atob(saltB64), (ch) => ch.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(passphrase),
    'PBKDF2',
    false,
    ['deriveBits'],
  );
  const bits = await crypto.subtle.deriveBits(
    { name: 'PBKDF2', salt, iterations: PBKDF2_ITERS, hash: 'SHA-256' },
    key,
    256,
  );
  return btoa(String.fromCharCode(...new Uint8Array(bits)));
}

/** Constant-time equality over two base64 strings (avoids early-exit leak). */
function safeEq(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/**
 * Set (or replace) a user's MCP passphrase. Hash + fresh per-user salt.
 * REJECTS a passphrase that would bind this user's Claude session to a DIFFERENT
 * account at /oauth/authorize, because authorize resolves a token's user solely
 * by passphrase:
 *   - one already in use by another user (silent cross-user access), and
 *   - the env `OWNER_AUTH_PASSPHRASE` (`ownerPassphrase`), which authorize checks
 *     FIRST and maps to the owner — the per-user hash check can't see the env
 *     secret, so this collision must be caught here (Codex #64 P2).
 * Re-setting your OWN passphrase is allowed.
 */
export async function setUserMcpPassphrase(
  db: D1Database,
  userId: string,
  passphrase: string,
  ownerPassphrase?: string,
): Promise<{ ok: true } | { error: 'passphrase_taken' }> {
  if (ownerPassphrase && passphrase === ownerPassphrase) return { error: 'passphrase_taken' };
  const owner = await findUserByMcpPassphrase(db, passphrase);
  if (owner && owner !== userId) return { error: 'passphrase_taken' };
  const saltBytes = crypto.getRandomValues(new Uint8Array(16));
  const salt = btoa(String.fromCharCode(...saltBytes));
  const hash = await pbkdf2(passphrase, salt);
  await workoutDB(db)
    .prepare('UPDATE users SET mcp_passphrase_hash = ?2, mcp_passphrase_salt = ?3 WHERE id = ?1')
    .bind(userId, hash, salt)
    .run();
  return { ok: true };
}

/**
 * Resolve a user id by their MCP passphrase, or null if none match. Iterates
 * the (small) set of users who have a passphrase set and PBKDF2-verifies each
 * — fine for a household-scale deployment; revisit if user count grows large.
 */
export async function findUserByMcpPassphrase(
  db: D1Database,
  passphrase: string,
): Promise<string | null> {
  if (!passphrase) return null;
  const rows = await workoutDB(db)
    .prepare(
      'SELECT id, mcp_passphrase_hash, mcp_passphrase_salt FROM users WHERE mcp_passphrase_hash IS NOT NULL AND mcp_passphrase_salt IS NOT NULL',
    )
    .all<{ id: string; mcp_passphrase_hash: string; mcp_passphrase_salt: string }>();
  // Defense in depth: if more than one user matches (legacy data predating the
  // set-time collision check), REFUSE to resolve — an ambiguous match must
  // never bind a token to an arbitrary account.
  let match: string | null = null;
  for (const r of rows.results) {
    const h = await pbkdf2(passphrase, r.mcp_passphrase_salt);
    if (safeEq(h, r.mcp_passphrase_hash)) {
      if (match) return null;
      match = r.id;
    }
  }
  return match;
}

/** True if `tz` is a valid IANA timezone the runtime accepts. */
export function isValidTimezone(tz: string): boolean {
  try {
    new Intl.DateTimeFormat('en-CA', { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}

/**
 * Civil date (YYYY-MM-DD) "now" in the given IANA timezone. Falls back to
 * UTC when tz is null/invalid (the pre-0012 behavior). Uses formatToParts
 * to assemble the date locale-independently — never parses a formatted
 * string.
 */
export function todayInTz(tz: string | null | undefined): string {
  if (!tz || !isValidTimezone(tz)) {
    return new Date().toISOString().slice(0, 10);
  }
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: tz,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(new Date());
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? '';
  return `${get('year')}-${get('month')}-${get('day')}`;
}

/** The owner's stored IANA timezone, or null if none recorded yet. */
export async function getUserTimezone(
  db: D1Database,
  userId: string,
): Promise<string | null> {
  const row = await workoutDB(db)
    .prepare('SELECT timezone FROM users WHERE id = ?1')
    .bind(userId)
    .first<{ timezone: string | null }>();
  return row?.timezone ?? null;
}

/**
 * Record the device's current IANA timezone on the user row when it differs
 * from what's stored. The iOS app reports it on each sync, so "today" on the
 * MCP side follows the user across time zones. Invalid/empty values are
 * ignored. Returns the effective stored value.
 */
export async function setUserTimezoneIfChanged(
  db: D1Database,
  userId: string,
  tz: string | null | undefined,
): Promise<void> {
  if (!tz || !isValidTimezone(tz)) return;
  const current = await getUserTimezone(db, userId);
  if (current === tz) return;
  await workoutDB(db).prepare('UPDATE users SET timezone = ?2 WHERE id = ?1').bind(userId, tz).run();
}

// ---- intervals.icu credentials (per-user; M1 multi-user foundation) ------

/**
 * P4.6 dual-mode SQL. Migration 0039 keeps the shadow column NULL until its
 * monotonic fence is activated, then atomically moves every durable athlete id
 * into it and clears the legacy column. COALESCE is therefore unambiguous on
 * both sides of the cutover.
 */
const INTERVALS_EFFECTIVE_ATHLETE_SQL =
  'COALESCE(intervals_cutover_athlete_id, intervals_athlete_id)';
const INTERVALS_SOURCE_FENCE_ENABLED_SQL =
  'COALESCE((SELECT enabled FROM intervals_source_fence WHERE singleton = 1), 0)';

export interface IntervalsSourceFenceState {
  enabled: boolean;
  activated_at: number | null;
  activated_user_count: number | null;
  activated_connected_count: number | null;
}

/**
 * Activate the source-bound cutover with one SQLite statement. The database
 * trigger owns the all-user move, validation, and rollback semantics; callers
 * never read or rewrite credential values. This helper is intentionally not
 * mounted on an HTTP route.
 */
export async function activateIntervalsSourceFence(
  db: D1Database,
  activatedAt: number,
): Promise<IntervalsSourceFenceState> {
  if (!Number.isSafeInteger(activatedAt) || activatedAt < 0) {
    throw new Error('intervals_source_fence_invalid_activation_time');
  }
  const activated = await workoutDB(db)
    .prepare(
      `UPDATE intervals_source_fence
          SET enabled = 1,
              activated_at = ?1,
              activated_user_count = (SELECT COUNT(*) FROM users),
              activated_connected_count = (
                SELECT COUNT(*) FROM users
                 WHERE intervals_athlete_id IS NOT NULL
                   AND (intervals_api_key IS NOT NULL
                        OR intervals_oauth_access_token IS NOT NULL)
              )
        WHERE singleton = 1 AND enabled = 0
      RETURNING enabled, activated_at,
                activated_user_count, activated_connected_count`,
    )
    .bind(activatedAt)
    .first<{
      enabled: number;
      activated_at: number;
      activated_user_count: number;
      activated_connected_count: number;
    }>();
  if (activated) {
    return {
      enabled: activated.enabled === 1,
      activated_at: activated.activated_at,
      activated_user_count: activated.activated_user_count,
      activated_connected_count: activated.activated_connected_count,
    };
  }

  const current = await workoutDB(db)
    .prepare(
      `SELECT enabled, activated_at,
              activated_user_count, activated_connected_count
         FROM intervals_source_fence WHERE singleton = 1`,
    )
    .first<{
      enabled: number;
      activated_at: number | null;
      activated_user_count: number | null;
      activated_connected_count: number | null;
    }>();
  if (!current) throw new Error('intervals_source_fence_missing');
  return {
    enabled: current.enabled === 1,
    activated_at: current.activated_at,
    activated_user_count: current.activated_user_count,
    activated_connected_count: current.activated_connected_count,
  };
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

/**
 * Enumerate users who have BOTH intervals.icu credentials populated. Used by
 * sync* in src/index.ts (cron) and refresh_rides (MCP) to loop per user
 * — each user's events/activities tag to their own user_id, so a second
 * Apple sign-in can connect a separate intervals.icu athlete without
 * clobbering the owner's data.
 */
export async function listUsersWithIntervalsCreds(
  db: D1Database,
): Promise<IntervalsUserCreds[]> {
  const r = await workoutDB(db)
    .prepare(
      `SELECT id, intervals_api_key, intervals_oauth_access_token,
              intervals_oauth_refresh_token, intervals_oauth_expires_at,
              ${INTERVALS_EFFECTIVE_ATHLETE_SQL} AS intervals_effective_athlete_id,
              intervals_credential_generation,
              intervals_events_synced_at, intervals_activities_synced_at
         FROM users
        WHERE ${INTERVALS_EFFECTIVE_ATHLETE_SQL} IS NOT NULL
          AND (intervals_api_key IS NOT NULL
               OR intervals_oauth_access_token IS NOT NULL)`,
    )
    .all<{
      id: string;
      intervals_api_key: string | null;
      intervals_oauth_access_token: string | null;
      intervals_oauth_refresh_token: string | null;
      intervals_oauth_expires_at: number | null;
      intervals_effective_athlete_id: string;
      intervals_credential_generation: number;
      intervals_events_synced_at: number | null;
      intervals_activities_synced_at: number | null;
    }>();
  return r.results.map((row) => ({
    user_id: row.id,
    api_key: row.intervals_api_key,
    access_token: row.intervals_oauth_access_token,
    refresh_token: row.intervals_oauth_refresh_token,
    expires_at: row.intervals_oauth_expires_at,
    athlete_id: row.intervals_effective_athlete_id,
    credential_generation: row.intervals_credential_generation,
    events_synced_at: row.intervals_events_synced_at,
    activities_synced_at: row.intervals_activities_synced_at,
  }));
}

/** Read one user's intervals.icu credentials (nulls if either is unset). */
export async function getUserIntervalsCreds(
  db: D1Database,
  userId: string,
): Promise<{
  api_key: string | null;
  access_token: string | null;
  refresh_token: string | null;
  expires_at: number | null;
  athlete_id: string | null;
  auth_error_at: number | null;
  credential_generation: number;
}> {
  const r = await workoutDB(db)
    .prepare(
      `SELECT intervals_api_key AS api_key,
              intervals_oauth_access_token AS access_token,
              intervals_oauth_refresh_token AS refresh_token,
              intervals_oauth_expires_at AS expires_at,
              ${INTERVALS_EFFECTIVE_ATHLETE_SQL} AS athlete_id,
              intervals_auth_error_at AS auth_error_at,
              intervals_credential_generation AS credential_generation
         FROM users WHERE id = ?1`,
    )
    .bind(userId)
    .first<{
      api_key: string | null;
      access_token: string | null;
      refresh_token: string | null;
      expires_at: number | null;
      athlete_id: string | null;
      auth_error_at: number | null;
      credential_generation: number;
    }>();
  return {
    api_key: r?.api_key ?? null,
    access_token: r?.access_token ?? null,
    refresh_token: r?.refresh_token ?? null,
    expires_at: r?.expires_at ?? null,
    athlete_id: r?.athlete_id ?? null,
    auth_error_at: r?.auth_error_at ?? null,
    credential_generation: r?.credential_generation ?? 0,
  };
}

/**
 * Resolve the user row owning a given intervals.icu `athlete_id`. Used by the
 * webhook receiver (`POST /webhooks/intervals`) to route a pushed event to the
 * right user before kicking the relevant sync. The expression index installed
 * by migration 0039 covers the effective identity before and after cutover.
 * Returns null when no user has connected that athlete.
 */
export async function getUserByIntervalsAthleteId(
  db: D1Database,
  athleteId: string,
): Promise<User | null> {
  return await workoutDB(db)
    .prepare(`SELECT * FROM users WHERE ${INTERVALS_EFFECTIVE_ATHLETE_SQL} = ?1`)
    .bind(athleteId)
    .first<User>();
}

/**
 * Has this user ever explicitly set or cleared their intervals.icu
 * credentials via PATCH /api/me/integrations/intervals? Determined from
 * audit_log (the REST endpoint writes a `set_intervals_creds` row on every
 * connect AND disconnect). Once true, the env→DB seed and the per-call env
 * fallback both back off — "no creds" then means "intentionally
 * disconnected", not "first sync after deploy".
 */
export async function userHasTouchedIntervalsCreds(
  db: D1Database,
  userId: string,
): Promise<boolean> {
  const r = await workoutDB(db)
    .prepare(
      "SELECT 1 FROM audit_log WHERE user_id = ?1 AND tool = 'set_intervals_creds' LIMIT 1",
    )
    .bind(userId)
    .first();
  return r !== null;
}

/**
 * Env → DB transition path. If NO user has intervals.icu credentials set
 * and the legacy Worker secrets are present, seed the OWNER user row
 * (the first row by created_at) from env exactly once. Idempotent: returns
 * the resulting per-user creds list, which on subsequent calls is just the
 * already-populated row.
 *
 * Rationale: a static SQL migration cannot read `wrangler secret`-managed
 * env vars, so 0016 added nullable columns and this code path does the
 * one-shot copy on the next sync after deploy. Calling this before each
 * sync is cheap (one SELECT + at most one UPDATE on first invocation).
 *
 * Respects explicit disconnects: if the owner has ever PATCHed their
 * intervals creds (set OR clear), the seed is permanently a no-op for them.
 * Otherwise, after the user disconnects via the UI, the next sync would
 * silently re-seed from env and resume polling — defeating the disconnect.
 * Generation zero remains mandatory even after the P4.6 cutover. Activation
 * bumps every generation, permanently closing this fallback; a release must
 * seed any legitimate env-only owner before activation. This also prevents an
 * old Worker's disconnect-row commit from racing ahead of its separate audit
 * insert and being resurrected by a new Worker.
 */
export async function seedOwnerIntervalsCredsFromEnv(
  db: D1Database,
  apiKey: string | null | undefined,
  athleteId: string | null | undefined,
  ownerAppleSub: string | undefined,
): Promise<IntervalsUserCreds[]> {
  // Resolve the owner row through findOwnerRow so OWNER_APPLE_SUB-set
  // deployments don't accidentally seed env creds onto a non-owner row
  // that happened to sign in first (Codex PR #38 P1). The seed gate is
  // also OWNER-SPECIFIC: an early "any user has creds → done" check
  // would skip the owner if a later-joined member happened to connect
  // their intervals account before the first post-deploy sync (the
  // owner would then lose ride syncing until they manually re-entered).
  const owner = await findOwnerRow(db, ownerAppleSub);
  if (!owner) return listUsersWithIntervalsCreds(db);
  // Already seeded (or set via PATCH / connected via OAuth): no-op. Checks
  // BOTH auth schemes so an OAuth-connected owner (api_key NULL, token set)
  // is recognised as already-connected and never env-seeded.
  const ownerAthleteId =
    owner.intervals_cutover_athlete_id ?? owner.intervals_athlete_id;
  if ((owner.intervals_api_key || owner.intervals_oauth_access_token) && ownerAthleteId) {
    return listUsersWithIntervalsCreds(db);
  }
  // Owner has explicitly PATCHed their creds (set then cleared, possibly):
  // NULLs here are intentional disconnects, not "never migrated." Respect.
  if (await userHasTouchedIntervalsCreds(db, owner.id)) {
    return listUsersWithIntervalsCreds(db);
  }
  // A prior sync rejected the owner's credential (401/403 → markIntervalsAuthError
  // cleared it and set this marker). Re-seeding the SAME dead env credential
  // would just 401 again next tick — an infinite reconnect loop. Back off until
  // the owner explicitly reconnects (which clears the marker).
  if (owner.intervals_auth_error_at != null) {
    return listUsersWithIntervalsCreds(db);
  }
  // No env values to seed from → dormant.
  if (!apiKey || !athleteId) return listUsersWithIntervalsCreds(db);
  await workoutDB(db)
    .prepare(
      `UPDATE users
          SET intervals_api_key = ?2,
              intervals_athlete_id = CASE
                WHEN ${INTERVALS_SOURCE_FENCE_ENABLED_SQL} = 1 THEN NULL ELSE ?3 END,
              intervals_cutover_athlete_id = CASE
                WHEN ${INTERVALS_SOURCE_FENCE_ENABLED_SQL} = 1 THEN ?3 ELSE NULL END,
              intervals_oauth_refresh_token = NULL,
              intervals_oauth_expires_at = NULL,
              intervals_credential_generation = intervals_credential_generation + 1,
              intervals_events_synced_at = NULL,
              intervals_activities_synced_at = NULL,
              intervals_events_sync_attempt = 0,
              intervals_activities_sync_attempt = 0,
              intervals_protocol_write_seq = intervals_protocol_write_seq
                + ${INTERVALS_SOURCE_FENCE_ENABLED_SQL}
        WHERE id = ?1
          AND intervals_api_key IS NULL
          AND intervals_oauth_access_token IS NULL
          AND ${INTERVALS_EFFECTIVE_ATHLETE_SQL} IS NULL
          AND intervals_auth_error_at IS NULL
          AND intervals_credential_generation = 0
          AND NOT EXISTS (
                SELECT 1 FROM audit_log
                 WHERE user_id = ?1 AND tool = 'set_intervals_creds'
              )`,
    )
    .bind(owner.id, apiKey, athleteId)
    .run();
  return listUsersWithIntervalsCreds(db);
}

/**
 * Set/clear a user's intervals.icu credentials. Both columns move together
 * — passing null on EITHER clears the pair (disconnect). Returns the
 * resulting connection state. Audit is the caller's responsibility (the
 * REST handler writes an audit row tagged actor='ios'). The users-row
 * generation changes in this mutation itself, so even an interrupted later
 * audit write cannot let the legacy owner-env fallback reactivate a disconnect.
 */
export async function setUserIntervalsCreds(
  db: D1Database,
  userId: string,
  apiKey: string | null,
  athleteId: string | null,
): Promise<{ connected: boolean; credential_generation: number; activity_sync_after: number | null }> {
  const connect = !!(apiKey && athleteId);
  // The API-key and OAuth schemes are mutually exclusive: writing an API key
  // clears any OAuth token, and a disconnect (nulls) clears BOTH schemes'
  // columns so "not connected" is unambiguous across the codebase.
  const { results: [row] } = await workoutDB(db)
    .prepare(
      `UPDATE users
          SET intervals_api_key = ?2,
              intervals_athlete_id = CASE
                WHEN ${INTERVALS_SOURCE_FENCE_ENABLED_SQL} = 1 THEN NULL ELSE ?3 END,
              intervals_cutover_athlete_id = CASE
                WHEN ${INTERVALS_SOURCE_FENCE_ENABLED_SQL} = 1 THEN ?3 ELSE NULL END,
              intervals_oauth_access_token = NULL,
              intervals_oauth_refresh_token = NULL,
              intervals_oauth_expires_at = NULL,
              intervals_auth_error_at = NULL,
              intervals_credential_generation = CASE
                WHEN ?4 = 1
                 AND intervals_api_key IS ?2
                 AND ${INTERVALS_EFFECTIVE_ATHLETE_SQL} IS ?3
                 AND intervals_oauth_access_token IS NULL
                THEN intervals_credential_generation
                ELSE intervals_credential_generation + 1 END,
              intervals_events_synced_at = CASE
                WHEN ?4 = 1
                 AND intervals_api_key IS ?2
                 AND ${INTERVALS_EFFECTIVE_ATHLETE_SQL} IS ?3
                 AND intervals_oauth_access_token IS NULL
                THEN intervals_events_synced_at ELSE NULL END,
              intervals_activities_synced_at = CASE
                WHEN ?4 = 1
                 AND intervals_api_key IS ?2
                 AND ${INTERVALS_EFFECTIVE_ATHLETE_SQL} IS ?3
                 AND intervals_oauth_access_token IS NULL
                THEN intervals_activities_synced_at ELSE NULL END,
              intervals_events_sync_attempt = CASE
                WHEN ?4 = 1
                 AND intervals_api_key IS ?2
                 AND ${INTERVALS_EFFECTIVE_ATHLETE_SQL} IS ?3
                 AND intervals_oauth_access_token IS NULL
                THEN intervals_events_sync_attempt ELSE 0 END,
              intervals_activities_sync_attempt = CASE
                WHEN ?4 = 1
                 AND intervals_api_key IS ?2
                 AND ${INTERVALS_EFFECTIVE_ATHLETE_SQL} IS ?3
                 AND intervals_oauth_access_token IS NULL
                THEN intervals_activities_sync_attempt ELSE 0 END,
              intervals_protocol_write_seq = intervals_protocol_write_seq
                + ${INTERVALS_SOURCE_FENCE_ENABLED_SQL}
        WHERE id = ?1
        RETURNING intervals_credential_generation AS credential_generation,
                  intervals_activities_synced_at AS activity_sync_after`,
    )
    .bind(userId, connect ? apiKey : null, connect ? athleteId : null, connect ? 1 : 0)
    .run<{ credential_generation: number; activity_sync_after: number | null }>();
  if (!row) throw new Error('intervals_user_not_found');
  return { connected: connect, ...row };
}

/**
 * Store a user's intervals.icu OAuth credentials — the /auth/intervals/callback
 * success path. Sets the bearer token + the `athlete.id` the token exchange
 * returned (into the effective legacy-or-shadow athlete column selected in
 * the same statement) and CLEARS any prior API key (the two schemes are
 * mutually exclusive; Bearer wins).
 * `refreshToken` / `expiresAt` are stored when present — the documented
 * intervals.icu token response carries neither (long-lived tokens), so both
 * are typically null.
 */
async function writeUserIntervalsOAuth(
  db: D1Database,
  userId: string,
  accessToken: string,
  refreshToken: string | null,
  expiresAt: number | null,
  athleteId: string,
  expectedGeneration?: number,
): Promise<{ credential_generation: number; activity_sync_after: number | null } | null> {
  const { results: [row] } = await workoutDB(db)
    .prepare(
      `UPDATE users
          SET intervals_oauth_access_token = ?2,
              intervals_oauth_refresh_token = ?3,
              intervals_oauth_expires_at = ?4,
              intervals_athlete_id = CASE
                WHEN ${INTERVALS_SOURCE_FENCE_ENABLED_SQL} = 1 THEN NULL ELSE ?5 END,
              intervals_cutover_athlete_id = CASE
                WHEN ${INTERVALS_SOURCE_FENCE_ENABLED_SQL} = 1 THEN ?5 ELSE NULL END,
              intervals_api_key = NULL,
              intervals_auth_error_at = NULL,
              intervals_credential_generation = CASE
                WHEN intervals_oauth_access_token IS ?2
                  AND ${INTERVALS_EFFECTIVE_ATHLETE_SQL} IS ?5
                  AND intervals_api_key IS NULL
                THEN intervals_credential_generation
                ELSE intervals_credential_generation + 1 END,
              intervals_events_synced_at = CASE
                WHEN intervals_oauth_access_token IS ?2
                  AND ${INTERVALS_EFFECTIVE_ATHLETE_SQL} IS ?5
                  AND intervals_api_key IS NULL
                THEN intervals_events_synced_at ELSE NULL END,
              intervals_activities_synced_at = CASE
                WHEN intervals_oauth_access_token IS ?2
                  AND ${INTERVALS_EFFECTIVE_ATHLETE_SQL} IS ?5
                  AND intervals_api_key IS NULL
                THEN intervals_activities_synced_at ELSE NULL END,
              intervals_events_sync_attempt = CASE
                WHEN intervals_oauth_access_token IS ?2
                  AND ${INTERVALS_EFFECTIVE_ATHLETE_SQL} IS ?5
                  AND intervals_api_key IS NULL
                THEN intervals_events_sync_attempt ELSE 0 END,
              intervals_activities_sync_attempt = CASE
                WHEN intervals_oauth_access_token IS ?2
                  AND ${INTERVALS_EFFECTIVE_ATHLETE_SQL} IS ?5
                  AND intervals_api_key IS NULL
                THEN intervals_activities_sync_attempt ELSE 0 END,
              intervals_protocol_write_seq = intervals_protocol_write_seq
                + ${INTERVALS_SOURCE_FENCE_ENABLED_SQL}
        WHERE id = ?1
          AND (?6 IS NULL OR intervals_credential_generation = ?6)
        RETURNING intervals_credential_generation AS credential_generation,
                  intervals_activities_synced_at AS activity_sync_after`,
    )
    .bind(
      userId,
      accessToken,
      refreshToken,
      expiresAt,
      athleteId,
      expectedGeneration ?? null,
    )
    .run<{ credential_generation: number; activity_sync_after: number | null }>();
  return row ?? null;
}

export async function setUserIntervalsOAuth(
  db: D1Database,
  userId: string,
  accessToken: string,
  refreshToken: string | null,
  expiresAt: number | null,
  athleteId: string,
  expectedGeneration?: number,
): Promise<{ credential_generation: number; activity_sync_after: number | null } | null> {
  return writeUserIntervalsOAuth(
    db,
    userId,
    accessToken,
    refreshToken,
    expiresAt,
    athleteId,
    expectedGeneration,
  );
}

/**
 * Mint a single-use OAuth `state` for the intervals.icu authorize→callback
 * round-trip and map it to `userId`. The authenticated POST /auth/intervals/start
 * calls this; the public GET /auth/intervals/callback resolves it back. The
 * state doubles as CSRF protection (unguessable, single-use, short TTL).
 */
export async function createIntervalsOAuthState(
  db: D1Database,
  userId: string,
  ttlMs = 10 * 60 * 1000,
): Promise<string> {
  const state =
    crypto.randomUUID().replace(/-/g, '') + crypto.randomUUID().replace(/-/g, '');
  const ts = now();
  const account = await workoutDB(db).prepare(
    'SELECT intervals_credential_generation AS generation FROM users WHERE id = ?1',
  ).bind(userId).first<{ generation: number }>();
  if (!account) throw new Error('intervals_user_not_found');
  const inserted = await workoutDB(db)
    .prepare(
      `INSERT INTO intervals_oauth_states (state, user_id, created_at, expires_at, credential_generation)
       SELECT ?1, ?2, ?3, ?4, ?5 FROM users
        WHERE id = ?2 AND intervals_credential_generation = ?5`,
    )
    .bind(state, userId, ts, ts + ttlMs, account.generation)
    .run();
  if (inserted.meta.changes !== 1) throw new Error('intervals_connection_changed');
  return state;
}

/**
 * Resolve + CONSUME an intervals.icu OAuth `state` (single-use): returns the
 * mapped user_id, or null if the state is unknown or expired. Deletes the row
 * on lookup regardless of validity and opportunistically sweeps stale rows,
 * so a replayed callback can't reuse a state.
 */
export async function consumeIntervalsOAuthState(
  db: D1Database,
  state: string,
): Promise<string | null> {
  return (await consumeIntervalsOAuthAttempt(db, state))?.user_id ?? null;
}

/** Consume the state with the generation recorded when the attempt began.
 * Migration 0047 also cancels pending states on credential changes. */
export async function consumeIntervalsOAuthAttempt(
  db: D1Database,
  state: string,
): Promise<{ user_id: string; credential_generation: number } | null> {
  const ts = now();
  // ATOMIC single-use: DELETE … RETURNING removes the row and yields its value
  // in one statement, so two concurrent callbacks (browser preload, double-tap,
  // replay) can't both observe the same valid state — only one DELETE returns
  // the row, the other gets nothing.
  const row = await workoutDB(db)
    .prepare(`DELETE FROM intervals_oauth_states WHERE state = ?1
      RETURNING user_id, expires_at, credential_generation`)
    .bind(state)
    .first<{ user_id: string; expires_at: number; credential_generation: number | null }>();
  // Best-effort sweep of any OTHER now-expired rows (kept out of the atomic
  // statement above so it never affects the single-use result).
  await workoutDB(db).prepare('DELETE FROM intervals_oauth_states WHERE expires_at < ?1').bind(ts).run();
  if (!row || row.expires_at < ts || row.credential_generation === null) return null;
  return { user_id: row.user_id, credential_generation: row.credential_generation };
}

// ---- groups + invites (M2) -----------------------------------------------
//
// Friends/family containers. The single-user invariant relaxes to multi-user-
// with-invite-gating: a new Apple sub may sign in only when the bootstrap
// path applies OR a valid invite code is supplied. The invite redemption +
// user creation are made atomic in /auth/apple — see src/routes/auth.ts.
//
// Group writes are AUDITED (writeAudit) but DO NOT bump plans.version —
// groups live outside the versioned plan-tree document. The audit_log trail
// is the per-mutation provenance, same single-user substitute for scopes
// that the plan-tree mutations use.

/**
 * Invite-code alphabet: 32 unambiguous chars (no 0/O, no 1/I/L).
 * 6 chars from 32 = 32^6 ≈ 1.07 * 10^9 codes, plenty for friends-and-family.
 */
const INVITE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
const INVITE_CODE_LEN = 6;
const DEFAULT_INVITE_TTL_MS = 30 * 24 * 60 * 60 * 1000; // 30 days

/**
 * Generate a single 6-char code from the no-ambiguous alphabet using
 * `crypto.getRandomValues`. Caller (`createInvite`) retries on PK collision
 * — at 32^6 the birthday-paradox collision rate is vanishingly small until
 * many millions of outstanding codes.
 */
function newInviteCode(): string {
  const buf = new Uint8Array(INVITE_CODE_LEN);
  crypto.getRandomValues(buf);
  let out = '';
  for (let i = 0; i < INVITE_CODE_LEN; i++) {
    out += INVITE_ALPHABET[buf[i]! % INVITE_ALPHABET.length];
  }
  return out;
}

/**
 * Account/setup snapshot for the iOS Profile tab. Read-only; never returns
 * the (write-only) intervals api_key. Connection state is derived from the
 * SERVER, not a client mirror — so env/MCP-seeded intervals creds and the
 * claude.ai connector both show up:
 *   - intervals.connected = the user row has an athlete_id.
 *   - claude: Claude coaching is SINGLE-OWNER — the MCP connector always
 *     resolves to the owner account (ensureOwnerUser/findOwnerRow), so it
 *     is only ever reported for the owner. The `oauth_tokens` table isn't
 *     user-scoped, so a global "a grant exists" check would tell every
 *     invited (non-owner) user the coach is connected the moment the owner
 *     authorizes — while Claude never touches their data (Codex PR #50 P2).
 *     Hence: `connected` = caller IS the owner AND a durable OAuth grant
 *     (refresh_token) exists; `is_owner` lets the client phrase the
 *     non-owner case ("managed by the owner") instead of a dead "connect"
 *     CTA; `last_active` = the owner's most recent MCP write (audit_log
 *     actor='mcp'; REST writes are actor='ios' and excluded).
 */
export interface MeProfile {
  display_name: string | null;
  email: string | null;
  intervals: IntervalsConnectionStatus;
  claude: { is_owner: boolean; connected: boolean; last_active: number | null };
  // Apple Health group-feed opt-in (migration 0028). Off by default; the iOS
  // Apple Health detail toggle flips it via PATCH /api/me/health-sharing.
  health: { sharing_in_group: boolean };
}

export interface IntervalsConnectionStatus {
  connected: boolean;
  athlete_id: string | null;
  needs_reauth: boolean;
  credential_generation: number;
  sync_pending: boolean;
  last_synced_at: number | null;
}

interface IntervalsStatusRow {
  intervals_effective_athlete_id: string | null;
  intervals_auth_error_at: number | null;
  intervals_credential_generation: number;
  intervals_activities_synced_at: number | null;
}

function intervalsStatus(row: IntervalsStatusRow | null): IntervalsConnectionStatus {
  const connected = !!row?.intervals_effective_athlete_id;
  return {
    connected,
    athlete_id: row?.intervals_effective_athlete_id ?? null,
    needs_reauth: row?.intervals_auth_error_at != null,
    credential_generation: row?.intervals_credential_generation ?? 0,
    sync_pending: connected && row?.intervals_activities_synced_at == null,
    last_synced_at: row?.intervals_activities_synced_at ?? null,
  };
}

export async function getIntervalsConnectionStatus(db: D1Database, userId: string): Promise<IntervalsConnectionStatus> {
  return intervalsStatus(await workoutDB(db).prepare(`SELECT
    ${INTERVALS_EFFECTIVE_ATHLETE_SQL} AS intervals_effective_athlete_id,
    intervals_auth_error_at, intervals_credential_generation, intervals_activities_synced_at
    FROM users WHERE id = ?1`).bind(userId).first<IntervalsStatusRow>());
}

export async function getMeProfile(
  db: D1Database,
  userId: string,
  ownerAppleSub: string | undefined,
): Promise<MeProfile> {
  const u = await workoutDB(db)
    .prepare(
      `SELECT display_name, email,
              ${INTERVALS_EFFECTIVE_ATHLETE_SQL} AS intervals_effective_athlete_id,
              intervals_auth_error_at, share_health_activities,
              intervals_credential_generation, intervals_activities_synced_at
         FROM users WHERE id = ?1`,
    )
    .bind(userId)
    .first<{
      display_name: string | null;
      email: string | null;
      intervals_effective_athlete_id: string | null;
      intervals_auth_error_at: number | null;
      intervals_credential_generation: number;
      intervals_activities_synced_at: number | null;
      share_health_activities: number | null;
    }>();

  // Claude connection is PER-USER (M3): a token bound to THIS user means their
  // connector is linked (a refresh_token is the durable grant claude.ai keeps,
  // so it survives access-token expiry). The owner additionally matches legacy
  // tokens with a NULL user_id — issued before M3, when /mcp always resolved to
  // the owner. (Codex #64 P2: non-owner grants must surface in their Profile.)
  const owner = await findOwnerRow(db, ownerAppleSub);
  const isOwner = !!owner && owner.id === userId;

  const grant = await workoutDB(db)
    .prepare(
      'SELECT 1 AS x FROM oauth_tokens WHERE refresh_token IS NOT NULL AND (user_id = ?1' +
        (isOwner ? ' OR user_id IS NULL' : '') +
        ') LIMIT 1',
    )
    .bind(userId)
    .first<{ x: number }>();
  const claudeConnected = !!grant;
  const lastMcp = await workoutDB(db)
    .prepare("SELECT MAX(created_at) AS t FROM audit_log WHERE user_id = ?1 AND actor = 'mcp'")
    .bind(userId)
    .first<{ t: number | null }>();
  const lastActive = lastMcp?.t ?? null;

  return {
    display_name: u?.display_name ?? null,
    email: u?.email ?? null,
    intervals: intervalsStatus(u),
    claude: {
      is_owner: isOwner,
      connected: claudeConnected,
      last_active: lastActive,
    },
    health: {
      // Whether THIS user's Apple Health activities are shared into the group
      // feed (opt-in, default off — migration 0028). Drives the iOS detail
      // toggle; the gate itself lives in the group-surface queries.
      sharing_in_group: !!u?.share_health_activities,
    },
  };
}

/**
 * Portable, caller-scoped snapshot of authoritative account and training data.
 * This projection is intentionally not mounted on a network route until the
 * sensitive export surface receives explicit product/security authorization.
 * Secret material (intervals credentials, MCP passphrase hashes, OAuth tokens,
 * and group-invite capabilities) is deliberately excluded; connection metadata
 * and the Apple subject remain because they are the user's own account data.
 * Shared group exports contain only the caller's membership row and group name,
 * never another member's profile or activity.
 */
export async function exportUserData(
  db: D1Database,
  userId: string,
): Promise<Record<string, unknown> | null> {
  // D1 batches are transactional, including read-only batches. Reading the
  // complete projection through one batch keeps the account, plan tree, logs,
  // and memberships on one coherent database snapshot while writes continue.
  const projection = await workoutDB(db).batch<Record<string, unknown>>([
    workoutDB(db)
      .prepare(
        `SELECT id, apple_sub, email, display_name, created_at, timezone,
                ${INTERVALS_EFFECTIVE_ATHLETE_SQL} AS intervals_athlete_id,
                intervals_auth_error_at,
                share_health_activities
           FROM users WHERE id = ?1`,
      )
      .bind(userId),
    workoutDB(db)
      .prepare('SELECT * FROM plans WHERE user_id = ?1 ORDER BY created_at, id')
      .bind(userId),
    workoutDB(db)
      .prepare(
        `SELECT d.* FROM workouts d
         JOIN plans p ON p.id = d.plan_id
         WHERE p.user_id = ?1
         ORDER BY d.plan_id, d.order_index, d.created_at, d.id`,
      )
      .bind(userId),
    workoutDB(db)
      .prepare(
        `SELECT te.* FROM template_exercises te
         JOIN workouts d ON d.id = te.workout_id
         JOIN plans p ON p.id = d.plan_id
         WHERE p.user_id = ?1
         ORDER BY te.workout_id, te.order_index, te.created_at, te.id`,
      )
      .bind(userId),
    workoutDB(db)
      .prepare('SELECT * FROM sessions WHERE user_id = ?1 ORDER BY date, created_at, id')
      .bind(userId),
    workoutDB(db)
      .prepare(
        `SELECT sl.* FROM set_logs sl
         JOIN sessions s ON s.id = sl.session_id
         WHERE s.user_id = ?1
         ORDER BY sl.logged_at, sl.id`,
      )
      .bind(userId),
    workoutDB(db)
      .prepare(
        `SELECT e.* FROM exercises e
         WHERE e.id IN (
           SELECT te.exercise_id FROM template_exercises te
           JOIN workouts d ON d.id = te.workout_id
           JOIN plans p ON p.id = d.plan_id
           WHERE p.user_id = ?1
           UNION
           SELECT sl.exercise_id FROM set_logs sl
           JOIN sessions s ON s.id = sl.session_id
           WHERE s.user_id = ?1
         )
         ORDER BY e.name, e.id`,
      )
      .bind(userId),
    workoutDB(db)
      .prepare(
        `SELECT sa.* FROM session_aliases sa
         JOIN sessions s ON s.id = sa.canonical_session_id
         WHERE s.user_id = ?1
         ORDER BY sa.alias_session_id`,
      )
      .bind(userId),
    workoutDB(db)
      .prepare(
        `SELECT sle.* FROM session_load_exports sle
         JOIN sessions s ON s.id = sle.session_id
         WHERE s.user_id = ?1
         ORDER BY sle.updated_at, sle.session_id`,
      )
      .bind(userId),
    workoutDB(db)
      .prepare('SELECT * FROM notes WHERE user_id = ?1 ORDER BY created_at, id')
      .bind(userId),
    workoutDB(db)
      .prepare('SELECT * FROM audit_log WHERE user_id = ?1 ORDER BY created_at, id')
      .bind(userId),
    workoutDB(db)
      .prepare('SELECT * FROM external_events WHERE user_id = ?1 ORDER BY date, id')
      .bind(userId),
    workoutDB(db)
      .prepare(
        'SELECT * FROM external_activities WHERE user_id = ?1 ORDER BY date, id',
      )
      .bind(userId),
    workoutDB(db)
      .prepare(
        'SELECT * FROM activities WHERE user_id = ?1 ORDER BY date, logged_at, id',
      )
      .bind(userId),
    workoutDB(db)
      .prepare(
        `SELECT id,user_id,plan_id,version,document,actor,operation,reason,created_at
           FROM plan_snapshots WHERE user_id=?1 ORDER BY plan_id,version`,
      )
      .bind(userId),
    workoutDB(db)
      .prepare(
        `SELECT gm.group_id, gm.display_name, gm.joined_at,
                g.created_by = ?1 AS owns_group,
                CASE WHEN g.created_by <> ?1 AND (
                  NOT EXISTS (SELECT 1 FROM group_members creator
                    WHERE creator.group_id = g.id AND creator.user_id = g.created_by)
                  OR EXISTS (SELECT 1 FROM group_sharing_restrictions r
                    WHERE r.user_id = g.created_by AND r.active = 1)
                  OR EXISTS (SELECT 1 FROM group_member_blocks b WHERE b.active = 1 AND (
                    (b.blocker_id = ?1 AND b.blocked_id = g.created_by)
                    OR (b.blocker_id = g.created_by AND b.blocked_id = ?1)))
                ) THEN 'Private group' ELSE g.name END AS group_name
           FROM group_members gm
           JOIN groups g ON g.id = gm.group_id
          WHERE gm.user_id = ?1
          ORDER BY gm.joined_at, gm.group_id`,
      )
      .bind(userId),
    workoutDB(db)
      .prepare('SELECT blocked_id AS user_id, created_at FROM group_member_blocks WHERE blocker_id = ?1 AND active = 1 ORDER BY created_at, blocked_id')
      .bind(userId),
    workoutDB(db)
      .prepare('SELECT active, reason, updated_at FROM group_sharing_restrictions WHERE user_id = ?1')
      .bind(userId),
  ]);
  const rowsAt = (index: number): Record<string, unknown>[] =>
    projection[index]?.results ?? [];
  const account = rowsAt(0)[0] ?? null;
  if (!account) return null;
  const plans = rowsAt(1);
  const days = rowsAt(2);
  const templateExercises = rowsAt(3);
  const sessions = rowsAt(4);
  const sets = rowsAt(5);
  const exercises = rowsAt(6);
  const aliases = rowsAt(7);
  const loadExports = rowsAt(8);
  const notes = rowsAt(9);
  const audit = rowsAt(10);
  const events = rowsAt(11);
  const externalActivities = rowsAt(12);
  const activities = rowsAt(13);
  const planSnapshots = rowsAt(14);
  const memberships = rowsAt(15).map(({ owns_group, ...row }) =>
    owns_group === 1 ? row : { ...row, group_name: sharedText(row.group_name as string, 'Private group') },
  );

  const auditRows = audit.map((row) => {
    if (row.tool !== 'create_invite' && row.tool !== 'redeem_invite') {
      return row;
    }
    if (typeof row.args !== 'string') return { ...row, args: '{}' };
    try {
      const args = JSON.parse(row.args) as unknown;
      if (args === null || Array.isArray(args) || typeof args !== 'object') {
        return { ...row, args: '{}' };
      }
      delete (args as Record<string, unknown>).code;
      return { ...row, args: JSON.stringify(args) };
    } catch {
      // Known invite audit rows fail closed: malformed historical arguments
      // must not bypass capability redaction.
      return { ...row, args: '{}' };
    }
  });
  return {
    schema_version: 2,
    exported_at: now(),
    account,
    training: {
      plans,
      workouts: days,
      template_exercises: templateExercises,
      exercises,
      sessions,
      set_logs: sets,
      session_aliases: aliases,
      session_load_exports: loadExports,
      notes,
      audit_log: auditRows,
      external_events: events,
      external_activities: externalActivities,
      activities,
      plan_snapshots: planSnapshots,
    },
    group_memberships: memberships,
    group_safety: {
      blocks: rowsAt(16),
      sharing_restriction: rowsAt(17)[0] ?? null,
    },
  };
}

export async function setUserDisplayName(
  db: D1Database,
  userId: string,
  displayName: string,
): Promise<boolean> {
  const result = await workoutDB(db)
    .prepare('UPDATE users SET display_name = ?2 WHERE id = ?1')
    .bind(userId, displayName)
    .run();
  return (result.meta.changes ?? 0) > 0;
}

/**
 * Set this user's "share my Apple Health activities in the group feed" opt-in
 * (migration 0028). Off by default; the iOS Apple Health detail toggle calls
 * PATCH /api/me/health-sharing to flip it. When off, the group feed/stats/series
 * queries exclude this user's source='healthkit' rows.
 */
export async function setHealthActivitySharing(
  db: D1Database,
  userId: string,
  enabled: boolean,
): Promise<{ sharing_in_group: boolean }> {
  await workoutDB(db)
    .prepare('UPDATE users SET share_health_activities = ?2 WHERE id = ?1')
    .bind(userId, enabled ? 1 : 0)
    .run();
  return { sharing_in_group: enabled };
}

/**
 * Create a group and add the creator as the first member. Returns the new
 * group row (without the auto-member — read it back via listGroupsForUser
 * if you need members hydrated). Audited as 'create_group' actor='ios'.
 */
export async function createGroup(
  db: D1Database,
  userId: string,
  name: string,
): Promise<Group> {
  const id = uuid();
  const ts = now();
  const group: Group = { id, name, created_by: userId, created_at: ts };
  // Use a batch so the membership row lands with the group row — D1 batches
  // run in a single transaction (an atomicity guarantee documented by
  // Cloudflare). If either statement fails the group is never visible.
  await workoutDB(db).batch([
    workoutDB(db)
      .prepare('INSERT INTO groups (id,name,created_by,created_at) VALUES (?1,?2,?3,?4)')
      .bind(id, name, userId, ts),
    workoutDB(db)
      .prepare(
        'INSERT INTO group_members (group_id,user_id,display_name,joined_at) VALUES (?1,?2,?3,?4)',
      )
      .bind(id, userId, null, ts),
  ]);
  await writeAudit(
    db,
    userId,
    'create_group',
    { group_id: id, name },
    'created',
    'ios',
  );
  return group;
}

/** True iff `userId` is currently a member of `groupId`. */
export async function isGroupMember(
  db: D1Database,
  userId: string,
  groupId: string,
): Promise<boolean> {
  const r = await workoutDB(db)
    .prepare('SELECT 1 AS x FROM group_members WHERE group_id = ?1 AND user_id = ?2')
    .bind(groupId, userId)
    .first<{ x: number }>();
  return !!r;
}

interface VisibleGroupMember {
  user_id: string;
  per_group_name: string | null;
  global_name: string | null;
  email: string | null;
  timezone: string | null;
  joined_at: number;
}

// One visibility rule for rosters, REST/MCP feeds, stats and activity series.
// Filtering before activity reads keeps pagination and totals consistent.
async function visibleGroupMembers(db: D1Database, groupId: string, callerUserId: string): Promise<VisibleGroupMember[]> {
  const rows = await workoutDB(db).prepare(`
    SELECT gm.user_id, gm.display_name AS per_group_name, gm.joined_at,
           u.display_name AS global_name, u.email, u.timezone
      FROM group_members gm JOIN users u ON u.id = gm.user_id
     WHERE gm.group_id = ?1
       AND EXISTS (SELECT 1 FROM group_members viewer WHERE viewer.group_id = ?1 AND viewer.user_id = ?2)
       AND (gm.user_id = ?2 OR (
         NOT EXISTS (SELECT 1 FROM group_sharing_restrictions r WHERE r.user_id = gm.user_id AND r.active = 1)
         AND NOT EXISTS (SELECT 1 FROM group_member_blocks b WHERE b.active = 1 AND
           ((b.blocker_id = ?2 AND b.blocked_id = gm.user_id) OR
            (b.blocked_id = ?2 AND b.blocker_id = gm.user_id)))
       ))
     ORDER BY gm.joined_at, gm.user_id`).bind(groupId, callerUserId).all<VisibleGroupMember>();
  return rows.results;
}

export async function listGroupBlocks(db: D1Database, userId: string) {
  const rows = await workoutDB(db).prepare(`
    SELECT blocked_id AS user_id, created_at FROM group_member_blocks
     WHERE blocker_id = ?1 AND active = 1 ORDER BY created_at, blocked_id
  `).bind(userId).all<{ user_id: string; created_at: number }>();
  return rows.results;
}

export async function setGroupMemberBlock(db: D1Database, userId: string, targetId: string, active: boolean): Promise<boolean> {
  if (userId === targetId) return false;
  if (!active) {
    // Only the block's owner can undo it; retry and leaving the group are safe.
    await workoutDB(db).prepare('UPDATE group_member_blocks SET active = 0 WHERE blocker_id = ?1 AND blocked_id = ?2')
      .bind(userId, targetId).run();
    return true;
  }
  const result = await workoutDB(db).prepare(`
    INSERT INTO group_member_blocks (blocker_id, blocked_id, created_at, active)
    SELECT ?1, ?2, ?3, 1
     WHERE EXISTS (SELECT 1 FROM group_members a JOIN group_members b ON a.group_id = b.group_id
                    WHERE a.user_id = ?1 AND b.user_id = ?2)
       AND NOT EXISTS (SELECT 1 FROM account_deletion_intents WHERE user_id IN (?1, ?2))
    ON CONFLICT (blocker_id, blocked_id) DO UPDATE SET active = 1
  `).bind(userId, targetId, now()).run();
  return (result.meta.changes ?? 0) > 0;
}

// Operator authority requires the explicitly configured Apple identity. Never
// promote the earliest account or a group creator into platform moderation.
export async function isGroupSafetyOperator(db: D1Database, userId: string, ownerAppleSub: string | undefined): Promise<boolean> {
  if (!ownerAppleSub) return false;
  const row = await workoutDB(db).prepare(`SELECT 1 AS allowed FROM users
    WHERE id = ?1 AND apple_sub = ?2
      AND NOT EXISTS (SELECT 1 FROM owner_deletion_tombstone WHERE singleton = 1)
      AND NOT EXISTS (SELECT 1 FROM account_deletion_intents WHERE user_id = ?1)
  `).bind(userId, ownerAppleSub).first();
  return row !== null;
}

export async function getGroupSharingRestriction(db: D1Database, userId: string) {
  return workoutDB(db).prepare('SELECT active, reason, updated_at FROM group_sharing_restrictions WHERE user_id = ?1')
    .bind(userId).first<{ active: number; reason: GroupReportReason; updated_at: number }>();
}

export async function setGroupSharingRestriction(
  db: D1Database, operatorId: string, ownerAppleSub: string | undefined,
  targetId: string, active: boolean, reason: GroupReportReason,
): Promise<boolean> {
  if (!ownerAppleSub) return false;
  const ts = now();
  // Restriction and audit commit together. Authority is rechecked at the write,
  // including account deletion; no report content is copied into the audit.
  const [result] = await workoutDB(db).batch([
    workoutDB(db).prepare(`INSERT INTO group_sharing_restrictions (user_id, active, reason, updated_at)
      SELECT ?1, ?2, ?3, ?4 WHERE EXISTS (SELECT 1 FROM users WHERE id = ?1)
        AND EXISTS (SELECT 1 FROM users WHERE id = ?5 AND apple_sub = ?6)
        AND NOT EXISTS (SELECT 1 FROM owner_deletion_tombstone WHERE singleton = 1)
        AND NOT EXISTS (SELECT 1 FROM account_deletion_intents WHERE user_id IN (?1, ?5))
      ON CONFLICT (user_id) DO UPDATE SET active = excluded.active, reason = excluded.reason, updated_at = excluded.updated_at
    `).bind(targetId, active ? 1 : 0, reason, ts, operatorId, ownerAppleSub),
    workoutDB(db).prepare(`INSERT INTO audit_log (id, user_id, actor, tool, args, result, created_at)
      SELECT ?1, ?2, 'ios', 'set_group_sharing_restriction', ?3, ?4, ?5 WHERE changes() = 1
    `).bind(uuid(), operatorId, JSON.stringify({ user_id: targetId, reason }), active ? 'restricted' : 'restored', ts),
  ]);
  return (result?.meta.changes ?? 0) > 0;
}

async function hydrateGroup(
  db: D1Database,
  group: Group,
  callerUserId: string,
): Promise<Group & { members: ResolvedGroupMember[] }> {
  const rows = await visibleGroupMembers(db, group.id, callerUserId);
  const members: ResolvedGroupMember[] = rows.map((row) => ({
    group_id: group.id,
    user_id: row.user_id,
    display_name: sharedText(row.per_group_name, 'Member'),
    joined_at: row.joined_at,
    effective_display_name: sharedText(row.per_group_name ?? row.global_name, 'Member'),
  }));
  const creatorVisible = rows.some((row) => row.user_id === group.created_by);
  // Retain the existing string wire shape for older clients; an unavailable
  // creator has no report/block target and contributes no shared group name.
  return { ...group,
    created_by: creatorVisible ? group.created_by : '',
    name: creatorVisible ? sharedText(group.name, 'Private group')! : 'Private group',
    members };
}

/**
 * List groups the user belongs to, with members hydrated. Stable ordering
 * (created_at, then id) so the iOS list isn't shuffled across reads.
 */
export async function listGroupsForUser(
  db: D1Database,
  userId: string,
): Promise<Array<Group & { members: ResolvedGroupMember[] }>> {
  const r = await workoutDB(db)
    .prepare(
      `SELECT g.*, CASE WHEN EXISTS (SELECT 1 FROM group_sharing_restrictions r WHERE r.user_id = g.created_by AND r.active = 1) THEN 'Private group' ELSE g.name END AS name FROM groups g
         JOIN group_members gm ON gm.group_id = g.id
        WHERE gm.user_id = ?1
        ORDER BY g.created_at, g.id`,
    )
    .bind(userId)
    .all<Group>();
  const out: Array<Group & { members: ResolvedGroupMember[] }> = [];
  for (const g of r.results) {
    out.push(await hydrateGroup(db, g, userId));
  }
  return out;
}

/** Read a group + its members. Returns null if the group does not exist. */
export async function getGroupWithMembers(
  db: D1Database,
  groupId: string,
  callerUserId: string,
): Promise<(Group & { members: ResolvedGroupMember[] }) | null> {
  const g = await workoutDB(db)
    .prepare("SELECT g.*, CASE WHEN EXISTS (SELECT 1 FROM group_sharing_restrictions r WHERE r.user_id = g.created_by AND r.active = 1) THEN 'Private group' ELSE g.name END AS name FROM groups g WHERE id = ?1")
    .bind(groupId)
    .first<Group>();
  if (!g) return null;
  return hydrateGroup(db, g, callerUserId);
}

/**
 * Create a new invite code for a group. Caller MUST have already verified
 * `isGroupMember(db, userId, groupId)` — this function does not enforce
 * authorization (the REST handler does). `expiresAtMs` semantics:
 *   undefined → default = created_at + 30 days
 *   null      → never expires
 *   number    → exact epoch-ms expiry (caller-provided)
 * Retries up to 5x on PK collision (32^6 alphabet; the retry is paranoia).
 * Audited as 'create_invite' actor='ios'.
 */
export async function createInvite(
  db: D1Database,
  userId: string,
  groupId: string,
  expiresAtMs?: number | null,
): Promise<GroupInvite> {
  const ts = now();
  const expires =
    expiresAtMs === undefined ? ts + DEFAULT_INVITE_TTL_MS : expiresAtMs;
  let code = '';
  let lastErr: unknown = null;
  for (let attempt = 0; attempt < 5; attempt++) {
    code = newInviteCode();
    try {
      await workoutDB(db)
        .prepare(
          `INSERT INTO group_invites
             (code,group_id,created_by,created_at,expires_at,used_at,used_by)
           VALUES (?1,?2,?3,?4,?5,NULL,NULL)`,
        )
        .bind(code, groupId, userId, ts, expires)
        .run();
      lastErr = null;
      break;
    } catch (e) {
      // PK collision on `code` → regenerate. Any other error rethrows below.
      lastErr = e;
      const msg = (e as Error).message ?? '';
      if (!/UNIQUE|constraint/i.test(msg)) throw e;
    }
  }
  if (lastErr) throw lastErr;
  const invite: GroupInvite = {
    code,
    group_id: groupId,
    created_by: userId,
    created_at: ts,
    expires_at: expires,
    used_at: null,
    used_by: null,
  };
  await writeAudit(
    db,
    userId,
    'create_invite',
    { group_id: groupId, expires_at: expires },
    'created',
    'ios',
  );
  return invite;
}

/**
 * Read-only invite lookup (no consumption). Returns the row regardless
 * of used/expired state; the caller (redeemInvite) makes the
 * accept/reject call.
 */
export async function getInviteForRedemption(
  db: D1Database,
  code: string,
): Promise<GroupInvite | null> {
  const r = await workoutDB(db)
    .prepare('SELECT * FROM group_invites WHERE code = ?1')
    .bind(code)
    .first<GroupInvite>();
  return r ?? null;
}

/**
 * Public, read-only preview of an invite code — the data behind both the
 * Universal-Link landing page (`GET /join/:code`) and the in-app join-confirm
 * sheet (`GET /api/groups/invite/:code`). Returns the group NAME so the
 * invitee sees *what* they're joining, plus a status the caller renders:
 *   valid   — joinable now
 *   used    — already redeemed (codes are single-use)
 *   expired — past expires_at
 *   unknown — no such code, or the group is gone
 *
 * Leaks nothing privileged: the only data exposed is the group name, keyed by
 * a code the caller already holds. The code IS the join capability, so anyone
 * who can call this could already redeem it. Does NOT consume the code.
 */
export async function getInvitePreview(
  db: D1Database,
  code: string,
): Promise<{ status: 'valid' | 'used' | 'expired' | 'unknown'; group_name: string | null }> {
  // Normalize to the stored form (codes are always uppercase) so preview is
  // case-insensitive and identical across both callers — the public /join
  // landing page and the authenticated /api/groups/invite/:code route.
  const invite = await getInviteForRedemption(db, code.trim().toUpperCase());
  if (!invite) return { status: 'unknown', group_name: null };
  const group = await workoutDB(db)
    .prepare("SELECT CASE WHEN EXISTS (SELECT 1 FROM group_sharing_restrictions r WHERE r.user_id = g.created_by AND r.active = 1) THEN 'Private group' ELSE g.name END AS name FROM groups g WHERE id = ?1")
    .bind(invite.group_id)
    .first<{ name: string }>();
  const group_name = sharedText(group?.name ?? null, 'Private group');
  if (group_name == null) return { status: 'unknown', group_name: null };
  if (invite.used_at != null) return { status: 'used', group_name };
  if (invite.expires_at != null && invite.expires_at < now()) {
    return { status: 'expired', group_name };
  }
  return { status: 'valid', group_name };
}

/**
 * Redeem an invite as `userId`. Validates, claims the code, inserts the
 * membership, and writes the success audit. The three writes share one D1
 * transaction, so account deletion or another redemption cannot land between
 * an invite claim and its membership/audit. The conditional UPDATE means at
 * most one redeemer wins; a loser is mapped back to the current public error.
 *
 * `already_member` is a soft success-ish case: the user is *already* in
 * the group, the invite is NOT consumed, and the iOS client can show
 * "you're already in this group" without burning the code.
 *
 * Audited as 'redeem_invite' actor='ios' on success.
 */
export async function redeemInvite(
  db: D1Database,
  code: string,
  userId: string,
): Promise<
  | { ok: true; group_id: string }
  | { error: 'unknown' | 'used' | 'expired' | 'already_member' }
> {
  const invite = await getInviteForRedemption(db, code);
  if (!invite) return { error: 'unknown' };
  if (invite.used_at != null) return { error: 'used' };
  if (invite.expires_at != null && invite.expires_at < now()) {
    return { error: 'expired' };
  }
  if (await isGroupMember(db, userId, invite.group_id)) {
    // Already in — do NOT consume the code. The invite stays alive for
    // someone else to use; the redeemer just learns they're already in.
    return { error: 'already_member' };
  }
  const ts = now();
  const auditId = uuid();
  const auditArgs = JSON.stringify({ group_id: invite.group_id });
  const [claim] = await workoutDB(db).batch([
    // Repeat every mutable validation inside the transaction. In particular,
    // requiring a live principal with no deletion intent prevents a deletion
    // that won the database write lock first from consuming the invite, even
    // while provider revocation intentionally keeps the users row present.
    workoutDB(db)
      .prepare(
        `UPDATE group_invites
            SET used_at = ?2, used_by = ?3
          WHERE code = ?1
            AND used_at IS NULL
            AND (expires_at IS NULL OR expires_at >= ?2)
            AND EXISTS (SELECT 1 FROM users WHERE id = ?3)
            AND NOT EXISTS (
              SELECT 1 FROM account_deletion_intents WHERE user_id = ?3
            )
            AND NOT EXISTS (
              SELECT 1 FROM account_deletion_receipts WHERE user_id = ?3
            )
            AND NOT EXISTS (
              SELECT 1 FROM group_members gm
               WHERE gm.group_id = group_invites.group_id
                 AND gm.user_id = ?3
            )`,
      )
      .bind(code, ts, userId),
    // changes() observes the immediately preceding conditional UPDATE on this
    // SQLite connection. A losing batch creates neither an audit attempt nor a
    // membership; the unique audit id then gates the final INSERT.
    workoutDB(db)
      .prepare(
        `INSERT INTO audit_log
           (id,user_id,actor,tool,args,result,created_at)
         SELECT ?1,?2,'ios','redeem_invite',?3,'joined',?4
          WHERE changes() = 1`,
      )
      .bind(auditId, userId, auditArgs, ts),
    workoutDB(db)
      .prepare(
        `INSERT INTO group_members (group_id,user_id,display_name,joined_at)
         SELECT group_id,?2,NULL,?3 FROM group_invites
          WHERE code = ?1
            AND EXISTS (SELECT 1 FROM audit_log WHERE id = ?4)`,
      )
      .bind(code, userId, ts, auditId),
  ]);
  if ((claim?.meta.changes ?? 0) !== 1) {
    const current = await getInviteForRedemption(db, code);
    if (!current) return { error: 'unknown' };
    if (current.used_at != null) return { error: 'used' };
    if (current.expires_at != null && current.expires_at < now()) {
      return { error: 'expired' };
    }
    if (await isGroupMember(db, userId, current.group_id)) {
      return { error: 'already_member' };
    }
    // The only remaining expected case is a principal deleted before this
    // transaction obtained the write lock. Do not disclose that lifecycle
    // state through the invite surface.
    return { error: 'unknown' };
  }
  return { ok: true, group_id: invite.group_id };
}

/**
 * Remove the caller from a group. Idempotent — returns true if a row was
 * actually deleted, false if the caller was not a member (the REST handler
 * still returns 200 either way per spec). Last member leaving does NOT
 * delete the group; orphan groups are tolerated (cleanup deferred).
 */
export async function leaveGroup(
  db: D1Database,
  userId: string,
  groupId: string,
): Promise<boolean> {
  const res = await workoutDB(db)
    .prepare('DELETE FROM group_members WHERE group_id = ?1 AND user_id = ?2')
    .bind(groupId, userId)
    .run();
  const removed = (res.meta?.changes ?? 0) > 0;
  if (removed) {
    await writeAudit(
      db,
      userId,
      'leave_group',
      { group_id: groupId },
      'left',
      'ios',
    );
  }
  return removed;
}

/**
 * Set or clear the caller's per-group nickname override. NULL = clear
 * (fall back to users.display_name on read). Returns true if a row was
 * updated, false if the caller is not a member of the group.
 * Audited as 'set_group_display_name' actor='ios'.
 */
export async function setGroupDisplayName(
  db: D1Database,
  userId: string,
  groupId: string,
  displayName: string | null,
): Promise<boolean> {
  const res = await workoutDB(db)
    .prepare(
      'UPDATE group_members SET display_name = ?3 WHERE group_id = ?1 AND user_id = ?2',
    )
    .bind(groupId, userId, displayName)
    .run();
  const ok = (res.meta?.changes ?? 0) > 0;
  if (ok) {
    await writeAudit(
      db,
      userId,
      'set_group_display_name',
      { group_id: groupId, display_name: displayName },
      displayName == null ? 'cleared' : 'set',
      'ios',
    );
  }
  return ok;
}

/** Count rows in the users table. Used by /auth/apple to detect the fresh-install bootstrap path. */
export async function countUsers(db: D1Database): Promise<number> {
  const r = await workoutDB(db)
    .prepare('SELECT COUNT(*) AS c FROM users')
    .first<{ c: number }>();
  return r?.c ?? 0;
}

// ---- plan tree -----------------------------------------------------------

export async function getActivePlan(
  db: D1Database,
  userId: string,
): Promise<PlanRow | null> {
  return workoutDB(db)
    .prepare("SELECT * FROM plans WHERE user_id = ?1 AND status = 'active'")
    .bind(userId)
    .first<PlanRow>();
}

export async function getPlanTree(
  db: D1Database,
  userId: string,
): Promise<PlanTree | null> {
  const plan = await getActivePlan(db, userId);
  if (!plan) return null;
  const days = await workoutDB(db)
    .prepare('SELECT * FROM workouts WHERE plan_id = ?1 ORDER BY order_index, created_at, id')
    .bind(plan.id)
    .all<WorkoutRow>();
  const dayIds = days.results.map((d) => d.id);
  let exercises: EnrichedTemplateExercise[] = [];
  if (dayIds.length) {
    const placeholders = dayIds.map((_, i) => `?${i + 1}`).join(',');
    const res = await workoutDB(db)
      .prepare(
        `SELECT te.*, e.name AS exercise_name, e.unit AS exercise_unit,
                e.primary_muscle AS exercise_muscle, e.modality AS exercise_modality,
                e.laterality AS exercise_laterality, e.load_mode AS exercise_load_mode,
                e.demo_slug AS exercise_demo_slug
         FROM template_exercises te
         JOIN exercises e ON e.id = te.exercise_id
         WHERE te.workout_id IN (${placeholders}) ORDER BY te.order_index, te.created_at, te.id`,
      )
      .bind(...dayIds)
      .all<EnrichedTemplateExercise>();
    exercises = res.results;
  }
  return {
    ...plan,
    workouts: days.results.map((d) => ({
      ...d,
      exercises: exercises.filter((e) => e.workout_id === d.id),
    })),
  };
}

export interface PlanSnapshotRow {
  id: string;
  user_id: string;
  plan_id: string;
  version: number;
  document: string;
  actor: string;
  operation: string;
  reason: string | null;
  created_at: number;
}

export interface PlanWriteAttribution {
  actor: 'mcp' | 'ios' | 'system';
  operation: string;
  args?: unknown;
  reason?: string | null;
  note?: string | null;
  noteAuthor?: 'claude' | 'nick';
  result?: unknown;
}

/**
 * SQL serializer for the writable plan document. Keeping this as an INSERT
 * statement lets a plan writer append it to the same D1 batch as its CAS,
 * so a snapshot can never describe a later post-commit read.
 */
export function preparePlanSnapshotInsert(
  db: D1Database,
  input: {
    userId: string;
    planId: string;
    version?: number;
    actor: string;
    operation: string;
    reason?: string | null;
    createdAt: number;
    ignoreExisting?: boolean;
    writeNonce?: string;
    databaseVersion?: number;
  },
): D1PreparedStatement {
  const insert = input.ignoreExisting ? 'INSERT OR IGNORE' : 'INSERT';
  return workoutDB(db).prepare(
    `${insert} INTO plan_snapshots
       (id,user_id,plan_id,version,document,actor,operation,reason,created_at)
     SELECT ?1,p.user_id,p.id,COALESCE(?4,p.version),
       json_object(
         'schema_version',2,
         'plan',json_object('name',p.name,'meta',p.meta),
         'workouts',json(COALESCE((
           SELECT json_group_array(json(day_document)) FROM (
             SELECT json_object(
               'id',d.id,'name',d.name,'day_label',d.day_label,
               'order_index',d.order_index,'notes',d.notes,
               'exercises',json(COALESCE((
                 SELECT json_group_array(json(slot_document)) FROM (
                   SELECT json_object(
                     'id',te.id,'exercise_id',te.exercise_id,
                     'order_index',te.order_index,'target_sets',te.target_sets,
                     'target_reps',te.target_reps,'target_reps_max',te.target_reps_max,
                     'target_rpe',te.target_rpe,'rest_seconds',te.rest_seconds,
                     'target_weight',te.target_weight,'target_duration_s',te.target_duration_s,
                     'progression',te.progression,'cues',te.cues,'is_warmup',te.is_warmup,
                     'group_id',te.group_id,'group_rest_seconds',te.group_rest_seconds,
                     'group_transition_seconds',te.group_transition_seconds
                   ) AS slot_document
                   FROM template_exercises te
                   WHERE te.workout_id=d.id
                   ORDER BY te.order_index,te.created_at,te.id
                 )), '[]'))
             ) AS day_document
             FROM workouts d
             WHERE d.plan_id=p.id
             ORDER BY d.order_index,d.created_at,d.id
           )
         ), '[]'))
       ),?5,?6,?7,?8
     FROM plans p
     WHERE p.id=?2 AND p.user_id=?3 AND (?4 IS NULL OR p.version=?10)
       AND (?9 IS NULL OR p.plan_write_nonce=?9)`,
  ).bind(
    uuid(), input.planId, input.userId, input.version ?? null, input.actor,
    input.operation, input.reason ?? null, input.createdAt, input.writeNonce ?? null,
    input.databaseVersion ?? input.version ?? null,
  );
}

export function preparePlanWriteStart(
  db: D1Database,
  plan: PlanRow,
  attribution: PlanWriteAttribution,
  ts: number,
  nonce: string,
  rejectActiveWorkout = false,
): D1PreparedStatement[] {
  return [
    workoutDB(db).prepare(
      `UPDATE plans SET plan_write_nonce=?4,version=-version
        WHERE id=?1 AND user_id=?2 AND status='active' AND version=?3
          AND plan_write_nonce IS NULL
          AND EXISTS (SELECT 1 FROM users u WHERE u.id=?2)
          AND NOT EXISTS (SELECT 1 FROM account_deletion_intents i WHERE i.user_id=?2)
          AND NOT EXISTS (SELECT 1 FROM account_deletion_receipts r WHERE r.user_id=?2)
          AND (?5=0 OR NOT EXISTS (
            SELECT 1 FROM sessions s WHERE s.user_id=?2 AND s.plan_id=?1 AND s.status='in_progress'
          ))`,
    ).bind(plan.id, plan.user_id, plan.version, nonce, rejectActiveWorkout ? 1 : 0),
    preparePlanSnapshotInsert(db, {
      userId: plan.user_id, planId: plan.id, version: plan.version,
      actor: 'system', operation: 'baseline', reason: 'First captured version',
      createdAt: ts, ignoreExisting: true, writeNonce: nonce,
      databaseVersion: -plan.version,
    }),
  ];
}

export function preparePlanWriteFinish(
  db: D1Database,
  plan: PlanRow,
  attribution: PlanWriteAttribution,
  ts: number,
  nonce: string,
): D1PreparedStatement[] {
  const nextVersion = plan.version + 1;
  const statements: D1PreparedStatement[] = [
    workoutDB(db).prepare(
      `UPDATE plans SET version=?6,updated_at=?5
        WHERE id=?1 AND user_id=?2 AND version=-?3 AND plan_write_nonce=?4
        RETURNING version`,
    ).bind(plan.id, plan.user_id, plan.version, nonce, ts, nextVersion),
    workoutDB(db).prepare(
      `INSERT INTO audit_log (id,user_id,actor,tool,args,result,created_at)
       SELECT ?5,p.user_id,?6,?7,?8,?9,?10 FROM plans p
        WHERE p.id=?1 AND p.user_id=?2 AND p.version=?3 AND p.plan_write_nonce=?4`,
    ).bind(plan.id, plan.user_id, nextVersion, nonce, uuid(), attribution.actor,
      attribution.operation, JSON.stringify(attribution.args ?? {}),
      typeof attribution.result === 'string'
        ? attribution.result
        : JSON.stringify(attribution.result ?? { plan_id: plan.id, version: nextVersion }), ts),
  ];
  if (attribution.note) {
    statements.push(workoutDB(db).prepare(
      `INSERT INTO notes (id,user_id,scope,ref_id,author,body,created_at)
       SELECT ?5,p.user_id,'plan',p.id,?6,?7,?8 FROM plans p
        WHERE p.id=?1 AND p.user_id=?2 AND p.version=?3 AND p.plan_write_nonce=?4`,
    ).bind(plan.id, plan.user_id, nextVersion, nonce, uuid(),
      attribution.noteAuthor ?? (attribution.actor === 'mcp' ? 'claude' : 'nick'),
      attribution.note, ts));
  }
  statements.push(
    preparePlanSnapshotInsert(db, {
      userId: plan.user_id, planId: plan.id, version: nextVersion,
      actor: attribution.actor, operation: attribution.operation,
      reason: attribution.reason ?? attribution.note ?? null, createdAt: ts,
      writeNonce: nonce,
    }),
    workoutDB(db).prepare(
      `UPDATE plans SET plan_write_nonce=NULL
        WHERE id=?1 AND user_id=?2 AND version=?3 AND plan_write_nonce=?4`,
    ).bind(plan.id, plan.user_id, nextVersion, nonce),
  );
  return statements;
}

export async function getPlanSnapshot(
  db: D1Database,
  userId: string,
  planId: string,
  version: number,
): Promise<(PlanSnapshotRow & { parsed: PlanSnapshotDocument }) | null> {
  const row = await workoutDB(db).prepare(
    'SELECT * FROM plan_snapshots WHERE user_id=?1 AND plan_id=?2 AND version=?3',
  ).bind(userId, planId, version).first<PlanSnapshotRow>();
  return row ? { ...row, parsed: parsePlanSnapshot(row.document) } : null;
}

async function materializeSnapshotPlan(
  db: D1Database,
  base: PlanRow,
  version: number,
  updatedAt: number,
  document: PlanSnapshotDocument,
): Promise<PlanTree> {
  const catalog = new Map((await getExercises(db)).map((exercise) => [exercise.id, exercise]));
  return {
    ...base, name: document.plan.name, meta: document.plan.meta, version, updated_at: updatedAt,
    workouts: document.workouts.map((day) => ({
      ...day, plan_id: base.id, created_at: updatedAt, updated_at: updatedAt,
      exercises: day.exercises.map((slot) => {
        const exercise = catalog.get(slot.exercise_id);
        if (!exercise) throw new Error('snapshot_exercise_missing');
        return {
          ...slot, workout_id: day.id, created_at: updatedAt, updated_at: updatedAt,
          exercise_name: exercise.name, exercise_unit: exercise.unit,
          exercise_muscle: exercise.primary_muscle, exercise_modality: exercise.modality,
          exercise_laterality: exercise.laterality, exercise_load_mode: exercise.load_mode,
          exercise_demo_slug: exercise.demo_slug,
        };
      }),
    })),
  };
}

async function readCommittedSnapshotPlan(
  db: D1Database,
  base: PlanRow,
  version: number,
  updatedAt: number,
): Promise<PlanTree | null> {
  try {
    const snapshot = await getPlanSnapshot(db, base.user_id, base.id, version);
    return snapshot
      ? await materializeSnapshotPlan(db, base, version, updatedAt, snapshot.parsed)
      : null;
  } catch {
    // The mutation is already committed. A refresh failure must preserve its
    // acknowledgement so callers do not retry and create another version.
    return null;
  }
}

export async function listPlanHistory(
  db: D1Database,
  userId: string,
  limit = 30,
  beforeVersion?: number,
) {
  const plan = await getActivePlan(db, userId);
  if (!plan) return { error: 'no_active_plan' as const };
  const capped = Math.max(1, Math.min(100, Math.floor(limit)));
  const rows = await workoutDB(db).prepare(
    `SELECT * FROM plan_snapshots
      WHERE user_id=?1 AND plan_id=?2 AND (?3 IS NULL OR version < ?3) AND version <= ?5
      ORDER BY version DESC LIMIT ?4`,
  ).bind(userId, plan.id, beforeVersion ?? null, capped + 1, plan.version).all<PlanSnapshotRow>();
  const visible = rows.results.slice(0, capped);
  const exerciseNames = new Map((await getExercises(db)).map((exercise) => [exercise.id, exercise.name]));
  const items = await Promise.all(visible.map(async (row) => {
    const prior = await workoutDB(db).prepare(
      `SELECT version, document FROM plan_snapshots
        WHERE user_id=?1 AND plan_id=?2 AND version < ?3
        ORDER BY version DESC LIMIT 1`,
    ).bind(userId, plan.id, row.version).first<{ version: number; document: string }>();
    const comparison = prior
      ? comparePlanSnapshots(parsePlanSnapshot(prior.document), parsePlanSnapshot(row.document), { exerciseNames })
      : null;
    return {
      version: row.version, actor: row.actor, operation: row.operation,
      reason: row.reason, created_at: row.created_at, summary: comparison?.summary ?? null,
      previous_version: prior?.version ?? null,
      affected: comparison ? [...new Set(comparison.changes.map((change) =>
        change.kind === 'plan'
          ? (change.path === 'name' ? 'Training plan name' : 'Training context')
          : change.path))] : [],
    };
  }));
  return {
    plan_id: plan.id,
    current_version: plan.version,
    items,
    next_before_version: rows.results.length > capped ? visible.at(-1)?.version ?? null : null,
  };
}

export async function comparePlanVersions(
  db: D1Database,
  userId: string,
  fromVersion: number,
  toVersion?: number,
) {
  const plan = await getActivePlan(db, userId);
  if (!plan) return { error: 'no_active_plan' as const };
  const from = await getPlanSnapshot(db, userId, plan.id, fromVersion);
  if (!from) return { error: 'snapshot_not_found' as const };
  let toDocument: PlanSnapshotDocument | undefined;
  let resolvedTo = toVersion ?? plan.version;
  if (toVersion == null || toVersion === plan.version) {
    const captured = await getPlanSnapshot(db, userId, plan.id, plan.version);
    if (captured) {
      toDocument = captured.parsed;
    } else {
      // A pre-0040 plan has no captured current snapshot. Bound the legacy
      // fallback by the version before and after the multi-query tree read so
      // comparison content is never labeled with a different version.
      let stableTree: PlanTree | null = null;
      for (let attempt = 0; attempt < 3 && !stableTree; attempt++) {
        const before = await getActivePlan(db, userId);
        const tree = await getPlanTree(db, userId);
        const after = await getActivePlan(db, userId);
        if (before && tree && after && before.id === after.id &&
            before.version === tree.version && tree.version === after.version) {
          stableTree = tree;
          resolvedTo = tree.version;
        } else if (after) {
          const afterSnapshot = await getPlanSnapshot(db, userId, after.id, after.version);
          if (afterSnapshot) {
            toDocument = afterSnapshot.parsed;
            resolvedTo = after.version;
            break;
          }
        }
      }
      if (!toDocument && !stableTree) return { error: 'plan_changed' as const };
      if (stableTree) toDocument = serializePlanSnapshot(stableTree);
    }
  } else {
    const to = await getPlanSnapshot(db, userId, plan.id, toVersion);
    if (!to) return { error: 'snapshot_not_found' as const };
    toDocument = to.parsed;
  }
  if (!toDocument) return { error: 'plan_changed' as const };
  const exerciseNames = new Map((await getExercises(db)).map((exercise) => [exercise.id, exercise.name]));
  return {
    plan_id: plan.id, from_version: fromVersion, to_version: resolvedTo,
    ...comparePlanSnapshots(from.parsed, toDocument, { exerciseNames }),
  };
}

export async function restorePlanSnapshot(
  db: D1Database,
  userId: string,
  input: {
    plan_id: string;
    snapshot_version: number;
    expected_version: number;
    actor: 'mcp' | 'ios';
    reason?: string | null;
  },
): Promise<
  | { ok: true; plan_id: string; restored_from_version: number; version: number; plan: PlanTree }
  | { ok: true; acknowledged: true; refresh_required: true; plan_id: string; restored_from_version: number; version: number }
  | { conflict: true; current_plan_id: string; current_version: number }
  | { error: 'snapshot_not_found' | 'active_workout' | 'no_active_plan' }
  | PrescriptionValidationError | GroupConflict
> {
  const plan = await getActivePlan(db, userId);
  if (!plan) return { error: 'no_active_plan' };
  if (plan.id !== input.plan_id || plan.version !== input.expected_version) {
    return { conflict: true, current_plan_id: plan.id, current_version: plan.version };
  }
  const snapshot = await getPlanSnapshot(db, userId, plan.id, input.snapshot_version);
  if (!snapshot) return { error: 'snapshot_not_found' };
  const modalities = new Map((await getExercises(db)).map((exercise) => [exercise.id, exercise.modality]));
  const invalidFields = new Set<string>();
  for (const day of snapshot.parsed.workouts) for (const slot of day.exercises) {
    let progression: unknown = null;
    try { progression = slot.progression == null ? null : JSON.parse(slot.progression); }
    catch { invalidFields.add(`${day.day_label ?? day.name}/${slot.exercise_id}.progression`); }
    const invalid = validateExercisePrescription({ ...slot, progression }, {
      modality: modalities.get(slot.exercise_id),
    });
    for (const field of invalid?.fields ?? []) {
      invalidFields.add(`${day.day_label ?? day.name}/${slot.exercise_id}.${field}`);
    }
  }
  if (invalidFields.size > 0) {
    return { error: 'invalid_fields', fields: [...invalidFields].sort() };
  }
  const groupInvalid = validatePlanExerciseGroups(snapshot.parsed.workouts);
  if (groupInvalid) return groupInvalid;
  const active = await workoutDB(db).prepare(
    `SELECT 1 FROM sessions
      WHERE user_id=?1 AND plan_id=?2 AND status='in_progress' LIMIT 1`,
  ).bind(userId, plan.id).first();
  if (active) return { error: 'active_workout' };

  const current = await getPlanTree(db, userId);
  if (!current) return { error: 'no_active_plan' };
  const target = snapshot.parsed;
  const targetDayIds = new Set(target.workouts.map((day) => day.id));
  const targetSlots = target.workouts.flatMap((day) =>
    day.exercises.map((slot) => ({ ...slot, workout_id: day.id })),
  );
  const targetSlotIds = new Set(targetSlots.map((slot) => slot.id));
  const ts = now();
  const nonce = uuid();
  const guarded = `EXISTS (SELECT 1 FROM plans WHERE id=?1 AND user_id=?2 AND status='active' AND version=?3 AND plan_write_nonce='${nonce}')`;
  const statements: D1PreparedStatement[] = [
    ...preparePlanWriteStart(db, plan, {
      actor: input.actor, operation: 'restore_plan', args: input,
      reason: input.reason,
      note: input.reason ?? `Restored plan version ${input.snapshot_version}.`,
    }, ts, nonce, true),
  ];
  for (const day of target.workouts) {
    statements.push(workoutDB(db).prepare(
      `INSERT OR IGNORE INTO workouts
       (id,plan_id,name,day_label,order_index,notes,created_at,updated_at)
       SELECT ?4,?1,?5,?6,?7,?8,?9,?9 WHERE ${guarded}`,
    ).bind(plan.id, userId, -plan.version, day.id, day.name, day.day_label,
      day.order_index, day.notes, ts));
    statements.push(workoutDB(db).prepare(
      `UPDATE workouts SET name=?5,day_label=?6,order_index=?7,notes=?8,updated_at=?9
       WHERE id=?4 AND plan_id=?1 AND ${guarded}`,
    ).bind(plan.id, userId, -plan.version, day.id, day.name, day.day_label,
      day.order_index, day.notes, ts));
  }
  for (const slot of targetSlots) {
    statements.push(workoutDB(db).prepare(
      `INSERT OR IGNORE INTO template_exercises
       (id,workout_id,exercise_id,order_index,target_sets,target_reps,target_reps_max,
        target_rpe,rest_seconds,target_weight,target_duration_s,progression,cues,is_warmup,
        created_at,updated_at,group_id,group_rest_seconds,group_transition_seconds)
       SELECT ?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?18,?19,?20,?21
       WHERE ${guarded}`,
    ).bind(plan.id, userId, -plan.version, slot.id, slot.workout_id,
      slot.exercise_id, slot.order_index, slot.target_sets, slot.target_reps,
      slot.target_reps_max, slot.target_rpe, slot.rest_seconds, slot.target_weight,
      slot.target_duration_s, slot.progression, slot.cues, slot.is_warmup, ts,
      slot.group_id ?? null, slot.group_rest_seconds ?? null, slot.group_transition_seconds ?? null));
    statements.push(workoutDB(db).prepare(
      `UPDATE template_exercises SET workout_id=?5,exercise_id=?6,order_index=?7,
       target_sets=?8,target_reps=?9,target_reps_max=?10,target_rpe=?11,
       rest_seconds=?12,target_weight=?13,target_duration_s=?14,progression=?15,
       cues=?16,is_warmup=?17,updated_at=?18,group_id=?19,group_rest_seconds=?20,
       group_transition_seconds=?21 WHERE id=?4 AND ${guarded}`,
    ).bind(plan.id, userId, -plan.version, slot.id, slot.workout_id,
      slot.exercise_id, slot.order_index, slot.target_sets, slot.target_reps,
      slot.target_reps_max, slot.target_rpe, slot.rest_seconds, slot.target_weight,
      slot.target_duration_s, slot.progression, slot.cues, slot.is_warmup, ts,
      slot.group_id ?? null, slot.group_rest_seconds ?? null, slot.group_transition_seconds ?? null));
  }
  for (const day of current.workouts) {
    for (const slot of day.exercises) if (!targetSlotIds.has(slot.id)) {
      statements.push(
        workoutDB(db).prepare(`UPDATE set_logs SET template_exercise_id=NULL,updated_at=MAX(updated_at+1,?4) WHERE template_exercise_id=?5 AND ${guarded}`)
          .bind(plan.id, userId, -plan.version, ts, slot.id),
        workoutDB(db).prepare(`DELETE FROM template_exercises WHERE id=?4 AND ${guarded}`)
          .bind(plan.id, userId, -plan.version, slot.id),
      );
    }
    if (!targetDayIds.has(day.id)) {
      statements.push(
        workoutDB(db).prepare(`UPDATE sessions SET workout_id=NULL,updated_at=?4 WHERE workout_id=?5 AND user_id=?2 AND ${guarded}`)
          .bind(plan.id, userId, -plan.version, ts, day.id),
        workoutDB(db).prepare(`DELETE FROM workouts WHERE id=?4 AND plan_id=?1 AND ${guarded}`)
          .bind(plan.id, userId, -plan.version, day.id),
      );
    }
  }
  statements.push(workoutDB(db).prepare(
    `UPDATE plans SET name=?4,meta=?5,updated_at=?6
     WHERE id=?1 AND user_id=?2 AND status='active' AND version=?3 AND plan_write_nonce=?7`,
  ).bind(plan.id, userId, -plan.version, target.plan.name, target.plan.meta, ts, nonce));
  const documentUpdateIndex = statements.length - 1;
  const versionResultIndex = statements.length;
  statements.push(...preparePlanWriteFinish(db, plan, {
    actor: input.actor, operation: 'restore_plan', args: input,
    reason: input.reason,
    note: input.reason ?? `Restored plan version ${input.snapshot_version}.`,
  }, ts, nonce));
  const results = await runWorkoutWriteBatch(db, statements);
  if ((results[0]?.meta.changes ?? 0) !== 1 || (results[documentUpdateIndex]?.meta.changes ?? 0) !== 1 || !results[versionResultIndex]?.results[0]) {
    const nowActive = await workoutDB(db).prepare(
      `SELECT 1 FROM sessions WHERE user_id=?1 AND plan_id=?2 AND status='in_progress' LIMIT 1`,
    ).bind(userId, plan.id).first();
    if (nowActive) return { error: 'active_workout' };
    const latest = await getActivePlan(db, userId);
    return {
      conflict: true,
      current_plan_id: latest?.id ?? plan.id,
      current_version: latest?.version ?? plan.version,
    };
  }
  const restoredVersion = plan.version + 1;
  const committedPlan = await readCommittedSnapshotPlan(db, plan, restoredVersion, ts);
  if (!committedPlan) {
    return {
      ok: true, acknowledged: true, refresh_required: true, plan_id: plan.id,
      restored_from_version: input.snapshot_version, version: restoredVersion,
    };
  }
  return {
    ok: true, plan_id: plan.id, restored_from_version: input.snapshot_version,
    version: restoredVersion, plan: committedPlan,
  };
}

export async function createPlan(
  db: D1Database,
  userId: string,
  name: string,
  meta: unknown = null,
  attribution: PlanWriteAttribution = { actor: 'system', operation: 'create_plan' },
): Promise<PlanRow> {
  const ts = now();
  const planId = uuid();
  const serializedMeta = meta == null ? null : JSON.stringify(meta);
  // Archive + replace in one D1 transaction. This also serializes against
  // ensureActivePlan's conflict-safe insert: an ensure cannot land between
  // these statements and make the replacement violate ux_one_active_plan.
  // Allocate from every prior plan inside that transaction so replacement
  // never moves the per-user sync cursor backward or repeats it.
  const results = await workoutDB(db).batch<PlanRow>([
    workoutDB(db)
      .prepare(
        "UPDATE plans SET status = 'archived', updated_at = ?2 WHERE user_id = ?1 AND status = 'active'",
      )
      .bind(userId, ts),
    workoutDB(db)
      .prepare(
        `INSERT INTO plans
           (id,user_id,name,status,version,meta,created_at,updated_at)
         SELECT ?1,?2,?3,'active',COALESCE(MAX(version),0)+1,?4,?5,?5
           FROM plans
          WHERE user_id=?2
         RETURNING *`,
      )
      .bind(planId, userId, name, serializedMeta, ts),
    preparePlanSnapshotInsert(db, {
      userId, planId, actor: attribution.actor, operation: attribution.operation,
      reason: attribution.reason ?? attribution.note ?? null, createdAt: ts,
    }),
    workoutDB(db).prepare(
      `INSERT INTO audit_log (id,user_id,actor,tool,args,result,created_at)
       SELECT ?1,?2,?3,?4,?5,?6,?7 WHERE EXISTS
       (SELECT 1 FROM plans WHERE id=?8 AND user_id=?2)`,
    ).bind(uuid(), userId, attribution.actor, attribution.operation,
      JSON.stringify(attribution.args ?? {}), JSON.stringify({ plan_id: planId }), ts, planId),
  ]);
  const plan = results[1]?.results[0];
  if (!plan) throw new Error('active_plan_replace_missing_result');
  return plan;
}

/**
 * Idempotent app bootstrap for manual authoring. Unlike `createPlan`, this
 * never archives or replaces an active plan. The partial unique index on
 * plans(user_id) serializes concurrent app/coach creation; a losing caller
 * simply returns the winner.
 */
export async function ensureActivePlan(
  db: D1Database,
  userId: string,
  name: string,
  attribution: PlanWriteAttribution = { actor: 'system', operation: 'ensure_active_plan' },
): Promise<{ plan: PlanRow; created: boolean }> {
  const existing = await getActivePlan(db, userId);
  if (existing) return { plan: existing, created: false };

  const ts = now();
  const candidateId = uuid();
  const candidateInsert = workoutDB(db).prepare(
      `INSERT INTO plans
         (id,user_id,name,status,version,meta,created_at,updated_at)
       SELECT ?1,?2,?3,'active',COALESCE(MAX(version),0)+1,NULL,?4,?4
         FROM plans
        WHERE user_id=?2
       ON CONFLICT DO NOTHING
       RETURNING *`,
    )
    .bind(candidateId, userId, name, ts);
  const results = await workoutDB(db).batch<PlanRow>([
    candidateInsert,
    preparePlanSnapshotInsert(db, {
      userId, planId: candidateId, actor: attribution.actor,
      operation: attribution.operation, reason: attribution.reason ?? null, createdAt: ts,
    }),
    workoutDB(db).prepare(
      `INSERT INTO audit_log (id,user_id,actor,tool,args,result,created_at)
       SELECT ?1,?2,?3,?4,?5,?6,?7 WHERE EXISTS
       (SELECT 1 FROM plans WHERE id=?8 AND user_id=?2)`,
    ).bind(uuid(), userId, attribution.actor, attribution.operation,
      JSON.stringify(attribution.args ?? {}), JSON.stringify({ plan_id: candidateId }), ts, candidateId),
  ]);
  const created = results[0]?.results[0];
  if (created) {
    return { plan: created, created: true };
  }

  const winner = await getActivePlan(db, userId);
  if (!winner) throw new Error('active_plan_create_conflict_without_winner');
  return { plan: winner, created: false };
}

/** Bump the plan version + updated_at. Called by every plan-tree mutation. */
export async function bumpPlanVersion(db: D1Database, planId: string): Promise<number> {
  const row = await workoutDB(db)
    .prepare('UPDATE plans SET version = version + 1, updated_at = ?2 WHERE id = ?1 RETURNING version')
    .bind(planId, now())
    .first<{ version: number }>();
  return row?.version ?? 0;
}

export async function addWorkout(
  db: D1Database,
  planId: string,
  name: string,
  dayLabel: string | null,
  orderIndex: number,
  normalizeOrder = false,
): Promise<WorkoutRow> {
  const ts = now();
  const row: WorkoutRow = {
    id: uuid(),
    plan_id: planId,
    name,
    day_label: dayLabel,
    order_index: orderIndex,
    notes: null,
    created_at: ts,
    updated_at: ts,
  };
  await workoutDB(db)
    .prepare(
      'INSERT INTO workouts (id,plan_id,name,day_label,order_index,notes,created_at,updated_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8)',
    )
    .bind(row.id, row.plan_id, row.name, row.day_label, row.order_index, row.notes, row.created_at, row.updated_at)
    .run();
  if (normalizeOrder && await dedupePlanDayOrderIndexes(db, planId, row.id)) {
    const fresh = await workoutDB(db)
      .prepare('SELECT order_index FROM workouts WHERE id = ?1')
      .bind(row.id)
      .first<{ order_index: number }>();
    if (fresh) row.order_index = fresh.order_index;
  }
  await bumpPlanVersion(db, planId);
  return row;
}

/** Resolve a day only inside one already-authorized plan. */
export async function getWorkoutInPlan(
  db: D1Database,
  planId: string,
  dayId: string,
): Promise<WorkoutRow | null> {
  return workoutDB(db)
    .prepare('SELECT * FROM workouts WHERE id = ?1 AND plan_id = ?2')
    .bind(dayId, planId)
    .first<WorkoutRow>();
}

/** Allowlist of patch keys accepted by `patchWorkout`. Unknown keys
 *  surface as `{ error: 'unknown_fields', fields }` — same diagnosability
 *  contract as updateExercise. */
const DAY_TEMPLATE_PATCH_KEYS = new Set<string>([
  'name',
  'day_label',
  'order_index',
  'notes',
]);

export async function patchWorkout(
  db: D1Database,
  planId: string,
  dayId: string,
  patch: {
    name?: string;
    day_label?: string | null;
    order_index?: number;
    notes?: string | null;
  },
  normalizeOrder = false,
): Promise<WorkoutRow | { error: 'unknown_fields'; fields: string[] } | null> {
  const existing = await workoutDB(db)
    .prepare('SELECT * FROM workouts WHERE id = ?1 AND plan_id = ?2')
    .bind(dayId, planId)
    .first<WorkoutRow>();
  if (!existing) return null;
  const unknown = Object.keys(patch).filter((k) => !DAY_TEMPLATE_PATCH_KEYS.has(k));
  if (unknown.length > 0) return { error: 'unknown_fields', fields: unknown };
  const merged = {
    name: patch.name ?? existing.name,
    day_label: patch.day_label === undefined ? existing.day_label : patch.day_label,
    order_index: patch.order_index ?? existing.order_index,
    notes: patch.notes === undefined ? existing.notes : patch.notes,
  };
  await workoutDB(db)
    .prepare('UPDATE workouts SET name=?2, day_label=?3, order_index=?4, notes=?5, updated_at=?6 WHERE id=?1')
    .bind(dayId, merged.name, merged.day_label, merged.order_index, merged.notes, now())
    .run();
  if (normalizeOrder && patch.order_index !== undefined) {
    await dedupePlanDayOrderIndexes(db, planId, dayId);
    const fresh = await workoutDB(db)
      .prepare('SELECT order_index FROM workouts WHERE id = ?1')
      .bind(dayId)
      .first<{ order_index: number }>();
    if (fresh) merged.order_index = fresh.order_index;
  }
  await bumpPlanVersion(db, planId);
  return { ...existing, ...merged, updated_at: now() };
}

export type PlanVersionConflict = { conflict: true; current_version: number };

const orderDayRows = <T extends { id: string; order_index: number }>(
  rows: T[],
  movedId: string,
): T[] => {
  const moved = rows.find((row) => row.id === movedId);
  if (!moved) return rows;
  const others = rows.filter((row) => row.id !== movedId);
  const target = Math.max(0, Math.min(moved.order_index, others.length));
  return [...others.slice(0, target), moved, ...others.slice(target)];
};

async function currentPlanVersion(
  db: D1Database,
  userId: string,
  fallback: number,
): Promise<PlanVersionConflict> {
  const current = await getActivePlan(db, userId);
  return { conflict: true, current_version: current?.version ?? fallback };
}

/**
 * App day creation tied to the exact plan version the route read. D1 batches
 * are transactions, so the day insert, dense ordering, and version bump either
 * commit together or all observe that a concurrent plan writer won.
 */
export async function addWorkoutAtVersion(
  db: D1Database,
  userId: string,
  plan: PlanRow,
  name: string,
  dayLabel: string | null,
  orderIndex: number,
  attribution: PlanWriteAttribution = { actor: 'system', operation: 'add_day' },
): Promise<WorkoutRow | PlanVersionConflict> {
  const ts = now();
  const row: WorkoutRow = {
    id: uuid(),
    plan_id: plan.id,
    name,
    day_label: dayLabel,
    order_index: orderIndex,
    notes: null,
    created_at: ts,
    updated_at: ts,
  };
  const currentDays = await workoutDB(db)
    .prepare(
      'SELECT id, order_index FROM workouts WHERE plan_id = ?1 ORDER BY order_index, created_at, id',
    )
    .bind(plan.id)
    .all<{ id: string; order_index: number }>();
  const ordered = orderDayRows([...currentDays.results, row], row.id);
  const nonce = uuid();
  const statements: D1PreparedStatement[] = [
    ...preparePlanWriteStart(db, plan, attribution, ts, nonce),
    workoutDB(db)
      .prepare(
        `INSERT INTO workouts
         (id,plan_id,name,day_label,order_index,notes,created_at,updated_at)
         SELECT ?1,?2,?3,?4,?5,?6,?7,?8
          WHERE EXISTS (
            SELECT 1 FROM plans
             WHERE id = ?2 AND user_id = ?9 AND status = 'active' AND version = ?10
          )`,
      )
      .bind(
        row.id, row.plan_id, row.name, row.day_label, row.order_index, row.notes,
        row.created_at, row.updated_at, userId, -plan.version,
      ),
    ...ordered.map((day, index) =>
      workoutDB(db)
        .prepare(
          `UPDATE workouts SET order_index = ?2, updated_at = ?3
            WHERE id = ?1 AND plan_id = ?4
              AND EXISTS (
                SELECT 1 FROM plans
                 WHERE id = ?4 AND user_id = ?5 AND status = 'active' AND version = ?6
              )`,
        )
        .bind(day.id, index, ts, plan.id, userId, -plan.version),
    ),
  ];
  const versionResultIndex = statements.length;
  statements.push(...preparePlanWriteFinish(db, plan, { ...attribution, result: row.id }, ts, nonce));
  const results = await runWorkoutWriteBatch<{ version: number }>(db, statements);
  const inserted = results[2];
  const updatedPlan = results[versionResultIndex]?.results[0];
  if ((results[0]?.meta.changes ?? 0) !== 1 || (inserted?.meta.changes ?? 0) !== 1 || !updatedPlan) {
    return currentPlanVersion(db, userId, plan.version);
  }
  row.order_index = ordered.findIndex((day) => day.id === row.id);
  return row;
}

/** Rename/reorder one day with write-time optimistic concurrency. */
export async function patchWorkoutAtVersion(
  db: D1Database,
  userId: string,
  plan: PlanRow,
  dayId: string,
  patch: {
    name?: string;
    day_label?: string | null;
    order_index?: number;
    notes?: string | null;
  },
  attribution: PlanWriteAttribution = { actor: 'system', operation: 'update_day' },
): Promise<WorkoutRow | { error: 'unknown_fields'; fields: string[] } | PlanVersionConflict | null> {
  const existing = await getWorkoutInPlan(db, plan.id, dayId);
  if (!existing) return null;
  const unknown = Object.keys(patch).filter((key) => !DAY_TEMPLATE_PATCH_KEYS.has(key));
  if (unknown.length > 0) return { error: 'unknown_fields', fields: unknown };
  const merged: WorkoutRow = {
    ...existing,
    name: patch.name ?? existing.name,
    day_label: patch.day_label === undefined ? existing.day_label : patch.day_label,
    order_index: patch.order_index ?? existing.order_index,
    notes: patch.notes === undefined ? existing.notes : patch.notes,
    updated_at: now(),
  };
  const currentDays = await workoutDB(db)
    .prepare(
      'SELECT id, order_index FROM workouts WHERE plan_id = ?1 ORDER BY order_index, created_at, id',
    )
    .bind(plan.id)
    .all<{ id: string; order_index: number }>();
  const withMove = currentDays.results.map((day) =>
    day.id === dayId ? { ...day, order_index: merged.order_index } : day,
  );
  const ordered = patch.order_index === undefined
    ? withMove
    : orderDayRows(withMove, dayId);
  const nonce = uuid();
  const statements: D1PreparedStatement[] = [
    ...preparePlanWriteStart(db, plan, attribution, merged.updated_at, nonce),
    workoutDB(db)
      .prepare(
        `UPDATE workouts
            SET name=?2, day_label=?3, order_index=?4, notes=?5, updated_at=?6
          WHERE id=?1 AND plan_id=?7
            AND EXISTS (
              SELECT 1 FROM plans
               WHERE id=?7 AND user_id=?8 AND status='active' AND version=?9
            )`,
      )
      .bind(
        dayId, merged.name, merged.day_label, merged.order_index, merged.notes,
        merged.updated_at, plan.id, userId, -plan.version,
      ),
    ...(patch.order_index === undefined
      ? []
      : ordered.map((day, index) =>
          workoutDB(db)
            .prepare(
              `UPDATE workouts SET order_index=?2, updated_at=?3
                WHERE id=?1 AND plan_id=?4
                  AND EXISTS (
                    SELECT 1 FROM plans
                     WHERE id=?4 AND user_id=?5 AND status='active' AND version=?6
                  )`,
            )
            .bind(day.id, index, merged.updated_at, plan.id, userId, -plan.version),
        )),
  ];
  const versionResultIndex = statements.length;
  statements.push(...preparePlanWriteFinish(db, plan, attribution, merged.updated_at, nonce));
  const results = await runWorkoutWriteBatch<{ version: number }>(db, statements);
  const patched = results[2];
  const updatedPlan = results[versionResultIndex]?.results[0];
  if ((results[0]?.meta.changes ?? 0) !== 1 || (patched?.meta.changes ?? 0) !== 1 || !updatedPlan) {
    return currentPlanVersion(db, userId, plan.version);
  }
  if (patch.order_index !== undefined) {
    merged.order_index = ordered.findIndex((day) => day.id === dayId);
  }
  return merged;
}

/** Dense, deterministic order for workout days after an explicit move. */
export async function dedupePlanDayOrderIndexes(
  db: D1Database,
  planId: string,
  preferId?: string,
): Promise<boolean> {
  const rows = await workoutDB(db)
    .prepare(
      'SELECT id, order_index FROM workouts WHERE plan_id = ?1 ORDER BY order_index, created_at, id',
    )
    .bind(planId)
    .all<{ id: string; order_index: number }>();
  const list = rows.results;
  const dense = list.every((row, index) => row.order_index === index);
  if (dense) return false;

  const ordered = preferId ? orderDayRows(list, preferId) : list;
  const ts = now();
  for (let index = 0; index < ordered.length; index++) {
    if (ordered[index]!.order_index !== index) {
      await workoutDB(db)
        .prepare('UPDATE workouts SET order_index = ?2, updated_at = ?3 WHERE id = ?1')
        .bind(ordered[index]!.id, index, ts)
        .run();
    }
  }
  return true;
}

/**
 * Next `order_index` for an append to a day — max existing + 1, or 0 if
 * the day has no exercises yet. Callers should use this when no explicit
 * order_index is given, instead of defaulting to a sentinel like 99
 * (which silently stranded every after-creation `add_exercise` at the
 * bottom; agent-facing P0 in the bug report).
 */
export async function nextExerciseOrderIndex(
  db: D1Database,
  workoutId: string,
): Promise<number> {
  const row = await workoutDB(db)
    .prepare('SELECT COALESCE(MAX(order_index), -1) AS m FROM template_exercises WHERE workout_id = ?1')
    .bind(workoutId)
    .first<{ m: number }>();
  return (row?.m ?? -1) + 1;
}

async function exerciseGroupDayRows(db: D1Database, dayId: string): Promise<TemplateExerciseRow[]> {
  return (await workoutDB(db).prepare(
    'SELECT * FROM template_exercises WHERE workout_id=?1 ORDER BY order_index,created_at,id',
  ).bind(dayId).all<TemplateExerciseRow>()).results;
}


/**
 * Collapse duplicate `order_index` values within one day to a dense,
 * deterministic 0..n-1 sequence. No-op when indices are already unique, so
 * it's cheap to call defensively after any write that takes an explicit
 * order_index (add_exercise / update_exercise). Returns true if it rewrote.
 *
 * `preferId` is the slot the caller just placed at an explicit index. To
 * honor that destination exactly (in BOTH directions — moving up or down),
 * we rebuild the order by removing that slot, densely ordering the rest by
 * (order_index, created_at, id), then re-inserting the slot at its requested
 * index (clamped). A tiebreak alone is insufficient: it works for upward
 * moves but a downward move (e.g. 0 → 2) would land one short after the
 * dense pass.
 */
export async function dedupeDayOrderIndexes(
  db: D1Database, workoutId: string, preferId?: string,
): Promise<boolean | GroupConflict> {
  const plan = await workoutDB(db).prepare(
    `SELECT p.* FROM plans p JOIN workouts d ON d.plan_id=p.id
     WHERE d.id=?1 AND p.status='active'`,
  ).bind(workoutId).first<PlanRow>();
  if (!plan) return false;
  const list = await exerciseGroupDayRows(db, workoutId);
  if (preferId && list.find((row) => row.id === preferId)?.group_id != null) {
    return { error: 'group_conflict', fields: ['order_index'] };
  }
  const hasDup = new Set(list.map((row) => row.order_index)).size !== list.length;
  const ordered = (hasDup && preferId ? orderDayRows(list, preferId) : list)
    .map((row, index) => hasDup ? { ...row, order_index: index } : row);
  const invalid = validateExerciseGroups(ordered);
  if (invalid) return invalid;
  if (!hasDup) return false;
  const ts = now(); const nonce = uuid();
  const attribution: PlanWriteAttribution = { actor: 'system', operation: 'normalize_exercise_order' };
  const statements = preparePlanWriteStart(db, plan, attribution, ts, nonce);
  for (const row of ordered) statements.push(workoutDB(db).prepare(
    `UPDATE template_exercises SET order_index=?2,updated_at=?3 WHERE id=?1
     AND EXISTS (SELECT 1 FROM plans WHERE id=?4 AND user_id=?5 AND version=-?6 AND plan_write_nonce=?7)`,
  ).bind(row.id, row.order_index, ts, plan.id, plan.user_id, plan.version, nonce));
  statements.push(...preparePlanWriteFinish(db, plan, attribution, ts, nonce));
  const results = await runWorkoutWriteBatch(db, statements);
  if ((results[0]?.meta.changes ?? 0) !== 1) throw new Error('plan_write_conflict');
  return true;
}

/** Sibling of `nextExerciseOrderIndex` for `workouts` — append a new
 *  day densely instead of the old 99 sentinel that `add_day` used. */
export async function nextWorkoutOrderIndex(
  db: D1Database,
  planId: string,
): Promise<number> {
  const row = await workoutDB(db)
    .prepare('SELECT COALESCE(MAX(order_index), -1) AS m FROM workouts WHERE plan_id = ?1')
    .bind(planId)
    .first<{ m: number }>();
  return (row?.m ?? -1) + 1;
}

export async function addTemplateExercise(
  db: D1Database,
  planId: string,
  input: Omit<TemplateExerciseRow, 'id' | 'created_at' | 'updated_at' | 'is_warmup'> & {
    is_warmup: number | boolean;
  },
  attribution: PlanWriteAttribution = { actor: 'system', operation: 'add_exercise' },
): Promise<TemplateExerciseRow | PrescriptionValidationError | GroupConflict> {
  const plan = await workoutDB(db).prepare("SELECT * FROM plans WHERE id=?1 AND status='active'")
    .bind(planId).first<PlanRow>();
  if (!plan) throw new Error('no_active_plan');
  const exercise = await workoutDB(db).prepare('SELECT modality FROM exercises WHERE id=?1')
    .bind(input.exercise_id).first<{ modality: string }>();
  const validationInput: Record<string, unknown> = {
    ...input,
    progression: input.progression === null
      ? null
      : (() => { try { return JSON.parse(input.progression); } catch { return input.progression; } })(),
  };
  const invalid = validateExercisePrescription(validationInput, { modality: exercise?.modality });
  if (invalid) return invalid;
  const groupFields = ['group_id', 'group_rest_seconds', 'group_transition_seconds'] as const;
  const suppliedGroupFields = groupFields.filter((field) => input[field] != null);
  if (suppliedGroupFields.length) return { error: 'group_conflict', fields: suppliedGroupFields };
  const ts = now();
  const row: TemplateExerciseRow = {
    ...input,
    is_warmup: input.is_warmup ? 1 : 0,
    id: uuid(),
    created_at: ts,
    updated_at: ts,
  };
  const siblings = await exerciseGroupDayRows(db, row.workout_id);
  const collides = siblings.some((slot) => slot.order_index === row.order_index);
  const ordered = collides ? orderDayRows([...siblings, row], row.id) : [...siblings, row];
  const groupInvalid = validateExerciseGroups(ordered.map((slot, index) => collides ? { ...slot, order_index: index } : slot));
  if (groupInvalid) return groupInvalid;
  const nonce = uuid();
  const statements: D1PreparedStatement[] = [
    ...preparePlanWriteStart(db, plan, attribution, ts, nonce),
    workoutDB(db).prepare(
      `INSERT INTO template_exercises
       (id,workout_id,exercise_id,order_index,target_sets,target_reps,target_reps_max,target_rpe,rest_seconds,target_weight,target_duration_s,progression,cues,is_warmup,created_at,updated_at)
       SELECT ?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16
       WHERE EXISTS (SELECT 1 FROM plans WHERE id=?17 AND user_id=?18 AND version=-?19 AND plan_write_nonce=?20)`,
    )
    .bind(
      row.id, row.workout_id, row.exercise_id, row.order_index, row.target_sets,
      row.target_reps, row.target_reps_max, row.target_rpe, row.rest_seconds,
      row.target_weight, row.target_duration_s, row.progression, row.cues, row.is_warmup ? 1 : 0,
      row.created_at, row.updated_at, plan.id, plan.user_id, plan.version, nonce,
    ),
    ...(collides ? ordered.map((slot, index) => workoutDB(db).prepare(
      `UPDATE template_exercises SET order_index=?2,updated_at=?3 WHERE id=?1
       AND EXISTS (SELECT 1 FROM plans WHERE id=?4 AND user_id=?5 AND version=-?6 AND plan_write_nonce=?7)`,
    ).bind(slot.id, index, ts, plan.id, plan.user_id, plan.version, nonce)) : []),
  ];
  const versionResultIndex = statements.length;
  statements.push(...preparePlanWriteFinish(db, plan, { ...attribution, result: row.id }, ts, nonce));
  const results = await runWorkoutWriteBatch<{ version: number }>(db, statements);
  if ((results[0]?.meta.changes ?? 0) !== 1 || (results[2]?.meta.changes ?? 0) !== 1 || !results[versionResultIndex]?.results[0]) {
    throw new Error('plan_write_conflict');
  }
  if (collides) row.order_index = ordered.findIndex((slot) => slot.id === row.id);
  return row;
}

// ---- exercise resolver ---------------------------------------------------

/**
 * Discoverable exercise catalog read for agents — closes the agent-facing
 * "exercise vocabulary is closed and undiscoverable" P1 in the bug report.
 * Optional filters: case-insensitive substring `query` (matches `name`),
 * exact `muscle` (matches `primary_muscle`), exact `modality`. Returns a
 * compact projection ordered by name.
 */
export async function getExercises(
  db: D1Database,
  filters: { query?: string; muscle?: string; modality?: string } = {},
): Promise<
  {
    id: string;
    name: string;
    primary_muscle: string;
    modality: string;
    unit: string;
    laterality: string;
    load_mode: string;
    demo_slug: string | null;
  }[]
> {
  const where: string[] = [];
  const binds: (string | number)[] = [];
  if (filters.query && filters.query.trim() !== '') {
    binds.push(`%${filters.query.trim().toLowerCase()}%`);
    where.push(`lower(name) LIKE ?${binds.length}`);
  }
  if (filters.muscle && filters.muscle.trim() !== '') {
    binds.push(filters.muscle.trim().toLowerCase());
    where.push(`lower(primary_muscle) = ?${binds.length}`);
  }
  if (filters.modality && filters.modality.trim() !== '') {
    binds.push(filters.modality.trim().toLowerCase());
    where.push(`lower(modality) = ?${binds.length}`);
  }
  const sql =
    'SELECT id, name, primary_muscle, modality, unit, laterality, load_mode, demo_slug FROM exercises' +
    (where.length ? ' WHERE ' + where.join(' AND ') : '') +
    ' ORDER BY name';
  const stmt = workoutDB(db).prepare(sql);
  const bound = binds.length === 0 ? stmt : stmt.bind(...binds);
  const r = await bound.all<{
    id: string;
    name: string;
    primary_muscle: string;
    modality: string;
    unit: string;
    laterality: string;
    load_mode: string;
    demo_slug: string | null;
  }>();
  return r.results;
}

/** Resolve an id, exact name, or alias to an exercise row. */
export async function resolveExercise(db: D1Database, nameOrId: string) {
  const q = nameOrId.trim().toLowerCase();
  return workoutDB(db)
    .prepare(
      'SELECT * FROM exercises WHERE id = ?1 OR lower(name) = ?2 OR lower(aliases) LIKE ?3 LIMIT 1',
    )
    .bind(nameOrId, q, `%"${q}"%`)
    .first();
}

// ---- sessions + sets -----------------------------------------------------

export async function getOrCreateSession(
  db: D1Database,
  userId: string,
  planId: string,
  date: string,
  workoutId: string | null,
  options: {
    reviveDiscarded?: boolean;
    expectedAttempt?: number;
    /** Only an explicitly capability-declaring REST client may claim v1.
     * Internal/MCP callers still carry an attempt CAS but preserve the row's
     * current protocol so the released tokenless app remains compatible. */
    claimAttemptProtocol?: boolean;
  } = {},
): Promise<SessionRow> {
  const claimAttemptProtocol = options.claimAttemptProtocol === true;
  const attemptScoped = options.expectedAttempt !== undefined;
  if (claimAttemptProtocol && !attemptScoped) {
    throw new Error('session_expected_attempt_missing');
  }
  const selectExisting = () =>
    workoutDB(db)
      .prepare(
        'SELECT * FROM sessions WHERE user_id = ?1 AND date = ?2 ORDER BY created_at, id LIMIT 1',
      )
      .bind(userId, date)
      .first<SessionRow>();

  // Keep all existing-row behavior in one path. A writer that loses the
  // conflict-safe INSERT below must behave exactly like a caller that found
  // the winning row on its initial read: it may fill an unpinned explicit day
  // (first writer wins), and it may revive a discarded session.
  const useExisting = async (existing: SessionRow): Promise<SessionRow> => {
    // A tokenless legacy resolver may operate only until an attempt-aware
    // writer claims this generation. Returning the row unchanged lets the
    // route surface a stable protocol conflict without reviving or pinning it.
    if (!attemptScoped && existing.write_protocol !== 'legacy') return existing;
    // A write-scoped resolver must not mutate a later generation before its
    // caller can report the conflict. This guard precedes both revival and the
    // optional day-template backfill below.
    if (
      options.expectedAttempt !== undefined &&
      existing.attempt !== options.expectedAttempt
    ) {
      return existing;
    }
    if (existing.status === 'discarded') {
      if (options.reviveDiscarded === false) return existing;
      // The (user,date) row exists but was DISCARDED. "Discarded" means
      // "this never happened" — so a fresh get/start for the same date must
      // RESURRECT it to a clean planned state rather than hand back the
      // tombstone (which would leave the day un-startable: the start path
      // only promotes 'planned'→'in_progress'). We keep the same row id
      // (the (user,date) idempotency key) but wipe it back to pristine. Its
      // old set_logs stay soft-deleted (they belong to the thrown-away
      // attempt); new work logs fresh rows.
      const ts = now();
      const revived: SessionRow = {
        ...existing,
        workout_id: workoutId,
        status: 'planned',
        started_at: null,
        completed_at: null,
        perceived_fatigue: null,
        notes: null,
        runner_targets: null,
        updated_at: ts,
        attempt: existing.attempt + 1,
        write_protocol: claimAttemptProtocol
          ? 'attempt-v1'
          : existing.write_protocol,
      };
      const updated = await runWorkoutWriteStatement(
        db,
        workoutDB(db).prepare(
          `UPDATE sessions
              SET workout_id=?2,
                  runner_targets=NULL,
                  status=?3,
                  started_at=?4,
                  completed_at=?5,
                  perceived_fatigue=?6,
                  notes=?7,
                  updated_at=?8,
                  attempt=?9,
                  write_protocol=CASE
                    WHEN ?11 = 1 THEN 'attempt-v1'
                    ELSE write_protocol
                  END
            WHERE id=?1
              AND status='discarded'
              AND attempt=?10
              AND (?12 = 1 OR write_protocol = 'legacy')`,
        )
        .bind(
          revived.id,
          revived.workout_id,
          revived.status,
          null,
          null,
          null,
          null,
          ts,
          revived.attempt,
          existing.attempt,
          claimAttemptProtocol ? 1 : 0,
          attemptScoped ? 1 : 0,
        ),
      );
      if (updated.meta.changes > 0) return revived;

      // A competing explicit restart or another resolver advanced the reused
      // row after our read. Adopt that winner without applying this stale
      // resolver's day pin or pristine-state reset to the newer generation.
      const winner = await workoutDB(db)
        .prepare('SELECT * FROM sessions WHERE id = ?1')
        .bind(existing.id)
        .first<SessionRow>();
      return winner ?? existing;
    }

    // #926: honor an EXPLICITLY-provided workout_id on a row that
    // doesn't have one yet. Most creators (GET /today, MCP log_set,
    // logWorkoutComplete) pass null and let the weekly schedule resolve the
    // template at display time — that's the "calendar is computed, not
    // stored" design, so we must NOT auto-resolve from the schedule here
    // (that would freeze a stale template if the schedule later changes).
    // But when a caller (POST /api/sessions / iOS createSession) explicitly
    // says "this date is day X", silently dropping it on an existing
    // null-template row is the Today/session impedance mismatch the iOS UX
    // had to paper over. Backfill ONLY a NULL slot; never clobber an
    // existing pin.
    const shouldPin = workoutId != null && existing.workout_id == null;
    const shouldClaim =
      claimAttemptProtocol && existing.write_protocol !== 'attempt-v1';
    if (shouldPin || shouldClaim) {
      const ts = now();
      // The conditional SET guards a read-then-write race: two explicit POSTs
      // for the same null-template date can both read workout_id == null,
      // but only the first execution sees NULL and installs its pin. Keep the
      // row eligible after another writer pins it so this request can still
      // perform its independent explicit protocol claim without clobbering the
      // winning day. (Codex P2 on #58.)
      const res = await runWorkoutWriteStatement(
        db,
        workoutDB(db).prepare(
          `UPDATE sessions
              SET workout_id = CASE
                    WHEN ?5 = 1 AND workout_id IS NULL THEN ?2
                    ELSE workout_id
                  END,
                  write_protocol = CASE
                    WHEN ?6 = 1 THEN 'attempt-v1'
                    ELSE write_protocol
                  END,
                  updated_at = ?3
            WHERE id = ?1
              AND attempt = ?4
              AND status = ?7
              AND (?8 = 1 OR write_protocol = 'legacy')`,
        )
        .bind(
          existing.id,
          workoutId,
          ts,
          existing.attempt,
          shouldPin ? 1 : 0,
          claimAttemptProtocol ? 1 : 0,
          existing.status,
          attemptScoped ? 1 : 0,
        ),
      );
      // Always return the authoritative row. A terminal transition can land
      // immediately after the guarded update; synthesizing from `existing`
      // would acknowledge stale planned/live state. A zero-change result is
      // likewise a normal CAS loss (pin, status, generation, or protocol).
      const fresh = await workoutDB(db)
        .prepare('SELECT * FROM sessions WHERE id = ?1')
        .bind(existing.id)
        .first<SessionRow>();
      return fresh ?? existing;
    }
    return existing;
  };

  const existing = await selectExisting();
  if (existing) return useExisting(existing);

  // A nonzero token asserts that a prior generation already exists. Never
  // manufacture attempt zero and then reject the response: that phantom row
  // would still change calendar/state projections.
  if (options.expectedAttempt !== undefined && options.expectedAttempt !== 0) {
    throw new Error('session_expected_attempt_missing');
  }

  const ts = now();
  const s: SessionRow = {
    id: uuid(),
    user_id: userId,
    plan_id: planId,
    workout_id: workoutId,
    date,
    status: 'planned',
    started_at: null,
    completed_at: null,
    perceived_fatigue: null,
    notes: null,
    created_at: ts,
    updated_at: ts,
    attempt: 0,
    write_protocol: claimAttemptProtocol ? 'attempt-v1' : 'legacy',
  };
  const inserted = await runWorkoutWriteStatement(
    db,
    workoutDB(db).prepare(
      `INSERT INTO sessions
       (id,user_id,plan_id,workout_id,date,status,started_at,completed_at,perceived_fatigue,notes,created_at,updated_at,attempt,write_protocol)
       VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14)
       ON CONFLICT(user_id,date) DO NOTHING`,
    )
    .bind(
      s.id,
      s.user_id,
      s.plan_id,
      s.workout_id,
      s.date,
      s.status,
      s.started_at,
      s.completed_at,
      s.perceived_fatigue,
      s.notes,
      s.created_at,
      s.updated_at,
      s.attempt,
      s.write_protocol,
    ),
  );
  if (inserted.meta.changes > 0) return s;

  // Another creator won after our null read. Do not inspect or parse an
  // engine-specific unique-constraint error: the unique index plus
  // ON CONFLICT makes the outcome explicit, and we re-read the canonical
  // row before applying the same explicit-pin/discarded-revival rules above.
  const winner = await selectExisting();
  if (!winner) throw new Error('session_create_conflict_without_winner');
  return useExisting(winner);
}

/** Read the canonical date row without revival, pin backfill, or creation. */
export async function getOwnedSessionByDate(
  db: D1Database,
  userId: string,
  date: string,
): Promise<SessionRow | null> {
  return workoutDB(db)
    .prepare(
      'SELECT * FROM sessions WHERE user_id = ?1 AND date = ?2 ORDER BY created_at, id LIMIT 1',
    )
    .bind(userId, date)
    .first<SessionRow>();
}

/**
 * Explicitly revive one discarded session generation. This is deliberately
 * separate from ordinary date-level session resolution: a delayed pre-discard
 * create must never look like a user-authorized restart. The expected attempt
 * makes the operation idempotent across a commit-then-timeout retry while
 * preventing that retry from reviving a later discarded generation.
 */
export async function reviveDiscardedSession(
  db: D1Database,
  userId: string,
  sessionId: string,
  expectedAttempt: number,
  workoutId: string | null,
  claimAttemptProtocol = false,
): Promise<SessionRow | SessionAttemptConflict | null> {
  const canonicalSessionId = await resolveOwnedSessionId(db, userId, sessionId);
  if (!canonicalSessionId) return null;
  const readCurrent = () =>
    workoutDB(db)
      .prepare('SELECT * FROM sessions WHERE id = ?1 AND user_id = ?2')
      .bind(canonicalSessionId, userId)
      .first<SessionRow>();
  const current = await readCurrent();
  if (!current) return null;

  const acceptLiveWinner = async (
    candidate: SessionRow,
  ): Promise<SessionRow | SessionAttemptConflict | null> => {
    const revivedAttempt = expectedAttempt + 1;
    if (
      candidate.status === 'discarded' ||
      candidate.attempt !== revivedAttempt
    ) {
      return sessionAttemptConflict(expectedAttempt, candidate);
    }
    if (!claimAttemptProtocol || candidate.write_protocol === 'attempt-v1') {
      return candidate;
    }
    await runWorkoutWriteStatement(
      db,
      workoutDB(db).prepare(
        `UPDATE sessions
            SET write_protocol = 'attempt-v1'
          WHERE id = ?1
            AND user_id = ?2
            AND attempt = ?3
            AND status = ?4
            AND write_protocol = 'legacy'`,
      )
      .bind(
        canonicalSessionId,
        userId,
        revivedAttempt,
        candidate.status,
      ),
    );
    const authoritative = await readCurrent();
    if (!authoritative) return null;
    if (
      authoritative.status === 'discarded' ||
      authoritative.attempt !== revivedAttempt ||
      authoritative.write_protocol !== 'attempt-v1'
    ) {
      return sessionAttemptConflict(expectedAttempt, authoritative);
    }
    return authoritative;
  };

  // A retry after the original restart committed observes exactly the next
  // live generation. Return it as the idempotent result; do not increment it
  // again. Any later generation is a real conflict.
  if (current.status !== 'discarded') {
    if (current.attempt === expectedAttempt + 1) {
      return acceptLiveWinner(current);
    }
    return sessionAttemptConflict(expectedAttempt, current);
  }
  if (current.attempt !== expectedAttempt) {
    return sessionAttemptConflict(expectedAttempt, current);
  }

  const ts = now();
  const revivedAttempt = expectedAttempt + 1;
  const updated = await runWorkoutWriteStatement(
    db,
    workoutDB(db).prepare(
      `UPDATE sessions
          SET workout_id = ?2,
              status = 'planned',
              runner_targets = NULL,
              started_at = NULL,
              completed_at = NULL,
              perceived_fatigue = NULL,
              notes = NULL,
              updated_at = ?3,
              attempt = ?4,
              write_protocol = CASE
                WHEN ?7 = 1 THEN 'attempt-v1'
                ELSE write_protocol
              END
        WHERE id = ?1
          AND user_id = ?5
          AND status = 'discarded'
          AND attempt = ?6`,
    )
    .bind(
      canonicalSessionId,
      workoutId,
      ts,
      revivedAttempt,
      userId,
      expectedAttempt,
      claimAttemptProtocol ? 1 : 0,
    ),
  );
  // Reread even after a successful CAS. A same-attempt discard can commit
  // immediately after the restart/claim; returning a synthesized planned row
  // would install an obsolete client barrier.
  const winner = await readCurrent();
  if (!winner) return null;
  if (winner.status !== 'discarded' && winner.attempt === revivedAttempt) {
    return acceptLiveWinner(winner);
  }
  return sessionAttemptConflict(expectedAttempt, winner);
}

/**
 * Resolve a session mutation target for one user. Direct session ids take
 * precedence; otherwise a stale id retained by migration 0029 may redirect to
 * its surviving canonical row. Joining through sessions keeps both paths
 * tenant-scoped and ensures an alias can never grant access to another user's
 * session.
 */
async function resolveOwnedSessionId(
  db: D1Database,
  userId: string,
  requestedId: string,
): Promise<string | null> {
  const resolved = await workoutDB(db)
    .prepare(
      `SELECT s.id
         FROM sessions AS s
         LEFT JOIN session_aliases AS sa
           ON sa.canonical_session_id = s.id
          AND sa.alias_session_id = ?1
        WHERE s.user_id = ?2
          AND (s.id = ?1 OR sa.alias_session_id = ?1)
        ORDER BY CASE WHEN s.id = ?1 THEN 0 ELSE 1 END
        LIMIT 1`,
    )
    .bind(requestedId, userId)
    .first<{ id: string }>();
  return resolved?.id ?? null;
}

export type SessionAttemptConflict = {
  error: 'session_attempt_conflict';
  status: SessionRow['status'];
  expected_attempt: number;
  current_attempt: number;
  current_session: SessionRow;
};

export type SessionAttemptMissing = {
  error: 'session_attempt_missing';
  expected_attempt: number;
};

export type SessionStateConflict = {
  error: 'session_state_conflict';
  expected_status?: SessionRow['status'];
  current_session: SessionRow;
};

export type SessionProtocolConflict = {
  error: 'session_attempt_required';
  status: SessionRow['status'];
  current_attempt: number;
  current_session: SessionRow;
};

function sessionAttemptConflict(
  expectedAttempt: number,
  current: SessionRow,
): SessionAttemptConflict {
  return {
    error: 'session_attempt_conflict',
    status: current.status,
    expected_attempt: expectedAttempt,
    current_attempt: current.attempt,
    current_session: current,
  };
}

function sessionStateConflict(
  expectedStatus: SessionRow['status'],
  current: SessionRow,
): SessionStateConflict {
  return {
    error: 'session_state_conflict',
    expected_status: expectedStatus,
    current_session: current,
  };
}

function sessionProtocolConflict(current: SessionRow): SessionProtocolConflict {
  return {
    error: 'session_attempt_required',
    status: current.status,
    current_attempt: current.attempt,
    current_session: current,
  };
}

export class SessionWriteConflictError extends Error {
  readonly currentSession: SessionRow;
  readonly expectedAttempt?: number;
  readonly expectedStatus?: SessionRow['status'];

  constructor(
    error:
      | 'session_attempt_conflict'
      | 'session_attempt_required'
      | 'session_discarded'
      | 'session_state_conflict',
    currentSession: SessionRow,
    expectedAttempt?: number,
    expectedStatus?: SessionRow['status'],
  ) {
    super(error);
    this.name = 'SessionWriteConflictError';
    this.currentSession = currentSession;
    this.expectedAttempt = expectedAttempt;
    this.expectedStatus = expectedStatus;
  }

  response():
    | SessionAttemptConflict
    | SessionProtocolConflict
    | SessionStateConflict
    | { error: 'session_discarded'; status: 'discarded'; current_session: SessionRow } {
    if (this.message === 'session_attempt_conflict' && this.expectedAttempt !== undefined) {
      return sessionAttemptConflict(this.expectedAttempt, this.currentSession);
    }
    if (this.message === 'session_attempt_required') {
      return sessionProtocolConflict(this.currentSession);
    }
    if (this.message === 'session_state_conflict') {
      return {
        error: 'session_state_conflict',
        ...(this.expectedStatus === undefined
          ? {}
          : { expected_status: this.expectedStatus }),
        current_session: this.currentSession,
      };
    }
    return {
      error: 'session_discarded',
      status: 'discarded',
      current_session: this.currentSession,
    };
  }
}

export async function patchSession(
  db: D1Database,
  userId: string,
  sessionId: string,
  // `status` is `unknown`: the PATCH body is NOT runtime-validated, so a
  // client can send a number/null/bool/object/array here. Typing it
  // honestly forces the type-guard below.
  patch: {
    status?: unknown;
    perceived_fatigue?: number | null;
    notes?: string | null;
    expected_feedback?: { notes: string | null; perceived_fatigue: number | null };
    workout_id?: string | null;
  },
  expectedAttempt?: number,
  claimAttemptProtocol = false,
): Promise<
  | SessionRow
  | null
  | { error: 'session_already_started'; status: 'in_progress' | 'completed' }
  | {
      error: 'session_discarded';
      status: 'discarded';
      current_session: SessionRow;
    }
  | { error: 'session_feedback_conflict'; current_session: SessionRow }
  | { error: 'invalid_status'; status: unknown }
  | SessionAttemptConflict
  | SessionProtocolConflict
  | SessionStateConflict
> {
  const canonicalSessionId = await resolveOwnedSessionId(db, userId, sessionId);
  if (!canonicalSessionId) return null;
  const s = await workoutDB(db)
    .prepare('SELECT * FROM sessions WHERE id = ?1 AND user_id = ?2')
    .bind(canonicalSessionId, userId)
    .first<SessionRow>();
  if (!s) return null;
  const attemptScoped = expectedAttempt !== undefined;
  if (claimAttemptProtocol && !attemptScoped) {
    throw new Error('session_expected_attempt_missing');
  }
  if (!attemptScoped && s.write_protocol !== 'legacy') {
    return sessionProtocolConflict(s);
  }
  if (expectedAttempt !== undefined && expectedAttempt !== s.attempt) {
    return sessionAttemptConflict(expectedAttempt, s);
  }
  const casAttempt = expectedAttempt ?? s.attempt;
  // Type-guard BEFORE normalizing: a present-but-non-string `status`
  // (e.g. {"status":123|null|true|{}|[]}) must be treated exactly like an
  // invalid status — return the invalid_status arm (→ HTTP 400), never
  // call .trim() on a non-string (that was a 500-causing regression),
  // never persist, never reach the burial guard. Key absent / undefined
  // → field-only patch, unchanged. Only a string proceeds to normalize.
  if (patch.status !== undefined && typeof patch.status !== 'string') {
    return { error: 'invalid_status', status: patch.status };
  }
  // Normalize the incoming status ONCE (trim + lowercase) so casing /
  // whitespace cannot bypass the skipped-guard ({"status":"  SKIPPED "})
  // and so the value compared here is the value persisted below — a
  // non-canonical status can never silently corrupt the row.
  const normalizedStatus =
    patch.status === undefined ? undefined : patch.status.trim().toLowerCase();
  // Validate against the closed status set BEFORE the burial guard and
  // BEFORE any write: an unknown status (e.g. "junk") is rejected, never
  // persisted. A field-only patch (no `status` key) skips this entirely.
  // This is app-layer validation (no DB CHECK / migration) and is what
  // makes the "can never silently corrupt the row" guarantee true.
  if (
    normalizedStatus !== undefined &&
    normalizedStatus !== 'planned' &&
    normalizedStatus !== 'in_progress' &&
    normalizedStatus !== 'completed' &&
    normalizedStatus !== 'skipped'
  ) {
    return { error: 'invalid_status', status: normalizedStatus };
  }
  // Discard is terminal for mutations that still address this session id.
  // A deliberate same-day restart goes through getOrCreateSession, which
  // first revives the row to a fresh `planned` attempt. Keeping that explicit
  // boundary prevents a delayed completion/status PATCH from silently
  // resurrecting the attempt the user just threw away.
  if (s.status === 'discarded') {
    return {
      error: 'session_discarded',
      status: 'discarded',
      current_session: s,
    };
  }
  // History-integrity guard (REST sibling of FIX2's skipPlannedSession
  // guard): a `skipped` patch must not bury a started/finished workout.
  // Setting an in_progress/completed session to 'skipped' would render it
  // skipped on the calendar/agenda and hide its logged set_logs. Reject
  // and leave the row + its sets untouched — same rejection shape as
  // skipPlannedSession. Other status transitions and non-status patches
  // are unchanged.
  if (
    normalizedStatus === 'skipped' &&
    (s.status === 'in_progress' || s.status === 'completed')
  ) {
    return {
      error: 'session_already_started',
      status: s.status as 'in_progress' | 'completed',
    };
  }
  const ts = now();
  const status = normalizedStatus ?? s.status;
  const fatigue = Object.prototype.hasOwnProperty.call(patch, 'perceived_fatigue')
    ? patch.perceived_fatigue ?? null : s.perceived_fatigue;
  const notes = Object.prototype.hasOwnProperty.call(patch, 'notes')
    ? patch.notes ?? null : s.notes;
  const completedAt = status === 'completed' ? s.completed_at ?? ts : s.completed_at;
  const startedAt = status === 'in_progress' ? s.started_at ?? ts : s.started_at;
  const statusPredicate =
    normalizedStatus === 'completed'
      ? "status IN ('planned','in_progress','completed')"
      : normalizedStatus === 'in_progress'
        ? "status IN ('planned','in_progress')"
        : normalizedStatus === 'skipped'
          ? "status IN ('planned','skipped')"
          : normalizedStatus === 'planned'
            ? "status IN ('planned','skipped')"
            : "status != 'discarded'";
  // Feedback CAS compares the original private fields, independently of set
  // writes that also advance sessions.updated_at. An exact retry is accepted;
  // a newer different note/rating is never overwritten by a delayed finish.
  // Attempt plus a transition-specific current-state predicate form the
  // read/write CAS. Completion is allowed to linearize on either side of a
  // final logSet in the same generation, and SQL COALESCE preserves the
  // concurrently installed started_at. Skip/planned transitions are stricter:
  // once a set promoted the row, they cannot hide or demote the live workout.
  const [updated] = await runWorkoutWriteBatch(db, [
    workoutDB(db).prepare(
      `UPDATE sessions
          SET status = CASE WHEN ?8 = 1 THEN ?2 ELSE status END,
              perceived_fatigue = CASE
                WHEN ?2 = 'planned' AND status = 'skipped' THEN NULL
                WHEN ?10 = 1 THEN ?3
                ELSE perceived_fatigue
              END,
              notes = CASE
                WHEN ?2 = 'planned' AND status = 'skipped' THEN NULL
                WHEN ?11 = 1 THEN ?4
                ELSE notes
              END,
              started_at = CASE
                WHEN ?2 = 'planned' AND status = 'skipped' THEN NULL
                WHEN ?2 = 'in_progress' THEN COALESCE(started_at, ?5)
                ELSE started_at
              END,
              runner_targets = CASE
                WHEN ?2 = 'planned' AND status = 'skipped' THEN NULL
                WHEN ?2 = 'completed' AND runner_targets IS NULL AND started_at IS NULL
                  THEN ${runnerTargetSnapshotSQL('sessions.workout_id', '?7')}
                ELSE runner_targets
              END,
              completed_at = CASE
                WHEN ?2 = 'planned' AND status = 'skipped' THEN NULL
                WHEN ?2 = 'completed' THEN COALESCE(completed_at, ?6)
                ELSE completed_at
              END,
              attempt = CASE
                WHEN ?2 = 'planned' AND status = 'skipped' THEN attempt + 1
                ELSE attempt
              END,
              workout_id = CASE
                WHEN ?12 = 1 THEN ?13
                ELSE workout_id
              END,
              write_protocol = CASE
                WHEN ?14 = 1 THEN 'attempt-v1'
                ELSE write_protocol
              END,
              updated_at = ?7
        WHERE id = ?1
          AND attempt = ?9
          AND (?15 = 1 OR write_protocol = 'legacy')
          AND ${statusPredicate}
          AND (?16 = 0
            OR (notes IS ?17 AND perceived_fatigue IS ?18)
            OR (notes IS ?4 AND perceived_fatigue IS ?3))`,
    )
    .bind(
      canonicalSessionId,
      normalizedStatus ?? '',
      fatigue,
      notes,
      startedAt,
      completedAt,
      ts,
      normalizedStatus === undefined ? 0 : 1,
      casAttempt,
      Object.prototype.hasOwnProperty.call(patch, 'perceived_fatigue') ? 1 : 0,
      Object.prototype.hasOwnProperty.call(patch, 'notes') ? 1 : 0,
      normalizedStatus === 'planned' &&
      Object.prototype.hasOwnProperty.call(patch, 'workout_id')
        ? 1
        : 0,
      patch.workout_id ?? null,
      claimAttemptProtocol ? 1 : 0,
      attemptScoped ? 1 : 0,
      patch.expected_feedback ? 1 : 0,
      patch.expected_feedback?.notes ?? null,
      patch.expected_feedback?.perceived_fatigue ?? null,
    ),
    reconcileNativeHealthKitStatement(db, userId, ts, true),
  ]);
  if (updated!.meta.changes === 0) {
    const current = await workoutDB(db)
      .prepare('SELECT * FROM sessions WHERE id = ?1 AND user_id = ?2')
      .bind(canonicalSessionId, userId)
      .first<SessionRow>();
    if (current && !attemptScoped && current.write_protocol !== 'legacy') {
      return sessionProtocolConflict(current);
    }
    if (current && current.attempt !== casAttempt) {
      return sessionAttemptConflict(casAttempt, current);
    }
    if (current?.status === 'discarded') {
      return {
        error: 'session_discarded',
        status: 'discarded',
        current_session: current,
      };
    }
    if (
      normalizedStatus === 'skipped' &&
      current &&
      (current.status === 'in_progress' || current.status === 'completed')
    ) {
      return {
        error: 'session_already_started',
        status: current.status,
      };
    }
    if (current && patch.expected_feedback
        && !(current.notes === patch.expected_feedback.notes
          && current.perceived_fatigue === patch.expected_feedback.perceived_fatigue)
        && !(current.notes === notes && current.perceived_fatigue === fatigue)) {
      return { error: 'session_feedback_conflict', current_session: current };
    }
    if (current) return sessionStateConflict(s.status, current);
    return null;
  }
  return workoutDB(db)
    .prepare('SELECT * FROM sessions WHERE id = ?1 AND user_id = ?2')
    .bind(canonicalSessionId, userId)
    .first<SessionRow>();
}

/**
 * Discard a session — the sanctioned escape hatch for "I started/ended a
 * workout I didn't really do." This is the ONE place allowed to override
 * the history-integrity burial guard in patchSession/skipPlannedSession,
 * and it earns that by being EXPLICIT and non-silent: it soft-deletes the
 * session's set_logs (so logged work is intentionally thrown away, never
 * hidden) and marks the session 'discarded'. A discarded session VANISHES
 * from the calendar projection (see projectCalendar's discarded carve-out)
 * and its now-soft-deleted sets drop out of history/volume/e1RM (those
 * already filter deleted_at IS NULL) and out of ride-conflict lift dates
 * (derived from the projection). The only session-row reads needing an
 * explicit `status != 'discarded'` filter are getRecentSessions and
 * getSessionByDate (the MCP coach reads) — both already carry it.
 *
 * Idempotent AND side-effect-free on repeat: an already-discarded session
 * short-circuits before any write (no redundant audit row). Reversible-
 * by-restart:
 * getOrCreateSession resurrects a discarded (user,date) row to a pristine
 * 'planned' state, so discarding never wedges a date.
 *
 * Returns null if no such session for this user (caller → 404).
 */
export async function discardSession(
  db: D1Database,
  userId: string,
  sessionId: string,
  expectedAttempt?: number,
  claimAttemptProtocol = false,
): Promise<
  | SessionRow
  | SessionAttemptConflict
  | SessionProtocolConflict
  | null
> {
  const canonicalSessionId = await resolveOwnedSessionId(db, userId, sessionId);
  if (!canonicalSessionId) return null;
  const s = await workoutDB(db)
    .prepare('SELECT * FROM sessions WHERE id = ?1 AND user_id = ?2')
    .bind(canonicalSessionId, userId)
    .first<SessionRow>();
  if (!s) return null;
  const attemptScoped = expectedAttempt !== undefined;
  if (claimAttemptProtocol && !attemptScoped) {
    throw new Error('session_expected_attempt_missing');
  }
  if (!attemptScoped && s.write_protocol !== 'legacy') {
    return sessionProtocolConflict(s);
  }
  if (expectedAttempt !== undefined && expectedAttempt !== s.attempt) {
    return sessionAttemptConflict(expectedAttempt, s);
  }
  const casAttempt = expectedAttempt ?? s.attempt;
  const acceptDiscardedWinner = async (
    candidate: SessionRow,
  ): Promise<SessionRow | SessionAttemptConflict | null> => {
    if (candidate.attempt !== casAttempt || candidate.status !== 'discarded') {
      return sessionAttemptConflict(casAttempt, candidate);
    }
    if (!claimAttemptProtocol || candidate.write_protocol === 'attempt-v1') {
      return candidate;
    }
    await runWorkoutWriteStatement(
      db,
      workoutDB(db).prepare(
        `UPDATE sessions
            SET write_protocol = 'attempt-v1'
          WHERE id = ?1
            AND user_id = ?2
            AND attempt = ?3
            AND status = 'discarded'
            AND write_protocol = 'legacy'`,
      )
      .bind(canonicalSessionId, userId, casAttempt),
    );
    const authoritative = await workoutDB(db)
      .prepare('SELECT * FROM sessions WHERE id = ?1 AND user_id = ?2')
      .bind(canonicalSessionId, userId)
      .first<SessionRow>();
    if (!authoritative) return null;
    if (
      authoritative.attempt !== casAttempt ||
      authoritative.status !== 'discarded' ||
      authoritative.write_protocol !== 'attempt-v1'
    ) {
      return sessionAttemptConflict(casAttempt, authoritative);
    }
    return authoritative;
  };
  // Already discarded: skip the terminal/tombstone batch and its audit so a
  // retry cannot inflate coaching history. An explicit iOS capability claim
  // may still perform the one guarded legacy→v1 protocol update.
  if (s.status === 'discarded') {
    return acceptDiscardedWinner(s);
  }
  const ts = now();
  // D1 batches are ordered transactions. Mark the session terminal first,
  // then tombstone every live set in the same transaction. A concurrent
  // logSet batch therefore linearizes wholly on one side: if it wins first,
  // its new set is included in this tombstone; if discard wins first, its
  // status-guarded insert observes `discarded` and is rejected.
  const [transition, , tombstones, terminalState] = await runWorkoutWriteBatch(db, [
    workoutDB(db)
      .prepare(
        `UPDATE sessions
            SET status = 'discarded',
                updated_at = ?2,
                write_protocol = CASE
                  WHEN ?4 = 1 THEN 'attempt-v1'
                  ELSE write_protocol
                END
          WHERE id = ?1
            AND status != 'discarded'
            AND attempt = ?3
            AND (?5 = 1 OR write_protocol = 'legacy')`,
      )
      .bind(
        canonicalSessionId,
        ts,
        casAttempt,
        claimAttemptProtocol ? 1 : 0,
        attemptScoped ? 1 : 0,
      ),
    reconcileNativeHealthKitStatement(db, userId, ts, true),
    workoutDB(db)
      .prepare(
        `UPDATE set_logs
            SET deleted_at = ?2,
                updated_at = MAX(updated_at + 1, ?2)
          WHERE session_id = ?1
            AND deleted_at IS NULL
            AND EXISTS (
              SELECT 1 FROM sessions
               WHERE id = ?1 AND status = 'discarded' AND attempt = ?3
            )
          RETURNING id`,
      )
      .bind(canonicalSessionId, ts, casAttempt),
    workoutDB(db)
      .prepare('SELECT * FROM sessions WHERE id = ?1 AND user_id = ?2')
      .bind(canonicalSessionId, userId),
  ]);
  const authoritative = terminalState!.results[0] as SessionRow | undefined;
  // Another concurrent/retried discard already won. Its transaction also
  // tombstoned the live sets, so this remains a true audit no-op. Return the
  // terminal result observed by this batch. If an explicit iOS caller still
  // needs to claim a legacy winner, acceptDiscardedWinner performs one guarded
  // claim and authoritative reread; a same-day restart that wins that race is
  // returned as a conflict rather than a misleading discarded ACK.
  if (transition!.meta.changes === 0) {
    const current = authoritative;
    if (current && !attemptScoped && current.write_protocol !== 'legacy') {
      return sessionProtocolConflict(current);
    }
    if (current && current.attempt !== casAttempt) {
      return sessionAttemptConflict(casAttempt, current);
    }
    if (current?.status === 'discarded') {
      return acceptDiscardedWinner(current);
    }
    if (current) return sessionAttemptConflict(casAttempt, current);
    return null;
  }
  // Count the outer statement's authoritative returned rows. D1 meta.changes
  // also includes writes performed by compatibility triggers, so it is not a
  // logical row count while migration 0034's legacy-update trigger exists.
  const discardedSets = tombstones!.results.length;
  await writeAudit(
    db,
    userId,
    'discard_session',
    {
      session_id: canonicalSessionId,
      date: s.date,
      attempt: casAttempt,
      prior_status: s.status,
      sets_discarded: discardedSets,
    },
    `discarded:${discardedSets}_sets`,
  );
  return authoritative ?? {
    ...s,
    status: 'discarded',
    updated_at: ts,
    write_protocol: claimAttemptProtocol ? 'attempt-v1' : s.write_protocol,
  };
}

/** Idempotent on the client-generated `id` (offline-safe; retries are no-ops). */
export async function logSet(
  db: D1Database,
  userId: string,
  input: {
    id: string;
    session_id: string;
    exercise_id: string;
    template_exercise_id?: string | null;
    set_index: number;
    weight: number;
    reps: number;
    rpe?: number | null;
    is_warmup?: boolean;
    notes?: string | null;
    logged_at?: number;
    duration_s?: number | null;
    /** Explicit timed-hold flag. When omitted, defaults to the exercise's
     *  catalog modality (=== 'timed'). A client that rendered a timed
     *  countdown (e.g. a target_duration_s slot) passes true so the set is
     *  stored as timed regardless of modality. */
    is_timed?: boolean;
    /** Optional generation CAS. New durable clients persist and reuse it;
     *  omitted legacy/MCP calls still snapshot the pre-write attempt below. */
    expected_attempt?: number;
    /** Capability declaration is separate from generation CAS. MCP supplies
     * an observed attempt but never claims the client protocol. */
    claim_attempt_protocol?: boolean;
    prescription?: SetPrescriptionContext;
    source: 'ios' | 'mcp';
  },
): Promise<{ set: SetLogRow; deduped: boolean; session: SessionRow }> {
  // Guard + migration compatibility: the requested id must resolve to this
  // user's direct or canonical session. Every operation below uses that
  // canonical id so a stale client heals from the returned SetLogRow.
  const canonicalSessionId = await resolveOwnedSessionId(db, userId, input.session_id);
  if (!canonicalSessionId) throw new Error('session_not_found');

  // A set UUID is idempotent only within the resolved owned session. Never
  // return a globally-matched row from another session/tenant, even if a
  // caller happens to know its UUID.
  const selectExisting = () =>
    workoutDB(db)
      .prepare(
        `SELECT sl.*
           FROM set_logs AS sl
           JOIN sessions AS s ON s.id = sl.session_id
          WHERE sl.id = ?1 AND sl.session_id = ?2 AND s.user_id = ?3`,
      )
      .bind(input.id, canonicalSessionId, userId);
  const selectSession = () =>
    workoutDB(db)
      .prepare('SELECT * FROM sessions WHERE id = ?1 AND user_id = ?2')
      .bind(canonicalSessionId, userId);
  // Read the UUID winner and its authoritative session from one D1 snapshot.
  // A retry must never pair an old planned read with a set that won later.
  const [initialSetState, initialSessionState] = await workoutDB(db).batch([
    selectExisting(),
    selectSession(),
  ]);
  const targetSession = initialSessionState!.results[0] as SessionRow | undefined;
  if (!targetSession) throw new Error('session_not_found');
  // Exact UUID retries remain idempotent even after discard/restart. The
  // original mutation already happened, so this path settles the old intent
  // without applying anything to the current generation. Return the current
  // authoritative session alongside the (possibly tombstoned) old set.
  const existing = initialSetState!.results[0] as SetLogRow | undefined;
  if (existing) {
    return { set: existing, deduped: true, session: targetSession };
  }
  const attemptScoped = input.expected_attempt !== undefined;
  const claimAttemptProtocol = input.claim_attempt_protocol === true;
  if (claimAttemptProtocol && !attemptScoped) {
    throw new Error('session_expected_attempt_missing');
  }
  if (!attemptScoped && targetSession.write_protocol !== 'legacy') {
    throw new SessionWriteConflictError(
      'session_attempt_required',
      targetSession,
    );
  }
  if (
    input.expected_attempt !== undefined &&
    input.expected_attempt !== targetSession.attempt
  ) {
    throw new SessionWriteConflictError(
      'session_attempt_conflict',
      targetSession,
      input.expected_attempt,
    );
  }
  const casAttempt = input.expected_attempt ?? targetSession.attempt;
  if (targetSession.status === 'skipped') {
    throw new SessionWriteConflictError(
      'session_state_conflict',
      targetSession,
      undefined,
    );
  }

  // Resolve the plan slot (if a link was provided) ONCE — it drives both the
  // dangling-link guard and the warm-up default.
  //
  // Dangling-link guard: template_exercise_id is an enforced FK into
  // template_exercises. A stale client can send a slot id that a plan rebuild
  // (update_plan deletes + re-creates rows with new ids) has since removed —
  // a real edit/sync race during an in-flight workout. Inserting it unchanged
  // would 500 and BLOCK logging until the user reloads. Set logs key on
  // exercise_id anyway, so treat a missing slot as "no link": store
  // template_exercise_id = null (an exercise-only log) and keep the set.
  //
  // Stale-swap guard: the slot may still EXIST but now hold a different
  // exercise (a swap_exercise / update_exercise edit landed mid-workout while
  // iOS still cached the old slot id). Keeping the link would file this set's
  // movement under the swapped-in slot, and todaySlotSets attributes any
  // non-null slot id before checking exercise_id — silently marking the wrong
  // slot complete. So only retain the link when the slot's exercise_id matches
  // the submitted set; otherwise drop it like the dangling path. (Ownership is
  // already covered: the session is user-scoped above, and a foreign-day slot
  // never appears in today's slot set regardless.)
  //
  // Warm-up default: an explicit flag wins; otherwise inherit the slot's
  // is_warmup so a set logged against a prescribed warm-up slot (erg, mobility)
  // is correctly a warm-up without the client restating it (migration 0026).
  let templateExerciseId: string | null = input.template_exercise_id ?? null;
  let slotIsWarmup: number | null = null;
  if (templateExerciseId) {
    const slot = await workoutDB(db)
      .prepare(`SELECT te.is_warmup, te.exercise_id FROM template_exercises te
        JOIN workouts w ON w.id=te.workout_id JOIN plans p ON p.id=w.plan_id
        WHERE te.id=?1 AND p.user_id=?2`)
      .bind(templateExerciseId, userId)
      .first<{ is_warmup: number; exercise_id: string }>();
    const approvedSwap = parseSessionExerciseSwaps(targetSession.exercise_swaps, targetSession.attempt).entries.find(
      (entry) => entry.original.id === templateExerciseId
        && entry.original.exercise_id === slot?.exercise_id
        && entry.exercise_ids.includes(input.exercise_id));
    if (!slot || (slot.exercise_id !== input.exercise_id && !approvedSwap)) {
      templateExerciseId = null; // dangling or swapped slot → exercise-only log
    } else {
      slotIsWarmup = slot.is_warmup === 1 ? 1 : 0;
    }
  }

  let isWarmupInt: number;
  if (typeof input.is_warmup === 'boolean') {
    isWarmupInt = input.is_warmup ? 1 : 0;
  } else {
    isWarmupInt = slotIsWarmup ?? 0;
  }

  // Collision-safe set_index. MCP and iOS each compute set_index
  // independently, so two writers could pick the same index for the same
  // (session, exercise, is_warmup) — the bug that produced two set_index=3
  // squat sets. Renumber on collision: keep the provided index unless a live
  // row already holds it, in which case bump to max+1. The partial unique
  // index ux_set_slot (migration 0013) is the hard backstop for races.
  let setIndex = input.set_index;
  const clash = await workoutDB(db)
    .prepare(
      `SELECT 1 FROM set_logs
       WHERE session_id = ?1 AND exercise_id = ?2 AND set_index = ?3
         AND is_warmup = ?4 AND deleted_at IS NULL LIMIT 1`,
    )
    .bind(canonicalSessionId, input.exercise_id, setIndex, isWarmupInt)
    .first();
  if (clash) {
    const max = await workoutDB(db)
      .prepare(
        `SELECT COALESCE(MAX(set_index), 0) AS m FROM set_logs
         WHERE session_id = ?1 AND exercise_id = ?2 AND is_warmup = ?3
           AND deleted_at IS NULL`,
      )
      .bind(canonicalSessionId, input.exercise_id, isWarmupInt)
      .first<{ m: number }>();
    setIndex = (max?.m ?? 0) + 1;
  }

  // Timed-ness is stored per-set (never inferred from duration_s, which rep
  // sets carry incidentally): an explicit flag wins; otherwise default to the
  // exercise's catalog modality. Both 'timed' (planks/holds) and 'cardio'
  // (erg/treadmill, migration 0026) are duration-driven, so a caller that
  // omits is_timed while logging a cardio effort still stores it as timed.
  let isTimedInt: number;
  if (typeof input.is_timed === 'boolean') {
    isTimedInt = input.is_timed ? 1 : 0;
  } else {
    const exRow = await workoutDB(db)
      .prepare('SELECT modality FROM exercises WHERE id = ?1')
      .bind(input.exercise_id)
      .first<{ modality: string | null }>();
    isTimedInt = exRow?.modality === 'timed' || exRow?.modality === 'cardio' ? 1 : 0;
  }

  const setUpdatedAt = now();
  const row: SetLogRow = {
    id: input.id,
    user_id: userId,
    session_id: canonicalSessionId,
    exercise_id: input.exercise_id,
    template_exercise_id: templateExerciseId,
    set_index: setIndex,
    weight: input.weight,
    reps: input.reps,
    rpe: input.rpe ?? null,
    is_warmup: isWarmupInt,
    notes: input.notes ?? null,
    logged_at: input.logged_at ?? setUpdatedAt,
    updated_at: setUpdatedAt,
    source: input.source,
    duration_s: input.duration_s ?? null,
    is_timed: isTimedInt,
    deleted_at: null,
  };
  // The pre-check above resolves the common collision, but two concurrent
  // writers can both pass it and then race on the INSERT — only the unique
  // index ux_set_slot catches that. Honor the "renumber, don't reject"
  // contract: on a slot-unique violation, recompute max+1 and retry rather
  // than letting one writer's set be dropped. ON CONFLICT(id) DO NOTHING
  // still covers a concurrent same-id retry (idempotency).
  const recordedTargets = input.prescription && targetSession.runner_targets == null
    ? await targetsForSetPrescription(db, userId, input.prescription, row.logged_at) : null;
  const insertAndStart = () => {
    const ts = now();
    return runWorkoutWriteBatch(db, [
      workoutDB(db)
        .prepare(
          `INSERT INTO set_logs
           (id,session_id,exercise_id,template_exercise_id,set_index,weight,reps,rpe,is_warmup,notes,logged_at,source,duration_s,is_timed,deleted_at,user_id,updated_at)
           SELECT ?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,NULL,user_id,?17
             FROM sessions
            WHERE id = ?2
              AND user_id = ?18
              AND status != 'discarded'
              AND status != 'skipped'
              AND attempt = ?15
              AND (?16 = 1 OR write_protocol = 'legacy')
           ON CONFLICT(id) DO NOTHING`,
        )
        .bind(
          row.id, row.session_id, row.exercise_id, row.template_exercise_id, row.set_index,
          row.weight, row.reps, row.rpe, row.is_warmup, row.notes, row.logged_at, row.source,
          row.duration_s, row.is_timed, casAttempt, attemptScoped ? 1 : 0,
          row.updated_at, userId,
        ),
      // Claim/start only when this owned UUID now exists. Keeping the INSERT
      // first avoids mutating the session for a globally-colliding UUID, while
      // the enclosing D1 batch remains one atomic linearization point: no
      // legacy writer can slip between insertion and the protocol fence.
      workoutDB(db)
        .prepare(
          `UPDATE sessions
              SET status = CASE WHEN status = 'planned' THEN 'in_progress' ELSE status END,
                  runner_targets = CASE
                    WHEN runner_targets IS NULL AND started_at IS NULL AND status = 'planned'
                      THEN CASE WHEN ?8=1 THEN ?9 ELSE ${runnerTargetSnapshotSQL("COALESCE((SELECT workout_id FROM template_exercises WHERE id=?7), sessions.workout_id)", '?2')} END
                    ELSE runner_targets END,
                  started_at = COALESCE(started_at, ?2),
                  updated_at = ?2,
                  write_protocol = CASE
                    WHEN ?4 = 1 THEN 'attempt-v1'
                    ELSE write_protocol
                  END
            WHERE id = ?1
              AND status != 'discarded'
              AND status != 'skipped'
              AND attempt = ?3
              AND (?6 = 1 OR write_protocol = 'legacy')
              AND EXISTS (
                SELECT 1 FROM set_logs
                 WHERE id = ?5 AND session_id = ?1
              )`,
        )
        .bind(
          canonicalSessionId,
          ts,
          casAttempt,
          claimAttemptProtocol ? 1 : 0,
          row.id,
          attemptScoped ? 1 : 0,
          row.template_exercise_id,
          input.prescription ? 1 : 0,
          recordedTargets,
        ),
      // Capture both the target generation and the canonical current row at
      // the same linearization point. The latter gives a stable conflict body
      // when discard/restart moved the generation during this request.
      workoutDB(db)
        .prepare('SELECT * FROM sessions WHERE id = ?1 AND attempt = ?2')
        .bind(canonicalSessionId, casAttempt),
      workoutDB(db)
        .prepare('SELECT * FROM sessions WHERE id = ?1')
        .bind(canonicalSessionId),
      selectExisting(),
    ]);
  };
  for (let attempt = 0; ; attempt++) {
    try {
      const [inserted, started, sessionState, currentState, winnerState] =
        await insertAndStart();
      const sessionAtWrite = sessionState!.results[0] as SessionRow | undefined;
      const currentSession = currentState!.results[0] as SessionRow | undefined;
      const winner = winnerState!.results[0] as SetLogRow | undefined;
      if (inserted!.meta.changes === 0) {
        // A concurrent same-id request won after our pre-read. Return only a
        // winner from this owned canonical session; a UUID already used by a
        // different session remains indistinguishable from a missing target.
        if (winner && (sessionAtWrite || currentSession)) {
          return {
            set: winner,
            deduped: true,
            session: sessionAtWrite ?? currentSession!,
          };
        }
        if (
          currentSession &&
          !attemptScoped &&
          currentSession.write_protocol !== 'legacy'
        ) {
          throw new SessionWriteConflictError(
            'session_attempt_required',
            currentSession,
          );
        }
        if (!sessionAtWrite && currentSession) {
          throw new SessionWriteConflictError(
            'session_attempt_conflict',
            currentSession,
            casAttempt,
          );
        }
        if (sessionAtWrite?.status === 'discarded') {
          throw new SessionWriteConflictError('session_discarded', sessionAtWrite);
        }
        if (sessionAtWrite?.status === 'skipped') {
          throw new SessionWriteConflictError(
            'session_state_conflict',
            sessionAtWrite,
          );
        }
        throw new Error('session_not_found');
      }
      // The claim/start and insert share one transaction, so a successful insert
      // always has a matching non-discarded session update. Keep this check as
      // a defensive invariant rather than allowing a stranded live set.
      if (started!.meta.changes === 0) {
        if (currentSession && currentSession.attempt !== casAttempt) {
          throw new SessionWriteConflictError(
            'session_attempt_conflict',
            currentSession,
            casAttempt,
          );
        }
        if (currentSession) {
          if (currentSession.status === 'skipped') {
            throw new SessionWriteConflictError(
              'session_state_conflict',
              currentSession,
            );
          }
          throw new SessionWriteConflictError('session_discarded', currentSession);
        }
        throw new Error('session_not_found');
      }
      if (!sessionAtWrite) throw new Error('session_not_found');
      return { set: row, deduped: false, session: sessionAtWrite };
    } catch (e) {
      const msg = String((e as Error)?.message ?? '');
      const slotConflict = /unique constraint failed/i.test(msg) && /set_index/i.test(msg);
      if (!slotConflict || attempt >= 5) throw e;
      const max = await workoutDB(db)
        .prepare(
          `SELECT COALESCE(MAX(set_index), 0) AS m FROM set_logs
           WHERE session_id = ?1 AND exercise_id = ?2 AND is_warmup = ?3
             AND deleted_at IS NULL`,
        )
        .bind(canonicalSessionId, input.exercise_id, isWarmupInt)
        .first<{ m: number }>();
      row.set_index = (max?.m ?? 0) + 1;
    }
  }
}

/**
 * Most recent live non-MCP set for (user, exercise, weight, reps, is_warmup)
 * within a sliding window (default 120s). Explicit set index / duration
 * values narrow the match; omitted values remain ambiguous wildcards. Used
 * by MCP log_set to refuse cross-channel phantom dupes when iOS just logged
 * the same work; REST writes are not gated (their idempotency is the row UUID).
 */
export async function findRecentMatchingSet(
  db: D1Database,
  userId: string,
  args: {
    exercise_id: string;
    weight: number;
    reps: number;
    is_warmup: boolean;
    set_index?: number | null;
    duration_s?: number | null;
    within_ms?: number;
  },
): Promise<SetLogRow | null> {
  const since = now() - (args.within_ms ?? 120_000);
  const row = await workoutDB(db)
    .prepare(
      `SELECT sl.* FROM set_logs sl
       JOIN sessions s ON s.id = sl.session_id
       WHERE sl.user_id = ?1
         AND s.user_id = ?1
         AND sl.exercise_id = ?2
         AND sl.weight = ?3
         AND sl.reps = ?4
         AND sl.is_warmup = ?5
         AND sl.source <> 'mcp'
         AND sl.deleted_at IS NULL
         AND sl.logged_at >= ?6
         AND (?7 IS NULL OR sl.set_index = ?7)
         AND (?8 IS NULL OR sl.duration_s = ?8)
       ORDER BY sl.logged_at DESC LIMIT 1`,
    )
    .bind(
      userId,
      args.exercise_id,
      args.weight,
      args.reps,
      args.is_warmup ? 1 : 0,
      since,
      args.set_index ?? null,
      args.duration_s ?? null,
    )
    .first<SetLogRow>();
  return row ?? null;
}

export async function patchSet(
  db: D1Database,
  userId: string,
  setId: string,
  patch: {
    weight?: number;
    reps?: number;
    rpe?: number | null;
    notes?: string | null;
    duration_s?: number | null;
    deleted?: boolean;
  },
  expected?: { session_id: string; attempt: number; updated_at: number },
): Promise<(SetLogRow & { session?: SessionRow }) | null> {
  if (patch.deleted === false) {
    throw new Error('set_undelete_unsupported');
  }
  const row = await workoutDB(db)
    .prepare(
      `SELECT sl.*, s.attempt AS session_attempt
         FROM set_logs sl JOIN sessions s ON s.id = sl.session_id
       WHERE sl.id = ?1 AND s.user_id = ?2`,
    )
    .bind(setId, userId)
    .first<SetLogRow & { session_attempt: number }>();
  if (!row) return null;
  const has = (field: keyof typeof patch) =>
    Object.prototype.hasOwnProperty.call(patch, field);
  const matches = (candidate: SetLogRow) => {
    if (patch.deleted === true) return candidate.deleted_at != null;
    if (candidate.deleted_at != null) return false;
    return (['weight', 'reps', 'rpe', 'notes', 'duration_s'] as const)
      .every((field) => !has(field) || candidate[field] === patch[field]);
  };
  if (expected && (row.session_id !== expected.session_id || row.session_attempt !== expected.attempt
      || (row.updated_at !== expected.updated_at && !matches(row)))) {
    throw new Error('set_correction_conflict');
  }
  if (expected && row.deleted_at != null && patch.deleted !== true) {
    throw new Error('set_correction_conflict');
  }
  const ts = now();
  const statements: D1PreparedStatement[] = [];
  const deletedAt =
    patch.deleted === undefined
      ? row.deleted_at
      : row.deleted_at ?? ts;
  // Build a field-only UPDATE. A duration correction must not rewrite a
  // concurrently changed weight/RPE or resurrect a concurrently deleted row;
  // deleted_at is touched only for an explicit soft-delete. Undelete is not a
  // public operation: an old-attempt tombstone must never rejoin a restarted
  // workout generation.
  const values: unknown[] = [setId];
  const assignments: string[] = [];
  const assign = (column: string, value: unknown) => {
    values.push(value);
    assignments.push(`${column}=?${values.length}`);
  };
  if (has('weight')) assign('weight', patch.weight);
  if (has('reps')) assign('reps', patch.reps);
  if (has('rpe')) assign('rpe', patch.rpe);
  if (has('notes')) assign('notes', patch.notes);
  if (has('duration_s')) assign('duration_s', patch.duration_s);
  if (has('deleted')) assign('deleted_at', deletedAt);
  if (assignments.length > 0 && (!expected || !matches(row))) {
    values.push(ts);
    assignments.push(`updated_at=MAX(updated_at + 1, ?${values.length})`);
    let condition = '';
    if (expected) {
      values.push(expected.updated_at, expected.session_id, expected.attempt);
      condition = ` AND updated_at=?${values.length - 2}
        AND session_id=?${values.length - 1}
        AND EXISTS (SELECT 1 FROM sessions WHERE id=set_logs.session_id AND attempt=?${values.length})
        AND deleted_at IS NULL`;
    }
    statements.push(workoutDB(db).prepare(`UPDATE set_logs SET ${assignments.join(', ')} WHERE id=?1${condition}`)
      .bind(...values));
  }
  // Phantom-session guard. Logging a set promotes a session 'planned' ->
  // 'in_progress' (see logSet). Deleting the LAST live set must do the
  // inverse: an 'in_progress' session with zero live sets records no work,
  // yet without this it lingers as a stale "in progress" row that the
  // calendar/agenda (and MCP get_today_workout) still surface. Revert it to
  // 'planned' and clear started_at so EVERY client — app, REST, MCP — agrees
  // the day is simply the upcoming workout again. Fires only on a real
  // live->deleted transition (field-only edits never touch
  // status), and only for 'in_progress' (a 'completed' session is NOT
  // auto-un-completed — that's a deliberate terminal state).
  const isDelete = patch.deleted === true;
  if (isDelete) {
    // Check both facts at the write's linearization point: this deletion must
    // still belong to the generation we read, and no concurrent writer may
    // have installed another live set. If a new set wins first, NOT EXISTS is
    // false; if this demotion wins first, logSet's ordered batch promotes the
    // same attempt back to in_progress. A discard/restart advances `attempt`,
    // so a stale deletion can never demote the newer workout.
    statements.push(workoutDB(db).prepare(
        `UPDATE sessions
            SET status = 'planned', started_at = NULL, updated_at = MAX(updated_at + 1, ?2)
          WHERE id = ?1
            AND status = 'in_progress'
            AND attempt = ?3
            AND NOT EXISTS (
              SELECT 1 FROM set_logs
               WHERE session_id = ?1 AND deleted_at IS NULL
            )`,
      )
      .bind(row.session_id, ts, row.session_attempt));
  }
  // Keep deletion and last-set demotion atomic; a lost reply can safely
  // replay the desired state without reopening or retargeting a workout.
  if (statements.length) await runWorkoutWriteBatch(db, statements);
  const fresh = await workoutDB(db).prepare(
    `SELECT sl.*, s.attempt AS session_attempt FROM set_logs sl
       JOIN sessions s ON s.id=sl.session_id WHERE sl.id=?1 AND s.user_id=?2`)
    .bind(setId, userId).first<SetLogRow & { session_attempt: number }>();
  if (expected && (!fresh || fresh.session_attempt !== expected.attempt || !matches(fresh))) {
    throw new Error('set_correction_conflict');
  }
  if (!fresh) return null;
  const { session_attempt, ...set } = fresh;
  if (!expected) return set;
  const session = await workoutDB(db).prepare('SELECT * FROM sessions WHERE id=?1 AND user_id=?2')
    .bind(set.session_id, userId).first<SessionRow>();
  if (!session || session.attempt !== expected.attempt) throw new Error('set_correction_conflict');
  return { ...set, session };
}

// ---- read models ---------------------------------------------------------

/** Change a movement for this attempt only. Session CAS + plan-version CAS are
 * enforced in the same transaction as the audit. No log or plan is rewritten. */
export async function swapSessionExercise(db: D1Database, userId: string, sessionId: string,
  slotId: string, input: { to_exercise: string; expected_attempt: number;
    expected_version: number; expected_revision: number }) {
  const session = await workoutDB(db).prepare('SELECT * FROM sessions WHERE id=?1 AND user_id=?2')
    .bind(sessionId, userId).first<SessionRow>();
  if (!session) return { error: 'not_found' as const };
  if (session.attempt !== input.expected_attempt || !['planned', 'in_progress'].includes(session.status)) {
    return { error: 'session_conflict' as const };
  }
  const plan = await getPlanTree(db, userId);
  if (!plan || plan.version !== input.expected_version) return { error: 'plan_conflict' as const };
  const slot = plan.workouts.flatMap((day) => day.exercises).find((slot) => slot.id === slotId);
  if (!slot) return { error: 'not_found' as const };
  const swaps = parseSessionExerciseSwaps(session.exercise_swaps, session.attempt);
  if (swaps.revision !== input.expected_revision) return { error: 'swap_conflict' as const };
  const exercise = await resolveExercise(db, input.to_exercise);
  if (!exercise) return { error: 'exercise_not_found' as const };
  const destination = await workoutDB(db).prepare('SELECT * FROM exercises WHERE id=?1')
    .bind(exercise.id).first<{ id: string; name: string; unit: string; primary_muscle: string;
      modality: string; laterality: string; load_mode: string; demo_slug: string | null }>();
  if (!destination) return { error: 'exercise_not_found' as const };
  const timed = ['timed', 'cardio'].includes(slot.exercise_modality) || slot.target_duration_s != null;
  if (timed !== ['timed', 'cardio'].includes(destination.modality)) {
    return { error: 'incompatible_measure' as const };
  }
  const previous = applicableSessionSwap(session.exercise_swaps, slot, session.attempt);
  const replacement: EnrichedTemplateExercise = { ...slot,
    exercise_id: destination.id, exercise_name: destination.name, exercise_unit: destination.unit,
    exercise_muscle: destination.primary_muscle, exercise_modality: destination.modality,
    exercise_laterality: destination.laterality, exercise_load_mode: destination.load_mode,
    exercise_demo_slug: destination.demo_slug, target_weight: null, cues: null, progression: null };
  const entry = { original: slot, replacement,
    exercise_ids: [...new Set([slot.exercise_id, ...(previous?.exercise_ids ?? []), destination.id])] };
  const next = JSON.stringify({ attempt: session.attempt, revision: swaps.revision + 1,
    entries: [...swaps.entries.filter((entry) => entry.original.id !== slotId), entry] });
  const auditID = uuid();
  const results = await runWorkoutWriteBatch(db, [
    workoutDB(db).prepare(`UPDATE sessions SET exercise_swaps=?3, updated_at=MAX(updated_at+1,?4)
      WHERE id=?1 AND user_id=?2 AND attempt=?5 AND status IN ('planned','in_progress')
        AND exercise_swaps IS ?6
        AND EXISTS (SELECT 1 FROM plans WHERE id=?7 AND user_id=?2 AND status='active' AND version=?8)
      RETURNING *`).bind(sessionId, userId, next, now(), input.expected_attempt,
        session.exercise_swaps ?? null, plan.id, input.expected_version),
    workoutDB(db).prepare(`INSERT INTO audit_log(id,user_id,actor,tool,args,result,created_at)
      SELECT ?1,?2,'ios','swap_session_exercise',?3,?4,?5 WHERE changes()>0`)
      .bind(auditID, userId, JSON.stringify({ session_id: sessionId, slot_id: slotId, ...input }), next, now()),
  ]);
  const updated = results[0]?.results[0] as SessionRow | undefined;
  return updated ?? { error: 'swap_conflict' as const };
}

export async function getState(
  db: D1Database,
  userId: string,
  sincePlanVersion: number,
  setsSince: number,
  eventsSince = 0,
  activitiesSince = 0,
  logSince = 0,
) {
  // Capture the response watermark before any collection read. A write that
  // commits after its collection was read will then have updated_at greater
  // than this value and cannot be skipped by the next overlapping pull.
  const serverTime = now();
  const plan = await getActivePlan(db, userId);
  const baseTree =
    plan && plan.version > sincePlanVersion ? await getPlanTree(db, userId) : null;
  // The weekly schedule rides the existing plan-tree sync: it is only
  // returned when the tree is (i.e. when plans.version advanced past the
  // client cursor). Parsed via the single meta accessor so iOS never
  // hand-parses meta. Null when nothing changed — no new endpoint.
  // Parsed via the single meta accessor so iOS never hand-parses meta. The
  // authored multisport intent (race/periodization/trips/stress_model) rides
  // the same plan-tree sync as the schedule — surfaced here pre-parsed.
  const baseMeta = baseTree ? parsePlanMeta(baseTree.meta) : null;
  const tree =
    baseTree && baseMeta
      ? {
          ...baseTree,
          schedule: baseMeta.schedule,
          race: baseMeta.race ?? null,
          periodization: baseMeta.periodization ?? [],
          trips: baseMeta.trips ?? [],
          stress_model: baseMeta.stress_model ?? null,
        }
      : null;
  const sessions = await workoutDB(db)
    .prepare('SELECT * FROM sessions WHERE user_id = ?1 AND updated_at > ?2 ORDER BY date')
    .bind(userId, setsSince)
    .all<SessionRow>();
  // Full reload preserves the existing complete shape. Incremental pulls use
  // the server-owned mutable cursor directly from the member-first index and
  // include soft-deleted rows as tombstones.
  const sets = setsSince > 0
    ? await workoutDB(db)
        .prepare(
          `SELECT * FROM set_logs
            WHERE user_id = ?1 AND updated_at > ?2
            ORDER BY updated_at, id`,
        )
        .bind(userId, setsSince)
        .all<SetLogRow>()
    : await workoutDB(db)
        .prepare(
          `SELECT sl.* FROM set_logs sl JOIN sessions s ON s.id = sl.session_id
            WHERE s.user_id = ?1 ORDER BY sl.logged_at`,
        )
        .bind(userId)
        .all<SetLogRow>();
  // external_events ride a SEPARATE watermark (synced_at epoch-ms). This is
  // a server-owned reconciled cache: NOT gated on plans.version and a ride
  // sync NEVER bumps it. TWO explicit modes (iOS must match):
  //
  //  - FULL RELOAD  (events_since absent OR 0): return the full CURRENT set
  //    of NON-deleted external_events. The full-reload path does a full
  //    replace (DESIGN §7, same as since=0/sets_since=0) so the server must
  //    NOT hand it tombstones — there is nothing to reconcile them against.
  //  - INCREMENTAL  (events_since > 0): return every row touched since the
  //    cursor INCLUDING soft-deleted ones (deleted_at set), so a syncing
  //    client learns about removals and drops them — exactly the set_logs
  //    delta+tombstone pattern.
  const events =
    eventsSince > 0
      ? await workoutDB(db)
          .prepare(
            'SELECT * FROM external_events WHERE user_id = ?1 AND synced_at > ?2 ORDER BY synced_at',
          )
          .bind(userId, eventsSince)
          .all<ExternalEventRow>()
      : await workoutDB(db)
          .prepare(
            'SELECT * FROM external_events WHERE user_id = ?1 AND deleted_at IS NULL ORDER BY synced_at',
          )
          .bind(userId)
          .all<ExternalEventRow>();
  // external_activities ride their OWN watermark (activities_since), exactly
  // like external_events: a separate server-owned reconciled cache (COMPLETED
  // endurance actuals), never gated on plans.version. Same two modes:
  //  - FULL RELOAD  (activities_since absent/0): full current non-deleted set
  //    (full replace on the client — no tombstones to reconcile).
  //  - INCREMENTAL  (activities_since > 0): every row touched since the cursor
  //    INCLUDING soft-deleted ones, so a syncing client learns about removals.
  const activities =
    activitiesSince > 0
      ? await workoutDB(db)
          .prepare(
            'SELECT * FROM external_activities WHERE user_id = ?1 AND synced_at > ?2 ORDER BY synced_at',
          )
          .bind(userId, activitiesSince)
          .all<ExternalActivityRow>()
      : await workoutDB(db)
          .prepare(
            'SELECT * FROM external_activities WHERE user_id = ?1 AND deleted_at IS NULL ORDER BY date',
          )
          .bind(userId)
          .all<ExternalActivityRow>();
  // Generic activity log (M3 — `activities` table). Append-only,
  // user-authored. Same delta-sync pattern as set_logs / external_events:
  //  - FULL RELOAD  (log_since absent/0): full current non-deleted set.
  //  - INCREMENTAL  (log_since > 0): every row touched since the cursor
  //    INCLUDING soft-deleted ones, so a syncing client learns about
  //    removals. Uses server-owned `updated_at`, never the client-authored
  //    event time, so clock skew cannot strand rows (see
  //    listActivitiesForUser for the delta-sync contract).
  const userActivities =
    logSince > 0
      ? await listActivitiesForUser(db, userId, logSince)
      : (
          await workoutDB(db)
            .prepare(
              'SELECT * FROM activities WHERE user_id = ?1 AND deleted_at IS NULL ORDER BY logged_at',
            )
            .bind(userId)
            .all<ActivityRow>()
        ).results;
  return {
    plan: tree,
    plan_version: plan?.version ?? 0,
    // Rollout capability for the two intervals.icu cache cursors. Older
    // Workers rewrote synced_at on every reconcile, so collection presence
    // alone cannot tell iOS that a nonzero cursor is safe. P2 lands the event
    // and activity semantics together; one version gates both collections.
    external_sync_cursors_version: 2 as const,
    sessions: sessions.results,
    sets: sets.results,
    external_events: events.results,
    external_activities: activities.results,
    activities: userActivities,
    server_time: serverTime,
  };
}

export async function getInProgressSession(
  db: D1Database,
  userId: string,
): Promise<SessionRow | null> {
  return workoutDB(db)
    .prepare(
      "SELECT * FROM sessions WHERE user_id = ?1 AND status = 'in_progress' ORDER BY updated_at DESC LIMIT 1",
    )
    .bind(userId)
    .first<SessionRow>();
}

export async function getSetsForSession(db: D1Database, sessionId: string) {
  const r = await workoutDB(db)
    .prepare(
      'SELECT * FROM set_logs WHERE session_id = ?1 AND deleted_at IS NULL ORDER BY logged_at',
    )
    .bind(sessionId)
    .all<SetLogRow>();
  return r.results;
}

export async function getRecentSessions(
  db: D1Database,
  userId: string,
  n: number,
  throughDate = '9999-12-31',
): Promise<SessionRow[]> {
  // Exclude 'discarded' — a thrown-away session is not "recent training"
  // and must not surface as last_session in the coach brief / today
  // context. (Visual calendar surfaces vanish it via the projection;
  // set-based reads via deleted_at. This is the one session-list read
  // that needs an explicit filter.)
  const r = await workoutDB(db)
    .prepare("SELECT * FROM sessions WHERE user_id = ?1 AND status != 'discarded' AND date <= ?3 ORDER BY date DESC, id LIMIT ?2")
    .bind(userId, n, throughDate)
    .all<SessionRow>();
  return r.results;
}

/**
 * Most recent COMPLETED session, optionally excluding a date (usually
 * today). Coaching context wants "the last real training session" — a
 * skipped/planned row in between (status != 'completed') should not obscure
 * it. Distinct from getRecentSessions, which returns the latest row of any
 * non-discarded status.
 */
export async function getLastCompletedSession(
  db: D1Database,
  userId: string,
  excludeDate?: string,
  throughDate = '9999-12-31',
): Promise<SessionRow | null> {
  return workoutDB(db)
    .prepare(
      "SELECT * FROM sessions WHERE user_id = ?1 AND status = 'completed' AND date != ?2 AND date <= ?3 ORDER BY date DESC, id LIMIT 1",
    )
    .bind(userId, excludeDate ?? '', throughDate)
    .first<SessionRow>();
}

export async function getSessionByDate(
  db: D1Database,
  userId: string,
  date: string,
): Promise<SessionRow | null> {
  // Excludes 'discarded': a thrown-away session must read as "no session
  // on this date" for the MCP coach reads that call this (get_today_workout,
  // get_session_log) — same vanish semantics the calendar projection
  // applies. Revival/discard never route through here (getOrCreateSession
  // has its own query; discardSession takes a session id), so filtering is
  // safe.
  return workoutDB(db)
    .prepare("SELECT * FROM sessions WHERE user_id = ?1 AND date = ?2 AND status != 'discarded' ORDER BY created_at LIMIT 1")
    .bind(userId, date)
    .first<SessionRow>();
}

export async function getWorkoutSummary(
  db: D1Database, userId: string, sessionId: string,
): Promise<WorkoutSummary | null> {
  const owned = `SELECT id FROM sessions WHERE id=?1 AND user_id=?2 AND status!='discarded'`;
  const [sessionResult, setResult, exerciseResult, previousResult] = await workoutDB(db).batch([
    workoutDB(db).prepare(`SELECT * FROM sessions WHERE id IN (${owned})`).bind(sessionId, userId),
    workoutDB(db).prepare(`SELECT * FROM set_logs WHERE session_id IN (${owned}) AND deleted_at IS NULL`).bind(sessionId, userId),
    workoutDB(db).prepare(`SELECT e.* FROM exercises e WHERE e.id IN (
      SELECT exercise_id FROM set_logs WHERE session_id IN (${owned}) AND deleted_at IS NULL)`)
      .bind(sessionId, userId),
    workoutDB(db).prepare(`SELECT sl.exercise_id,sl.weight,sl.is_timed,MAX(sl.reps) AS reps,
        MAX(COALESCE(sl.duration_s,sl.reps)) AS duration_s
      FROM set_logs sl JOIN sessions s ON s.id=sl.session_id
      WHERE s.user_id=?2 AND s.status='completed' AND sl.deleted_at IS NULL AND sl.is_warmup=0
        AND s.date < (SELECT date FROM sessions WHERE id IN (${owned}))
        AND sl.exercise_id IN (SELECT exercise_id FROM set_logs WHERE session_id IN (${owned}) AND deleted_at IS NULL)
      GROUP BY sl.exercise_id,sl.weight,sl.is_timed`).bind(sessionId, userId),
  ]);
  const session = sessionResult!.results[0] as unknown as SessionRow | undefined;
  if (!session) return null;
  return summarizeWorkout(session, setResult!.results as unknown as SummarySet[],
    previousResult!.results as unknown as SummarySet[], exerciseResult!.results as unknown as SummaryExercise[],
    parseRunnerTargets(session.runner_targets));
}

// ---- notes + audit -------------------------------------------------------

export async function writeNote(
  db: D1Database,
  userId: string,
  scope: string,
  refId: string | null,
  author: 'claude' | 'nick',
  body: string,
): Promise<void> {
  await workoutDB(db)
    .prepare(
      'INSERT INTO notes (id,user_id,scope,ref_id,author,body,created_at) VALUES (?1,?2,?3,?4,?5,?6,?7)',
    )
    .bind(uuid(), userId, scope, refId, author, body, now())
    .run();
}

export async function writeAudit(
  db: D1Database,
  userId: string,
  tool: string,
  args: unknown,
  result: string,
  actor: string = 'mcp',
): Promise<void> {
  await workoutDB(db)
    .prepare(
      'INSERT INTO audit_log (id,user_id,actor,tool,args,result,created_at) VALUES (?1,?2,?3,?4,?5,?6,?7)',
    )
    .bind(uuid(), userId, actor, tool, JSON.stringify(args).slice(0, 4000), result.slice(0, 500), now())
    .run();
}

// ---- generic activity log (M3 — append-only, user-authored) --------------
//
// The "everything else" bucket alongside strength sessions (set_logs) and
// intervals.icu actuals (external_activities). Same consistency model as
// set_logs:
//   - `id` is the CLIENT-generated UUID idempotency key (iOS outbox safe-
//     retries land on ON CONFLICT(id) DO NOTHING). MCP-source rows mint the
//     id server-side because Claude doesn't retry like the iOS outbox.
//   - Rows are SOFT-deleted only (deleted_at) — preserve history.
//   - Writes do NOT bump plans.version.

export interface ActivityInput {
  id: string;
  date: string;
  type: string;
  title?: string | null;
  duration_minutes?: number | null;
  notes?: string | null;
  logged_at?: number;
}

/**
 * Idempotent on the client-generated `id`. A retry of the same id is a
 * no-op (returns the existing row). The user_id is stamped from the
 * authenticated caller, never trusted from the client body.
 */
export async function logActivity(
  db: D1Database,
  userId: string,
  input: ActivityInput,
  source: 'ios' | 'mcp',
): Promise<ActivityRow> {
  const updatedAt = now();
  const loggedAt = input.logged_at ?? updatedAt;
  await workoutDB(db)
    .prepare(
      `INSERT INTO activities
         (id,user_id,date,type,title,duration_minutes,notes,logged_at,source,deleted_at,updated_at)
       VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,NULL,?10)
       ON CONFLICT(id) DO NOTHING`,
    )
    .bind(
      input.id,
      userId,
      input.date,
      input.type,
      input.title ?? null,
      input.duration_minutes ?? null,
      input.notes ?? null,
      loggedAt,
      source,
      updatedAt,
    )
    .run();
  // Re-select so retries return the *original* persisted row (preserving the
  // original logged_at/title/etc.), not the fresh-looking input.
  const row = await workoutDB(db)
    .prepare('SELECT * FROM activities WHERE id = ?1 AND user_id = ?2')
    .bind(input.id, userId)
    .first<ActivityRow>();
  if (!row) {
    // Either the user_id mismatched (an id collision across users — should
    // be impossible for UUIDs, but we surface it rather than silently
    // returning a stale row from another user) or the insert failed
    // mysteriously. Either way the caller needs to see this.
    throw new Error('activity_insert_failed');
  }
  return row;
}

/**
 * Soft-delete by id, scoped to the caller's user. Returns true on success,
 * false if the row doesn't exist or belongs to another user — REST surfaces
 * both as 404 (don't leak existence of other users' rows). Idempotent:
 * deleting an already-deleted row returns false (the row still exists but
 * the second call is a no-op delete).
 */
export async function softDeleteActivity(
  db: D1Database,
  userId: string,
  activityId: string,
): Promise<boolean> {
  const ts = now();
  const r = await workoutDB(db)
    .prepare(
      `UPDATE activities
          SET deleted_at = ?3,
              updated_at = MAX(updated_at + 1, ?3)
       WHERE id = ?1 AND user_id = ?2 AND deleted_at IS NULL`,
    )
    .bind(activityId, userId, ts)
    .run();
  // D1 exposes meta.changes; fall back to 0 if absent.
  const changes = (r as { meta?: { changes?: number } }).meta?.changes ?? 0;
  return changes > 0;
}

/**
 * Delta-sync read for /api/state. Returns every row TOUCHED since the
 * server-owned cursor, including tombstones, so skewed client event times
 * cannot strand a row behind a server-time watermark. Same pattern as the
 * set_logs sync described in DESIGN.md §7.
 */
export async function listActivitiesForUser(
  db: D1Database,
  userId: string,
  sinceMs: number,
): Promise<ActivityRow[]> {
  const rows = await workoutDB(db)
    .prepare(
      `SELECT * FROM activities
       WHERE user_id = ?1 AND updated_at > ?2
       ORDER BY updated_at, id`,
    )
    .bind(userId, sinceMs)
    .all<ActivityRow>();
  return rows.results;
}

// ---- plan-tree mutations (MCP write tools) -------------------------------

export interface ExerciseInput extends ExerciseGroupFields {
  exercise: string;
  order_index?: number;
  target_sets: number;
  target_reps: number;
  target_reps_max?: number | null;
  target_rpe?: number | null;
  rest_seconds?: number;
  target_weight?: number | null;
  /** Planned hold seconds for timed slots (mirrors set_logs.duration_s).
   *  NULL/omitted → conventional reps slot. */
  target_duration_s?: number | null;
  progression?: unknown;
  cues?: string | null;
  /** 1 = prescribed warm-up slot (erg, mobility). Omitted/0 = working slot.
   *  Preserved across a full-tree rebuild so update_plan never silently
   *  strips a warm-up flag set via the REST editor. */
  is_warmup?: number | boolean;
}

export type PrescriptionValidationError = {
  error: 'invalid_fields';
  fields: string[];
};

const isPlainRecord = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === 'object' && !Array.isArray(value);

/** Runtime prescription validation shared by every plan-slot writer.
 * Null is intentionally distinct from omission for nullable targets. */
export function validateExercisePrescription(
  value: Record<string, unknown>,
  options: { partial?: boolean; modality?: string | null } = {},
): PrescriptionValidationError | null {
  const bad = new Set<string>();
  const has = (field: string) => Object.prototype.hasOwnProperty.call(value, field);
  const required = (field: string) => !options.partial || has(field);
  const integer = (field: string, min: number) => {
    if (required(field) && (!Number.isSafeInteger(value[field]) || (value[field] as number) < min)) bad.add(field);
  };
  integer('target_sets', 1);
  integer('target_reps', 1);
  if (has('target_reps_max') && value.target_reps_max !== null &&
      (!Number.isSafeInteger(value.target_reps_max) || (value.target_reps_max as number) < 1)) bad.add('target_reps_max');
  if (has('target_rpe') && value.target_rpe !== null &&
      (typeof value.target_rpe !== 'number' || !Number.isFinite(value.target_rpe) || value.target_rpe < 0 || value.target_rpe > 10)) bad.add('target_rpe');
  if (has('rest_seconds') && (!Number.isSafeInteger(value.rest_seconds) || (value.rest_seconds as number) < 0)) bad.add('rest_seconds');
  if (has('target_duration_s') && value.target_duration_s !== null &&
      (!Number.isSafeInteger(value.target_duration_s) || (value.target_duration_s as number) <= 0)) bad.add('target_duration_s');
  if (has('target_weight') && value.target_weight !== null &&
      (typeof value.target_weight !== 'number' || !Number.isFinite(value.target_weight))) bad.add('target_weight');
  if (typeof value.target_weight === 'number' && value.target_weight < 0 &&
      options.modality !== 'bw' && options.modality !== 'timed') bad.add('target_weight');
  if (has('order_index') && (!Number.isSafeInteger(value.order_index) || (value.order_index as number) < 0)) bad.add('order_index');
  if (has('cues') && value.cues !== null && typeof value.cues !== 'string') bad.add('cues');
  if (has('progression') && value.progression !== null && !isPlainRecord(value.progression)) bad.add('progression');
  if (has('group_id') && value.group_id !== undefined && value.group_id !== null && !isGroupId(value.group_id)) bad.add('group_id');
  for (const field of ['group_rest_seconds', 'group_transition_seconds']) {
    if (has(field) && value[field] !== undefined && value[field] !== null &&
        (!Number.isSafeInteger(value[field]) || (value[field] as number) < 0)) bad.add(field);
  }
  if (has('is_warmup') && typeof value.is_warmup !== 'boolean' && value.is_warmup !== 0 && value.is_warmup !== 1) bad.add('is_warmup');
  if (typeof value.target_reps === 'number' && typeof value.target_reps_max === 'number' && value.target_reps_max < value.target_reps) bad.add('target_reps_max');
  return bad.size === 0 ? null : { error: 'invalid_fields', fields: [...bad].sort() };
}

async function resolveOrThrow(db: D1Database, name: string): Promise<string> {
  const ex = await resolveExercise(db, name);
  if (!ex) throw new Error(`unknown_exercise:${name}`);
  return (ex as { id: string }).id;
}

/**
 * Transactional full-plan upsert with optimistic concurrency. If
 * expectedVersion is given and stale, returns a conflict (Claude refetches
 * and reapplies — DESIGN.md §7). Replaces the day/exercise tree atomically.
 */
export async function updatePlanTree(
  db: D1Database,
  userId: string,
  input: {
    name?: string;
    meta?: unknown;
    expected_version?: number | null;
    workouts: {
      day_label?: string | null;
      name: string;
      order_index?: number;
      notes?: string | null;
      exercises?: ExerciseInput[];
    }[];
  },
  attribution: PlanWriteAttribution = { actor: 'system', operation: 'update_plan' },
  retryConcurrentBootstrap = true,
): Promise<
  | { conflict: true; current_version: number }
  | { conflict: false; plan: PlanTree }
  | { conflict: false; acknowledged: true; refresh_required: true; plan_id: string; version: number }
  | { error: 'unknown_exercise'; queries: string[]; query: string }
  | PrescriptionValidationError | GroupConflict
> {
  if (!input || !Array.isArray(input.workouts)) {
    return { error: 'invalid_fields', fields: ['workouts'] };
  }
  if (input.name !== undefined && typeof input.name !== 'string') {
    return { error: 'invalid_fields', fields: ['name'] };
  }
  if (input.meta !== undefined && input.meta !== null && !isPlainRecord(input.meta)) {
    return { error: 'invalid_fields', fields: ['meta'] };
  }
  if (input.expected_version !== undefined && input.expected_version !== null &&
      (!Number.isInteger(input.expected_version) || input.expected_version < 1)) {
    return { error: 'invalid_fields', fields: ['expected_version'] };
  }
  const malformedDays: string[] = [];
  input.workouts.forEach((day, dayIndex) => {
    if (!isPlainRecord(day) || !Array.isArray(day.exercises ?? [])) {
      malformedDays.push(`workouts.${dayIndex}`);
      return;
    }
    (day.exercises ?? []).forEach((exercise, exerciseIndex) => {
      if (!isPlainRecord(exercise)) malformedDays.push(`workouts.${dayIndex}.exercises.${exerciseIndex}`);
    });
  });
  if (malformedDays.length > 0) return { error: 'invalid_fields', fields: malformedDays.sort() };
  const explicitlyGroups = input.workouts.some((day) => (day.exercises ?? []).some((slot) =>
    slot.group_id !== undefined || slot.group_rest_seconds !== undefined || slot.group_transition_seconds !== undefined));
  if (explicitlyGroups && input.expected_version == null) return { error: 'invalid_fields', fields: ['expected_version'] };
  let plan = await getActivePlan(db, userId);
  let createsPlan = false;
  if (
    plan &&
    input.expected_version != null &&
    input.expected_version !== plan.version
  ) {
    return { conflict: true, current_version: plan.version };
  }

  // Resolve every exercise name up front, collecting EVERY unresolved
  // name into `queries` instead of aborting on the first miss — a 16-
  // exercise plan with two typos previously took two round trips
  // (fail-fix-retry-fail-fix-retry). Now the agent fixes them in one
  // pass. `query` is kept (= first unknown) for back-compat with the
  // structured shape introduced in PR #12. Use list_exercises to
  // discover valid catalog names.
  const resolved = new Map<string, string>();
  const resolvedModality = new Map<string, string>();
  const unknown: string[] = [];
  const seenUnknown = new Set<string>();
  for (const d of input.workouts) {
    for (const e of d.exercises ?? []) {
      if (typeof e.exercise !== 'string' || e.exercise.trim() === '') {
        if (!seenUnknown.has('<missing>')) {
          seenUnknown.add('<missing>');
          unknown.push('<missing>');
        }
        continue;
      }
      if (resolved.has(e.exercise) || seenUnknown.has(e.exercise)) continue;
      const ex = await resolveExercise(db, e.exercise);
      if (!ex) {
        seenUnknown.add(e.exercise);
        unknown.push(e.exercise);
        continue;
      }
      resolved.set(e.exercise, (ex as { id: string }).id);
      resolvedModality.set(e.exercise, (ex as { modality: string }).modality);
    }
  }
  if (unknown.length > 0) {
    return { error: 'unknown_exercise', queries: unknown, query: unknown[0]! };
  }
  const invalidFields = new Set<string>();
  input.workouts.forEach((day, dayIndex) => {
    if (typeof day.name !== 'string' || day.name.trim() === '') invalidFields.add(`workouts.${dayIndex}.name`);
    if (day.order_index !== undefined && (!Number.isInteger(day.order_index) || day.order_index < 0)) invalidFields.add(`workouts.${dayIndex}.order_index`);
    if (day.day_label !== undefined && day.day_label !== null && typeof day.day_label !== 'string') invalidFields.add(`workouts.${dayIndex}.day_label`);
    if (day.notes !== undefined && day.notes !== null && typeof day.notes !== 'string') invalidFields.add(`workouts.${dayIndex}.notes`);
    (day.exercises ?? []).forEach((exercise, exerciseIndex) => {
      const invalid = validateExercisePrescription(exercise as unknown as Record<string, unknown>, {
        modality: resolvedModality.get(exercise.exercise),
      });
      for (const field of invalid?.fields ?? []) invalidFields.add(`workouts.${dayIndex}.exercises.${exerciseIndex}.${field}`);
    });
  });
  if (invalidFields.size > 0) return { error: 'invalid_fields', fields: [...invalidFields].sort() };
  if (!plan) {
    // Build the candidate only after the complete proposed tree has passed
    // resolution and runtime validation. Its INSERT joins the tree rebuild's
    // transaction below, so a downstream failure cannot leave an empty plan.
    const prior = await workoutDB(db).prepare(
      'SELECT COALESCE(MAX(version),0) AS version FROM plans WHERE user_id=?1',
    ).bind(userId).first<{ version: number }>();
    const ts = now();
    plan = {
      id: uuid(), user_id: userId, name: input.name ?? 'My Plan', status: 'active',
      version: (prior?.version ?? 0) + 1, meta: null, created_at: ts, updated_at: ts,
    };
    createsPlan = true;
  }

  // Capture the OLD day identity (id → name/label) before the rebuild so we
  // can re-point surviving schedule weekdays at the NEW day id whose
  // name/label matches. Without this, every update_plan (e.g. "add a
  // deadlift day") would silently wipe the entire weekly schedule because
  // rebuilt days get fresh UUIDs.
  const oldDays = await workoutDB(db)
    .prepare('SELECT id, name, day_label FROM workouts WHERE plan_id = ?1')
    .bind(plan.id)
    .all<{ id: string; name: string; day_label: string | null }>();
  const oldById = new Map<string, { name: string; day_label: string | null }>();
  for (const od of oldDays.results) {
    oldById.set(od.id, { name: od.name, day_label: od.day_label });
  }

  const ts = now();
  // Generate new day ids up-front so the schedule remap can reference them.
  const newDayIds = input.workouts.map(() => uuid());
  // Match old→new day identity by day_label first (the stable handle), then
  // by name. First writer wins on a duplicate (schedule holds one id/slot).
  const newIdByLabel = new Map<string, string>();
  const newIdByName = new Map<string, string>();
  input.workouts.forEach((d, i) => {
    const id = newDayIds[i]!;
    if (d.day_label != null) {
      const lk = d.day_label.toLowerCase();
      if (!newIdByLabel.has(lk)) newIdByLabel.set(lk, id);
    }
    const nk = d.name.toLowerCase();
    if (!newIdByName.has(nk)) newIdByName.set(nk, id);
  });

  // FK-safe rebuild: sessions.workout_id and set_logs.template_exercise_id
  // reference rows we're about to DELETE. With no ON DELETE clause on those
  // FKs (schema 0001), a strict-FK delete fails the moment any real session
  // or logged set points at a day_template/template_exercise that's being
  // rebuilt — the agent-facing bug report's P0. The fix is a pre-DELETE
  // REMAP: for every old → new (matched by day_label/name, then by
  // exercise_id within the matched day), repoint the referencing rows at
  // the NEW id; for genuinely-removed old rows, NULL out the reference
  // (history preserved, plan-tree pointer detached). All in the same D1
  // batch so it's atomic with the rebuild.

  // Build old → new day map first (matched by day_label, then name).
  const oldToNewDay = new Map<string, string | null>();
  for (const od of oldDays.results) {
    const lk = od.day_label?.toLowerCase();
    const nk = od.name.toLowerCase();
    const newId = (lk != null ? newIdByLabel.get(lk) : undefined) ?? newIdByName.get(nk) ?? null;
    oldToNewDay.set(od.id, newId);
  }
  const oldTeRows = await workoutDB(db)
    .prepare(
      `SELECT te.*
         FROM template_exercises te
         JOIN workouts d ON d.id = te.workout_id
        WHERE d.plan_id = ?1
        ORDER BY te.workout_id, te.order_index, te.created_at, te.id`,
    )
    .bind(plan.id)
    .all<TemplateExerciseRow>();
  // Even an older payload can move or remove grouped members during rebuild.
  // Keep the legacy optional version contract only for an ungrouped document.
  if (input.expected_version == null && oldTeRows.results.some((slot) => slot.group_id != null)) {
    return { error: 'invalid_fields', fields: ['expected_version'] };
  }

  // is_warmup INHERITANCE map — positional by (newDayId, exercise_id) occurrence.
  // Recovers the existing warm-up flag for a slot a caller leaves unspecified so
  // a rebuild from an older client / tool-schema payload that omits is_warmup
  // doesn't silently demote a prescribed warm-up. This MUST stay positional: the
  // new slot's flag isn't known until we apply this very inheritance, so it can't
  // key on is_warmup itself. The n-th old slot of an exercise pairs to the n-th
  // new one (old rows ordered by order_index above).
  const oldIsWarmupByDayExOcc = new Map<string, number>();
  {
    const occ = new Map<string, number>();
    for (const ot of oldTeRows.results) {
      const newDayId = oldToNewDay.get(ot.workout_id) ?? null;
      if (newDayId == null) continue;
      const exKey = `${newDayId}:${ot.exercise_id}`;
      const o = occ.get(exKey) ?? 0;
      occ.set(exKey, o + 1);
      oldIsWarmupByDayExOcc.set(`${exKey}:${o}`, ot.is_warmup);
    }
  }

  // Pre-generate new template_exercise ids AND each new slot's FINAL is_warmup
  // (the inserter below reuses both), then index the new slots by
  // (dayId, exId, is_warmup, occurrence-WITHIN-that-class). The set-log remap
  // pairs warm-up→warm-up and working→working within an exercise, so removing a
  // duplicate slot from ANY position — front, middle, or end of the duplicate
  // run — detaches that class member's logged sets to null instead of sliding
  // them onto a surviving slot of the OTHER class (e.g. a removed warm-up erg's
  // sets must not land on the surviving working erg). A purely positional index
  // only handled end removals. (A slot whose warm-up flag is genuinely flipped
  // by the rebuild changes class, so its old sets detach rather than mis-count —
  // the safe direction, consistent with the dangling/swap guards.)
  const teIdPerExerciseOccurrence: string[][] = input.workouts.map((d) =>
    (d.exercises ?? []).map(() => uuid()),
  );
  const isWarmupPerOccurrence: number[][] = input.workouts.map((d) =>
    (d.exercises ?? []).map(() => 0),
  );
  const newTeIdByClassOcc = new Map<string, string>();
  {
    const posOcc = new Map<string, number>(); // positional (exId) — inheritance lookup
    const classOcc = new Map<string, number>(); // (exId, is_warmup) — remap pairing
    input.workouts.forEach((d, di) => {
      const dayId = newDayIds[di]!;
      (d.exercises ?? []).forEach((e, ei) => {
        const exId = resolved.get(e.exercise)!;
        const exKey = `${dayId}:${exId}`;
        const p = posOcc.get(exKey) ?? 0;
        posOcc.set(exKey, p + 1);
        const isWarmup =
          e.is_warmup === undefined
            ? oldIsWarmupByDayExOcc.get(`${exKey}:${p}`) ?? 0
            : e.is_warmup
              ? 1
              : 0;
        isWarmupPerOccurrence[di]![ei] = isWarmup;
        const classKey = `${exKey}:${isWarmup}`;
        const c = classOcc.get(classKey) ?? 0;
        classOcc.set(classKey, c + 1);
        newTeIdByClassOcc.set(`${classKey}:${c}`, teIdPerExerciseOccurrence[di]![ei]!);
      });
    });
  }

  // Old → new set-log remap, paired within (exId, is_warmup) class; a surplus
  // old slot with no matching new class member detaches to null (history kept,
  // pointer cleared) — the same path a fully-removed exercise/day takes.
  const oldToNewTe = new Map<string, string | null>();
  {
    const classOcc = new Map<string, number>();
    for (const ot of oldTeRows.results) {
      const newDayId = oldToNewDay.get(ot.workout_id) ?? null;
      if (newDayId == null) {
        oldToNewTe.set(ot.id, null);
        continue;
      }
      const classKey = `${newDayId}:${ot.exercise_id}:${ot.is_warmup}`;
      const c = classOcc.get(classKey) ?? 0;
      classOcc.set(classKey, c + 1);
      oldToNewTe.set(ot.id, newTeIdByClassOcc.get(`${classKey}:${c}`) ?? null);
    }
  }

  // Group attributes follow the exact slot remap, including duplicate exercise
  // occurrences and warm-up roles. Older clients can omit these additive fields.
  const oldByNewSlot = new Map<string, TemplateExerciseRow>();
  for (const old of oldTeRows.results) {
    const newId = oldToNewTe.get(old.id);
    if (newId) oldByNewSlot.set(newId, old);
  }
  const groupCandidates = input.workouts.map((day, di) => ({
    exercises: (day.exercises ?? []).map((exercise, ei) => {
      const id = teIdPerExerciseOccurrence[di]![ei]!;
      const old = oldByNewSlot.get(id);
      const groupId = exercise.group_id === undefined ? old?.group_id ?? null : exercise.group_id;
      return {
        id, order_index: exercise.order_index ?? ei, target_sets: exercise.target_sets,
        group_id: groupId,
        group_rest_seconds: groupId == null ? exercise.group_rest_seconds ?? null
          : exercise.group_rest_seconds === undefined ? old?.group_rest_seconds ?? null : exercise.group_rest_seconds,
        group_transition_seconds: groupId == null ? exercise.group_transition_seconds ?? null
          : exercise.group_transition_seconds === undefined ? old?.group_transition_seconds ?? 0 : exercise.group_transition_seconds,
      };
    }),
  }));
  // Removing a member in a rebuild has the same singleton normalization as
  // deleting it directly. An explicitly authored singleton is still invalid.
  for (const day of groupCandidates) {
    for (const slot of day.exercises) if (slot.group_id != null) {
      const groupId = slot.group_id;
      const oldMembers = oldTeRows.results.filter((old) => old.group_id === groupId);
      const survivors = day.exercises.filter((member) => member.group_id === groupId);
      if (survivors.length === 1 && oldMembers.length >= 2 && oldMembers.some((old) => !oldToNewTe.get(old.id))) {
        Object.assign(slot, emptyExerciseGroup);
      }
    }
  }
  const groupInvalid = validatePlanExerciseGroups(groupCandidates);
  if (groupInvalid) return groupInvalid;

  // FK-safe order: INSERT new rows FIRST (so the remap can point at real
  // parents), then UPDATE refs old→new (or NULL for removed), then DELETE
  // the now-orphaned old rows by EXPLICIT id (not by plan_id sweep —
  // that'd catch the freshly-inserted new rows too). The original DELETE-
  // before-INSERT order failed FK the moment any real session or set_log
  // referenced a row being deleted.
  const nonce = uuid();
  const stmts: D1PreparedStatement[] = createsPlan
    ? [workoutDB(db).prepare(
        `INSERT INTO plans
           (id,user_id,name,status,version,meta,created_at,updated_at,plan_write_nonce)
         SELECT ?1,?2,?3,'active',?4,NULL,?5,?5,?6
          WHERE EXISTS (SELECT 1 FROM users u WHERE u.id=?2)
            AND NOT EXISTS (SELECT 1 FROM account_deletion_intents i WHERE i.user_id=?2)
            AND NOT EXISTS (SELECT 1 FROM account_deletion_receipts r WHERE r.user_id=?2)
         ON CONFLICT DO NOTHING
         RETURNING id`,
      ).bind(plan.id, userId, plan.name, -plan.version, ts, nonce)]
    : [...preparePlanWriteStart(db, plan, attribution, ts, nonce)];
  // 1) INSERT new workouts (parents) — coexist with old by id.
  input.workouts.forEach((d, di) => {
    const dayId = newDayIds[di]!;
    stmts.push(
      workoutDB(db)
        .prepare(
          `INSERT INTO workouts
           (id,plan_id,name,day_label,order_index,notes,created_at,updated_at)
           SELECT ?1,?2,?3,?4,?5,?6,?7,?8
            WHERE EXISTS (
              SELECT 1 FROM plans
               WHERE id = ?9 AND user_id = ?10 AND status = 'active' AND version = ?11
            )`,
        )
        .bind(
          dayId,
          plan!.id,
          d.name,
          d.day_label ?? null,
          d.order_index ?? di,
          d.notes ?? null,
          ts,
          ts,
          plan!.id,
          userId,
          -plan!.version,
        ),
    );
  });
  // 2) INSERT new template_exercises (children of step 1's parents). is_warmup
  // was resolved above (explicit wins; else inherit the matched old slot's flag)
  // into isWarmupPerOccurrence so the inserted flag and the remap's class keys
  // are guaranteed identical.
  input.workouts.forEach((d, di) => {
    const dayId = newDayIds[di]!;
    (d.exercises ?? []).forEach((e, ei) => {
      const exId = resolved.get(e.exercise)!;
      const isWarmup = isWarmupPerOccurrence[di]![ei]!;
      const group = groupCandidates[di]!.exercises[ei]!;
      stmts.push(
        workoutDB(db)
          .prepare(
            `INSERT INTO template_exercises
             (id,workout_id,exercise_id,order_index,target_sets,target_reps,target_reps_max,target_rpe,rest_seconds,target_weight,target_duration_s,progression,cues,is_warmup,created_at,updated_at,group_id,group_rest_seconds,group_transition_seconds)
             SELECT ?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?20,?21,?22
              WHERE EXISTS (
                SELECT 1 FROM plans
                 WHERE id = ?17 AND user_id = ?18 AND status = 'active' AND version = ?19
              )`,
          )
          .bind(
            teIdPerExerciseOccurrence[di]![ei]!, dayId, exId, e.order_index ?? ei, e.target_sets,
            e.target_reps, e.target_reps_max ?? null, e.target_rpe ?? null, e.rest_seconds ?? 120,
            e.target_weight ?? null, e.target_duration_s ?? null,
            e.progression == null ? null : JSON.stringify(e.progression),
            e.cues ?? null, isWarmup, ts, ts, plan!.id, userId, -plan!.version,
            group.group_id, group.group_rest_seconds, group.group_transition_seconds,
          ),
      );
    });
  });
  // 3) Remap session.workout_id: old → new (surviving) or NULL.
  for (const [oldDayId, newDayId] of oldToNewDay.entries()) {
    if (newDayId != null) {
      stmts.push(
        workoutDB(db)
          .prepare(
            `UPDATE sessions SET workout_id = ?2, updated_at = ?6
              WHERE workout_id = ?1
                AND EXISTS (
                  SELECT 1 FROM plans
                   WHERE id = ?3 AND user_id = ?4 AND status = 'active' AND version = ?5
                )`,
          )
          .bind(oldDayId, newDayId, plan.id, userId, -plan.version, ts),
      );
    } else {
      stmts.push(
        workoutDB(db)
          .prepare(
            `UPDATE sessions SET workout_id = NULL, updated_at = ?5
              WHERE workout_id = ?1
                AND EXISTS (
                  SELECT 1 FROM plans
                   WHERE id = ?2 AND user_id = ?3 AND status = 'active' AND version = ?4
                )`,
          )
          .bind(oldDayId, plan.id, userId, -plan.version, ts),
      );
    }
  }
  // 4) Remap set_logs.template_exercise_id (same scheme).
  for (const [oldTeId, newTeId] of oldToNewTe.entries()) {
    if (newTeId != null) {
      stmts.push(
        workoutDB(db)
          .prepare(
            `UPDATE set_logs
                SET template_exercise_id = ?2,
                    updated_at = MAX(updated_at + 1, ?6)
              WHERE template_exercise_id = ?1
                AND EXISTS (
                  SELECT 1 FROM plans
                   WHERE id = ?3 AND user_id = ?4 AND status = 'active' AND version = ?5
                )`,
          )
          .bind(oldTeId, newTeId, plan.id, userId, -plan.version, ts),
      );
    } else {
      stmts.push(
        workoutDB(db)
          .prepare(
            `UPDATE set_logs
                SET template_exercise_id = NULL,
                    updated_at = MAX(updated_at + 1, ?5)
              WHERE template_exercise_id = ?1
                AND EXISTS (
                  SELECT 1 FROM plans
                   WHERE id = ?2 AND user_id = ?3 AND status = 'active' AND version = ?4
                )`,
          )
          .bind(oldTeId, plan.id, userId, -plan.version, ts),
      );
    }
  }
  // 5) DELETE old template_exercises by EXPLICIT id (avoid catching the
  //    freshly-inserted new rows that now share plan_id). Children first.
  for (const ot of oldTeRows.results) {
    stmts.push(
      workoutDB(db)
        .prepare(
          `DELETE FROM template_exercises
            WHERE id = ?1
              AND EXISTS (
                SELECT 1 FROM plans
                 WHERE id = ?2 AND user_id = ?3 AND status = 'active' AND version = ?4
              )`,
        )
        .bind(ot.id, plan.id, userId, -plan.version),
    );
  }
  // 6) DELETE old workouts by EXPLICIT id. Parents last.
  for (const od of oldDays.results) {
    stmts.push(
      workoutDB(db)
        .prepare(
          `DELETE FROM workouts
            WHERE id = ?1
              AND EXISTS (
                SELECT 1 FROM plans
                 WHERE id = ?2 AND user_id = ?3 AND status = 'active' AND version = ?4
              )`,
        )
        .bind(od.id, plan.id, userId, -plan.version),
    );
  }
  // The full tree is rebuilt with fresh day UUIDs. Re-point each schedule
  // weekday at the NEW day whose name/label matches the OLD day it pointed
  // at; weekdays whose day genuinely no longer exists (no matching new day)
  // are cleared. Same batch ⇒ shares the single version bump. Never lose
  // the schedule key.
  // baseMeta ALWAYS starts from the EXISTING persisted plan.meta so the
  // user's recurring schedule survives a metadata-only update_plan. An
  // incoming `meta` is MERGED over it (incoming keys win). The existing
  // meta.schedule is PRESERVED unless the incoming meta explicitly carries
  // its own `schedule` key — only then does that replace it (and it still
  // rides the day-name/label remap below). Passing NO meta is unchanged.
  const existingMeta = parsePlanMeta(plan.meta);
  const incomingMetaRaw =
    input.meta !== undefined &&
    input.meta !== null &&
    typeof input.meta === 'object' &&
    !Array.isArray(input.meta)
      ? (input.meta as Record<string, unknown>)
      : undefined;
  const incomingHasSchedule =
    incomingMetaRaw !== undefined &&
    Object.prototype.hasOwnProperty.call(incomingMetaRaw, 'schedule');
  // Merge: existing meta is the base; incoming non-schedule keys overlay it.
  // The schedule is decided explicitly below so a schedule-less incoming
  // meta cannot erase the persisted one.
  const mergedMeta: PlanMeta = parsePlanMeta(
    JSON.stringify({
      ...existingMeta,
      ...(input.meta === undefined ? {} : input.meta ?? {}),
      schedule: incomingHasSchedule
        ? (incomingMetaRaw as Record<string, unknown>).schedule
        : existingMeta.schedule,
    }),
  );
  const baseMeta = mergedMeta;
  const remappedWeek = { ...baseMeta.schedule.week };
  for (const wd of WEEKDAYS) {
    const oldId = remappedWeek[wd];
    if (oldId == null) continue;
    const old = oldById.get(oldId);
    let newId: string | undefined;
    if (old) {
      if (old.day_label != null) newId = newIdByLabel.get(old.day_label.toLowerCase());
      if (!newId) newId = newIdByName.get(old.name.toLowerCase());
    }
    remappedWeek[wd] = newId ?? null;
  }
  const remappedSchedule: WeeklySchedule = {
    version: baseMeta.schedule.version,
    week: remappedWeek,
  };
  stmts.push(
    workoutDB(db)
      .prepare(
        `UPDATE plans
            SET name = ?2, meta = ?3, updated_at = ?4
          WHERE id = ?1 AND user_id = ?5 AND status = 'active' AND version = ?6
            AND plan_write_nonce=?7`,
      )
      .bind(
        plan.id,
        input.name ?? plan.name,
        serializePlanMeta(baseMeta, remappedSchedule),
        ts,
        userId,
        -plan.version,
        nonce,
      ),
  );
  const documentUpdateIndex = stmts.length - 1;
  const versionResultIndex = stmts.length;
  stmts.push(...preparePlanWriteFinish(db, plan, attribution, ts, nonce));
  // D1 executes a batch atomically and sequentially. Every statement above
  // carries the SAME active-plan/version predicate, so after one contender
  // bumps the version a stale contender's entire batch becomes a no-op: no
  // transient inserts, remaps, or deletes can leak through before the final
  // compare-and-swap. This applies even when the caller omitted
  // expected_version; the version we actually read is always the CAS token.
  const results = await runWorkoutWriteBatch(db, stmts);
  const claimed = results[0];
  const documentUpdate = results[documentUpdateIndex];
  const versionUpdate = results[versionResultIndex];
  if ((claimed?.meta.changes ?? 0) !== 1 || (documentUpdate?.meta.changes ?? 0) !== 1 || !versionUpdate?.results[0]) {
    if (createsPlan && retryConcurrentBootstrap) {
      return updatePlanTree(db, userId, input, attribution, false);
    }
    const current = await getActivePlan(db, userId);
    return { conflict: true, current_version: current?.version ?? plan.version };
  }
  const acknowledgedVersion = plan.version + 1;
  const committedPlan = await readCommittedSnapshotPlan(db, plan, acknowledgedVersion, ts);
  if (!committedPlan) {
    return {
      conflict: false, acknowledged: true, refresh_required: true,
      plan_id: plan.id, version: acknowledgedVersion,
    };
  }
  return {
    conflict: false,
    plan: committedPlan,
  };
}

/** Find a template_exercise slot by id, or by (day + exercise name/id).
 *  When `workout_id` is supplied alongside `template_exercise_id`, the
 *  slot must live in THAT day: the nested REST route /days/:id/exercises/:teId
 *  claims a day in its path, so a /days/<dayA>/exercises/<slot-from-dayB>
 *  request must resolve to null (→ 404) rather than mutating day B's slot by
 *  the globally-unique teId alone. Day-less callers (the MCP tools, which have
 *  no URL day) omit it and resolve by teId + user as before. */
async function findSlot(
  db: D1Database,
  userId: string,
  ref: { template_exercise_id?: string; workout_id?: string; day?: string; exercise?: string },
): Promise<TemplateExerciseRow | null> {
  if (ref.template_exercise_id) {
    return workoutDB(db)
      .prepare(
        `SELECT te.* FROM template_exercises te
         JOIN workouts d ON d.id = te.workout_id
         JOIN plans p ON p.id = d.plan_id
         WHERE te.id = ?1 AND p.user_id = ?2
           AND (?3 IS NULL OR te.workout_id = ?3)`,
      )
      .bind(ref.template_exercise_id, userId, ref.workout_id ?? null)
      .first<TemplateExerciseRow>();
  }
  if (!ref.day || !ref.exercise) return null;
  const exId = await resolveOrThrow(db, ref.exercise);
  return workoutDB(db)
    .prepare(
      `SELECT te.* FROM template_exercises te
       JOIN workouts d ON d.id = te.workout_id
       JOIN plans p ON p.id = d.plan_id
       WHERE p.user_id = ?1 AND te.exercise_id = ?2 AND p.status = 'active'
         AND (d.day_label = ?3 OR d.name = ?3)`,
    )
    .bind(userId, exId, ref.day)
    .first<TemplateExerciseRow>();
}

/** Allowlist of patch keys accepted by `updateExercise`. Any unknown key
 *  in the incoming patch returns an explicit `unknown_fields` error
 *  instead of being silently dropped (the agent-facing diagnosability bug
 *  — `orderIndex` camelCase had returned 200 OK with no change). */
const TEMPLATE_EXERCISE_PATCH_KEYS = new Set<string>([
  'target_sets',
  'target_reps',
  'target_reps_max',
  'target_rpe',
  'rest_seconds',
  'target_weight',
  'target_duration_s',
  'cues',
  'progression',
  'order_index',
  'is_warmup',
]);

export async function updateExercise(
  db: D1Database,
  userId: string,
  ref: { template_exercise_id?: string; workout_id?: string; day?: string; exercise?: string },
  patch: Partial<
    Pick<
      TemplateExerciseRow,
      | 'target_sets'
      | 'target_reps'
      | 'target_reps_max'
      | 'target_rpe'
      | 'rest_seconds'
      | 'target_weight'
      | 'target_duration_s'
      | 'cues'
      | 'order_index'
      | 'is_warmup'
    >
  > & { progression?: unknown },
  attribution: PlanWriteAttribution = { actor: 'system', operation: 'update_exercise' },
  retryLegacyConflict = true,
): Promise<TemplateExerciseRow | PlanVersionConflict | { error: 'unknown_fields'; fields: string[] } | PrescriptionValidationError | GroupConflict | null> {
  const plan = await getActivePlan(db, userId);
  if (!plan) return null;
  // Slot lookup first so a wrong ref returns the more actionable
  // `slot_not_found` (via null) before unknown_fields. A double-mistake
  // call gets the higher-priority diagnostic.
  const slot = await findSlot(db, userId, ref);
  if (!slot) return null;
  const unknown = Object.keys(patch).filter((k) => !TEMPLATE_EXERCISE_PATCH_KEYS.has(k));
  if (unknown.length > 0) return { error: 'unknown_fields', fields: unknown };
  if (slot.group_id != null) {
    const owned = ['order_index', 'target_sets'].filter((key) => Object.prototype.hasOwnProperty.call(patch, key));
    if (owned.length) return { error: 'group_conflict', fields: owned };
  }
  const modality = await workoutDB(db).prepare('SELECT modality FROM exercises WHERE id=?1')
    .bind(slot.exercise_id).first<{ modality: string }>();
  const merged = {
    target_sets: patch.target_sets === undefined ? slot.target_sets : patch.target_sets,
    target_reps: patch.target_reps === undefined ? slot.target_reps : patch.target_reps,
    target_reps_max: patch.target_reps_max === undefined ? slot.target_reps_max : patch.target_reps_max,
    target_rpe: patch.target_rpe === undefined ? slot.target_rpe : patch.target_rpe,
    rest_seconds: patch.rest_seconds === undefined ? slot.rest_seconds : patch.rest_seconds,
    target_weight: patch.target_weight === undefined ? slot.target_weight : patch.target_weight,
    target_duration_s: patch.target_duration_s === undefined ? slot.target_duration_s : patch.target_duration_s,
    cues: patch.cues === undefined ? slot.cues : patch.cues,
    order_index: patch.order_index === undefined ? slot.order_index : patch.order_index,
    is_warmup: patch.is_warmup === undefined ? slot.is_warmup : patch.is_warmup,
    progression: patch.progression === undefined
      ? (slot.progression === null ? null : JSON.parse(slot.progression) as unknown)
      : patch.progression,
  };
  const invalid = validateExercisePrescription(merged as Record<string, unknown>, { modality: modality?.modality });
  if (invalid) return invalid;
  const groupSiblings = await exerciseGroupDayRows(db, slot.workout_id);
  const groupMoved = groupSiblings.map((row) => row.id === slot.id ? { ...row, ...merged } : row);
  const groupHasDuplicate = new Set(groupMoved.map((row) => row.order_index)).size !== groupMoved.length;
  const groupOrdered = patch.order_index !== undefined && groupHasDuplicate
    ? orderDayRows(groupMoved, slot.id).map((row, index) => ({ ...row, order_index: index })) : groupMoved;
  const groupInvalid = validateExerciseGroups(groupOrdered);
  if (groupInvalid) return groupInvalid;
  if (Object.keys(patch).length === 0) return slot;

  // Update only fields supplied by the caller. This bounded legacy policy lets
  // disjoint tokenless patches compose; concurrent same-field patches remain
  // last-committer-wins until every released caller supplies expected_version.
  const assignments: string[] = [];
  const values: unknown[] = [slot.id];
  const assign = (column: string, value: unknown) => {
    values.push(value);
    assignments.push(`${column}=?${values.length}`);
  };
  for (const key of TEMPLATE_EXERCISE_PATCH_KEYS) {
    if (!Object.prototype.hasOwnProperty.call(patch, key)) continue;
    const value = key === 'progression'
      ? (patch.progression == null ? null : JSON.stringify(patch.progression))
      : key === 'is_warmup'
        ? (patch.is_warmup ? 1 : 0)
        : (patch as Record<string, unknown>)[key];
    assign(key, value);
  }
  const ts = now();
  assign('updated_at', ts);
  values.push(userId);
  const userParam = values.length;
  const rangePredicates: string[] = [];
  if (patch.target_reps !== undefined && patch.target_reps_max === undefined) {
    values.push(patch.target_reps);
    rangePredicates.push(`(target_reps_max IS NULL OR target_reps_max>=?${values.length})`);
  }
  if (patch.target_reps_max !== undefined && patch.target_reps_max !== null && patch.target_reps === undefined) {
    values.push(patch.target_reps_max);
    rangePredicates.push(`target_reps<=?${values.length}`);
  }
  const nonce = uuid();
  const statements: D1PreparedStatement[] = [
    ...preparePlanWriteStart(db, plan, attribution, ts, nonce),
    workoutDB(db).prepare(
      `UPDATE template_exercises SET ${assignments.join(',')}
        WHERE id=?1 AND EXISTS (
          SELECT 1 FROM workouts d JOIN plans p ON p.id=d.plan_id
           WHERE d.id=template_exercises.workout_id
             AND p.user_id=?${userParam} AND p.status='active'
             AND p.id='${plan.id}' AND p.version=-${plan.version}
             AND p.plan_write_nonce='${nonce}'
        )${rangePredicates.length ? ` AND ${rangePredicates.join(' AND ')}` : ''}`,
    ).bind(...values),
  ];
  let acknowledgedOrder = patch.order_index ?? slot.order_index;
  if (patch.order_index !== undefined) {
    const siblings = await workoutDB(db).prepare(
      'SELECT id,order_index FROM template_exercises WHERE workout_id=?1 ORDER BY order_index,created_at,id',
    ).bind(slot.workout_id).all<{ id: string; order_index: number }>();
    const moved = siblings.results.map((row) => row.id === slot.id ? { ...row, order_index: patch.order_index! } : row);
    const hasDuplicate = new Set(moved.map((row) => row.order_index)).size !== moved.length;
    if (hasDuplicate) {
      const ordered = orderDayRows(moved, slot.id);
      acknowledgedOrder = ordered.findIndex((row) => row.id === slot.id);
      ordered.forEach((row, index) => statements.push(
        workoutDB(db).prepare(`UPDATE template_exercises SET order_index=?2,updated_at=?3 WHERE id=?1
          AND EXISTS (SELECT 1 FROM workouts d JOIN plans p ON p.id=d.plan_id
            JOIN template_exercises te ON te.workout_id=d.id
            WHERE te.id=?4 AND p.id='${plan.id}' AND p.version=-${plan.version}
              AND p.plan_write_nonce='${nonce}')`).bind(row.id, index, ts, slot.id),
      ));
    }
  }
  const versionResultIndex = statements.length;
  statements.push(...preparePlanWriteFinish(db, plan, attribution, ts, nonce));
  const results = await runWorkoutWriteBatch<{ version: number }>(db, statements);
  if ((results[0]?.meta.changes ?? 0) !== 1) {
    if (retryLegacyConflict) {
      return updateExercise(db, userId, ref, patch, attribution, false);
    }
    return currentPlanVersion(db, userId, plan.version);
  }
  if ((results[2]?.meta.changes ?? 0) !== 1 || !results[versionResultIndex]?.results[0]) {
    const current = await findSlot(db, userId, ref);
    if (current && (patch.target_reps !== undefined || patch.target_reps_max !== undefined)) {
      return { error: 'invalid_fields', fields: ['target_reps_max'] };
    }
    return null;
  }
  return {
    ...slot,
    ...merged,
    progression: merged.progression == null ? null : JSON.stringify(merged.progression),
    is_warmup: merged.is_warmup ? 1 : 0,
    order_index: acknowledgedOrder,
    updated_at: ts,
  };
}

/**
 * Delete an exercise slot from a day. Resolves the slot by id or by
 * `(day, exercise)` — same ref shape as updateExercise. NULLs any
 * `set_logs.template_exercise_id` that pointed at this slot so historical
 * sets are detached (not deleted — they stay queryable by exercise_id).
 * Bumps the plan version (it's a plan-tree mutation). Returns the deleted
 * row or null when no slot matches.
 */
export async function deleteTemplateExercise(
  db: D1Database,
  userId: string,
  ref: { template_exercise_id?: string; workout_id?: string; day?: string; exercise?: string },
  attribution: PlanWriteAttribution = { actor: 'system', operation: 'delete_exercise' },
  retryLegacyConflict = true,
): Promise<TemplateExerciseRow | GroupConflict | null> {
  const plan = await getActivePlan(db, userId);
  if (!plan) return null;
  const slot = await findSlot(db, userId, ref);
  if (!slot) return null;
  const siblings = await exerciseGroupDayRows(db, slot.workout_id);
  const remaining = normalizeRemovedGroupMember(siblings.filter((row) => row.id !== slot.id), slot.group_id);
  const groupInvalid = validateExerciseGroups(remaining);
  if (groupInvalid) return groupInvalid;
  const normalized = remaining.filter((row) => row.group_id == null && siblings.find((old) => old.id === row.id)?.group_id != null);
  const ts = now();
  const nonce = uuid();
  const statements: D1PreparedStatement[] = [
      ...preparePlanWriteStart(db, plan, attribution, ts, nonce),
      workoutDB(db)
        .prepare(
          `UPDATE set_logs
              SET template_exercise_id = NULL,
                  updated_at = MAX(updated_at + 1, ?2)
            WHERE template_exercise_id = ?1
              AND EXISTS (SELECT 1 FROM plans WHERE id=?3 AND user_id=?4 AND version=-?5 AND plan_write_nonce=?6)`,
        )
        .bind(slot.id, ts, plan.id, userId, plan.version, nonce),
      workoutDB(db).prepare(
        `DELETE FROM template_exercises WHERE id=?1 AND EXISTS
         (SELECT 1 FROM plans WHERE id=?2 AND user_id=?3 AND version=-?4 AND plan_write_nonce=?5)`,
      ).bind(slot.id, plan.id, userId, plan.version, nonce),
  ];
  for (const row of normalized) statements.push(workoutDB(db).prepare(
    `UPDATE template_exercises SET group_id=NULL,group_rest_seconds=NULL,group_transition_seconds=NULL,
       updated_at=?2 WHERE id=?1 AND EXISTS
       (SELECT 1 FROM plans WHERE id=?3 AND user_id=?4 AND version=-?5 AND plan_write_nonce=?6)`,
  ).bind(row.id, ts, plan.id, userId, plan.version, nonce));
  const versionResultIndex = statements.length;
  statements.push(...preparePlanWriteFinish(db, plan, attribution, ts, nonce));
  const results = await runWorkoutWriteBatch<{ version: number }>(db, statements);
  if ((results[0]?.meta.changes ?? 0) !== 1) {
    return retryLegacyConflict
      ? deleteTemplateExercise(db, userId, ref, attribution, false)
      : null;
  }
  if ((results[3]?.meta.changes ?? 0) !== 1 || !results[versionResultIndex]?.results[0]) return null;
  return slot;
}

export async function swapExercise(
  db: D1Database,
  userId: string,
  ref: {
    template_exercise_id?: string; workout_id?: string;
    day?: string; from_exercise?: string; to_exercise: string;
    expected_version?: number;
  },
  attribution: PlanWriteAttribution = { actor: 'system', operation: 'swap_exercise' },
  retryLegacyConflict = true,
): Promise<TemplateExerciseRow | PlanVersionConflict | PrescriptionValidationError | GroupConflict | null> {
  const plan = await getActivePlan(db, userId);
  if (!plan) return null;
  const slot = await findSlot(db, userId, { ...ref, exercise: ref.from_exercise });
  if (!slot || !await getWorkoutInPlan(db, plan.id, slot.workout_id)) return null;
  if (ref.expected_version !== undefined) {
    if (!Number.isSafeInteger(ref.expected_version) || ref.expected_version < 1) {
      return { error: 'invalid_fields', fields: ['expected_version'] };
    }
    if (ref.expected_version !== plan.version) {
      return { conflict: true, current_version: plan.version };
    }
  }
  if (typeof ref.to_exercise !== 'string' || !ref.to_exercise.trim()) {
    return { error: 'invalid_fields', fields: ['to_exercise'] };
  }
  const destination = await resolveExercise(db, ref.to_exercise) as { id: string; modality: string } | null;
  if (!destination) return { error: 'invalid_fields', fields: ['to_exercise'] };
  const progression = slot.progression === null ? null : JSON.parse(slot.progression) as unknown;
  const invalid = validateExercisePrescription({ ...slot, progression }, { modality: destination.modality });
  if (invalid) return invalid;
  const groupInvalid = validateExerciseGroups(await exerciseGroupDayRows(db, slot.workout_id));
  if (groupInvalid) return groupInvalid;
  // A replacement always preserves the saved prescription and slot identity.
  // Historical logs retain their original exercise_id and values.
  const ts = now();
  const nonce = uuid();
  const statements: D1PreparedStatement[] = [
    ...preparePlanWriteStart(db, plan, attribution, ts, nonce),
    workoutDB(db).prepare(
      `UPDATE template_exercises SET exercise_id=?2,updated_at=?3 WHERE id=?1
        AND EXISTS (
          SELECT 1 FROM workouts d JOIN plans p ON p.id=d.plan_id
           WHERE d.id=template_exercises.workout_id AND p.user_id=?4 AND p.status='active'
             AND p.id=?5 AND p.version=-?6 AND p.plan_write_nonce=?7
        )`,
    ).bind(slot.id, destination.id, ts, userId, plan.id, plan.version, nonce),
  ];
  const versionResultIndex = statements.length;
  statements.push(...preparePlanWriteFinish(db, plan, attribution, ts, nonce));
  const results = await runWorkoutWriteBatch<{ version: number }>(db, statements);
  if ((results[0]?.meta.changes ?? 0) !== 1) {
    return ref.expected_version === undefined && retryLegacyConflict
      ? swapExercise(db, userId, ref, attribution, false)
      : currentPlanVersion(db, userId, plan.version);
  }
  if ((results[2]?.meta.changes ?? 0) !== 1 || !results[versionResultIndex]?.results[0]) return null;
  return { ...slot, exercise_id: destination.id, updated_at: ts };
}

async function bumpPlanVersionByDay(db: D1Database, workoutId: string): Promise<void> {
  const row = await workoutDB(db)
    .prepare('SELECT plan_id FROM workouts WHERE id = ?1')
    .bind(workoutId)
    .first<{ plan_id: string }>();
  if (row) await bumpPlanVersion(db, row.plan_id);
}

export async function logWorkoutComplete(
  db: D1Database,
  userId: string,
  date: string,
  perceivedFatigue: number | null,
  notes: string | null,
): Promise<
  | Awaited<ReturnType<typeof patchSession>>
  | { error: 'session_discarded'; status: 'discarded' }
> {
  const plan = await getActivePlan(db, userId);
  if (!plan) return null;
  const session = await getOrCreateSession(
    db,
    userId,
    plan.id,
    date,
    null,
    { reviveDiscarded: false },
  );
  if (session.status === 'discarded') {
    return { error: 'session_discarded', status: 'discarded' };
  }
  // Carry the generation observed above across this await. A discard/restart
  // in between returns a structured conflict instead of retargeting completion
  // to the newer workout.
  return patchSession(
    db,
    userId,
    session.id,
    {
      status: 'completed',
      perceived_fatigue: perceivedFatigue ?? undefined,
      notes: notes ?? undefined,
    },
    session.attempt,
  );
}

/** "I'm beat — adjust." Scales target day(s) and records the reasoning. */
export async function adjustToday(
  db: D1Database,
  userId: string,
  intent: 'deload' | 'reduce_volume' | 'reduce_intensity',
  magnitude: 'light' | 'moderate' | 'heavy' = 'moderate',
  dayLabel?: string,
  attribution: PlanWriteAttribution = { actor: 'system', operation: 'adjust_today' },
): Promise<{
  plan: PlanTree | null;
  changes: string[];
  recurring: true;
  affected_workouts: string[];
  no_op: boolean;
  acknowledged?: true;
  refresh_required?: true;
  version?: number;
  conflict?: true;
  current_version?: number;
  error?: 'invalid_fields' | 'group_conflict';
  fields?: string[];
}> {
  if (!['deload', 'reduce_volume', 'reduce_intensity'].includes(intent)
      || !['light', 'moderate', 'heavy'].includes(magnitude)) {
    throw new Error('invalid_adjustment');
  }
  const tree = await getPlanTree(db, userId);
  if (!tree) return { plan: null, changes: [], recurring: true, affected_workouts: [], no_op: true };
  const setF = { light: 0.8, moderate: 0.65, heavy: 0.5 }[magnitude];
  const wtF = { light: 0.95, moderate: 0.9, heavy: 0.85 }[magnitude];
  const days = dayLabel
    ? tree.workouts.filter((d) => d.day_label === dayLabel || d.name === dayLabel)
    : tree.workouts;
  const invalidFields = new Set<string>();
  for (const day of days) for (const slot of day.exercises) {
    let progression: unknown = null;
    try { progression = slot.progression == null ? null : JSON.parse(slot.progression); }
    catch { invalidFields.add(`${day.day_label ?? day.name}/${slot.exercise_name}.progression`); }
    const invalid = validateExercisePrescription({ ...slot, progression }, {
      modality: slot.exercise_modality,
    });
    for (const field of invalid?.fields ?? []) {
      invalidFields.add(`${day.day_label ?? day.name}/${slot.exercise_name}.${field}`);
    }
  }
  if (invalidFields.size > 0) {
    return {
      error: 'invalid_fields', fields: [...invalidFields].sort(), plan: tree,
      changes: [], recurring: true,
      affected_workouts: days.map((day) => day.day_label ?? day.name), no_op: true,
    };
  }
  const groupInvalid = validatePlanExerciseGroups(days.map((day) => ({ exercises: day.exercises.map((slot) => ({
    ...slot, target_sets: intent === 'reduce_intensity' ? slot.target_sets : Math.max(1, Math.round(slot.target_sets * setF)),
  })) })));
  if (groupInvalid) return { ...groupInvalid, plan: tree, changes: [], recurring: true,
    affected_workouts: days.map((day) => day.day_label ?? day.name), no_op: true };
  const changes: string[] = [];
  const computedInvalid = new Set<string>();
  const ts = now();
  const nonce = uuid();
  const stmts: D1PreparedStatement[] = [
    ...preparePlanWriteStart(db, tree, attribution, ts, nonce),
  ];
  for (const d of days) {
    for (const te of d.exercises) {
      if (intent === 'reduce_intensity') {
        if (te.target_weight == null) continue;
        // Positive added load gets lighter. Negative load is assistance, so
        // reducing intensity must increase its magnitude rather than move it
        // toward zero and accidentally make the exercise harder.
        const assisted = te.target_weight < 0;
        const scaled = assisted ? te.target_weight / wtF : te.target_weight * wtF;
        const rounded = Math.round(scaled / 5) * 5;
        // Keep the existing five-pound convention when it increases
        // assistance, but never let a small negative value round to zero.
        const w = Math.min(te.target_weight, rounded);
        if (w === te.target_weight) continue;
        const invalid = validateExercisePrescription({
          ...te, target_weight: w,
          progression: te.progression == null ? null : JSON.parse(te.progression),
        }, { modality: te.exercise_modality });
        if (invalid) {
          for (const field of invalid.fields) {
            computedInvalid.add(`${d.day_label ?? d.name}/${te.exercise_name}.${field}`);
          }
          continue;
        }
        stmts.push(
          workoutDB(db)
            .prepare(`UPDATE template_exercises SET target_weight=?2, updated_at=?3 WHERE id=?1
              AND EXISTS (SELECT 1 FROM plans WHERE id=?4 AND user_id=?5 AND version=-?6 AND plan_write_nonce=?7)`)
            .bind(te.id, w, ts, tree.id, userId, tree.version, nonce),
        );
        changes.push(`${d.day_label ?? d.name}/${te.exercise_name}: weight ${te.target_weight}→${w}`);
      } else {
        const s = Math.max(1, Math.round(te.target_sets * setF));
        if (s === te.target_sets) continue;
        const invalid = validateExercisePrescription({
          ...te, target_sets: s,
          progression: te.progression == null ? null : JSON.parse(te.progression),
        }, { modality: te.exercise_modality });
        if (invalid) {
          for (const field of invalid.fields) {
            computedInvalid.add(`${d.day_label ?? d.name}/${te.exercise_name}.${field}`);
          }
          continue;
        }
        stmts.push(
          workoutDB(db)
            .prepare(`UPDATE template_exercises SET target_sets=?2, updated_at=?3 WHERE id=?1
              AND EXISTS (SELECT 1 FROM plans WHERE id=?4 AND user_id=?5 AND version=-?6 AND plan_write_nonce=?7)`)
            .bind(te.id, s, ts, tree.id, userId, tree.version, nonce),
        );
        changes.push(`${d.day_label ?? d.name}/${te.exercise_name}: sets ${te.target_sets}→${s}`);
      }
    }
  }
  if (computedInvalid.size > 0) {
    return {
      error: 'invalid_fields', fields: [...computedInvalid].sort(), plan: tree,
      changes: [], recurring: true,
      affected_workouts: days.map((day) => day.day_label ?? day.name), no_op: true,
    };
  }
  if (changes.length) {
    const versionResultIndex = stmts.length;
    const workouts = days.map((day) => day.day_label ?? day.name).join(', ');
    const detail = `Recurring templates (${workouts}): ${changes.length} change(s): ${changes.join('; ')}`;
    stmts.push(...preparePlanWriteFinish(db, tree, {
      ...attribution,
      note: attribution.note ? `${attribution.note} ${detail}` : detail,
    }, ts, nonce));
    const results = await runWorkoutWriteBatch<{ version: number }>(db, stmts);
    if ((results[0]?.meta.changes ?? 0) !== 1 || !results[versionResultIndex]?.results[0]) {
      const current = await getActivePlan(db, userId);
      return {
        conflict: true, current_version: current?.version ?? tree.version,
        plan: null, changes: [], recurring: true,
        affected_workouts: days.map((day) => day.day_label ?? day.name), no_op: false,
      };
    }
    const committedVersion = tree.version + 1;
    const committedPlan = await readCommittedSnapshotPlan(db, tree, committedVersion, ts);
    if (!committedPlan) {
      return {
        plan: null, changes, recurring: true,
        affected_workouts: days.map((day) => day.day_label ?? day.name), no_op: false,
        acknowledged: true, refresh_required: true, version: committedVersion,
      };
    }
    return {
      plan: committedPlan,
      changes, recurring: true,
      affected_workouts: days.map((day) => day.day_label ?? day.name), no_op: false,
    };
  }
  return {
    plan: tree,
    changes,
    recurring: true,
    affected_workouts: days.map((day) => day.day_label ?? day.name),
    no_op: changes.length === 0,
  };
}

export async function getHistory(
  db: D1Database,
  userId: string,
  exerciseId: string,
  from: number,
  to: number,
) {
  const exercise =
    (await workoutDB(db)
      .prepare('SELECT modality, unit, laterality, load_mode FROM exercises WHERE id = ?1')
      .bind(exerciseId)
      .first<MetricExercise>()) ?? {
      modality: 'unknown',
      unit: 'lb',
      laterality: 'bilateral',
      load_mode: 'total',
    };
  const sets = await workoutDB(db)
    .prepare(
      `SELECT sl.*, s.date as session_date, s.notes AS session_notes,
         s.perceived_fatigue AS session_perceived_fatigue FROM set_logs sl
       JOIN sessions s ON s.id = sl.session_id
       WHERE sl.user_id = ?1 AND s.user_id = ?1
         AND sl.exercise_id = ?2 AND sl.deleted_at IS NULL
         AND sl.is_warmup = 0 AND sl.logged_at BETWEEN ?3 AND ?4
       ORDER BY sl.logged_at`,
    )
    .bind(userId, exerciseId, from, to)
    .all<SetLogRow & { session_date: string; session_notes: string | null; session_perceived_fatigue: number | null }>();
  const rowsBySession = new Map<string, (typeof sets.results)>();
  for (const s of sets.results) {
    const rows = rowsBySession.get(s.session_date) ?? [];
    rows.push(s);
    rowsBySession.set(s.session_date, rows);
  }

  const bySession = [...rowsBySession].map(([date, rows]) => {
    const cohorts = metricCohorts(rows, exercise);
    const repCohorts = cohorts.filter((cohort) => !cohort.is_timed);
    const timedCohorts = cohorts.filter((cohort) => cohort.is_timed);
    const estimated = rows.filter((row) => estimatedOneRepMax(row, exercise) != null);
    const estimatedTop = estimated.length ? estimated.reduce((best, row) =>
      estimatedOneRepMax(row, exercise)! > estimatedOneRepMax(best, exercise)! ? row : best) : null;
    // Preserve conventional Epley summaries. Incompatible BW/hold conditions
    // have no overall winner; callers use the explicitly keyed cohorts.
    const top = cohorts.length === 1 ? cohorts[0]!.top : estimatedTop;
    const tonnages = rows.map((row) => positiveSetTonnage(row, exercise))
      .filter((value): value is number => value != null);
    return {
      date, top,
      notes: rows[0]!.session_notes,
      perceived_fatigue: rows[0]!.session_perceived_fatigue,
      metric: top == null ? 'mixed' : estimatedTop ? 'load' : cohorts[0]!.metric,
      est_1rm: estimatedTop ? estimatedOneRepMax(estimatedTop, exercise) : null,
      best_reps: exercise.modality === 'bw' && repCohorts.length === 1
        ? repCohorts[0]!.best_reps : null,
      total_reps: exercise.modality === 'bw'
        ? repCohorts.reduce((sum, cohort) => sum + (cohort.total_reps ?? 0), 0) : null,
      best_duration_s: timedCohorts.length === 1 ? timedCohorts[0]!.best_duration_s : null,
      tonnage: tonnages.length ? tonnages.reduce((a, b) => a + b, 0) : null,
      tonnage_basis: 'external_load',
      cohorts,
    };
  });
  return {
    exercise_id: exerciseId,
    sets: sets.results,
    by_session: bySession.sort((a, b) => a.date.localeCompare(b.date)),
  };
}

export async function getVolume(
  db: D1Database, userId: string, muscle: string, from: number, to: number,
) {
  const normalizedMuscle = muscle.trim().toLowerCase();
  const known = await workoutDB(db)
    .prepare('SELECT 1 FROM exercises WHERE lower(primary_muscle) = ?1 LIMIT 1')
    .bind(normalizedMuscle).first();
  if (!known) return { error: 'unknown_muscle' as const, query: muscle };
  const rows = await workoutDB(db).prepare(
    `SELECT strftime('%Y-%W', s.date) AS week, e.unit,
            COUNT(*) AS logged_working_sets, COUNT(sl.rpe) AS sets_with_effort,
            SUM(CASE WHEN sl.weight > 0 AND sl.is_timed = 0 AND e.unit != 'sec' AND e.modality != 'cardio'
                     THEN sl.weight * sl.reps
                       * CASE WHEN e.laterality = 'unilateral' THEN 2 ELSE 1 END
                       * CASE WHEN e.load_mode = 'per_hand' THEN 2 ELSE 1 END
                     ELSE NULL END) AS external_load_volume,
            SUM(CASE WHEN sl.weight > 0 AND sl.is_timed = 0 AND e.unit != 'sec' AND e.modality != 'cardio' THEN 1 ELSE 0 END) AS contributing_sets
     FROM set_logs sl JOIN sessions s ON s.id = sl.session_id
     JOIN exercises e ON e.id = sl.exercise_id
     WHERE s.user_id = ?1 AND lower(e.primary_muscle) = ?2 AND sl.deleted_at IS NULL
       AND s.status != 'discarded' AND sl.is_warmup = 0 AND sl.logged_at BETWEEN ?3 AND ?4
     GROUP BY week, e.unit ORDER BY week, e.unit`,
  ).bind(userId, normalizedMuscle, from, to).all<{
    week: string; unit: string; logged_working_sets: number; sets_with_effort: number;
    external_load_volume: number | null; contributing_sets: number;
  }>();
  const weeks = [...new Set(rows.results.map(row => row.week))];
  return {
    muscle_group: normalizedMuscle, muscle_attribution: 'primary_muscle_only' as const,
    set_count_basis: 'logged_non_warmup_sets' as const,
    hard_sets_meaning: 'Legacy alias of logged_working_sets; effort is not required. Not measured stimulus or complete muscle volume.',
    tonnage_basis: 'external_load' as const,
    buckets: weeks.map(week => {
      const group = rows.results.filter(row => row.week === week);
      const count = group.reduce((n, row) => n + row.logged_working_sets, 0);
      const byUnit = group.filter(row => row.external_load_volume != null).map(row => ({
        unit: row.unit, value: row.external_load_volume!, contributing_sets: row.contributing_sets,
      }));
      return { week, hard_sets: count, logged_working_sets: count,
        sets_with_effort: group.reduce((n, row) => n + row.sets_with_effort, 0),
        external_load_volume: byUnit,
        // A legacy scalar is valid only for one known unit; never sum lb and kg.
        tonnage: byUnit.length === 1 ? byUnit[0]!.value : null,
        unit: byUnit.length === 1 ? byUnit[0]!.unit : null };
    }),
  };
}

// ---- weekly schedule + future-calendar projection ------------------------
//
// The recurring pattern lives in plans.meta JSON (frozen contract, see
// migrations/0005). Schedule edits are plan-tree mutations: they bump
// plans.version and use optimistic concurrency. The one-off planned/skip
// session writes are append-only sessions rows and do NOT bump version.

/**
 * Calendar weekday rule (iOS MUST mirror this byte-for-byte):
 * parse the device-local 'YYYY-MM-DD' string as a proleptic Gregorian date,
 * compute days since the fixed Monday epoch 1970-01-05 using integer day
 * arithmetic (NOT a UTC Date offset, NOT timezone-aware), and index
 * WEEKDAYS = [mon,tue,wed,thu,fri,sat,sun]. 1970-01-05 was a Monday, so
 * ((daysSinceEpoch % 7) + 7) % 7 gives 0=mon ... 6=sun.
 */
function dayNumber(ymd: string): number {
  const parts = ymd.split('-');
  const y = Number(parts[0]);
  const m = Number(parts[1]);
  const d = Number(parts[2]);
  // Days from 1970-01-01 via a pure civil-from-date algorithm (Howard
  // Hinnant's days_from_civil) — no Date object, no UTC, no DST.
  const yy = m <= 2 ? y - 1 : y;
  const era = Math.floor((yy >= 0 ? yy : yy - 399) / 400);
  const yoe = yy - era * 400;
  const doy = Math.floor((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5) + d - 1;
  const doe = yoe * 365 + Math.floor(yoe / 4) - Math.floor(yoe / 100) + doy;
  return era * 146097 + doe - 719468; // days since 1970-01-01
}

/** 'YYYY-MM-DD' -> weekday key, via the calendar rule above (1970-01-05=Mon). */
export function weekdayOf(ymd: string): Weekday {
  const days = dayNumber(ymd) - 4; // 1970-01-05 (Monday) is day 4
  const idx = ((days % 7) + 7) % 7;
  return WEEKDAYS[idx]!;
}

/** Inclusive day count between two 'YYYY-MM-DD' strings (calendar, not UTC). */
function daySpan(from: string, to: string): number {
  return dayNumber(to) - dayNumber(from);
}

/** Add n days to a 'YYYY-MM-DD' string, returning 'YYYY-MM-DD'. */
export function addDays(ymd: string, n: number): string {
  // Civil-from-days inverse of dayNumber (Hinnant), pure integer math.
  let z = dayNumber(ymd) + n + 719468;
  const era = Math.floor((z >= 0 ? z : z - 146096) / 146097);
  const doe = z - era * 146097;
  const yoe = Math.floor(
    (doe - Math.floor(doe / 1460) + Math.floor(doe / 36524) - Math.floor(doe / 146096)) / 365,
  );
  const y = yoe + era * 400;
  const doy = doe - (365 * yoe + Math.floor(yoe / 4) - Math.floor(yoe / 100));
  const mp = Math.floor((5 * doy + 2) / 153);
  const d = doy - Math.floor((153 * mp + 2) / 5) + 1;
  const m = mp < 10 ? mp + 3 : mp - 9;
  const yr = m <= 2 ? y + 1 : y;
  const pad = (x: number, w = 2) => String(x).padStart(w, '0');
  return `${pad(yr, 4)}-${pad(m)}-${pad(d)}`;
}

export async function getPlanSchedule(
  db: D1Database,
  userId: string,
): Promise<{ plan: PlanRow; schedule: WeeklySchedule } | null> {
  const plan = await getActivePlan(db, userId);
  if (!plan) return null;
  return { plan, schedule: parsePlanMeta(plan.meta).schedule };
}

/**
 * Replace the full weekly map. Resolves each value (id, day_label, or day
 * name) to a workout_id belonging to the active plan; rejects any ref
 * that doesn't resolve to a day in THIS plan (no partial write). Optimistic
 * concurrency on expected_version. Bumps plans.version on success.
 */
export async function setPlanSchedule(
  db: D1Database,
  userId: string,
  weekInput: Partial<Record<Weekday, string | null>>,
  expectedVersion?: number | null,
  expectedPlanId?: string | null,
  attribution: PlanWriteAttribution = { actor: 'system', operation: 'set_schedule' },
): Promise<
  | { conflict: true; current_plan_id: string; current_version: number }
  | { error: 'no_active_plan' }
  | { error: 'unknown_day_ref'; ref: string }
  | { ok: true; plan: PlanRow; schedule: WeeklySchedule; version: number }
> {
  const plan = await getActivePlan(db, userId);
  if (!plan) return { error: 'no_active_plan' };
  if (expectedPlanId != null && expectedPlanId !== plan.id) {
    return {
      conflict: true,
      current_plan_id: plan.id,
      current_version: plan.version,
    };
  }
  if (expectedVersion != null && expectedVersion !== plan.version) {
    return {
      conflict: true,
      current_plan_id: plan.id,
      current_version: plan.version,
    };
  }
  const days = await workoutDB(db)
    .prepare('SELECT id, name, day_label FROM workouts WHERE plan_id = ?1')
    .bind(plan.id)
    .all<{ id: string; name: string; day_label: string | null }>();
  // Build resolution maps; id wins, then exact day_label, then exact name.
  const byId = new Map(days.results.map((d) => [d.id, d.id]));
  const byLabel = new Map<string, string>();
  const byName = new Map<string, string>();
  for (const d of days.results) {
    if (d.day_label) byLabel.set(d.day_label.toLowerCase(), d.id);
    byName.set(d.name.toLowerCase(), d.id);
  }
  const resolved: ScheduleWeek = {
    mon: null, tue: null, wed: null, thu: null, fri: null, sat: null, sun: null,
  };
  for (const wd of WEEKDAYS) {
    const ref = weekInput[wd];
    if (ref == null || ref === '') {
      resolved[wd] = null;
      continue;
    }
    const id =
      byId.get(ref) ?? byLabel.get(ref.toLowerCase()) ?? byName.get(ref.toLowerCase());
    if (!id) return { error: 'unknown_day_ref', ref };
    resolved[wd] = id;
  }
  const meta = parsePlanMeta(plan.meta);
  // schedule.version is a monotonic change counter for the schedule itself
  // (distinct from plans.version): bump it on every successful write so
  // clients can detect a schedule change without diffing the full week map.
  const schedule: WeeklySchedule = {
    version: meta.schedule.version + 1,
    week: resolved,
  };
  const ts = now();
  // Gate on the read version (write-time optimistic concurrency) — same as
  // writePlanMeta; a concurrent plan write → no row updated → 409.
  const nonce = uuid();
  const statements = preparePlanWriteStart(db, plan, attribution, ts, nonce);
  statements.push(workoutDB(db).prepare(
    `UPDATE plans SET meta=?2,updated_at=?3
      WHERE id=?1 AND version=-?4 AND user_id=?5 AND status='active' AND plan_write_nonce=?6`,
  ).bind(plan.id, serializePlanMeta(meta, schedule), ts, plan.version, userId, nonce));
  const versionResultIndex = statements.length;
  statements.push(...preparePlanWriteFinish(db, plan, attribution, ts, nonce));
  const results = await runWorkoutWriteBatch<{ version: number }>(db, statements);
  const row = results[versionResultIndex]?.results[0];
  if ((results[0]?.meta.changes ?? 0) !== 1 || (results[2]?.meta.changes ?? 0) !== 1 || !row) {
    const cur = await getActivePlan(db, userId);
    return {
      conflict: true,
      current_plan_id: cur?.id ?? plan.id,
      current_version: cur?.version ?? plan.version,
    };
  }
  return {
    ok: true,
    plan: { ...plan, version: row.version, updated_at: ts },
    schedule,
    version: row.version,
  };
}

// ---- authored-intent plan meta (race / periodization / trips / stress) ----
// These ride the SAME versioned-document path as the weekly schedule
// (docs/MULTISPORT.md §3-4): optimistic concurrency on plans.version, a single
// UPDATE that bumps the version, and audit+note written by the MCP dispatch
// layer. No new tables, no projection change — store authored truth in
// plans.meta; the calendar derives from it later.

const YMD = /^\d{4}-\d{2}-\d{2}$/;

type PlanMetaWrite =
  | { conflict: true; current_version: number }
  | { error: string }
  | { ok: true; version: number; meta: PlanMeta };

/**
 * Shared optimistic-concurrency writer for the authored-intent fields in
 * plans.meta. Mirrors setPlanSchedule exactly. `mutate` edits the parsed meta
 * in place; returning a string aborts the write with that error code (no
 * partial write, no version bump).
 */
async function writePlanMeta(
  db: D1Database,
  userId: string,
  expectedVersion: number | null | undefined,
  mutate: (meta: PlanMeta) => string | void,
  attribution: PlanWriteAttribution,
): Promise<PlanMetaWrite> {
  const plan = await getActivePlan(db, userId);
  if (!plan) return { error: 'no_active_plan' };
  if (expectedVersion != null && expectedVersion !== plan.version) {
    return { conflict: true, current_version: plan.version };
  }
  const meta = parsePlanMeta(plan.meta);
  const err = mutate(meta);
  if (typeof err === 'string') return { error: err };
  const ts = now();
  // Enforce optimistic concurrency at WRITE time, not just the pre-check: gate
  // the UPDATE on the version we read, so two concurrent meta writes off the
  // same get_current_plan (e.g. set_race + add_trip) can't both pass and let
  // the later one serialize a stale copy, silently dropping the other's
  // changes. No row updated → another writer won → 409 (caller refetches).
  const nonce = uuid();
  const statements = preparePlanWriteStart(db, plan, attribution, ts, nonce);
  statements.push(workoutDB(db).prepare(
    `UPDATE plans SET meta=?2,updated_at=?3
      WHERE id=?1 AND version=-?4 AND user_id=?5 AND plan_write_nonce=?6`,
  ).bind(plan.id, serializePlanMeta(meta, meta.schedule), ts, plan.version, userId, nonce));
  const versionResultIndex = statements.length;
  statements.push(...preparePlanWriteFinish(db, plan, attribution, ts, nonce));
  const results = await runWorkoutWriteBatch<{ version: number }>(db, statements);
  const row = results[versionResultIndex]?.results[0];
  if ((results[0]?.meta.changes ?? 0) !== 1 || (results[2]?.meta.changes ?? 0) !== 1 || !row) {
    const cur = await getActivePlan(db, userId);
    return { conflict: true, current_version: cur?.version ?? plan.version };
  }
  return { ok: true, version: row.version, meta };
}

/** Set the goal A-race. Replaces any existing race. */
export async function setRace(
  db: D1Database,
  userId: string,
  race: RaceGoal,
  expectedVersion?: number | null,
  attribution: PlanWriteAttribution = { actor: 'system', operation: 'set_race' },
) {
  if (!YMD.test(race.date)) return { error: 'invalid_date' as const };
  const res = await writePlanMeta(db, userId, expectedVersion, (meta) => {
    meta.race = race;
  }, attribution);
  return 'ok' in res
    ? { ok: true as const, version: res.version, race: res.meta.race ?? null }
    : res;
}

/** Replace the periodization plan (full ordered phase array). */
export async function setPeriodization(
  db: D1Database,
  userId: string,
  phases: PeriodizationPhase[],
  expectedVersion?: number | null,
  attribution: PlanWriteAttribution = { actor: 'system', operation: 'set_periodization' },
) {
  for (const p of phases) {
    if (!YMD.test(p.start) || !YMD.test(p.end)) return { error: 'invalid_date' as const };
    // An inverted phase (start > end) covers no dates but would be stored as
    // authored truth for Claude to reason over — reject it, same as trips
    // (Codex #64 P2).
    if (p.start > p.end) return { error: 'invalid_range' as const };
  }
  const res = await writePlanMeta(db, userId, expectedVersion, (meta) => {
    meta.periodization = phases;
  }, attribution);
  return 'ok' in res
    ? { ok: true as const, version: res.version, periodization: res.meta.periodization ?? [] }
    : res;
}

/** Append a trip/blackout range; mints and returns its id. */
export async function addTrip(
  db: D1Database,
  userId: string,
  trip: Omit<Trip, 'id'>,
  expectedVersion?: number | null,
  attribution: PlanWriteAttribution = { actor: 'system', operation: 'add_trip' },
) {
  if (!YMD.test(trip.start) || !YMD.test(trip.end)) return { error: 'invalid_date' as const };
  // YYYY-MM-DD sorts chronologically, so an inverted range (start > end) would
  // store a trip the projection (date >= start && date <= end) can NEVER cover
  // — a silent no-op. Reject it. (Codex #64 P2.)
  if (trip.start > trip.end) return { error: 'invalid_range' as const };
  const id = uuid();
  const res = await writePlanMeta(db, userId, expectedVersion, (meta) => {
    const trips = meta.trips ?? [];
    trips.push({ ...trip, id });
    meta.trips = trips;
  }, attribution);
  return 'ok' in res
    ? { ok: true as const, version: res.version, id, trips: res.meta.trips ?? [] }
    : res;
}

/** Patch one trip by id. Errors `trip_not_found` if absent. */
export async function updateTrip(
  db: D1Database,
  userId: string,
  tripId: string,
  patch: Partial<Omit<Trip, 'id'>>,
  expectedVersion?: number | null,
  attribution: PlanWriteAttribution = { actor: 'system', operation: 'update_trip' },
) {
  if (patch.start && !YMD.test(patch.start)) return { error: 'invalid_date' as const };
  if (patch.end && !YMD.test(patch.end)) return { error: 'invalid_date' as const };
  const res = await writePlanMeta(db, userId, expectedVersion, (meta) => {
    const trips = meta.trips ?? [];
    const i = trips.findIndex((t) => t.id === tripId);
    const existing = i < 0 ? undefined : trips[i];
    if (!existing) return 'trip_not_found';
    // Merge only the fields actually present — never clobber with undefined.
    const merged: Trip = { ...existing, id: tripId };
    if (patch.start !== undefined) merged.start = patch.start;
    if (patch.end !== undefined) merged.end = patch.end;
    if (patch.type !== undefined) merged.type = patch.type;
    if (patch.can_train_light !== undefined) merged.can_train_light = patch.can_train_light;
    if (patch.note !== undefined) merged.note = patch.note;
    // Validate the RESULTING range (a patch may move only start or only end)
    // — an inverted range covers no dates (Codex #64 P2).
    if (merged.start > merged.end) return 'invalid_range';
    trips[i] = merged;
    meta.trips = trips;
  }, attribution);
  return 'ok' in res
    ? { ok: true as const, version: res.version, trips: res.meta.trips ?? [] }
    : res;
}

/** Remove one trip by id. Errors `trip_not_found` if absent. */
export async function removeTrip(
  db: D1Database,
  userId: string,
  tripId: string,
  expectedVersion?: number | null,
  attribution: PlanWriteAttribution = { actor: 'system', operation: 'remove_trip' },
) {
  const res = await writePlanMeta(db, userId, expectedVersion, (meta) => {
    const trips = meta.trips ?? [];
    if (!trips.some((t) => t.id === tripId)) return 'trip_not_found';
    meta.trips = trips.filter((t) => t.id !== tripId);
  }, attribution);
  return 'ok' in res
    ? { ok: true as const, version: res.version, trips: res.meta.trips ?? [] }
    : res;
}

/** Replace the planning stress model. */
export async function setStressModel(
  db: D1Database,
  userId: string,
  model: StressModel,
  expectedVersion?: number | null,
  attribution: PlanWriteAttribution = { actor: 'system', operation: 'set_stress_model' },
) {
  const res = await writePlanMeta(db, userId, expectedVersion, (meta) => {
    meta.stress_model = model;
  }, attribution);
  return 'ok' in res
    ? { ok: true as const, version: res.version, stress_model: res.meta.stress_model ?? null }
    : res;
}

/**
 * Scrub schedule weekday entries whose workout_id is not in `liveIds`.
 * Returns the cleaned schedule, or null if nothing changed. Caller decides
 * whether to persist (used inside the plan-rebuild batch so it shares the
 * single version bump).
 */
function scrubSchedule(
  schedule: WeeklySchedule,
  liveIds: Set<string>,
): WeeklySchedule | null {
  let changed = false;
  const week: ScheduleWeek = { ...schedule.week };
  for (const wd of WEEKDAYS) {
    const v = week[wd];
    if (v != null && !liveIds.has(v)) {
      week[wd] = null;
      changed = true;
    }
  }
  return changed ? { version: schedule.version + 1, week } : null;
}

/**
 * Delete one day_template and, in the same transaction, scrub any schedule
 * entries pointing at it and bump plans.version exactly once.
 */
export async function deleteWorkout(
  db: D1Database,
  userId: string,
  dayId: string,
  expectedVersion?: number,
  attribution: PlanWriteAttribution = { actor: 'system', operation: 'delete_day' },
): Promise<
  { ok: true; version: number }
  | { error: 'day_not_found' }
  | { error: 'day_in_progress' }
  | PlanVersionConflict
  | GroupConflict
> {
  const plan = await getActivePlan(db, userId);
  if (!plan) return { error: 'day_not_found' };
  if (expectedVersion !== undefined && expectedVersion !== plan.version) {
    return { conflict: true, current_version: plan.version };
  }
  const writeVersion = expectedVersion ?? plan.version;
  const day = await workoutDB(db)
    .prepare('SELECT id FROM workouts WHERE id = ?1 AND plan_id = ?2')
    .bind(dayId, plan.id)
    .first<{ id: string }>();
  if (!day) return { error: 'day_not_found' };
  const groupTree = await getPlanTree(db, userId);
  const groupInvalid = validatePlanExerciseGroups(groupTree?.workouts.filter((candidate) => candidate.id !== dayId) ?? []);
  if (groupInvalid) return groupInvalid;
  const meta = parsePlanMeta(plan.meta);
  const remaining = await workoutDB(db)
    .prepare(
      'SELECT id FROM workouts WHERE plan_id = ?1 AND id != ?2 ORDER BY order_index, created_at, id',
    )
    .bind(plan.id, dayId)
    .all<{ id: string }>();
  const liveIds = new Set(remaining.results.map((r) => r.id));
  const scrubbed = scrubSchedule(meta.schedule, liveIds);
  // A session may deliberately keep workout_id NULL and resolve its
  // workout from the recurring schedule for that civil date. Treat those
  // rows as references to this day too, using the same mon..sun rule as the
  // calendar projection. The literal list is derived only from WEEKDAYS.
  const scheduledWeekdayNumbers = WEEKDAYS.flatMap((weekday, index) =>
    meta.schedule.week[weekday] === dayId ? [(index + 1) % 7] : [],
  );
  const matchesDeletedDay = (
    alias: string,
    dayParameter: string,
    planParameter: string,
  ): string => {
    // Keep the plan identity explicit in both branches. Besides preventing an
    // archived-plan row from participating, this keeps the numbered binding
    // contract stable when the deleted day is no longer in the schedule.
    const explicit = `(${alias}.workout_id = ${dayParameter} AND ${alias}.plan_id = ${planParameter})`;
    if (scheduledWeekdayNumbers.length === 0) return explicit;
    return `(${explicit} OR (${alias}.workout_id IS NULL AND ${alias}.plan_id = ${planParameter} AND CAST(strftime('%w', ${alias}.date) AS INTEGER) IN (${scheduledWeekdayNumbers.join(',')})))`;
  };
  // Once a null-template session has started, its live set links are durable
  // evidence of which template it is executing. The recurring schedule can be
  // remapped while that workout is still active, so current weekday resolution
  // alone is insufficient to protect the old day from deletion.
  const activeSessionReferencesDeletedDay = (
    alias: string,
    dayParameter: string,
    planParameter: string,
  ): string => `(
    ${matchesDeletedDay(alias, dayParameter, planParameter)}
    OR EXISTS (
      SELECT 1 FROM set_logs AS active_set
      JOIN template_exercises AS active_slot
        ON active_slot.id = active_set.template_exercise_id
      WHERE active_set.session_id = ${alias}.id
        AND active_set.deleted_at IS NULL
        AND active_slot.workout_id = ${dayParameter}
    )
  )`;
  const ts = now();
  const nonce = uuid();
  const stmts: D1PreparedStatement[] = [
    ...preparePlanWriteStart(db, plan, attribution, ts, nonce),
    // Preserve historical rows; only detach their pointers into the plan
    // document before deleting that document node.
    workoutDB(db)
      .prepare(
        `UPDATE sessions
            SET workout_id = NULL,
                status = CASE WHEN status = 'planned' THEN 'skipped' ELSE status END,
                updated_at = CASE
                  WHEN workout_id IS NOT NULL OR status = 'planned' THEN ?5
                  ELSE updated_at
                END,
                attempt = CASE WHEN status = 'planned' THEN attempt + 1 ELSE attempt END
          WHERE user_id = ?1 AND ${matchesDeletedDay('sessions', '?2', '?3')}
            AND status != 'in_progress'
            AND EXISTS (
              SELECT 1 FROM plans
               WHERE id = ?3 AND user_id = ?1 AND status = 'active' AND version = ?4
            )
            AND NOT EXISTS (
              SELECT 1 FROM sessions AS active_session
               WHERE active_session.user_id = ?1
                 AND ${activeSessionReferencesDeletedDay('active_session', '?2', '?3')}
                 AND active_session.status = 'in_progress'
            )`,
      )
      .bind(userId, dayId, plan.id, -writeVersion, ts),
    workoutDB(db)
      .prepare(
        `UPDATE set_logs
            SET template_exercise_id = NULL,
                updated_at = MAX(updated_at + 1, ?5)
          WHERE template_exercise_id IN (
            SELECT id FROM template_exercises WHERE workout_id = ?1
          )
            AND EXISTS (
              SELECT 1 FROM plans
               WHERE id = ?2 AND user_id = ?3 AND status = 'active' AND version = ?4
            )
            AND NOT EXISTS (
              SELECT 1 FROM sessions AS active_session
               WHERE active_session.user_id = ?3
                 AND ${activeSessionReferencesDeletedDay('active_session', '?1', '?2')}
                 AND active_session.status = 'in_progress'
            )`,
      )
      .bind(dayId, plan.id, userId, -writeVersion, ts),
    workoutDB(db)
      .prepare(
        `DELETE FROM template_exercises WHERE workout_id = ?1
          AND EXISTS (
            SELECT 1 FROM plans
             WHERE id = ?2 AND user_id = ?3 AND status = 'active' AND version = ?4
          )
          AND NOT EXISTS (
            SELECT 1 FROM sessions AS active_session
             WHERE active_session.user_id = ?3
               AND ${activeSessionReferencesDeletedDay('active_session', '?1', '?2')}
               AND active_session.status = 'in_progress'
          )`,
      )
      .bind(dayId, plan.id, userId, -writeVersion),
    workoutDB(db)
      .prepare(
        `DELETE FROM workouts WHERE id = ?1 AND plan_id = ?2
          AND EXISTS (
            SELECT 1 FROM plans
             WHERE id = ?2 AND user_id = ?3 AND status = 'active' AND version = ?4
          )
          AND NOT EXISTS (
            SELECT 1 FROM sessions AS active_session
             WHERE active_session.user_id = ?3
               AND ${activeSessionReferencesDeletedDay('active_session', '?1', '?2')}
               AND active_session.status = 'in_progress'
          )`,
      )
      .bind(dayId, plan.id, userId, -writeVersion),
    ...remaining.results.map((row, index) =>
      workoutDB(db)
        .prepare(
          `UPDATE workouts SET order_index = ?2, updated_at = ?3
            WHERE id = ?1 AND plan_id = ?4
              AND EXISTS (
                SELECT 1 FROM plans
                 WHERE id = ?4 AND user_id = ?5 AND status = 'active' AND version = ?6
              )
              AND NOT EXISTS (
                SELECT 1 FROM sessions AS active_session
                 WHERE active_session.user_id = ?5
                   AND ${activeSessionReferencesDeletedDay('active_session', '?7', '?4')}
                   AND active_session.status = 'in_progress'
              )`,
        )
        .bind(row.id, index, ts, plan.id, userId, -writeVersion, dayId),
    ),
    workoutDB(db)
      .prepare(
        `UPDATE plans SET meta = ?2, updated_at = ?3
          WHERE id = ?1 AND user_id = ?4 AND status = 'active' AND version = ?5
            AND plan_write_nonce = ?7
            AND NOT EXISTS (
              SELECT 1 FROM sessions AS active_session
               WHERE active_session.user_id = ?4
                 AND ${activeSessionReferencesDeletedDay('active_session', '?6', '?1')}
                 AND active_session.status = 'in_progress'
            )
          `,
      )
      .bind(
        plan.id,
        serializePlanMeta(meta, scrubbed ?? meta.schedule),
        ts,
        userId,
        -writeVersion,
        dayId,
        nonce,
      ),
  ];
  const documentUpdateIndex = stmts.length - 1;
  const versionResultIndex = stmts.length;
  stmts.push(...preparePlanWriteFinish(db, plan, attribution, ts, nonce));
  const results = await runWorkoutWriteBatch<{ version: number }>(db, stmts);
  const updatedPlan = results[versionResultIndex]?.results[0];
  if ((results[0]?.meta.changes ?? 0) !== 1 || (results[documentUpdateIndex]?.meta.changes ?? 0) !== 1 || !updatedPlan) {
    const active = await workoutDB(db)
      .prepare(
        `SELECT 1 FROM sessions AS active_session
          WHERE active_session.user_id = ?1
            AND ${activeSessionReferencesDeletedDay('active_session', '?2', '?3')}
            AND active_session.status = 'in_progress'
          LIMIT 1`,
      )
      .bind(userId, dayId, plan.id)
      .first();
    if (active) return { error: 'day_in_progress' };
    return currentPlanVersion(db, userId, writeVersion);
  }
  return { ok: true, version: updatedPlan.version };
}

export interface CalendarMoveInput {
  id: string;
  from_date: string;
  to_date: string;
  today: string;
  workout_id: string;
  expected_plan_id: string;
  expected_version: number;
  expected_from_attempt: number;
  expected_to_attempt: number;
}

export interface CalendarMoveAcknowledgement {
  ok: true;
  from: SessionRow;
  to: SessionRow;
}

/** Two date exceptions and their retry receipt commit together. Notes and
 * fatigue remain on their original dates, as with a date assignment/removal. */
export async function moveCalendarWorkout(db: D1Database, userId: string, input: CalendarMoveInput): Promise<
  CalendarMoveAcknowledgement | { error: 'calendar_move_conflict' | 'invalid_move' | 'idempotency_conflict' }
> {
  const args = JSON.stringify(input);
  const receiptID = input.id;
  const readReceipt = async () => {
    const row = await workoutDB(db).prepare(
      'SELECT user_id,tool,args,result FROM audit_log WHERE id=?1').bind(receiptID)
      .first<{ user_id: string; tool: string; args: string; result: string }>();
    if (!row) return null;
    if (row.user_id !== userId || row.tool !== 'move_calendar_workout' || row.args !== args) {
      return { error: 'idempotency_conflict' as const };
    }
    return JSON.parse(row.result).acknowledgement as CalendarMoveAcknowledgement;
  };
  const previous = await readReceipt();
  if (previous) return previous;
  if (input.from_date === input.to_date || input.from_date < input.today || input.to_date < input.today) {
    return { error: 'invalid_move' };
  }
  const plan = await getPlanTree(db, userId);
  if (!plan || plan.id !== input.expected_plan_id || plan.version !== input.expected_version
      || !plan.workouts.some((workout) => workout.id === input.workout_id)) {
    return { error: 'calendar_move_conflict' };
  }
  const rows = (await workoutDB(db).prepare(
    'SELECT * FROM sessions WHERE user_id=?1 AND date IN (?2,?3)')
    .bind(userId, input.from_date, input.to_date).all<SessionRow>()).results;
  const from = rows.find((row) => row.date === input.from_date);
  const to = rows.find((row) => row.date === input.to_date);
  if ((from?.attempt ?? 0) !== input.expected_from_attempt || (to?.attempt ?? 0) !== input.expected_to_attempt
      || rows.some((row) => !['planned', 'skipped', 'discarded'].includes(row.status))) {
    return { error: 'calendar_move_conflict' };
  }
  const meta = parsePlanMeta(plan.meta);
  const project = (date: string) => projectCalendar(plan, meta.schedule, rows, date, date,
    input.today, plan.workouts.map((workout) => workout.id), meta.trips)[0];
  const origin = project(input.from_date);
  const destination = project(input.to_date);
  const resolvedWorkout = (cell: CalendarCell | undefined) => {
    if (!cell || cell.suppresses_schedule_and_endurance) return null;
    if (cell.status === 'skipped' || cell.status === 'rest') return null;
    if (cell.workout_id) return cell.workout_id;
    if (cell.real && cell.status === 'planned') {
      const id = meta.schedule.week[weekdayOf(cell.date)];
      return plan.workouts.some((workout) => workout.id === id) ? id : null;
    }
    return null;
  };
  if (!origin || !destination || origin.suppresses_schedule_and_endurance
      || destination.suppresses_schedule_and_endurance || resolvedWorkout(origin) !== input.workout_id
      || resolvedWorkout(destination) !== null) return { error: 'calendar_move_conflict' };

  const ts = Math.max(now(), (from?.updated_at ?? 0) + 1, (to?.updated_at ?? 0) + 1);
  const newRow = (date: string, old: SessionRow | undefined, workoutId: string | null): SessionRow => ({
    id: old?.id ?? uuid(), user_id: userId, plan_id: plan.id, date,
    workout_id: workoutId, status: workoutId ? 'planned' : 'skipped',
    started_at: null, completed_at: null,
    perceived_fatigue: old?.perceived_fatigue ?? null, notes: old?.notes ?? null,
    runner_targets: null, exercise_swaps: null, created_at: old?.created_at ?? ts, updated_at: ts,
    attempt: (old?.attempt ?? 0) + 1, write_protocol: old?.write_protocol ?? 'legacy',
  });
  const acknowledgement: CalendarMoveAcknowledgement = { ok: true,
    from: newRow(input.from_date, from, null), to: newRow(input.to_date, to, input.workout_id) };
  const nonce = uuid();
  const conditions: string[] = [];
  const bindings: unknown[] = [receiptID, userId, args, JSON.stringify({ nonce, acknowledgement }), ts,
    plan.id, plan.version];
  // Fence the observed assignment and annotations, including absence, in one transaction.
  for (const [date, row] of [[input.from_date, from], [input.to_date, to]] as const) {
    const index = bindings.length + 1;
    bindings.push(date, JSON.stringify(row ? [row.id, row.attempt, row.status, row.workout_id, row.updated_at,
      row.notes, row.perceived_fatigue] : null));
    conditions.push(`COALESCE((SELECT json_array(id,attempt,status,workout_id,updated_at,notes,perceived_fatigue)
      FROM sessions WHERE user_id=?2 AND date=?${index}), 'null')=?${index + 1}`);
  }
  const statements = [workoutDB(db).prepare(
    `INSERT INTO audit_log (id,user_id,actor,tool,args,result,created_at)
     SELECT ?1,?2,'ios','move_calendar_workout',?3,?4,?5
     WHERE EXISTS (SELECT 1 FROM plans WHERE id=?6 AND user_id=?2 AND status='active' AND version=?7)
       AND ${conditions.join(' AND ')}
     ON CONFLICT(id) DO NOTHING`).bind(...bindings)];
  for (const row of [acknowledgement.from, acknowledgement.to]) {
    statements.push(workoutDB(db).prepare(
      `INSERT INTO sessions (id,user_id,plan_id,workout_id,date,status,started_at,completed_at,
        perceived_fatigue,notes,runner_targets,created_at,updated_at,attempt,write_protocol)
       SELECT ?1,?2,?3,?4,?5,?6,NULL,NULL,?13,?14,NULL,?7,?8,?9,?10
       WHERE EXISTS (SELECT 1 FROM audit_log WHERE id=?11 AND user_id=?2 AND json_extract(result,'$.nonce')=?12)
       ON CONFLICT(user_id,date) DO UPDATE SET
         plan_id=excluded.plan_id,workout_id=excluded.workout_id,status=excluded.status,
         started_at=NULL,completed_at=NULL,runner_targets=NULL,
         updated_at=excluded.updated_at,attempt=excluded.attempt`)
      .bind(row.id, row.user_id, row.plan_id, row.workout_id, row.date, row.status,
        row.created_at, row.updated_at, row.attempt, row.write_protocol, receiptID, nonce,
        row.perceived_fatigue, row.notes));
  }
  const results = await runWorkoutWriteBatch(db, statements);
  if (results[0]?.meta.changes === 1) return acknowledgement;
  return await readReceipt() ?? { error: 'calendar_move_conflict' };
}

/**
 * One-off: pin a specific date to a day template (or clear to a bare planned
 * session). Writes/updates a sessions row ONLY — append-only log, NO version
 * bump. `day` accepts id, day_label, or day name.
 */
export async function setPlannedSession(
  db: D1Database,
  userId: string,
  date: string,
  day: string,
  expectedAttempt?: number,
): Promise<
  | { error: 'no_active_plan' }
  | { error: 'unknown_day_ref'; ref: string }
  | { error: 'session_already_started'; status: 'in_progress' | 'completed' }
  | SessionAttemptConflict
  | SessionAttemptMissing
  | SessionStateConflict
  | PlanVersionConflict
  | { ok: true; session: SessionRow }
> {
  const plan = await getActivePlan(db, userId);
  if (!plan) return { error: 'no_active_plan' };
  const d = await workoutDB(db)
    .prepare(
      "SELECT id FROM workouts WHERE plan_id = ?1 AND (id = ?2 OR lower(day_label) = lower(?2) OR lower(name) = lower(?2)) LIMIT 1",
    )
    .bind(plan.id, day)
    .first<{ id: string }>();
  if (!d) return { error: 'unknown_day_ref', ref: day };
  const readExisting = () =>
    workoutDB(db)
      .prepare(
        'SELECT * FROM sessions WHERE user_id = ?1 AND date = ?2 ORDER BY created_at, id LIMIT 1',
      )
      .bind(userId, date)
      .first<SessionRow>();
  const useExisting = async (
    existing: SessionRow,
  ): Promise<
    | { ok: true; session: SessionRow }
    | { error: 'session_already_started'; status: 'in_progress' | 'completed' }
    | SessionAttemptConflict
    | SessionStateConflict
    | PlanVersionConflict
  > => {
    if (existing.status === 'in_progress' || existing.status === 'completed') {
      return {
        error: 'session_already_started',
        status: existing.status as 'in_progress' | 'completed',
      };
    }
    // An identical retry is idempotent even if the caller never received the
    // first response's advanced assignment token. Every *different* date
    // choice below advances attempt, so an old queued set/override cannot
    // silently join the replacement assignment.
    const assignmentUnchanged =
      existing.plan_id === plan.id &&
      existing.status === 'planned' &&
      existing.workout_id === d.id;
    if (assignmentUnchanged) return { ok: true, session: existing };

    const casAttempt = expectedAttempt ?? 0;
    if (existing.attempt !== casAttempt) {
      return sessionAttemptConflict(casAttempt, existing);
    }
    const casStatus = existing.status;
    const ts = now();
    // The SQL CASE already flips the row to a sensible status; the bug was
    // that the response object spread `...existing` and kept the OLD status
    // (e.g. an agent saw `status: 'discarded'` with a past `started_at`
    // while the DB was actually 'planned' now). Compute the new shape
    // explicitly and persist BOTH started_at and completed_at resets when
    // we're reviving a discarded row, mirroring getOrCreateSession's
    // discard→planned resurrection (consistent revival rule across the
    // two places that revive a discarded session).
    const newStatus = 'planned';
    // Every assignment change is a generation boundary. This includes
    // planned A -> planned B and planned -> rest (in skipPlannedSession), not
    // only discarded/skipped revival: otherwise two clients holding attempt 0
    // can both win and an old queued set can land in the newly assigned day.
    const reviving =
      existing.status === 'discarded' || existing.status === 'skipped';
    const newStartedAt = reviving ? null : existing.started_at;
    const newCompletedAt = reviving ? null : existing.completed_at;
    const newFatigue = reviving ? null : existing.perceived_fatigue;
    const newNotes = reviving ? null : existing.notes;
    const newAttempt = casAttempt + 1;
    const updated = await runWorkoutWriteStatement(
      db,
      workoutDB(db).prepare(
        `UPDATE sessions
            SET plan_id = ?13,
                workout_id = ?2,
                status = ?3,
                started_at = ?4,
                completed_at = ?5,
                perceived_fatigue = ?11,
                notes = ?12,
                updated_at = ?6,
                attempt = ?7
          WHERE id = ?1
            AND user_id = ?8
            AND status = ?9
            AND attempt = ?10
            AND EXISTS (
              SELECT 1
                FROM plans AS active_plan
                JOIN workouts AS active_day
                  ON active_day.plan_id = active_plan.id
               WHERE active_plan.id = ?13
                 AND active_plan.user_id = ?8
                 AND active_plan.status = 'active'
                 AND active_plan.version = ?14
                 AND active_day.id = ?2
            )`,
      )
      .bind(
        existing.id,
        d.id,
        newStatus,
        newStartedAt,
        newCompletedAt,
        ts,
        newAttempt,
        userId,
        casStatus,
        casAttempt,
        newFatigue,
        newNotes,
        plan.id,
        plan.version,
      ),
    );
    if (updated.meta.changes === 0) {
      const activePlan = await getActivePlan(db, userId);
      if (activePlan?.id !== plan.id || activePlan.version !== plan.version) {
        return { conflict: true, current_version: activePlan?.version ?? plan.version };
      }
      const current = await readExisting();
      if (!current) throw new Error('session_update_conflict_without_winner');
      if (current.attempt !== casAttempt) {
        return sessionAttemptConflict(casAttempt, current);
      }
      return sessionStateConflict(casStatus, current);
    }
    const session: SessionRow = {
      ...existing,
      plan_id: plan.id,
      workout_id: d.id,
      status: newStatus,
      started_at: newStartedAt,
      completed_at: newCompletedAt,
      perceived_fatigue: newFatigue,
      notes: newNotes,
      updated_at: ts,
      attempt: newAttempt,
      write_protocol: existing.write_protocol,
    };
    return { ok: true, session };
  };
  const existing = await readExisting();
  if (existing) return useExisting(existing);
  if (expectedAttempt !== undefined && expectedAttempt !== 0) {
    return { error: 'session_attempt_missing', expected_attempt: expectedAttempt };
  }

  const ts = now();
  const s: SessionRow = {
    id: uuid(),
    user_id: userId,
    plan_id: plan.id,
    workout_id: d.id,
    date,
    status: 'planned',
    started_at: null,
    completed_at: null,
    perceived_fatigue: null,
    notes: null,
    created_at: ts,
    updated_at: ts,
    // Attempt zero is the explicit "no date assignment observed" token.
    // Persist the first concrete assignment as generation one so a second
    // concurrent creator carrying zero loses the CAS in useExisting().
    attempt: 1,
    write_protocol: 'legacy',
  };
  const inserted = await runWorkoutWriteStatement(
    db,
    workoutDB(db).prepare(
      `INSERT INTO sessions
       (id,user_id,plan_id,workout_id,date,status,started_at,completed_at,perceived_fatigue,notes,created_at,updated_at,attempt,write_protocol)
       SELECT ?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14
        WHERE EXISTS (
          SELECT 1
            FROM plans AS active_plan
            JOIN workouts AS active_day
              ON active_day.plan_id = active_plan.id
           WHERE active_plan.id = ?3
             AND active_plan.user_id = ?2
             AND active_plan.status = 'active'
             AND active_plan.version = ?15
             AND active_day.id = ?4
        )
       ON CONFLICT(user_id,date) DO NOTHING`,
    )
    .bind(
      s.id,
      s.user_id,
      s.plan_id,
      s.workout_id,
      s.date,
      s.status,
      s.started_at,
      s.completed_at,
      s.perceived_fatigue,
      s.notes,
      s.created_at,
      s.updated_at,
      s.attempt,
      s.write_protocol,
      plan.version,
    ),
  );
  if (inserted.meta.changes > 0) return { ok: true, session: s };

  const activePlan = await getActivePlan(db, userId);
  if (activePlan?.id !== plan.id || activePlan.version !== plan.version) {
    return { conflict: true, current_version: activePlan?.version ?? plan.version };
  }
  const winner = await readExisting();
  if (!winner) throw new Error('session_create_conflict_without_winner');
  return useExisting(winner);
}

/**
 * One-off: mark a specific date a rest/skip day. Writes/updates a sessions
 * row with status 'skipped' — append-only, NO version bump.
 */
export async function skipPlannedSession(
  db: D1Database,
  userId: string,
  date: string,
  expectedAttempt?: number,
): Promise<
  | { error: 'no_active_plan' }
  | { error: 'session_already_started'; status: 'in_progress' | 'completed' }
  | SessionAttemptConflict
  | SessionAttemptMissing
  | SessionStateConflict
  | PlanVersionConflict
  | { ok: true; session: SessionRow }
> {
  const plan = await getActivePlan(db, userId);
  if (!plan) return { error: 'no_active_plan' };
  const readExisting = () =>
    workoutDB(db)
      .prepare(
        'SELECT * FROM sessions WHERE user_id = ?1 AND date = ?2 ORDER BY created_at, id LIMIT 1',
      )
      .bind(userId, date)
      .first<SessionRow>();
  const useExisting = async (
    existing: SessionRow,
  ): Promise<
    | { error: 'session_already_started'; status: 'in_progress' | 'completed' }
    | SessionAttemptConflict
    | SessionStateConflict
    | PlanVersionConflict
    | { ok: true; session: SessionRow }
  > => {
    // A skip may only override a planned (or absent) session. If the date
    // already has a started/finished workout, skipping it would hide logged
    // sets and destroy visible history for a mis-dated skip. Reject and
    // leave the row untouched — Claude must explicitly intend something
    // else. The MCP wrapper still audits this rejection (audit-on-write).
    if (existing.status === 'in_progress' || existing.status === 'completed') {
      return {
        error: 'session_already_started',
        status: existing.status as 'in_progress' | 'completed',
      };
    }
    const assignmentUnchanged =
      existing.plan_id === plan.id && existing.status === 'skipped';
    if (assignmentUnchanged) return { ok: true, session: existing };

    const casAttempt = expectedAttempt ?? 0;
    if (existing.attempt !== casAttempt) {
      return sessionAttemptConflict(casAttempt, existing);
    }
    const casStatus = existing.status;
    const ts = now();
    const newAttempt = casAttempt + 1;
    const updated = await runWorkoutWriteStatement(
      db,
      workoutDB(db).prepare(
        `UPDATE sessions
            SET plan_id = ?6,
                workout_id = NULL,
                status = 'skipped',
                updated_at = ?2,
                attempt = ?7
          WHERE id = ?1
            AND user_id = ?3
            AND status = ?4
            AND attempt = ?5
            AND EXISTS (
              SELECT 1 FROM plans AS active_plan
               WHERE active_plan.id = ?6
                 AND active_plan.user_id = ?3
                 AND active_plan.status = 'active'
                 AND active_plan.version = ?8
            )`,
      )
      .bind(
        existing.id,
        ts,
        userId,
        casStatus,
        casAttempt,
        plan.id,
        newAttempt,
        plan.version,
      ),
    );
    if (updated.meta.changes === 0) {
      const activePlan = await getActivePlan(db, userId);
      if (activePlan?.id !== plan.id || activePlan.version !== plan.version) {
        return { conflict: true, current_version: activePlan?.version ?? plan.version };
      }
      const current = await readExisting();
      if (!current) throw new Error('session_update_conflict_without_winner');
      if (current.attempt !== casAttempt) {
        return sessionAttemptConflict(casAttempt, current);
      }
      if (current.status === 'in_progress' || current.status === 'completed') {
        return {
          error: 'session_already_started',
          status: current.status,
        };
      }
      return sessionStateConflict(casStatus, current);
    }
    return {
      ok: true,
      session: {
        ...existing,
        plan_id: plan.id,
        workout_id: null,
        status: 'skipped',
        updated_at: ts,
        attempt: newAttempt,
        write_protocol: existing.write_protocol,
      },
    };
  };
  const existing = await readExisting();
  if (existing) return useExisting(existing);
  if (expectedAttempt !== undefined && expectedAttempt !== 0) {
    return { error: 'session_attempt_missing', expected_attempt: expectedAttempt };
  }

  const ts = now();
  const s: SessionRow = {
    id: uuid(),
    user_id: userId,
    plan_id: plan.id,
    workout_id: null,
    date,
    status: 'skipped',
    started_at: null,
    completed_at: null,
    perceived_fatigue: null,
    notes: null,
    created_at: ts,
    updated_at: ts,
    attempt: 1,
    write_protocol: 'legacy',
  };
  const inserted = await runWorkoutWriteStatement(
    db,
    workoutDB(db).prepare(
      `INSERT INTO sessions
       (id,user_id,plan_id,workout_id,date,status,started_at,completed_at,perceived_fatigue,notes,created_at,updated_at,attempt,write_protocol)
       SELECT ?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14
        WHERE EXISTS (
          SELECT 1 FROM plans AS active_plan
           WHERE active_plan.id = ?3
             AND active_plan.user_id = ?2
             AND active_plan.status = 'active'
             AND active_plan.version = ?15
        )
       ON CONFLICT(user_id,date) DO NOTHING`,
    )
    .bind(
      s.id,
      s.user_id,
      s.plan_id,
      s.workout_id,
      s.date,
      s.status,
      s.started_at,
      s.completed_at,
      s.perceived_fatigue,
      s.notes,
      s.created_at,
      s.updated_at,
      s.attempt,
      s.write_protocol,
      plan.version,
    ),
  );
  if (inserted.meta.changes > 0) return { ok: true, session: s };

  const activePlan = await getActivePlan(db, userId);
  if (activePlan?.id !== plan.id || activePlan.version !== plan.version) {
    return { conflict: true, current_version: activePlan?.version ?? plan.version };
  }
  const winner = await readExisting();
  if (!winner) throw new Error('session_create_conflict_without_winner');
  return useExisting(winner);
}

/**
 * An endurance item on a calendar day (MULTISPORT.md §6.1). These COEXIST
 * with the strength side (`workout_id`) — a brick is a lift + a ride on
 * the same day — so they live in their own array rather than replacing the
 * strength cell. Read-only (endurance executes on the watch); on today+ days
 * these are planned `external_events`, on past days completed
 * `external_activities`. iOS renders them as read-only cards.
 */
export interface EnduranceItem {
  /** external_event / external_activity id (e.g. "intervals:{external_id}"). */
  id: string;
  /** ride | run | swim | other. */
  kind: string;
  title: string | null;
  /** Planned (future) duration; null for completed-actual items. */
  planned_duration_sec: number | null;
  /** TSS-like load (planned or actual). */
  training_load: number | null;
  /** true → a completed actual (past), false → a planned event (today+). */
  completed: boolean;
}

export interface CalendarCell {
  date: string;
  /**
   * The day's coarse status. Strength + endurance + trips collapse into one:
   *   - 'unavailable' — a trip covers the date with can_train_light=false:
   *     no logged strength happened and items is []. A real in_progress/
   *     completed strength session instead keeps its status, but still has
   *     no endurance items. (The trip type remains in `trip_type`.)
   *   - 'light'       — a trip covers the date with can_train_light=true:
   *     training is possible but constrained; items reflect what's planned.
   *   - real session status (planned|in_progress|completed|skipped) — a real
   *     strength sessions row drives it.
   *   - 'projected'   — no real session; the weekly pattern projects a lift.
   *   - 'rest'        — no template that weekday and no items.
   * NOTE: a day with ONLY endurance (no strength) and no trip reports
   * 'projected' (it has planned training) so existing lift-or-not consumers
   * keep working; inspect `items` to distinguish a pure-endurance day.
   */
  status:
    | 'projected'
    | 'rest'
    | 'planned'
    | 'in_progress'
    | 'completed'
    | 'skipped'
    | 'unavailable'
    | 'light';
  /** Set when a template resolves (projected or a real session w/ day). */
  workout_id: string | null;
  /** True iff this cell came from a real sessions row. */
  real: boolean;
  /**
   * Endurance items for the day (bricks / doubles). Empty array when there is
   * no endurance. ADDITIVE — existing single-item strength consumers ignore
   * this and keep reading `status`/`workout_id`/`real` unchanged.
   */
  items: EnduranceItem[];
  /** When status is a trip status ('unavailable'/'light'), the trip.type. */
  trip_type?: string;
  /** True when a hard blackout suppressed both recurring strength and every
   *  endurance event. Real in-progress/completed strength may remain visible,
   *  so consumers cannot infer this solely from `status`. */
  suppresses_schedule_and_endurance?: true;
}

/**
 * A planned endurance event for the projection (future days). Mirror-shape of
 * the relevant ExternalEventRow columns; `date` is the civil YYYY-MM-DD.
 */
export type ProjectionEvent = Pick<
  ExternalEventRow,
  'id' | 'date' | 'kind' | 'title' | 'planned_duration_sec' | 'training_load'
>;

/**
 * A completed endurance actual for the projection (past days). Mirror-shape of
 * the relevant ExternalActivityRow columns.
 */
export type ProjectionActivity = Pick<
  ExternalActivityRow,
  'id' | 'date' | 'kind' | 'name' | 'moving_time_sec' | 'training_load'
>;

/** Index a list by its civil `date` into a Map<date, T[]>. */
function groupByDate<T extends { date: string }>(rows: Iterable<T>): Map<string, T[]> {
  const m = new Map<string, T[]>();
  for (const r of rows) {
    const arr = m.get(r.date);
    if (arr) arr.push(r);
    else m.set(r.date, [r]);
  }
  return m;
}

/**
 * Pure COMPOSITE projection (MULTISPORT.md §6.1). Given the plan, schedule,
 * real sessions, trips, and the endurance feeds (planned events for today+,
 * completed actuals for the past), emit a calendar cell per date. A
 * today-or-future day is a COMPOSITE: a strength side (status/workout_id)
 * PLUS an `items` array of coexisting endurance (bricks/doubles), PLUS a trip
 * status. It stays COMPUTED — no materialized rows.
 *
 * Per civil date:
 *  - date < today (PAST): emit ONLY if there is real history — a real
 *    sessions row (NOT a vanished discarded/planned one) OR a completed
 *    endurance actual. Never fabricate past rest/missed days. items =
 *    completed actuals on the date.
 *  - date >= today (TODAY+):
 *      trip covering date with can_train_light=false:
 *        a real in_progress/completed strength session stays visible with
 *          its own status/template; otherwise status = 'unavailable'.
 *        Either way, items = [] and no schedule/endurance is projected.
 *      else:
 *        strength: a real sessions row wins; else schedule[weekday] template
 *          (cleared if a trip covers the date — a trip blanks the schedule
 *          projection but keeps explicitly-pinned sessions).
 *        endurance: planned external_events on the date COEXIST (items).
 *        status: trip (can_train_light=true) → 'light'; else any strength or
 *          items → its lift/'projected' status; else 'rest'.
 *
 * Weekday is derived from the 'YYYY-MM-DD' string via weekdayOf() (calendar
 * rule, NOT a UTC offset) — iOS must mirror weekdayOf byte-for-byte.
 */
export function projectCalendar(
  plan: { id: string },
  schedule: WeeklySchedule,
  realSessions: SessionRow[],
  fromDate: string,
  toDate: string,
  today: string,
  /** Day-template ids that still exist; a schedule id not here is dangling
   *  and degrades to 'rest'. Pass [] only if you have no plan tree. */
  liveDayIds: Iterable<string> = [],
  /** Availability ranges (meta.trips). A covering trip drives the status. */
  trips: Trip[] = [],
  /** Planned endurance events (future days) — the coexisting brick/double. */
  plannedEvents: ProjectionEvent[] = [],
  /** Completed endurance actuals (past days) — what actually happened. */
  completedActivities: ProjectionActivity[] = [],
): CalendarCell[] {
  void plan;
  const resolvable = new Set(liveDayIds);
  // Clamp the span to 90 days (inclusive endpoint counts as span 0..89).
  let span = daySpan(fromDate, toDate);
  if (span < 0) return [];
  if (span > 89) span = 89;
  const byDate = new Map<string, SessionRow>();
  for (const s of realSessions) {
    // A 'discarded' session is treated as if it never existed: the user
    // explicitly threw it away (its set_logs are soft-deleted by
    // discardSession). Skipping it here makes the date fall through to the
    // schedule projection (past → no cell; today/future → projected/rest)
    // — i.e. it VANISHES rather than showing as a skip. This carve-out is
    // mirrored byte-for-byte in CalendarProjection.swift (`project`): the
    // frozen truth table now reads "a real session WINS *unless* it is
    // 'discarded'". test/calendar.test.ts is the contract.
    if (s.status === 'discarded') continue;
    if (!byDate.has(s.date)) byDate.set(s.date, s);
  }
  const eventsByDate = groupByDate(plannedEvents);
  const actsByDate = groupByDate(completedActivities);

  // Returns the trip covering `date` (first match), or null. A trip range is
  // [start, end] inclusive, compared on the civil YYYY-MM-DD string (the same
  // tz-free rule as weekdayOf/addDays). String compare is valid because the
  // format is zero-padded and sortable.
  const tripFor = (date: string): Trip | null => {
    for (const t of trips) {
      if (date >= t.start && date <= t.end) return t;
    }
    return null;
  };

  const eventItem = (e: ProjectionEvent): EnduranceItem => ({
    id: e.id,
    kind: e.kind,
    title: e.title,
    planned_duration_sec: e.planned_duration_sec,
    training_load: e.training_load,
    completed: false,
  });
  const actItem = (a: ProjectionActivity): EnduranceItem => ({
    id: a.id,
    kind: a.kind,
    title: a.name,
    planned_duration_sec: a.moving_time_sec,
    training_load: a.training_load,
    completed: true,
  });

  const cells: CalendarCell[] = [];
  for (let i = 0; i <= span; i++) {
    const date = addDays(fromDate, i);
    const real = byDate.get(date);
    const isPast = daySpan(today, date) < 0;

    if (isPast) {
      // PAST — show only real history: a real (non-vanished) session and/or
      // completed endurance actuals. A still-'planned' past session never
      // executed (logging flips it to in_progress/completed), so it VANISHES
      // like 'discarded' (#48). Mirrored byte-for-byte in
      // CalendarProjection.swift; calendar.test.ts is the contract.
      const items = (actsByDate.get(date) ?? []).map(actItem);
      if (real && real.status !== 'planned') {
        cells.push({
          date,
          status: real.status as CalendarCell['status'],
          workout_id: real.workout_id,
          real: true,
          items,
        });
      } else if (items.length) {
        // Endurance-only past day: completed actuals with no strength session.
        cells.push({
          date,
          status: 'completed',
          workout_id: null,
          real: false,
          items,
        });
      }
      // else: no real history → no fabricated past cell.
      continue;
    }

    // TODAY or FUTURE.
    const trip = tripFor(date);
    if (trip && trip.can_train_light === false) {
      // BLACKOUT TRUTH TABLE — keep byte-for-byte in backend and iOS:
      //   real in_progress/completed → surface the real session;
      //   real planned/skipped/other, or no real → unavailable.
      // In every case the blackout suppresses schedule and endurance items.
      if (real && (real.status === 'in_progress' || real.status === 'completed')) {
        cells.push({
          date,
          status: real.status,
          workout_id: real.workout_id,
          real: true,
          items: [],
          trip_type: trip.type,
          suppresses_schedule_and_endurance: true,
        });
        continue;
      }
      cells.push({
        date,
        status: 'unavailable',
        workout_id: null,
        real: false,
        items: [],
        trip_type: trip.type,
        suppresses_schedule_and_endurance: true,
      });
      continue;
    }

    // Outside a hard blackout, a real session wins; else the schedule
    // projection, UNLESS a trip covers the date (a trip blanks the recurring
    // pattern — Claude re-plans the week as explicit sessions). An explicitly-
    // pinned real session always survives a light trip.
    let status: CalendarCell['status'];
    let workoutId: string | null;
    let real_ = false;
    if (real) {
      status = real.status as CalendarCell['status'];
      workoutId = real.workout_id;
      real_ = true;
    } else {
      const tid = trip ? null : schedule.week[weekdayOf(date)];
      if (tid && resolvable.has(tid)) {
        status = 'projected';
        workoutId = tid;
      } else {
        status = 'rest';
        workoutId = null;
      }
    }

    // Endurance side coexists (brick / double).
    const items = (eventsByDate.get(date) ?? []).map(eventItem);

    // Resolve the composite status.
    let finalStatus = status;
    if (trip) {
      // can_train_light=true → constrained but possible. A pinned real
      // session keeps its own status; otherwise the day is 'light'.
      finalStatus = real_ ? status : 'light';
    } else if (status === 'rest' && items.length) {
      // Pure-endurance day (no strength) → report 'projected' so existing
      // lift-or-not consumers see planned training; items disambiguate.
      finalStatus = 'projected';
    }

    const cell: CalendarCell = {
      date,
      status: finalStatus,
      workout_id: workoutId,
      real: real_,
      items,
    };
    if (trip) cell.trip_type = trip.type;
    cells.push(cell);
  }
  return cells;
}

/**
 * Data-layer entry point: load the active plan, its schedule, the live day
 * ids (for dangling detection), and the real sessions in range, then return
 * the pure projection. fromDate/toDate are device-local 'YYYY-MM-DD'.
 */
export async function getProjectedCalendar(
  db: D1Database,
  userId: string,
  fromDate: string,
  toDate: string,
  today: string,
): Promise<CalendarCell[]> {
  const plan = await getActivePlan(db, userId);
  if (!plan) return [];
  const meta = parsePlanMeta(plan.meta);
  const schedule = meta.schedule;
  const trips = meta.trips ?? [];
  const liveDays = await workoutDB(db)
    .prepare('SELECT id FROM workouts WHERE plan_id = ?1')
    .bind(plan.id)
    .all<{ id: string }>();
  // Endurance feeds for the composite projection. Planned events drive
  // today+ bricks/doubles; completed actuals drive past endurance items.
  // Both are soft-deleted caches — exclude tombstones. The window matches
  // the sessions window (the projection clamps the span itself).
  const plannedEvents = await workoutDB(db)
    .prepare(
      `SELECT id, date, kind, title, planned_duration_sec, training_load
         FROM external_events
        WHERE user_id = ?1 AND deleted_at IS NULL
          AND date >= ?2 AND date <= ?3`,
    )
    .bind(userId, fromDate, toDate)
    .all<ProjectionEvent>();
  const completedActivities = await workoutDB(db)
    .prepare(
      `SELECT id, date, kind, name, moving_time_sec, training_load
         FROM external_activities
        WHERE user_id = ?1 AND deleted_at IS NULL
          AND date >= ?2 AND date <= ?3`,
    )
    .bind(userId, fromDate, toDate)
    .all<ProjectionActivity>();
  // NOTE: the `sessions` table has NO soft-delete column (only set_logs and
  // external_events carry deleted_at — see migrations 0001/0006). A session
  // is never soft-deleted; a cancelled/rest day is modelled as a real row
  // with status='skipped', and a thrown-away session as status='discarded'.
  // So there is intentionally no `deleted_at IS NULL` guard here (it would
  // reference a non-existent column). Spurious lift dates are prevented
  // downstream: getRideConflicts' liftDates filter includes only
  // projected|planned|in_progress|completed and EXCLUDES 'skipped'; a
  // 'discarded' session never even reaches that filter because
  // projectCalendar drops it from byDate (vanishes), so it likewise
  // produces no conflict.
  const sessions = await workoutDB(db)
    .prepare(
      'SELECT * FROM sessions WHERE user_id = ?1 AND date >= ?2 AND date <= ?3 ORDER BY date',
    )
    .bind(userId, fromDate, toDate)
    .all<SessionRow>();
  return projectCalendar(
    plan,
    schedule,
    sessions.results,
    fromDate,
    toDate,
    today,
    liveDays.results.map((r) => r.id),
    trips,
    plannedEvents.results,
    completedActivities.results,
  );
}

/** Resolve the schedule to human-readable weekday → day name, for context. */
export async function getResolvedScheduleNames(
  db: D1Database,
  userId: string,
): Promise<Record<Weekday, string | null> | null> {
  const got = await getPlanSchedule(db, userId);
  if (!got) return null;
  const days = await workoutDB(db)
    .prepare('SELECT id, name FROM workouts WHERE plan_id = ?1')
    .bind(got.plan.id)
    .all<{ id: string; name: string }>();
  const nameById = new Map(days.results.map((d) => [d.id, d.name]));
  const out = {} as Record<Weekday, string | null>;
  for (const wd of WEEKDAYS) {
    const id = got.schedule.week[wd];
    out[wd] = id ? nameById.get(id) ?? null : null;
  }
  return out;
}

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
      ? workoutDB(db).prepare(
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
      : workoutDB(db).prepare(
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
      ? await workoutDB(db)
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
      : await workoutDB(db)
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
  const row = await workoutDB(db)
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
      ? workoutDB(db).prepare(
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
      : workoutDB(db).prepare(
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
      ? workoutDB(db).prepare(
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
      : workoutDB(db).prepare(
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
  const [cleared] = await workoutDB(db).batch([
    clear,
    workoutDB(db)
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

type IntervalsOAuthCredential = Extract<
  IntervalsCredentialIdentity,
  { kind: 'oauth' }
>;

type IntervalsOAuthRefreshResult =
  | { status: 'refreshed'; credential: IntervalsOAuthCredential }
  | { status: 'unavailable' }
  | { status: 'superseded' };

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
  const row = await workoutDB(db)
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
  const stored = await workoutDB(db)
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
export async function syncExternalEvents(
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
      workoutDB(db)
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
    workoutDB(db)
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
    workoutDB(db)
      .prepare(
        `SELECT EXISTS(
                  SELECT 1 FROM users
                   WHERE id = ?1 AND intervals_credential_generation = ?2
                     AND intervals_events_sync_attempt = ?3
                ) AS current_identity`,
      )
      .bind(userId, effectiveCredential.generation, attempts.eventsAttempt),
  );

  const reconcileResults = await workoutDB(db).batch(stmts);
  const generationCheck = reconcileResults.at(-1)?.results[0] as
    | { current_identity: number }
    | undefined;
  if (generationCheck?.current_identity !== 1) {
    return { status: 'superseded', synced: 0, detail: 'superseded' };
  }

  const cnt = await workoutDB(db)
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
export async function getUpcomingRides(
  db: D1Database,
  userId: string,
  opts: { from?: string; range?: number } = {},
): Promise<ExternalEventRow[]> {
  const from = opts.from ?? new Date().toISOString().slice(0, 10);
  const to = addDays(from, opts.range ?? 90);
  const r = await workoutDB(db)
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

/** Recent-activity import after an acknowledged connect, or an explicit retry.
 * Failures describe the import and never turn a saved credential into a failed
 * connect acknowledgement. All provider/cache writes retain the existing fence. */
export async function reconcileIntervalsConnection(
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
export async function syncExternalActivities(
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
      workoutDB(db)
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
               external_activities.elevation_gain_m IS NOT excluded.elevation_gain_m
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
               external_activities.elevation_gain_m IS NOT excluded.elevation_gain_m
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
    workoutDB(db)
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
    workoutDB(db)
      .prepare(
        `SELECT EXISTS(
                  SELECT 1 FROM users
                   WHERE id = ?1 AND intervals_credential_generation = ?2
                     AND intervals_activities_sync_attempt = ?3
                ) AS current_identity`,
      )
      .bind(userId, effectiveCredential.generation, attempts.activitiesAttempt),
  );

  const reconcileResults = await workoutDB(db).batch(stmts);
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

  const cnt = await workoutDB(db)
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
export async function getRecentActivities(
  db: D1Database,
  userId: string,
  opts: { to?: string; range?: number; limit?: number } = {},
): Promise<ExternalActivityRow[]> {
  const to = opts.to ?? new Date().toISOString().slice(0, 10);
  const from = addDays(to, -(opts.range ?? 90));
  const limit = Math.max(1, Math.min(500, opts.limit ?? 50));
  const r = await workoutDB(db)
    .prepare(
      `SELECT * FROM external_activities
        WHERE user_id = ?1 AND deleted_at IS NULL
          AND date >= ?2 AND date <= ?3
        ORDER BY date DESC
        LIMIT ?4`,
    )
    .bind(userId, from, to, limit)
    .all<ExternalActivityRow>();
  return r.results;
}

/** A completed activity pushed from the iOS app's HealthKit reader. Mirrors
 *  the intervals-derived CompletedActivity shape but `id` is the CLIENT-supplied
 *  idempotency key (the HKWorkout UUID), not a provider-side external id. */
export interface HealthKitActivityInput {
  id: string; // client UUID = HKWorkout.uuid = idempotency key
  date: string; // device-local YYYY-MM-DD (workout start), verbatim
  // UTC-like encoding of that same local wall clock; its date must agree.
  start_date_local_ms: number | null;
  start_date_utc_ms?: number | null;
  source_timezone?: string | null;
  kind: string; // normalized lowercase (run|ride|walk|…)
  name: string | null;
  moving_time_sec: number | null;
  elapsed_time_sec: number | null;
  distance_m: number | null;
  average_watts: number | null;
  average_hr: number | null;
  max_hr: number | null;
  calories: number | null;
  elevation_gain_m: number | null;
  raw: string | null;
}

/** HealthKit encodes the device-local wall clock as UTC-like epoch ms. */
export function healthKitDateMatchesStart(date: string, startMs: number | null): boolean {
  if (startMs === null) return true;
  if (!Number.isSafeInteger(startMs)) return false;
  const parsed = new Date(startMs);
  return Number.isFinite(parsed.getTime()) && parsed.toISOString().slice(0, 10) === date;
}

/** A conservative native match needs one completed workout with both absolute
 * start and end within two minutes. Missing/ambiguous timing stays unmatched.
 * The prefix distinguishes a session identity from an external-activity id. */
function nativeHealthKitWinnerSQL(a: string): string {
  return `(SELECT 'session:' || MIN(s.id) FROM sessions s
    WHERE s.user_id = ${a}.user_id AND s.status = 'completed'
      AND ${a}.kind = 'strength' AND ${a}.elapsed_time_sec > 0
      AND s.started_at IS NOT NULL AND s.completed_at >= s.started_at
      AND s.started_at BETWEEN ${a}.start_date_utc_ms - 120000 AND ${a}.start_date_utc_ms + 120000
      AND ABS(s.completed_at - (${a}.start_date_utc_ms + ${a}.elapsed_time_sec * 1000)) <= 120000
    HAVING COUNT(*) = 1)`;
}

/** Runs inside the source/session transaction, so completion/discard and the
 * external tombstone become visible together. The prior-change guard keeps
 * rejected session CAS writes side-effect-free. Only native matches or rows
 * previously retired by this path are managed; Intervals' rule stays intact. */
function reconcileNativeHealthKitStatement(
  db: D1Database,
  userId: string,
  ts: number,
  requirePriorChange = false,
): D1PreparedStatement {
  const native = nativeHealthKitWinnerSQL('h');
  return workoutDB(db).prepare(`WITH desired AS MATERIALIZED (
    SELECT h.id, COALESCE(${native}, (
      SELECT id FROM (
        SELECT i.id,
          CASE WHEN i.start_date_utc_ms IS NOT NULL AND h.start_date_utc_ms IS NOT NULL
            THEN 0 ELSE 1 END AS clock_priority,
          CASE WHEN i.start_date_utc_ms IS NOT NULL AND h.start_date_utc_ms IS NOT NULL
            THEN i.start_date_utc_ms ELSE i.start_date_local_ms END AS candidate_start,
          ABS(CASE WHEN i.start_date_utc_ms IS NOT NULL AND h.start_date_utc_ms IS NOT NULL
            THEN i.start_date_utc_ms - h.start_date_utc_ms
            ELSE i.start_date_local_ms - h.start_date_local_ms END) AS delta
        FROM external_activities i WHERE i.user_id = h.user_id AND i.source = 'intervals'
          AND i.deleted_at IS NULL AND i.kind = h.kind
      ) WHERE delta <= 120000 ORDER BY clock_priority, delta, candidate_start, id LIMIT 1
    )) AS winner
    FROM external_activities h WHERE h.user_id = ?1 AND h.source = 'healthkit'
      AND (h.deleted_at IS NULL OR h.duplicate_of IS NOT NULL)
      AND (${native} IS NOT NULL OR h.duplicate_of LIKE 'session:%')
      ${requirePriorChange ? 'AND changes() > 0' : ''}
  ) UPDATE external_activities SET
    duplicate_of = (SELECT winner FROM desired WHERE desired.id = external_activities.id),
    canonical = CASE WHEN (SELECT winner FROM desired WHERE desired.id = external_activities.id) IS NULL THEN 1 ELSE 0 END,
    deleted_at = CASE WHEN (SELECT winner FROM desired WHERE desired.id = external_activities.id) IS NULL THEN NULL ELSE MAX(synced_at + 1, ?2) END,
    synced_at = MAX(synced_at + 1, ?2)
  WHERE id IN (SELECT id FROM desired) AND (
    duplicate_of IS NOT (SELECT winner FROM desired WHERE desired.id = external_activities.id)
    OR (deleted_at IS NULL) != ((SELECT winner FROM desired WHERE desired.id = external_activities.id) IS NULL)
  )`).bind(userId, ts);
}

/**
 * Upsert an Apple Health (HealthKit) workout PUSHED from the iOS app into the
 * external_activities cache. Apple Health is ON-DEVICE only — the Worker can
 * never read HealthKit — so unlike the intervals PULL path this is a client
 * push: the phone reads HKWorkout and POSTs it here (POST /api/activities/healthkit).
 *
 * source='healthkit'. The PK embeds the user + the client id (the HKWorkout
 * UUID), making it the idempotency key: a re-push (iOS outbox retry, or a later
 * anchored sync that re-sees the same workout) lands on ON CONFLICT and UPDATEs
 * the stats in place (HealthKit can revise a workout's totals) rather than
 * duplicating. PUSH rows are NEVER reconcile-soft-deleted — the intervals sync's
 * windowed tombstoning is source-scoped to 'intervals' (migration 0027), and a
 * HealthKit deletion is an explicit future delete path, not a windowed reconcile.
 *
 * training_load / intensity are intentionally left NULL: HealthKit carries no
 * native TSS and we have no per-user HR anchor (LTHR/max-HR) to derive hrTSS
 * yet, so we do NOT fabricate a load number — the coach reads average_hr +
 * duration directly. A per-user HR-anchor setting that unlocks hrTSS is a
 * tracked follow-up (docs/MULTISOURCE-INGESTION.md).
 */
export async function upsertHealthKitActivity(
  db: D1Database,
  userId: string,
  input: HealthKitActivityInput,
): Promise<ExternalActivityRow> {
  if (!healthKitDateMatchesStart(input.date, input.start_date_local_ms)) {
    throw new Error('healthkit_date_start_mismatch');
  }
  if (!validActivitySourceTime(input.start_date_utc_ms, input.source_timezone, input.date, input.start_date_local_ms)) {
    throw new Error('healthkit_source_time_invalid');
  }
  const id = `healthkit:activity:${userId}:${input.id}`;
  const ts = now();
  await workoutDB(db).batch([
    workoutDB(db)
    .prepare(
      `INSERT INTO external_activities
         (id,user_id,source,external_id,date,start_date_local_ms,kind,name,
          moving_time_sec,elapsed_time_sec,distance_m,average_watts,
          weighted_avg_watts,average_hr,max_hr,training_load,intensity,
          calories,elevation_gain_m,raw,synced_at,deleted_at,canonical,duplicate_of,start_date_utc_ms,source_timezone)
       VALUES (?1,?2,'healthkit',?3,?4,?5,?6,?7,?8,?9,?10,?11,NULL,?12,?13,NULL,NULL,
               ?14,?15,?16,?17,NULL,1,NULL,?18,?19)
       ON CONFLICT(id) DO UPDATE SET
         start_date_utc_ms=COALESCE(external_activities.start_date_utc_ms, excluded.start_date_utc_ms),
         source_timezone=CASE WHEN external_activities.start_date_utc_ms IS NULL
           AND external_activities.start_date_local_ms IS excluded.start_date_local_ms
           THEN excluded.source_timezone ELSE external_activities.source_timezone END,
         kind=excluded.kind,
         name=excluded.name,
         moving_time_sec=excluded.moving_time_sec,
         elapsed_time_sec=excluded.elapsed_time_sec,
         distance_m=excluded.distance_m,
         average_watts=excluded.average_watts,
         average_hr=excluded.average_hr,
         max_hr=excluded.max_hr,
         calories=excluded.calories,
         elevation_gain_m=excluded.elevation_gain_m,
         raw=excluded.raw,
         synced_at=CASE
           WHEN excluded.synced_at > external_activities.synced_at THEN excluded.synced_at
           ELSE external_activities.synced_at + 1
         END,
         deleted_at=NULL,
         canonical=1,
         duplicate_of=NULL
       WHERE (external_activities.start_date_utc_ms IS NULL AND excluded.start_date_utc_ms IS NOT NULL) OR
         external_activities.kind IS NOT excluded.kind OR
         external_activities.name IS NOT excluded.name OR
         external_activities.moving_time_sec IS NOT excluded.moving_time_sec OR
         external_activities.elapsed_time_sec IS NOT excluded.elapsed_time_sec OR
         external_activities.distance_m IS NOT excluded.distance_m OR
         external_activities.average_watts IS NOT excluded.average_watts OR
         external_activities.average_hr IS NOT excluded.average_hr OR
         external_activities.max_hr IS NOT excluded.max_hr OR
         external_activities.calories IS NOT excluded.calories OR
         external_activities.elevation_gain_m IS NOT excluded.elevation_gain_m`,
    )
    .bind(
      id,
      userId,
      input.id,
      input.date,
      input.start_date_local_ms,
      input.kind,
      input.name,
      input.moving_time_sec,
      input.elapsed_time_sec,
      input.distance_m,
      input.average_watts,
      input.average_hr,
      input.max_hr,
      input.calories,
      input.elevation_gain_m,
      input.raw,
      ts,
      input.start_date_utc_ms ?? null,
      input.source_timezone ?? null,
    ),
    reconcileNativeHealthKitStatement(db, userId, ts),
  ]);
  // Existing cross-source dedup: if this workout also exists from
  // intervals.icu, retire the HealthKit copy so it isn't shown/counted twice.
  // Runs AFTER the upsert so a real HealthKit revision resets prior provenance
  // and is immediately re-deduped. An identical retry does not update/reset the
  // row; this idempotent pass therefore preserves an already-retired duplicate.
  await dedupeHealthKitAgainstIntervals(db, userId);
  const row = await workoutDB(db)
    .prepare('SELECT * FROM external_activities WHERE id = ?1 AND user_id = ?2')
    .bind(id, userId)
    .first<ExternalActivityRow>();
  if (!row) throw new Error('healthkit_activity_insert_failed');
  return row;
}

/** Existing cross-source matching tolerance, applied to the shared clock:
 * source instants when both are known, otherwise legacy local wall time. */
export const ACTIVITY_DEDUP_TOLERANCE_MS = 2 * 60 * 1000;

export interface ActivityDedupeWindow {
  /** Inclusive device-local range containing HealthKit rows that may change. */
  healthKitFromDate: string;
  healthKitToDate: string;
  /** Inclusive wider range containing every possible intervals winner. */
  intervalsFromDate: string;
  intervalsToDate: string;
}

/**
 * Cross-source dedup: retire HealthKit activities that duplicate an
 * intervals.icu activity for the same user. The same physical workout can
 * arrive from BOTH sources (e.g. a Zwift ride synced into intervals AND mirrored
 * into Apple Health); without this it would be shown and counted twice.
 *
 * Rule (deterministic, order-independent — so it's correct whichever source
 * lands first): a non-deleted `healthkit` row is a duplicate of a non-deleted
 * `intervals` row when they share the same `kind` and start within
 * ACTIVITY_DEDUP_TOLERANCE_MS, comparing source instants when BOTH are known.
 * Only a missing instant permits the legacy local-clock comparison; different
 * known instants must not match merely because the wall clocks agree (DST).
 * Absolute matches take priority over legacy matches, then selection is stable
 * by (absolute delta, candidate start on the selected clock, id), ascending.
 * Intervals wins this pair (richer data — power,
 * native TSS), so the HealthKit copy is the one retired. A unique native
 * strength match takes precedence and is excluded at both read and write time.
 *
 * "Retire" = soft-delete the loser (set deleted_at) + record provenance
 * (canonical=0, duplicate_of=<intervals id>). Using deleted_at as the exclusion
 * mechanism means every existing read path (getRecentActivities, projectCalendar,
 * group feed/stats/series — all already filter deleted_at) and the /api/state
 * tombstone delta Just Work with no new filters and no iOS change. synced_at is
 * advanced so the change reaches incremental sync clients.
 *
 * BIDIRECTIONAL (Codex P2 follow-up): this is a full reconciliation by default,
 * not a one-way retire. A caller that changed only a bounded date range may
 * provide a HealthKit candidate range plus a wider intervals-winner range
 * without scanning unrelated history. It also RESTORES a previously-retired
 * HealthKit row when its intervals winner later disappears (the activity is
 * removed upstream → the intervals sync soft-deletes the canonical row, then
 * calls this). Without restoration, both copies stay hidden until the phone
 * re-pushes the workout. A HealthKit row soft-deleted for any OTHER reason
 * (duplicate_of IS NULL) is left untouched — we only manage rows WE retired.
 *
 * Idempotent: only state CHANGES emit a write (no synced_at churn in steady
 * state). Deterministic + order-independent — called from BOTH write paths (the
 * HealthKit push and the intervals sync) so it converges whichever source lands
 * (or leaves) first. Surfacing the duplicate's provenance in the UI ("also from
 * Apple Health") is a future enhancement (needs an iOS field).
 */
export async function dedupeHealthKitAgainstIntervals(
  db: D1Database,
  userId: string,
  window?: ActivityDedupeWindow,
  expectedIntervalsFence?: { generation: number; attempt: number },
): Promise<number> {
  const dateClause = window ? ' AND date >= ?2 AND date <= ?3' : '';
  // HealthKit rows we manage: currently live (candidates to retire) OR
  // previously retired BY US as a dup (deleted_at + duplicate_of set →
  // candidates to RESTORE if their winner is gone).
  const hkStatement = workoutDB(db).prepare(
    `SELECT id, kind, start_date_local_ms, start_date_utc_ms, deleted_at, duplicate_of
       FROM external_activities
      WHERE user_id = ?1 AND source = 'healthkit'
        AND (start_date_local_ms IS NOT NULL OR start_date_utc_ms IS NOT NULL)
        AND (deleted_at IS NULL OR duplicate_of IS NOT NULL)
        AND ${nativeHealthKitWinnerSQL('external_activities')} IS NULL${dateClause}`,
  );
  const hk = (
    await (window
      ? hkStatement.bind(userId, window.healthKitFromDate, window.healthKitToDate)
      : hkStatement.bind(userId))
      .all<{
        id: string;
        kind: string;
        start_date_local_ms: number | null;
        start_date_utc_ms: number | null;
        deleted_at: number | null;
        duplicate_of: string | null;
      }>()
  ).results;
  if (hk.length === 0) return 0;
  // Live intervals winners (NOT early-returned on empty: with no live winner,
  // any retired dup must be RESTORED).
  const ivStatement = workoutDB(db).prepare(
    `SELECT id, kind, start_date_local_ms, start_date_utc_ms FROM external_activities
      WHERE user_id = ?1 AND source = 'intervals' AND deleted_at IS NULL
        AND (start_date_local_ms IS NOT NULL OR start_date_utc_ms IS NOT NULL)${dateClause}`,
  );
  const iv = (
    await (window
      ? ivStatement.bind(userId, window.intervalsFromDate, window.intervalsToDate)
      : ivStatement.bind(userId))
      .all<{ id: string; kind: string; start_date_local_ms: number | null; start_date_utc_ms: number | null }>()
  ).results;

  // Index candidates by kind and time once. The old nested scan compared every
  // HealthKit row with every intervals row (O(H*I)); the sorted buckets make
  // each nearest-match lookup O(log I + candidates within the tolerance).
  type Candidate = { id: string; start: number };
  type ClockIndex = Map<string, Candidate[]>;
  const absolute: ClockIndex = new Map();
  const local: ClockIndex = new Map();
  const legacyLocal: ClockIndex = new Map();
  const index = (clock: ClockIndex, kind: string, id: string, start: number | null) => {
    if (start === null) return;
    const candidates = clock.get(kind) ?? [];
    candidates.push({ id, start });
    clock.set(kind, candidates);
  };
  for (const candidate of iv) {
    index(absolute, candidate.kind, candidate.id, candidate.start_date_utc_ms);
    index(local, candidate.kind, candidate.id, candidate.start_date_local_ms);
    if (candidate.start_date_utc_ms === null) {
      index(legacyLocal, candidate.kind, candidate.id, candidate.start_date_local_ms);
    }
  }
  for (const clock of [absolute, local, legacyLocal]) {
    for (const candidates of clock.values()) {
      candidates.sort((a, b) => a.start - b.start || (a.id < b.id ? -1 : 1));
    }
  }
  const nearest = (clock: ClockIndex, kind: string, start: number | null): Candidate | null => {
    if (start === null) return null;
    let best: Candidate | null = null;
    let bestDelta = Infinity;
    const candidates = clock.get(kind) ?? [];
    const earliest = start - ACTIVITY_DEDUP_TOLERANCE_MS;
    const latest = start + ACTIVITY_DEDUP_TOLERANCE_MS;
    let low = 0;
    let high = candidates.length;
    while (low < high) {
      const middle = Math.floor((low + high) / 2);
      if (candidates[middle]!.start < earliest) low = middle + 1;
      else high = middle;
    }
    for (let i = low; i < candidates.length; i += 1) {
      const v = candidates[i]!;
      if (v.start > latest) break;
      const delta = Math.abs(v.start - start);
      // Buckets are sorted by start then id, so equal deltas keep the first.
      if (delta < bestDelta) {
        bestDelta = delta;
        best = v;
      }
    }
    return best;
  };

  const ts = now();
  const stmts: D1PreparedStatement[] = [];
  for (const h of hk) {
    const best = h.start_date_utc_ms === null
      ? nearest(local, h.kind, h.start_date_local_ms)
      : nearest(absolute, h.kind, h.start_date_utc_ms)
        ?? nearest(legacyLocal, h.kind, h.start_date_local_ms);
    const isRetiredDup = h.deleted_at != null && h.duplicate_of != null;
    if (best && !isRetiredDup) {
      // Live HealthKit row duplicating a live intervals activity → retire it.
      const statement = workoutDB(db).prepare(
            `UPDATE external_activities
                SET deleted_at = CASE
                      WHEN ?2 > synced_at THEN ?2 ELSE synced_at + 1
                    END,
                    synced_at = CASE
                      WHEN ?2 > synced_at THEN ?2 ELSE synced_at + 1
                    END,
                    canonical = 0,
                    duplicate_of = ?3
              WHERE id = ?1 AND ${nativeHealthKitWinnerSQL('external_activities')} IS NULL${
                expectedIntervalsFence === undefined
                  ? ''
                  : ` AND EXISTS (
                          SELECT 1 FROM users
                           WHERE id = ?4 AND intervals_credential_generation = ?5
                             AND intervals_activities_sync_attempt = ?6
                        )`
              }`,
      );
      stmts.push(
        expectedIntervalsFence === undefined
          ? statement.bind(h.id, ts, best.id)
          : statement.bind(
              h.id,
              ts,
              best.id,
              userId,
              expectedIntervalsFence.generation,
              expectedIntervalsFence.attempt,
            ),
      );
    } else if (best && h.duplicate_of !== best.id) {
      // The row is already retired, but the deterministic winner changed.
      // Advance the tombstone watermark so downstream clients receive the
      // corrected provenance instead of retaining a stale duplicate_of.
      const statement = workoutDB(db).prepare(
            `UPDATE external_activities
                SET synced_at = CASE
                      WHEN ?2 > synced_at THEN ?2 ELSE synced_at + 1
                    END,
                    duplicate_of = ?3
              WHERE id = ?1 AND ${nativeHealthKitWinnerSQL('external_activities')} IS NULL${
                expectedIntervalsFence === undefined
                  ? ''
                  : ` AND EXISTS (
                          SELECT 1 FROM users
                           WHERE id = ?4 AND intervals_credential_generation = ?5
                             AND intervals_activities_sync_attempt = ?6
                        )`
              }`,
      );
      stmts.push(
        expectedIntervalsFence === undefined
          ? statement.bind(h.id, ts, best.id)
          : statement.bind(
              h.id,
              ts,
              best.id,
              userId,
              expectedIntervalsFence.generation,
              expectedIntervalsFence.attempt,
            ),
      );
    } else if (!best && isRetiredDup) {
      // We retired this as a dup but its intervals winner is gone → restore it
      // as the surviving copy so the workout doesn't vanish.
      const statement = workoutDB(db).prepare(
            `UPDATE external_activities
                SET deleted_at = NULL,
                    synced_at = CASE
                      WHEN ?2 > synced_at THEN ?2 ELSE synced_at + 1
                    END,
                    canonical = 1,
                    duplicate_of = NULL
              WHERE id = ?1 AND ${nativeHealthKitWinnerSQL('external_activities')} IS NULL${
                expectedIntervalsFence === undefined
                  ? ''
                  : ` AND EXISTS (
                          SELECT 1 FROM users
                           WHERE id = ?3 AND intervals_credential_generation = ?4
                             AND intervals_activities_sync_attempt = ?5
                        )`
              }`,
      );
      stmts.push(
        expectedIntervalsFence === undefined
          ? statement.bind(h.id, ts)
          : statement.bind(
              h.id,
              ts,
              userId,
              expectedIntervalsFence.generation,
              expectedIntervalsFence.attempt,
            ),
      );
    }
    // else: already correct (live with no match, or retired with winner still
    // present) → no-op, so steady-state syncs don't churn synced_at.
  }
  if (stmts.length === 0) return 0;
  const results = await workoutDB(db).batch(stmts);
  return results.reduce((total, result) => total + (result.meta.changes ?? 0), 0);
}

/** Scheduling heuristic, mirrored by Swift. These fixed thresholds use only
 * planned endurance load/duration and lift dates; they cannot establish
 * individualized interference or safety. One missing measure leaves context
 * incomplete even when the other is known. Same-day takes priority. */
export function detectConflicts(
  liftDates: Iterable<string>,
  events: Pick<ExternalEventRow, 'id' | 'date' | 'training_load' | 'planned_duration_sec'>[],
): DayConflict[] {
  const byDate = new Map<string, typeof events>();
  for (const e of events) {
    const arr = byDate.get(e.date);
    if (arr) arr.push(e);
    else byDate.set(e.date, [e]);
  }
  const isHard = (e: { training_load: number | null; planned_duration_sec: number | null }) =>
    (e.training_load ?? 0) >= 150 || (e.planned_duration_sec ?? 0) >= 9000;

  const out: DayConflict[] = [];
  // Dedupe + stable order: iterate sorted unique lift dates.
  const dates = [...new Set(liftDates)].sort();
  for (const d of dates) {
    const sameDay = byDate.get(d);
    if (sameDay && sameDay.length) {
      // Known threshold evidence wins; missing inputs never mean easy work.
      const severity: DayConflict['severity'] = sameDay.some(isHard) ? 'clash'
        : sameDay.some(e => e.training_load == null || e.planned_duration_sec == null) ? 'unknown' : 'brick';
      out.push({ date: d, conflicts: sameDay.map((e) => e.id), severity });
      continue;
    }
    const next = byDate.get(addDays(d, 1));
    if (next) {
      const hard = next.filter(isHard);
      if (hard.length) {
        out.push({ date: d, conflicts: hard.map((e) => e.id), severity: 'heavy-next-day' });
      } else {
        const incomplete = next.filter(e => e.training_load == null || e.planned_duration_sec == null);
        if (incomplete.length) out.push({ date: d, conflicts: incomplete.map(e => e.id), severity: 'unknown' });
      }
    }
  }
  return out;
}

/**
 * Data-layer convenience: collect lift dates from the projected calendar in
 * a window and run detectConflicts against the live ride cache. Pure read.
 */
export async function getRideConflicts(
  db: D1Database,
  userId: string,
  fromDate: string,
  toDate: string,
  today: string,
): Promise<DayConflict[]> {
  // Conflict detection reads one day beyond the visible range for its
  // next-day warning, so projection/suppression must cover that same day.
  const cal = await getProjectedCalendar(db, userId, fromDate, toDate, today);
  // `projectCalendar` intentionally caps one call at 90 cells. Probe the
  // visible boundary separately so a max-range request still learns that the
  // day after its final projected lift is a hard blackout. Without this small
  // window, a hard ride suppressed on that blackout could leak back as a
  // false heavy-next-day conflict.
  const boundaryCal = await getProjectedCalendar(
    db, userId, toDate, addDays(toDate, 1), today,
  );
  const suppressedDates = new Set(
    [...cal, ...boundaryCal]
      .filter((c) => c.suppresses_schedule_and_endurance === true)
      .map((c) => c.date),
  );
  // A LIFT date carries actual STRENGTH (the conflict subject) — NOT a pure
  // endurance day. The composite projection now also reports 'projected'/
  // 'completed' for endurance-only days, distinguishable by the absence of a
  // strength template/session: a real strength session (planned|in_progress|
  // completed) OR a projected strength template (workout_id != null).
  // 'skipped' lifts and pure-endurance cells (workout_id == null and
  // !real) are excluded, keeping the prior contract intact.
  const liftDates = cal
    .filter(
      (c) =>
        c.date <= toDate &&
        !c.suppresses_schedule_and_endurance &&
        ((c.real && (c.status === 'planned' || c.status === 'in_progress' || c.status === 'completed')) ||
          (c.status === 'projected' && c.workout_id != null)),
    )
    .map((c) => c.date);
  const events = await workoutDB(db)
    .prepare(
      `SELECT id, date, training_load, planned_duration_sec
         FROM external_events
        WHERE user_id = ?1 AND deleted_at IS NULL
          AND date >= ?2 AND date <= ?3`,
    )
    .bind(userId, fromDate, addDays(toDate, 1))
    .all<Pick<ExternalEventRow, 'id' | 'date' | 'training_load' | 'planned_duration_sec'>>();
  return detectConflicts(
    liftDates,
    events.results.filter((event) => !suppressedDates.has(event.date)),
  );
}

// ---- M4: group feed + stats ---------------------------------------------
//
// Group accountability surface. The feed merges three sources into a single
// time-ordered stream of FeedItems (session | ride | activity); the stats
// roll up per-member workout_count + streak_days over a rolling window.
//
// Privacy contract (do not break — this is the trust substrate that lets
// the feature ship):
//   * Strength sessions: SHARE date, completed_at, day_name, set_count,
//     duration_sec, per-exercise top set (exercise name + load/reps or hold
//     duration per compatible load/mode, plus Epley only for conventional
//     positive-load rep work). HIDE
//     session.notes, session.perceived_fatigue, every
//     set's `notes`, every set's `rpe`.
//   * Intervals.icu rides: SHARE all the ride metrics (these are not
//     personal). Soft-deleted rows are excluded.
//   * Activities (M3): SHARE type, title, duration_minutes, notes (the
//     user-authored notes ARE the description of what they did — sharing
//     them is the point). Soft-deleted rows are excluded.
//
// Wire shape matches `.context/m5-ios-spec.md` §5 verbatim: discriminated
// on `type` with nested `session`/`ride`/`activity` inner objects, plus
// `id, user_id, user_display_name, occurred_at, date` at the top level.
// `is_me` is server-stamped so the iOS client does not have to compare
// user ids manually.

const FEED_LIMIT_DEFAULT = 30;
const FEED_LIMIT_MAX = 100;

/** Per-feed-item shapes the wire emits. Matches iOS m5-ios-spec.md §5. */
export interface FeedSessionItem {
  type: 'session';
  id: string;
  user_id: string;
  user_display_name: string;
  is_me: boolean;
  date: string;
  occurred_at: number;
  session: {
    day_name: string | null;
    day_label: string | null;
    duration_sec: number | null;
    set_count: number;
    cohort_top_sets: FeedSessionItem['session']['top_sets'];
    top_sets: Array<{
      cohort_key: string;
      exercise_id: string;
      laterality: string;
      load_mode: string;
      exercise: string;
      weight: number;
      reps: number;
      unit: string | null;
      modality: string;
      duration_s: number | null;
      is_timed: boolean;
      /** Kept numeric for installed iOS clients whose decoder predates the
       * metric fields. Zero means unavailable; current clients hide it. */
      est_1rm: number;
    }>;
  };
}
export interface FeedRideItem {
  type: 'ride';
  id: string;
  user_id: string;
  user_display_name: string;
  is_me: boolean;
  date: string;
  occurred_at: number;
  ride: {
    kind: string;
    name: string | null;
    distance_m: number | null;
    moving_time_sec: number | null;
    average_watts: number | null;
    training_load: number | null;
    elevation_gain_m: number | null;
  };
}
export interface FeedActivityItem {
  type: 'activity';
  id: string;
  user_id: string;
  user_display_name: string;
  is_me: boolean;
  date: string;
  occurred_at: number;
  activity: {
    kind: string;
    title: string | null;
    duration_min: number | null;
    notes: string | null;
  };
}
export type FeedItem = FeedSessionItem | FeedRideItem | FeedActivityItem;

/**
 * Two-character avatar initials from a display name. "Sarah Kim" -> "SK",
 * "nick" -> "N", "" -> "?". Pure, locale-stable (uppercased once at the
 * end). Per-member initials live on MemberStat so the iOS chip strip
 * doesn't have to recompute.
 */
function avatarInitials(name: string | null | undefined): string {
  const s = (name ?? '').trim();
  if (s.length === 0) return '?';
  // Split on whitespace, take first letter of first two non-empty words.
  const words = s.split(/\s+/).filter((w) => w.length > 0);
  if (words.length === 0) return '?';
  if (words.length === 1) return words[0]!.charAt(0).toUpperCase();
  return (words[0]!.charAt(0) + words[1]!.charAt(0)).toUpperCase();
}

/**
 * Resolve effective display name for a member. Order:
 *   1. per-group nickname (group_members.display_name)
 *   2. user's global display name (users.display_name)
 *   3. email prefix (everything before '@')
 *   4. literal "Member"
 * Pure function; the caller pre-joins the three input columns.
 */
function resolveDisplayName(
  perGroup: string | null,
  global: string | null,
  email: string | null,
): string {
  if (perGroup && perGroup.length > 0) return perGroup;
  if (global && global.length > 0) return global;
  if (email && email.length > 0) {
    const at = email.indexOf('@');
    const pre = at > 0 ? email.slice(0, at) : email;
    if (pre.length > 0) return pre;
  }
  return 'Member';
}

export interface MemberStat {
  user_id: string;
  display_name: string;
  avatar_initials: string;
  is_me: boolean;
  workout_count: number;
  streak_days: number;
  last_active: number | null;
}

/**
 * Group feed. Returns up to `limit` FeedItems strictly OLDER than the
 * cursor (when both `sinceMs` and `sinceId` are null → no upper bound,
 * get the most recent N). Items are ordered by `(occurred_at, id)` DESC.
 *
 * The cursor is COMPOSITE on `(occurred_at, id)` so ties at the page
 * boundary don't drop items: when N rows share an occurred_at timestamp
 * (bulk sync / two activities logged in the same millisecond), a plain
 * "occurred_at < since" cursor would skip every remaining tied row. The
 * filter is "occurred_at < ?upper OR (occurred_at = ?upper AND id < ?upperId)".
 *
 * NOTE: callers MUST enforce group membership BEFORE calling this — the
 * function itself trusts the caller has done the auth check. Same pattern
 * as createInvite / setGroupDisplayName.
 */
export async function getGroupFeed(
  db: D1Database,
  groupId: string,
  sinceMs: number | null,
  sinceId: string | null,
  limit: number,
  callerUserId: string,
): Promise<FeedItem[]> {
  const cap = Math.max(1, Math.min(limit, FEED_LIMIT_MAX));
  // Composite upper-bound cursor. `upper` is the timestamp; `upperId` is
  // the tiebreaker for items with that exact timestamp. When sinceMs is
  // null we treat the timestamp as infinity (no upper bound) and the
  // tiebreaker is irrelevant.
  //
  // When the caller passes since but NO since_id (a legacy/first-page
  // request), we deliberately collapse to STRICT `occurred_at < upper`
  // semantics — the tiebreaker would otherwise return rows the previous
  // page already returned (their occurred_at = upper). We do this by
  // setting upperId to the empty string: SQLite's lexicographic `id < ''`
  // is always false for non-empty UUIDs, so the tiebreaker OR branch is
  // dead. Composite cursor only activates when the caller passes BOTH.
  const upper = sinceMs ?? Number.MAX_SAFE_INTEGER;
  const upperId = sinceId ?? '';

  // 1. Resolve group members + their effective display names + email
  //    fallback. Join into a single row per user_id for the join later.
  const memberRows = { results: await visibleGroupMembers(db, groupId, callerUserId) };
  if (memberRows.results.length === 0) return [];

  const memberMeta = new Map<string, { displayName: string }>();
  const memberIds: string[] = [];
  for (const m of memberRows.results) {
    memberMeta.set(m.user_id, {
      displayName: sharedText(resolveDisplayName(m.per_group_name, m.global_name, m.email), 'Member')!,
    });
    memberIds.push(m.user_id);
  }

  const placeholders = memberIds.map((_, i) => `?${i + 1}`).join(',');

  // Over-pull each source by `cap` so the post-merge slice still has
  // enough items in the worst case (one source dominates the window).
  // The merge-then-slice keeps the SQL simple at the cost of fetching up
  // to 3*cap rows. Friends/family scale: <10 members, ~30 limit → trivial.
  const sourceLimit = cap;

  // 2a. Strength sessions. We surface "item timestamp" = completed_at if
  //     the session is completed, else created_at — sessions still
  //     in_progress show as "currently doing X" rows so groupmates see
  //     today's lift as it's happening. Discarded sessions are excluded.
  const sessionRows = await workoutDB(db)
    .prepare(
      `SELECT s.id,
              s.user_id,
              s.date,
              s.status,
              s.completed_at,
              s.created_at,
              s.workout_id,
              dt.name AS day_name,
              dt.day_label AS day_label,
              s.started_at,
              COALESCE(s.completed_at, s.created_at) AS occurred_at
         FROM sessions s
         LEFT JOIN workouts dt ON dt.id = s.workout_id
        WHERE s.user_id IN (${placeholders})
          -- Codex PR#36 P2: opening Today calls getOrCreateSession which
          -- creates status='planned' rows BEFORE any set is logged. Those
          -- aren't activity, they're intent — keep them out of the feed
          -- so a groupmate who just glanced at Today doesn't show up as
          -- a 0-set "session" item. Only started/completed sessions are
          -- real activity worth surfacing.
          AND s.status IN ('in_progress', 'completed')
          AND (
            COALESCE(s.completed_at, s.created_at) < ?${memberIds.length + 1}
            OR (
              COALESCE(s.completed_at, s.created_at) = ?${memberIds.length + 1}
              AND s.id < ?${memberIds.length + 2}
            )
          )
        ORDER BY occurred_at DESC, s.id DESC
        LIMIT ?${memberIds.length + 3}`,
    )
    .bind(...memberIds, upper, upperId, sourceLimit)
    .all<{
      id: string;
      user_id: string;
      date: string;
      status: string;
      completed_at: number | null;
      created_at: number;
      workout_id: string | null;
      day_name: string | null;
      day_label: string | null;
      started_at: number | null;
      occurred_at: number;
    }>();

  // 2b. Top sets — single query keyed by session_id IN (...). Aggregating
  //     in JS keeps the SQL portable; D1 (SQLite) doesn't have window
  //     functions on every version path. Warmups excluded; soft-deleted
  //     sets excluded. We pre-join exercises so we get the display name.
  const sessionIds = sessionRows.results.map((s) => s.id);
  const topSetsBySession = new Map<string, FeedSessionItem['session']['top_sets']>();
  const setCountBySession = new Map<string, number>();
  if (sessionIds.length > 0) {
    const setPlaceholders = sessionIds.map((_, i) => `?${i + 1}`).join(',');
    const sets = await workoutDB(db)
      .prepare(
        `SELECT sl.session_id,
                sl.exercise_id,
                sl.weight,
                sl.reps,
                sl.duration_s,
                sl.is_timed,
                e.name AS exercise_name,
                e.unit AS exercise_unit,
                e.modality AS exercise_modality,
                e.laterality, e.load_mode
           FROM set_logs sl
           JOIN exercises e ON e.id = sl.exercise_id
          WHERE sl.session_id IN (${setPlaceholders})
            AND sl.deleted_at IS NULL
            AND sl.is_warmup = 0`,
      )
      .bind(...sessionIds)
      .all<{
        session_id: string;
        exercise_id: string;
        weight: number;
        reps: number;
        duration_s: number | null;
        is_timed: number;
        exercise_name: string;
        exercise_unit: string;
        exercise_modality: string;
        laterality: string;
        load_mode: string;
      }>();
    const acc = new Map<string, Map<string, typeof sets.results>>();
    for (const row of sets.results) {
      setCountBySession.set(row.session_id, (setCountBySession.get(row.session_id) ?? 0) + 1);
      const perSession = acc.get(row.session_id) ?? new Map();
      const candidates = perSession.get(row.exercise_id) ?? [];
      candidates.push(row);
      perSession.set(row.exercise_id, candidates);
      acc.set(row.session_id, perSession);
    }
    for (const [sid, perExercise] of acc) {
      const list = [...perExercise.values()].flatMap((rows) => {
        const exercise = rows[0]!;
        return metricCohorts(rows, {
          modality: exercise.exercise_modality, unit: exercise.exercise_unit,
          laterality: exercise.laterality, load_mode: exercise.load_mode,
        }).map((cohort) => ({
          cohort_key: cohort.key,
          exercise_id: exercise.exercise_id,
          exercise: exercise.exercise_name,
          unit: exercise.exercise_unit,
          modality: exercise.exercise_modality,
          laterality: exercise.laterality,
          load_mode: exercise.load_mode,
          weight: cohort.top.weight,
          reps: cohort.top.reps,
          duration_s: cohort.top.duration_s,
          is_timed: cohort.is_timed,
          // Installed clients require a number: zero is the unavailable sentinel.
          est_1rm: cohort.est_1rm ?? 0,
        }));
      });
      list.sort((a, b) => a.exercise.localeCompare(b.exercise)
        || Number(a.is_timed) - Number(b.is_timed) || a.weight - b.weight);
      topSetsBySession.set(sid, list);
    }
  }

  // Older clients key top_sets by exercise name. Keep one conventional
  // estimate, or a single comparable condition; omit incompatible BW/holds
  // rather than imply an overall winner. New clients use cohort_top_sets.
  const legacyTopSets = (sets: FeedSessionItem['session']['top_sets']) => {
    const byExercise = new Map<string, typeof sets>();
    for (const set of sets) {
      const rows = byExercise.get(set.exercise_id) ?? [];
      rows.push(set);
      byExercise.set(set.exercise_id, rows);
    }
    return [...byExercise.values()].flatMap((rows) => {
      if (rows.length === 1) return rows;
      const estimated = rows.filter((row) => row.est_1rm > 0);
      return estimated.length ? [estimated.reduce((best, row) =>
        row.est_1rm > best.est_1rm ? row : best)] : [];
    });
  };
  const sessionItems: FeedSessionItem[] = sessionRows.results.map((s) => ({
    type: 'session',
    id: s.id,
    user_id: s.user_id,
    user_display_name: memberMeta.get(s.user_id)?.displayName ?? 'Member',
    is_me: s.user_id === callerUserId,
    date: s.date,
    occurred_at: s.occurred_at,
    session: {
      day_name: sharedText(s.day_name),
      day_label: sharedText(s.day_label),
      // duration_sec is only meaningful once the session is completed;
      // a still-in-progress session emits null (matches calendar.ts).
      duration_sec:
        s.started_at != null && s.completed_at != null
          ? Math.max(0, Math.round((s.completed_at - s.started_at) / 1000))
          : null,
      set_count: setCountBySession.get(s.id) ?? 0,
      top_sets: legacyTopSets(topSetsBySession.get(s.id) ?? []),
      cohort_top_sets: topSetsBySession.get(s.id) ?? [],
    },
  }));

  // 2c. Rides (external_activities). Order by `start_date_local_ms`
  //     (migration 0019) — the actual workout start time. `synced_at`
  //     used to be the proxy but it rewrites on every cron tick, which
  //     bubbled every recent ride to the top of the feed after each
  //     sync and broke pagination. COALESCE handles any legacy row that
  //     somehow escaped the migration backfill (defensive — should not
  //     happen on a freshly-migrated DB).
  const rideRows = await workoutDB(db)
    .prepare(
      `SELECT id, user_id, date, kind, name, moving_time_sec, distance_m,
              average_watts, training_load, elevation_gain_m,
              COALESCE(start_date_local_ms, synced_at) AS occurred_at
         FROM external_activities
        WHERE user_id IN (${placeholders})
          AND deleted_at IS NULL
          -- Codex P1 / migration 0028: a member's HealthKit activities are
          -- private until they opt into group sharing. intervals rows are
          -- unaffected (its terms permit cross-user display).
          AND (source <> 'healthkit'
               OR (SELECT share_health_activities FROM users
                     WHERE id = external_activities.user_id) = 1)
          AND (
            COALESCE(start_date_local_ms, synced_at) < ?${memberIds.length + 1}
            OR (
              COALESCE(start_date_local_ms, synced_at) = ?${memberIds.length + 1}
              AND id < ?${memberIds.length + 2}
            )
          )
        ORDER BY COALESCE(start_date_local_ms, synced_at) DESC, id DESC
        LIMIT ?${memberIds.length + 3}`,
    )
    .bind(...memberIds, upper, upperId, sourceLimit)
    .all<{
      id: string;
      user_id: string;
      date: string;
      kind: string;
      name: string | null;
      moving_time_sec: number | null;
      distance_m: number | null;
      average_watts: number | null;
      training_load: number | null;
      elevation_gain_m: number | null;
      occurred_at: number;
    }>();

  const rideItems: FeedRideItem[] = rideRows.results.map((r) => ({
    type: 'ride',
    id: r.id,
    user_id: r.user_id,
    user_display_name: memberMeta.get(r.user_id)?.displayName ?? 'Member',
    is_me: r.user_id === callerUserId,
    date: r.date,
    occurred_at: r.occurred_at,
    ride: {
      kind: sharedText(r.kind)!,
      name: sharedText(r.name),
      distance_m: r.distance_m,
      moving_time_sec: r.moving_time_sec,
      average_watts: r.average_watts,
      training_load: r.training_load,
      elevation_gain_m: r.elevation_gain_m,
    },
  }));

  // 2d. Activities (M3 generic log). Soft-deleted rows excluded. The wire
  //     `notes` field IS shared — per the privacy contract above, the
  //     user-authored notes on an activity are the description of what
  //     they did.
  const actRows = await workoutDB(db)
    .prepare(
      `SELECT id, user_id, date, type, title, duration_minutes, notes, logged_at
         FROM activities
        WHERE user_id IN (${placeholders})
          AND deleted_at IS NULL
          AND (
            logged_at < ?${memberIds.length + 1}
            OR (logged_at = ?${memberIds.length + 1} AND id < ?${memberIds.length + 2})
          )
        ORDER BY logged_at DESC, id DESC
        LIMIT ?${memberIds.length + 3}`,
    )
    .bind(...memberIds, upper, upperId, sourceLimit)
    .all<{
      id: string;
      user_id: string;
      date: string;
      type: string;
      title: string | null;
      duration_minutes: number | null;
      notes: string | null;
      logged_at: number;
    }>();

  const activityItems: FeedActivityItem[] = actRows.results.map((a) => ({
    type: 'activity',
    id: a.id,
    user_id: a.user_id,
    user_display_name: memberMeta.get(a.user_id)?.displayName ?? 'Member',
    is_me: a.user_id === callerUserId,
    date: a.date,
    occurred_at: a.logged_at,
    activity: {
      kind: sharedText(a.type)!,
      title: sharedText(a.title),
      duration_min: a.duration_minutes,
      notes: sharedText(a.notes),
    },
  }));

  // 3. Merge + sort + cap. Stable secondary key (id) for determinism when
  //    two items share an occurred_at (rare but possible — a cron-synced
  //    ride and a logged set in the same ms).
  const merged: FeedItem[] = [...sessionItems, ...rideItems, ...activityItems];
  merged.sort((a, b) => {
    if (b.occurred_at !== a.occurred_at) return b.occurred_at - a.occurred_at;
    return a.id < b.id ? 1 : a.id > b.id ? -1 : 0;
  });
  return merged.slice(0, cap);
}

/**
 * Per-member stats over a rolling N-day window (typically 7/14/30). The
 * window is anchored to "today" in each MEMBER's own timezone so a
 * groupmate in Sydney isn't penalized by your civil clock.
 *
 * `workout_count` = number of DISTINCT dates in the window with at least
 * one activity (strength session that isn't discarded, intervals ride,
 * or generic activity). Three Pilates classes in one day count as one.
 *
 * `streak_days` = consecutive member-local civil days ending at "today"
 * with at least one activity. Simplification rule for v1: if today has
 * activity, count back from today; else count back from yesterday (so a
 * member who hasn't logged today yet still sees their existing streak).
 *
 * NOTE: callers MUST enforce group membership BEFORE calling this — same
 * authorization pattern as getGroupFeed / createInvite.
 */
export async function getGroupStats(
  db: D1Database,
  groupId: string,
  rangeDays: number,
  callerUserId: string,
): Promise<MemberStat[]> {
  const range = Math.max(1, Math.min(rangeDays, 365));

  // 1. Resolve members + names + timezones + emails in one round trip.
  const memberRows = { results: await visibleGroupMembers(db, groupId, callerUserId) };
  if (memberRows.results.length === 0) return [];

  const out: MemberStat[] = [];
  for (const m of memberRows.results) {
    const displayName = sharedText(resolveDisplayName(m.per_group_name, m.global_name, m.email), 'Member')!;
    const today = todayInTz(m.timezone);
    // The window: [windowStart, today] inclusive, in this member's civil
    // calendar. We collect ALL activity dates within (and one day before,
    // so the streak walker has continuity at the boundary), then compute
    // count + streak in JS.
    const windowStart = addDays(today, -(range - 1));
    // Streak walker may need to look further back than the workout-count
    // window when the streak is longer than `range`. We cap streak look-
    // back at 365d (one year) — generous enough for a friends-and-family
    // streak, bounded so the query stays small.
    const streakStart = addDays(today, -365);

    // Pull dates from all three sources for this member in one go. Each
    // SELECT projects (date) only — we don't need the row payloads here,
    // just the civil-date column. epoch_ms-keyed rows (set_logs.logged_at,
    // external_activities.synced_at) use the SESSION.date / activity.date
    // strings to keep the bucketing tz-correct.
    const sessionsRows = await workoutDB(db)
      .prepare(
        // Same planned-session leak fix as the feed query: a session row
        // with status='planned' (auto-created by GET /api/today) is intent,
        // not activity. workout_count and streak_days must only count
        // sessions that were actually started or completed.
        `SELECT DISTINCT date FROM sessions
          WHERE user_id = ?1
            AND status IN ('in_progress', 'completed')
            AND date >= ?2 AND date <= ?3`,
      )
      .bind(m.user_id, streakStart, today)
      .all<{ date: string }>();
    const ridesRows = await workoutDB(db)
      .prepare(
        // HealthKit rows are gated behind the per-user opt-in (0028) so an
        // un-shared member's private health activity never inflates the
        // group streak/count surfaced to others.
        `SELECT DISTINCT date FROM external_activities
          WHERE user_id = ?1
            AND deleted_at IS NULL
            AND (source <> 'healthkit'
                 OR (SELECT share_health_activities FROM users
                       WHERE id = external_activities.user_id) = 1)
            AND date >= ?2 AND date <= ?3`,
      )
      .bind(m.user_id, streakStart, today)
      .all<{ date: string }>();
    const actRows = await workoutDB(db)
      .prepare(
        `SELECT DISTINCT date FROM activities
          WHERE user_id = ?1
            AND deleted_at IS NULL
            AND date >= ?2 AND date <= ?3`,
      )
      .bind(m.user_id, streakStart, today)
      .all<{ date: string }>();
    const activeDates = new Set<string>();
    for (const r of sessionsRows.results) activeDates.add(r.date);
    for (const r of ridesRows.results) activeDates.add(r.date);
    for (const r of actRows.results) activeDates.add(r.date);

    // workout_count = distinct active dates within the rolling window.
    let workoutCount = 0;
    for (const d of activeDates) {
      if (d >= windowStart && d <= today) workoutCount++;
    }

    // streak_days = consecutive days back from "today" (or yesterday if
    // today is empty). Walk one civil day at a time using addDays so the
    // boundary math is identical to the rest of the project.
    let streak = 0;
    let cursor: string;
    if (activeDates.has(today)) {
      cursor = today;
    } else {
      cursor = addDays(today, -1);
      // If yesterday is ALSO empty, streak is 0 — both today and the
      // most recent prior day broke the chain.
      if (!activeDates.has(cursor)) cursor = '';
    }
    while (cursor && activeDates.has(cursor)) {
      streak++;
      cursor = addDays(cursor, -1);
    }

    // last_active = the most recent active date as an epoch-ms timestamp
    // (midnight UTC of that civil date — iOS just needs *something* to
    // render "active 3d ago"; precise wall-clock isn't surfaced).
    let lastActiveMs: number | null = null;
    if (activeDates.size > 0) {
      const sorted = [...activeDates].sort();
      const latest = sorted[sorted.length - 1]!;
      lastActiveMs = Date.parse(`${latest}T00:00:00Z`);
    }

    out.push({
      user_id: m.user_id,
      display_name: displayName,
      avatar_initials: avatarInitials(displayName),
      is_me: m.user_id === callerUserId,
      workout_count: workoutCount,
      streak_days: streak,
      last_active: lastActiveMs,
    });
  }
  return out;
}

/**
 * Per-member DAILY activity series over a trailing civil-day window —
 * the data behind the iOS Group-tab week/month/year zoom. Where
 * getGroupStats rolls every source up to a single count+streak, this
 * returns the raw per-day breakdown so the client can re-bucket it into
 * day cells (week/month) or week cells (year) WITHOUT a refetch per zoom.
 *
 * Counts are kept by SOURCE, not by display category: `sessions`
 * (started/completed strength → "lift"), `rides` (external_activities,
 * the intervals.icu endurance actuals → "endurance"), and `activities`
 * (manual log, keyed by its freeform `type`). The client owns the
 * type→category mapping (WorkoutCategory) so the rule lives in exactly
 * one place — this endpoint stays a dumb aggregator.
 *
 * Window is per-member-tz-anchored (same as getGroupStats) and the rows
 * are SPARSE: only dates with at least one item are returned. A
 * 4-lifts-a-week athlete over a year is ~200 tiny rows — trivial wire.
 *
 * NOTE: callers MUST enforce group membership BEFORE calling this — same
 * authorization pattern as getGroupFeed / getGroupStats.
 */
export interface DayActivityCount {
  date: string; // YYYY-MM-DD civil (device-local; no UTC math)
  sessions: number; // started/completed strength sessions that day
  rides: number; // intervals.icu endurance activities that day
  activities: Record<string, number>; // manual-log counts keyed by type
}

export interface MemberActivitySeries {
  user_id: string;
  days: DayActivityCount[];
}

export async function getGroupActivitySeries(
  db: D1Database,
  groupId: string,
  windowDays: number,
  callerUserId: string,
): Promise<MemberActivitySeries[]> {
  // Cap at 372 (53 weeks) — enough for the year view's week buckets,
  // bounded so the per-member GROUP BY stays cheap. The caller determines
  // which members are visible; is_me is resolved from /stats.
  const days = Math.max(1, Math.min(Math.floor(windowDays), 372));

  const memberRows = { results: await visibleGroupMembers(db, groupId, callerUserId) };
  if (memberRows.results.length === 0) return [];

  const out: MemberActivitySeries[] = [];
  for (const m of memberRows.results) {
    const today = todayInTz(m.timezone);
    const start = addDays(today, -(days - 1));

    const byDate = new Map<string, DayActivityCount>();
    const ensure = (date: string): DayActivityCount => {
      let d = byDate.get(date);
      if (!d) {
        d = { date, sessions: 0, rides: 0, activities: {} };
        byDate.set(date, d);
      }
      return d;
    };

    // Same source filters as getGroupStats: planned (intent) sessions are
    // excluded; rides/activities honor soft-delete. COUNT(*) per date is
    // the cell intensity (two sessions on a day → 2), unlike stats which
    // collapses to DISTINCT dates.
    const sessRows = await workoutDB(db)
      .prepare(
        `SELECT date, COUNT(*) AS n FROM sessions
          WHERE user_id = ?1
            AND status IN ('in_progress', 'completed')
            AND date >= ?2 AND date <= ?3
          GROUP BY date`,
      )
      .bind(m.user_id, start, today)
      .all<{ date: string; n: number }>();
    for (const r of sessRows.results) ensure(r.date).sessions = r.n;

    const rideRows = await workoutDB(db)
      .prepare(
        // HealthKit rows gated behind the opt-in (0028), same as the feed/stats.
        `SELECT date, COUNT(*) AS n FROM external_activities
          WHERE user_id = ?1
            AND deleted_at IS NULL
            AND (source <> 'healthkit'
                 OR (SELECT share_health_activities FROM users
                       WHERE id = external_activities.user_id) = 1)
            AND date >= ?2 AND date <= ?3
          GROUP BY date`,
      )
      .bind(m.user_id, start, today)
      .all<{ date: string; n: number }>();
    for (const r of rideRows.results) ensure(r.date).rides = r.n;

    const actRows = await workoutDB(db)
      .prepare(
        `SELECT date, type, COUNT(*) AS n FROM activities
          WHERE user_id = ?1
            AND deleted_at IS NULL
            AND date >= ?2 AND date <= ?3
          GROUP BY date, type`,
      )
      .bind(m.user_id, start, today)
      .all<{ date: string; type: string; n: number }>();
    for (const r of actRows.results) {
      const counts = ensure(r.date).activities;
      const kind = sharedText(r.type, 'other')!;
      counts[kind] = (counts[kind] ?? 0) + r.n;
    }

    const daysArr = [...byDate.values()].sort((x, y) =>
      x.date < y.date ? -1 : x.date > y.date ? 1 : 0,
    );
    out.push({ user_id: m.user_id, days: daysArr });
  }
  return out;
}

// ---- OAuth grant transitions --------------------------------------------

export interface OAuthCodeRedemption {
  code: string;
  client_id: string;
  redirect_uri: string;
  code_challenge: string;
  code_challenge_method: string;
  scope: string | null;
  resource: string | null;
  expires_at: number;
  user_id: string | null;
  access_token: string;
  refresh_token: string;
  access_expires_at: number;
  grant_id: string;
  owner_apple_sub?: string;
}

export interface OAuthRefreshRotation {
  presented_refresh_token: string;
  presented_client_id: string;
  client_id: string;
  scope: string | null;
  expires_at: number;
  user_id: string | null;
  access_token: string;
  refresh_token: string;
  access_expires_at: number;
  grant_id: string | null;
  consumed_refresh_sha256: string;
  owner_apple_sub?: string;
}

export interface OAuthTokenPair {
  access_token: string;
  refresh_token: string;
  scope: string;
  grant_id: string;
  access_expires_at: number;
}

export const OAUTH_GRANT_INACTIVITY_MS = 90 * 24 * 60 * 60 * 1000;
export const OAUTH_GRANT_ABSOLUTE_MS = 365 * 24 * 60 * 60 * 1000;

/**
 * One-time administrative policy activation. Migration 0042's trigger makes
 * the conditional claim and every existing-grant update one transaction, so
 * failure rolls the whole activation back.
 * Existing deadlines are never overwritten, including a retry with the same
 * nonce. Migration 0042's trigger initializes existing grants in the same
 * transaction as this one conditional UPDATE.
 */
export async function activateOAuthGrantLifecyclePolicy(
  db: D1Database,
  activatedAt: number,
  nonce: string,
): Promise<{ newly_activated: boolean; activated_at: number }> {
  if (!Number.isSafeInteger(activatedAt) || activatedAt <= 0 || !nonce) {
    throw new Error('invalid OAuth grant lifecycle activation');
  }
  const claimed = await workoutDB(db)
    .prepare(
      `UPDATE oauth_grant_lifecycle_policy
          SET activated_at = ?1, activation_nonce = ?2
        WHERE id = 1 AND activated_at IS NULL
      RETURNING id`,
    )
    .bind(activatedAt, nonce)
    .run();
  const policy = await workoutDB(db).prepare(
    'SELECT activated_at, activation_nonce FROM oauth_grant_lifecycle_policy WHERE id = 1',
  ).first<{ activated_at: number; activation_nonce: string }>();
  if (!policy) throw new Error('OAuth grant lifecycle policy row missing');
  if (policy.activation_nonce !== nonce || policy.activated_at !== activatedAt) {
    throw new Error('OAuth grant lifecycle policy already activated');
  }
  return { newly_activated: claimed.results.length === 1, activated_at: policy.activated_at };
}

/**
 * Consume one already-validated authorization-code snapshot and insert its
 * sole successor in one D1 transaction. Every immutable validation input is
 * repeated at the write boundary. If insertion fails, D1 rolls the batch back
 * and leaves the code available for a corrected retry.
 */
export async function redeemOAuthAuthorizationCode(
  db: D1Database,
  redemption: OAuthCodeRedemption,
): Promise<OAuthTokenPair | null> {
  // Legacy unscoped grants belong only to an existing distinguished owner.
  // Do not bootstrap a replacement identity while redeeming old credentials.
  const principal = redemption.user_id
    ? await workoutDB(db).prepare('SELECT id FROM users WHERE id = ?1').bind(redemption.user_id).first<{ id: string }>()
    : await findOwnerRow(db, redemption.owner_apple_sub);
  if (!principal) return null;

  const nowMs = now();
  const tokenCreatedAt = Math.floor(nowMs / 1000);
  const legacy = redemption.user_id === null;
  const [family, inserted, consumed, cleaned] = await workoutDB(db).batch([
    workoutDB(db).prepare(
      `INSERT INTO oauth_grants
         (id, user_id, client_id, scope, created_at, last_refreshed_at, legacy,
          inactivity_expires_at, absolute_expires_at)
       SELECT ?1, ?2, c.client_id, COALESCE(c.scope, 'mcp'), ?3, ?3, ?15,
              CASE WHEN p.activated_at IS NULL THEN NULL
                   ELSE MAX(c.created_at, p.activated_at) + ?16 END,
              CASE WHEN p.activated_at IS NULL THEN NULL
                   ELSE MAX(c.created_at, p.activated_at) + ?17 END
         FROM oauth_codes c
         LEFT JOIN oauth_grant_lifecycle_policy p ON p.id = 1
        WHERE c.code = ?4
          AND p.id = 1
          AND c.client_id = ?5
          AND c.redirect_uri = ?6
          AND c.code_challenge = ?7
          AND c.code_challenge_method = ?8
          AND c.expires_at = ?9
          AND c.expires_at >= ?10
          AND c.scope IS ?11
          AND c.resource IS ?12
          AND (c.user_id = ?13 OR (?14 = 1 AND c.user_id IS NULL))
          AND EXISTS (SELECT 1 FROM users WHERE id = ?2)
          AND NOT EXISTS (SELECT 1 FROM account_deletion_intents WHERE user_id = ?2)
          AND NOT EXISTS (SELECT 1 FROM account_deletion_receipts WHERE user_id = ?2)`,
    ).bind(
      redemption.grant_id,
      principal.id,
      nowMs,
      redemption.code,
      redemption.client_id,
      redemption.redirect_uri,
      redemption.code_challenge,
      redemption.code_challenge_method,
      redemption.expires_at,
      nowMs,
      redemption.scope,
      redemption.resource,
      redemption.user_id,
      legacy ? 1 : 0,
      legacy ? 1 : 0,
      OAUTH_GRANT_INACTIVITY_MS,
      OAUTH_GRANT_ABSOLUTE_MS,
    ),
    workoutDB(db).prepare(
      `INSERT INTO oauth_tokens
         (access_token, refresh_token, client_id, scope, expires_at, created_at, user_id, grant_id)
       SELECT ?1, ?2, c.client_id, COALESCE(c.scope, 'mcp'),
              CASE WHEN g.inactivity_expires_at IS NULL THEN ?3
                   ELSE MIN(?3, CAST(g.inactivity_expires_at / 1000 AS INTEGER),
                                CAST(g.absolute_expires_at / 1000 AS INTEGER)) END,
              ?4, ?5, ?17
         FROM oauth_codes c
         JOIN oauth_grants g ON g.id = ?17
        WHERE c.code = ?6
          AND c.client_id = ?7
          AND c.redirect_uri = ?8
          AND c.code_challenge = ?9
          AND c.code_challenge_method = ?10
          AND c.expires_at = ?11
          AND c.expires_at >= ?12
          AND c.scope IS ?13
          AND c.resource IS ?14
          AND (c.user_id = ?15 OR (?16 = 1 AND c.user_id IS NULL))
          AND EXISTS (SELECT 1 FROM users WHERE id = ?5)
          AND NOT EXISTS (SELECT 1 FROM account_deletion_intents WHERE user_id = ?5)
          AND NOT EXISTS (SELECT 1 FROM account_deletion_receipts WHERE user_id = ?5)
          AND changes() = 1
       RETURNING expires_at`,
    ).bind(
      redemption.access_token,
      redemption.refresh_token,
      redemption.access_expires_at,
      tokenCreatedAt,
      principal.id,
      redemption.code,
      redemption.client_id,
      redemption.redirect_uri,
      redemption.code_challenge,
      redemption.code_challenge_method,
      redemption.expires_at,
      nowMs,
      redemption.scope,
      redemption.resource,
      redemption.user_id,
      legacy ? 1 : 0,
      redemption.grant_id,
    ),
    workoutDB(db).prepare(
      `DELETE FROM oauth_codes
        WHERE code = ?1
          AND client_id = ?2
          AND redirect_uri = ?3
          AND code_challenge = ?4
          AND code_challenge_method = ?5
          AND expires_at = ?6
          AND expires_at >= ?7
          AND scope IS ?8
          AND resource IS ?9
          AND (user_id = ?10 OR (?11 = 1 AND user_id IS NULL))
          AND changes() = 1`,
    ).bind(
      redemption.code,
      redemption.client_id,
      redemption.redirect_uri,
      redemption.code_challenge,
      redemption.code_challenge_method,
      redemption.expires_at,
      nowMs,
      redemption.scope,
      redemption.resource,
      redemption.user_id,
      legacy ? 1 : 0,
    ),
    workoutDB(db).prepare(
      `DELETE FROM oauth_grants
        WHERE id = ?1
          AND NOT EXISTS (SELECT 1 FROM oauth_tokens WHERE grant_id = ?1)`,
    ).bind(redemption.grant_id),
  ]);
  if (
    family?.meta.changes !== 1 ||
    inserted?.meta.changes !== 1 ||
    consumed?.meta.changes !== 1 ||
    cleaned?.meta.changes !== 0
  ) return null;
  return {
    access_token: redemption.access_token,
    refresh_token: redemption.refresh_token,
    scope: redemption.scope ?? 'mcp',
    grant_id: redemption.grant_id,
    access_expires_at: (inserted.results?.[0] as { expires_at: number }).expires_at,
  };
}

/** Rotate a refresh credential with one conditional write. */
export async function rotateOAuthRefreshToken(
  db: D1Database,
  rotation: OAuthRefreshRotation,
): Promise<OAuthTokenPair | null> {
  if (!rotation.presented_client_id || rotation.presented_client_id !== rotation.client_id) {
    return null;
  }
  const principal = rotation.user_id
    ? await workoutDB(db).prepare('SELECT id FROM users WHERE id = ?1').bind(rotation.user_id).first<{ id: string }>()
    : await findOwnerRow(db, rotation.owner_apple_sub);
  if (!principal) return null;

  const refreshedAt = now();
  const tokenCreatedAt = Math.floor(refreshedAt / 1000);
  const legacy = rotation.user_id === null;
  const grantId = rotation.grant_id ?? crypto.randomUUID();
  const [adopted, initialized, rotated, archived, touched, cleaned] = await workoutDB(db).batch([
    workoutDB(db).prepare(
      `INSERT INTO oauth_grants
         (id, user_id, client_id, scope, created_at, last_refreshed_at, legacy,
          inactivity_expires_at, absolute_expires_at)
       SELECT ?1, ?2, t.client_id, t.scope, t.created_at * 1000, ?3, 1,
              CASE WHEN p.activated_at IS NULL THEN NULL
                   ELSE MAX(t.created_at * 1000, p.activated_at) + ?10 END,
              CASE WHEN p.activated_at IS NULL THEN NULL
                   ELSE MAX(t.created_at * 1000, p.activated_at) + ?11 END
         FROM oauth_tokens t
         LEFT JOIN oauth_grant_lifecycle_policy p ON p.id = 1
        WHERE t.refresh_token = ?4
          AND p.id = 1
          AND t.client_id = ?5
          AND t.expires_at = ?6
          AND t.scope IS ?7
          AND t.grant_id IS NULL
          AND (t.user_id = ?8 OR (?9 = 1 AND t.user_id IS NULL))
          AND EXISTS (SELECT 1 FROM users WHERE id = ?2)
          AND NOT EXISTS (SELECT 1 FROM account_deletion_intents WHERE user_id = ?2)
          AND NOT EXISTS (SELECT 1 FROM account_deletion_receipts WHERE user_id = ?2)
       ON CONFLICT(id) DO NOTHING`,
    ).bind(
      grantId,
      principal.id,
      refreshedAt,
      rotation.presented_refresh_token,
      rotation.client_id,
      rotation.expires_at,
      rotation.scope,
      rotation.user_id,
      legacy ? 1 : 0,
      OAUTH_GRANT_INACTIVITY_MS,
      OAUTH_GRANT_ABSOLUTE_MS,
    ),
    workoutDB(db).prepare(
      `UPDATE oauth_grants
          SET inactivity_expires_at = MAX(created_at, p.activated_at) + ?2,
              absolute_expires_at = MAX(created_at, p.activated_at) + ?3
         FROM oauth_grant_lifecycle_policy p
        WHERE oauth_grants.id = ?1
          AND p.id = 1 AND p.activated_at IS NOT NULL
          AND oauth_grants.revoked_at IS NULL
          AND oauth_grants.inactivity_expires_at IS NULL
          AND oauth_grants.absolute_expires_at IS NULL`,
    ).bind(grantId, OAUTH_GRANT_INACTIVITY_MS, OAUTH_GRANT_ABSOLUTE_MS),
    workoutDB(db).prepare(
    `UPDATE oauth_tokens
        SET access_token = ?1,
            refresh_token = ?2,
            expires_at = CASE
              WHEN g.inactivity_expires_at IS NULL AND g.absolute_expires_at IS NULL
                   AND p.activated_at IS NULL THEN ?3
              ELSE MIN(?3,
                       CAST(MIN(CAST(unixepoch('subsec') * 1000 AS INTEGER) + ?14,
                                    g.absolute_expires_at) / 1000 AS INTEGER))
            END,
            created_at = CAST(unixepoch('subsec') AS INTEGER),
            user_id = ?5,
            grant_id = ?12
       FROM oauth_grants g
       LEFT JOIN oauth_grant_lifecycle_policy p ON p.id = 1
      WHERE oauth_tokens.refresh_token = ?6
        AND oauth_tokens.client_id = ?7
        AND oauth_tokens.expires_at = ?8
        AND (oauth_tokens.user_id = ?9 OR (?10 = 1 AND oauth_tokens.user_id IS NULL))
        AND EXISTS (SELECT 1 FROM users WHERE id = ?5)
        AND NOT EXISTS (SELECT 1 FROM account_deletion_intents WHERE user_id = ?5)
        AND NOT EXISTS (SELECT 1 FROM account_deletion_receipts WHERE user_id = ?5)
        AND oauth_tokens.scope IS ?11
        AND (oauth_tokens.grant_id = ?12 OR oauth_tokens.grant_id IS NULL)
        AND g.id = ?12 AND g.revoked_at IS NULL
        AND (
          (p.id = 1 AND p.activated_at IS NULL
           AND g.inactivity_expires_at IS NULL AND g.absolute_expires_at IS NULL)
          OR
          (p.id = 1 AND p.activated_at IS NOT NULL
           AND g.inactivity_expires_at > CAST(unixepoch('subsec') * 1000 AS INTEGER)
           AND g.absolute_expires_at > CAST(unixepoch('subsec') * 1000 AS INTEGER))
        )
        AND NOT EXISTS (
              SELECT 1 FROM oauth_refresh_history WHERE token_sha256 = ?13
            )
      RETURNING expires_at`,
  ).bind(
    rotation.access_token,
    rotation.refresh_token,
    rotation.access_expires_at,
    tokenCreatedAt,
    principal.id,
    rotation.presented_refresh_token,
    rotation.client_id,
    rotation.expires_at,
    rotation.user_id,
    legacy ? 1 : 0,
    rotation.scope,
    grantId,
    rotation.consumed_refresh_sha256,
    OAUTH_GRANT_INACTIVITY_MS,
  ),
    workoutDB(db).prepare(
      `INSERT INTO oauth_refresh_history (token_sha256, grant_id, client_id, consumed_at)
       SELECT ?1, ?2, ?3, ?4
        WHERE changes() = 1`,
    ).bind(rotation.consumed_refresh_sha256, grantId, rotation.client_id, refreshedAt),
    workoutDB(db).prepare(
      `UPDATE oauth_grants
          SET last_refreshed_at = CAST(unixepoch('subsec') * 1000 AS INTEGER),
              inactivity_expires_at = CASE
                WHEN inactivity_expires_at IS NULL THEN NULL
                ELSE MIN(CAST(unixepoch('subsec') * 1000 AS INTEGER) + ?3,
                         absolute_expires_at)
              END
        WHERE id = ?1 AND revoked_at IS NULL AND changes() = 1`,
    ).bind(grantId, refreshedAt, OAUTH_GRANT_INACTIVITY_MS),
    workoutDB(db).prepare(
      `DELETE FROM oauth_grants
        WHERE id = ?1 AND ?2 = 1
          AND NOT EXISTS (SELECT 1 FROM oauth_tokens WHERE grant_id = ?1)
          AND NOT EXISTS (SELECT 1 FROM oauth_refresh_history WHERE grant_id = ?1)`,
    ).bind(grantId, rotation.grant_id === null ? 1 : 0),
  ]);
  if (rotated?.meta.changes !== 1 || archived?.meta.changes !== 1 || touched?.meta.changes !== 1) {
    return null;
  }
  if (cleaned?.meta.changes !== 0) return null;
  if (rotation.grant_id === null && adopted?.meta.changes !== 1) return null;
  return {
    access_token: rotation.access_token,
    refresh_token: rotation.refresh_token,
    scope: rotation.scope ?? 'mcp',
    grant_id: grantId,
    access_expires_at: (rotated.results?.[0] as { expires_at: number }).expires_at,
  };
}

/**
 * Complete refresh behavior for one validated snapshot. A clean CAS loss may
 * mean another contender just consumed the same credential, so check history
 * before returning invalid_grant and revoke that family's surviving token.
 */
export async function refreshOAuthGrant(
  db: D1Database,
  rotation: OAuthRefreshRotation,
): Promise<OAuthTokenPair | null> {
  const tokens = await rotateOAuthRefreshToken(db, rotation);
  if (tokens) return tokens;
  await revokeOAuthGrantOnRefreshReplay(
    db,
    rotation.consumed_refresh_sha256,
    rotation.presented_client_id,
    rotation.owner_apple_sub,
  );
  return null;
}

export interface OAuthGrantSummary {
  id: string;
  client_id: string;
  scope: string;
  created_at: number;
  last_refreshed_at: number | null;
  legacy: boolean;
}

/**
 * A matching replay of a consumed refresh credential invalidates only its
 * family. A wrong client id has no effect: public client ids bind requests but
 * do not authenticate whoever presented the stale credential.
 */
export async function revokeOAuthGrantOnRefreshReplay(
  db: D1Database,
  tokenSha256: string,
  clientId: string,
  ownerAppleSub: string | undefined,
): Promise<boolean> {
  const replay = await workoutDB(db).prepare(
    `SELECT g.id, g.user_id FROM oauth_refresh_history h
       JOIN oauth_grants g ON g.id = h.grant_id
      WHERE h.token_sha256 = ?1
        AND h.client_id = ?2
        AND g.client_id = ?2`,
  ).bind(tokenSha256, clientId).first<{ id: string; user_id: string | null }>();
  if (!replay) return false;
  const principal = replay.user_id
    ? await workoutDB(db).prepare('SELECT id FROM users WHERE id = ?1').bind(replay.user_id).first<{ id: string }>()
    : await findOwnerRow(db, ownerAppleSub);
  if (!principal) return false;
  const revokedAt = now();
  const [revoked, removed] = await workoutDB(db).batch([
    workoutDB(db).prepare(
      `UPDATE oauth_grants SET revoked_at = ?2
        WHERE id = ?1 AND revoked_at IS NULL
          AND (user_id = ?3 OR (?4 = 1 AND user_id IS NULL))`,
    ).bind(replay.id, revokedAt, replay.user_id, replay.user_id === null ? 1 : 0),
    workoutDB(db).prepare('DELETE FROM oauth_tokens WHERE grant_id = ?1 AND changes() = 1')
      .bind(replay.id),
  ]);
  return revoked?.meta.changes === 1 && (removed?.meta.changes ?? 0) <= 1;
}

async function adoptUntrackedOAuthGrants(
  db: D1Database,
  userId: string,
  includeLegacyOwner: boolean,
): Promise<void> {
  const rows = await workoutDB(db).prepare(
    `SELECT access_token, user_id, client_id, scope, created_at
       FROM oauth_tokens
      WHERE grant_id IS NULL
        AND (user_id = ?1 OR (?2 = 1 AND user_id IS NULL))`,
  ).bind(userId, includeLegacyOwner ? 1 : 0).all<{
    access_token: string;
    user_id: string | null;
    client_id: string;
    scope: string | null;
    created_at: number;
  }>();
  for (const row of rows.results) {
    const grantId = crypto.randomUUID();
    await workoutDB(db).batch([
      workoutDB(db).prepare(
        `INSERT INTO oauth_grants
           (id, user_id, client_id, scope, created_at, last_refreshed_at, legacy,
            inactivity_expires_at, absolute_expires_at)
         SELECT ?1, ?2, t.client_id, t.scope, t.created_at * 1000, t.created_at * 1000, 1,
                CASE WHEN p.activated_at IS NULL THEN NULL
                     ELSE MAX(t.created_at * 1000, p.activated_at) + ?5 END,
                CASE WHEN p.activated_at IS NULL THEN NULL
                     ELSE MAX(t.created_at * 1000, p.activated_at) + ?6 END
           FROM oauth_tokens t
           LEFT JOIN oauth_grant_lifecycle_policy p ON p.id = 1
          WHERE access_token = ?3 AND grant_id IS NULL
            AND (user_id = ?2 OR (?4 = 1 AND user_id IS NULL))
            AND EXISTS (SELECT 1 FROM users WHERE id = ?2)
            AND NOT EXISTS (SELECT 1 FROM account_deletion_intents WHERE user_id = ?2)
            AND NOT EXISTS (SELECT 1 FROM account_deletion_receipts WHERE user_id = ?2)`,
      ).bind(
        grantId,
        row.user_id ?? userId,
        row.access_token,
        row.user_id === null ? 1 : 0,
        OAUTH_GRANT_INACTIVITY_MS,
        OAUTH_GRANT_ABSOLUTE_MS,
      ),
      workoutDB(db).prepare(
        `UPDATE oauth_tokens SET grant_id = ?2
          WHERE access_token = ?1 AND grant_id IS NULL AND changes() = 1`,
      ).bind(row.access_token, grantId),
      workoutDB(db).prepare(
        `DELETE FROM oauth_grants
          WHERE id = ?1
            AND NOT EXISTS (SELECT 1 FROM oauth_tokens WHERE grant_id = ?1)`,
      ).bind(grantId),
    ]);
  }
}

export async function listOAuthGrants(
  db: D1Database,
  userId: string,
  ownerAppleSub: string | undefined,
): Promise<OAuthGrantSummary[]> {
  const owner = await findOwnerRow(db, ownerAppleSub);
  const isOwner = owner?.id === userId;
  await adoptUntrackedOAuthGrants(db, userId, isOwner);
  const rows = await workoutDB(db).prepare(
    `SELECT g.id, g.client_id, COALESCE(g.scope, 'mcp') AS scope, g.created_at,
            g.last_refreshed_at, g.legacy
       FROM oauth_grants g
       JOIN oauth_grant_lifecycle_policy p ON p.id = 1
      WHERE g.revoked_at IS NULL
        AND (
          (p.activated_at IS NULL
           AND g.inactivity_expires_at IS NULL AND g.absolute_expires_at IS NULL)
          OR
          (p.activated_at IS NOT NULL
           AND g.inactivity_expires_at > CAST(unixepoch('subsec') * 1000 AS INTEGER)
           AND g.absolute_expires_at > CAST(unixepoch('subsec') * 1000 AS INTEGER))
        )
        AND (g.user_id = ?1 OR (?2 = 1 AND g.user_id IS NULL))
      ORDER BY g.created_at DESC, g.id`,
  ).bind(userId, isOwner ? 1 : 0).all<{
    id: string;
    client_id: string;
    scope: string;
    created_at: number;
    last_refreshed_at: number | null;
    legacy: number;
  }>();
  return rows.results.map((row) => ({ ...row, legacy: row.legacy === 1 }));
}

/** Caller-scoped and idempotent; never returns or audits credential values. */
export async function revokeOAuthGrant(
  db: D1Database,
  userId: string,
  grantId: string,
  ownerAppleSub: string | undefined,
): Promise<boolean> {
  const owner = await findOwnerRow(db, ownerAppleSub);
  const isOwner = owner?.id === userId;
  const grant = await workoutDB(db).prepare(
    `SELECT id FROM oauth_grants
      WHERE id = ?1 AND (user_id = ?2 OR (?3 = 1 AND user_id IS NULL))`,
  ).bind(grantId, userId, isOwner ? 1 : 0).first<{ id: string }>();
  if (!grant) return false;
  await workoutDB(db).batch([
    workoutDB(db).prepare(
      `INSERT INTO audit_log (id,user_id,actor,tool,args,result,created_at)
       VALUES (?1,?2,'ios','revoke_coach_grant',?3,'revoked',?4)`,
    ).bind(uuid(), userId, JSON.stringify({ grant_id: grantId }), now()),
    workoutDB(db).prepare(
      'UPDATE oauth_grants SET revoked_at = COALESCE(revoked_at, ?2) WHERE id = ?1',
    ).bind(grantId, now()),
    workoutDB(db).prepare('DELETE FROM oauth_tokens WHERE grant_id = ?1').bind(grantId),
  ]);
  return true;
}

export async function revokeAllOAuthGrants(
  db: D1Database,
  userId: string,
  ownerAppleSub: string | undefined,
): Promise<number> {
  const owner = await findOwnerRow(db, ownerAppleSub);
  const isOwner = owner?.id === userId;
  await adoptUntrackedOAuthGrants(db, userId, isOwner);
  const [, revoked] = await workoutDB(db).batch([
    workoutDB(db).prepare(
      `INSERT INTO audit_log (id,user_id,actor,tool,args,result,created_at)
       VALUES (?1,?2,'ios','revoke_coach_grants',?3,'revoked',?4)`,
    ).bind(uuid(), userId, JSON.stringify({ scope: 'all' }), now()),
    workoutDB(db).prepare(
      `UPDATE oauth_grants SET revoked_at = COALESCE(revoked_at, ?3)
        WHERE revoked_at IS NULL
          AND (user_id = ?1 OR (?2 = 1 AND user_id IS NULL))`,
    ).bind(userId, isOwner ? 1 : 0, now()),
    workoutDB(db).prepare(
      `DELETE FROM oauth_tokens
        WHERE grant_id IN (
          SELECT id FROM oauth_grants
           WHERE revoked_at IS NOT NULL
             AND (user_id = ?1 OR (?2 = 1 AND user_id IS NULL))
        )`,
    ).bind(userId, isOwner ? 1 : 0),
  ]);
  return revoked?.meta.changes ?? 0;
}

// ---- prescribed exercise groups ------------------------------------------

export interface ExerciseGroupAcknowledgement {
  ok: true;
  plan_id: string;
  version: number;
  group_id: string;
  day_id: string | null;
  members: string[];
  round_rest: number | null;
  transition_rest: number | null;
  target_sets: number | null;
  cleared: boolean;
  unchanged?: true;
  replayed?: true;
}
export type ExerciseGroupResult = ExerciseGroupAcknowledgement | PlanVersionConflict
  | PrescriptionValidationError | GroupConflict | { error: 'no_active_plan' | 'day_not_found' };
export interface SetExerciseGroupOptions {
  expected_version: number;
  round_rest: number;
  transition_rest?: number;
  target_sets?: number;
  /** Destination for the complete member block in the resulting day. */
  order_index?: number;
}

/** Preserve JSON value semantics while ignoring object-property insertion order.
 * Arrays remain ordered because member order is part of group authoring. */
function canonicalExerciseGroupArgs(value: unknown): string {
  const normalized = (item: unknown): unknown => {
    if (Array.isArray(item)) return item.map(normalized);
    if (isPlainRecord(item)) return Object.fromEntries(
      Object.keys(item).sort().map((key) => [key, normalized(item[key])]),
    );
    return item;
  };
  return JSON.stringify(normalized(value));
}

/** A name-based MCP retry must recognize the original accepted request before
 * resolving names against a renamed, rebuilt or removed day. Original args and
 * the canonical acknowledgement already share the writer's atomic audit row.
 * The MCP wrapper validates allowed fields and their types before this lookup. */
export async function findMcpExerciseGroupAcknowledgement(
  db: D1Database,
  userId: string,
  operation: 'group_exercises' | 'ungroup_exercises',
  args: Record<string, unknown>,
): Promise<ExerciseGroupAcknowledgement | null> {
  if (!isGroupId(args.group_id) || !Number.isSafeInteger(args.expected_version)
      || (args.expected_version as number) < 1) return null;
  const rows = await workoutDB(db).prepare(
    `SELECT args,result FROM audit_log
      WHERE user_id=?1 AND actor='mcp' AND tool=?2
        AND json_extract(CASE WHEN json_valid(args) THEN args ELSE '{}' END,'$.group_id')=?3
        AND json_extract(CASE WHEN json_valid(args) THEN args ELSE '{}' END,'$.expected_version')=?4
        AND json_type(CASE WHEN json_valid(result) THEN result ELSE '{}' END,'$.exercise_group_receipt')='text'
        AND json_extract(CASE WHEN json_valid(result) THEN result ELSE '{}' END,'$.ok')=1
        AND json_extract(CASE WHEN json_valid(result) THEN result ELSE '{}' END,'$.group_id')=?3
      ORDER BY created_at,id`,
  ).bind(userId, operation, args.group_id, args.expected_version).all<{ args: string; result: string }>();
  const request = canonicalExerciseGroupArgs(args);
  for (const row of rows.results) {
    if (canonicalExerciseGroupArgs(JSON.parse(row.args)) !== request) continue;
    const { exercise_group_receipt: _, ...acknowledgement } = JSON.parse(row.result) as
      ExerciseGroupAcknowledgement & { exercise_group_receipt: string };
    return { ...acknowledgement, replayed: true };
  }
  return null;
}

async function findExerciseGroupReceipt(db: D1Database, userId: string, actor: string, key: string): Promise<ExerciseGroupAcknowledgement | null> {
  const row = await workoutDB(db).prepare(
    `SELECT result FROM audit_log WHERE user_id=?1 AND actor=?2 AND json_valid(result)
      AND json_extract(CASE WHEN json_valid(result) THEN result ELSE '{}' END,'$.exercise_group_receipt')=?3 LIMIT 1`,
  ).bind(userId, actor, key).first<{ result: string }>();
  if (!row) return null;
  const { exercise_group_receipt: _, ...result } = JSON.parse(row.result) as ExerciseGroupAcknowledgement & { exercise_group_receipt: string };
  return { ...result, replayed: true };
}

async function commitExerciseGroup(
  db: D1Database, plan: PlanRow, changed: readonly TemplateExerciseRow[],
  result: ExerciseGroupAcknowledgement, key: string, attribution: PlanWriteAttribution,
): Promise<ExerciseGroupResult> {
  const nonce = crypto.randomUUID();
  const ts = Date.now();
  const statements = preparePlanWriteStart(db, plan, attribution, ts, nonce);
  for (const slot of changed) statements.push(workoutDB(db).prepare(
    `UPDATE template_exercises SET group_id=?2,group_rest_seconds=?3,group_transition_seconds=?4,
       target_sets=?5,order_index=?6,updated_at=?7 WHERE id=?1
       AND EXISTS (SELECT 1 FROM plans p JOIN workouts d ON d.plan_id=p.id
         WHERE d.id=template_exercises.workout_id AND p.id=?8 AND p.user_id=?9
           AND p.version=-?10 AND p.plan_write_nonce=?11)`,
  ).bind(slot.id, slot.group_id ?? null, slot.group_rest_seconds ?? null,
    slot.group_transition_seconds ?? null, slot.target_sets, slot.order_index, ts,
    plan.id, plan.user_id, plan.version, nonce));
  const versionIndex = statements.length;
  statements.push(...preparePlanWriteFinish(db, plan, {
    ...attribution,
    note: attribution.note ?? (result.cleared ? 'Ungrouped exercises.' : `Grouped ${result.members.length} exercises for ${result.target_sets} rounds.`),
    result: { ...result, exercise_group_receipt: key },
  }, ts, nonce));
  const rows = await runWorkoutWriteBatch(db, statements);
  if ((rows[0]?.meta.changes ?? 0) !== 1 || !rows[versionIndex]?.results[0]) {
    // A concurrent copy may have committed the same request while we read.
    const replay = await findExerciseGroupReceipt(db, plan.user_id, attribution.actor, key);
    if (replay) return replay;
    const latest = await getActivePlan(db, plan.user_id);
    return { conflict: true, current_version: latest?.version ?? plan.version };
  }
  return result;
}

export async function setGroup(
  db: D1Database, userId: string, dayId: string, groupId: string, memberIds: string[],
  options: SetExerciseGroupOptions,
  attribution: PlanWriteAttribution = { actor: 'system', operation: 'group_exercises' },
): Promise<ExerciseGroupResult> {
  const invalid = new Set<string>();
  if (!isGroupId(groupId)) invalid.add('group_id');
  if (!Number.isSafeInteger(options.expected_version) || options.expected_version < 1) invalid.add('expected_version');
  if (!Number.isSafeInteger(options.round_rest) || options.round_rest < 0) invalid.add('round_rest');
  const transition = options.transition_rest === undefined ? 0 : options.transition_rest;
  if (!Number.isSafeInteger(transition) || transition < 0) invalid.add('transition_rest');
  if (options.order_index !== undefined && (!Number.isSafeInteger(options.order_index) || options.order_index < 0)) invalid.add('order_index');
  if (options.target_sets !== undefined && (!Number.isSafeInteger(options.target_sets) || options.target_sets < 1)) invalid.add('target_sets');
  if (!Array.isArray(memberIds) || memberIds.some((id) => typeof id !== 'string') || new Set(memberIds).size !== memberIds.length || memberIds.length < 2) invalid.add('members');
  if (invalid.size) return { error: 'invalid_fields', fields: [...invalid].sort() };
  const plan = await getActivePlan(db, userId);
  if (!plan) return { error: 'no_active_plan' };
  const key = JSON.stringify({ kind: 'set', plan_id: plan.id, day_id: dayId, group_id: groupId,
    members: memberIds, expected_version: options.expected_version,
    round_rest: options.round_rest, transition_rest: transition, target_sets: options.target_sets ?? null, order_index: options.order_index ?? null });
  const replay = await findExerciseGroupReceipt(db, userId, attribution.actor, key);
  if (replay) return replay;
  if (plan.version !== options.expected_version) return { conflict: true, current_version: plan.version };
  const tree = await getPlanTree(db, userId);
  if (!tree || tree.id !== plan.id || tree.version !== plan.version) {
    return { conflict: true, current_version: tree?.version ?? plan.version };
  }
  const day = tree.workouts.find((day) => day.id === dayId);
  if (!day) return { error: 'day_not_found' };
  if (tree.workouts.some((day) => day.id !== dayId && day.exercises.some((slot) => slot.group_id === groupId))) {
    return { error: 'group_conflict', fields: ['group_id'] };
  }
  const selected = memberIds.map((id) => day.exercises.find((slot) => slot.id === id));
  if (selected.some((slot) => !slot)) return { error: 'group_conflict', fields: ['members'] };
  if (selected.some((slot) => slot!.group_id != null && slot!.group_id !== groupId)) {
    return { error: 'group_conflict', fields: ['group_id'] };
  }
  const memberSet = new Set(memberIds);
  const positions = day.exercises.filter((slot) => memberSet.has(slot.id)).map((slot) => slot.order_index).sort((a, b) => a - b);
  let proposed = day.exercises.map((slot) => {
    const index = memberIds.indexOf(slot.id);
    if (index !== -1) return { ...slot, group_id: groupId, group_rest_seconds: options.round_rest,
      group_transition_seconds: transition, target_sets: options.target_sets ?? slot.target_sets,
      order_index: positions[index]! };
    return slot.group_id === groupId ? { ...slot, ...emptyExerciseGroup } : slot;
  });
  if (options.order_index !== undefined) {
    const others = proposed.filter((slot) => !memberSet.has(slot.id));
    const members = memberIds.map((id) => proposed.find((slot) => slot.id === id)!);
    const target = Math.min(options.order_index, others.length);
    proposed = [...others.slice(0, target), ...members, ...others.slice(target)]
      .map((slot, index) => ({ ...slot, order_index: index }));
  }
  const groupInvalid = validateExerciseGroups(proposed);
  if (groupInvalid) return groupInvalid;
  for (const slot of proposed.filter((slot) => memberSet.has(slot.id) || day.exercises.find((old) => old.id === slot.id)?.group_id === groupId)) {
    let progression: unknown;
    try { progression = slot.progression == null ? null : JSON.parse(slot.progression); }
    catch { return { error: 'invalid_fields', fields: ['progression'] }; }
    const invalid = validateExercisePrescription({ ...slot, progression }, { modality: slot.exercise_modality });
    if (invalid) return invalid;
  }
  const changed = proposed.filter((slot) => {
    const old = day.exercises.find((old) => old.id === slot.id)!;
    return slot.group_id !== old.group_id || slot.group_rest_seconds !== old.group_rest_seconds
      || slot.group_transition_seconds !== old.group_transition_seconds || slot.target_sets !== old.target_sets
      || slot.order_index !== old.order_index;
  });
  const result: ExerciseGroupAcknowledgement = { ok: true, plan_id: plan.id,
    version: plan.version + (changed.length ? 1 : 0), group_id: groupId, day_id: dayId,
    members: memberIds, round_rest: options.round_rest, transition_rest: transition,
    target_sets: proposed.find((slot) => slot.id === memberIds[0])!.target_sets, cleared: false };
  if (!changed.length) return { ...result, unchanged: true };
  return commitExerciseGroup(db, plan, changed, result, key, attribution);
}

export async function clearGroup(
  db: D1Database, userId: string, groupId: string, expectedVersion: number,
  attribution: PlanWriteAttribution = { actor: 'system', operation: 'ungroup_exercises' },
  scopeDayId?: string,
): Promise<ExerciseGroupResult> {
  const fields: string[] = [];
  if (!isGroupId(groupId)) fields.push('group_id');
  if (!Number.isSafeInteger(expectedVersion) || expectedVersion < 1) fields.push('expected_version');
  if (fields.length) return { error: 'invalid_fields', fields };
  const plan = await getActivePlan(db, userId);
  if (!plan) return { error: 'no_active_plan' };
  const key = JSON.stringify({ kind: 'clear', plan_id: plan.id, group_id: groupId, expected_version: expectedVersion });
  const replay = await findExerciseGroupReceipt(db, userId, attribution.actor, key);
  if (replay) return scopeDayId !== undefined && replay.day_id !== scopeDayId
    ? { error: 'group_conflict', fields: ['group_id'] } : replay;
  if (plan.version !== expectedVersion) return { conflict: true, current_version: plan.version };
  const tree = await getPlanTree(db, userId);
  if (!tree || tree.id !== plan.id || tree.version !== plan.version) return { conflict: true, current_version: tree?.version ?? plan.version };
  if (scopeDayId !== undefined && !tree.workouts.some((day) => day.id === scopeDayId)) return { error: 'day_not_found' };
  const members = tree.workouts.flatMap((day) => day.exercises.filter((slot) => slot.group_id === groupId));
  if (scopeDayId !== undefined && members.some((slot) => slot.workout_id !== scopeDayId)) {
    return { error: 'group_conflict', fields: ['group_id'] };
  }
  const changed = members.map((slot) => ({ ...slot, ...emptyExerciseGroup }));
  for (const slot of changed) {
    let progression: unknown;
    try { progression = slot.progression == null ? null : JSON.parse(slot.progression); }
    catch { return { error: 'invalid_fields', fields: ['progression'] }; }
    const invalid = validateExercisePrescription({ ...slot, progression }, { modality: slot.exercise_modality });
    if (invalid) return invalid;
  }
  const candidate = tree.workouts.map((day) => ({ ...day, exercises: day.exercises.map((slot) => slot.group_id === groupId ? { ...slot, ...emptyExerciseGroup } : slot) }));
  const groupInvalid = validatePlanExerciseGroups(candidate);
  if (groupInvalid) return groupInvalid;
  const result: ExerciseGroupAcknowledgement = { ok: true, plan_id: plan.id,
    version: plan.version + (changed.length ? 1 : 0), group_id: groupId,
    day_id: members[0]?.workout_id ?? scopeDayId ?? null, members: [], round_rest: null,
    transition_rest: null, target_sets: null, cleared: true };
  if (!changed.length) return { ...result, unchanged: true };
  return commitExerciseGroup(db, plan, changed, result, key, attribution);
}
