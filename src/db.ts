// Service layer: all D1 access goes through here so REST (now) and MCP
// (milestone b) share identical behavior. Timestamps are epoch-ms integers.
import type {
  ActivityRow,
  DayConflict,
  DayTemplateRow,
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
const now = () => Date.now();
const uuid = () => crypto.randomUUID();

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
  const receipt = await db
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
  const row = await db
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
    (await db
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
  const result = await db
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
  const result = await db
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
  const result = await db
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
  const [stored, retained] = await db.batch([
    db
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
    db
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
  const [cleared, removed] = await db.batch([
    db
      .prepare(
        `UPDATE apple_grant_exchange_state
            SET reservation_id = NULL, active_since = NULL
          WHERE user_id = ?1 AND reservation_id = ?2`,
      )
      .bind(userId, reservationId),
    db
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
  const row = await db
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
  const row = await db
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
  const row = await db
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
  const existing = await db
    .prepare('SELECT * FROM users WHERE apple_sub = ?1')
    .bind(appleSub)
    .first<User>();
  if (existing) {
    if (displayName && !existing.display_name) {
      await db
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
    intervals_oauth_access_token: null,
    intervals_oauth_refresh_token: null,
    intervals_oauth_expires_at: null,
    intervals_auth_error_at: null,
    mcp_passphrase_hash: null,
    mcp_passphrase_salt: null,
  };
  await db
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
  await db
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
  return db
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
  const candidate: User = {
    id: uuid(),
    apple_sub: appleSub,
    email,
    display_name: displayName,
    created_at: now(),
    timezone: null,
    intervals_api_key: null,
    intervals_athlete_id: null,
    intervals_oauth_access_token: null,
    intervals_oauth_refresh_token: null,
    intervals_oauth_expires_at: null,
    intervals_auth_error_at: null,
    mcp_passphrase_hash: null,
    mcp_passphrase_salt: null,
  };
  await db
    .prepare(
      `INSERT INTO users (id, apple_sub, email, display_name, created_at)
       SELECT ?1, ?2, ?3, ?4, ?5
        WHERE NOT EXISTS (
                SELECT 1 FROM owner_deletion_tombstone WHERE singleton = 1
              )
          AND (?6 = 0 OR NOT EXISTS (SELECT 1 FROM users))
       ON CONFLICT(apple_sub) DO NOTHING`,
    )
    .bind(
      candidate.id,
      candidate.apple_sub,
      candidate.email,
      candidate.display_name,
      candidate.created_at,
      requireEmptyUsers ? 1 : 0,
    )
    .run();
  return db
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
  const byApple = await db
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
    const bootstrap = await db
      .prepare('SELECT * FROM users WHERE apple_sub = ?1')
      .bind(BOOTSTRAP_APPLE_SUB)
      .first<User>();
    if (bootstrap) {
      const claimed = await db
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
        return db
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
  if (ownerAppleSub) {
    return await db
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
    return await db
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
  return await db
    .prepare(
      `SELECT u.* FROM users u
        WHERE NOT EXISTS (
                SELECT 1 FROM owner_deletion_tombstone WHERE singleton = 1
              )
        ORDER BY u.created_at LIMIT 1`,
    )
    .first<User>();
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
  const rows = await db
    .prepare('SELECT apple_sub FROM users')
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
  return db
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
  await db.batch([
    db
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
    db
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

  let intent = await db
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
    const liveUser = await db
      .prepare('SELECT 1 AS x FROM users WHERE id = ?1')
      .bind(userId)
      .first<{ x: number }>();
    return liveUser ? { error: 'conflict' } : { error: 'not_found' };
  }

  let appleRevocation = intent.apple_revocation;
  if (appleRevocation === null) {
    const credential = await db
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
    await db
      .prepare(
        `UPDATE account_deletion_intents
            SET apple_revocation = ?3
          WHERE user_id = ?1
            AND idempotency_key_sha256 = ?2
            AND apple_revocation IS NULL`,
      )
      .bind(userId, idempotencyKeyHash, appleRevocation)
      .run();
    intent = await db
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

  const user = await db
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
    db
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
      db
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
    db
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
    db
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
    db
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
    db
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
    db.prepare('DELETE FROM group_invites WHERE created_by = ?1').bind(userId),
    db.prepare('UPDATE group_invites SET used_by = NULL WHERE used_by = ?1').bind(userId),
    db.prepare('DELETE FROM group_members WHERE user_id = ?1').bind(userId),

    // Session-dependent ledgers and logs must go before their canonical
    // sessions; the plan tree follows sessions because those rows hold plan/day
    // references under strict foreign keys.
    db
      .prepare(
        `DELETE FROM session_aliases
          WHERE canonical_session_id IN (
            SELECT id FROM sessions WHERE user_id = ?1
          )`,
      )
      .bind(userId),
    db
      .prepare(
        `DELETE FROM session_load_exports
          WHERE session_id IN (SELECT id FROM sessions WHERE user_id = ?1)`,
      )
      .bind(userId),
    db
      .prepare(
        `DELETE FROM set_logs
          WHERE session_id IN (SELECT id FROM sessions WHERE user_id = ?1)`,
      )
      .bind(userId),
    db.prepare('DELETE FROM sessions WHERE user_id = ?1').bind(userId),
    db
      .prepare(
        `DELETE FROM template_exercises
          WHERE day_template_id IN (
            SELECT d.id FROM day_templates d
            JOIN plans p ON p.id = d.plan_id
            WHERE p.user_id = ?1
          )`,
      )
      .bind(userId),
    db
      .prepare(
        `DELETE FROM day_templates
          WHERE plan_id IN (SELECT id FROM plans WHERE user_id = ?1)`,
      )
      .bind(userId),
    db.prepare('DELETE FROM plans WHERE user_id = ?1').bind(userId),

    db.prepare('DELETE FROM activities WHERE user_id = ?1').bind(userId),
    db.prepare('DELETE FROM external_events WHERE user_id = ?1').bind(userId),
    db.prepare('DELETE FROM external_activities WHERE user_id = ?1').bind(userId),
    db.prepare('DELETE FROM notes WHERE user_id = ?1').bind(userId),
    db.prepare('DELETE FROM audit_log WHERE user_id = ?1').bind(userId),
    db.prepare('DELETE FROM intervals_oauth_states WHERE user_id = ?1').bind(userId),
    db.prepare('DELETE FROM oauth_codes WHERE user_id = ?1').bind(userId),
    db.prepare('DELETE FROM oauth_tokens WHERE user_id = ?1').bind(userId),
  );

  // Tokens issued before multi-user MCP have a NULL principal and resolve to
  // the owner. Revoke them only when the distinguished owner is deleted.
  if (deletingOwner) {
    statements.push(
      db.prepare('DELETE FROM oauth_codes WHERE user_id IS NULL'),
      db.prepare('DELETE FROM oauth_tokens WHERE user_id IS NULL'),
    );
  }

  statements.push(db.prepare('DELETE FROM users WHERE id = ?1').bind(userId));
  await db.batch(statements);
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
  await db
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
  const rows = await db
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
  const row = await db
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
  await db.prepare('UPDATE users SET timezone = ?2 WHERE id = ?1').bind(userId, tz).run();
}

// ---- intervals.icu credentials (per-user; M1 multi-user foundation) ------

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
  athlete_id: string;
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
  const r = await db
    .prepare(
      `SELECT id, intervals_api_key, intervals_oauth_access_token, intervals_athlete_id
         FROM users
        WHERE intervals_athlete_id IS NOT NULL
          AND (intervals_api_key IS NOT NULL
               OR intervals_oauth_access_token IS NOT NULL)`,
    )
    .all<{
      id: string;
      intervals_api_key: string | null;
      intervals_oauth_access_token: string | null;
      intervals_athlete_id: string;
    }>();
  return r.results.map((row) => ({
    user_id: row.id,
    api_key: row.intervals_api_key,
    access_token: row.intervals_oauth_access_token,
    athlete_id: row.intervals_athlete_id,
  }));
}

/** Read one user's intervals.icu credentials (nulls if either is unset). */
export async function getUserIntervalsCreds(
  db: D1Database,
  userId: string,
): Promise<{
  api_key: string | null;
  access_token: string | null;
  athlete_id: string | null;
  auth_error_at: number | null;
}> {
  const r = await db
    .prepare(
      `SELECT intervals_api_key AS api_key,
              intervals_oauth_access_token AS access_token,
              intervals_athlete_id AS athlete_id,
              intervals_auth_error_at AS auth_error_at
         FROM users WHERE id = ?1`,
    )
    .bind(userId)
    .first<{
      api_key: string | null;
      access_token: string | null;
      athlete_id: string | null;
      auth_error_at: number | null;
    }>();
  return {
    api_key: r?.api_key ?? null,
    access_token: r?.access_token ?? null,
    athlete_id: r?.athlete_id ?? null,
    auth_error_at: r?.auth_error_at ?? null,
  };
}

/**
 * Resolve the user row owning a given intervals.icu `athlete_id`. Used by the
 * webhook receiver (`POST /webhooks/intervals`) to route a pushed event to the
 * right user before kicking the relevant sync. `intervals_athlete_id` is the
 * canonical "intervals connected" column shared by both auth schemes (API key
 * and OAuth), so a single lookup covers both. Returns null when no user has
 * connected that athlete (an unknown/disconnected athlete → graceful no-op).
 */
export async function getUserByIntervalsAthleteId(
  db: D1Database,
  athleteId: string,
): Promise<User | null> {
  return await db
    .prepare('SELECT * FROM users WHERE intervals_athlete_id = ?1')
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
  const r = await db
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
  if ((owner.intervals_api_key || owner.intervals_oauth_access_token) && owner.intervals_athlete_id) {
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
  await db
    .prepare(
      `UPDATE users
          SET intervals_api_key = ?2,
              intervals_athlete_id = ?3
        WHERE id = ?1
          AND intervals_api_key IS NULL
          AND intervals_athlete_id IS NULL`,
    )
    .bind(owner.id, apiKey, athleteId)
    .run();
  return listUsersWithIntervalsCreds(db);
}

/**
 * Set/clear a user's intervals.icu credentials. Both columns move together
 * — passing null on EITHER clears the pair (disconnect). Returns the
 * resulting connection state. Audit is the caller's responsibility (the
 * REST handler writes an audit row tagged actor='ios').
 */
export async function setUserIntervalsCreds(
  db: D1Database,
  userId: string,
  apiKey: string | null,
  athleteId: string | null,
): Promise<{ connected: boolean }> {
  const connect = !!(apiKey && athleteId);
  // The API-key and OAuth schemes are mutually exclusive: writing an API key
  // clears any OAuth token, and a disconnect (nulls) clears BOTH schemes'
  // columns so "not connected" is unambiguous across the codebase.
  await db
    .prepare(
      `UPDATE users
          SET intervals_api_key = ?2,
              intervals_athlete_id = ?3,
              intervals_oauth_access_token = NULL,
              intervals_oauth_refresh_token = NULL,
              intervals_oauth_expires_at = NULL,
              intervals_auth_error_at = NULL
        WHERE id = ?1`,
    )
    .bind(userId, connect ? apiKey : null, connect ? athleteId : null)
    .run();
  return { connected: connect };
}

/**
 * Store a user's intervals.icu OAuth credentials — the /auth/intervals/callback
 * success path. Sets the bearer token + the `athlete.id` the token exchange
 * returned (into the shared `intervals_athlete_id` column) and CLEARS any
 * prior API key (the two schemes are mutually exclusive; Bearer wins).
 * `refreshToken` / `expiresAt` are stored when present — the documented
 * intervals.icu token response carries neither (long-lived tokens), so both
 * are typically null.
 */
export async function setUserIntervalsOAuth(
  db: D1Database,
  userId: string,
  accessToken: string,
  refreshToken: string | null,
  expiresAt: number | null,
  athleteId: string,
): Promise<void> {
  await db
    .prepare(
      `UPDATE users
          SET intervals_oauth_access_token = ?2,
              intervals_oauth_refresh_token = ?3,
              intervals_oauth_expires_at = ?4,
              intervals_athlete_id = ?5,
              intervals_api_key = NULL,
              intervals_auth_error_at = NULL
        WHERE id = ?1`,
    )
    .bind(userId, accessToken, refreshToken, expiresAt, athleteId)
    .run();
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
  await db
    .prepare(
      `INSERT INTO intervals_oauth_states (state, user_id, created_at, expires_at)
       VALUES (?1, ?2, ?3, ?4)`,
    )
    .bind(state, userId, ts, ts + ttlMs)
    .run();
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
  const ts = now();
  // ATOMIC single-use: DELETE … RETURNING removes the row and yields its value
  // in one statement, so two concurrent callbacks (browser preload, double-tap,
  // replay) can't both observe the same valid state — only one DELETE returns
  // the row, the other gets nothing.
  const row = await db
    .prepare('DELETE FROM intervals_oauth_states WHERE state = ?1 RETURNING user_id, expires_at')
    .bind(state)
    .first<{ user_id: string; expires_at: number }>();
  // Best-effort sweep of any OTHER now-expired rows (kept out of the atomic
  // statement above so it never affects the single-use result).
  await db.prepare('DELETE FROM intervals_oauth_states WHERE expires_at < ?1').bind(ts).run();
  if (!row || row.expires_at < ts) return null;
  return row.user_id;
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
  intervals: { connected: boolean; athlete_id: string | null; needs_reauth: boolean };
  claude: { is_owner: boolean; connected: boolean; last_active: number | null };
  // Apple Health group-feed opt-in (migration 0028). Off by default; the iOS
  // Apple Health detail toggle flips it via PATCH /api/me/health-sharing.
  health: { sharing_in_group: boolean };
}

export async function getMeProfile(
  db: D1Database,
  userId: string,
  ownerAppleSub: string | undefined,
): Promise<MeProfile> {
  const u = await db
    .prepare(
      'SELECT display_name, email, intervals_athlete_id, intervals_auth_error_at, share_health_activities FROM users WHERE id = ?1',
    )
    .bind(userId)
    .first<{
      display_name: string | null;
      email: string | null;
      intervals_athlete_id: string | null;
      intervals_auth_error_at: number | null;
      share_health_activities: number | null;
    }>();

  // Claude connection is PER-USER (M3): a token bound to THIS user means their
  // connector is linked (a refresh_token is the durable grant claude.ai keeps,
  // so it survives access-token expiry). The owner additionally matches legacy
  // tokens with a NULL user_id — issued before M3, when /mcp always resolved to
  // the owner. (Codex #64 P2: non-owner grants must surface in their Profile.)
  const owner = await findOwnerRow(db, ownerAppleSub);
  const isOwner = !!owner && owner.id === userId;

  const grant = await db
    .prepare(
      'SELECT 1 AS x FROM oauth_tokens WHERE refresh_token IS NOT NULL AND (user_id = ?1' +
        (isOwner ? ' OR user_id IS NULL' : '') +
        ') LIMIT 1',
    )
    .bind(userId)
    .first<{ x: number }>();
  const claudeConnected = !!grant;
  const lastMcp = await db
    .prepare("SELECT MAX(created_at) AS t FROM audit_log WHERE user_id = ?1 AND actor = 'mcp'")
    .bind(userId)
    .first<{ t: number | null }>();
  const lastActive = lastMcp?.t ?? null;

  return {
    display_name: u?.display_name ?? null,
    email: u?.email ?? null,
    intervals: {
      connected: !!u?.intervals_athlete_id,
      athlete_id: u?.intervals_athlete_id ?? null,
      // A dead credential clears athlete_id (connected:false) AND sets the
      // marker — so iOS can say "your intervals connection expired, reconnect"
      // rather than the ambiguous "not connected".
      needs_reauth: u?.intervals_auth_error_at != null,
    },
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
  const projection = await db.batch<Record<string, unknown>>([
    db
      .prepare(
        `SELECT id, apple_sub, email, display_name, created_at, timezone,
                intervals_athlete_id, intervals_auth_error_at,
                share_health_activities
           FROM users WHERE id = ?1`,
      )
      .bind(userId),
    db
      .prepare('SELECT * FROM plans WHERE user_id = ?1 ORDER BY created_at, id')
      .bind(userId),
    db
      .prepare(
        `SELECT d.* FROM day_templates d
         JOIN plans p ON p.id = d.plan_id
         WHERE p.user_id = ?1
         ORDER BY d.plan_id, d.order_index, d.created_at, d.id`,
      )
      .bind(userId),
    db
      .prepare(
        `SELECT te.* FROM template_exercises te
         JOIN day_templates d ON d.id = te.day_template_id
         JOIN plans p ON p.id = d.plan_id
         WHERE p.user_id = ?1
         ORDER BY te.day_template_id, te.order_index, te.created_at, te.id`,
      )
      .bind(userId),
    db
      .prepare('SELECT * FROM sessions WHERE user_id = ?1 ORDER BY date, created_at, id')
      .bind(userId),
    db
      .prepare(
        `SELECT sl.* FROM set_logs sl
         JOIN sessions s ON s.id = sl.session_id
         WHERE s.user_id = ?1
         ORDER BY sl.logged_at, sl.id`,
      )
      .bind(userId),
    db
      .prepare(
        `SELECT e.* FROM exercises e
         WHERE e.id IN (
           SELECT te.exercise_id FROM template_exercises te
           JOIN day_templates d ON d.id = te.day_template_id
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
    db
      .prepare(
        `SELECT sa.* FROM session_aliases sa
         JOIN sessions s ON s.id = sa.canonical_session_id
         WHERE s.user_id = ?1
         ORDER BY sa.alias_session_id`,
      )
      .bind(userId),
    db
      .prepare(
        `SELECT sle.* FROM session_load_exports sle
         JOIN sessions s ON s.id = sle.session_id
         WHERE s.user_id = ?1
         ORDER BY sle.updated_at, sle.session_id`,
      )
      .bind(userId),
    db
      .prepare('SELECT * FROM notes WHERE user_id = ?1 ORDER BY created_at, id')
      .bind(userId),
    db
      .prepare('SELECT * FROM audit_log WHERE user_id = ?1 ORDER BY created_at, id')
      .bind(userId),
    db
      .prepare('SELECT * FROM external_events WHERE user_id = ?1 ORDER BY date, id')
      .bind(userId),
    db
      .prepare(
        'SELECT * FROM external_activities WHERE user_id = ?1 ORDER BY date, id',
      )
      .bind(userId),
    db
      .prepare(
        'SELECT * FROM activities WHERE user_id = ?1 ORDER BY date, logged_at, id',
      )
      .bind(userId),
    db
      .prepare(
        `SELECT gm.group_id, g.name AS group_name, gm.display_name, gm.joined_at
           FROM group_members gm
           JOIN groups g ON g.id = gm.group_id
          WHERE gm.user_id = ?1
          ORDER BY gm.joined_at, gm.group_id`,
      )
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
  const memberships = rowsAt(14);

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
    schema_version: 1,
    exported_at: now(),
    account,
    training: {
      plans,
      day_templates: days,
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
    },
    group_memberships: memberships,
  };
}

export async function setUserDisplayName(
  db: D1Database,
  userId: string,
  displayName: string,
): Promise<boolean> {
  const result = await db
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
  await db
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
  await db.batch([
    db
      .prepare('INSERT INTO groups (id,name,created_by,created_at) VALUES (?1,?2,?3,?4)')
      .bind(id, name, userId, ts),
    db
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
  const r = await db
    .prepare('SELECT 1 AS x FROM group_members WHERE group_id = ?1 AND user_id = ?2')
    .bind(groupId, userId)
    .first<{ x: number }>();
  return !!r;
}

/**
 * Hydrate a group with its members + effective display names (per-group
 * override > users.display_name). Returns null if no such group.
 */
async function hydrateGroup(
  db: D1Database,
  group: Group,
): Promise<Group & { members: ResolvedGroupMember[] }> {
  const r = await db
    .prepare(
      `SELECT gm.group_id, gm.user_id, gm.display_name, gm.joined_at,
              u.display_name AS user_display_name
         FROM group_members gm
         JOIN users u ON u.id = gm.user_id
        WHERE gm.group_id = ?1
        ORDER BY gm.joined_at, gm.user_id`,
    )
    .bind(group.id)
    .all<{
      group_id: string;
      user_id: string;
      display_name: string | null;
      joined_at: number;
      user_display_name: string | null;
    }>();
  const members: ResolvedGroupMember[] = r.results.map((row) => ({
    group_id: row.group_id,
    user_id: row.user_id,
    display_name: row.display_name,
    joined_at: row.joined_at,
    effective_display_name: row.display_name ?? row.user_display_name,
  }));
  return { ...group, members };
}

/**
 * List groups the user belongs to, with members hydrated. Stable ordering
 * (created_at, then id) so the iOS list isn't shuffled across reads.
 */
export async function listGroupsForUser(
  db: D1Database,
  userId: string,
): Promise<Array<Group & { members: ResolvedGroupMember[] }>> {
  const r = await db
    .prepare(
      `SELECT g.* FROM groups g
         JOIN group_members gm ON gm.group_id = g.id
        WHERE gm.user_id = ?1
        ORDER BY g.created_at, g.id`,
    )
    .bind(userId)
    .all<Group>();
  const out: Array<Group & { members: ResolvedGroupMember[] }> = [];
  for (const g of r.results) {
    out.push(await hydrateGroup(db, g));
  }
  return out;
}

/** Read a group + its members. Returns null if the group does not exist. */
export async function getGroupWithMembers(
  db: D1Database,
  groupId: string,
): Promise<(Group & { members: ResolvedGroupMember[] }) | null> {
  const g = await db
    .prepare('SELECT * FROM groups WHERE id = ?1')
    .bind(groupId)
    .first<Group>();
  if (!g) return null;
  return hydrateGroup(db, g);
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
      await db
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
  const r = await db
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
  const group = await db
    .prepare('SELECT name FROM groups WHERE id = ?1')
    .bind(invite.group_id)
    .first<{ name: string }>();
  const group_name = group?.name ?? null;
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
  const [claim] = await db.batch([
    // Repeat every mutable validation inside the transaction. In particular,
    // requiring a live principal with no deletion intent prevents a deletion
    // that won the database write lock first from consuming the invite, even
    // while provider revocation intentionally keeps the users row present.
    db
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
    db
      .prepare(
        `INSERT INTO audit_log
           (id,user_id,actor,tool,args,result,created_at)
         SELECT ?1,?2,'ios','redeem_invite',?3,'joined',?4
          WHERE changes() = 1`,
      )
      .bind(auditId, userId, auditArgs, ts),
    db
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
  const res = await db
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
  const res = await db
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
  const r = await db
    .prepare('SELECT COUNT(*) AS c FROM users')
    .first<{ c: number }>();
  return r?.c ?? 0;
}

// ---- plan tree -----------------------------------------------------------

export async function getActivePlan(
  db: D1Database,
  userId: string,
): Promise<PlanRow | null> {
  return db
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
  const days = await db
    .prepare('SELECT * FROM day_templates WHERE plan_id = ?1 ORDER BY order_index, created_at, id')
    .bind(plan.id)
    .all<DayTemplateRow>();
  const dayIds = days.results.map((d) => d.id);
  let exercises: EnrichedTemplateExercise[] = [];
  if (dayIds.length) {
    const placeholders = dayIds.map((_, i) => `?${i + 1}`).join(',');
    const res = await db
      .prepare(
        `SELECT te.*, e.name AS exercise_name, e.unit AS exercise_unit,
                e.primary_muscle AS exercise_muscle, e.modality AS exercise_modality,
                e.laterality AS exercise_laterality, e.load_mode AS exercise_load_mode,
                e.demo_slug AS exercise_demo_slug
         FROM template_exercises te
         JOIN exercises e ON e.id = te.exercise_id
         WHERE te.day_template_id IN (${placeholders}) ORDER BY te.order_index, te.created_at, te.id`,
      )
      .bind(...dayIds)
      .all<EnrichedTemplateExercise>();
    exercises = res.results;
  }
  return {
    ...plan,
    days: days.results.map((d) => ({
      ...d,
      exercises: exercises.filter((e) => e.day_template_id === d.id),
    })),
  };
}

export async function createPlan(
  db: D1Database,
  userId: string,
  name: string,
  meta: unknown = null,
): Promise<PlanRow> {
  const ts = now();
  const planId = uuid();
  const serializedMeta = meta == null ? null : JSON.stringify(meta);
  // Archive + replace in one D1 transaction. This also serializes against
  // ensureActivePlan's conflict-safe insert: an ensure cannot land between
  // these statements and make the replacement violate ux_one_active_plan.
  // Allocate from every prior plan inside that transaction so replacement
  // never moves the per-user sync cursor backward or repeats it.
  const results = await db.batch<PlanRow>([
    db
      .prepare(
        "UPDATE plans SET status = 'archived', updated_at = ?2 WHERE user_id = ?1 AND status = 'active'",
      )
      .bind(userId, ts),
    db
      .prepare(
        `INSERT INTO plans
           (id,user_id,name,status,version,meta,created_at,updated_at)
         SELECT ?1,?2,?3,'active',COALESCE(MAX(version),0)+1,?4,?5,?5
           FROM plans
          WHERE user_id=?2
         RETURNING *`,
      )
      .bind(planId, userId, name, serializedMeta, ts),
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
): Promise<{ plan: PlanRow; created: boolean }> {
  const existing = await getActivePlan(db, userId);
  if (existing) return { plan: existing, created: false };

  const ts = now();
  const candidateId = uuid();
  const created = await db
    .prepare(
      `INSERT INTO plans
         (id,user_id,name,status,version,meta,created_at,updated_at)
       SELECT ?1,?2,?3,'active',COALESCE(MAX(version),0)+1,NULL,?4,?4
         FROM plans
        WHERE user_id=?2
       ON CONFLICT DO NOTHING
       RETURNING *`,
    )
    .bind(candidateId, userId, name, ts)
    .first<PlanRow>();
  if (created) {
    return { plan: created, created: true };
  }

  const winner = await getActivePlan(db, userId);
  if (!winner) throw new Error('active_plan_create_conflict_without_winner');
  return { plan: winner, created: false };
}

/** Bump the plan version + updated_at. Called by every plan-tree mutation. */
export async function bumpPlanVersion(db: D1Database, planId: string): Promise<number> {
  const row = await db
    .prepare('UPDATE plans SET version = version + 1, updated_at = ?2 WHERE id = ?1 RETURNING version')
    .bind(planId, now())
    .first<{ version: number }>();
  return row?.version ?? 0;
}

export async function addDayTemplate(
  db: D1Database,
  planId: string,
  name: string,
  dayLabel: string | null,
  orderIndex: number,
  normalizeOrder = false,
): Promise<DayTemplateRow> {
  const ts = now();
  const row: DayTemplateRow = {
    id: uuid(),
    plan_id: planId,
    name,
    day_label: dayLabel,
    order_index: orderIndex,
    notes: null,
    created_at: ts,
    updated_at: ts,
  };
  await db
    .prepare(
      'INSERT INTO day_templates (id,plan_id,name,day_label,order_index,notes,created_at,updated_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8)',
    )
    .bind(row.id, row.plan_id, row.name, row.day_label, row.order_index, row.notes, row.created_at, row.updated_at)
    .run();
  if (normalizeOrder && await dedupePlanDayOrderIndexes(db, planId, row.id)) {
    const fresh = await db
      .prepare('SELECT order_index FROM day_templates WHERE id = ?1')
      .bind(row.id)
      .first<{ order_index: number }>();
    if (fresh) row.order_index = fresh.order_index;
  }
  await bumpPlanVersion(db, planId);
  return row;
}

/** Resolve a day only inside one already-authorized plan. */
export async function getDayTemplateInPlan(
  db: D1Database,
  planId: string,
  dayId: string,
): Promise<DayTemplateRow | null> {
  return db
    .prepare('SELECT * FROM day_templates WHERE id = ?1 AND plan_id = ?2')
    .bind(dayId, planId)
    .first<DayTemplateRow>();
}

/** Allowlist of patch keys accepted by `patchDayTemplate`. Unknown keys
 *  surface as `{ error: 'unknown_fields', fields }` — same diagnosability
 *  contract as updateExercise. */
const DAY_TEMPLATE_PATCH_KEYS = new Set<string>([
  'name',
  'day_label',
  'order_index',
  'notes',
]);

export async function patchDayTemplate(
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
): Promise<DayTemplateRow | { error: 'unknown_fields'; fields: string[] } | null> {
  const existing = await db
    .prepare('SELECT * FROM day_templates WHERE id = ?1 AND plan_id = ?2')
    .bind(dayId, planId)
    .first<DayTemplateRow>();
  if (!existing) return null;
  const unknown = Object.keys(patch).filter((k) => !DAY_TEMPLATE_PATCH_KEYS.has(k));
  if (unknown.length > 0) return { error: 'unknown_fields', fields: unknown };
  const merged = {
    name: patch.name ?? existing.name,
    day_label: patch.day_label === undefined ? existing.day_label : patch.day_label,
    order_index: patch.order_index ?? existing.order_index,
    notes: patch.notes === undefined ? existing.notes : patch.notes,
  };
  await db
    .prepare('UPDATE day_templates SET name=?2, day_label=?3, order_index=?4, notes=?5, updated_at=?6 WHERE id=?1')
    .bind(dayId, merged.name, merged.day_label, merged.order_index, merged.notes, now())
    .run();
  if (normalizeOrder && patch.order_index !== undefined) {
    await dedupePlanDayOrderIndexes(db, planId, dayId);
    const fresh = await db
      .prepare('SELECT order_index FROM day_templates WHERE id = ?1')
      .bind(dayId)
      .first<{ order_index: number }>();
    if (fresh) merged.order_index = fresh.order_index;
  }
  await bumpPlanVersion(db, planId);
  return { ...existing, ...merged, updated_at: now() };
}

type PlanVersionConflict = { conflict: true; current_version: number };

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
export async function addDayTemplateAtVersion(
  db: D1Database,
  userId: string,
  plan: PlanRow,
  name: string,
  dayLabel: string | null,
  orderIndex: number,
): Promise<DayTemplateRow | PlanVersionConflict> {
  const ts = now();
  const row: DayTemplateRow = {
    id: uuid(),
    plan_id: plan.id,
    name,
    day_label: dayLabel,
    order_index: orderIndex,
    notes: null,
    created_at: ts,
    updated_at: ts,
  };
  const currentDays = await db
    .prepare(
      'SELECT id, order_index FROM day_templates WHERE plan_id = ?1 ORDER BY order_index, created_at, id',
    )
    .bind(plan.id)
    .all<{ id: string; order_index: number }>();
  const ordered = orderDayRows([...currentDays.results, row], row.id);
  const statements: D1PreparedStatement[] = [
    db
      .prepare(
        `INSERT INTO day_templates
         (id,plan_id,name,day_label,order_index,notes,created_at,updated_at)
         SELECT ?1,?2,?3,?4,?5,?6,?7,?8
          WHERE EXISTS (
            SELECT 1 FROM plans
             WHERE id = ?2 AND user_id = ?9 AND status = 'active' AND version = ?10
          )`,
      )
      .bind(
        row.id, row.plan_id, row.name, row.day_label, row.order_index, row.notes,
        row.created_at, row.updated_at, userId, plan.version,
      ),
    ...ordered.map((day, index) =>
      db
        .prepare(
          `UPDATE day_templates SET order_index = ?2, updated_at = ?3
            WHERE id = ?1 AND plan_id = ?4
              AND EXISTS (
                SELECT 1 FROM plans
                 WHERE id = ?4 AND user_id = ?5 AND status = 'active' AND version = ?6
              )`,
        )
        .bind(day.id, index, ts, plan.id, userId, plan.version),
    ),
    db
      .prepare(
        `UPDATE plans SET version = version + 1, updated_at = ?3
          WHERE id = ?1 AND user_id = ?2 AND status = 'active' AND version = ?4
          RETURNING version`,
      )
      .bind(plan.id, userId, ts, plan.version),
  ];
  const results = await db.batch<{ version: number }>(statements);
  const inserted = results[0];
  const updatedPlan = results.at(-1)?.results[0];
  if ((inserted?.meta.changes ?? 0) !== 1 || !updatedPlan) {
    return currentPlanVersion(db, userId, plan.version);
  }
  row.order_index = ordered.findIndex((day) => day.id === row.id);
  return row;
}

/** Rename/reorder one day with write-time optimistic concurrency. */
export async function patchDayTemplateAtVersion(
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
): Promise<DayTemplateRow | { error: 'unknown_fields'; fields: string[] } | PlanVersionConflict | null> {
  const existing = await getDayTemplateInPlan(db, plan.id, dayId);
  if (!existing) return null;
  const unknown = Object.keys(patch).filter((key) => !DAY_TEMPLATE_PATCH_KEYS.has(key));
  if (unknown.length > 0) return { error: 'unknown_fields', fields: unknown };
  const merged: DayTemplateRow = {
    ...existing,
    name: patch.name ?? existing.name,
    day_label: patch.day_label === undefined ? existing.day_label : patch.day_label,
    order_index: patch.order_index ?? existing.order_index,
    notes: patch.notes === undefined ? existing.notes : patch.notes,
    updated_at: now(),
  };
  const currentDays = await db
    .prepare(
      'SELECT id, order_index FROM day_templates WHERE plan_id = ?1 ORDER BY order_index, created_at, id',
    )
    .bind(plan.id)
    .all<{ id: string; order_index: number }>();
  const withMove = currentDays.results.map((day) =>
    day.id === dayId ? { ...day, order_index: merged.order_index } : day,
  );
  const ordered = patch.order_index === undefined
    ? withMove
    : orderDayRows(withMove, dayId);
  const statements: D1PreparedStatement[] = [
    db
      .prepare(
        `UPDATE day_templates
            SET name=?2, day_label=?3, order_index=?4, notes=?5, updated_at=?6
          WHERE id=?1 AND plan_id=?7
            AND EXISTS (
              SELECT 1 FROM plans
               WHERE id=?7 AND user_id=?8 AND status='active' AND version=?9
            )`,
      )
      .bind(
        dayId, merged.name, merged.day_label, merged.order_index, merged.notes,
        merged.updated_at, plan.id, userId, plan.version,
      ),
    ...(patch.order_index === undefined
      ? []
      : ordered.map((day, index) =>
          db
            .prepare(
              `UPDATE day_templates SET order_index=?2, updated_at=?3
                WHERE id=?1 AND plan_id=?4
                  AND EXISTS (
                    SELECT 1 FROM plans
                     WHERE id=?4 AND user_id=?5 AND status='active' AND version=?6
                  )`,
            )
            .bind(day.id, index, merged.updated_at, plan.id, userId, plan.version),
        )),
    db
      .prepare(
        `UPDATE plans SET version=version+1, updated_at=?3
          WHERE id=?1 AND user_id=?2 AND status='active' AND version=?4
          RETURNING version`,
      )
      .bind(plan.id, userId, merged.updated_at, plan.version),
  ];
  const results = await db.batch<{ version: number }>(statements);
  const patched = results[0];
  const updatedPlan = results.at(-1)?.results[0];
  if ((patched?.meta.changes ?? 0) !== 1 || !updatedPlan) {
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
  const rows = await db
    .prepare(
      'SELECT id, order_index FROM day_templates WHERE plan_id = ?1 ORDER BY order_index, created_at, id',
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
      await db
        .prepare('UPDATE day_templates SET order_index = ?2, updated_at = ?3 WHERE id = ?1')
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
  dayTemplateId: string,
): Promise<number> {
  const row = await db
    .prepare('SELECT COALESCE(MAX(order_index), -1) AS m FROM template_exercises WHERE day_template_id = ?1')
    .bind(dayTemplateId)
    .first<{ m: number }>();
  return (row?.m ?? -1) + 1;
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
  db: D1Database,
  dayTemplateId: string,
  preferId?: string,
): Promise<boolean> {
  const rows = await db
    .prepare(
      'SELECT id, order_index FROM template_exercises WHERE day_template_id = ?1 ORDER BY order_index, created_at, id',
    )
    .bind(dayTemplateId)
    .all<{ id: string; order_index: number }>();
  const list = rows.results;
  const hasDup = new Set(list.map((r) => r.order_index)).size !== list.length;
  if (!hasDup) return false;

  let ordered: { id: string; order_index: number }[];
  const moved = preferId ? list.find((r) => r.id === preferId) : undefined;
  if (moved) {
    // Requested destination = the index the caller just set on this slot.
    // Drop it, then splice it back at that position so siblings shift around
    // it — landing the moved slot exactly there for up- and down-moves alike.
    const others = list.filter((r) => r.id !== moved.id);
    const target = Math.max(0, Math.min(moved.order_index, others.length));
    ordered = [...others.slice(0, target), moved, ...others.slice(target)];
  } else {
    ordered = list;
  }

  const ts = now();
  for (let i = 0; i < ordered.length; i++) {
    if (ordered[i]!.order_index !== i) {
      await db
        .prepare('UPDATE template_exercises SET order_index = ?2, updated_at = ?3 WHERE id = ?1')
        .bind(ordered[i]!.id, i, ts)
        .run();
    }
  }
  return true;
}

/** Sibling of `nextExerciseOrderIndex` for `day_templates` — append a new
 *  day densely instead of the old 99 sentinel that `add_day` used. */
export async function nextDayOrderIndex(
  db: D1Database,
  planId: string,
): Promise<number> {
  const row = await db
    .prepare('SELECT COALESCE(MAX(order_index), -1) AS m FROM day_templates WHERE plan_id = ?1')
    .bind(planId)
    .first<{ m: number }>();
  return (row?.m ?? -1) + 1;
}

export async function addTemplateExercise(
  db: D1Database,
  planId: string,
  input: Omit<TemplateExerciseRow, 'id' | 'created_at' | 'updated_at'>,
): Promise<TemplateExerciseRow> {
  const ts = now();
  const row: TemplateExerciseRow = { ...input, id: uuid(), created_at: ts, updated_at: ts };
  await db
    .prepare(
      `INSERT INTO template_exercises
       (id,day_template_id,exercise_id,order_index,target_sets,target_reps,target_reps_max,target_rpe,rest_seconds,target_weight,target_duration_s,progression,cues,is_warmup,created_at,updated_at)
       VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16)`,
    )
    .bind(
      row.id, row.day_template_id, row.exercise_id, row.order_index, row.target_sets,
      row.target_reps, row.target_reps_max, row.target_rpe, row.rest_seconds,
      row.target_weight, row.target_duration_s, row.progression, row.cues, row.is_warmup ? 1 : 0,
      row.created_at, row.updated_at,
    )
    .run();
  // An explicit order_index can collide with a sibling; densify so the day
  // never holds duplicate indices (non-deterministic display otherwise).
  if (await dedupeDayOrderIndexes(db, row.day_template_id, row.id)) {
    const fresh = await db
      .prepare('SELECT order_index FROM template_exercises WHERE id = ?1')
      .bind(row.id)
      .first<{ order_index: number }>();
    if (fresh) row.order_index = fresh.order_index;
  }
  await bumpPlanVersion(db, planId);
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
  const stmt = db.prepare(sql);
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
  return db
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
  dayTemplateId: string | null,
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
    db
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
        day_template_id: dayTemplateId,
        status: 'planned',
        started_at: null,
        completed_at: null,
        perceived_fatigue: null,
        notes: null,
        updated_at: ts,
        attempt: existing.attempt + 1,
        write_protocol: claimAttemptProtocol
          ? 'attempt-v1'
          : existing.write_protocol,
      };
      const updated = await runWorkoutWriteStatement(
        db,
        db.prepare(
          `UPDATE sessions
              SET day_template_id=?2,
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
          revived.day_template_id,
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
      const winner = await db
        .prepare('SELECT * FROM sessions WHERE id = ?1')
        .bind(existing.id)
        .first<SessionRow>();
      return winner ?? existing;
    }

    // #926: honor an EXPLICITLY-provided day_template_id on a row that
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
    const shouldPin = dayTemplateId != null && existing.day_template_id == null;
    const shouldClaim =
      claimAttemptProtocol && existing.write_protocol !== 'attempt-v1';
    if (shouldPin || shouldClaim) {
      const ts = now();
      // The conditional SET guards a read-then-write race: two explicit POSTs
      // for the same null-template date can both read day_template_id == null,
      // but only the first execution sees NULL and installs its pin. Keep the
      // row eligible after another writer pins it so this request can still
      // perform its independent explicit protocol claim without clobbering the
      // winning day. (Codex P2 on #58.)
      const res = await runWorkoutWriteStatement(
        db,
        db.prepare(
          `UPDATE sessions
              SET day_template_id = CASE
                    WHEN ?5 = 1 AND day_template_id IS NULL THEN ?2
                    ELSE day_template_id
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
          dayTemplateId,
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
      const fresh = await db
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
    day_template_id: dayTemplateId,
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
    db.prepare(
      `INSERT INTO sessions
       (id,user_id,plan_id,day_template_id,date,status,started_at,completed_at,perceived_fatigue,notes,created_at,updated_at,attempt,write_protocol)
       VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14)
       ON CONFLICT(user_id,date) DO NOTHING`,
    )
    .bind(
      s.id,
      s.user_id,
      s.plan_id,
      s.day_template_id,
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
  return db
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
  dayTemplateId: string | null,
  claimAttemptProtocol = false,
): Promise<SessionRow | SessionAttemptConflict | null> {
  const canonicalSessionId = await resolveOwnedSessionId(db, userId, sessionId);
  if (!canonicalSessionId) return null;
  const readCurrent = () =>
    db
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
      db.prepare(
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
    db.prepare(
      `UPDATE sessions
          SET day_template_id = ?2,
              status = 'planned',
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
      dayTemplateId,
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
  const resolved = await db
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
    perceived_fatigue?: number;
    notes?: string;
    day_template_id?: string | null;
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
  | { error: 'invalid_status'; status: unknown }
  | SessionAttemptConflict
  | SessionProtocolConflict
  | SessionStateConflict
> {
  const canonicalSessionId = await resolveOwnedSessionId(db, userId, sessionId);
  if (!canonicalSessionId) return null;
  const s = await db
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
  const fatigue = patch.perceived_fatigue ?? s.perceived_fatigue;
  const notes = patch.notes ?? s.notes;
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
  // Attempt plus a transition-specific current-state predicate form the
  // read/write CAS. Completion is allowed to linearize on either side of a
  // final logSet in the same generation, and SQL COALESCE preserves the
  // concurrently installed started_at. Skip/planned transitions are stricter:
  // once a set promoted the row, they cannot hide or demote the live workout.
  const updated = await runWorkoutWriteStatement(
    db,
    db.prepare(
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
              completed_at = CASE
                WHEN ?2 = 'planned' AND status = 'skipped' THEN NULL
                WHEN ?2 = 'completed' THEN COALESCE(completed_at, ?6)
                ELSE completed_at
              END,
              attempt = CASE
                WHEN ?2 = 'planned' AND status = 'skipped' THEN attempt + 1
                ELSE attempt
              END,
              day_template_id = CASE
                WHEN ?12 = 1 THEN ?13
                ELSE day_template_id
              END,
              write_protocol = CASE
                WHEN ?14 = 1 THEN 'attempt-v1'
                ELSE write_protocol
              END,
              updated_at = ?7
        WHERE id = ?1
          AND attempt = ?9
          AND (?15 = 1 OR write_protocol = 'legacy')
          AND ${statusPredicate}`,
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
      Object.prototype.hasOwnProperty.call(patch, 'day_template_id')
        ? 1
        : 0,
      patch.day_template_id ?? null,
      claimAttemptProtocol ? 1 : 0,
      attemptScoped ? 1 : 0,
    ),
  );
  if (updated.meta.changes === 0) {
    const current = await db
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
    if (current) return sessionStateConflict(s.status, current);
    return null;
  }
  return db
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
  const s = await db
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
      db.prepare(
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
    const authoritative = await db
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
  const [transition, tombstones, terminalState] = await runWorkoutWriteBatch(db, [
    db
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
    db
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
    db
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
    db
      .prepare(
        `SELECT sl.*
           FROM set_logs AS sl
           JOIN sessions AS s ON s.id = sl.session_id
          WHERE sl.id = ?1 AND sl.session_id = ?2 AND s.user_id = ?3`,
      )
      .bind(input.id, canonicalSessionId, userId);
  const selectSession = () =>
    db
      .prepare('SELECT * FROM sessions WHERE id = ?1 AND user_id = ?2')
      .bind(canonicalSessionId, userId);
  // Read the UUID winner and its authoritative session from one D1 snapshot.
  // A retry must never pair an old planned read with a set that won later.
  const [initialSetState, initialSessionState] = await db.batch([
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
    const slot = await db
      .prepare('SELECT is_warmup, exercise_id FROM template_exercises WHERE id = ?1')
      .bind(templateExerciseId)
      .first<{ is_warmup: number; exercise_id: string }>();
    if (!slot || slot.exercise_id !== input.exercise_id) {
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
  const clash = await db
    .prepare(
      `SELECT 1 FROM set_logs
       WHERE session_id = ?1 AND exercise_id = ?2 AND set_index = ?3
         AND is_warmup = ?4 AND deleted_at IS NULL LIMIT 1`,
    )
    .bind(canonicalSessionId, input.exercise_id, setIndex, isWarmupInt)
    .first();
  if (clash) {
    const max = await db
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
    const exRow = await db
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
  const insertAndStart = () => {
    const ts = now();
    return runWorkoutWriteBatch(db, [
      db
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
      db
        .prepare(
          `UPDATE sessions
              SET status = CASE WHEN status = 'planned' THEN 'in_progress' ELSE status END,
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
        ),
      // Capture both the target generation and the canonical current row at
      // the same linearization point. The latter gives a stable conflict body
      // when discard/restart moved the generation during this request.
      db
        .prepare('SELECT * FROM sessions WHERE id = ?1 AND attempt = ?2')
        .bind(canonicalSessionId, casAttempt),
      db
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
      const max = await db
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
  const row = await db
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
): Promise<SetLogRow | null> {
  if (patch.deleted === false) {
    throw new Error('set_undelete_unsupported');
  }
  const row = await db
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
  const ts = now();
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
  if (assignments.length > 0) {
    values.push(ts);
    assignments.push(`updated_at=MAX(updated_at + 1, ?${values.length})`);
    await runWorkoutWriteStatement(
      db,
      db
        .prepare(`UPDATE set_logs SET ${assignments.join(', ')} WHERE id=?1`)
        .bind(...values),
    );
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
  const isDelete = row.deleted_at === null && deletedAt !== null;
  if (isDelete) {
    // Check both facts at the write's linearization point: this deletion must
    // still belong to the generation we read, and no concurrent writer may
    // have installed another live set. If a new set wins first, NOT EXISTS is
    // false; if this demotion wins first, logSet's ordered batch promotes the
    // same attempt back to in_progress. A discard/restart advances `attempt`,
    // so a stale deletion can never demote the newer workout.
    await runWorkoutWriteStatement(
      db,
      db.prepare(
        `UPDATE sessions
            SET status = 'planned', started_at = NULL, updated_at = ?2
          WHERE id = ?1
            AND status = 'in_progress'
            AND attempt = ?3
            AND NOT EXISTS (
              SELECT 1 FROM set_logs
               WHERE session_id = ?1 AND deleted_at IS NULL
            )`,
      )
      .bind(row.session_id, ts, row.session_attempt),
    );
  }
  // Return a fresh row so the caller sees any disjoint concurrent correction
  // or delete that committed alongside this field-only update.
  return db
    .prepare(
      `SELECT sl.* FROM set_logs sl JOIN sessions s ON s.id = sl.session_id
       WHERE sl.id = ?1 AND s.user_id = ?2`,
    )
    .bind(setId, userId)
    .first<SetLogRow>();
}

// ---- read models ---------------------------------------------------------

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
  const sessions = await db
    .prepare('SELECT * FROM sessions WHERE user_id = ?1 AND updated_at > ?2 ORDER BY date')
    .bind(userId, setsSince)
    .all<SessionRow>();
  // Full reload preserves the existing complete shape. Incremental pulls use
  // the server-owned mutable cursor directly from the member-first index and
  // include soft-deleted rows as tombstones.
  const sets = setsSince > 0
    ? await db
        .prepare(
          `SELECT * FROM set_logs
            WHERE user_id = ?1 AND updated_at > ?2
            ORDER BY updated_at, id`,
        )
        .bind(userId, setsSince)
        .all<SetLogRow>()
    : await db
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
      ? await db
          .prepare(
            'SELECT * FROM external_events WHERE user_id = ?1 AND synced_at > ?2 ORDER BY synced_at',
          )
          .bind(userId, eventsSince)
          .all<ExternalEventRow>()
      : await db
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
      ? await db
          .prepare(
            'SELECT * FROM external_activities WHERE user_id = ?1 AND synced_at > ?2 ORDER BY synced_at',
          )
          .bind(userId, activitiesSince)
          .all<ExternalActivityRow>()
      : await db
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
          await db
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
  return db
    .prepare(
      "SELECT * FROM sessions WHERE user_id = ?1 AND status = 'in_progress' ORDER BY updated_at DESC LIMIT 1",
    )
    .bind(userId)
    .first<SessionRow>();
}

export async function getSetsForSession(db: D1Database, sessionId: string) {
  const r = await db
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
): Promise<SessionRow[]> {
  // Exclude 'discarded' — a thrown-away session is not "recent training"
  // and must not surface as last_session in the coach brief / today
  // context. (Visual calendar surfaces vanish it via the projection;
  // set-based reads via deleted_at. This is the one session-list read
  // that needs an explicit filter.)
  const r = await db
    .prepare("SELECT * FROM sessions WHERE user_id = ?1 AND status != 'discarded' ORDER BY date DESC LIMIT ?2")
    .bind(userId, n)
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
): Promise<SessionRow | null> {
  return db
    .prepare(
      "SELECT * FROM sessions WHERE user_id = ?1 AND status = 'completed' AND date != ?2 ORDER BY date DESC LIMIT 1",
    )
    .bind(userId, excludeDate ?? '')
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
  return db
    .prepare("SELECT * FROM sessions WHERE user_id = ?1 AND date = ?2 AND status != 'discarded' ORDER BY created_at LIMIT 1")
    .bind(userId, date)
    .first<SessionRow>();
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
  await db
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
  await db
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
  await db
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
  const row = await db
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
  const r = await db
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
  const rows = await db
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

interface ExerciseInput {
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
    days: {
      day_label?: string | null;
      name: string;
      order_index?: number;
      notes?: string | null;
      exercises?: ExerciseInput[];
    }[];
  },
): Promise<
  | { conflict: true; current_version: number }
  | { conflict: false; plan: PlanTree }
  | { error: 'unknown_exercise'; queries: string[]; query: string }
> {
  let plan = await getActivePlan(db, userId);
  if (!plan) {
    // The no-plan coach path shares the same conflict-safe bootstrap as the
    // app. If both callers observe "no active plan", the partial unique index
    // elects one stable plan id and the coach rebuilds that winner instead of
    // archiving the app's just-created row with createPlan().
    plan = (await ensureActivePlan(db, userId, input.name ?? 'My Plan')).plan;
  }
  if (
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
  const unknown: string[] = [];
  const seenUnknown = new Set<string>();
  for (const d of input.days) {
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
    }
  }
  if (unknown.length > 0) {
    return { error: 'unknown_exercise', queries: unknown, query: unknown[0]! };
  }

  // Capture the OLD day identity (id → name/label) before the rebuild so we
  // can re-point surviving schedule weekdays at the NEW day id whose
  // name/label matches. Without this, every update_plan (e.g. "add a
  // deadlift day") would silently wipe the entire weekly schedule because
  // rebuilt days get fresh UUIDs.
  const oldDays = await db
    .prepare('SELECT id, name, day_label FROM day_templates WHERE plan_id = ?1')
    .bind(plan.id)
    .all<{ id: string; name: string; day_label: string | null }>();
  const oldById = new Map<string, { name: string; day_label: string | null }>();
  for (const od of oldDays.results) {
    oldById.set(od.id, { name: od.name, day_label: od.day_label });
  }

  const ts = now();
  // Generate new day ids up-front so the schedule remap can reference them.
  const newDayIds = input.days.map(() => uuid());
  // Match old→new day identity by day_label first (the stable handle), then
  // by name. First writer wins on a duplicate (schedule holds one id/slot).
  const newIdByLabel = new Map<string, string>();
  const newIdByName = new Map<string, string>();
  input.days.forEach((d, i) => {
    const id = newDayIds[i]!;
    if (d.day_label != null) {
      const lk = d.day_label.toLowerCase();
      if (!newIdByLabel.has(lk)) newIdByLabel.set(lk, id);
    }
    const nk = d.name.toLowerCase();
    if (!newIdByName.has(nk)) newIdByName.set(nk, id);
  });

  // FK-safe rebuild: sessions.day_template_id and set_logs.template_exercise_id
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
  const oldTeRows = await db
    .prepare(
      `SELECT te.id, te.day_template_id, te.exercise_id, te.is_warmup
         FROM template_exercises te
         JOIN day_templates d ON d.id = te.day_template_id
        WHERE d.plan_id = ?1
        ORDER BY te.day_template_id, te.order_index, te.created_at, te.id`,
    )
    .bind(plan.id)
    .all<{ id: string; day_template_id: string; exercise_id: string; is_warmup: number }>();

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
      const newDayId = oldToNewDay.get(ot.day_template_id) ?? null;
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
  const teIdPerExerciseOccurrence: string[][] = input.days.map((d) =>
    (d.exercises ?? []).map(() => uuid()),
  );
  const isWarmupPerOccurrence: number[][] = input.days.map((d) =>
    (d.exercises ?? []).map(() => 0),
  );
  const newTeIdByClassOcc = new Map<string, string>();
  {
    const posOcc = new Map<string, number>(); // positional (exId) — inheritance lookup
    const classOcc = new Map<string, number>(); // (exId, is_warmup) — remap pairing
    input.days.forEach((d, di) => {
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
      const newDayId = oldToNewDay.get(ot.day_template_id) ?? null;
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

  // FK-safe order: INSERT new rows FIRST (so the remap can point at real
  // parents), then UPDATE refs old→new (or NULL for removed), then DELETE
  // the now-orphaned old rows by EXPLICIT id (not by plan_id sweep —
  // that'd catch the freshly-inserted new rows too). The original DELETE-
  // before-INSERT order failed FK the moment any real session or set_log
  // referenced a row being deleted.
  const stmts: D1PreparedStatement[] = [];
  // 1) INSERT new day_templates (parents) — coexist with old by id.
  input.days.forEach((d, di) => {
    const dayId = newDayIds[di]!;
    stmts.push(
      db
        .prepare(
          `INSERT INTO day_templates
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
          plan!.version,
        ),
    );
  });
  // 2) INSERT new template_exercises (children of step 1's parents). is_warmup
  // was resolved above (explicit wins; else inherit the matched old slot's flag)
  // into isWarmupPerOccurrence so the inserted flag and the remap's class keys
  // are guaranteed identical.
  input.days.forEach((d, di) => {
    const dayId = newDayIds[di]!;
    (d.exercises ?? []).forEach((e, ei) => {
      const exId = resolved.get(e.exercise)!;
      const isWarmup = isWarmupPerOccurrence[di]![ei]!;
      stmts.push(
        db
          .prepare(
            `INSERT INTO template_exercises
             (id,day_template_id,exercise_id,order_index,target_sets,target_reps,target_reps_max,target_rpe,rest_seconds,target_weight,target_duration_s,progression,cues,is_warmup,created_at,updated_at)
             SELECT ?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16
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
            e.cues ?? null, isWarmup, ts, ts, plan!.id, userId, plan!.version,
          ),
      );
    });
  });
  // 3) Remap session.day_template_id: old → new (surviving) or NULL.
  for (const [oldDayId, newDayId] of oldToNewDay.entries()) {
    if (newDayId != null) {
      stmts.push(
        db
          .prepare(
            `UPDATE sessions SET day_template_id = ?2, updated_at = ?6
              WHERE day_template_id = ?1
                AND EXISTS (
                  SELECT 1 FROM plans
                   WHERE id = ?3 AND user_id = ?4 AND status = 'active' AND version = ?5
                )`,
          )
          .bind(oldDayId, newDayId, plan.id, userId, plan.version, ts),
      );
    } else {
      stmts.push(
        db
          .prepare(
            `UPDATE sessions SET day_template_id = NULL, updated_at = ?5
              WHERE day_template_id = ?1
                AND EXISTS (
                  SELECT 1 FROM plans
                   WHERE id = ?2 AND user_id = ?3 AND status = 'active' AND version = ?4
                )`,
          )
          .bind(oldDayId, plan.id, userId, plan.version, ts),
      );
    }
  }
  // 4) Remap set_logs.template_exercise_id (same scheme).
  for (const [oldTeId, newTeId] of oldToNewTe.entries()) {
    if (newTeId != null) {
      stmts.push(
        db
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
          .bind(oldTeId, newTeId, plan.id, userId, plan.version, ts),
      );
    } else {
      stmts.push(
        db
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
          .bind(oldTeId, plan.id, userId, plan.version, ts),
      );
    }
  }
  // 5) DELETE old template_exercises by EXPLICIT id (avoid catching the
  //    freshly-inserted new rows that now share plan_id). Children first.
  for (const ot of oldTeRows.results) {
    stmts.push(
      db
        .prepare(
          `DELETE FROM template_exercises
            WHERE id = ?1
              AND EXISTS (
                SELECT 1 FROM plans
                 WHERE id = ?2 AND user_id = ?3 AND status = 'active' AND version = ?4
              )`,
        )
        .bind(ot.id, plan.id, userId, plan.version),
    );
  }
  // 6) DELETE old day_templates by EXPLICIT id. Parents last.
  for (const od of oldDays.results) {
    stmts.push(
      db
        .prepare(
          `DELETE FROM day_templates
            WHERE id = ?1
              AND EXISTS (
                SELECT 1 FROM plans
                 WHERE id = ?2 AND user_id = ?3 AND status = 'active' AND version = ?4
              )`,
        )
        .bind(od.id, plan.id, userId, plan.version),
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
    db
      .prepare(
        `UPDATE plans
            SET name = ?2, meta = ?3, version = version + 1, updated_at = ?4
          WHERE id = ?1 AND user_id = ?5 AND status = 'active' AND version = ?6`,
      )
      .bind(
        plan.id,
        input.name ?? plan.name,
        serializePlanMeta(baseMeta, remappedSchedule),
        ts,
        userId,
        plan.version,
      ),
  );
  // D1 executes a batch atomically and sequentially. Every statement above
  // carries the SAME active-plan/version predicate, so after one contender
  // bumps the version a stale contender's entire batch becomes a no-op: no
  // transient inserts, remaps, or deletes can leak through before the final
  // compare-and-swap. This applies even when the caller omitted
  // expected_version; the version we actually read is always the CAS token.
  const results = await runWorkoutWriteBatch(db, stmts);
  const finalUpdate = results[results.length - 1];
  if (!finalUpdate || finalUpdate.meta.changes === 0) {
    const current = await getActivePlan(db, userId);
    return { conflict: true, current_version: current?.version ?? plan.version };
  }
  return { conflict: false, plan: (await getPlanTree(db, userId))! };
}

/** Find a template_exercise slot by id, or by (day + exercise name/id).
 *  When `day_template_id` is supplied alongside `template_exercise_id`, the
 *  slot must live in THAT day: the nested REST route /days/:id/exercises/:teId
 *  claims a day in its path, so a /days/<dayA>/exercises/<slot-from-dayB>
 *  request must resolve to null (→ 404) rather than mutating day B's slot by
 *  the globally-unique teId alone. Day-less callers (the MCP tools, which have
 *  no URL day) omit it and resolve by teId + user as before. */
async function findSlot(
  db: D1Database,
  userId: string,
  ref: { template_exercise_id?: string; day_template_id?: string; day?: string; exercise?: string },
): Promise<TemplateExerciseRow | null> {
  if (ref.template_exercise_id) {
    return db
      .prepare(
        `SELECT te.* FROM template_exercises te
         JOIN day_templates d ON d.id = te.day_template_id
         JOIN plans p ON p.id = d.plan_id
         WHERE te.id = ?1 AND p.user_id = ?2
           AND (?3 IS NULL OR te.day_template_id = ?3)`,
      )
      .bind(ref.template_exercise_id, userId, ref.day_template_id ?? null)
      .first<TemplateExerciseRow>();
  }
  if (!ref.day || !ref.exercise) return null;
  const exId = await resolveOrThrow(db, ref.exercise);
  return db
    .prepare(
      `SELECT te.* FROM template_exercises te
       JOIN day_templates d ON d.id = te.day_template_id
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
  ref: { template_exercise_id?: string; day_template_id?: string; day?: string; exercise?: string },
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
): Promise<TemplateExerciseRow | { error: 'unknown_fields'; fields: string[] } | null> {
  // Slot lookup first so a wrong ref returns the more actionable
  // `slot_not_found` (via null) before unknown_fields. A double-mistake
  // call gets the higher-priority diagnostic.
  const slot = await findSlot(db, userId, ref);
  if (!slot) return null;
  const unknown = Object.keys(patch).filter((k) => !TEMPLATE_EXERCISE_PATCH_KEYS.has(k));
  if (unknown.length > 0) return { error: 'unknown_fields', fields: unknown };
  const m: TemplateExerciseRow = {
    ...slot,
    target_sets: patch.target_sets ?? slot.target_sets,
    target_reps: patch.target_reps ?? slot.target_reps,
    target_reps_max:
      patch.target_reps_max === undefined ? slot.target_reps_max : patch.target_reps_max,
    target_rpe: patch.target_rpe === undefined ? slot.target_rpe : patch.target_rpe,
    rest_seconds: patch.rest_seconds ?? slot.rest_seconds,
    target_weight:
      patch.target_weight === undefined ? slot.target_weight : patch.target_weight,
    target_duration_s:
      patch.target_duration_s === undefined ? slot.target_duration_s : patch.target_duration_s,
    cues: patch.cues === undefined ? slot.cues : patch.cues,
    order_index: patch.order_index === undefined ? slot.order_index : patch.order_index,
    is_warmup:
      patch.is_warmup === undefined ? slot.is_warmup : patch.is_warmup ? 1 : 0,
    progression:
      patch.progression === undefined
        ? slot.progression
        : patch.progression == null
          ? null
          : JSON.stringify(patch.progression),
    updated_at: now(),
  };
  await db
    .prepare(
      `UPDATE template_exercises SET target_sets=?2,target_reps=?3,target_reps_max=?4,
       target_rpe=?5,rest_seconds=?6,target_weight=?7,target_duration_s=?8,cues=?9,progression=?10,order_index=?11,is_warmup=?12,updated_at=?13
       WHERE id=?1`,
    )
    .bind(
      slot.id, m.target_sets, m.target_reps, m.target_reps_max, m.target_rpe,
      m.rest_seconds, m.target_weight, m.target_duration_s, m.cues, m.progression, m.order_index, m.is_warmup, m.updated_at,
    )
    .run();
  // Patching order_index can collide with a sibling; densify the day so the
  // result has unique 0..n-1 indices honoring the requested position.
  if (patch.order_index !== undefined && (await dedupeDayOrderIndexes(db, slot.day_template_id, slot.id))) {
    const fresh = await db
      .prepare('SELECT order_index FROM template_exercises WHERE id = ?1')
      .bind(slot.id)
      .first<{ order_index: number }>();
    if (fresh) m.order_index = fresh.order_index;
  }
  await bumpPlanVersionByDay(db, slot.day_template_id);
  return m;
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
  ref: { template_exercise_id?: string; day_template_id?: string; day?: string; exercise?: string },
): Promise<TemplateExerciseRow | null> {
  const slot = await findSlot(db, userId, ref);
  if (!slot) return null;
  const ts = now();
  await runWorkoutWriteBatch(
    db,
    [
      db
        .prepare(
          `UPDATE set_logs
              SET template_exercise_id = NULL,
                  updated_at = MAX(updated_at + 1, ?2)
            WHERE template_exercise_id = ?1`,
        )
        .bind(slot.id, ts),
      db.prepare('DELETE FROM template_exercises WHERE id = ?1').bind(slot.id),
    ],
  );
  await bumpPlanVersionByDay(db, slot.day_template_id);
  return slot;
}

export async function swapExercise(
  db: D1Database,
  userId: string,
  ref: { day: string; from_exercise: string; to_exercise: string; carry_targets?: boolean },
): Promise<TemplateExerciseRow | null> {
  const slot = await findSlot(db, userId, { day: ref.day, exercise: ref.from_exercise });
  if (!slot) return null;
  const toId = await resolveOrThrow(db, ref.to_exercise);
  await db
    .prepare('UPDATE template_exercises SET exercise_id=?2, updated_at=?3 WHERE id=?1')
    .bind(slot.id, toId, now())
    .run();
  await bumpPlanVersionByDay(db, slot.day_template_id);
  return { ...slot, exercise_id: toId, updated_at: now() };
}

async function bumpPlanVersionByDay(db: D1Database, dayTemplateId: string): Promise<void> {
  const row = await db
    .prepare('SELECT plan_id FROM day_templates WHERE id = ?1')
    .bind(dayTemplateId)
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
): Promise<{ plan: PlanTree | null; changes: string[] }> {
  const tree = await getPlanTree(db, userId);
  if (!tree) return { plan: null, changes: [] };
  const setF = { light: 0.8, moderate: 0.65, heavy: 0.5 }[magnitude];
  const wtF = { light: 0.95, moderate: 0.9, heavy: 0.85 }[magnitude];
  const days = dayLabel
    ? tree.days.filter((d) => d.day_label === dayLabel || d.name === dayLabel)
    : tree.days;
  const changes: string[] = [];
  const stmts: D1PreparedStatement[] = [];
  const ts = now();
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
        const w = assisted ? Math.min(te.target_weight, rounded) : rounded;
        stmts.push(
          db
            .prepare('UPDATE template_exercises SET target_weight=?2, updated_at=?3 WHERE id=?1')
            .bind(te.id, w, ts),
        );
        changes.push(`${d.day_label ?? d.name}/${te.exercise_id}: weight ${te.target_weight}→${w}`);
      } else {
        const s = Math.max(1, Math.round(te.target_sets * setF));
        stmts.push(
          db
            .prepare('UPDATE template_exercises SET target_sets=?2, updated_at=?3 WHERE id=?1')
            .bind(te.id, s, ts),
        );
        changes.push(`${d.day_label ?? d.name}/${te.exercise_id}: sets ${te.target_sets}→${s}`);
      }
    }
  }
  if (stmts.length) {
    stmts.push(
      db
        .prepare('UPDATE plans SET version = version + 1, updated_at = ?2 WHERE id = ?1')
        .bind(tree.id, ts),
    );
    await db.batch(stmts);
  }
  return { plan: await getPlanTree(db, userId), changes };
}

const epley = (w: number, r: number) => Math.round(w * (1 + r / 30) * 10) / 10;

type ExerciseMetricSemantics = {
  modality: string;
  laterality: string;
  load_mode: string;
};

type HistorySessionSummary = {
  date: string;
  top: SetLogRow;
  metric: 'load' | 'reps' | 'duration';
  est_1rm: number | null;
  best_reps: number | null;
  total_reps: number | null;
  best_duration_s: number | null;
  tonnage: number | null;
};

function positiveSetTonnage(
  set: Pick<SetLogRow, 'weight' | 'reps' | 'is_timed'>,
  exercise: Pick<ExerciseMetricSemantics, 'laterality' | 'load_mode'>,
): number | null {
  if (set.is_timed === 1 || set.weight <= 0) return null;
  const sides = exercise.laterality === 'unilateral' ? 2 : 1;
  const implementsUsed = exercise.load_mode === 'per_hand' ? 2 : 1;
  return set.weight * set.reps * sides * implementsUsed;
}

function timedDurationSeconds(
  set: Pick<SetLogRow, 'duration_s' | 'reps'>,
): number {
  // Older MCP clients logged elapsed seconds in reps before duration_s was
  // added. Keep those valid timed sets visible in history and feeds.
  return set.duration_s ?? set.reps;
}

function chooseHistoryTop(
  rows: SetLogRow[],
  modality: string,
): { top: SetLogRow; metric: HistorySessionSummary['metric'] } {
  const timed = rows.filter((row) => row.is_timed === 1);
  const repBased = rows.filter((row) => row.is_timed !== 1);

  if (modality === 'bw' && repBased.length > 0) {
    const top = repBased.reduce((best, row) =>
      row.reps > best.reps || (row.reps === best.reps && row.weight > best.weight)
        ? row
        : best,
    );
    return { top, metric: 'reps' };
  }
  if (timed.length > 0 && repBased.length === 0) {
    const top = timed.reduce((best, row) =>
      timedDurationSeconds(row) > timedDurationSeconds(best) ? row : best,
    );
    return { top, metric: 'duration' };
  }
  const candidates = repBased.length > 0 ? repBased : rows;
  const top = candidates.reduce((best, row) =>
    epley(row.weight, row.reps) > epley(best.weight, best.reps) ? row : best,
  );
  return { top, metric: 'load' };
}

export async function getHistory(
  db: D1Database,
  userId: string,
  exerciseId: string,
  from: number,
  to: number,
) {
  const exercise =
    (await db
      .prepare('SELECT modality, laterality, load_mode FROM exercises WHERE id = ?1')
      .bind(exerciseId)
      .first<ExerciseMetricSemantics>()) ?? {
      modality: 'unknown',
      laterality: 'bilateral',
      load_mode: 'total',
    };
  const sets = await db
    .prepare(
      `SELECT sl.*, s.date as session_date FROM set_logs sl
       JOIN sessions s ON s.id = sl.session_id
       WHERE sl.user_id = ?1 AND s.user_id = ?1
         AND sl.exercise_id = ?2 AND sl.deleted_at IS NULL
         AND sl.is_warmup = 0 AND sl.logged_at BETWEEN ?3 AND ?4
       ORDER BY sl.logged_at`,
    )
    .bind(userId, exerciseId, from, to)
    .all<SetLogRow & { session_date: string }>();
  const rowsBySession = new Map<string, SetLogRow[]>();
  for (const s of sets.results) {
    const rows = rowsBySession.get(s.session_date) ?? [];
    rows.push(s);
    rowsBySession.set(s.session_date, rows);
  }

  const bySession: HistorySessionSummary[] = [...rowsBySession].map(([date, rows]) => {
    const { top, metric } = chooseHistoryTop(rows, exercise.modality);
    const timedRows = rows.filter((row) => row.is_timed === 1);
    const repRows = rows.filter((row) => row.is_timed !== 1);
    const tonnages = repRows
      .map((row) => positiveSetTonnage(row, exercise))
      .filter((value): value is number => value != null);
    const est1rm = top.is_timed !== 1 && top.weight > 0
      ? epley(top.weight, top.reps)
      : null;
    return {
      date,
      top: metric === 'duration'
        ? { ...top, duration_s: timedDurationSeconds(top) }
        : top,
      metric,
      est_1rm: est1rm,
      best_reps:
        exercise.modality === 'bw' && repRows.length > 0
          ? Math.max(...repRows.map((row) => row.reps))
          : null,
      total_reps:
        exercise.modality === 'bw'
          ? repRows.reduce(
              (total, row) =>
                total + row.reps * (exercise.laterality === 'unilateral' ? 2 : 1),
              0,
            )
          : null,
      best_duration_s:
        timedRows.length > 0
          ? Math.max(...timedRows.map(timedDurationSeconds))
          : null,
      tonnage: tonnages.length > 0 ? tonnages.reduce((total, value) => total + value, 0) : null,
    };
  });
  return {
    exercise_id: exerciseId,
    sets: sets.results,
    by_session: bySession.sort((a, b) => a.date.localeCompare(b.date)),
  };
}

export async function getVolume(
  db: D1Database,
  userId: string,
  muscle: string,
  from: number,
  to: number,
): Promise<
  | {
      muscle_group: string;
      buckets: { week: string; hard_sets: number; tonnage: number | null }[];
    }
  | { error: 'unknown_muscle'; query: string }
> {
  const normalizedMuscle = muscle.trim().toLowerCase();
  const known = await db
    .prepare('SELECT 1 FROM exercises WHERE lower(primary_muscle) = ?1 LIMIT 1')
    .bind(normalizedMuscle)
    .first();
  if (!known) return { error: 'unknown_muscle', query: muscle };

  // `weight` is one implement when load_mode=per_hand and `reps` is one
  // side when laterality=unilateral. These dimensions are independent: a
  // 45x8 two-dumbbell Bulgarian split squat is 45*8*2 legs*2 dumbbells =
  // 1,440 lb of work. Zero-load bodyweight and assisted (negative-load)
  // sets remain hard sets but have undefined tonnage; timed holds likewise
  // use duration rather than pretending seconds are repetitions.
  const rows = await db
    .prepare(
      `SELECT strftime('%Y-%W', s.date) AS week,
              COUNT(*) AS hard_sets,
              SUM(CASE WHEN sl.weight > 0 AND sl.is_timed = 0
                       THEN sl.weight * sl.reps
                         * CASE WHEN e.laterality = 'unilateral' THEN 2 ELSE 1 END
                         * CASE WHEN e.load_mode = 'per_hand' THEN 2 ELSE 1 END
                       ELSE NULL END) AS tonnage
       FROM set_logs sl
       JOIN sessions s ON s.id = sl.session_id
       JOIN exercises e ON e.id = sl.exercise_id
       WHERE s.user_id = ?1 AND lower(e.primary_muscle) = ?2 AND sl.deleted_at IS NULL
         AND sl.is_warmup = 0 AND sl.logged_at BETWEEN ?3 AND ?4
       GROUP BY week ORDER BY week`,
    )
    .bind(userId, normalizedMuscle, from, to)
    .all<{ week: string; hard_sets: number; tonnage: number | null }>();
  return { muscle_group: normalizedMuscle, buckets: rows.results };
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
 * name) to a day_template_id belonging to the active plan; rejects any ref
 * that doesn't resolve to a day in THIS plan (no partial write). Optimistic
 * concurrency on expected_version. Bumps plans.version on success.
 */
export async function setPlanSchedule(
  db: D1Database,
  userId: string,
  weekInput: Partial<Record<Weekday, string | null>>,
  expectedVersion?: number | null,
  expectedPlanId?: string | null,
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
  const days = await db
    .prepare('SELECT id, name, day_label FROM day_templates WHERE plan_id = ?1')
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
  const row = await db
    .prepare(
      `UPDATE plans SET meta = ?2, version = version + 1, updated_at = ?3
        WHERE id = ?1 AND version = ?4 AND user_id = ?5 AND status = 'active'
        RETURNING version`,
    )
    .bind(plan.id, serializePlanMeta(meta, schedule), ts, plan.version, userId)
    .first<{ version: number }>();
  if (!row) {
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
  const row = await db
    .prepare(
      'UPDATE plans SET meta = ?2, version = version + 1, updated_at = ?3 WHERE id = ?1 AND version = ?4 RETURNING version',
    )
    .bind(plan.id, serializePlanMeta(meta, meta.schedule), ts, plan.version)
    .first<{ version: number }>();
  if (!row) {
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
) {
  if (!YMD.test(race.date)) return { error: 'invalid_date' as const };
  const res = await writePlanMeta(db, userId, expectedVersion, (meta) => {
    meta.race = race;
  });
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
  });
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
  });
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
  });
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
) {
  const res = await writePlanMeta(db, userId, expectedVersion, (meta) => {
    const trips = meta.trips ?? [];
    if (!trips.some((t) => t.id === tripId)) return 'trip_not_found';
    meta.trips = trips.filter((t) => t.id !== tripId);
  });
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
) {
  const res = await writePlanMeta(db, userId, expectedVersion, (meta) => {
    meta.stress_model = model;
  });
  return 'ok' in res
    ? { ok: true as const, version: res.version, stress_model: res.meta.stress_model ?? null }
    : res;
}

/**
 * Scrub schedule weekday entries whose day_template_id is not in `liveIds`.
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
export async function deleteDayTemplate(
  db: D1Database,
  userId: string,
  dayId: string,
  expectedVersion?: number,
): Promise<
  { ok: true; version: number }
  | { error: 'day_not_found' }
  | { error: 'day_in_progress' }
  | PlanVersionConflict
> {
  const plan = await getActivePlan(db, userId);
  if (!plan) return { error: 'day_not_found' };
  if (expectedVersion !== undefined && expectedVersion !== plan.version) {
    return { conflict: true, current_version: plan.version };
  }
  const writeVersion = expectedVersion ?? plan.version;
  const day = await db
    .prepare('SELECT id FROM day_templates WHERE id = ?1 AND plan_id = ?2')
    .bind(dayId, plan.id)
    .first<{ id: string }>();
  if (!day) return { error: 'day_not_found' };
  const meta = parsePlanMeta(plan.meta);
  const remaining = await db
    .prepare(
      'SELECT id FROM day_templates WHERE plan_id = ?1 AND id != ?2 ORDER BY order_index, created_at, id',
    )
    .bind(plan.id, dayId)
    .all<{ id: string }>();
  const liveIds = new Set(remaining.results.map((r) => r.id));
  const scrubbed = scrubSchedule(meta.schedule, liveIds);
  // A session may deliberately keep day_template_id NULL and resolve its
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
    const explicit = `(${alias}.day_template_id = ${dayParameter} AND ${alias}.plan_id = ${planParameter})`;
    if (scheduledWeekdayNumbers.length === 0) return explicit;
    return `(${explicit} OR (${alias}.day_template_id IS NULL AND ${alias}.plan_id = ${planParameter} AND CAST(strftime('%w', ${alias}.date) AS INTEGER) IN (${scheduledWeekdayNumbers.join(',')})))`;
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
        AND active_slot.day_template_id = ${dayParameter}
    )
  )`;
  const ts = now();
  const stmts: D1PreparedStatement[] = [
    // Preserve historical rows; only detach their pointers into the plan
    // document before deleting that document node.
    db
      .prepare(
        `UPDATE sessions
            SET day_template_id = NULL,
                status = CASE WHEN status = 'planned' THEN 'skipped' ELSE status END,
                updated_at = CASE
                  WHEN day_template_id IS NOT NULL OR status = 'planned' THEN ?5
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
      .bind(userId, dayId, plan.id, writeVersion, ts),
    db
      .prepare(
        `UPDATE set_logs
            SET template_exercise_id = NULL,
                updated_at = MAX(updated_at + 1, ?5)
          WHERE template_exercise_id IN (
            SELECT id FROM template_exercises WHERE day_template_id = ?1
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
      .bind(dayId, plan.id, userId, writeVersion, ts),
    db
      .prepare(
        `DELETE FROM template_exercises WHERE day_template_id = ?1
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
      .bind(dayId, plan.id, userId, writeVersion),
    db
      .prepare(
        `DELETE FROM day_templates WHERE id = ?1 AND plan_id = ?2
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
      .bind(dayId, plan.id, userId, writeVersion),
    ...remaining.results.map((row, index) =>
      db
        .prepare(
          `UPDATE day_templates SET order_index = ?2, updated_at = ?3
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
        .bind(row.id, index, ts, plan.id, userId, writeVersion, dayId),
    ),
    db
      .prepare(
        `UPDATE plans SET meta = ?2, version = version + 1, updated_at = ?3
          WHERE id = ?1 AND user_id = ?4 AND status = 'active' AND version = ?5
            AND NOT EXISTS (
              SELECT 1 FROM sessions AS active_session
               WHERE active_session.user_id = ?4
                 AND ${activeSessionReferencesDeletedDay('active_session', '?6', '?1')}
                 AND active_session.status = 'in_progress'
            )
          RETURNING version`,
      )
      .bind(
        plan.id,
        serializePlanMeta(meta, scrubbed ?? meta.schedule),
        ts,
        userId,
        writeVersion,
        dayId,
      ),
  ];
  const results = await runWorkoutWriteBatch<{ version: number }>(db, stmts);
  const updatedPlan = results.at(-1)?.results[0];
  if (!updatedPlan) {
    const active = await db
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
  const d = await db
    .prepare(
      "SELECT id FROM day_templates WHERE plan_id = ?1 AND (id = ?2 OR lower(day_label) = lower(?2) OR lower(name) = lower(?2)) LIMIT 1",
    )
    .bind(plan.id, day)
    .first<{ id: string }>();
  if (!d) return { error: 'unknown_day_ref', ref: day };
  const readExisting = () =>
    db
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
      existing.day_template_id === d.id;
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
      db.prepare(
        `UPDATE sessions
            SET plan_id = ?13,
                day_template_id = ?2,
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
                JOIN day_templates AS active_day
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
      day_template_id: d.id,
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
    day_template_id: d.id,
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
    db.prepare(
      `INSERT INTO sessions
       (id,user_id,plan_id,day_template_id,date,status,started_at,completed_at,perceived_fatigue,notes,created_at,updated_at,attempt,write_protocol)
       SELECT ?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14
        WHERE EXISTS (
          SELECT 1
            FROM plans AS active_plan
            JOIN day_templates AS active_day
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
      s.day_template_id,
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
    db
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
      db.prepare(
        `UPDATE sessions
            SET plan_id = ?6,
                day_template_id = NULL,
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
        day_template_id: null,
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
    day_template_id: null,
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
    db.prepare(
      `INSERT INTO sessions
       (id,user_id,plan_id,day_template_id,date,status,started_at,completed_at,perceived_fatigue,notes,created_at,updated_at,attempt,write_protocol)
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
      s.day_template_id,
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
 * with the strength side (`day_template_id`) — a brick is a lift + a ride on
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
  day_template_id: string | null;
  /** True iff this cell came from a real sessions row. */
  real: boolean;
  /**
   * Endurance items for the day (bricks / doubles). Empty array when there is
   * no endurance. ADDITIVE — existing single-item strength consumers ignore
   * this and keep reading `status`/`day_template_id`/`real` unchanged.
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
 * today-or-future day is a COMPOSITE: a strength side (status/day_template_id)
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
          day_template_id: real.day_template_id,
          real: true,
          items,
        });
      } else if (items.length) {
        // Endurance-only past day: completed actuals with no strength session.
        cells.push({
          date,
          status: 'completed',
          day_template_id: null,
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
          day_template_id: real.day_template_id,
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
        day_template_id: null,
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
    let dayTemplateId: string | null;
    let real_ = false;
    if (real) {
      status = real.status as CalendarCell['status'];
      dayTemplateId = real.day_template_id;
      real_ = true;
    } else {
      const tid = trip ? null : schedule.week[weekdayOf(date)];
      if (tid && resolvable.has(tid)) {
        status = 'projected';
        dayTemplateId = tid;
      } else {
        status = 'rest';
        dayTemplateId = null;
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
      day_template_id: dayTemplateId,
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
  const liveDays = await db
    .prepare('SELECT id FROM day_templates WHERE plan_id = ?1')
    .bind(plan.id)
    .all<{ id: string }>();
  // Endurance feeds for the composite projection. Planned events drive
  // today+ bricks/doubles; completed actuals drive past endurance items.
  // Both are soft-deleted caches — exclude tombstones. The window matches
  // the sessions window (the projection clamps the span itself).
  const plannedEvents = await db
    .prepare(
      `SELECT id, date, kind, title, planned_duration_sec, training_load
         FROM external_events
        WHERE user_id = ?1 AND deleted_at IS NULL
          AND date >= ?2 AND date <= ?3`,
    )
    .bind(userId, fromDate, toDate)
    .all<ProjectionEvent>();
  const completedActivities = await db
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
  const sessions = await db
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
  const days = await db
    .prepare('SELECT id, name FROM day_templates WHERE plan_id = ?1')
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
  | 'fetch_failed'; // non-2xx/timeout/parse: cache left COMPLETELY untouched

export interface SyncResult {
  status: SyncStatus;
  /** Count of non-deleted in-window rows after a successful sync (else 0). */
  synced: number;
  /** Diagnostic only (http status / reason) on a failed fetch. */
  detail?: string;
}

export interface SyncDeps extends FetchDeps {
  /** Override the user id (defaults to the single owner). */
  userId?: string;
  /** Allow injecting the env-resolved owner sub (tests). */
  ownerSub?: string;
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
async function markIntervalsAuthError(db: D1Database, userId: string): Promise<void> {
  const ts = now();
  await db.batch([
    db
      .prepare(
        `UPDATE users
            SET intervals_api_key = NULL,
                intervals_oauth_access_token = NULL,
                intervals_oauth_refresh_token = NULL,
                intervals_oauth_expires_at = NULL,
                intervals_athlete_id = NULL,
                intervals_auth_error_at = ?2
          WHERE id = ?1`,
      )
      .bind(userId, ts),
    db
      .prepare(
        `INSERT INTO audit_log (id,user_id,actor,tool,args,result,created_at)
         VALUES (?1,?2,'system','intervals_auth_error',?3,'disconnected',?4)`,
      )
      .bind(
        uuid(),
        userId,
        JSON.stringify({ disconnected: true, reason: 'auth_rejected' }),
        ts,
      ),
  ]);
}

/**
 * Best-effort OAuth refresh against intervals.icu's token endpoint. Returns a
 * fresh access token on success, else null. DORMANT for current connections:
 * intervals.icu's documented token response carries no refresh_token (tokens
 * "appear long-lived" — intervalsAuth.ts), so a stored refresh_token is
 * typically null and this returns null with NO network call. It activates only
 * if a refresh_token was ever persisted — future-proofing against intervals
 * adding token expiry. The fetcher is injectable so tests stay offline.
 */
async function tryRefreshIntervalsOAuth(
  db: D1Database,
  env: Env,
  userId: string,
  fetcher?: Fetcher,
): Promise<string | null> {
  const clientId = env.INTERVALS_OAUTH_CLIENT_ID;
  const clientSecret = env.INTERVALS_OAUTH_CLIENT_SECRET;
  if (!clientId || !clientSecret) return null;
  const row = await db
    .prepare(
      `SELECT intervals_oauth_refresh_token AS rt, intervals_athlete_id AS aid
         FROM users WHERE id = ?1`,
    )
    .bind(userId)
    .first<{ rt: string | null; aid: string | null }>();
  const refreshToken = row?.rt ?? null;
  const athleteId = row?.aid ?? null;
  if (!refreshToken || !athleteId) return null;

  const f = fetcher ?? (globalThis.fetch as unknown as Fetcher);
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
    return null;
  }
  if (!res.ok) return null;
  let body: { access_token?: unknown; refresh_token?: unknown; expires_in?: unknown };
  try {
    body = (await res.json()) as typeof body;
  } catch {
    return null;
  }
  const accessToken = typeof body.access_token === 'string' ? body.access_token : null;
  if (!accessToken) return null;
  // Keep the old refresh token if the response rotates none; honour expiry if given.
  const newRefresh = typeof body.refresh_token === 'string' ? body.refresh_token : refreshToken;
  const expiresAt =
    typeof body.expires_in === 'number' && Number.isFinite(body.expires_in)
      ? now() + body.expires_in * 1000
      : null;
  await setUserIntervalsOAuth(db, userId, accessToken, newRefresh, expiresAt, athleteId);
  return accessToken;
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
  accessToken: string | null | undefined,
  fetcher: Fetcher | undefined,
  run: (token: string | null | undefined) => Promise<T>,
): Promise<{ result: T; reauthRequired: boolean }> {
  let result = await run(accessToken);
  if (!isIntervalsAuthError(result)) return { result, reauthRequired: false };
  const refreshed = await tryRefreshIntervalsOAuth(db, env, userId, fetcher);
  if (refreshed) {
    result = await run(refreshed);
    if (!isIntervalsAuthError(result)) return { result, reauthRequired: false };
  }
  await markIntervalsAuthError(db, userId);
  return { result, reauthRequired: true };
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

  // Resolve creds for THIS sync. Three call shapes (M1 multi-user):
  //   (a) deps.userId given (refresh_rides MCP tool / tests): sync that one
  //       user, reading creds off their row. If the row has no creds, the
  //       legacy env values are accepted as a fallback so existing
  //       single-user tests keep passing without code changes.
  //   (b) no userId: cron entrypoint. Run the env→DB seed (idempotent), then
  //       iterate ALL users with creds. Aggregate the SyncResult.
  let userId: string;
  let apiKey: string | null | undefined;
  let athleteId: string | null | undefined;
  let accessToken: string | null | undefined;
  if (deps.userId) {
    userId = deps.userId;
    const creds = await getUserIntervalsCreds(db, userId);
    // Env fallback only when the user has NEVER PATCHed their creds. After
    // an explicit disconnect, both columns are NULL but the audit row says
    // "intentionally cleared" — don't silently revive the env credentials.
    const envFallbackOk =
      creds.api_key === null &&
      creds.athlete_id === null &&
      // A dead-credential disconnect (401/403) also blocks the env fallback —
      // otherwise we'd re-fall-back to the same env credential and 401 again.
      creds.auth_error_at === null &&
      !(await userHasTouchedIntervalsCreds(db, userId));
    apiKey = creds.api_key ?? (envFallbackOk ? env.INTERVALS_ICU_API_KEY : null);
    athleteId =
      creds.athlete_id ?? (envFallbackOk ? env.INTERVALS_ICU_ATHLETE_ID : null);
    // OAuth bearer token rides alongside (no env fallback — env is the
    // legacy API-key path only). intervals.ts prefers it over the API key.
    accessToken = creds.access_token;
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
        else if (agg !== 'fetch_failed' && r.status === 'ok') agg = 'ok';
        if (r.detail) details.push(`${c.user_id.slice(0, 8)}:${r.detail}`);
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

  const { result: fetched, reauthRequired } = await fetchIntervalsWithAuthRecovery(
    db,
    env,
    userId,
    accessToken,
    deps.fetcher,
    (token) =>
      fetchPlannedEvents(apiKey, athleteId, { ...deps, today, windowDays, accessToken: token }),
  );
  if (!fetched.ok) {
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
           VALUES (?1,?2,'intervals',?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,NULL)
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
           WHERE external_events.deleted_at IS NOT NULL OR
             external_events.date IS NOT excluded.date OR
             external_events.start_date_local_ms IS NOT excluded.start_date_local_ms OR
             external_events.kind IS NOT excluded.kind OR
             external_events.title IS NOT excluded.title OR
             external_events.description IS NOT excluded.description OR
             external_events.planned_duration_sec IS NOT excluded.planned_duration_sec OR
             external_events.training_load IS NOT excluded.training_load OR
             external_events.intensity IS NOT excluded.intensity`,
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
            AND id NOT IN (SELECT CAST(value AS TEXT) FROM json_each(?4))`,
      )
      .bind(userId, today, ts, JSON.stringify(seenIds), newest),
  );

  await db.batch(stmts);

  const cnt = await db
    .prepare(
      `SELECT COUNT(*) AS c FROM external_events
        WHERE user_id = ?1 AND deleted_at IS NULL
          AND date >= ?2 AND date <= ?3`,
    )
    .bind(userId, today, newest)
    .first<{ c: number }>();
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
  // function for the full rationale on the three call shapes (explicit
  // userId vs cron fan-out vs env-seed fallback).
  let userId: string;
  let apiKey: string | null | undefined;
  let athleteId: string | null | undefined;
  let accessToken: string | null | undefined;
  if (deps.userId) {
    userId = deps.userId;
    const creds = await getUserIntervalsCreds(db, userId);
    // Env fallback only when the user has NEVER PATCHed their creds. After
    // an explicit disconnect, both columns are NULL but the audit row says
    // "intentionally cleared" — don't silently revive the env credentials.
    const envFallbackOk =
      creds.api_key === null &&
      creds.athlete_id === null &&
      // A dead-credential disconnect (401/403) also blocks the env fallback —
      // otherwise we'd re-fall-back to the same env credential and 401 again.
      creds.auth_error_at === null &&
      !(await userHasTouchedIntervalsCreds(db, userId));
    apiKey = creds.api_key ?? (envFallbackOk ? env.INTERVALS_ICU_API_KEY : null);
    athleteId =
      creds.athlete_id ?? (envFallbackOk ? env.INTERVALS_ICU_ATHLETE_ID : null);
    // OAuth bearer token rides alongside (no env fallback — env is the
    // legacy API-key path only). intervals.ts prefers it over the API key.
    accessToken = creds.access_token;
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
        else if (agg !== 'fetch_failed' && r.status === 'ok') agg = 'ok';
        if (r.detail) details.push(`${c.user_id.slice(0, 8)}:${r.detail}`);
      }
      return {
        status: agg,
        synced: total,
        ...(details.length ? { detail: details.join(',') } : {}),
      };
    }
    void owner;
  }

  const { result: fetched, reauthRequired } = await fetchIntervalsWithAuthRecovery(
    db,
    env,
    userId,
    accessToken,
    deps.fetcher,
    (token) =>
      fetchCompletedActivities(apiKey, athleteId, { ...deps, today, pastDays, accessToken: token }),
  );
  if (!fetched.ok) {
    // Same guard as syncExternalEvents: transient/disabled leaves the cache
    // untouched; a 401/403 was just disconnected inside the recovery helper.
    return {
      status: fetched.reason === 'disabled' ? 'disabled' : 'fetch_failed',
      synced: 0,
      detail:
        fetched.reason +
        (fetched.reason === 'http' && 'status' in fetched ? `:${fetched.status}` : '') +
        (reauthRequired ? ':reauth_required' : ''),
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
              calories,elevation_gain_m,raw,synced_at,deleted_at)
           VALUES (?1,?2,'intervals',?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,
                   ?15,?16,?17,?18,?19,?20,NULL)
           ON CONFLICT(id) DO UPDATE SET
             date=excluded.date,
             start_date_local_ms=excluded.start_date_local_ms,
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
           WHERE external_activities.deleted_at IS NOT NULL OR
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
             external_activities.elevation_gain_m IS NOT excluded.elevation_gain_m`,
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
            AND id NOT IN (SELECT CAST(value AS TEXT) FROM json_each(?4))`,
      )
      .bind(userId, oldest, ts, JSON.stringify(seenIds), today),
  );

  await db.batch(stmts);

  // Cross-source dedup (Codex P2): intervals rows just changed, so retire any
  // HealthKit copies that now duplicate one — handles the ordering where the
  // HealthKit push arrived BEFORE the intervals activity synced in.
  // This reconcile can only change intervals rows in [oldest,today]. Expand
  // the dedup scope by one civil day on each side so a same workout crossing
  // midnight still matches within the two-minute tolerance. Historical rows
  // outside this affected window cannot have changed during this sync.
  await dedupeHealthKitAgainstIntervals(db, userId, {
    healthKitFromDate: addDays(oldest, -1),
    healthKitToDate: addDays(today, 1),
    // A boundary HealthKit candidate can have a still-live winner on the
    // adjacent civil day. Look one day beyond the candidate range so that
    // winner is present and the duplicate is not incorrectly restored.
    intervalsFromDate: addDays(oldest, -2),
    intervalsToDate: addDays(today, 2),
  });

  const cnt = await db
    .prepare(
      `SELECT COUNT(*) AS c FROM external_activities
        WHERE user_id = ?1 AND source = 'intervals' AND deleted_at IS NULL
          AND date >= ?2 AND date <= ?3`,
    )
    .bind(userId, oldest, today)
    .first<{ c: number }>();
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
  const id = `healthkit:activity:${userId}:${input.id}`;
  const ts = now();
  await db
    .prepare(
      `INSERT INTO external_activities
         (id,user_id,source,external_id,date,start_date_local_ms,kind,name,
          moving_time_sec,elapsed_time_sec,distance_m,average_watts,
          weighted_avg_watts,average_hr,max_hr,training_load,intensity,
          calories,elevation_gain_m,raw,synced_at,deleted_at,canonical,duplicate_of)
       VALUES (?1,?2,'healthkit',?3,?4,?5,?6,?7,?8,?9,?10,?11,NULL,?12,?13,NULL,NULL,
               ?14,?15,?16,?17,NULL,1,NULL)
       ON CONFLICT(id) DO UPDATE SET
         date=excluded.date,
         start_date_local_ms=excluded.start_date_local_ms,
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
       WHERE external_activities.date IS NOT excluded.date OR
         external_activities.start_date_local_ms IS NOT excluded.start_date_local_ms OR
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
    )
    .run();
  // Cross-source dedup (Codex P2): if this workout also exists from
  // intervals.icu, retire the HealthKit copy so it isn't shown/counted twice.
  // Runs AFTER the upsert so a real HealthKit revision resets prior provenance
  // and is immediately re-deduped. An identical retry does not update/reset the
  // row; this idempotent pass therefore preserves an already-retired duplicate.
  await dedupeHealthKitAgainstIntervals(db, userId);
  const row = await db
    .prepare('SELECT * FROM external_activities WHERE id = ?1 AND user_id = ?2')
    .bind(id, userId)
    .first<ExternalActivityRow>();
  if (!row) throw new Error('healthkit_activity_insert_failed');
  return row;
}

/** Start-time tolerance for treating two activities as the same workout. Two
 *  same-kind sessions starting within 2 minutes of each other are, in practice,
 *  the same physical activity arriving from two sources — never two distinct
 *  workouts. Tunable. */
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
 * ACTIVITY_DEDUP_TOLERANCE_MS. **intervals always wins** (richer data — power,
 * native TSS), so the HealthKit copy is the one retired.
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
 * If several intervals rows are within tolerance, selection is stable by
 * (absolute delta, start_date_local_ms, id), ascending.
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
): Promise<number> {
  const dateClause = window ? ' AND date >= ?2 AND date <= ?3' : '';
  // HealthKit rows we manage: currently live (candidates to retire) OR
  // previously retired BY US as a dup (deleted_at + duplicate_of set →
  // candidates to RESTORE if their winner is gone).
  const hkStatement = db.prepare(
    `SELECT id, kind, start_date_local_ms, deleted_at, duplicate_of
       FROM external_activities
      WHERE user_id = ?1 AND source = 'healthkit'
        AND start_date_local_ms IS NOT NULL
        AND (deleted_at IS NULL OR duplicate_of IS NOT NULL)${dateClause}`,
  );
  const hk = (
    await (window
      ? hkStatement.bind(userId, window.healthKitFromDate, window.healthKitToDate)
      : hkStatement.bind(userId))
      .all<{
        id: string;
        kind: string;
        start_date_local_ms: number;
        deleted_at: number | null;
        duplicate_of: string | null;
      }>()
  ).results;
  if (hk.length === 0) return 0;
  // Live intervals winners (NOT early-returned on empty: with no live winner,
  // any retired dup must be RESTORED).
  const ivStatement = db.prepare(
    `SELECT id, kind, start_date_local_ms FROM external_activities
      WHERE user_id = ?1 AND source = 'intervals' AND deleted_at IS NULL
        AND start_date_local_ms IS NOT NULL${dateClause}`,
  );
  const iv = (
    await (window
      ? ivStatement.bind(userId, window.intervalsFromDate, window.intervalsToDate)
      : ivStatement.bind(userId))
      .all<{ id: string; kind: string; start_date_local_ms: number }>()
  ).results;

  // Index candidates by kind and time once. The old nested scan compared every
  // HealthKit row with every intervals row (O(H*I)); the sorted buckets make
  // each nearest-match lookup O(log I + candidates within the tolerance).
  const intervalsByKind = new Map<
    string,
    Array<{ id: string; start_date_local_ms: number }>
  >();
  for (const candidate of iv) {
    const candidates = intervalsByKind.get(candidate.kind) ?? [];
    candidates.push(candidate);
    intervalsByKind.set(candidate.kind, candidates);
  }
  for (const candidates of intervalsByKind.values()) {
    candidates.sort(
      (a, b) => a.start_date_local_ms - b.start_date_local_ms || (a.id < b.id ? -1 : 1),
    );
  }

  const ts = now();
  const stmts: D1PreparedStatement[] = [];
  for (const h of hk) {
    let best: { id: string; start_date_local_ms: number } | null = null;
    let bestDelta = Infinity;
    const candidates = intervalsByKind.get(h.kind) ?? [];
    const earliest = h.start_date_local_ms - ACTIVITY_DEDUP_TOLERANCE_MS;
    const latest = h.start_date_local_ms + ACTIVITY_DEDUP_TOLERANCE_MS;
    let low = 0;
    let high = candidates.length;
    while (low < high) {
      const middle = Math.floor((low + high) / 2);
      if (candidates[middle]!.start_date_local_ms < earliest) low = middle + 1;
      else high = middle;
    }
    for (let i = low; i < candidates.length; i += 1) {
      const v = candidates[i]!;
      if (v.start_date_local_ms > latest) break;
      const delta = Math.abs(v.start_date_local_ms - h.start_date_local_ms);
      const winsTie =
        delta === bestDelta &&
        best !== null &&
        (v.start_date_local_ms < best.start_date_local_ms ||
          (v.start_date_local_ms === best.start_date_local_ms && v.id < best.id));
      if (delta < bestDelta || winsTie) {
        bestDelta = delta;
        best = v;
      }
    }
    const isRetiredDup = h.deleted_at != null && h.duplicate_of != null;
    if (best && !isRetiredDup) {
      // Live HealthKit row duplicating a live intervals activity → retire it.
      stmts.push(
        db
          .prepare(
            `UPDATE external_activities
                SET deleted_at = CASE
                      WHEN ?2 > synced_at THEN ?2 ELSE synced_at + 1
                    END,
                    synced_at = CASE
                      WHEN ?2 > synced_at THEN ?2 ELSE synced_at + 1
                    END,
                    canonical = 0,
                    duplicate_of = ?3
              WHERE id = ?1`,
          )
          .bind(h.id, ts, best.id),
      );
    } else if (best && h.duplicate_of !== best.id) {
      // The row is already retired, but the deterministic winner changed.
      // Advance the tombstone watermark so downstream clients receive the
      // corrected provenance instead of retaining a stale duplicate_of.
      stmts.push(
        db
          .prepare(
            `UPDATE external_activities
                SET synced_at = CASE
                      WHEN ?2 > synced_at THEN ?2 ELSE synced_at + 1
                    END,
                    duplicate_of = ?3
              WHERE id = ?1`,
          )
          .bind(h.id, ts, best.id),
      );
    } else if (!best && isRetiredDup) {
      // We retired this as a dup but its intervals winner is gone → restore it
      // as the surviving copy so the workout doesn't vanish.
      stmts.push(
        db
          .prepare(
            `UPDATE external_activities
                SET deleted_at = NULL,
                    synced_at = CASE
                      WHEN ?2 > synced_at THEN ?2 ELSE synced_at + 1
                    END,
                    canonical = 1,
                    duplicate_of = NULL
              WHERE id = ?1`,
          )
          .bind(h.id, ts),
      );
    }
    // else: already correct (live with no match, or retired with winner still
    // present) → no-op, so steady-state syncs don't churn synced_at.
  }
  if (stmts.length) await db.batch(stmts);
  return stmts.length;
}

/**
 * CONFLICT RULE — authoritative. iOS mirrors this BYTE-FOR-BYTE.
 *
 * INTERFERENCE-AWARE (MULTISPORT.md §6.1/§7). The old rule flagged EVERY
 * same-day lift+endurance as a 'clash' — which means every intended brick
 * read as a conflict (the M0-spike bug, `db.ts` §5/#5). The fix keys the
 * same-day severity off whether the endurance side is HARD — the same
 * `isHard` proxy the day-before branch already uses — so a key/long endurance
 * session on a lift day is a real clash, while an easy/short one is a benign,
 * intended brick.
 *
 * Inputs: the set of dates that hold a lift (a real lift session OR a
 * projected/scheduled lift day) and the non-deleted external_events.
 * Soft-deleted events are excluded by the caller and ignored here.
 *
 * "Hard" endurance = training_load >= 150 OR planned_duration_sec >= 9000
 * (≈2h30m) — the key/long-session proxy.
 *
 * For each lift date D, in priority order (first match wins; a date emits at
 * most one DayConflict):
 *
 *  (a) SAME-DAY:
 *      there exists a non-deleted external_event whose `date` == D.
 *        - if ANY same-day event is HARD → severity "clash" (real
 *          interference: a heavy/key endurance session on a strength day).
 *        - else (all same-day endurance is easy/short) → severity "brick"
 *          (a benign, intended same-day pairing — NOT a problem; surfaced
 *          informationally so a UI can label the brick).
 *      `conflicts` = the ids of ALL same-day events either way.
 *
 *  (b) DAY-BEFORE-HARD  → severity "heavy-next-day":
 *      D itself has no same-day event, AND there exists a non-deleted
 *      external_event E on the immediately following calendar day
 *      (date == D + 1 civil day) that is HARD.
 *      `conflicts` = the ids of ALL such hard next-day events.
 *      (Sub-threshold next-day events do NOT flag.)
 *
 * NOTE ON "heavy LOWER-BODY": the §7 ideal keys a clash off a heavy/lower-
 * body strength day. `detectConflicts` has no per-day strength load/muscle
 * metadata in its inputs today (lift dates are bare strings), so M4 uses the
 * conservative, available proxy — the endurance side's hardness — exactly as
 * the day-before branch does. Tightening to lower-body-aware clashes needs
 * strength-day metadata plumbed in; left for a later milestone.
 *
 * "Calendar day before/after" uses the YYYY-MM-DD civil date (the same
 * tz-free rule as weekdayOf/addDays) — never a UTC offset. Output is
 * sorted by date ascending and is fully deterministic.
 */
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
      // A same-day pairing is a real 'clash' only when the endurance side is
      // hard (key/long); otherwise it is an intended 'brick'.
      const severity: DayConflict['severity'] = sameDay.some(isHard) ? 'clash' : 'brick';
      out.push({ date: d, conflicts: sameDay.map((e) => e.id), severity });
      continue;
    }
    const next = byDate.get(addDays(d, 1));
    if (next) {
      const hard = next.filter(isHard);
      if (hard.length) {
        out.push({ date: d, conflicts: hard.map((e) => e.id), severity: 'heavy-next-day' });
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
  // completed) OR a projected strength template (day_template_id != null).
  // 'skipped' lifts and pure-endurance cells (day_template_id == null and
  // !real) are excluded, keeping the prior contract intact.
  const liftDates = cal
    .filter(
      (c) =>
        c.date <= toDate &&
        !c.suppresses_schedule_and_endurance &&
        ((c.real && (c.status === 'planned' || c.status === 'in_progress' || c.status === 'completed')) ||
          (c.status === 'projected' && c.day_template_id != null)),
    )
    .map((c) => c.date);
  const events = await db
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
//     duration, plus Epley est_1rm only for positive rep-based loads). HIDE
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
    top_sets: Array<{
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
  const memberRows = await db
    .prepare(
      `SELECT gm.user_id,
              gm.display_name AS per_group_name,
              u.display_name  AS global_name,
              u.email
         FROM group_members gm
         JOIN users u ON u.id = gm.user_id
        WHERE gm.group_id = ?1`,
    )
    .bind(groupId)
    .all<{
      user_id: string;
      per_group_name: string | null;
      global_name: string | null;
      email: string | null;
    }>();
  if (memberRows.results.length === 0) return [];

  const memberMeta = new Map<string, { displayName: string }>();
  const memberIds: string[] = [];
  for (const m of memberRows.results) {
    memberMeta.set(m.user_id, {
      displayName: resolveDisplayName(m.per_group_name, m.global_name, m.email),
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
  const sessionRows = await db
    .prepare(
      `SELECT s.id,
              s.user_id,
              s.date,
              s.status,
              s.completed_at,
              s.created_at,
              s.day_template_id,
              dt.name AS day_name,
              dt.day_label AS day_label,
              s.started_at,
              COALESCE(s.completed_at, s.created_at) AS occurred_at
         FROM sessions s
         LEFT JOIN day_templates dt ON dt.id = s.day_template_id
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
      day_template_id: string | null;
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
    const sets = await db
      .prepare(
        `SELECT sl.session_id,
                sl.exercise_id,
                sl.weight,
                sl.reps,
                sl.duration_s,
                sl.is_timed,
                e.name AS exercise_name,
                e.unit AS exercise_unit,
                e.modality AS exercise_modality
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
      }>();
    // Aggregate per exercise using the metric that represents its work:
    // longest hold for timed sets, most reps for bodyweight work, and Epley
    // for externally loaded rep work. Cross-modality scores are never mixed.
    type FeedSetCandidate = {
      exercise: string;
      unit: string | null;
      modality: string;
      weight: number;
      reps: number;
      duration_s: number | null;
      is_timed: boolean;
    };
    const acc = new Map<string, Map<string, FeedSetCandidate[]>>();
    for (const r of sets.results) {
      setCountBySession.set(r.session_id, (setCountBySession.get(r.session_id) ?? 0) + 1);
      let perSession = acc.get(r.session_id);
      if (!perSession) {
        perSession = new Map();
        acc.set(r.session_id, perSession);
      }
      const candidates = perSession.get(r.exercise_id) ?? [];
      candidates.push({
        exercise: r.exercise_name,
        unit: r.exercise_unit,
        modality: r.exercise_modality,
        weight: r.weight,
        reps: r.reps,
        duration_s: r.duration_s,
        is_timed: r.is_timed === 1,
      });
      perSession.set(r.exercise_id, candidates);
    }
    for (const [sid, perEx] of acc) {
      const list = [...perEx.values()].map((rows) => {
        const repRows = rows.filter((row) => !row.is_timed);
        const timedRows = rows.filter((row) => row.is_timed);
        let top: FeedSetCandidate;
        if (rows[0]!.modality === 'bw' && repRows.length > 0) {
          top = repRows.reduce((best, row) =>
            row.reps > best.reps || (row.reps === best.reps && row.weight > best.weight)
              ? row
              : best,
          );
        } else if (timedRows.length > 0 && repRows.length === 0) {
          top = timedRows.reduce((best, row) =>
            timedDurationSeconds(row) > timedDurationSeconds(best) ? row : best,
          );
        } else {
          const candidates = repRows.length > 0 ? repRows : rows;
          top = candidates.reduce((best, row) => {
            const score = epley(row.weight, row.reps);
            const bestScore = epley(best.weight, best.reps);
            return score > bestScore || (score === bestScore && row.reps > best.reps)
              ? row
              : best;
          });
        }
        return {
          ...top,
          duration_s: top.is_timed ? timedDurationSeconds(top) : top.duration_s,
          // The shipped iOS decoder requires a number here. Preserve that
          // wire contract with zero as the legacy unavailable sentinel; new
          // clients use is_timed/load semantics to hide the estimate.
          est_1rm: !top.is_timed && top.weight > 0
            ? epley(top.weight, top.reps)
            : 0,
        };
      });
      list.sort((a, b) => a.exercise.localeCompare(b.exercise));
      topSetsBySession.set(sid, list);
    }
  }

  const sessionItems: FeedSessionItem[] = sessionRows.results.map((s) => ({
    type: 'session',
    id: s.id,
    user_id: s.user_id,
    user_display_name: memberMeta.get(s.user_id)?.displayName ?? 'Member',
    is_me: s.user_id === callerUserId,
    date: s.date,
    occurred_at: s.occurred_at,
    session: {
      day_name: s.day_name,
      day_label: s.day_label,
      // duration_sec is only meaningful once the session is completed;
      // a still-in-progress session emits null (matches calendar.ts).
      duration_sec:
        s.started_at != null && s.completed_at != null
          ? Math.max(0, Math.round((s.completed_at - s.started_at) / 1000))
          : null,
      set_count: setCountBySession.get(s.id) ?? 0,
      top_sets: topSetsBySession.get(s.id) ?? [],
    },
  }));

  // 2c. Rides (external_activities). Order by `start_date_local_ms`
  //     (migration 0019) — the actual workout start time. `synced_at`
  //     used to be the proxy but it rewrites on every cron tick, which
  //     bubbled every recent ride to the top of the feed after each
  //     sync and broke pagination. COALESCE handles any legacy row that
  //     somehow escaped the migration backfill (defensive — should not
  //     happen on a freshly-migrated DB).
  const rideRows = await db
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
      kind: r.kind,
      name: r.name,
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
  const actRows = await db
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
      kind: a.type,
      title: a.title,
      duration_min: a.duration_minutes,
      notes: a.notes,
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
  const memberRows = await db
    .prepare(
      `SELECT gm.user_id,
              gm.display_name AS per_group_name,
              u.display_name  AS global_name,
              u.email,
              u.timezone
         FROM group_members gm
         JOIN users u ON u.id = gm.user_id
        WHERE gm.group_id = ?1
        ORDER BY gm.joined_at, gm.user_id`,
    )
    .bind(groupId)
    .all<{
      user_id: string;
      per_group_name: string | null;
      global_name: string | null;
      email: string | null;
      timezone: string | null;
    }>();

  if (memberRows.results.length === 0) return [];

  const out: MemberStat[] = [];
  for (const m of memberRows.results) {
    const displayName = resolveDisplayName(m.per_group_name, m.global_name, m.email);
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
    const sessionsRows = await db
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
    const ridesRows = await db
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
    const actRows = await db
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
  // bounded so the per-member GROUP BY stays cheap. callerUserId is
  // accepted for signature symmetry with getGroupStats/getGroupFeed (the
  // series itself is identity-blind; is_me is resolved from /stats).
  void callerUserId;
  const days = Math.max(1, Math.min(Math.floor(windowDays), 372));

  const memberRows = await db
    .prepare(
      `SELECT gm.user_id, u.timezone
         FROM group_members gm
         JOIN users u ON u.id = gm.user_id
        WHERE gm.group_id = ?1
        ORDER BY gm.joined_at, gm.user_id`,
    )
    .bind(groupId)
    .all<{ user_id: string; timezone: string | null }>();
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
    const sessRows = await db
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

    const rideRows = await db
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

    const actRows = await db
      .prepare(
        `SELECT date, type, COUNT(*) AS n FROM activities
          WHERE user_id = ?1
            AND deleted_at IS NULL
            AND date >= ?2 AND date <= ?3
          GROUP BY date, type`,
      )
      .bind(m.user_id, start, today)
      .all<{ date: string; type: string; n: number }>();
    for (const r of actRows.results) ensure(r.date).activities[r.type] = r.n;

    const daysArr = [...byDate.values()].sort((x, y) =>
      x.date < y.date ? -1 : x.date > y.date ? 1 : 0,
    );
    out.push({ user_id: m.user_id, days: daysArr });
  }
  return out;
}
