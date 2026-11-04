import { applyD1Migrations, env } from 'cloudflare:test';
import { beforeAll, describe, expect, it, vi } from 'vitest';

import {
  activateIntervalsSourceFence,
  deleteUserAccount,
  ensureOwnerUser,
  exportUserData,
  getMeProfile,
  getUserByIntervalsAthleteId,
  getUserIntervalsCreds,
  listUsersWithIntervalsCreds,
  seedOwnerIntervalsCredsFromEnv,
  setUserIntervalsCreds,
  setUserIntervalsOAuth,
  syncExternalActivities,
  syncExternalEvents,
} from '../src/db';
import { openCredential } from '../src/credentials';
import type { Fetcher } from '../src/intervals';
import type { Env } from '../src/types';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

const ACTIVATED_AT = Date.parse('2037-06-01T12:00:00Z');
const MAX_SAFE = Number.MAX_SAFE_INTEGER;

const testEnv = (overrides: Partial<Env> = {}): Env => ({
  ...(env as unknown as Env),
  INTERVALS_ICU_API_KEY: undefined,
  INTERVALS_ICU_ATHLETE_ID: undefined,
  ...overrides,
});

const emptySuccess: Fetcher = async () =>
  new Response(JSON.stringify([]), {
    status: 200,
    headers: { 'content-type': 'application/json' },
  });

async function addUser(label: string): Promise<string> {
  const id = crypto.randomUUID();
  await env.DB
    .prepare(
      `INSERT INTO users (id,apple_sub,email,display_name,created_at)
       VALUES (?1,?2,NULL,?3,?4)`,
    )
    .bind(id, `p46-sub-${label}-${id}`, `P4.6 ${label}`, ACTIVATED_AT)
    .run();
  return id;
}

async function addApiUser(label: string): Promise<{
  id: string;
  athleteId: string;
  apiKey: string;
}> {
  const id = await addUser(label);
  const athleteId = `p46-athlete-${label}-${id}`;
  const apiKey = `p46-key-${label}-${id}`;
  await setUserIntervalsCreds(env.DB, id, env.CREDENTIAL_ENCRYPTION_KEY, apiKey, athleteId);
  return { id, athleteId, apiKey };
}

async function userState(userId: string): Promise<Record<string, unknown>> {
  const row = (await env.DB
    .prepare('SELECT * FROM users WHERE id = ?1')
    .bind(userId)
    .first<Record<string, unknown>>())!;
  for (const [column, purpose] of [['intervals_api_key', 'intervals-api-key'], ['intervals_oauth_access_token', 'intervals-access-token'], ['intervals_oauth_refresh_token', 'intervals-refresh-token']]) {
    row[column!] = await openCredential(row[column!] as string | null, env.CREDENTIAL_ENCRYPTION_KEY, userId, purpose!);
  }
  return row;
}

function activateBeforeRun(
  db: D1Database,
  sqlNeedle: string,
): { db: D1Database; activated: () => boolean } {
  let didActivate = false;
  return {
    activated: () => didActivate,
    db: new Proxy(db, {
      get(target, property) {
        if (property !== 'prepare') {
          const value = Reflect.get(target, property, target);
          return typeof value === 'function' ? value.bind(target) : value;
        }
        return (sql: string) => {
          const statement = target.prepare(sql);
          if (!sql.includes(sqlNeedle)) return statement;
          return new Proxy(statement, {
            get(statementTarget, statementProperty) {
              if (statementProperty !== 'bind') {
                const value = Reflect.get(statementTarget, statementProperty, statementTarget);
                return typeof value === 'function' ? value.bind(statementTarget) : value;
              }
              return (...values: unknown[]) => {
                const bound = statementTarget.bind(...values);
                return new Proxy(bound, {
                  get(boundTarget, boundProperty) {
                    if (boundProperty === 'run') {
                      return async () => {
                        if (!didActivate) {
                          didActivate = true;
                          await activateIntervalsSourceFence(db, ACTIVATED_AT);
                        }
                        return boundTarget.run();
                      };
                    }
                    const value = Reflect.get(boundTarget, boundProperty, boundTarget);
                    return typeof value === 'function' ? value.bind(boundTarget) : value;
                  },
                });
              };
            },
          });
        };
      },
    }),
  };
}

function activateBeforeFirstBatch(db: D1Database): D1Database {
  let didActivate = false;
  return new Proxy(db, {
    get(target, property) {
      if (property === 'batch') {
        return async <T = unknown>(statements: D1PreparedStatement[]) => {
          if (!didActivate) {
            didActivate = true;
            await activateIntervalsSourceFence(target, ACTIVATED_AT);
          }
          return target.batch<T>(statements);
        };
      }
      const value = Reflect.get(target, property, target);
      return typeof value === 'function' ? value.bind(target) : value;
    },
  });
}

describe('P4.6 inert migration and monotonic activation', () => {
  it('installs disabled with bounded defaults while exact P4 writes remain compatible', async () => {
    expect(
      await env.DB
        .prepare(
          'SELECT singleton, enabled, activated_at FROM intervals_source_fence',
        )
        .first(),
    ).toEqual({ singleton: 1, enabled: 0, activated_at: null });

    const id = await addUser('inactive');
    expect(await userState(id)).toMatchObject({
      intervals_cutover_athlete_id: null,
      intervals_protocol_write_seq: 0,
    });

    // Exact P4 never mentions the new columns. It remains valid until the
    // monotonic activation statement commits.
    await env.DB
      .prepare(
        `UPDATE users
            SET intervals_api_key = 'old-key',
                intervals_athlete_id = 'old-athlete',
                intervals_credential_generation = intervals_credential_generation + 1,
                intervals_events_synced_at = NULL
          WHERE id = ?1`,
      )
      .bind(id)
      .run();
    expect(await getUserIntervalsCreds(env.DB, id, env.CREDENTIAL_ENCRYPTION_KEY)).toMatchObject({
      api_key: 'old-key',
      athlete_id: 'old-athlete',
      credential_generation: 1,
    });
    expect((await listUsersWithIntervalsCreds(env.DB)).map((row) => row.user_id)).toEqual([id]);

    await expect(
      env.DB
        .prepare(
          "UPDATE users SET intervals_cutover_athlete_id='premature' WHERE id=?1",
        )
        .bind(id)
        .run(),
    ).rejects.toThrow(/intervals_source_fence_not_active/);
    await expect(
      env.DB
        .prepare('UPDATE users SET intervals_protocol_write_seq=-1 WHERE id=?1')
        .bind(id)
        .run(),
    ).rejects.toThrow();
    await expect(
      env.DB
        .prepare(`UPDATE users SET intervals_protocol_write_seq=${MAX_SAFE + 1} WHERE id=?1`)
        .bind(id)
        .run(),
    ).rejects.toThrow();
  });

  it('moves all user identities atomically and exposes the same public identity', async () => {
    const api = await addApiUser('api');
    const oauthId = await addUser('oauth');
    const oauthAthlete = `p46-oauth-${oauthId}`;
    await setUserIntervalsOAuth(
      env.DB,
      oauthId,
      env.CREDENTIAL_ENCRYPTION_KEY, 'oauth-access',
      'oauth-refresh',
      ACTIVATED_AT + 10_000,
      oauthAthlete,
    );
    const dormantId = await addUser('dormant');
    await env.DB
      .prepare(
        `UPDATE users
            SET intervals_events_synced_at=11,
                intervals_activities_synced_at=12,
                intervals_events_sync_attempt=3,
                intervals_activities_sync_attempt=4
          WHERE id=?1`,
      )
      .bind(api.id)
      .run();

    const activated = await activateIntervalsSourceFence(env.DB, ACTIVATED_AT);
    expect(activated).toEqual({
      enabled: true,
      activated_at: ACTIVATED_AT,
      activated_user_count: 3,
      activated_connected_count: 2,
    });

    expect(await userState(api.id)).toMatchObject({
      intervals_athlete_id: null,
      intervals_cutover_athlete_id: api.athleteId,
      intervals_api_key: api.apiKey,
      intervals_credential_generation: 2,
      intervals_events_synced_at: null,
      intervals_activities_synced_at: null,
      intervals_events_sync_attempt: 0,
      intervals_activities_sync_attempt: 0,
      intervals_protocol_write_seq: 1,
    });
    expect(await userState(oauthId)).toMatchObject({
      intervals_athlete_id: null,
      intervals_cutover_athlete_id: oauthAthlete,
      intervals_oauth_access_token: 'oauth-access',
      intervals_oauth_refresh_token: 'oauth-refresh',
      intervals_credential_generation: 2,
      intervals_protocol_write_seq: 1,
    });
    expect(await userState(dormantId)).toMatchObject({
      intervals_athlete_id: null,
      intervals_cutover_athlete_id: null,
      intervals_credential_generation: 1,
      intervals_protocol_write_seq: 1,
    });

    expect((await getUserByIntervalsAthleteId(env.DB, api.athleteId))?.id).toBe(api.id);
    expect((await getUserByIntervalsAthleteId(env.DB, oauthAthlete))?.id).toBe(oauthId);
    expect((await getMeProfile(env.DB, api.id, undefined)).intervals).toMatchObject({
      connected: true,
      athlete_id: api.athleteId,
    });
    const exported = await exportUserData(env.DB, api.id);
    expect((exported?.account as Record<string, unknown>).intervals_athlete_id).toBe(
      api.athleteId,
    );
    expect((await listUsersWithIntervalsCreds(env.DB)).map((row) => row.user_id).sort()).toEqual(
      [api.id, oauthId].sort(),
    );

    // Idempotent helper reads the immutable state without replaying the move.
    expect(await activateIntervalsSourceFence(env.DB, ACTIVATED_AT + 1)).toEqual({
      enabled: true,
      activated_at: ACTIVATED_AT,
      activated_user_count: 3,
      activated_connected_count: 2,
    });
    expect((await userState(api.id)).intervals_protocol_write_seq).toBe(1);
  });

  it('rolls back the whole activation on malformed, duplicate, or exhausted rows', async () => {
    const healthy = await addApiUser('healthy');
    const malformed = await addUser('malformed');
    await env.DB
      .prepare("UPDATE users SET intervals_api_key='orphan-key' WHERE id=?1")
      .bind(malformed)
      .run();

    await expect(activateIntervalsSourceFence(env.DB, ACTIVATED_AT)).rejects.toThrow(
      /intervals_source_fence_activation_preflight_failed/,
    );
    expect(
      await env.DB.prepare('SELECT enabled FROM intervals_source_fence').first(),
    ).toEqual({ enabled: 0 });
    expect(await userState(healthy.id)).toMatchObject({
      intervals_athlete_id: healthy.athleteId,
      intervals_cutover_athlete_id: null,
      intervals_protocol_write_seq: 0,
    });

    await env.DB
      .prepare(
        `UPDATE users
            SET intervals_api_key=NULL,
                intervals_credential_generation=${MAX_SAFE}
          WHERE id=?1`,
      )
      .bind(malformed)
      .run();
    await expect(activateIntervalsSourceFence(env.DB, ACTIVATED_AT)).rejects.toThrow(
      /intervals_source_fence_activation_preflight_failed/,
    );
    expect((await userState(healthy.id)).intervals_protocol_write_seq).toBe(0);
  });

  it('rejects duplicate athletes and leaves every row in legacy mode', async () => {
    const first = await addUser('duplicate-a');
    const second = await addUser('duplicate-b');
    for (const id of [first, second]) {
      await env.DB
        .prepare(
          `UPDATE users
              SET intervals_api_key=?2, intervals_athlete_id='duplicate-athlete'
            WHERE id=?1`,
        )
        .bind(id, `key-${id}`)
        .run();
    }

    await expect(activateIntervalsSourceFence(env.DB, ACTIVATED_AT)).rejects.toThrow(
      /intervals_source_fence_duplicate_athlete/,
    );
    expect(
      await env.DB.prepare('SELECT enabled FROM intervals_source_fence').first(),
    ).toEqual({ enabled: 0 });
    for (const id of [first, second]) {
      expect(await userState(id)).toMatchObject({
        intervals_athlete_id: 'duplicate-athlete',
        intervals_cutover_athlete_id: null,
        intervals_protocol_write_seq: 0,
      });
    }
  });

  it('makes the singleton monotonic, undeletable, and fail-closed if damaged', async () => {
    const userId = await addUser('singleton');
    await activateIntervalsSourceFence(env.DB, ACTIVATED_AT);
    await expect(
      env.DB
        .prepare(
          'UPDATE intervals_source_fence SET enabled=0, activated_at=NULL WHERE singleton=1',
        )
        .run(),
    ).rejects.toThrow(/intervals_source_fence_is_monotonic/);
    await expect(
      env.DB.prepare('DELETE FROM intervals_source_fence WHERE singleton=1').run(),
    ).rejects.toThrow(/intervals_source_fence_cannot_be_deleted/);
    await expect(
      env.DB
        .prepare(
          `INSERT OR REPLACE INTO intervals_source_fence
             (singleton,enabled,activated_at,activated_user_count,activated_connected_count)
           VALUES (1,0,NULL,NULL,NULL)`,
        )
        .run(),
    ).rejects.toThrow(/intervals_source_fence_cannot_be_/);

    // Simulate out-of-band schema damage by deliberately removing only the
    // delete guard. Protected updates and account inserts still fail closed.
    await env.DB.prepare('DROP TRIGGER intervals_source_fence_cannot_be_deleted').run();
    await env.DB.prepare('DELETE FROM intervals_source_fence WHERE singleton=1').run();
    await expect(
      env.DB
        .prepare('UPDATE users SET intervals_events_sync_attempt=1 WHERE id=?1')
        .bind(userId)
        .run(),
    ).rejects.toThrow(/intervals_source_fence_missing/);
    await expect(addUser('missing-singleton')).rejects.toThrow(
      /intervals_source_fence_missing/,
    );
  });
});

describe('P4.6 exact old-worker exclusion', () => {
  it('disconnects old cron enumeration and webhook lookup after activation', async () => {
    const member = await addApiUser('old-read');
    await activateIntervalsSourceFence(env.DB, ACTIVATED_AT);

    const oldCron = await env.DB
      .prepare(
        `SELECT id FROM users
          WHERE intervals_athlete_id IS NOT NULL
            AND (intervals_api_key IS NOT NULL OR intervals_oauth_access_token IS NOT NULL)`,
      )
      .all();
    expect(oldCron.results).toEqual([]);
    expect(
      await env.DB
        .prepare('SELECT id FROM users WHERE intervals_athlete_id=?1')
        .bind(member.athleteId)
        .first(),
    ).toBeNull();
    expect((await getUserByIntervalsAthleteId(env.DB, member.athleteId))?.id).toBe(member.id);
  });

  it('fences delayed P4 cache, tombstone, dedup, stamp, refresh, and 401 writes', async () => {
    const member = await addApiUser('old-delayed');
    const oldGeneration = (await getUserIntervalsCreds(env.DB, member.id, env.CREDENTIAL_ENCRYPTION_KEY)).credential_generation;
    const eventId = `intervals:${member.id}:baseline`;
    const intervalsActivityId = `intervals:activity:${member.id}:baseline`;
    const healthkitId = `healthkit:${member.id}:baseline`;
    await env.DB.batch([
      env.DB
        .prepare(
          `INSERT INTO external_events
             (id,user_id,source,external_id,date,kind,title,synced_at)
           VALUES (?1,?2,'intervals','baseline','2037-06-02','ride','baseline',1)`,
        )
        .bind(eventId, member.id),
      env.DB
        .prepare(
          `INSERT INTO external_activities
             (id,user_id,source,external_id,date,kind,name,synced_at,canonical)
           VALUES (?1,?2,'intervals','baseline','2037-05-31','ride','baseline',1,1)`,
        )
        .bind(intervalsActivityId, member.id),
      env.DB
        .prepare(
          `INSERT INTO external_activities
             (id,user_id,source,external_id,date,kind,name,synced_at,canonical)
           VALUES (?1,?2,'healthkit','hk-baseline','2037-05-31','ride','healthkit',1,1)`,
        )
        .bind(healthkitId, member.id),
    ]);

    await activateIntervalsSourceFence(env.DB, ACTIVATED_AT);

    // These predicates are the exact P4 generation guard used by cache
    // upsert/tombstone/dedup writes. Activation advanced the generation in the
    // same statement that hid the legacy athlete identity.
    for (const statement of [
      env.DB
        .prepare(
          `UPDATE external_events SET title='stale-cache'
            WHERE id=?1 AND EXISTS (
              SELECT 1 FROM users
               WHERE id=?2 AND intervals_credential_generation=?3
            )`,
        )
        .bind(eventId, member.id, oldGeneration),
      env.DB
        .prepare(
          `UPDATE external_events SET deleted_at=2, synced_at=2
            WHERE id=?1 AND EXISTS (
              SELECT 1 FROM users
               WHERE id=?2 AND intervals_credential_generation=?3
            )`,
        )
        .bind(eventId, member.id, oldGeneration),
      env.DB
        .prepare(
          `UPDATE external_activities
              SET deleted_at=2, synced_at=2, canonical=0, duplicate_of=?4
            WHERE id=?1 AND EXISTS (
              SELECT 1 FROM users
               WHERE id=?2 AND intervals_credential_generation=?3
            )`,
        )
        .bind(healthkitId, member.id, oldGeneration, intervalsActivityId),
    ]) {
      expect((await statement.run()).meta.changes).toBe(0);
    }

    const oldStamp = await env.DB
      .prepare(
        `UPDATE users SET intervals_events_synced_at=99
          WHERE id=?1
            AND intervals_credential_generation=?2
            AND intervals_api_key=?3
            AND intervals_athlete_id=?4
            AND intervals_oauth_access_token IS NULL`,
      )
      .bind(member.id, oldGeneration, member.apiKey, member.athleteId)
      .run();
    expect(oldStamp.meta.changes).toBe(0);
    const oldRefresh = await env.DB
      .prepare(
        `UPDATE users
            SET intervals_oauth_access_token='stale-refresh',
                intervals_oauth_refresh_token='stale-rotated',
                intervals_oauth_expires_at=99,
                intervals_auth_error_at=NULL
          WHERE id=?1 AND intervals_credential_generation=?2
            AND intervals_athlete_id=?3`,
      )
      .bind(member.id, oldGeneration, member.athleteId)
      .run();
    expect(oldRefresh.meta.changes).toBe(0);
    const old401 = await env.DB
      .prepare(
        `UPDATE users
            SET intervals_api_key=NULL,
                intervals_oauth_access_token=NULL,
                intervals_oauth_refresh_token=NULL,
                intervals_oauth_expires_at=NULL,
                intervals_athlete_id=NULL,
                intervals_auth_error_at=99,
                intervals_credential_generation=intervals_credential_generation+1,
                intervals_events_synced_at=NULL,
                intervals_activities_synced_at=NULL
          WHERE id=?1 AND intervals_credential_generation=?2
            AND intervals_athlete_id=?3`,
      )
      .bind(member.id, oldGeneration, member.athleteId)
      .run();
    expect(old401.meta.changes).toBe(0);

    expect(await userState(member.id)).toMatchObject({
      intervals_cutover_athlete_id: member.athleteId,
      intervals_api_key: member.apiKey,
      intervals_events_synced_at: null,
      intervals_auth_error_at: null,
      intervals_protocol_write_seq: 1,
    });
    expect(await env.DB.prepare('SELECT title, deleted_at FROM external_events WHERE id=?1')
      .bind(eventId)
      .first()).toEqual({ title: 'baseline', deleted_at: null });
    expect(await env.DB.prepare('SELECT canonical, duplicate_of FROM external_activities WHERE id=?1')
      .bind(healthkitId)
      .first()).toEqual({ canonical: 1, duplicate_of: null });
  });

  it('rejects delayed P4 direct connect, callback, and disconnect statements', async () => {
    const member = await addApiUser('old-direct');
    const oldConnect = env.DB
      .prepare(
        `UPDATE users
            SET intervals_api_key=?2,
                intervals_athlete_id=?3,
                intervals_oauth_access_token=NULL,
                intervals_oauth_refresh_token=NULL,
                intervals_oauth_expires_at=NULL,
                intervals_auth_error_at=NULL,
                intervals_credential_generation=intervals_credential_generation+1
          WHERE id=?1`,
      )
      .bind(member.id, 'stale-connect', 'stale-athlete');
    const oldCallback = env.DB
      .prepare(
        `UPDATE users
            SET intervals_oauth_access_token=?2,
                intervals_oauth_refresh_token=?3,
                intervals_oauth_expires_at=?4,
                intervals_athlete_id=?5,
                intervals_api_key=NULL,
                intervals_auth_error_at=NULL,
                intervals_credential_generation=intervals_credential_generation+1
          WHERE id=?1`,
      )
      .bind(member.id, 'stale-oauth', null, null, 'stale-oauth-athlete');
    // intervals_athlete_id is already NULL after activation. SQLite UPDATE OF
    // still fires on the same-NULL assignment and rejects this exact P4
    // disconnect because it does not advance the protocol sequence.
    const oldDisconnect = env.DB
      .prepare(
        `UPDATE users
            SET intervals_api_key=NULL,
                intervals_athlete_id=NULL,
                intervals_oauth_access_token=NULL,
                intervals_oauth_refresh_token=NULL,
                intervals_oauth_expires_at=NULL,
                intervals_auth_error_at=NULL,
                intervals_credential_generation=intervals_credential_generation+1
          WHERE id=?1`,
      )
      .bind(member.id);

    await activateIntervalsSourceFence(env.DB, ACTIVATED_AT);
    for (const statement of [oldConnect, oldCallback, oldDisconnect]) {
      await expect(statement.run()).rejects.toThrow(/intervals_source_fence_/);
    }
    expect(await userState(member.id)).toMatchObject({
      intervals_cutover_athlete_id: member.athleteId,
      intervals_api_key: member.apiKey,
      intervals_protocol_write_seq: 1,
    });
  });

  it('keeps authorized terminal account deletion as an explicit carve-out', async () => {
    const member = await addApiUser('delete');
    await syncExternalEvents(env.DB, testEnv(), {
      userId: member.id,
      fetcher: emptySuccess,
    });
    await activateIntervalsSourceFence(env.DB, ACTIVATED_AT);

    const deleted = await deleteUserAccount(
      env.DB,
      member.id,
      undefined,
      crypto.randomUUID(),
    );
    expect(deleted).toMatchObject({ ok: true });
    expect(
      await env.DB.prepare('SELECT id FROM users WHERE id=?1').bind(member.id).first(),
    ).toBeNull();
    expect(
      await env.DB
        .prepare('SELECT COUNT(*) AS count FROM external_events WHERE user_id=?1')
        .bind(member.id)
        .first(),
    ).toEqual({ count: 0 });
  });
});

describe.each([
  'intervals_athlete_id',
  'intervals_cutover_athlete_id',
  'intervals_api_key',
  'intervals_oauth_access_token',
  'intervals_oauth_refresh_token',
  'intervals_oauth_expires_at',
  'intervals_auth_error_at',
  'intervals_credential_generation',
  'intervals_events_synced_at',
  'intervals_activities_synced_at',
  'intervals_events_sync_attempt',
  'intervals_activities_sync_attempt',
  'intervals_protocol_write_seq',
])('P4.6 protected UPDATE OF %s', (column) => {
  it('requires an exact sequence advance after activation', async () => {
    const member = await addApiUser(`protected-${column}`);
    await activateIntervalsSourceFence(env.DB, ACTIVATED_AT);
    await expect(
      env.DB
        .prepare(`UPDATE users SET ${column}=${column} WHERE id=?1`)
        .bind(member.id)
        .run(),
    ).rejects.toThrow(/intervals_source_fence_sequence_required/);
    expect((await userState(member.id)).intervals_protocol_write_seq).toBe(1);
  });
});

describe('P4.6 dual-mode current Worker', () => {
  it('routes connect, OAuth callback, and disconnect through the active row mode at execution', async () => {
    const connectId = await addUser('race-connect');
    const connectRace = activateBeforeRun(env.DB, 'SET intervals_api_key = ?2');
    await setUserIntervalsCreds(
      connectRace.db,
      connectId,
      env.CREDENTIAL_ENCRYPTION_KEY, 'race-key',
      'race-athlete',
    );
    expect(connectRace.activated()).toBe(true);
    expect(await userState(connectId)).toMatchObject({
      intervals_athlete_id: null,
      intervals_cutover_athlete_id: 'race-athlete',
      intervals_api_key: 'race-key',
      intervals_credential_generation: 2,
      intervals_protocol_write_seq: 2,
    });

    const callbackId = await addUser('race-callback');
    const callbackRace = activateBeforeRun(env.DB, 'SET intervals_oauth_access_token = ?2');
    await setUserIntervalsOAuth(
      callbackRace.db,
      callbackId,
      env.CREDENTIAL_ENCRYPTION_KEY, 'callback-access',
      'callback-refresh',
      ACTIVATED_AT + 1000,
      'callback-athlete',
    );
    expect(await userState(callbackId)).toMatchObject({
      intervals_athlete_id: null,
      intervals_cutover_athlete_id: 'callback-athlete',
      intervals_oauth_access_token: 'callback-access',
      intervals_credential_generation: 1,
      intervals_protocol_write_seq: 1,
    });

    const disconnect = await addApiUser('race-disconnect');
    const disconnectRace = activateBeforeRun(env.DB, 'SET intervals_api_key = ?2');
    await setUserIntervalsCreds(disconnectRace.db, disconnect.id, env.CREDENTIAL_ENCRYPTION_KEY, null, null);
    expect(await userState(disconnect.id)).toMatchObject({
      intervals_athlete_id: null,
      intervals_cutover_athlete_id: null,
      intervals_api_key: null,
      intervals_credential_generation: 2,
      intervals_protocol_write_seq: 2,
    });
  });

  it('keeps an auth clear that crosses activation from clearing the moved credential', async () => {
    const member = await addApiUser('race-auth-clear');
    const provider = vi.fn<Fetcher>(async () => new Response('unauthorized', { status: 401 }));
    const result = await syncExternalEvents(
      activateBeforeFirstBatch(env.DB),
      testEnv(),
      { userId: member.id, fetcher: provider },
    );

    expect(result).toMatchObject({ status: 'superseded' });
    expect(provider).toHaveBeenCalledTimes(1);
    expect(await userState(member.id)).toMatchObject({
      intervals_athlete_id: null,
      intervals_cutover_athlete_id: member.athleteId,
      intervals_api_key: member.apiKey,
      intervals_auth_error_at: null,
      intervals_protocol_write_seq: 1,
    });
  });

  it('runs both caches and every protected lifecycle mutation after activation', async () => {
    const member = await addApiUser('active');
    await activateIntervalsSourceFence(env.DB, ACTIVATED_AT);
    const before = await userState(member.id);

    await syncExternalEvents(env.DB, testEnv(), {
      userId: member.id,
      fetcher: emptySuccess,
      syncedAt: ACTIVATED_AT + 1,
    });
    await syncExternalActivities(env.DB, testEnv(), {
      userId: member.id,
      fetcher: emptySuccess,
      syncedAt: ACTIVATED_AT + 2,
    });
    expect(await userState(member.id)).toMatchObject({
      intervals_cutover_athlete_id: member.athleteId,
      intervals_events_sync_attempt: 1,
      intervals_activities_sync_attempt: 1,
      intervals_events_synced_at: ACTIVATED_AT + 1,
      intervals_activities_synced_at: ACTIVATED_AT + 2,
      // activation + (claim, stamp) for each of the two caches
      intervals_protocol_write_seq:
        Number(before.intervals_protocol_write_seq) + 4,
    });

    await setUserIntervalsOAuth(
      env.DB,
      member.id,
      env.CREDENTIAL_ENCRYPTION_KEY, 'active-oauth',
      null,
      null,
      member.athleteId,
    );
    const afterOauth = await userState(member.id);
    expect(afterOauth).toMatchObject({
      intervals_athlete_id: null,
      intervals_cutover_athlete_id: member.athleteId,
      intervals_api_key: null,
      intervals_oauth_access_token: 'active-oauth',
      intervals_events_sync_attempt: 0,
      intervals_activities_sync_attempt: 0,
    });
    expect(afterOauth.intervals_protocol_write_seq).toBe(
      Number(before.intervals_protocol_write_seq) + 5,
    );

    await setUserIntervalsCreds(env.DB, member.id, env.CREDENTIAL_ENCRYPTION_KEY, null, null);
    expect(await userState(member.id)).toMatchObject({
      intervals_cutover_athlete_id: null,
      intervals_oauth_access_token: null,
      intervals_protocol_write_seq:
        Number(before.intervals_protocol_write_seq) + 6,
    });
  });

  it('persists an OAuth refresh and completes the sync after activation', async () => {
    const memberId = await addUser('active-refresh');
    await setUserIntervalsOAuth(
      env.DB,
      memberId,
      env.CREDENTIAL_ENCRYPTION_KEY, 'old-access',
      'old-refresh',
      null,
      'active-refresh-athlete',
    );
    await activateIntervalsSourceFence(env.DB, ACTIVATED_AT);

    let eventCalls = 0;
    const provider = vi.fn<Fetcher>(async (url) => {
      if (url.includes('/oauth/token')) {
        return new Response(
          JSON.stringify({
            access_token: 'new-access',
            refresh_token: 'new-refresh',
          }),
          {
            status: 200,
            headers: { 'content-type': 'application/json' },
          },
        );
      }
      eventCalls += 1;
      return eventCalls === 1
        ? new Response('{}', { status: 401 })
        : new Response('[]', {
            status: 200,
            headers: { 'content-type': 'application/json' },
          });
    });

    const result = await syncExternalEvents(
      env.DB,
      testEnv({
        INTERVALS_OAUTH_CLIENT_ID: 'client-id',
        INTERVALS_OAUTH_CLIENT_SECRET: 'client-secret',
      }),
      {
        userId: memberId,
        fetcher: provider,
        syncedAt: ACTIVATED_AT + 1,
      },
    );

    expect(result).toMatchObject({ status: 'ok', synced: 0 });
    expect(provider).toHaveBeenCalledTimes(3);
    expect(await userState(memberId)).toMatchObject({
      intervals_athlete_id: null,
      intervals_cutover_athlete_id: 'active-refresh-athlete',
      intervals_oauth_access_token: 'new-access',
      intervals_oauth_refresh_token: 'new-refresh',
      intervals_auth_error_at: null,
      intervals_credential_generation: 2,
      // activation + claim + refresh + success stamp
      intervals_protocol_write_seq: 4,
    });
  });

  it('clears a rejected API credential and records the audit after activation', async () => {
    const member = await addApiUser('active-401');
    await activateIntervalsSourceFence(env.DB, ACTIVATED_AT);
    const provider = vi.fn<Fetcher>(async () =>
      new Response('unauthorized', { status: 401 }),
    );

    const result = await syncExternalEvents(env.DB, testEnv(), {
      userId: member.id,
      fetcher: provider,
    });

    expect(result).toMatchObject({ status: 'fetch_failed' });
    expect(result.detail).toContain('reauth_required');
    expect(provider).toHaveBeenCalledTimes(1);
    const state = await userState(member.id);
    expect(state).toMatchObject({
      intervals_athlete_id: null,
      intervals_cutover_athlete_id: null,
      intervals_api_key: null,
      intervals_oauth_access_token: null,
      intervals_credential_generation: 3,
      intervals_events_sync_attempt: 0,
      intervals_activities_sync_attempt: 0,
      // activation + claim + auth clear
      intervals_protocol_write_seq: 3,
    });
    expect(typeof state.intervals_auth_error_at).toBe('number');
    expect(
      await env.DB
        .prepare(
          `SELECT COUNT(*) AS count FROM audit_log
            WHERE user_id=?1 AND tool='intervals_auth_error'`,
        )
        .bind(member.id)
        .first(),
    ).toEqual({ count: 1 });
  });

  it('seeds an env-only owner before activation and keeps it connected afterward', async () => {
    const owner = await ensureOwnerUser(env.DB, undefined);
    if (!owner) throw new Error('expected owner');
    const seeded = await seedOwnerIntervalsCredsFromEnv(
      env.DB,
      'env-key',
      'env-athlete',
      undefined, env.CREDENTIAL_ENCRYPTION_KEY,
    );
    expect(seeded).toHaveLength(1);
    expect(await userState(owner.id)).toMatchObject({
      intervals_athlete_id: 'env-athlete',
      intervals_cutover_athlete_id: null,
      intervals_credential_generation: 1,
      intervals_protocol_write_seq: 0,
    });

    await activateIntervalsSourceFence(env.DB, ACTIVATED_AT);
    expect(await userState(owner.id)).toMatchObject({
      intervals_athlete_id: null,
      intervals_cutover_athlete_id: 'env-athlete',
      intervals_api_key: 'env-key',
      intervals_credential_generation: 2,
      intervals_protocol_write_seq: 1,
    });

    const repeated = await seedOwnerIntervalsCredsFromEnv(
      env.DB,
      'must-not-replace',
      'must-not-replace-athlete',
      undefined, env.CREDENTIAL_ENCRYPTION_KEY,
    );
    expect(repeated).toHaveLength(1);
    expect(await userState(owner.id)).toMatchObject({
      intervals_athlete_id: null,
      intervals_cutover_athlete_id: 'env-athlete',
      intervals_api_key: 'env-key',
      intervals_credential_generation: 2,
      intervals_protocol_write_seq: 1,
    });

    // Exact P4's generation-zero env seed is now a safe no-op.
    const oldSeed = await env.DB
      .prepare(
        `UPDATE users
            SET intervals_api_key='old-env-key',
                intervals_athlete_id='old-env-athlete',
                intervals_credential_generation=intervals_credential_generation+1
          WHERE id=?1
            AND intervals_api_key IS NULL
            AND intervals_oauth_access_token IS NULL
            AND intervals_athlete_id IS NULL
            AND intervals_auth_error_at IS NULL
            AND intervals_credential_generation=0`,
      )
      .bind(owner.id)
      .run();
    expect(oldSeed.meta.changes).toBe(0);
  });

  it('does not resurrect an old-worker disconnect that activates before its audit', async () => {
    const owner = await ensureOwnerUser(env.DB, undefined);
    if (!owner) throw new Error('expected owner');
    await seedOwnerIntervalsCredsFromEnv(
      env.DB,
      'env-key',
      'env-athlete',
      undefined, env.CREDENTIAL_ENCRYPTION_KEY,
    );

    // Exact P4 commits the credential row and the iOS audit separately. Pause
    // in that gap, activate, and let the new cron's seed path run.
    await env.DB
      .prepare(
        `UPDATE users
            SET intervals_api_key=NULL,
                intervals_athlete_id=NULL,
                intervals_oauth_access_token=NULL,
                intervals_oauth_refresh_token=NULL,
                intervals_oauth_expires_at=NULL,
                intervals_auth_error_at=NULL,
                intervals_credential_generation=intervals_credential_generation+1,
                intervals_events_synced_at=NULL,
                intervals_activities_synced_at=NULL,
                intervals_events_sync_attempt=0,
                intervals_activities_sync_attempt=0
          WHERE id=?1`,
      )
      .bind(owner.id)
      .run();
    await activateIntervalsSourceFence(env.DB, ACTIVATED_AT);
    await seedOwnerIntervalsCredsFromEnv(
      env.DB,
      'must-not-resurrect',
      'must-not-resurrect-athlete',
      undefined, env.CREDENTIAL_ENCRYPTION_KEY,
    );
    await env.DB
      .prepare(
        `INSERT INTO audit_log (id,user_id,actor,tool,args,result,created_at)
         VALUES (?1,?2,'ios','set_intervals_creds','{}','disconnected',?3)`,
      )
      .bind(crypto.randomUUID(), owner.id, ACTIVATED_AT + 1)
      .run();

    expect(await userState(owner.id)).toMatchObject({
      intervals_athlete_id: null,
      intervals_cutover_athlete_id: null,
      intervals_api_key: null,
      intervals_credential_generation: 3,
      intervals_protocol_write_seq: 1,
    });
  });

  it('retains intentional-disconnect and auth-error gates for active env seeding', async () => {
    const touched = await addUser('touched-owner');
    await env.DB
      .prepare(
        `INSERT INTO audit_log (id,user_id,actor,tool,args,result,created_at)
         VALUES (?1,?2,'ios','set_intervals_creds','{}','disconnected',?3)`,
      )
      .bind(crypto.randomUUID(), touched, ACTIVATED_AT)
      .run();
    await activateIntervalsSourceFence(env.DB, ACTIVATED_AT);

    await seedOwnerIntervalsCredsFromEnv(
      env.DB,
      'must-not-seed',
      'must-not-seed-athlete',
      undefined, env.CREDENTIAL_ENCRYPTION_KEY,
    );
    expect(await userState(touched)).toMatchObject({
      intervals_cutover_athlete_id: null,
      intervals_api_key: null,
      intervals_credential_generation: 1,
      intervals_protocol_write_seq: 1,
    });
  });

  it('preserves D1 write accounting and uses the effective-athlete index', async () => {
    const member = await addApiUser('accounting');
    await activateIntervalsSourceFence(env.DB, ACTIVATED_AT);
    const observed: Array<{ rows_written?: number }> = [];
    const observer = new Proxy(env.DB, {
      get(target, property) {
        if (property !== 'prepare') {
          const value = Reflect.get(target, property, target);
          return typeof value === 'function' ? value.bind(target) : value;
        }
        return (sql: string) => {
          const statement = target.prepare(sql);
          return new Proxy(statement, {
            get(statementTarget, statementProperty) {
              if (statementProperty !== 'bind') {
                const value = Reflect.get(statementTarget, statementProperty, statementTarget);
                return typeof value === 'function' ? value.bind(statementTarget) : value;
              }
              return (...values: unknown[]) => {
                const bound = statementTarget.bind(...values);
                return new Proxy(bound, {
                  get(boundTarget, boundProperty) {
                    if (boundProperty === 'first') {
                      return async <T>() => {
                        const result = await boundTarget.run<T>();
                        observed.push(result.meta);
                        return (result.results[0] as T | undefined) ?? null;
                      };
                    }
                    if (boundProperty === 'run') {
                      return async <T>() => {
                        const result = await boundTarget.run<T>();
                        observed.push(result.meta);
                        return result;
                      };
                    }
                    const value = Reflect.get(boundTarget, boundProperty, boundTarget);
                    return typeof value === 'function' ? value.bind(boundTarget) : value;
                  },
                });
              };
            },
          });
        };
      },
    });
    await syncExternalEvents(observer, testEnv(), {
      userId: member.id,
      fetcher: emptySuccess,
      syncedAt: ACTIVATED_AT + 1,
    });
    expect(observed.reduce((sum, meta) => sum + (meta.rows_written ?? 0), 0)).toBe(2);

    const plan = await env.DB
      .prepare(
        `EXPLAIN QUERY PLAN
         SELECT id FROM users
          WHERE COALESCE(intervals_cutover_athlete_id, intervals_athlete_id)=?1`,
      )
      .bind(member.athleteId)
      .all<{ detail: string }>();
    expect(plan.results.map((row) => row.detail).join('\n')).toMatch(
      /ix_users_intervals_effective_athlete/,
    );
    const indexes = await env.DB
      .prepare("SELECT name, sql FROM sqlite_master WHERE type='index' AND tbl_name='users'")
      .all<{ name: string; sql: string | null }>();
    expect(indexes.results.map((row) => row.sql ?? '').join('\n')).not.toMatch(
      /intervals_(events|activities)_sync_attempt|intervals_protocol_write_seq/,
    );
  });
});
