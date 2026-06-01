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
  pushStrengthActivity,
  type ActivityFetchDeps,
  type FetchDeps,
  type Fetcher,
} from './intervals';

const now = () => Date.now();
const uuid = () => crypto.randomUUID();

// ---- users ---------------------------------------------------------------

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
 * Sign in with Apple owner resolution. Single-user invariant: there is
 * exactly one user row. If this Apple sub is unseen and the only existing
 * user is a bootstrap row (e.g. the MCP-created 'mcp-owner'), *claim* that
 * row — rebinding it to the real Apple identity — so MCP-seeded data and
 * iOS stay on one user_id. Otherwise create the first user.
 */
export async function claimOrCreateOwner(
  db: D1Database,
  appleSub: string,
  email: string | null,
  displayName: string | null,
  ownerSubLocked: boolean,
): Promise<User> {
  const byApple = await db
    .prepare('SELECT * FROM users WHERE apple_sub = ?1')
    .bind(appleSub)
    .first<User>();
  if (byApple) return byApple;

  if (!ownerSubLocked) {
    const all = await db.prepare('SELECT * FROM users').all<User>();
    if (all.results.length === 1) {
      const row = all.results[0]!;
      await db
        .prepare('UPDATE users SET apple_sub = ?2, email = ?3, display_name = ?4 WHERE id = ?1')
        .bind(row.id, appleSub, email ?? row.email, displayName ?? row.display_name)
        .run();
      return { ...row, apple_sub: appleSub, email: email ?? row.email, display_name: displayName ?? row.display_name };
    }
  }
  return upsertUser(db, appleSub, email, displayName);
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
): Promise<User> {
  const existing = await findOwnerRow(db, ownerAppleSub);
  if (existing) return existing;
  return upsertUser(db, ownerAppleSub ?? BOOTSTRAP_APPLE_SUB, null, 'Owner');
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
 *  - ownerAppleSub UNSET → fall back to "earliest by created_at." The
 *    fresh-install/claim path (Path 3) ensures the earliest row is
 *    always the rightful owner in this mode (no other path can create
 *    a user before the owner has signed in or been bootstrap-seeded).
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
      .prepare('SELECT * FROM users WHERE apple_sub = ?1')
      .bind(ownerAppleSub)
      .first<User>();
  }
  return await db
    .prepare('SELECT * FROM users ORDER BY created_at LIMIT 1')
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
  const rows = await db
    .prepare('SELECT apple_sub FROM users')
    .all<{ apple_sub: string }>();
  if (rows.results.length === 0) return true;
  if (rows.results.length === 1) {
    return rows.results[0]!.apple_sub === BOOTSTRAP_APPLE_SUB;
  }
  return false;
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
}

export async function getMeProfile(
  db: D1Database,
  userId: string,
  ownerAppleSub: string | undefined,
): Promise<MeProfile> {
  const u = await db
    .prepare(
      'SELECT display_name, email, intervals_athlete_id, intervals_auth_error_at FROM users WHERE id = ?1',
    )
    .bind(userId)
    .first<{
      display_name: string | null;
      email: string | null;
      intervals_athlete_id: string | null;
      intervals_auth_error_at: number | null;
    }>();

  // Only the owner's account is coached by Claude (the connector resolves
  // there), so Claude status is reported for the owner alone.
  const owner = await findOwnerRow(db, ownerAppleSub);
  const isOwner = !!owner && owner.id === userId;

  let claudeConnected = false;
  let lastActive: number | null = null;
  if (isOwner) {
    // A refresh_token is the durable grant claude.ai keeps — its presence
    // means the connector is linked even after access tokens expire.
    const grant = await db
      .prepare('SELECT 1 AS x FROM oauth_tokens WHERE refresh_token IS NOT NULL LIMIT 1')
      .first<{ x: number }>();
    claudeConnected = !!grant;
    const lastMcp = await db
      .prepare(
        "SELECT MAX(created_at) AS t FROM audit_log WHERE user_id = ?1 AND actor = 'mcp'",
      )
      .bind(userId)
      .first<{ t: number | null }>();
    lastActive = lastMcp?.t ?? null;
  }

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
  };
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
    { group_id: groupId, code, expires_at: expires },
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
 * Redeem an invite as `userId`. Validates → marks the code used → inserts
 * the group_members row. The check-then-write race window is tolerable in
 * the friends-and-family setting (two redemptions of the same code within
 * a few ms is essentially a non-event), but we still guard against it: the
 * `used_at IS NULL` predicate on the UPDATE means at most one redeemer
 * wins. If a redeemer loses the race they see `used`.
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
  // Conditional UPDATE: only mark used if still unused. Returns
  // info().changes = 1 on the winning redeemer, 0 if someone else just
  // beat us to it (race-loss → report as `used`).
  const res = await db
    .prepare(
      `UPDATE group_invites
          SET used_at = ?2, used_by = ?3
        WHERE code = ?1 AND used_at IS NULL`,
    )
    .bind(code, ts, userId)
    .run();
  if ((res.meta?.changes ?? 0) !== 1) {
    return { error: 'used' };
  }
  await db
    .prepare(
      'INSERT INTO group_members (group_id,user_id,display_name,joined_at) VALUES (?1,?2,?3,?4)',
    )
    .bind(invite.group_id, userId, null, ts)
    .run();
  await writeAudit(
    db,
    userId,
    'redeem_invite',
    { group_id: invite.group_id, code },
    'joined',
    'ios',
  );
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
  const plan: PlanRow = {
    id: uuid(),
    user_id: userId,
    name,
    status: 'active',
    version: 1,
    meta: meta == null ? null : JSON.stringify(meta),
    created_at: ts,
    updated_at: ts,
  };
  // Archive any currently-active plan to honor the one-active-plan invariant.
  await db
    .prepare("UPDATE plans SET status = 'archived', updated_at = ?2 WHERE user_id = ?1 AND status = 'active'")
    .bind(userId, ts)
    .run();
  await db
    .prepare(
      'INSERT INTO plans (id,user_id,name,status,version,meta,created_at,updated_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8)',
    )
    .bind(plan.id, plan.user_id, plan.name, plan.status, plan.version, plan.meta, plan.created_at, plan.updated_at)
    .run();
  return plan;
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
  await bumpPlanVersion(db, planId);
  return row;
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
  await bumpPlanVersion(db, planId);
  return { ...existing, ...merged, updated_at: now() };
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
       (id,day_template_id,exercise_id,order_index,target_sets,target_reps,target_reps_max,target_rpe,rest_seconds,target_weight,target_duration_s,progression,cues,created_at,updated_at)
       VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15)`,
    )
    .bind(
      row.id, row.day_template_id, row.exercise_id, row.order_index, row.target_sets,
      row.target_reps, row.target_reps_max, row.target_rpe, row.rest_seconds,
      row.target_weight, row.target_duration_s, row.progression, row.cues, row.created_at, row.updated_at,
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
): Promise<SessionRow> {
  const existing = await db
    .prepare('SELECT * FROM sessions WHERE user_id = ?1 AND date = ?2 ORDER BY created_at LIMIT 1')
    .bind(userId, date)
    .first<SessionRow>();
  if (existing && existing.status !== 'discarded') {
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
    if (dayTemplateId != null && existing.day_template_id == null) {
      const ts = now();
      // Conditional UPDATE guards a read-then-write race: two explicit POSTs
      // for the same null-template date can both read day_template_id == null,
      // so an unconditional write would let the second clobber the first pin.
      // `WHERE … AND day_template_id IS NULL` means only the FIRST writer's
      // update affects a row; a racing second writer matches 0 rows and falls
      // through to re-read the winning pin. (Codex P2 on #58.)
      const res = await db
        .prepare(
          'UPDATE sessions SET day_template_id = ?2, updated_at = ?3 WHERE id = ?1 AND day_template_id IS NULL',
        )
        .bind(existing.id, dayTemplateId, ts)
        .run();
      if (res.meta.changes > 0) {
        return { ...existing, day_template_id: dayTemplateId, updated_at: ts };
      }
      // Lost the race — another writer pinned it first. Return the winner.
      const fresh = await db
        .prepare('SELECT * FROM sessions WHERE id = ?1')
        .bind(existing.id)
        .first<SessionRow>();
      return fresh ?? existing;
    }
    return existing;
  }
  if (existing) {
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
    };
    await db
      .prepare(
        'UPDATE sessions SET day_template_id=?2, status=?3, started_at=?4, completed_at=?5, perceived_fatigue=?6, notes=?7, updated_at=?8 WHERE id=?1',
      )
      .bind(revived.id, revived.day_template_id, revived.status, null, null, null, null, ts)
      .run();
    return revived;
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
  };
  await db
    .prepare(
      'INSERT INTO sessions (id,user_id,plan_id,day_template_id,date,status,started_at,completed_at,perceived_fatigue,notes,created_at,updated_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)',
    )
    .bind(s.id, s.user_id, s.plan_id, s.day_template_id, s.date, s.status, s.started_at, s.completed_at, s.perceived_fatigue, s.notes, s.created_at, s.updated_at)
    .run();
  return s;
}

export async function patchSession(
  db: D1Database,
  userId: string,
  sessionId: string,
  // `status` is `unknown`: the PATCH body is NOT runtime-validated, so a
  // client can send a number/null/bool/object/array here. Typing it
  // honestly forces the type-guard below.
  patch: { status?: unknown; perceived_fatigue?: number; notes?: string },
): Promise<
  | SessionRow
  | null
  | { error: 'session_already_started'; status: 'in_progress' | 'completed' }
  | { error: 'invalid_status'; status: unknown }
> {
  const s = await db
    .prepare('SELECT * FROM sessions WHERE id = ?1 AND user_id = ?2')
    .bind(sessionId, userId)
    .first<SessionRow>();
  if (!s) return null;
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
  const status = normalizedStatus ?? s.status;
  const fatigue = patch.perceived_fatigue ?? s.perceived_fatigue;
  const notes = patch.notes ?? s.notes;
  const completedAt = status === 'completed' ? s.completed_at ?? now() : s.completed_at;
  const startedAt = status === 'in_progress' ? s.started_at ?? now() : s.started_at;
  await db
    .prepare('UPDATE sessions SET status=?2, perceived_fatigue=?3, notes=?4, started_at=?5, completed_at=?6, updated_at=?7 WHERE id=?1')
    .bind(sessionId, status, fatigue, notes, startedAt, completedAt, now())
    .run();
  return { ...s, status, perceived_fatigue: fatigue, notes, started_at: startedAt, completed_at: completedAt };
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
): Promise<SessionRow | null> {
  const s = await db
    .prepare('SELECT * FROM sessions WHERE id = ?1 AND user_id = ?2')
    .bind(sessionId, userId)
    .first<SessionRow>();
  if (!s) return null;
  // Already discarded → true no-op: skip the (no-op) UPDATEs AND the audit
  // write, so a double-tap / retry can't inflate audit_log (which feeds
  // Claude's coaching context).
  if (s.status === 'discarded') return s;
  const ts = now();
  const live = await db
    .prepare('SELECT COUNT(*) AS n FROM set_logs WHERE session_id = ?1 AND deleted_at IS NULL')
    .bind(sessionId)
    .first<{ n: number }>();
  const discardedSets = live?.n ?? 0;
  await db
    .prepare('UPDATE set_logs SET deleted_at = ?2 WHERE session_id = ?1 AND deleted_at IS NULL')
    .bind(sessionId, ts)
    .run();
  await db
    .prepare("UPDATE sessions SET status = 'discarded', updated_at = ?2 WHERE id = ?1")
    .bind(sessionId, ts)
    .run();
  await writeAudit(
    db,
    userId,
    'discard_session',
    { session_id: sessionId, date: s.date, prior_status: s.status, sets_discarded: discardedSets },
    `discarded:${discardedSets}_sets`,
  );
  return { ...s, status: 'discarded', updated_at: ts };
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
    source: 'ios' | 'mcp';
  },
): Promise<{ set: SetLogRow; deduped: boolean }> {
  // Guard: the session must belong to this user.
  const sess = await db
    .prepare('SELECT id FROM sessions WHERE id = ?1 AND user_id = ?2')
    .bind(input.session_id, userId)
    .first();
  if (!sess) throw new Error('session_not_found');

  const existing = await db
    .prepare('SELECT * FROM set_logs WHERE id = ?1')
    .bind(input.id)
    .first<SetLogRow>();
  if (existing) return { set: existing, deduped: true };

  // Collision-safe set_index. MCP and iOS each compute set_index
  // independently, so two writers could pick the same index for the same
  // (session, exercise, is_warmup) — the bug that produced two set_index=3
  // squat sets. Renumber on collision: keep the provided index unless a live
  // row already holds it, in which case bump to max+1. The partial unique
  // index ux_set_slot (migration 0013) is the hard backstop for races.
  const isWarmupInt = input.is_warmup ? 1 : 0;
  let setIndex = input.set_index;
  const clash = await db
    .prepare(
      `SELECT 1 FROM set_logs
       WHERE session_id = ?1 AND exercise_id = ?2 AND set_index = ?3
         AND is_warmup = ?4 AND deleted_at IS NULL LIMIT 1`,
    )
    .bind(input.session_id, input.exercise_id, setIndex, isWarmupInt)
    .first();
  if (clash) {
    const max = await db
      .prepare(
        `SELECT COALESCE(MAX(set_index), 0) AS m FROM set_logs
         WHERE session_id = ?1 AND exercise_id = ?2 AND is_warmup = ?3
           AND deleted_at IS NULL`,
      )
      .bind(input.session_id, input.exercise_id, isWarmupInt)
      .first<{ m: number }>();
    setIndex = (max?.m ?? 0) + 1;
  }

  // Timed-ness is stored per-set (never inferred from duration_s, which rep
  // sets carry incidentally): an explicit flag wins; otherwise default to the
  // exercise's catalog modality.
  let isTimedInt: number;
  if (typeof input.is_timed === 'boolean') {
    isTimedInt = input.is_timed ? 1 : 0;
  } else {
    const exRow = await db
      .prepare('SELECT modality FROM exercises WHERE id = ?1')
      .bind(input.exercise_id)
      .first<{ modality: string | null }>();
    isTimedInt = exRow?.modality === 'timed' ? 1 : 0;
  }

  const row: SetLogRow = {
    id: input.id,
    session_id: input.session_id,
    exercise_id: input.exercise_id,
    template_exercise_id: input.template_exercise_id ?? null,
    set_index: setIndex,
    weight: input.weight,
    reps: input.reps,
    rpe: input.rpe ?? null,
    is_warmup: isWarmupInt,
    notes: input.notes ?? null,
    logged_at: input.logged_at ?? now(),
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
  const insert = () =>
    db
      .prepare(
        `INSERT INTO set_logs
         (id,session_id,exercise_id,template_exercise_id,set_index,weight,reps,rpe,is_warmup,notes,logged_at,source,duration_s,is_timed,deleted_at)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,NULL)
         ON CONFLICT(id) DO NOTHING`,
      )
      .bind(
        row.id, row.session_id, row.exercise_id, row.template_exercise_id, row.set_index,
        row.weight, row.reps, row.rpe, row.is_warmup, row.notes, row.logged_at, row.source,
        row.duration_s, row.is_timed,
      )
      .run();
  for (let attempt = 0; ; attempt++) {
    try {
      await insert();
      break;
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
        .bind(input.session_id, input.exercise_id, isWarmupInt)
        .first<{ m: number }>();
      row.set_index = (max?.m ?? 0) + 1;
    }
  }
  // Logging a set implicitly starts the session. A 'discarded' row is
  // also revived here (defense-in-depth: getOrCreateSession already
  // resurrects on the get path, but logging work into a discarded session
  // must never leave the new set stranded under an invisible/vanished
  // row). started_at resets off the COALESCE for a revived discard so the
  // sRPE duration reflects the new attempt, not the thrown-away one.
  await db
    .prepare("UPDATE sessions SET status = CASE WHEN status IN ('planned','discarded') THEN 'in_progress' ELSE status END, started_at = CASE WHEN status='discarded' THEN ?2 ELSE COALESCE(started_at, ?2) END, updated_at = ?2 WHERE id = ?1")
    .bind(input.session_id, now())
    .run();
  return { set: row, deduped: false };
}

/**
 * Most recent live set across ALL sources for (user, exercise, weight, reps,
 * is_warmup) within a sliding window (default 120s). Used by the MCP log_set
 * path to refuse phantom dupes when iOS just logged the same work; REST
 * writes from iOS are not gated by this (their idempotency is the row UUID).
 */
export async function findRecentMatchingSet(
  db: D1Database,
  userId: string,
  args: {
    exercise_id: string;
    weight: number;
    reps: number;
    is_warmup: boolean;
    within_ms?: number;
  },
): Promise<SetLogRow | null> {
  const since = now() - (args.within_ms ?? 120_000);
  const row = await db
    .prepare(
      `SELECT sl.* FROM set_logs sl
       JOIN sessions s ON s.id = sl.session_id
       WHERE s.user_id = ?1
         AND sl.exercise_id = ?2
         AND sl.weight = ?3
         AND sl.reps = ?4
         AND sl.is_warmup = ?5
         AND sl.deleted_at IS NULL
         AND sl.logged_at >= ?6
       ORDER BY sl.logged_at DESC LIMIT 1`,
    )
    .bind(userId, args.exercise_id, args.weight, args.reps, args.is_warmup ? 1 : 0, since)
    .first<SetLogRow>();
  return row ?? null;
}

export async function patchSet(
  db: D1Database,
  userId: string,
  setId: string,
  patch: { weight?: number; reps?: number; rpe?: number | null; notes?: string | null; deleted?: boolean },
): Promise<SetLogRow | null> {
  const row = await db
    .prepare(
      `SELECT sl.* FROM set_logs sl JOIN sessions s ON s.id = sl.session_id
       WHERE sl.id = ?1 AND s.user_id = ?2`,
    )
    .bind(setId, userId)
    .first<SetLogRow>();
  if (!row) return null;
  const weight = patch.weight ?? row.weight;
  const reps = patch.reps ?? row.reps;
  const rpe = patch.rpe === undefined ? row.rpe : patch.rpe;
  const notes = patch.notes === undefined ? row.notes : patch.notes;
  // WARNING: this soft-delete is INVISIBLE to an incremental `sets_since`
  // client — the getState sets query gates on the immutable `logged_at`,
  // not deleted_at (see the WARNING on that query). Only safe while the
  // iOS client full-reloads; needs a mutable updated_at cursor (follow-up).
  const deletedAt = patch.deleted ? row.deleted_at ?? now() : patch.deleted === false ? null : row.deleted_at;
  // Undelete collision: the partial unique index ux_set_slot only covers
  // live rows, so reviving a soft-deleted set whose slot was reused while it
  // was gone would violate the constraint (→ 500). Renumber the revived row
  // to max+1 before clearing deleted_at — same "renumber, don't reject"
  // contract logSet uses.
  let setIndex = row.set_index;
  const isUndelete = row.deleted_at !== null && deletedAt === null;
  if (isUndelete) {
    const clash = await db
      .prepare(
        `SELECT 1 FROM set_logs
         WHERE session_id = ?1 AND exercise_id = ?2 AND set_index = ?3
           AND is_warmup = ?4 AND deleted_at IS NULL AND id != ?5 LIMIT 1`,
      )
      .bind(row.session_id, row.exercise_id, setIndex, row.is_warmup, setId)
      .first();
    if (clash) {
      const max = await db
        .prepare(
          `SELECT COALESCE(MAX(set_index), 0) AS m FROM set_logs
           WHERE session_id = ?1 AND exercise_id = ?2 AND is_warmup = ?3
             AND deleted_at IS NULL`,
        )
        .bind(row.session_id, row.exercise_id, row.is_warmup)
        .first<{ m: number }>();
      setIndex = (max?.m ?? 0) + 1;
    }
  }
  // The clash pre-check above narrows the common case, but a concurrent
  // undelete/logSet can still race onto the same slot and trip ux_set_slot.
  // Retry-renumber on conflict (same contract as logSet) so an undelete is
  // never a 500. Non-undelete patches keep their set_index, so they never
  // conflict and the loop runs once.
  for (let attempt = 0; ; attempt++) {
    try {
      await db
        .prepare('UPDATE set_logs SET weight=?2, reps=?3, rpe=?4, notes=?5, deleted_at=?6, set_index=?7 WHERE id=?1')
        .bind(setId, weight, reps, rpe, notes, deletedAt, setIndex)
        .run();
      break;
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
        .bind(row.session_id, row.exercise_id, row.is_warmup)
        .first<{ m: number }>();
      setIndex = (max?.m ?? 0) + 1;
    }
  }
  // Phantom-session guard. Logging a set promotes a session 'planned' ->
  // 'in_progress' (see logSet). Deleting the LAST live set must do the
  // inverse: an 'in_progress' session with zero live sets records no work,
  // yet without this it lingers as a stale "in progress" row that the
  // calendar/agenda (and MCP get_today_workout) still surface. Revert it to
  // 'planned' and clear started_at so EVERY client — app, REST, MCP — agrees
  // the day is simply the upcoming workout again. Fires only on a real
  // live->deleted transition (undeletes / field-only edits never touch
  // status), and only for 'in_progress' (a 'completed' session is NOT
  // auto-un-completed — that's a deliberate terminal state).
  const isDelete = row.deleted_at === null && deletedAt !== null;
  if (isDelete) {
    const remaining = await db
      .prepare('SELECT COUNT(*) AS c FROM set_logs WHERE session_id = ?1 AND deleted_at IS NULL')
      .bind(row.session_id)
      .first<{ c: number }>();
    if ((remaining?.c ?? 0) === 0) {
      await db
        .prepare(
          "UPDATE sessions SET status = 'planned', started_at = NULL, updated_at = ?2 WHERE id = ?1 AND status = 'in_progress'",
        )
        .bind(row.session_id, now())
        .run();
    }
  }
  return { ...row, weight, reps, rpe, notes, deleted_at: deletedAt, set_index: setIndex };
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
  // WARNING: `logged_at` is an IMMUTABLE incremental cursor — a set
  // soft-deleted (deleted_at set) AFTER a client's watermark passed its
  // logged_at is NEVER delivered incrementally (FIX3-class tombstone gap,
  // like external_events). Only safe because the current iOS client
  // full-reloads (sets_since=0). An incremental client needs a mutable
  // set_logs `updated_at` cursor — tracked follow-up; see patchSet.
  const sets = await db
    .prepare(
      `SELECT sl.* FROM set_logs sl JOIN sessions s ON s.id = sl.session_id
       WHERE s.user_id = ?1 AND sl.logged_at > ?2 ORDER BY sl.logged_at`,
    )
    .bind(userId, setsSince)
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
  //    removals. Uses `logged_at` as the cursor for inserts and
  //    `deleted_at` to surface tombstones past the cursor (see
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
    sessions: sessions.results,
    sets: sets.results,
    external_events: events.results,
    external_activities: activities.results,
    activities: userActivities,
    server_time: now(),
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
  const loggedAt = input.logged_at ?? now();
  await db
    .prepare(
      `INSERT INTO activities
         (id,user_id,date,type,title,duration_minutes,notes,logged_at,source,deleted_at)
       VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,NULL)
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
      `UPDATE activities SET deleted_at = ?3
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
 * cursor — both fresh inserts (logged_at > since) AND tombstones
 * (deleted_at > since), so a syncing client can apply removals. Same
 * pattern as the set_logs sync described in DESIGN.md §7. Ordered by
 * logged_at so the client can advance its watermark monotonically.
 */
export async function listActivitiesForUser(
  db: D1Database,
  userId: string,
  sinceMs: number,
  limit?: number,
): Promise<ActivityRow[]> {
  const cap = typeof limit === 'number' && limit > 0 ? Math.min(limit, 1000) : 1000;
  const rows = await db
    .prepare(
      `SELECT * FROM activities
       WHERE user_id = ?1
         AND (logged_at > ?2 OR (deleted_at IS NOT NULL AND deleted_at > ?2))
       ORDER BY logged_at
       LIMIT ?3`,
    )
    .bind(userId, sinceMs, cap)
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
  if (!plan) plan = await createPlan(db, userId, input.name ?? 'My Plan', input.meta ?? null);
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

  // Pre-generate new template_exercise ids so the remap can target them
  // (the old code uuid()'d inline during INSERT — replaced below). Keyed
  // by (newDayId, exercise_id); a duplicate-within-day collapses to the
  // first occurrence's id for remap purposes (the inserted rows still get
  // distinct ids per occurrence — see the inserter below).
  const newTeIdByDayAndEx = new Map<string, string>();
  const teIdPerExerciseOccurrence: string[][] = input.days.map((d) =>
    (d.exercises ?? []).map(() => uuid()),
  );
  input.days.forEach((d, di) => {
    const dayId = newDayIds[di]!;
    (d.exercises ?? []).forEach((e, ei) => {
      const exId = resolved.get(e.exercise)!;
      const key = `${dayId}:${exId}`;
      if (!newTeIdByDayAndEx.has(key)) {
        newTeIdByDayAndEx.set(key, teIdPerExerciseOccurrence[di]![ei]!);
      }
    });
  });

  // Build old → new remaps (null = removed; reference must NULL out).
  const oldToNewDay = new Map<string, string | null>();
  for (const od of oldDays.results) {
    const lk = od.day_label?.toLowerCase();
    const nk = od.name.toLowerCase();
    const newId = (lk != null ? newIdByLabel.get(lk) : undefined) ?? newIdByName.get(nk) ?? null;
    oldToNewDay.set(od.id, newId);
  }
  const oldTeRows = await db
    .prepare(
      `SELECT te.id, te.day_template_id, te.exercise_id
         FROM template_exercises te
         JOIN day_templates d ON d.id = te.day_template_id
        WHERE d.plan_id = ?1`,
    )
    .bind(plan.id)
    .all<{ id: string; day_template_id: string; exercise_id: string }>();
  const oldToNewTe = new Map<string, string | null>();
  for (const ot of oldTeRows.results) {
    const newDayId = oldToNewDay.get(ot.day_template_id) ?? null;
    if (newDayId == null) {
      oldToNewTe.set(ot.id, null);
    } else {
      const newTeId = newTeIdByDayAndEx.get(`${newDayId}:${ot.exercise_id}`) ?? null;
      oldToNewTe.set(ot.id, newTeId);
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
          'INSERT INTO day_templates (id,plan_id,name,day_label,order_index,notes,created_at,updated_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8)',
        )
        .bind(dayId, plan!.id, d.name, d.day_label ?? null, d.order_index ?? di, d.notes ?? null, ts, ts),
    );
  });
  // 2) INSERT new template_exercises (children of step 1's parents).
  input.days.forEach((d, di) => {
    const dayId = newDayIds[di]!;
    (d.exercises ?? []).forEach((e, ei) => {
      stmts.push(
        db
          .prepare(
            `INSERT INTO template_exercises
             (id,day_template_id,exercise_id,order_index,target_sets,target_reps,target_reps_max,target_rpe,rest_seconds,target_weight,target_duration_s,progression,cues,created_at,updated_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15)`,
          )
          .bind(
            teIdPerExerciseOccurrence[di]![ei]!, dayId, resolved.get(e.exercise)!, e.order_index ?? ei, e.target_sets,
            e.target_reps, e.target_reps_max ?? null, e.target_rpe ?? null, e.rest_seconds ?? 120,
            e.target_weight ?? null, e.target_duration_s ?? null,
            e.progression == null ? null : JSON.stringify(e.progression),
            e.cues ?? null, ts, ts,
          ),
      );
    });
  });
  // 3) Remap session.day_template_id: old → new (surviving) or NULL.
  for (const [oldDayId, newDayId] of oldToNewDay.entries()) {
    if (newDayId != null) {
      stmts.push(
        db
          .prepare('UPDATE sessions SET day_template_id = ?2 WHERE day_template_id = ?1')
          .bind(oldDayId, newDayId),
      );
    } else {
      stmts.push(
        db
          .prepare('UPDATE sessions SET day_template_id = NULL WHERE day_template_id = ?1')
          .bind(oldDayId),
      );
    }
  }
  // 4) Remap set_logs.template_exercise_id (same scheme).
  for (const [oldTeId, newTeId] of oldToNewTe.entries()) {
    if (newTeId != null) {
      stmts.push(
        db
          .prepare('UPDATE set_logs SET template_exercise_id = ?2 WHERE template_exercise_id = ?1')
          .bind(oldTeId, newTeId),
      );
    } else {
      stmts.push(
        db
          .prepare('UPDATE set_logs SET template_exercise_id = NULL WHERE template_exercise_id = ?1')
          .bind(oldTeId),
      );
    }
  }
  // 5) DELETE old template_exercises by EXPLICIT id (avoid catching the
  //    freshly-inserted new rows that now share plan_id). Children first.
  for (const ot of oldTeRows.results) {
    stmts.push(db.prepare('DELETE FROM template_exercises WHERE id = ?1').bind(ot.id));
  }
  // 6) DELETE old day_templates by EXPLICIT id. Parents last.
  for (const od of oldDays.results) {
    stmts.push(db.prepare('DELETE FROM day_templates WHERE id = ?1').bind(od.id));
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
        'UPDATE plans SET name = ?2, meta = ?3, version = version + 1, updated_at = ?4 WHERE id = ?1',
      )
      .bind(
        plan.id,
        input.name ?? plan.name,
        serializePlanMeta(baseMeta, remappedSchedule),
        ts,
      ),
  );
  await db.batch(stmts);
  return { conflict: false, plan: (await getPlanTree(db, userId))! };
}

/** Find a template_exercise slot by id, or by (day + exercise name/id). */
async function findSlot(
  db: D1Database,
  userId: string,
  ref: { template_exercise_id?: string; day?: string; exercise?: string },
): Promise<TemplateExerciseRow | null> {
  if (ref.template_exercise_id) {
    return db
      .prepare(
        `SELECT te.* FROM template_exercises te
         JOIN day_templates d ON d.id = te.day_template_id
         JOIN plans p ON p.id = d.plan_id
         WHERE te.id = ?1 AND p.user_id = ?2`,
      )
      .bind(ref.template_exercise_id, userId)
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
]);

export async function updateExercise(
  db: D1Database,
  userId: string,
  ref: { template_exercise_id?: string; day?: string; exercise?: string },
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
       target_rpe=?5,rest_seconds=?6,target_weight=?7,target_duration_s=?8,cues=?9,progression=?10,order_index=?11,updated_at=?12
       WHERE id=?1`,
    )
    .bind(
      slot.id, m.target_sets, m.target_reps, m.target_reps_max, m.target_rpe,
      m.rest_seconds, m.target_weight, m.target_duration_s, m.cues, m.progression, m.order_index, m.updated_at,
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
  ref: { template_exercise_id?: string; day?: string; exercise?: string },
): Promise<TemplateExerciseRow | null> {
  const slot = await findSlot(db, userId, ref);
  if (!slot) return null;
  await db
    .batch([
      db
        .prepare('UPDATE set_logs SET template_exercise_id = NULL WHERE template_exercise_id = ?1')
        .bind(slot.id),
      db.prepare('DELETE FROM template_exercises WHERE id = ?1').bind(slot.id),
    ]);
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
): Promise<SessionRow | null> {
  const plan = await getActivePlan(db, userId);
  if (!plan) return null;
  const session = await getOrCreateSession(db, userId, plan.id, date, null);
  const r = await patchSession(db, userId, session.id, {
    status: 'completed',
    perceived_fatigue: perceivedFatigue ?? undefined,
    notes: notes ?? undefined,
  });
  // logWorkoutComplete ALWAYS passes status:'completed', which is a valid
  // status and never the skipped-burial case — so neither patchSession
  // rejection arm ('invalid_status' / 'session_already_started') is
  // reachable here. Fail LOUD rather than silently return null if that
  // ever changes (e.g. the guard's scope is widened beyond 'skipped').
  if (r && 'error' in r) {
    throw new Error(
      `unreachable: patchSession returned ${r.error} on the status:'completed' path — guard scope changed`,
    );
  }
  return r;
}

// ---- one-way lifting-load export to intervals.icu (Option C) ------------
//
// This whole block is its OWN concern: a best-effort, decoupled, one-way
// EXPORT. It never bumps plans.version, never touches the plan tree or the
// append-only log, and an intervals.icu failure must never fail/block/throw
// into log_workout_complete.

/**
 * sRPE-load calibration knob: `load = round(sessionRPE * durationMin * K)`.
 *
 * This is a TUNABLE calibration constant, NOT a correctness value — it only
 * scales the absolute number to sit on a TSS-comparable axis in
 * intervals.icu. Adjust it to taste; nothing in this codebase depends on
 * its exact value.
 */
export const SRPE_LOAD_K = 0.2;

/** Session-RPE fallback when neither perceived_fatigue nor set RPE exist.
 *  Documented ESTIMATE: a "moderately hard" session on the 1-10 scale. */
export const SRPE_FALLBACK_RPE = 7;

/** Duration is clamped to this minute window before the load formula. */
export const SRPE_MIN_MINUTES = 20;
export const SRPE_MAX_MINUTES = 180;

export interface SessionLoad {
  /** Final integer load to push as icu_training_load. */
  load: number;
  /** Resolved session-RPE (1-10) and which source produced it. */
  sessionRpe: number;
  rpeSource: 'perceived_fatigue' | 'weighted_set_rpe' | 'fallback';
  /** Clamped duration in minutes / raw seconds (for the activity payload). */
  durationMin: number;
  durationSec: number;
}

/**
 * PURE sRPE load model (no I/O). Locked design:
 *   load = round(sessionRPE * durationMin * K)
 *
 * sessionRPE priority:
 *   1. session.perceived_fatigue (1-10) if set
 *   2. else load-weighted mean of NON-warmup set RPE
 *      (weight = weight*reps; sets without RPE are excluded)
 *   3. else SRPE_FALLBACK_RPE (documented estimate)
 *
 * duration = (completed_at - started_at) → minutes, clamped to
 * [SRPE_MIN_MINUTES, SRPE_MAX_MINUTES]. If started/completed are missing
 * the duration is treated as 0 then clamped up to the floor.
 *
 * Returns `null` when the session has NO non-warmup sets → caller SKIPS
 * the export entirely (a no-op, NOT a load of 0).
 */
export function computeSessionLoad(
  session: Pick<SessionRow, 'perceived_fatigue' | 'started_at' | 'completed_at'>,
  sets: Pick<SetLogRow, 'weight' | 'reps' | 'rpe' | 'is_warmup' | 'deleted_at'>[],
): SessionLoad | null {
  const working = sets.filter((s) => !s.is_warmup && s.deleted_at == null);
  // No non-warmup work → nothing to export. Skip, do not push load 0.
  if (working.length === 0) return null;

  let sessionRpe: number;
  let rpeSource: SessionLoad['rpeSource'];
  if (
    session.perceived_fatigue != null &&
    Number.isFinite(session.perceived_fatigue)
  ) {
    sessionRpe = session.perceived_fatigue;
    rpeSource = 'perceived_fatigue';
  } else {
    // Load-weighted mean of non-warmup set RPE; weight = weight*reps.
    let wSum = 0;
    let wRpe = 0;
    for (const s of working) {
      if (s.rpe == null || !Number.isFinite(s.rpe)) continue;
      const w = Math.max(0, s.weight) * Math.max(0, s.reps);
      // A bodyweight/zero-volume set still counts (min weight 1) so its
      // RPE is not silently dropped.
      const ww = w > 0 ? w : 1;
      wSum += ww;
      wRpe += ww * s.rpe;
    }
    if (wSum > 0) {
      sessionRpe = wRpe / wSum;
      rpeSource = 'weighted_set_rpe';
    } else {
      sessionRpe = SRPE_FALLBACK_RPE;
      rpeSource = 'fallback';
    }
  }

  const rawMs =
    session.started_at != null && session.completed_at != null
      ? session.completed_at - session.started_at
      : 0;
  const rawMin = rawMs > 0 ? rawMs / 60_000 : 0;
  const durationMin = Math.min(
    SRPE_MAX_MINUTES,
    Math.max(SRPE_MIN_MINUTES, rawMin),
  );

  const load = Math.round(sessionRpe * durationMin * SRPE_LOAD_K);
  return {
    load,
    sessionRpe,
    rpeSource,
    durationMin,
    durationSec: Math.round(durationMin * 60),
  };
}

interface LoadExportRow {
  session_id: string;
  intervals_ref: string | null;
  load: number | null;
  status: string;
  attempts: number;
  updated_at: number;
}

export interface ExportDeps {
  /** Injected in tests so the suite never hits the network. */
  fetcher?: Fetcher;
  timeoutMs?: number;
  /**
   * Override the in-flight staleness window (ms). Defaults to
   * IN_FLIGHT_STALE_MS. Tests set this (e.g. 0) to deterministically
   * exercise the crashed-in_flight reclaim path without sleeping 15 min;
   * production never sets it.
   */
  staleMs?: number;
}

/**
 * An `in_flight` ledger row older than this (epoch-ms age) is treated as a
 * crashed/abandoned export and is eligible for cron retry, so a process
 * that died mid-push cannot wedge a session forever. 15 min comfortably
 * exceeds the export's worst-case wall time (a couple of ~10s intervals
 * round-trips) while still recovering quickly.
 */
export const IN_FLIGHT_STALE_MS = 15 * 60_000;

/**
 * Best-effort, one-way push of a completed session's sRPE load into
 * intervals.icu.
 *
 * GUARANTEES (architecture, non-negotiable):
 *  - NEVER bumps plans.version; NEVER touches the plan tree / sessions /
 *    set_logs. Only writes its own `session_load_exports` row + audit_log.
 *  - Idempotent, keyed by session_id: re-running for the same session
 *    UPSERTs the SAME row and (via the stored intervals_ref) UPDATEs the
 *    SAME intervals.icu activity — never a duplicate.
 *  - This function does not throw for an intervals failure (returns a
 *    status). Callers in the sacred log_workout_complete path additionally
 *    wrap it so even an unexpected throw cannot propagate.
 *
 * Returns the resolved status; 'skipped' means no non-warmup work (no-op).
 */
export async function exportSessionLoad(
  db: D1Database,
  env: Env,
  userId: string,
  sessionId: string,
  deps: ExportDeps = {},
): Promise<{ status: 'ok' | 'pending' | 'skipped' | 'disabled'; load?: number }> {
  const session = await db
    .prepare('SELECT * FROM sessions WHERE id = ?1 AND user_id = ?2')
    .bind(sessionId, userId)
    .first<SessionRow>();
  if (!session) return { status: 'skipped' };

  const sets = await getSetsForSession(db, sessionId);
  const computed = computeSessionLoad(session, sets);

  // No non-warmup work → skip export ENTIRELY (no row write, no push).
  if (!computed) {
    await writeAudit(db, userId, 'export_session_load', { session_id: sessionId }, 'skipped:no_working_sets');
    return { status: 'skipped' };
  }

  // Non-null aliases (TS can't carry the `session`/`computed` guards above
  // into the nested putUpdateKnownRef closure defined later).
  const sessionRow = session;
  const computedLoad = computed;

  // Per-user intervals.icu credentials (M1). Fall back to legacy env vars
  // ONLY when this user has never PATCHed their creds — after an explicit
  // disconnect, both columns are NULL but the audit row says "intentionally
  // cleared." Without this guard, completing a session would re-export to
  // intervals.icu via env creds even though the user explicitly disconnected
  // (the sync paths already enforce the same invariant via the same helper).
  const userCreds = await getUserIntervalsCreds(db, userId);
  const envFallbackOk =
    userCreds.api_key === null &&
    userCreds.athlete_id === null &&
    !(await userHasTouchedIntervalsCreds(db, userId));
  const apiKey = userCreds.api_key ?? (envFallbackOk ? env.INTERVALS_ICU_API_KEY : null);
  const athleteId =
    userCreds.athlete_id ?? (envFallbackOk ? env.INTERVALS_ICU_ATHLETE_ID : null);
  // OAuth bearer token (no env fallback — env is the legacy API-key path).
  // Passed to pushStrengthActivity so OAuth users export via Bearer.
  const accessToken = userCreds.access_token;

  // Day name for a friendly activity title.
  let dayName = 'Lifting';
  if (session.day_template_id) {
    const dt = await db
      .prepare('SELECT name, day_label FROM day_templates WHERE id = ?1')
      .bind(session.day_template_id)
      .first<{ name: string; day_label: string | null }>();
    if (dt) dayName = dt.day_label || dt.name || dayName;
  }
  const name = `Lift: ${dayName}`;

  // ---- PER-SESSION SINGLE-FLIGHT (concurrency guard) -------------------
  //
  // The offline-first iOS client can fire two log_workout_complete requests
  // for the SAME session concurrently (retry-on-timeout while the first is
  // still in-flight) → two waitUntil exports racing. Without serialization
  // both read prior=null, both GET (neither sees the other yet), both POST
  // → a duplicate intervals.icu event with NO cleanup path. The D1 PK
  // dedupes the ledger ROW but not the remote calls.
  //
  // The ledger row is the mutex. Two atomic claim attempts BEFORE any
  // network I/O; `meta.changes === 1` on either ⇒ this caller won and is
  // the ONLY one allowed to GET/POST/PUT-create this session's event:
  //  (a) INSERT a fresh `in_flight` sentinel (first-ever export); or
  //  (b) transition an existing RETRYABLE row (pending / disabled /
  //      STALE in_flight from a crashed run) to `in_flight`.
  // A live in_flight owned by a concurrent export, or a terminal `ok`,
  // matches neither → this caller defers (no remote create).
  const claimTs = now();
  const ins = await db
    .prepare(
      `INSERT INTO session_load_exports
         (session_id,intervals_ref,load,status,attempts,updated_at)
       VALUES (?1,NULL,?2,'in_flight',0,?3)
       ON CONFLICT(session_id) DO NOTHING`,
    )
    .bind(sessionId, computed.load, claimTs)
    .run();
  let wonClaim = ins.meta.changes === 1;
  if (!wonClaim) {
    const staleBefore = claimTs - (deps.staleMs ?? IN_FLIGHT_STALE_MS);
    const take = await db
      .prepare(
        `UPDATE session_load_exports
           SET status='in_flight', updated_at=?2
         WHERE session_id=?1
           AND ( status IN ('pending','disabled')
                 OR (status='in_flight' AND updated_at < ?3) )`,
      )
      .bind(sessionId, claimTs, staleBefore)
      .run();
    wonClaim = take.meta.changes === 1;
  }

  // Read the (now-guaranteed) row to learn any prior ref / terminal state.
  const prior = await db
    .prepare('SELECT * FROM session_load_exports WHERE session_id = ?1')
    .bind(sessionId)
    .first<LoadExportRow>();

  // Idempotent PUT-update against a KNOWN remote ref. Used by BOTH the
  // non-winner deferred-update path and the post-completion changed-load
  // re-export path. A known ref makes pushStrengthActivity go straight to
  // PUT — no GET, no POST — so concurrent callers issuing this against the
  // SAME ref are idempotent and cannot create a duplicate remote event. On
  // success it UPSERTs load/updated_at/status='ok' and writes an audit row
  // (reason supplied by the caller so the audit trail still distinguishes
  // the two callers). It NEVER downgrades the row on failure — the caller
  // decides the (non-downgrading) return value. Returns whether the remote
  // PUT succeeded so the caller can shape its own status/load result.
  async function putUpdateKnownRef(
    ref: string,
    okReason: string,
  ): Promise<{ ok: true } | { ok: false; reason: string }> {
    const upd = await pushStrengthActivity(
      apiKey,
      athleteId,
      {
        date: sessionRow.date,
        name,
        loadTss: computedLoad.load,
        durationSec: computedLoad.durationSec,
        sessionId,
        ref,
      },
      { fetcher: deps.fetcher, timeoutMs: deps.timeoutMs, accessToken },
    );
    if (upd.ok) {
      const ts2 = now();
      await db
        .prepare(
          `UPDATE session_load_exports
             SET intervals_ref=?2, load=?3, status='ok', updated_at=?4
           WHERE session_id=?1`,
        )
        .bind(sessionId, upd.ref, computedLoad.load, ts2)
        .run();
      await writeAudit(
        db,
        userId,
        'export_session_load',
        { session_id: sessionId, load: computedLoad.load },
        `ok:ref=${upd.ref}:${okReason}`,
      );
      return { ok: true };
    }
    return { ok: false, reason: upd.reason };
  }

  if (!wonClaim) {
    // We did NOT claim — another export already owns this session, OR a
    // terminal row exists. We must NOT create a remote event (that is the
    // exact concurrent-duplicate window).
    if (prior?.status === 'ok') {
      // Already exported successfully. `computed.load` is recomputed on
      // EVERY call, so a post-completion correction (re-running
      // log_workout_complete after editing perceived_fatigue / sets / RPE)
      // shows up here as a changed load. Unconditionally early-returning
      // would strand that correction locally — the remote activity would
      // keep the stale load, contradicting the 0008 FROZEN CONTRACT.
      if (computed.load === prior.load) {
        // Inputs unchanged → genuine no-op. Do NOT hit intervals.icu on
        // benign re-calls (idempotent re-export of an ok session).
        return { status: 'ok', load: prior.load };
      }
      if (prior.intervals_ref) {
        // Load changed AND we know the remote ref → idempotently
        // PUT-update the SAME activity (no GET, no POST ⇒ duplicate-free
        // even if two corrections race: concurrent PUTs to the same known
        // ref converge). This is what makes "re-completing with a changed
        // load updates the same activity" actually true.
        const r = await putUpdateKnownRef(prior.intervals_ref, 'reexport_load_changed');
        if (r.ok) return { status: 'ok', load: computed.load };
        // PUT failed — do NOT downgrade the good `ok` row. The stored
        // remote value is still the last good one; a future correction (or
        // the user re-running completion) will retry. P2 ok-not-downgraded
        // recovery guard is preserved.
        await writeAudit(
          db,
          userId,
          'export_session_load',
          { session_id: sessionId },
          `ok:reexport_update_failed:${r.reason}`,
        );
        return { status: 'ok', load: prior.load ?? computed.load };
      }
      // Defensive / unreachable: a terminal `ok` row ALWAYS carries an
      // intervals_ref (a row only becomes `ok` after a push that stored
      // the ref). An `ok` row with a changed load and NO ref therefore
      // should never occur. Handle it like the PUT-failure case above:
      // do NOT downgrade `ok` → that would violate the ok-not-downgraded
      // invariant, and the cron's pending/in_flight selector NEVER picks
      // an `ok` row, so a "defer to pending" here would neither persist
      // nor get reconciled — it would silently drop the correction while
      // re-entering this branch (and re-auditing) on every later call.
      // Keep the row `ok`, return the stored last-good load. Write the
      // anomaly audit AT MOST ONCE per session so this (unreachable) state
      // cannot spam audit_log unbounded across repeated calls.
      const priorAnomaly = await db
        .prepare(
          `SELECT 1 FROM audit_log
             WHERE tool='export_session_load'
               AND result='anomaly:ok_changed_load_no_ref'
               AND args LIKE ?1
             LIMIT 1`,
        )
        .bind(`%${sessionId}%`)
        .first<{ 1: number }>();
      if (!priorAnomaly) {
        await writeAudit(
          db,
          userId,
          'export_session_load',
          { session_id: sessionId, load: computed.load },
          'anomaly:ok_changed_load_no_ref',
        );
      }
      return { status: 'ok', load: prior.load ?? computed.load };
    } else if (prior?.intervals_ref) {
      // A remote event already exists → it is safe & duplicate-free to
      // PUT-update that EXACT ref (known id ⇒ pushStrengthActivity goes
      // straight to PUT, no GET, no POST). This refreshes load without a
      // duplicate even if we lost the claim race.
      const r = await putUpdateKnownRef(prior.intervals_ref, 'deferred_update');
      if (r.ok) return { status: 'ok', load: computed.load };
      // Update failed — leave whatever the in-flight owner / cron will
      // reconcile; do not downgrade a possibly-good row.
      await writeAudit(db, userId, 'export_session_load', { session_id: sessionId }, `deferred:update_failed:${r.reason}`);
      return { status: 'pending', load: computed.load };
    } else {
      // Another export is in flight with no ref yet (or row is pending) —
      // defer entirely. The in-flight owner finishes it; if that owner
      // crashed, the cron retries the stale in_flight row.
      await writeAudit(db, userId, 'export_session_load', { session_id: sessionId }, 'deferred:in_flight');
      return { status: 'pending', load: computed.load };
    }
  }

  // --- This caller WON the claim: it alone performs the create/push. ---
  const push = await pushStrengthActivity(
    apiKey,
    athleteId,
    {
      date: session.date, // device-local civil date VERBATIM
      name,
      loadTss: computed.load,
      durationSec: computed.durationSec,
      sessionId, // drives the deterministic remote idempotency marker
      ref: prior?.intervals_ref ?? null,
    },
    { fetcher: deps.fetcher, timeoutMs: deps.timeoutMs },
  );

  const ts = now();
  // prior.attempts is 0 for a fresh sentinel, or the prior count for a
  // reclaimed retryable row (claim transitions didn't bump it). Count this.
  const attempts = (prior?.attempts ?? 0) + 1;

  if (push.ok) {
    // UPSERT keyed by session_id — same intervals_ref, never a duplicate.
    await db
      .prepare(
        `INSERT INTO session_load_exports
           (session_id,intervals_ref,load,status,attempts,updated_at)
         VALUES (?1,?2,?3,'ok',?4,?5)
         ON CONFLICT(session_id) DO UPDATE SET
           intervals_ref=excluded.intervals_ref,
           load=excluded.load,
           status='ok',
           attempts=excluded.attempts,
           updated_at=excluded.updated_at`,
      )
      .bind(sessionId, push.ref, computed.load, attempts, ts)
      .run();
    await writeAudit(
      db,
      userId,
      'export_session_load',
      { session_id: sessionId, load: computed.load },
      `ok:ref=${push.ref}`,
    );
    return { status: 'ok', load: computed.load };
  }

  if (push.reason === 'disabled') {
    // Feature dormant — record nothing pushable, do not mark pending.
    await db
      .prepare(
        `INSERT INTO session_load_exports
           (session_id,intervals_ref,load,status,attempts,updated_at)
         VALUES (?1,?2,?3,'disabled',?4,?5)
         ON CONFLICT(session_id) DO UPDATE SET
           load=excluded.load,
           status='disabled',
           attempts=excluded.attempts,
           updated_at=excluded.updated_at`,
      )
      .bind(sessionId, prior?.intervals_ref ?? null, computed.load, attempts, ts)
      .run();
    await writeAudit(db, userId, 'export_session_load', { session_id: sessionId }, 'disabled');
    return { status: 'disabled' };
  }

  // Transient failure (http/timeout/parse) → leave PENDING for cron retry.
  await db
    .prepare(
      `INSERT INTO session_load_exports
         (session_id,intervals_ref,load,status,attempts,updated_at)
       VALUES (?1,?2,?3,'pending',?4,?5)
       ON CONFLICT(session_id) DO UPDATE SET
         intervals_ref=COALESCE(session_load_exports.intervals_ref,excluded.intervals_ref),
         load=excluded.load,
         status='pending',
         attempts=excluded.attempts,
         updated_at=excluded.updated_at`,
    )
    .bind(sessionId, prior?.intervals_ref ?? null, computed.load, attempts, ts)
    .run();
  await writeAudit(
    db,
    userId,
    'export_session_load',
    { session_id: sessionId, load: computed.load },
    `pending:${push.reason}${'status' in push && push.status ? `:${push.status}` : ''}`,
  );
  return { status: 'pending', load: computed.load };
}

/**
 * BEST-EFFORT export hook for the sacred log_workout_complete path. Wraps
 * exportSessionLoad so that ANY failure — including an unexpected throw —
 * cannot fail, block, or propagate into workout completion / set logging.
 * Resolves silently regardless; the cron retries anything left pending.
 */
export async function tryExportSessionLoad(
  db: D1Database,
  env: Env,
  userId: string,
  sessionId: string,
  deps: ExportDeps = {},
): Promise<void> {
  try {
    await exportSessionLoad(db, env, userId, sessionId, deps);
  } catch (e) {
    // The export must NEVER throw into the caller. Best-effort: record a
    // pending row (so the cron retries) and swallow. Even this recovery is
    // guarded so a DB hiccup here still cannot propagate.
    try {
      // Status guard: if the ok UPSERT already committed and a LATER step
      // (e.g. writeAudit) threw, the row is terminal `ok` with a real
      // intervals_ref — must NOT be downgraded to `pending` (that would
      // cause a needless ok→pending→ok cron round-trip). Only re-queue a
      // non-terminal row. intervals_ref is still never touched on conflict.
      await db
        .prepare(
          `INSERT INTO session_load_exports (session_id,intervals_ref,load,status,attempts,updated_at)
           VALUES (?1,NULL,NULL,'pending',
             COALESCE((SELECT attempts FROM session_load_exports WHERE session_id=?1),0)+1,?2)
           ON CONFLICT(session_id) DO UPDATE SET
             status = CASE WHEN status='ok' THEN 'ok' ELSE 'pending' END,
             updated_at = excluded.updated_at`,
        )
        .bind(sessionId, now())
        .run();
    } catch {
      /* swallow — completion must succeed no matter what */
    }
    console.error('tryExportSessionLoad swallowed', e);
  }
}

/**
 * Cron retry: re-attempt every still-`pending` export PLUS any STALE
 * `in_flight` row (older than IN_FLIGHT_STALE_MS — a crashed export that
 * never reached a terminal state, so it can't wedge a session forever).
 * Idempotent — each retry routes back through exportSessionLoad, whose
 * single-flight reclaim transitions the stale/pending row to in_flight and
 * the marker lookup / known ref guarantees the same intervals activity is
 * UPDATEd (never a duplicate). A failing retry stays 'pending'. Never
 * throws.
 */
export async function retryPendingLoadExports(
  db: D1Database,
  env: Env,
  deps: ExportDeps = {},
): Promise<{ retried: number; ok: number; stillPending: number }> {
  const out = { retried: 0, ok: 0, stillPending: 0 };
  let rows: { session_id: string }[];
  try {
    const staleBefore = now() - (deps.staleMs ?? IN_FLIGHT_STALE_MS);
    const r = await db
      .prepare(
        `SELECT session_id FROM session_load_exports
          WHERE status = 'pending'
             OR (status = 'in_flight' AND updated_at < ?1)`,
      )
      .bind(staleBefore)
      .all<{ session_id: string }>();
    rows = r.results;
  } catch (e) {
    console.error('retryPendingLoadExports list failed', e);
    return out;
  }
  for (const { session_id } of rows) {
    out.retried++;
    try {
      const owner = await db
        .prepare('SELECT user_id FROM sessions WHERE id = ?1')
        .bind(session_id)
        .first<{ user_id: string }>();
      if (!owner) continue;
      const res = await exportSessionLoad(db, env, owner.user_id, session_id, deps);
      if (res.status === 'ok') out.ok++;
      else if (res.status === 'pending') out.stillPending++;
    } catch (e) {
      out.stillPending++;
      console.error('retryPendingLoadExports item failed', e);
    }
  }
  return out;
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
        const w = Math.round((te.target_weight * wtF) / 5) * 5;
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

export async function getHistory(
  db: D1Database,
  userId: string,
  exerciseId: string,
  from: number,
  to: number,
) {
  const sets = await db
    .prepare(
      `SELECT sl.*, s.date as session_date FROM set_logs sl
       JOIN sessions s ON s.id = sl.session_id
       WHERE s.user_id = ?1 AND sl.exercise_id = ?2 AND sl.deleted_at IS NULL
         AND sl.is_warmup = 0 AND sl.logged_at BETWEEN ?3 AND ?4
       ORDER BY sl.logged_at`,
    )
    .bind(userId, exerciseId, from, to)
    .all<SetLogRow & { session_date: string }>();
  // Top working set per session + Epley est-1RM.
  const bySession = new Map<string, { date: string; top: SetLogRow; est_1rm: number }>();
  for (const s of sets.results) {
    const e = epley(s.weight, s.reps);
    const cur = bySession.get(s.session_date);
    if (!cur || e > cur.est_1rm) {
      bySession.set(s.session_date, { date: s.session_date, top: s, est_1rm: e });
    }
  }
  return {
    exercise_id: exerciseId,
    sets: sets.results,
    by_session: [...bySession.values()].sort((a, b) => a.date.localeCompare(b.date)),
  };
}

export async function getVolume(
  db: D1Database,
  userId: string,
  muscle: string,
  from: number,
  to: number,
) {
  // Unilateral sets log reps per-side, so a 45x8 Bulgarian split squat is
  // really 16 physical reps and 720 lb of work — not 8 reps and 360 lb.
  // hard_sets stays a literal COUNT (one logged set is one set entered),
  // tonnage doubles via the CASE so volume trends match reality.
  const rows = await db
    .prepare(
      `SELECT strftime('%Y-%W', s.date) AS week,
              COUNT(*) AS hard_sets,
              SUM(sl.weight * sl.reps
                  * CASE WHEN e.laterality = 'unilateral' THEN 2 ELSE 1 END) AS tonnage
       FROM set_logs sl
       JOIN sessions s ON s.id = sl.session_id
       JOIN exercises e ON e.id = sl.exercise_id
       WHERE s.user_id = ?1 AND e.primary_muscle = ?2 AND sl.deleted_at IS NULL
         AND sl.is_warmup = 0 AND sl.logged_at BETWEEN ?3 AND ?4
       GROUP BY week ORDER BY week`,
    )
    .bind(userId, muscle, from, to)
    .all<{ week: string; hard_sets: number; tonnage: number }>();
  return { muscle_group: muscle, buckets: rows.results };
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
): Promise<
  | { conflict: true; current_version: number }
  | { error: 'no_active_plan' }
  | { error: 'unknown_day_ref'; ref: string }
  | { ok: true; plan: PlanRow; schedule: WeeklySchedule; version: number }
> {
  const plan = await getActivePlan(db, userId);
  if (!plan) return { error: 'no_active_plan' };
  if (expectedVersion != null && expectedVersion !== plan.version) {
    return { conflict: true, current_version: plan.version };
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
  const row = await db
    .prepare(
      'UPDATE plans SET meta = ?2, version = version + 1, updated_at = ?3 WHERE id = ?1 RETURNING version',
    )
    .bind(plan.id, serializePlanMeta(meta, schedule), ts)
    .first<{ version: number }>();
  return {
    ok: true,
    plan: { ...plan, version: row?.version ?? plan.version + 1, updated_at: ts },
    schedule,
    version: row?.version ?? plan.version + 1,
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
  const row = await db
    .prepare(
      'UPDATE plans SET meta = ?2, version = version + 1, updated_at = ?3 WHERE id = ?1 RETURNING version',
    )
    .bind(plan.id, serializePlanMeta(meta, meta.schedule), ts)
    .first<{ version: number }>();
  return { ok: true, version: row?.version ?? plan.version + 1, meta };
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
  return changed ? { version: schedule.version, week } : null;
}

/**
 * Delete one day_template and, in the same transaction, scrub any schedule
 * entries pointing at it and bump plans.version exactly once.
 */
export async function deleteDayTemplate(
  db: D1Database,
  userId: string,
  dayId: string,
): Promise<{ ok: true } | { error: 'day_not_found' }> {
  const plan = await getActivePlan(db, userId);
  if (!plan) return { error: 'day_not_found' };
  const day = await db
    .prepare('SELECT id FROM day_templates WHERE id = ?1 AND plan_id = ?2')
    .bind(dayId, plan.id)
    .first<{ id: string }>();
  if (!day) return { error: 'day_not_found' };
  const meta = parsePlanMeta(plan.meta);
  const remaining = await db
    .prepare('SELECT id FROM day_templates WHERE plan_id = ?1 AND id != ?2')
    .bind(plan.id, dayId)
    .all<{ id: string }>();
  const liveIds = new Set(remaining.results.map((r) => r.id));
  const scrubbed = scrubSchedule(meta.schedule, liveIds);
  const ts = now();
  const stmts: D1PreparedStatement[] = [
    db
      .prepare('DELETE FROM template_exercises WHERE day_template_id = ?1')
      .bind(dayId),
    db.prepare('DELETE FROM day_templates WHERE id = ?1').bind(dayId),
    db
      .prepare(
        'UPDATE plans SET meta = ?2, version = version + 1, updated_at = ?3 WHERE id = ?1',
      )
      .bind(
        plan.id,
        serializePlanMeta(meta, scrubbed ?? meta.schedule),
        ts,
      ),
  ];
  await db.batch(stmts);
  return { ok: true };
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
): Promise<
  | { error: 'no_active_plan' }
  | { error: 'unknown_day_ref'; ref: string }
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
  const existing = await db
    .prepare('SELECT * FROM sessions WHERE user_id = ?1 AND date = ?2 ORDER BY created_at LIMIT 1')
    .bind(userId, date)
    .first<SessionRow>();
  const ts = now();
  if (existing) {
    // The SQL CASE already flips the row to a sensible status; the bug was
    // that the response object spread `...existing` and kept the OLD status
    // (e.g. an agent saw `status: 'discarded'` with a past `started_at`
    // while the DB was actually 'planned' now). Compute the new shape
    // explicitly and persist BOTH started_at and completed_at resets when
    // we're reviving a discarded row, mirroring getOrCreateSession's
    // discard→planned resurrection (consistent revival rule across the
    // two places that revive a discarded session).
    const newStatus =
      existing.status === 'completed' || existing.status === 'in_progress'
        ? existing.status
        : 'planned';
    const reviving = existing.status === 'discarded';
    const newStartedAt = reviving ? null : existing.started_at;
    const newCompletedAt = reviving ? null : existing.completed_at;
    await db
      .prepare(
        'UPDATE sessions SET day_template_id = ?2, status = ?3, started_at = ?4, completed_at = ?5, updated_at = ?6 WHERE id = ?1',
      )
      .bind(existing.id, d.id, newStatus, newStartedAt, newCompletedAt, ts)
      .run();
    return {
      ok: true,
      session: {
        ...existing,
        day_template_id: d.id,
        status: newStatus,
        started_at: newStartedAt,
        completed_at: newCompletedAt,
        updated_at: ts,
      },
    };
  }
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
  };
  await db
    .prepare(
      'INSERT INTO sessions (id,user_id,plan_id,day_template_id,date,status,started_at,completed_at,perceived_fatigue,notes,created_at,updated_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)',
    )
    .bind(s.id, s.user_id, s.plan_id, s.day_template_id, s.date, s.status, s.started_at, s.completed_at, s.perceived_fatigue, s.notes, s.created_at, s.updated_at)
    .run();
  return { ok: true, session: s };
}

/**
 * One-off: mark a specific date a rest/skip day. Writes/updates a sessions
 * row with status 'skipped' — append-only, NO version bump.
 */
export async function skipPlannedSession(
  db: D1Database,
  userId: string,
  date: string,
): Promise<
  | { error: 'no_active_plan' }
  | { error: 'session_already_started'; status: 'in_progress' | 'completed' }
  | { ok: true; session: SessionRow }
> {
  const plan = await getActivePlan(db, userId);
  if (!plan) return { error: 'no_active_plan' };
  const existing = await db
    .prepare('SELECT * FROM sessions WHERE user_id = ?1 AND date = ?2 ORDER BY created_at LIMIT 1')
    .bind(userId, date)
    .first<SessionRow>();
  const ts = now();
  if (existing) {
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
    await db
      .prepare("UPDATE sessions SET status = 'skipped', updated_at = ?2 WHERE id = ?1")
      .bind(existing.id, ts)
      .run();
    return { ok: true, session: { ...existing, status: 'skipped', updated_at: ts } };
  }
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
  };
  await db
    .prepare(
      'INSERT INTO sessions (id,user_id,plan_id,day_template_id,date,status,started_at,completed_at,perceived_fatigue,notes,created_at,updated_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)',
    )
    .bind(s.id, s.user_id, s.plan_id, s.day_template_id, s.date, s.status, s.started_at, s.completed_at, s.perceived_fatigue, s.notes, s.created_at, s.updated_at)
    .run();
  return { ok: true, session: s };
}

export interface CalendarCell {
  date: string;
  /** projected: from the weekly pattern. rest: no template that weekday.
   *  Otherwise the real sessions.status (planned|in_progress|completed|skipped). */
  status: 'projected' | 'rest' | 'planned' | 'in_progress' | 'completed' | 'skipped';
  /** Set when a template resolves (projected or a real session w/ day). */
  day_template_id: string | null;
  /** True iff this cell came from a real sessions row. */
  real: boolean;
}

/**
 * Pure projection. Given the plan, its schedule, the real sessions in range,
 * and an inclusive [fromDate,toDate] window (capped at 90 days span), emit a
 * calendar cell per date:
 *
 *  - date < today: emit ONLY if a real sessions row exists (use its status).
 *    Never fabricate past rest/missed days.
 *  - date >= today: a real sessions row wins; otherwise weekday(date) ->
 *    schedule.week -> template id. Resolvable id -> 'projected'; null /
 *    missing / dangling id -> 'rest'.
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
  const cells: CalendarCell[] = [];
  for (let i = 0; i <= span; i++) {
    const date = addDays(fromDate, i);
    const real = byDate.get(date);
    const isPast = daySpan(today, date) < 0;
    // A PAST 'planned' session was never executed: logging a set flips a
    // session to in_progress/completed, so a still-'planned' row in the
    // past is a workout that did NOT happen (Claude pre-planned the day,
    // the user did something else). The past calendar shows only what
    // happened, so it VANISHES — same spirit as the 'discarded' carve-out
    // above (#48: "a workout yesterday with no content"). A FUTURE 'planned'
    // (set_planned_session) still wins over the schedule projection. This
    // is mirrored byte-for-byte in CalendarProjection.swift; calendar.test.ts
    // is the contract.
    if (real && !(isPast && real.status === 'planned')) {
      cells.push({
        date,
        status: real.status as CalendarCell['status'],
        day_template_id: real.day_template_id,
        real: true,
      });
      continue;
    }
    if (isPast) continue; // no fabricated past cells (incl. a vanished past-planned)
    const tid = schedule.week[weekdayOf(date)];
    if (tid && resolvable.has(tid)) {
      cells.push({ date, status: 'projected', day_template_id: tid, real: false });
    } else {
      cells.push({ date, status: 'rest', day_template_id: null, real: false });
    }
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
  const schedule = parsePlanMeta(plan.meta).schedule;
  const liveDays = await db
    .prepare('SELECT id FROM day_templates WHERE plan_id = ?1')
    .bind(plan.id)
    .all<{ id: string }>();
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
             raw=excluded.raw,
             synced_at=excluded.synced_at,
             deleted_at=NULL`,
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
  // Done as a single statement excluding the seen ids.
  const seenIds = [...seen];
  const placeholders = seenIds.map((_, i) => `?${i + 4}`).join(',');
  const notInSeen = seenIds.length ? `AND id NOT IN (${placeholders})` : '';
  stmts.push(
    db
      .prepare(
        // Advance synced_at to the deletion time alongside deleted_at:
        // /api/state?events_since= filters `synced_at > cursor`, so a
        // tombstone that kept its old synced_at would never reach an
        // incremental client (it would keep showing the deleted ride).
        `UPDATE external_events
            SET deleted_at = ?3, synced_at = ?3
          WHERE user_id = ?1
            AND deleted_at IS NULL
            AND date >= ?2 AND date <= ?${seenIds.length ? seenIds.length + 4 : 4}
            ${notInSeen}`,
      )
      .bind(userId, today, ts, ...seenIds, newest),
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
             raw=excluded.raw,
             synced_at=excluded.synced_at,
             deleted_at=NULL`,
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
  // left alone (we didn't query them).
  const seenIds = [...seen];
  const placeholders = seenIds.map((_, i) => `?${i + 4}`).join(',');
  const notInSeen = seenIds.length ? `AND id NOT IN (${placeholders})` : '';
  stmts.push(
    db
      .prepare(
        `UPDATE external_activities
            SET deleted_at = ?3, synced_at = ?3
          WHERE user_id = ?1
            AND deleted_at IS NULL
            AND date >= ?2 AND date <= ?${seenIds.length ? seenIds.length + 4 : 4}
            ${notInSeen}`,
      )
      .bind(userId, oldest, ts, ...seenIds, today),
  );

  await db.batch(stmts);

  const cnt = await db
    .prepare(
      `SELECT COUNT(*) AS c FROM external_activities
        WHERE user_id = ?1 AND deleted_at IS NULL
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

/**
 * CONFLICT RULE — authoritative. iOS mirrors this BYTE-FOR-BYTE.
 *
 * Inputs: the set of dates that hold a lift (a real lift session OR a
 * projected/scheduled lift day) and the non-deleted external_events.
 * Soft-deleted events are excluded by the caller and ignored here.
 *
 * For each lift date D, in priority order (first match wins; a date emits at
 * most one DayConflict):
 *
 *  (a) SAME-DAY  → severity "clash":
 *      there exists a non-deleted external_event whose `date` == D.
 *      `conflicts` = the ids of ALL such same-day events.
 *
 *  (b) DAY-BEFORE-HARD  → severity "heavy-next-day":
 *      D itself has no same-day event, AND there exists a non-deleted
 *      external_event E on the immediately following calendar day
 *      (date == D + 1 civil day) that is "hard", where hard means
 *      training_load >= 150 OR planned_duration_sec >= 9000.
 *      `conflicts` = the ids of ALL such hard next-day events.
 *      (Sub-threshold next-day events do NOT flag.)
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
      out.push({ date: d, conflicts: sameDay.map((e) => e.id), severity: 'clash' });
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
  const cal = await getProjectedCalendar(db, userId, fromDate, toDate, today);
  const liftDates = cal
    .filter(
      (c) =>
        c.status === 'projected' ||
        c.status === 'planned' ||
        c.status === 'in_progress' ||
        c.status === 'completed',
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
  return detectConflicts(liftDates, events.results);
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
//     duration_sec, per-exercise top set (exercise name + weight + reps +
//     Epley est_1rm). HIDE session.notes, session.perceived_fatigue, every
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
                e.name AS exercise_name,
                e.unit AS exercise_unit
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
        exercise_name: string;
        exercise_unit: string;
      }>();
    // Aggregate: per (session_id, exercise_id) → highest-est-1RM working
    // set. Ties broken by higher reps (matches the convention of "show me
    // the harder set"). Total set_count is just the row count per session.
    type TopAcc = {
      exercise: string;
      unit: string | null;
      weight: number;
      reps: number;
      est_1rm: number;
    };
    const acc = new Map<string, Map<string, TopAcc>>(); // session_id -> exercise_id -> top
    for (const r of sets.results) {
      setCountBySession.set(r.session_id, (setCountBySession.get(r.session_id) ?? 0) + 1);
      const est = epley(r.weight, r.reps);
      let perSession = acc.get(r.session_id);
      if (!perSession) {
        perSession = new Map();
        acc.set(r.session_id, perSession);
      }
      const cur = perSession.get(r.exercise_id);
      if (
        !cur ||
        est > cur.est_1rm ||
        (est === cur.est_1rm && r.reps > cur.reps)
      ) {
        perSession.set(r.exercise_id, {
          exercise: r.exercise_name,
          unit: r.exercise_unit,
          weight: r.weight,
          reps: r.reps,
          est_1rm: est,
        });
      }
    }
    for (const [sid, perEx] of acc) {
      // Sort top_sets by est_1rm DESC so the "headline" lift renders first.
      const list = [...perEx.values()].sort((a, b) => b.est_1rm - a.est_1rm);
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
        `SELECT DISTINCT date FROM external_activities
          WHERE user_id = ?1
            AND deleted_at IS NULL
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
        `SELECT date, COUNT(*) AS n FROM external_activities
          WHERE user_id = ?1
            AND deleted_at IS NULL
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
