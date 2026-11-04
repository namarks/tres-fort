import { sealCredential } from '../src/credentials';
import { applyD1Migrations, env } from 'cloudflare:test';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  createD1UsageObserver,
  ensureOwnerUser,
  getUserIntervalsCreds,
  setUserIntervalsCreds,
  setUserIntervalsOAuth,
  syncExternalActivities,
  syncExternalEvents,
} from '../src/db';
import { runIntervalsCron } from '../src/index';
import type { Fetcher } from '../src/intervals';
import type { Env } from '../src/types';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

beforeEach(async () => {
  // Keep cron enumeration local to each test without deleting account rows
  // that other suites may have created in the shared Workers test runtime.
  await env.DB.prepare(
    `UPDATE users
        SET intervals_api_key = NULL,
            intervals_oauth_access_token = NULL,
            intervals_oauth_refresh_token = NULL,
            intervals_oauth_expires_at = NULL,
            intervals_athlete_id = NULL,
            intervals_auth_error_at = NULL,
            intervals_credential_generation = 0,
            intervals_events_synced_at = NULL,
            intervals_activities_synced_at = NULL,
            intervals_events_sync_attempt = 0,
            intervals_activities_sync_attempt = 0`,
  ).run();
});

afterEach(() => {
  vi.restoreAllMocks();
});

const TICK = Date.parse('2036-05-18T12:00:00Z');

const testEnv = (): Env => ({
  ...(env as unknown as Env),
  // P4 tests provision explicit per-member credentials. Disabling the legacy
  // env pair here keeps owner-seeding out of write-count assertions.
  INTERVALS_ICU_API_KEY: undefined,
  INTERVALS_ICU_ATHLETE_ID: undefined,
});

async function connectedMember(
  label: string,
  freshness: { events?: number | null; activities?: number | null } = {},
): Promise<{ id: string; athleteId: string; apiKey: string }> {
  const id = crypto.randomUUID();
  const athleteId = `p4-athlete-${label}-${id}`;
  const apiKey = `p4-key-${label}-${id}`;
  await env.DB.prepare(
    `INSERT INTO users
       (id,apple_sub,email,display_name,created_at,intervals_api_key,
        intervals_athlete_id,intervals_events_synced_at,
        intervals_activities_synced_at)
     VALUES (?1,?2,NULL,?3,?4,?5,?6,?7,?8)`,
  )
    .bind(
      id,
      `p4-sub-${id}`,
      `P4 ${label}`,
      TICK,
      apiKey,
      athleteId,
      freshness.events ?? null,
      freshness.activities ?? null,
    )
    .run();
  return { id, athleteId, apiKey };
}

const jsonSuccess = (rows: unknown[]): Fetcher => async () =>
  new Response(JSON.stringify(rows), {
    status: 200,
    headers: { 'content-type': 'application/json' },
  });

const emptySuccess: Fetcher = jsonSuccess([]);

const plannedEvent = (id: string, title: string) => ({
  id,
  category: 'WORKOUT',
  type: 'Ride',
  start_date_local: '2036-05-18T08:00:00',
  name: title,
  moving_time: 3600,
  icu_training_load: 50,
});

const completedActivity = (id: string, name: string) => ({
  id,
  type: 'Ride',
  start_date_local: '2036-05-18T08:00:30',
  name,
  moving_time: 3600,
  elapsed_time: 3700,
  distance: 20_000,
  icu_training_load: 50,
});

async function externalRows(
  table: 'external_events' | 'external_activities',
  userId: string,
): Promise<Record<string, unknown>[]> {
  const rows = await env.DB.prepare(
    `SELECT * FROM ${table} WHERE user_id = ?1 ORDER BY id`,
  )
    .bind(userId)
    .all<Record<string, unknown>>();
  return rows.results;
}

async function freshness(userId: string): Promise<{
  events: number | null;
  activities: number | null;
}> {
  const row = await env.DB.prepare(
    `SELECT intervals_events_synced_at AS events,
            intervals_activities_synced_at AS activities
       FROM users WHERE id = ?1`,
  )
    .bind(userId)
    .first<{ events: number | null; activities: number | null }>();
  return row!;
}

async function syncAttempts(userId: string): Promise<{
  events: number;
  activities: number;
}> {
  const row = await env.DB.prepare(
    `SELECT intervals_events_sync_attempt AS events,
            intervals_activities_sync_attempt AS activities
       FROM users WHERE id = ?1`,
  )
    .bind(userId)
    .first<{ events: number; activities: number }>();
  return row!;
}

async function intervalsUserState(userId: string): Promise<Record<string, unknown>> {
  return (await env.DB.prepare('SELECT * FROM users WHERE id = ?1')
    .bind(userId)
    .first<Record<string, unknown>>())!;
}

async function authAuditCount(userId: string): Promise<number> {
  const row = await env.DB.prepare(
    "SELECT COUNT(*) AS c FROM audit_log WHERE user_id = ?1 AND tool = 'intervals_auth_error'",
  )
    .bind(userId)
    .first<{ c: number }>();
  return row?.c ?? 0;
}

/** Throw only when P4 tries to stamp one member's events success. */
function failEventsStampFor(db: D1Database, userId: string): D1Database {
  return new Proxy(db, {
    get(target, property) {
      if (property !== 'prepare') {
        const value = Reflect.get(target, property, target);
        return typeof value === 'function' ? value.bind(target) : value;
      }
      return (sql: string) => {
        const statement = target.prepare(sql);
        if (!sql.includes('SET intervals_events_synced_at = CASE')) return statement;
        return new Proxy(statement, {
          get(statementTarget, statementProperty) {
            if (statementProperty !== 'bind') {
              const value = Reflect.get(statementTarget, statementProperty, statementTarget);
              return typeof value === 'function' ? value.bind(statementTarget) : value;
            }
            return (...values: unknown[]) => {
              const bound = statementTarget.bind(...values);
              if (values[0] !== userId) return bound;
              return new Proxy(bound, {
                get(boundTarget, boundProperty) {
                  if (boundProperty === 'run') {
                    return async () => {
                      throw new Error('forced D1 freshness failure');
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
}

/** Change credentials after dedup has read its candidates but before it writes. */
function supersedeAfterHealthKitRead(
  db: D1Database,
  changeIdentity: () => Promise<void>,
): D1Database {
  let changed = false;
  return new Proxy(db, {
    get(target, property) {
      if (property !== 'prepare') {
        const value = Reflect.get(target, property, target);
        return typeof value === 'function' ? value.bind(target) : value;
      }
      return (sql: string) => {
        const statement = target.prepare(sql);
        if (!sql.includes("source = 'healthkit'")) return statement;
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
                  if (boundProperty === 'all') {
                    return async <T>() => {
                      const result = await boundTarget.all<T>();
                      if (!changed) {
                        changed = true;
                        await changeIdentity();
                      }
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
}

describe('P4 intervals cron routing and freshness', () => {
  it('skips a cache fresh within two scheduled intervals while polling the other cache', async () => {
    const member = await connectedMember('split');
    // The webhook and manual MCP routes call this same service function. Its
    // success stamp must make only the events cache fresh for the next cron.
    await syncExternalEvents(env.DB, testEnv(), {
      userId: member.id,
      fetcher: emptySuccess,
      syncedAt: TICK - 60 * 60 * 1000,
    });
    const calls: string[] = [];
    const fetcher: Fetcher = async (input) => {
      calls.push(input);
      return emptySuccess(input);
    };

    const result = await runIntervalsCron(env.DB, testEnv(), TICK, { fetcher });

    expect(result).toMatchObject({ events_polled: 0, activities_polled: 1 });
    expect(calls).toHaveLength(1);
    expect(calls[0]).toContain('/activities?');
    const after = await freshness(member.id);
    expect(after.events).toBe(TICK - 60 * 60 * 1000);
    expect(after.activities).not.toBeNull();
  });

  it('treats a stamp exactly two intervals old as fresh using scheduledTime', async () => {
    await connectedMember('cutoff', {
      events: TICK - 2 * 60 * 60 * 1000,
      activities: TICK - 2 * 60 * 60 * 1000,
    });
    const fetcher = vi.fn(emptySuccess);

    const result = await runIntervalsCron(env.DB, testEnv(), TICK, { fetcher });

    expect(fetcher).not.toHaveBeenCalled();
    expect(result).toMatchObject({ events_polled: 0, activities_polled: 0 });
  });

  it('a Retry-After-bearing 429 suppresses that member second cache and stamps neither', async () => {
    const member = await connectedMember('limited');
    const fetcher = vi.fn<Fetcher>(async () =>
      new Response('rate limited', {
        status: 429,
        headers: { 'Retry-After': '120' },
      }),
    );
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => undefined);
    const info = vi.spyOn(console, 'log').mockImplementation(() => undefined);

    const result = await runIntervalsCron(env.DB, testEnv(), TICK, { fetcher });

    expect(fetcher).toHaveBeenCalledTimes(1);
    expect(result).toMatchObject({
      failed: true,
      events_polled: 1,
      activities_polled: 0,
      rate_limited_members: 1,
    });
    expect(await freshness(member.id)).toEqual({ events: null, activities: null });
    expect(await syncAttempts(member.id)).toEqual({ events: 1, activities: 0 });
    const logged = JSON.stringify(warn.mock.calls);
    const allLogs = logged + JSON.stringify(info.mock.calls);
    expect(allLogs).not.toContain(member.id);
    expect(allLogs).not.toContain(member.athleteId);
    expect(allLogs).not.toContain(member.apiKey);
  });

  it('isolates an unexpected member D1 exception so another member still completes', async () => {
    const memberA = await connectedMember('throws');
    const memberB = await connectedMember('continues');
    const fetcher = vi.fn(emptySuccess);
    const error = vi.spyOn(console, 'error').mockImplementation(() => undefined);

    const result = await runIntervalsCron(
      failEventsStampFor(env.DB, memberA.id),
      testEnv(),
      TICK,
      { fetcher },
    );

    expect(result.failed).toBe(true);
    expect(await freshness(memberB.id)).toEqual({
      events: expect.any(Number),
      activities: expect.any(Number),
    });
    const logged = JSON.stringify(error.mock.calls);
    expect(logged).not.toContain(memberA.id);
    expect(logged).not.toContain(memberA.athleteId);
    expect(logged).not.toContain(memberA.apiKey);
  });

  it('bounds member concurrency at four and awaits every provider call', async () => {
    for (let index = 0; index < 6; index += 1) {
      await connectedMember(`concurrency-${index}`);
    }
    let active = 0;
    let maximum = 0;
    let calls = 0;
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    const fetcher: Fetcher = async () => {
      calls += 1;
      active += 1;
      maximum = Math.max(maximum, active);
      await gate;
      active -= 1;
      return new Response(JSON.stringify([]), { status: 200 });
    };

    const running = runIntervalsCron(env.DB, testEnv(), TICK, { fetcher });
    await vi.waitFor(() => expect(calls).toBe(4));
    expect(maximum).toBe(4);
    release();
    const result = await running;

    expect(calls).toBe(12);
    expect(result.provider_calls).toBe(12);
    expect(active).toBe(0);
    expect(maximum).toBeLessThanOrEqual(4);
  });

  it('charges claim plus freshness for success, claim only for failure, and nothing for a skip', async () => {
    const member = await connectedMember('billing', {
      events: null,
      activities: TICK,
    });
    const executed = createD1UsageObserver(env.DB);
    await runIntervalsCron(executed.db, testEnv(), TICK, { fetcher: emptySuccess });
    expect(executed.usage.rows_written).toBe(2);
    expect((await freshness(member.id)).events).not.toBeNull();

    const failed = createD1UsageObserver(env.DB);
    await syncExternalEvents(failed.db, testEnv(), {
      userId: member.id,
      fetcher: async () => new Response('upstream', { status: 500 }),
    });
    expect(failed.usage.rows_written).toBe(1);

    await env.DB.prepare(
      `UPDATE users
          SET intervals_events_synced_at = ?2,
              intervals_activities_synced_at = ?2
        WHERE id = ?1`,
    )
      .bind(member.id, TICK)
      .run();
    const skipped = createD1UsageObserver(env.DB);
    const fetcher = vi.fn(emptySuccess);
    await runIntervalsCron(skipped.db, testEnv(), TICK, { fetcher });
    expect(fetcher).not.toHaveBeenCalled();
    expect(skipped.usage.rows_written).toBe(0);
  });
});

describe('P4 shared success stamps and credential lifecycle', () => {
  it('stamps only the successfully reconciled cache, strictly monotonically', async () => {
    const member = await connectedMember('shared-stamp');
    await syncExternalEvents(env.DB, testEnv(), {
      userId: member.id,
      fetcher: emptySuccess,
      syncedAt: 100,
    });
    expect(await freshness(member.id)).toEqual({ events: 100, activities: null });

    await syncExternalEvents(env.DB, testEnv(), {
      userId: member.id,
      fetcher: emptySuccess,
      syncedAt: 100,
    });
    expect(await freshness(member.id)).toEqual({ events: 101, activities: null });

    await syncExternalActivities(env.DB, testEnv(), {
      userId: member.id,
      fetcher: emptySuccess,
      syncedAt: 90,
    });
    expect(await freshness(member.id)).toEqual({ events: 101, activities: 90 });
  });

  it('never stamps a disabled or failed fetch', async () => {
    const member = await connectedMember('failed-stamp');
    await syncExternalEvents(env.DB, testEnv(), {
      userId: member.id,
      fetcher: async () => new Response('upstream', { status: 500 }),
    });
    await setUserIntervalsCreds(env.DB, member.id, env.CREDENTIAL_ENCRYPTION_KEY, null, null);
    await syncExternalActivities(env.DB, testEnv(), {
      userId: member.id,
      fetcher: emptySuccess,
    });
    expect(await freshness(member.id)).toEqual({ events: null, activities: null });
  });

  it('resets stamps and attempts on generation changes while preserving same identity', async () => {
    const member = await connectedMember('identity', { events: 10, activities: 20 });
    await env.DB.prepare('UPDATE users SET intervals_api_key=?1 WHERE id=?2')
      .bind(await sealCredential(member.apiKey, env.CREDENTIAL_ENCRYPTION_KEY, member.id, 'intervals-api-key'), member.id).run();
    await env.DB.prepare(
      `UPDATE users SET intervals_events_sync_attempt = 7,
                        intervals_activities_sync_attempt = 8
        WHERE id = ?1`,
    )
      .bind(member.id)
      .run();

    await setUserIntervalsCreds(env.DB, member.id, env.CREDENTIAL_ENCRYPTION_KEY, member.apiKey, member.athleteId);
    expect(await freshness(member.id)).toEqual({ events: 10, activities: 20 });
    expect(await syncAttempts(member.id)).toEqual({ events: 7, activities: 8 });
    expect((await getUserIntervalsCreds(env.DB, member.id, env.CREDENTIAL_ENCRYPTION_KEY)).credential_generation).toBe(0);

    await setUserIntervalsCreds(env.DB, member.id, env.CREDENTIAL_ENCRYPTION_KEY, 'replacement-key', member.athleteId);
    expect(await freshness(member.id)).toEqual({ events: null, activities: null });
    expect(await syncAttempts(member.id)).toEqual({ events: 0, activities: 0 });
    expect((await getUserIntervalsCreds(env.DB, member.id, env.CREDENTIAL_ENCRYPTION_KEY)).credential_generation).toBe(1);

    await env.DB.prepare(
      `UPDATE users SET intervals_events_sync_attempt = 3,
                        intervals_activities_sync_attempt = 4
        WHERE id = ?1`,
    )
      .bind(member.id)
      .run();
    await setUserIntervalsCreds(env.DB, member.id, env.CREDENTIAL_ENCRYPTION_KEY, 'replacement-key', member.athleteId);
    expect(await syncAttempts(member.id)).toEqual({ events: 3, activities: 4 });
    expect((await getUserIntervalsCreds(env.DB, member.id, env.CREDENTIAL_ENCRYPTION_KEY)).credential_generation).toBe(1);

    await env.DB.prepare(
      `UPDATE users SET intervals_events_synced_at = 30,
                        intervals_activities_synced_at = 40
        WHERE id = ?1`,
    )
      .bind(member.id)
      .run();
    await setUserIntervalsCreds(env.DB, member.id, env.CREDENTIAL_ENCRYPTION_KEY, null, null);
    expect(await freshness(member.id)).toEqual({ events: null, activities: null });
    expect(await syncAttempts(member.id)).toEqual({ events: 0, activities: 0 });
    expect((await getUserIntervalsCreds(env.DB, member.id, env.CREDENTIAL_ENCRYPTION_KEY)).credential_generation).toBe(2);

    await setUserIntervalsCreds(env.DB, member.id, env.CREDENTIAL_ENCRYPTION_KEY, null, null);
    expect((await getUserIntervalsCreds(env.DB, member.id, env.CREDENTIAL_ENCRYPTION_KEY)).credential_generation).toBe(3);
  });

  it('keeps every event cache byte unchanged when replacement or disconnect wins first', async () => {
    for (const action of ['replace', 'disconnect'] as const) {
      const member = await connectedMember(`api-race-${action}`, {
        events: 10,
        activities: 20,
      });
      await syncExternalEvents(env.DB, testEnv(), {
        userId: member.id,
        today: '2036-05-18',
        fetcher: jsonSuccess([
          plannedEvent('kept', 'baseline kept'),
          plannedEvent('would-tombstone', 'baseline omitted later'),
        ]),
      });
      const cacheBefore = await externalRows('external_events', member.id);
      const fetcher: Fetcher = async () => {
        await setUserIntervalsCreds(
          env.DB,
          member.id,
          env.CREDENTIAL_ENCRYPTION_KEY, action === 'replace' ? `new-${member.apiKey}` : null,
          action === 'replace' ? member.athleteId : null,
        );
        return new Response(
          JSON.stringify([
            plannedEvent('kept', 'stale overwrite'),
            plannedEvent('stale-insert', 'must not exist'),
          ]),
          { status: 200 },
        );
      };

      const result = await syncExternalEvents(env.DB, testEnv(), {
        userId: member.id,
        today: '2036-05-18',
        fetcher,
        syncedAt: 30,
      });

      expect(result.status).toBe('superseded');
      expect(await externalRows('external_events', member.id)).toEqual(cacheBefore);
      expect(await freshness(member.id)).toEqual({ events: null, activities: null });
      expect(await getUserIntervalsCreds(env.DB, member.id, env.CREDENTIAL_ENCRYPTION_KEY)).toMatchObject(
        action === 'replace'
          ? { api_key: `new-${member.apiKey}`, athlete_id: member.athleteId }
          : { api_key: null, athlete_id: null },
      );
    }
  });

  it('versions owner env credentials before fetch and fences disconnect even if audit is interrupted', async () => {
    const owner = await ensureOwnerUser(env.DB, testEnv().OWNER_APPLE_SUB);
    if (!owner) throw new Error('expected test owner');
    await env.DB.prepare(
      `UPDATE users
          SET intervals_api_key = NULL,
              intervals_oauth_access_token = NULL,
              intervals_oauth_refresh_token = NULL,
              intervals_oauth_expires_at = NULL,
              intervals_athlete_id = NULL,
              intervals_auth_error_at = NULL,
              intervals_credential_generation = 0,
              intervals_events_synced_at = 10,
              intervals_activities_synced_at = 20,
              intervals_events_sync_attempt = 7,
              intervals_activities_sync_attempt = 8
        WHERE id = ?1`,
    )
      .bind(owner.id)
      .run();
    await env.DB.prepare('DELETE FROM external_events WHERE user_id = ?1')
      .bind(owner.id)
      .run();
    await env.DB.prepare(
      `INSERT INTO external_events
         (id,user_id,source,external_id,date,kind,title,raw,synced_at)
       VALUES (?1,?2,'intervals','legacy-cache','2036-05-18','ride','baseline',?3,10)`,
    )
      .bind(
        `intervals:${owner.id}:legacy-cache`,
        owner.id,
        JSON.stringify({ name: 'baseline' }),
      )
      .run();
    const cacheBefore = await externalRows('external_events', owner.id);
    await env.DB.prepare(
      "DELETE FROM audit_log WHERE user_id = ?1 AND tool = 'set_intervals_creds'",
    )
      .bind(owner.id)
      .run();
    const fallbackEnv: Env = {
      ...testEnv(),
      INTERVALS_ICU_API_KEY: 'legacy-owner-key',
      INTERVALS_ICU_ATHLETE_ID: 'legacy-owner-athlete',
    };
    const fetcher: Fetcher = async () => {
      expect((await getUserIntervalsCreds(env.DB, owner.id, env.CREDENTIAL_ENCRYPTION_KEY)).credential_generation).toBe(1);
      expect(await syncAttempts(owner.id)).toEqual({ events: 1, activities: 0 });
      await setUserIntervalsCreds(env.DB, owner.id, env.CREDENTIAL_ENCRYPTION_KEY, null, null);
      // Deliberately omit the route's later audit to model interruption in
      // that gap. Generation alone must make the disconnect durable.
      return new Response(
        JSON.stringify([plannedEvent('legacy-cache', 'stale overwrite')]),
        { status: 200 },
      );
    };

    const result = await syncExternalEvents(env.DB, fallbackEnv, {
      userId: owner.id,
      fetcher,
      syncedAt: 30,
    });

    expect(result.status).toBe('superseded');
    expect(await externalRows('external_events', owner.id)).toEqual(cacheBefore);
    expect(await freshness(owner.id)).toEqual({ events: null, activities: null });
    expect((await getUserIntervalsCreds(env.DB, owner.id, env.CREDENTIAL_ENCRYPTION_KEY)).credential_generation).toBe(2);
    const interruptedAudit = await env.DB.prepare(
      "SELECT COUNT(*) AS c FROM audit_log WHERE user_id = ?1 AND tool = 'set_intervals_creds'",
    )
      .bind(owner.id)
      .first<{ c: number }>();
    expect(interruptedAudit?.c).toBe(0);

    const fallbackRetry = vi.fn(emptySuccess);
    const retry = await syncExternalEvents(env.DB, fallbackEnv, {
      userId: owner.id,
      fetcher: fallbackRetry,
    });
    expect(retry.status).toBe('disabled');
    expect(fallbackRetry).not.toHaveBeenCalled();
  });

  it('preserves attempts during same-identity OAuth callback and refresh, then resets on change', async () => {
    const member = await connectedMember('oauth', { events: 10, activities: 20 });
    await setUserIntervalsOAuth(
      env.DB,
      member.id,
      env.CREDENTIAL_ENCRYPTION_KEY, 'initial-token',
      'refresh-token',
      null,
      member.athleteId,
    );
    expect(await freshness(member.id)).toEqual({ events: null, activities: null });
    expect(await syncAttempts(member.id)).toEqual({ events: 0, activities: 0 });
    expect((await getUserIntervalsCreds(env.DB, member.id, env.CREDENTIAL_ENCRYPTION_KEY)).credential_generation).toBe(1);

    await env.DB.prepare(
      `UPDATE users SET intervals_events_synced_at = 30,
                        intervals_activities_synced_at = 40,
                        intervals_events_sync_attempt = 5,
                        intervals_activities_sync_attempt = 6
        WHERE id = ?1`,
    )
      .bind(member.id)
      .run();
    await setUserIntervalsOAuth(
      env.DB,
      member.id,
      env.CREDENTIAL_ENCRYPTION_KEY, 'initial-token',
      'refresh-token',
      null,
      member.athleteId,
    );
    expect(await syncAttempts(member.id)).toEqual({ events: 5, activities: 6 });
    let eventCalls = 0;
    const refreshFetcher: Fetcher = async (input) => {
      if (input.includes('/oauth/token')) {
        return new Response(JSON.stringify({ access_token: 'rotated-token' }), {
          status: 200,
        });
      }
      eventCalls += 1;
      if (eventCalls === 1) return new Response('expired', { status: 401 });
      return new Response(JSON.stringify([]), { status: 200 });
    };
    const result = await syncExternalEvents(env.DB, testEnv(), {
      userId: member.id,
      fetcher: refreshFetcher,
      syncedAt: 31,
    });
    expect(result.status).toBe('ok');
    // Events advances because the post-refresh provider reconcile succeeded;
    // the unrelated activities freshness survives the token rotation.
    expect(await freshness(member.id)).toEqual({ events: 31, activities: 40 });
    expect((await getUserIntervalsCreds(env.DB, member.id, env.CREDENTIAL_ENCRYPTION_KEY)).access_token).toBe(
      'rotated-token',
    );
    expect((await getUserIntervalsCreds(env.DB, member.id, env.CREDENTIAL_ENCRYPTION_KEY)).credential_generation).toBe(1);
    expect(await syncAttempts(member.id)).toEqual({ events: 6, activities: 6 });

    await setUserIntervalsOAuth(
      env.DB,
      member.id,
      env.CREDENTIAL_ENCRYPTION_KEY, 'callback-replacement',
      'callback-refresh',
      null,
      member.athleteId,
    );
    expect(await syncAttempts(member.id)).toEqual({ events: 0, activities: 0 });
    expect((await getUserIntervalsCreds(env.DB, member.id, env.CREDENTIAL_ENCRYPTION_KEY)).credential_generation).toBe(2);
  });

  it('does not stamp a refreshed OAuth completion after that identity is replaced', async () => {
    const member = await connectedMember('oauth-race');
    await setUserIntervalsOAuth(
      env.DB,
      member.id,
      env.CREDENTIAL_ENCRYPTION_KEY, 'initial-token',
      'refresh-token',
      null,
      member.athleteId,
    );
    await syncExternalEvents(env.DB, testEnv(), {
      userId: member.id,
      today: '2036-05-18',
      fetcher: jsonSuccess([plannedEvent('oauth-cache', 'baseline')]),
    });
    const cacheBefore = await externalRows('external_events', member.id);
    await env.DB.prepare(
      `UPDATE users SET intervals_events_synced_at = 30,
                        intervals_activities_synced_at = 40
        WHERE id = ?1`,
    )
      .bind(member.id)
      .run();
    let eventCalls = 0;
    const fetcher: Fetcher = async (input, init) => {
      if (input.includes('/oauth/token')) {
        return new Response(JSON.stringify({ access_token: 'rotated-token' }), {
          status: 200,
        });
      }
      eventCalls += 1;
      if (eventCalls === 1) return new Response('expired', { status: 401 });
      expect(init?.headers?.Authorization).toBe('Bearer rotated-token');
      await setUserIntervalsOAuth(
        env.DB,
        member.id,
        env.CREDENTIAL_ENCRYPTION_KEY, 'replacement-token',
        'replacement-refresh',
        null,
        member.athleteId,
      );
      return new Response(
        JSON.stringify([
          plannedEvent('oauth-cache', 'stale overwrite'),
          plannedEvent('oauth-stale-insert', 'must not exist'),
        ]),
        { status: 200 },
      );
    };

    const result = await syncExternalEvents(env.DB, testEnv(), {
      userId: member.id,
      fetcher,
      syncedAt: 31,
    });

    expect(result.status).toBe('superseded');
    expect(await externalRows('external_events', member.id)).toEqual(cacheBefore);
    expect(await freshness(member.id)).toEqual({ events: null, activities: null });
    expect((await getUserIntervalsCreds(env.DB, member.id, env.CREDENTIAL_ENCRYPTION_KEY)).access_token).toBe(
      'replacement-token',
    );
  });

  it('a stale OAuth refresh cannot overwrite a callback replacement or emit an auth-clear audit', async () => {
    const member = await connectedMember('stale-refresh');
    await setUserIntervalsOAuth(
      env.DB,
      member.id,
      env.CREDENTIAL_ENCRYPTION_KEY, 'expired-token',
      'old-refresh',
      null,
      member.athleteId,
    );
    const before = await externalRows('external_events', member.id);
    let providerCalls = 0;
    const fetcher: Fetcher = async (input) => {
      if (input.includes('/oauth/token')) {
        await setUserIntervalsOAuth(
          env.DB,
          member.id,
          env.CREDENTIAL_ENCRYPTION_KEY, 'callback-replacement',
          'callback-refresh',
          null,
          member.athleteId,
        );
        return new Response(JSON.stringify({ access_token: 'stale-refreshed-token' }), {
          status: 200,
        });
      }
      providerCalls += 1;
      return new Response('expired', { status: 401 });
    };

    const result = await syncExternalEvents(env.DB, testEnv(), {
      userId: member.id,
      fetcher,
    });

    expect(result.status).toBe('superseded');
    expect(providerCalls).toBe(1);
    expect(await externalRows('external_events', member.id)).toEqual(before);
    expect(await getUserIntervalsCreds(env.DB, member.id, env.CREDENTIAL_ENCRYPTION_KEY)).toMatchObject({
      access_token: 'callback-replacement',
      credential_generation: 2,
    });
    const audits = await env.DB.prepare(
      "SELECT COUNT(*) AS c FROM audit_log WHERE user_id = ?1 AND tool = 'intervals_auth_error'",
    )
      .bind(member.id)
      .first<{ c: number }>();
    expect(audits?.c).toBe(0);
  });

  it('generation-fences every HealthKit dedup transition after an OAuth replacement', async () => {
    const member = await connectedMember('dedup-race');
    await setUserIntervalsOAuth(
      env.DB,
      member.id,
      env.CREDENTIAL_ENCRYPTION_KEY, 'oauth-before-dedup',
      'refresh-before-dedup',
      null,
      member.athleteId,
    );
    const providerRows = [
      completedActivity('retire-winner', 'retire winner'),
      {
        ...completedActivity('repoint-winner', 'repoint winner'),
        start_date_local: '2036-05-18T09:00:30',
      },
    ];
    await syncExternalActivities(env.DB, testEnv(), {
      userId: member.id,
      today: '2036-05-18',
      fetcher: jsonSuccess(providerRows),
    });
    const hkRows = [
      {
        id: 'hk-retire',
        start: Date.parse('2036-05-18T08:00:00Z'),
        deletedAt: null,
        canonical: 1,
        duplicateOf: null,
      },
      {
        id: 'hk-repoint',
        start: Date.parse('2036-05-18T09:00:00Z'),
        deletedAt: 11,
        canonical: 0,
        duplicateOf: 'intervals:activity:obsolete',
      },
      {
        id: 'hk-restore',
        start: Date.parse('2036-05-18T10:00:00Z'),
        deletedAt: 12,
        canonical: 0,
        duplicateOf: 'intervals:activity:gone',
      },
    ];
    for (const row of hkRows) {
      await env.DB.prepare(
        `INSERT INTO external_activities
           (id,user_id,source,external_id,date,start_date_local_ms,kind,name,
            synced_at,deleted_at,canonical,duplicate_of)
         VALUES (?1,?2,'healthkit',?3,'2036-05-18',?4,'ride',?3,10,?5,?6,?7)`,
      )
        .bind(
          `healthkit:activity:${member.id}:${row.id}`,
          member.id,
          row.id,
          row.start,
          row.deletedAt,
          row.canonical,
          row.duplicateOf,
        )
        .run();
    }
    const cacheBefore = await externalRows('external_activities', member.id);
    const racedDb = supersedeAfterHealthKitRead(env.DB, async () => {
      await setUserIntervalsOAuth(
        env.DB,
        member.id,
        env.CREDENTIAL_ENCRYPTION_KEY, 'oauth-after-dedup',
        'refresh-after-dedup',
        null,
        member.athleteId,
      );
    });

    const result = await syncExternalActivities(racedDb, testEnv(), {
      userId: member.id,
      today: '2036-05-18',
      fetcher: jsonSuccess(providerRows),
      syncedAt: 50,
    });

    expect(result.status).toBe('superseded');
    expect(await externalRows('external_activities', member.id)).toEqual(cacheBefore);
    expect(await freshness(member.id)).toEqual({ events: null, activities: null });
    expect(await getUserIntervalsCreds(env.DB, member.id, env.CREDENTIAL_ENCRYPTION_KEY)).toMatchObject({
      access_token: 'oauth-after-dedup',
      credential_generation: 2,
    });
  });

  it('a stale API-key 401 cannot clear its replacement or write an auth audit', async () => {
    const member = await connectedMember('stale-api-401');
    await syncExternalEvents(env.DB, testEnv(), {
      userId: member.id,
      today: '2036-05-18',
      fetcher: jsonSuccess([plannedEvent('api-401-cache', 'baseline')]),
    });
    const cacheBefore = await externalRows('external_events', member.id);
    const fetcher: Fetcher = async () => {
      await setUserIntervalsCreds(
        env.DB,
        member.id,
        env.CREDENTIAL_ENCRYPTION_KEY, 'api-key-after-401',
        member.athleteId,
      );
      return new Response('old credential rejected', { status: 401 });
    };

    const result = await syncExternalEvents(env.DB, testEnv(), {
      userId: member.id,
      fetcher,
    });

    expect(result.status).toBe('superseded');
    expect(await externalRows('external_events', member.id)).toEqual(cacheBefore);
    expect(await getUserIntervalsCreds(env.DB, member.id, env.CREDENTIAL_ENCRYPTION_KEY)).toMatchObject({
      api_key: 'api-key-after-401',
      athlete_id: member.athleteId,
      credential_generation: 1,
      auth_error_at: null,
    });
    const audits = await env.DB.prepare(
      "SELECT COUNT(*) AS c FROM audit_log WHERE user_id = ?1 AND tool = 'intervals_auth_error'",
    )
      .bind(member.id)
      .first<{ c: number }>();
    expect(audits?.c).toBe(0);
  });

  it('atomically clears and audits only the credential that actually receives a 401', async () => {
    const member = await connectedMember('winning-api-401', {
      events: 10,
      activities: 20,
    });

    const result = await syncExternalEvents(env.DB, testEnv(), {
      userId: member.id,
      fetcher: async () => new Response('rejected', { status: 401 }),
    });

    expect(result).toMatchObject({
      status: 'fetch_failed',
      detail: 'http:401:reauth_required',
    });
    expect(await getUserIntervalsCreds(env.DB, member.id, env.CREDENTIAL_ENCRYPTION_KEY)).toMatchObject({
      api_key: null,
      access_token: null,
      athlete_id: null,
      credential_generation: 1,
      auth_error_at: expect.any(Number),
    });
    expect(await freshness(member.id)).toEqual({ events: null, activities: null });
    const audits = await env.DB.prepare(
      "SELECT COUNT(*) AS c FROM audit_log WHERE user_id = ?1 AND tool = 'intervals_auth_error'",
    )
      .bind(member.id)
      .first<{ c: number }>();
    expect(audits?.c).toBe(1);

    const retry = await syncExternalEvents(env.DB, testEnv(), {
      userId: member.id,
      fetcher: emptySuccess,
    });
    expect(retry.status).toBe('disabled');
    const auditsAfterRetry = await env.DB.prepare(
      "SELECT COUNT(*) AS c FROM audit_log WHERE user_id = ?1 AND tool = 'intervals_auth_error'",
    )
      .bind(member.id)
      .first<{ c: number }>();
    expect(auditsAfterRetry?.c).toBe(1);
  });

  it('converges on the new event cache in both old/new completion orders', async () => {
    const newFirst = await connectedMember('new-first');
    let oldFetchStarted!: () => void;
    const started = new Promise<void>((resolve) => {
      oldFetchStarted = resolve;
    });
    let releaseOld!: () => void;
    const oldGate = new Promise<void>((resolve) => {
      releaseOld = resolve;
    });
    const oldRunning = syncExternalEvents(env.DB, testEnv(), {
      userId: newFirst.id,
      today: '2036-05-18',
      syncedAt: 60,
      fetcher: async () => {
        oldFetchStarted();
        await oldGate;
        return new Response(JSON.stringify([plannedEvent('ordered', 'old result')]), {
          status: 200,
        });
      },
    });
    await started;
    await setUserIntervalsCreds(env.DB, newFirst.id, env.CREDENTIAL_ENCRYPTION_KEY, 'new-first-key', newFirst.athleteId);
    const newResult = await syncExternalEvents(env.DB, testEnv(), {
      userId: newFirst.id,
      today: '2036-05-18',
      syncedAt: 50,
      fetcher: jsonSuccess([plannedEvent('ordered', 'new result')]),
    });
    releaseOld();
    const staleResult = await oldRunning;

    expect(newResult.status).toBe('ok');
    expect(staleResult.status).toBe('superseded');
    expect(await externalRows('external_events', newFirst.id)).toEqual([
      expect.objectContaining({ title: 'new result' }),
    ]);
    expect((await freshness(newFirst.id)).events).toBe(50);

    const oldFirst = await connectedMember('old-first');
    const oldResult = await syncExternalEvents(env.DB, testEnv(), {
      userId: oldFirst.id,
      today: '2036-05-18',
      syncedAt: 70,
      fetcher: jsonSuccess([plannedEvent('ordered', 'old result')]),
    });
    const oldCache = await externalRows('external_events', oldFirst.id);
    await setUserIntervalsCreds(env.DB, oldFirst.id, env.CREDENTIAL_ENCRYPTION_KEY, 'old-first-new-key', oldFirst.athleteId);
    expect(await externalRows('external_events', oldFirst.id)).toEqual(oldCache);
    expect(await freshness(oldFirst.id)).toEqual({ events: null, activities: null });
    const finalResult = await syncExternalEvents(env.DB, testEnv(), {
      userId: oldFirst.id,
      today: '2036-05-18',
      syncedAt: 80,
      fetcher: jsonSuccess([plannedEvent('ordered', 'new result')]),
    });

    expect(oldResult.status).toBe('ok');
    expect(finalResult.status).toBe('ok');
    expect(await externalRows('external_events', oldFirst.id)).toEqual([
      expect.objectContaining({ title: 'new result' }),
    ]);
    expect((await freshness(oldFirst.id)).events).toBe(80);
  });

  it('orders an OAuth callback and disconnect solely by their committed generations', async () => {
    const callbackFirst = await connectedMember('callback-first');
    await setUserIntervalsOAuth(
      env.DB,
      callbackFirst.id,
      env.CREDENTIAL_ENCRYPTION_KEY, 'callback-token',
      'callback-refresh',
      null,
      callbackFirst.athleteId,
    );
    await setUserIntervalsCreds(env.DB, callbackFirst.id, env.CREDENTIAL_ENCRYPTION_KEY, null, null);
    expect(await getUserIntervalsCreds(env.DB, callbackFirst.id, env.CREDENTIAL_ENCRYPTION_KEY)).toMatchObject({
      access_token: null,
      athlete_id: null,
      credential_generation: 2,
    });

    const disconnectFirst = await connectedMember('disconnect-first');
    await setUserIntervalsCreds(env.DB, disconnectFirst.id, env.CREDENTIAL_ENCRYPTION_KEY, null, null);
    await setUserIntervalsOAuth(
      env.DB,
      disconnectFirst.id,
      env.CREDENTIAL_ENCRYPTION_KEY, 'later-callback-token',
      'later-callback-refresh',
      null,
      disconnectFirst.athleteId,
    );
    expect(await getUserIntervalsCreds(env.DB, disconnectFirst.id, env.CREDENTIAL_ENCRYPTION_KEY)).toMatchObject({
      access_token: 'later-callback-token',
      athlete_id: disconnectFirst.athleteId,
      credential_generation: 2,
    });
  });

  it('never gives a non-owner the legacy owner env credential fallback', async () => {
    const owner = await connectedMember('owner');
    const memberId = crypto.randomUUID();
    await env.DB.prepare(
      'INSERT INTO users (id,apple_sub,email,display_name,created_at) VALUES (?1,?2,NULL,?3,?4)',
    )
      .bind(memberId, `p4-sub-${memberId}`, 'No Credentials', TICK + 1)
      .run();
    const fetcher = vi.fn(emptySuccess);
    const envWithOwnerFallback: Env = {
      ...testEnv(),
      INTERVALS_ICU_API_KEY: owner.apiKey,
      INTERVALS_ICU_ATHLETE_ID: owner.athleteId,
    };

    const events = await syncExternalEvents(env.DB, envWithOwnerFallback, {
      userId: memberId,
      fetcher,
    });
    const activities = await syncExternalActivities(env.DB, envWithOwnerFallback, {
      userId: memberId,
      fetcher,
    });

    expect(events.status).toBe('disabled');
    expect(activities.status).toBe('disabled');
    expect(fetcher).not.toHaveBeenCalled();
    expect(await getUserIntervalsCreds(env.DB, memberId, env.CREDENTIAL_ENCRYPTION_KEY)).toMatchObject({
      api_key: null,
      access_token: null,
      athlete_id: null,
    });
  });
});

describe('P4.5 same-generation attempt ordering', () => {
  it('keeps the newer event cache, tombstones, and freshness byte-exact', async () => {
    const member = await connectedMember('attempt-events');
    await syncExternalEvents(env.DB, testEnv(), {
      userId: member.id,
      today: '2036-05-18',
      syncedAt: 10,
      fetcher: jsonSuccess([
        plannedEvent('kept', 'baseline'),
        plannedEvent('removed', 'will be tombstoned'),
      ]),
    });
    let entered!: () => void;
    const enteredProvider = new Promise<void>((resolve) => {
      entered = resolve;
    });
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    const older = syncExternalEvents(env.DB, testEnv(), {
      userId: member.id,
      today: '2036-05-18',
      syncedAt: 30,
      fetcher: async () => {
        entered();
        await gate;
        return new Response(
          JSON.stringify([
            plannedEvent('kept', 'stale overwrite'),
            plannedEvent('stale-insert', 'must never land'),
          ]),
          { status: 200 },
        );
      },
    });
    await enteredProvider;

    const newer = await syncExternalEvents(env.DB, testEnv(), {
      userId: member.id,
      today: '2036-05-18',
      syncedAt: 20,
      fetcher: jsonSuccess([
        plannedEvent('kept', 'newest result'),
        plannedEvent('new-insert', 'newest insert'),
      ]),
    });
    const cacheAfterNewer = await externalRows('external_events', member.id);
    const freshnessAfterNewer = await freshness(member.id);
    release();
    const olderResult = await older;

    expect(newer.status).toBe('ok');
    expect(olderResult.status).toBe('superseded');
    expect(await externalRows('external_events', member.id)).toEqual(cacheAfterNewer);
    expect(await freshness(member.id)).toEqual(freshnessAfterNewer);
    expect(cacheAfterNewer).toEqual([
      expect.objectContaining({ external_id: 'kept', title: 'newest result', deleted_at: null }),
      expect.objectContaining({ external_id: 'new-insert', deleted_at: null }),
      expect.objectContaining({ external_id: 'removed', deleted_at: expect.any(Number) }),
    ]);
    expect(await syncAttempts(member.id)).toEqual({ events: 3, activities: 0 });
  });

  it('a newer failed attempt still supersedes an older successful response', async () => {
    const member = await connectedMember('attempt-failure');
    await syncExternalEvents(env.DB, testEnv(), {
      userId: member.id,
      today: '2036-05-18',
      syncedAt: 10,
      fetcher: jsonSuccess([plannedEvent('preserved', 'baseline')]),
    });
    let entered!: () => void;
    const enteredProvider = new Promise<void>((resolve) => {
      entered = resolve;
    });
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    const older = syncExternalEvents(env.DB, testEnv(), {
      userId: member.id,
      today: '2036-05-18',
      syncedAt: 30,
      fetcher: async () => {
        entered();
        await gate;
        return new Response(
          JSON.stringify([plannedEvent('preserved', 'stale success')]),
          { status: 200 },
        );
      },
    });
    await enteredProvider;
    const newerFailure = await syncExternalEvents(env.DB, testEnv(), {
      userId: member.id,
      fetcher: async () => new Response('upstream', { status: 500 }),
    });
    const cacheAfterFailure = await externalRows('external_events', member.id);
    const freshnessAfterFailure = await freshness(member.id);
    release();

    expect(newerFailure.status).toBe('fetch_failed');
    expect((await older).status).toBe('superseded');
    expect(await externalRows('external_events', member.id)).toEqual(cacheAfterFailure);
    expect(await freshness(member.id)).toEqual(freshnessAfterFailure);
    expect(cacheAfterFailure).toEqual([
      expect.objectContaining({ external_id: 'preserved', title: 'baseline' }),
    ]);
    expect(await syncAttempts(member.id)).toEqual({ events: 3, activities: 0 });
  });

  it('keeps the newer activity cache, tombstones, and freshness byte-exact', async () => {
    const member = await connectedMember('attempt-activities');
    await syncExternalActivities(env.DB, testEnv(), {
      userId: member.id,
      today: '2036-05-18',
      syncedAt: 10,
      fetcher: jsonSuccess([
        completedActivity('kept', 'baseline'),
        completedActivity('removed', 'will be tombstoned'),
      ]),
    });
    let entered!: () => void;
    const enteredProvider = new Promise<void>((resolve) => {
      entered = resolve;
    });
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    const older = syncExternalActivities(env.DB, testEnv(), {
      userId: member.id,
      today: '2036-05-18',
      syncedAt: 30,
      fetcher: async () => {
        entered();
        await gate;
        return new Response(
          JSON.stringify([
            completedActivity('kept', 'stale overwrite'),
            completedActivity('stale-insert', 'must never land'),
          ]),
          { status: 200 },
        );
      },
    });
    await enteredProvider;
    const newer = await syncExternalActivities(env.DB, testEnv(), {
      userId: member.id,
      today: '2036-05-18',
      syncedAt: 20,
      fetcher: jsonSuccess([
        completedActivity('kept', 'newest result'),
        completedActivity('new-insert', 'newest insert'),
      ]),
    });
    const cacheAfterNewer = await externalRows('external_activities', member.id);
    const freshnessAfterNewer = await freshness(member.id);
    release();
    const olderResult = await older;

    expect(newer.status).toBe('ok');
    expect(olderResult.status).toBe('superseded');
    expect(await externalRows('external_activities', member.id)).toEqual(cacheAfterNewer);
    expect(await freshness(member.id)).toEqual(freshnessAfterNewer);
    expect(cacheAfterNewer).toEqual([
      expect.objectContaining({ external_id: 'kept', name: 'newest result', deleted_at: null }),
      expect.objectContaining({ external_id: 'new-insert', deleted_at: null }),
      expect.objectContaining({ external_id: 'removed', deleted_at: expect.any(Number) }),
    ]);
    expect(await syncAttempts(member.id)).toEqual({ events: 0, activities: 3 });
  });

  it('fences HealthKit retire, repoint, and restore after a newer activity claim', async () => {
    const member = await connectedMember('attempt-healthkit');
    const providerRows = [
      completedActivity('retire-winner', 'retire winner'),
      {
        ...completedActivity('repoint-winner', 'repoint winner'),
        start_date_local: '2036-05-18T09:00:30',
      },
    ];
    await syncExternalActivities(env.DB, testEnv(), {
      userId: member.id,
      today: '2036-05-18',
      syncedAt: 10,
      fetcher: jsonSuccess(providerRows),
    });
    for (const row of [
      { id: 'retire', start: '08:00:00', deleted: null, canonical: 1, duplicate: null },
      {
        id: 'repoint',
        start: '09:00:00',
        deleted: 11,
        canonical: 0,
        duplicate: 'intervals:activity:obsolete',
      },
      {
        id: 'restore',
        start: '10:00:00',
        deleted: 12,
        canonical: 0,
        duplicate: 'intervals:activity:gone',
      },
    ]) {
      await env.DB.prepare(
        `INSERT INTO external_activities
           (id,user_id,source,external_id,date,start_date_local_ms,kind,name,
            synced_at,deleted_at,canonical,duplicate_of)
         VALUES (?1,?2,'healthkit',?3,'2036-05-18',?4,'ride',?3,10,?5,?6,?7)`,
      )
        .bind(
          `healthkit:activity:${member.id}:${row.id}`,
          member.id,
          row.id,
          Date.parse(`2036-05-18T${row.start}Z`),
          row.deleted,
          row.canonical,
          row.duplicate,
        )
        .run();
    }
    const healthKitBefore = (await externalRows('external_activities', member.id)).filter(
      (row) => row.source === 'healthkit',
    );
    const freshnessBefore = await freshness(member.id);
    let newerResult: Awaited<ReturnType<typeof syncExternalActivities>> | undefined;
    const racedDb = supersedeAfterHealthKitRead(env.DB, async () => {
      newerResult = await syncExternalActivities(env.DB, testEnv(), {
        userId: member.id,
        fetcher: async () => new Response('upstream', { status: 500 }),
      });
    });

    const olderResult = await syncExternalActivities(racedDb, testEnv(), {
      userId: member.id,
      today: '2036-05-18',
      syncedAt: 20,
      fetcher: jsonSuccess(providerRows),
    });
    const healthKitAfter = (await externalRows('external_activities', member.id)).filter(
      (row) => row.source === 'healthkit',
    );

    expect(newerResult?.status).toBe('fetch_failed');
    expect(olderResult.status).toBe('superseded');
    expect(healthKitAfter).toEqual(healthKitBefore);
    expect(await freshness(member.id)).toEqual(freshnessBefore);
    expect(await syncAttempts(member.id)).toEqual({ events: 0, activities: 3 });
  });

  it('isolates attempts per cache and per user', async () => {
    const memberA = await connectedMember('attempt-isolation-a');
    const memberB = await connectedMember('attempt-isolation-b');
    let entered!: () => void;
    const enteredProvider = new Promise<void>((resolve) => {
      entered = resolve;
    });
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    const aEvents = syncExternalEvents(env.DB, testEnv(), {
      userId: memberA.id,
      fetcher: async () => {
        entered();
        await gate;
        return new Response(JSON.stringify([plannedEvent('a-event', 'A')]), { status: 200 });
      },
    });
    await enteredProvider;

    const [aActivities, bEvents] = await Promise.all([
      syncExternalActivities(env.DB, testEnv(), {
        userId: memberA.id,
        fetcher: jsonSuccess([completedActivity('a-activity', 'A')]),
      }),
      syncExternalEvents(env.DB, testEnv(), {
        userId: memberB.id,
        fetcher: jsonSuccess([plannedEvent('b-event', 'B')]),
      }),
    ]);
    release();

    expect((await aEvents).status).toBe('ok');
    expect(aActivities.status).toBe('ok');
    expect(bEvents.status).toBe('ok');
    expect(await syncAttempts(memberA.id)).toEqual({ events: 1, activities: 1 });
    expect(await syncAttempts(memberB.id)).toEqual({ events: 1, activities: 0 });
  });

  it('a newer same-cache attempt makes an older 401 a no-op', async () => {
    const member = await connectedMember('attempt-stale-401');
    let entered!: () => void;
    const enteredProvider = new Promise<void>((resolve) => {
      entered = resolve;
    });
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    const older = syncExternalEvents(env.DB, testEnv(), {
      userId: member.id,
      fetcher: async () => {
        entered();
        await gate;
        return new Response('stale rejection', { status: 401 });
      },
    });
    await enteredProvider;
    const newer = await syncExternalEvents(env.DB, testEnv(), {
      userId: member.id,
      syncedAt: 20,
      fetcher: emptySuccess,
    });
    release();

    expect(newer.status).toBe('ok');
    expect((await older).status).toBe('superseded');
    expect(await getUserIntervalsCreds(env.DB, member.id, env.CREDENTIAL_ENCRYPTION_KEY)).toMatchObject({
      api_key: member.apiKey,
      credential_generation: 0,
      auth_error_at: null,
    });
    expect(await authAuditCount(member.id)).toBe(0);
    expect(await syncAttempts(member.id)).toEqual({ events: 2, activities: 0 });
  });

  it('cross-cache claims supersede stale shared-auth mutation in both directions', async () => {
    for (const oldCache of ['events', 'activities'] as const) {
      const member = await connectedMember(`attempt-cross-${oldCache}`);
      let entered!: () => void;
      const enteredProvider = new Promise<void>((resolve) => {
        entered = resolve;
      });
      let release!: () => void;
      const gate = new Promise<void>((resolve) => {
        release = resolve;
      });
      const older = (oldCache === 'events' ? syncExternalEvents : syncExternalActivities)(
        env.DB,
        testEnv(),
        {
          userId: member.id,
          fetcher: async () => {
            entered();
            await gate;
            return new Response('stale rejection', { status: 401 });
          },
        },
      );
      await enteredProvider;
      const newer = await (oldCache === 'events'
        ? syncExternalActivities(env.DB, testEnv(), {
            userId: member.id,
            fetcher: emptySuccess,
          })
        : syncExternalEvents(env.DB, testEnv(), {
            userId: member.id,
            fetcher: emptySuccess,
          }));
      release();

      expect(newer.status).toBe('ok');
      expect((await older).status).toBe('superseded');
      expect(await getUserIntervalsCreds(env.DB, member.id, env.CREDENTIAL_ENCRYPTION_KEY)).toMatchObject({
        api_key: member.apiKey,
        credential_generation: 0,
        auth_error_at: null,
      });
      expect(await authAuditCount(member.id)).toBe(0);
      expect(await syncAttempts(member.id)).toEqual({ events: 1, activities: 1 });
    }
  });

  it('a pending newer other-cache claim blocks an older 401 before it finishes', async () => {
    const member = await connectedMember('attempt-cross-pending');
    let oldEntered!: () => void;
    const oldStarted = new Promise<void>((resolve) => {
      oldEntered = resolve;
    });
    let releaseOld!: () => void;
    const oldGate = new Promise<void>((resolve) => {
      releaseOld = resolve;
    });
    const older = syncExternalEvents(env.DB, testEnv(), {
      userId: member.id,
      fetcher: async () => {
        oldEntered();
        await oldGate;
        return new Response('stale rejection', { status: 401 });
      },
    });
    await oldStarted;

    let newEntered!: () => void;
    const newStarted = new Promise<void>((resolve) => {
      newEntered = resolve;
    });
    let releaseNew!: () => void;
    const newGate = new Promise<void>((resolve) => {
      releaseNew = resolve;
    });
    const newer = syncExternalActivities(env.DB, testEnv(), {
      userId: member.id,
      fetcher: async () => {
        newEntered();
        await newGate;
        return new Response(JSON.stringify([]), { status: 200 });
      },
    });
    await newStarted;
    releaseOld();

    expect((await older).status).toBe('superseded');
    expect(await authAuditCount(member.id)).toBe(0);
    expect((await getUserIntervalsCreds(env.DB, member.id, env.CREDENTIAL_ENCRYPTION_KEY)).api_key).toBe(member.apiKey);
    releaseNew();
    expect((await newer).status).toBe('ok');
  });

  it('orders concurrent cross-cache OAuth refresh responses by the full claim tuple', async () => {
    for (const oldCache of ['events', 'activities'] as const) {
      for (const releaseOrder of ['older-first', 'newer-first'] as const) {
        const member = await connectedMember(`refresh-${oldCache}-${releaseOrder}`);
        await setUserIntervalsOAuth(
          env.DB,
          member.id,
          env.CREDENTIAL_ENCRYPTION_KEY, 'expired-token',
          'refresh-token',
          123,
          member.athleteId,
        );
        let oldRefreshEntered!: () => void;
        const oldRefreshStarted = new Promise<void>((resolve) => {
          oldRefreshEntered = resolve;
        });
        let releaseOldRefresh!: () => void;
        const oldRefreshGate = new Promise<void>((resolve) => {
          releaseOldRefresh = resolve;
        });
        let oldProviderCalls = 0;
        const oldFetcher: Fetcher = async (input) => {
          if (input.includes('/oauth/token')) {
            oldRefreshEntered();
            await oldRefreshGate;
            return new Response(JSON.stringify({ access_token: 'stale-rotated-token' }), {
              status: 200,
            });
          }
          oldProviderCalls += 1;
          return new Response('expired', { status: 401 });
        };
        const older = (oldCache === 'events' ? syncExternalEvents : syncExternalActivities)(
          env.DB,
          testEnv(),
          { userId: member.id, fetcher: oldFetcher },
        );
        await oldRefreshStarted;

        let newRefreshEntered!: () => void;
        const newRefreshStarted = new Promise<void>((resolve) => {
          newRefreshEntered = resolve;
        });
        let releaseNewRefresh!: () => void;
        const newRefreshGate = new Promise<void>((resolve) => {
          releaseNewRefresh = resolve;
        });
        let newProviderCalls = 0;
        const newestToken = `newest-${oldCache}-${releaseOrder}`;
        const newFetcher: Fetcher = async (input) => {
          if (input.includes('/oauth/token')) {
            newRefreshEntered();
            await newRefreshGate;
            return new Response(JSON.stringify({ access_token: newestToken }), {
              status: 200,
            });
          }
          newProviderCalls += 1;
          return newProviderCalls === 1
            ? new Response('expired', { status: 401 })
            : new Response(JSON.stringify([]), { status: 200 });
        };
        const newer = oldCache === 'events'
          ? syncExternalActivities(env.DB, testEnv(), {
              userId: member.id,
              fetcher: newFetcher,
            })
          : syncExternalEvents(env.DB, testEnv(), {
              userId: member.id,
              fetcher: newFetcher,
            });
        await newRefreshStarted;

        if (releaseOrder === 'older-first') {
          releaseOldRefresh();
          expect((await older).status).toBe('superseded');
          releaseNewRefresh();
          expect((await newer).status).toBe('ok');
        } else {
          releaseNewRefresh();
          expect((await newer).status).toBe('ok');
          releaseOldRefresh();
          expect((await older).status).toBe('superseded');
        }
        expect(oldProviderCalls).toBe(1);
        expect(newProviderCalls).toBe(2);
        expect(await getUserIntervalsCreds(env.DB, member.id, env.CREDENTIAL_ENCRYPTION_KEY)).toMatchObject({
          access_token: newestToken,
          credential_generation: 1,
          auth_error_at: null,
        });
        expect(await authAuditCount(member.id)).toBe(0);
        expect(await syncAttempts(member.id)).toEqual({ events: 1, activities: 1 });
      }
    }
  });

  it('lets only the newest same-cache 401 clear credentials and audit once', async () => {
    const member = await connectedMember('attempt-winning-401', {
      events: 10,
      activities: 20,
    });
    let entered!: () => void;
    const enteredProvider = new Promise<void>((resolve) => {
      entered = resolve;
    });
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    const older = syncExternalEvents(env.DB, testEnv(), {
      userId: member.id,
      fetcher: async () => {
        entered();
        await gate;
        return new Response('old rejection', { status: 401 });
      },
    });
    await enteredProvider;
    const newest = await syncExternalEvents(env.DB, testEnv(), {
      userId: member.id,
      fetcher: async () => new Response('new rejection', { status: 401 }),
    });
    release();

    expect(newest).toMatchObject({
      status: 'fetch_failed',
      detail: 'http:401:reauth_required',
    });
    expect((await older).status).toBe('superseded');
    expect(await authAuditCount(member.id)).toBe(1);
    expect(await getUserIntervalsCreds(env.DB, member.id, env.CREDENTIAL_ENCRYPTION_KEY)).toMatchObject({
      api_key: null,
      athlete_id: null,
      credential_generation: 1,
      auth_error_at: expect.any(Number),
    });
    expect(await syncAttempts(member.id)).toEqual({ events: 0, activities: 0 });
    expect(await freshness(member.id)).toEqual({ events: null, activities: null });
  });

  it('fails closed at the safe-integer attempt limit without provider I/O or mutation', async () => {
    const member = await connectedMember('attempt-overflow', { events: 10, activities: 20 });
    await env.DB.prepare(
      `UPDATE users SET intervals_events_sync_attempt = 9007199254740991,
                        intervals_activities_sync_attempt = 17
        WHERE id = ?1`,
    )
      .bind(member.id)
      .run();
    const stateBefore = await intervalsUserState(member.id);
    const cacheBefore = await externalRows('external_events', member.id);
    const fetcher = vi.fn(emptySuccess);

    const result = await syncExternalEvents(env.DB, testEnv(), {
      userId: member.id,
      fetcher,
    });

    expect(result).toEqual({
      status: 'fetch_failed',
      synced: 0,
      detail: 'attempt_exhausted',
    });
    expect(fetcher).not.toHaveBeenCalled();
    expect(await intervalsUserState(member.id)).toEqual(stateBefore);
    expect(await externalRows('external_events', member.id)).toEqual(cacheBefore);
  });

  it('keeps migration defaults old-writer compatible and enforces unindexed bounds', async () => {
    const id = crypto.randomUUID();
    await env.DB.prepare(
      'INSERT INTO users (id,apple_sub,email,display_name,created_at) VALUES (?1,?2,NULL,NULL,?3)',
    )
      .bind(id, `p4-5-old-writer-${id}`, TICK)
      .run();
    expect(await syncAttempts(id)).toEqual({ events: 0, activities: 0 });

    await expect(
      env.DB.prepare('UPDATE users SET intervals_events_sync_attempt = -1 WHERE id = ?1')
        .bind(id)
        .run(),
    ).rejects.toThrow(/CHECK constraint failed/);
    await expect(
      env.DB.prepare(
        'UPDATE users SET intervals_activities_sync_attempt = 9007199254740992 WHERE id = ?1',
      )
        .bind(id)
        .run(),
    ).rejects.toThrow(/CHECK constraint failed/);

    const indexes = await env.DB.prepare(
      "SELECT sql FROM sqlite_schema WHERE type = 'index' AND tbl_name = 'users'",
    ).all<{ sql: string | null }>();
    expect(JSON.stringify(indexes.results)).not.toContain('sync_attempt');
  });
});
