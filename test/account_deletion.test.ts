import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { issueAppJwt } from '../src/auth';
import { validateBearer } from '../src/oauth';
import {
  acknowledgeAppleGrantExchange,
  beginAppleGrantExchange,
  claimOrCreateOwner,
  deleteUserAccount,
  ensureOwnerUser,
  finishAppleGrantExchange,
  findOwnerRow,
  markAppleGrantExchangeUncertain,
  storeAppleRefreshToken,
  upsertUserUnlessDeletedOwner,
  upsertUser,
} from '../src/db';

const BASE = 'https://lift-coach.test';
const auth = (jwt: string) => ({ Authorization: `Bearer ${jwt}` });
const deletionAuth = (jwt: string, key: string) => ({
  ...auth(jwt),
  'X-Account-Deletion-Key': key,
});

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

async function makeUser(label: string) {
  const user = await upsertUser(
    env.DB,
    `delete-${label}-${crypto.randomUUID()}`,
    `${label}@test`,
    label,
  );
  return { user, jwt: await issueAppJwt(user.id, 'test-secret') };
}

async function seedTrainingGraph(userId: string, label: string) {
  const suffix = `${label}-${crypto.randomUUID()}`;
  const exerciseId = `exercise-${suffix}`;
  const planId = `plan-${suffix}`;
  const dayId = `day-${suffix}`;
  const templateExerciseId = `te-${suffix}`;
  const sessionId = `session-${suffix}`;
  const setId = `set-${suffix}`;
  const aliasId = `alias-${suffix}`;
  const noteId = `note-${suffix}`;
  const auditId = `audit-${suffix}`;
  const eventId = `event-${suffix}`;
  const externalActivityId = `external-activity-${suffix}`;
  const activityId = `activity-${suffix}`;
  const oauthCode = `oauth-code-${suffix}`;
  const oauthAccess = `oauth-access-${suffix}`;
  const oauthRefresh = `oauth-refresh-${suffix}`;
  const intervalsState = `intervals-state-${suffix}`;
  const ts = Date.now();

  await env.DB.batch([
    env.DB
      .prepare(
        `INSERT INTO exercises
           (id,name,primary_muscle,unit,created_at)
         VALUES (?1,?2,'legs','lb',?3)`,
      )
      .bind(exerciseId, `Exercise ${label}`, ts),
    env.DB
      .prepare(
        `INSERT INTO plans
           (id,user_id,name,status,version,created_at,updated_at)
         VALUES (?1,?2,?3,'active',1,?4,?4)`,
      )
      .bind(planId, userId, `Plan ${label}`, ts),
    env.DB
      .prepare(
        `INSERT INTO day_templates
           (id,plan_id,name,order_index,created_at,updated_at)
         VALUES (?1,?2,'Day',0,?3,?3)`,
      )
      .bind(dayId, planId, ts),
    env.DB
      .prepare(
        `INSERT INTO template_exercises
           (id,day_template_id,exercise_id,order_index,target_sets,target_reps,
            rest_seconds,created_at,updated_at)
         VALUES (?1,?2,?3,0,3,5,120,?4,?4)`,
      )
      .bind(templateExerciseId, dayId, exerciseId, ts),
    env.DB
      .prepare(
        `INSERT INTO sessions
           (id,user_id,plan_id,day_template_id,date,status,created_at,updated_at)
         VALUES (?1,?2,?3,?4,'2026-08-29','completed',?5,?5)`,
      )
      .bind(sessionId, userId, planId, dayId, ts),
    env.DB
      .prepare(
        `INSERT INTO set_logs
           (id,session_id,exercise_id,template_exercise_id,set_index,weight,reps,
            logged_at,source)
         VALUES (?1,?2,?3,?4,1,100,5,?5,'ios')`,
      )
      .bind(setId, sessionId, exerciseId, templateExerciseId, ts),
    env.DB
      .prepare(
        `INSERT INTO session_load_exports
           (session_id,load,status,attempts,updated_at)
         VALUES (?1,10,'ok',1,?2)`,
      )
      .bind(sessionId, ts),
    env.DB
      .prepare(
        `INSERT INTO session_aliases (alias_session_id,canonical_session_id)
         VALUES (?1,?2)`,
      )
      .bind(aliasId, sessionId),
    env.DB
      .prepare(
        `INSERT INTO notes
           (id,user_id,scope,author,body,created_at)
         VALUES (?1,?2,'user','ios','private note',?3)`,
      )
      .bind(noteId, userId, ts),
    env.DB
      .prepare(
        `INSERT INTO audit_log
           (id,user_id,actor,tool,created_at)
         VALUES (?1,?2,'mcp','private_action',?3)`,
      )
      .bind(auditId, userId, ts),
    env.DB
      .prepare(
        `INSERT INTO external_events
           (id,user_id,source,external_id,date,kind,synced_at)
         VALUES (?1,?2,'intervals',?3,'2026-08-30','ride',?4)`,
      )
      .bind(eventId, userId, `event-upstream-${suffix}`, ts),
    env.DB
      .prepare(
        `INSERT INTO external_activities
           (id,user_id,source,external_id,date,kind,synced_at)
         VALUES (?1,?2,'intervals',?3,'2026-08-29','ride',?4)`,
      )
      .bind(
        externalActivityId,
        userId,
        `activity-upstream-${suffix}`,
        ts,
      ),
    env.DB
      .prepare(
        `INSERT INTO activities
           (id,user_id,date,type,logged_at,source)
         VALUES (?1,?2,'2026-08-29','walk',?3,'ios')`,
      )
      .bind(activityId, userId, ts),
    env.DB
      .prepare(
        `INSERT INTO oauth_codes
           (code,client_id,redirect_uri,code_challenge,code_challenge_method,
            scope,expires_at,created_at,user_id)
         VALUES (?1,'client','https://example.test/callback','challenge','S256',
                 'mcp',?2,?3,?4)`,
      )
      .bind(oauthCode, ts + 60_000, ts, userId),
    env.DB
      .prepare(
        `INSERT INTO oauth_tokens
           (access_token,refresh_token,client_id,scope,expires_at,created_at,user_id)
         VALUES (?1,?2,'client','mcp',?3,?4,?5)`,
      )
      .bind(oauthAccess, oauthRefresh, ts + 60_000, ts, userId),
    env.DB
      .prepare(
        `INSERT INTO intervals_oauth_states
           (state,user_id,created_at,expires_at)
         VALUES (?1,?2,?3,?4)`,
      )
      .bind(intervalsState, userId, ts, ts + 60_000),
    env.DB
      .prepare(
        `UPDATE users SET
           intervals_api_key='private-key', intervals_athlete_id='private-athlete',
           mcp_passphrase_hash='private-hash', mcp_passphrase_salt='private-salt'
         WHERE id=?1`,
      )
      .bind(userId),
  ]);

  return {
    planId,
    dayId,
    templateExerciseId,
    sessionId,
    setId,
    aliasId,
    noteId,
    auditId,
    eventId,
    externalActivityId,
    activityId,
    oauthCode,
    oauthAccess,
    intervalsState,
  };
}

async function byId(
  table: string,
  column: string,
  id: string,
): Promise<Record<string, unknown> | null> {
  return env.DB.prepare(`SELECT * FROM ${table} WHERE ${column} = ?1`)
    .bind(id)
    .first<Record<string, unknown>>();
}

describe('DELETE /api/me', () => {
  it('accepts an expired bearer only for its matching committed receipt', async () => {
    const target = await makeUser('expired-receipt');
    const deletionKey = crypto.randomUUID();
    const expiredBearer = await issueAppJwt(target.user.id, 'test-secret', {
      ttlSeconds: -1,
    });

    // Expiry can never authorize the initial destructive operation.
    const premature = await SELF.fetch(`${BASE}/api/me`, {
      method: 'DELETE',
      headers: deletionAuth(expiredBearer, deletionKey),
    });
    expect(premature.status).toBe(401);
    expect(await byId('users', 'id', target.user.id)).not.toBeNull();

    const deletion = await SELF.fetch(`${BASE}/api/me`, {
      method: 'DELETE',
      headers: deletionAuth(target.jwt, deletionKey),
    });
    expect(deletion.status).toBe(200);
    const deletionResult = await deletion.json<{
      ok: true;
      owner_tombstoned: boolean;
      apple_revocation: 'revoked' | 'manual_required';
    }>();

    // Once deletion has committed, the expired signed bearer plus the exact
    // high-entropy receipt key can acknowledge the lost response.
    const retry = await SELF.fetch(`${BASE}/api/me`, {
      method: 'DELETE',
      headers: deletionAuth(expiredBearer, deletionKey),
    });
    expect(retry.status).toBe(200);
    expect(await retry.json()).toEqual(deletionResult);

    const wrongKey = await SELF.fetch(`${BASE}/api/me`, {
      method: 'DELETE',
      headers: deletionAuth(expiredBearer, crypto.randomUUID()),
    });
    expect(wrongKey.status).toBe(401);

    const forgedBearer = await issueAppJwt(target.user.id, 'wrong-secret', {
      ttlSeconds: -1,
    });
    const forged = await SELF.fetch(`${BASE}/api/me`, {
      method: 'DELETE',
      headers: deletionAuth(forgedBearer, deletionKey),
    });
    expect(forged.status).toBe(401);
  });

  it('requires an authenticated app session', async () => {
    const response = await SELF.fetch(`${BASE}/api/me`, { method: 'DELETE' });
    expect(response.status).toBe(401);
  });

  it('requires recent authentication for an initial deletion but not a receipt retry', async () => {
    const target = await makeUser('recent-auth');
    const deletionKey = crypto.randomUUID();
    const nowSeconds = Math.floor(Date.now() / 1000);
    const oldBearer = await issueAppJwt(target.user.id, 'test-secret', {
      nowSeconds,
      authTimeSeconds: nowSeconds - 6 * 60,
    });

    const staleAttempt = await SELF.fetch(`${BASE}/api/me`, {
      method: 'DELETE',
      headers: deletionAuth(oldBearer, deletionKey),
    });
    expect(staleAttempt.status).toBe(401);
    expect(await staleAttempt.json()).toEqual({
      error: 'reauthentication_required',
    });
    expect(await byId('users', 'id', target.user.id)).not.toBeNull();

    const deletion = await SELF.fetch(`${BASE}/api/me`, {
      method: 'DELETE',
      headers: deletionAuth(target.jwt, deletionKey),
    });
    expect(deletion.status).toBe(200);
    const deletionResult = await deletion.json();

    // Once the transaction committed, the older still-valid bearer cannot
    // initiate another deletion; it can only acknowledge this exact receipt.
    const retry = await SELF.fetch(`${BASE}/api/me`, {
      method: 'DELETE',
      headers: deletionAuth(oldBearer, deletionKey),
    });
    expect(retry.status).toBe(200);
    expect(await retry.json()).toEqual(deletionResult);
  });

  it('claims a live intent before provider I/O, blocks other auth, and returns 409 for a different key', async () => {
    const target = await makeUser('provider-intent');
    const deletionKey = crypto.randomUUID();
    const oauthAccess = `intent-access-${crypto.randomUUID()}`;
    const oauthRefresh = `intent-refresh-${crypto.randomUUID()}`;
    await env.DB
      .prepare(
        `INSERT INTO oauth_tokens
           (access_token,refresh_token,client_id,scope,expires_at,created_at,user_id)
         VALUES (?1,?2,'intent-client','mcp',?3,?4,?5)`,
      )
      .bind(
        oauthAccess,
        oauthRefresh,
        Math.floor(Date.now() / 1000) + 3600,
        Math.floor(Date.now() / 1000),
        target.user.id,
      )
      .run();
    expect(
      await storeAppleRefreshToken(
        env.DB,
        target.user.id,
        'caller-refresh-token',
      ),
    ).toBe(true);

    let releaseProvider!: () => void;
    const providerReleased = new Promise<void>((resolve) => {
      releaseProvider = resolve;
    });
    let providerStarted!: () => void;
    const providerStart = new Promise<void>((resolve) => {
      providerStarted = resolve;
    });
    let providerCalls = 0;
    const deletion = deleteUserAccount(
      env.DB,
      target.user.id,
      undefined,
      deletionKey,
      {
        appleConfig: {
          clientId: 'com.example.tresfort',
          teamId: 'test-team',
          keyId: 'test-key',
          privateKey: 'not-used-by-injected-revoker',
        },
        revokeAppleToken: async (_config, token) => {
          providerCalls += 1;
          expect(token).toBe('caller-refresh-token');
          providerStarted();
          await providerReleased;
        },
      },
    );
    await providerStart;

    const intent = await byId(
      'account_deletion_intents',
      'user_id',
      target.user.id,
    );
    expect(intent?.apple_revocation).toBeNull();
    expect(await byId('users', 'id', target.user.id)).not.toBeNull();

    // Once claimed, copied app and MCP credentials cannot perform normal work.
    expect(
      (await SELF.fetch(`${BASE}/api/me`, { headers: auth(target.jwt) })).status,
    ).toBe(401);
    expect(await validateBearer(env, oauthAccess)).toBeNull();
    await expect(
      env.DB
        .prepare(
          `INSERT INTO oauth_tokens
             (access_token,refresh_token,client_id,scope,expires_at,created_at,user_id)
           VALUES (?1,?2,'late-client','mcp',?3,?4,?5)`,
        )
        .bind(
          `late-${crypto.randomUUID()}`,
          `late-refresh-${crypto.randomUUID()}`,
          Math.floor(Date.now() / 1000) + 3600,
          Math.floor(Date.now() / 1000),
          target.user.id,
        )
        .run(),
    ).rejects.toThrow('deleting_user');

    // This is not cross-device completion: iOS must retain its local state.
    const collision = await SELF.fetch(`${BASE}/api/me`, {
      method: 'DELETE',
      headers: deletionAuth(target.jwt, crypto.randomUUID()),
    });
    expect(collision.status).toBe(409);
    expect(await collision.json()).toEqual({ error: 'conflict' });
    expect(await byId('users', 'id', target.user.id)).not.toBeNull();

    releaseProvider();
    expect(await deletion).toEqual({
      ok: true,
      owner_tombstoned: true,
      apple_revocation: 'revoked',
    });
    expect(providerCalls).toBe(1);

    // A receipt retry uses the stored outcome and never calls Apple again.
    expect(
      await deleteUserAccount(
        env.DB,
        target.user.id,
        undefined,
        deletionKey,
        {
          appleConfig: {
            clientId: 'com.example.tresfort',
            teamId: 'test-team',
            keyId: 'test-key',
            privateKey: 'not-used-by-injected-revoker',
          },
          revokeAppleToken: async () => {
            providerCalls += 1;
          },
        },
      ),
    ).toEqual({
      ok: true,
      owner_tombstoned: true,
      apple_revocation: 'revoked',
    });
    expect(providerCalls).toBe(1);
  });

  it('lets an old bearer resume its matching intent and keeps the first persisted provider outcome', async () => {
    const target = await makeUser('intent-resume');
    const deletionKey = crypto.randomUUID();
    const nowSeconds = Math.floor(Date.now() / 1000);
    const oldBearer = await issueAppJwt(target.user.id, 'test-secret', {
      nowSeconds,
      authTimeSeconds: nowSeconds - 6 * 60,
    });
    expect(
      await storeAppleRefreshToken(
        env.DB,
        target.user.id,
        'resume-refresh-token',
      ),
    ).toBe(true);

    let releaseProvider!: () => void;
    const providerReleased = new Promise<void>((resolve) => {
      releaseProvider = resolve;
    });
    let providerStarted!: () => void;
    const providerStart = new Promise<void>((resolve) => {
      providerStarted = resolve;
    });
    const first = deleteUserAccount(
      env.DB,
      target.user.id,
      undefined,
      deletionKey,
      {
        appleConfig: {
          clientId: 'com.example.tresfort',
          teamId: 'test-team',
          keyId: 'test-key',
          privateKey: 'not-used-by-injected-revoker',
        },
        revokeAppleToken: async () => {
          providerStarted();
          await providerReleased;
        },
      },
    );
    await providerStart;

    // The route has no signing credentials in test configuration, so this
    // matching continuation durably chooses manual_required and finalizes.
    const resumed = await SELF.fetch(`${BASE}/api/me`, {
      method: 'DELETE',
      headers: deletionAuth(oldBearer, deletionKey),
    });
    expect(resumed.status).toBe(200);
    expect(await resumed.json()).toEqual({
      ok: true,
      owner_tombstoned: true,
      apple_revocation: 'manual_required',
    });

    releaseProvider();
    // The delayed successful call cannot overwrite the durable first outcome.
    expect(await first).toEqual({
      ok: true,
      owner_tombstoned: true,
      apple_revocation: 'manual_required',
    });
  });

  it('deletes local data and persists manual handoff when Apple revocation fails', async () => {
    const target = await makeUser('provider-failure');
    const deletionKey = crypto.randomUUID();
    await storeAppleRefreshToken(
      env.DB,
      target.user.id,
      'failing-refresh-token',
    );
    let calls = 0;
    const result = await deleteUserAccount(
      env.DB,
      target.user.id,
      undefined,
      deletionKey,
      {
        appleConfig: {
          clientId: 'com.example.tresfort',
          teamId: 'test-team',
          keyId: 'test-key',
          privateKey: 'not-used-by-injected-revoker',
        },
        revokeAppleToken: async () => {
          calls += 1;
          throw new Error('offline-provider-failure');
        },
      },
    );
    expect(result).toEqual({
      ok: true,
      owner_tombstoned: true,
      apple_revocation: 'manual_required',
    });
    expect(calls).toBe(1);
    expect(await byId('users', 'id', target.user.id)).toBeNull();
    expect(
      (await byId('account_deletion_receipts', 'user_id', target.user.id))
        ?.apple_revocation,
    ).toBe('manual_required');
  });

  it('blocks deletion while a fresh Apple grant exchange is active', async () => {
    const target = await makeUser('fresh-exchange');
    const reservationId = crypto.randomUUID();
    expect(
      await beginAppleGrantExchange(
        env.DB,
        target.user.id,
        reservationId,
      ),
    ).toBe(true);
    // A second fresh exchange cannot replace the in-flight owner.
    expect(
      await beginAppleGrantExchange(
        env.DB,
        target.user.id,
        crypto.randomUUID(),
      ),
    ).toBe(false);

    const routeCollision = await SELF.fetch(`${BASE}/api/me`, {
      method: 'DELETE',
      headers: deletionAuth(target.jwt, crypto.randomUUID()),
    });
    expect(routeCollision.status).toBe(409);
    expect(await routeCollision.json()).toEqual({ error: 'conflict' });

    let providerCalls = 0;
    const result = await deleteUserAccount(
      env.DB,
      target.user.id,
      undefined,
      crypto.randomUUID(),
      {
        appleConfig: {
          clientId: 'com.example.tresfort',
          teamId: 'test-team',
          keyId: 'test-key',
          privateKey: 'not-used-by-injected-revoker',
        },
        revokeAppleToken: async () => {
          providerCalls += 1;
        },
      },
    );
    expect(result).toEqual({ error: 'conflict' });
    expect(providerCalls).toBe(0);
    expect(await byId('users', 'id', target.user.id)).not.toBeNull();
    expect(
      (await byId(
        'apple_grant_exchange_state',
        'user_id',
        target.user.id,
      ))?.reservation_id,
    ).toBe(reservationId);
  });

  it('atomically finishes an exchange so deletion revokes the newest token', async () => {
    const target = await makeUser('finished-exchange');
    await storeAppleRefreshToken(env.DB, target.user.id, 'older-refresh-token');
    const reservationId = crypto.randomUUID();
    expect(
      await beginAppleGrantExchange(
        env.DB,
        target.user.id,
        reservationId,
      ),
    ).toBe(true);
    expect(
      await finishAppleGrantExchange(
        env.DB,
        target.user.id,
        reservationId,
        'newest-refresh-token',
      ),
    ).toBe(true);
    expect(
      await acknowledgeAppleGrantExchange(
        env.DB,
        target.user.id,
        reservationId,
      ),
    ).toBe(true);
    expect(
      await byId('apple_grant_exchange_state', 'user_id', target.user.id),
    ).toBeNull();

    let revokedToken: string | null = null;
    expect(
      await deleteUserAccount(
        env.DB,
        target.user.id,
        undefined,
        crypto.randomUUID(),
        {
          appleConfig: {
            clientId: 'com.example.tresfort',
            teamId: 'test-team',
            keyId: 'test-key',
            privateKey: 'not-used-by-injected-revoker',
          },
          revokeAppleToken: async (_config, token) => {
            revokedToken = token;
          },
        },
      ),
    ).toEqual({
      ok: true,
      owner_tombstoned: true,
      apple_revocation: 'revoked',
    });
    expect(revokedToken).toBe('newest-refresh-token');
  });

  it('keeps exchange uncertainty sticky across later success and forces manual deletion', async () => {
    const target = await makeUser('uncertain-exchange');
    const uncertainReservation = crypto.randomUUID();
    expect(
      await beginAppleGrantExchange(
        env.DB,
        target.user.id,
        uncertainReservation,
      ),
    ).toBe(true);
    expect(
      await markAppleGrantExchangeUncertain(
        env.DB,
        target.user.id,
        uncertainReservation,
      ),
    ).toBe(true);

    const laterReservation = crypto.randomUUID();
    expect(
      await beginAppleGrantExchange(
        env.DB,
        target.user.id,
        laterReservation,
      ),
    ).toBe(true);
    expect(
      await finishAppleGrantExchange(
        env.DB,
        target.user.id,
        laterReservation,
        'later-known-token',
      ),
    ).toBe(true);
    expect(
      await acknowledgeAppleGrantExchange(
        env.DB,
        target.user.id,
        laterReservation,
      ),
    ).toBe(true);
    const sticky = await byId(
      'apple_grant_exchange_state',
      'user_id',
      target.user.id,
    );
    expect(sticky?.reservation_id).toBeNull();
    expect(sticky?.revocation_uncertain).toBe(1);

    let providerCalls = 0;
    const deletionKey = crypto.randomUUID();
    expect(
      await deleteUserAccount(
        env.DB,
        target.user.id,
        undefined,
        deletionKey,
        {
          appleConfig: {
            clientId: 'com.example.tresfort',
            teamId: 'test-team',
            keyId: 'test-key',
            privateKey: 'not-used-by-injected-revoker',
          },
          revokeAppleToken: async () => {
            providerCalls += 1;
          },
        },
      ),
    ).toEqual({
      ok: true,
      owner_tombstoned: true,
      apple_revocation: 'manual_required',
    });
    expect(providerCalls).toBe(0);
    expect(
      await byId('apple_grant_exchange_state', 'user_id', target.user.id),
    ).toBeNull();
    expect(
      (await byId('account_deletion_receipts', 'user_id', target.user.id))
        ?.apple_revocation,
    ).toBe('manual_required');
  });

  it('consumes a stale exchange as manual and rejects a finish serialized after an intent', async () => {
    const target = await makeUser('stale-exchange');
    const reservationId = crypto.randomUUID();
    expect(
      await beginAppleGrantExchange(
        env.DB,
        target.user.id,
        reservationId,
        Date.now() - 60_001,
      ),
    ).toBe(true);
    let providerCalls = 0;
    expect(
      await deleteUserAccount(
        env.DB,
        target.user.id,
        undefined,
        crypto.randomUUID(),
        {
          appleConfig: {
            clientId: 'com.example.tresfort',
            teamId: 'test-team',
            keyId: 'test-key',
            privateKey: 'not-used-by-injected-revoker',
          },
          revokeAppleToken: async () => {
            providerCalls += 1;
          },
        },
      ),
    ).toEqual({
      ok: true,
      owner_tombstoned: true,
      apple_revocation: 'manual_required',
    });
    expect(providerCalls).toBe(0);
    expect(
      await finishAppleGrantExchange(
        env.DB,
        target.user.id,
        reservationId,
        'too-late-token',
      ),
    ).toBe(false);

    // Deterministic defense-in-depth interleaving: even if a matching
    // reservation and an intent are observed together, finish cannot store.
    const live = await makeUser('finish-after-intent');
    const liveReservation = crypto.randomUUID();
    expect(
      await beginAppleGrantExchange(
        env.DB,
        live.user.id,
        liveReservation,
      ),
    ).toBe(true);
    await env.DB
      .prepare(
        `INSERT INTO account_deletion_intents
           (user_id,idempotency_key_sha256,apple_revocation,created_at)
         VALUES (?1,?2,NULL,?3)`,
      )
      .bind(live.user.id, '0'.repeat(64), Date.now())
      .run();
    expect(
      await finishAppleGrantExchange(
        env.DB,
        live.user.id,
        liveReservation,
        'must-not-store',
      ),
    ).toBe(false);
    expect(
      await byId('apple_refresh_tokens', 'user_id', live.user.id),
    ).toBeNull();
    expect(
      (await byId(
        'apple_grant_exchange_state',
        'user_id',
        live.user.id,
      ))?.reservation_id,
    ).toBe(liveReservation);
  });

  it('atomically removes only the caller and transfers shared groups', async () => {
    const owner = await ensureOwnerUser(env.DB, undefined);
    expect(owner).not.toBeNull();
    const target = await makeUser('target');
    const olderMember = await makeUser('older-member');
    const newerMember = await makeUser('newer-member');
    const targetGraph = await seedTrainingGraph(target.user.id, 'target');
    const survivorGraph = await seedTrainingGraph(
      olderMember.user.id,
      'survivor',
    );
    const ts = Date.now();
    const sharedGroup = `shared-${crypto.randomUUID()}`;
    const emptyGroup = `empty-${crypto.randomUUID()}`;
    const foreignGroup = `foreign-${crypto.randomUUID()}`;
    const targetInvite = `target-invite-${crypto.randomUUID()}`;
    const survivorInvite = `survivor-invite-${crypto.randomUUID()}`;
    const deletionKey = crypto.randomUUID();

    await env.DB.batch([
      env.DB
        .prepare(
          `INSERT INTO groups (id,name,created_by,created_at)
           VALUES (?1,'Shared',?2,?3)`,
        )
        .bind(sharedGroup, target.user.id, ts),
      env.DB
        .prepare(
          `INSERT INTO group_members (group_id,user_id,joined_at)
           VALUES (?1,?2,?3), (?1,?4,?5), (?1,?6,?7)`,
        )
        .bind(
          sharedGroup,
          target.user.id,
          ts,
          olderMember.user.id,
          ts + 10,
          newerMember.user.id,
          ts + 20,
        ),
      env.DB
        .prepare(
          `INSERT INTO groups (id,name,created_by,created_at)
           VALUES (?1,'Empty',?2,?3)`,
        )
        .bind(emptyGroup, target.user.id, ts),
      env.DB
        .prepare(
          `INSERT INTO group_members (group_id,user_id,joined_at)
           VALUES (?1,?2,?3)`,
        )
        .bind(emptyGroup, target.user.id, ts),
      env.DB
        .prepare(
          `INSERT INTO groups (id,name,created_by,created_at)
           VALUES (?1,'Foreign',?2,?3)`,
        )
        .bind(foreignGroup, olderMember.user.id, ts),
      env.DB
        .prepare(
          `INSERT INTO group_members (group_id,user_id,joined_at)
           VALUES (?1,?2,?3), (?1,?4,?5)`,
        )
        .bind(
          foreignGroup,
          olderMember.user.id,
          ts,
          target.user.id,
          ts + 10,
        ),
      env.DB
        .prepare(
          `INSERT INTO group_invites
             (code,group_id,created_by,created_at)
           VALUES (?1,?2,?3,?4)`,
        )
        .bind(targetInvite, sharedGroup, target.user.id, ts),
      env.DB
        .prepare(
          `INSERT INTO group_invites
             (code,group_id,created_by,created_at,used_at,used_by)
           VALUES (?1,?2,?3,?4,?4,?5)`,
        )
        .bind(
          survivorInvite,
          sharedGroup,
          olderMember.user.id,
          ts,
          target.user.id,
        ),
    ]);

    const response = await SELF.fetch(`${BASE}/api/me`, {
      method: 'DELETE',
      headers: deletionAuth(target.jwt, deletionKey),
    });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      ok: true,
      owner_tombstoned: false,
      apple_revocation: 'manual_required',
    });

    expect(await byId('users', 'id', target.user.id)).toBeNull();
    expect(await byId('plans', 'id', targetGraph.planId)).toBeNull();
    expect(await byId('day_templates', 'id', targetGraph.dayId)).toBeNull();
    expect(
      await byId(
        'template_exercises',
        'id',
        targetGraph.templateExerciseId,
      ),
    ).toBeNull();
    expect(await byId('sessions', 'id', targetGraph.sessionId)).toBeNull();
    expect(await byId('set_logs', 'id', targetGraph.setId)).toBeNull();
    expect(
      await byId('session_aliases', 'alias_session_id', targetGraph.aliasId),
    ).toBeNull();
    expect(
      await byId('session_load_exports', 'session_id', targetGraph.sessionId),
    ).toBeNull();
    expect(await byId('notes', 'id', targetGraph.noteId)).toBeNull();
    expect(await byId('audit_log', 'id', targetGraph.auditId)).toBeNull();
    expect(await byId('external_events', 'id', targetGraph.eventId)).toBeNull();
    expect(
      await byId(
        'external_activities',
        'id',
        targetGraph.externalActivityId,
      ),
    ).toBeNull();
    expect(await byId('activities', 'id', targetGraph.activityId)).toBeNull();
    expect(await byId('oauth_codes', 'code', targetGraph.oauthCode)).toBeNull();
    expect(
      await byId('oauth_tokens', 'access_token', targetGraph.oauthAccess),
    ).toBeNull();
    expect(
      await byId(
        'intervals_oauth_states',
        'state',
        targetGraph.intervalsState,
      ),
    ).toBeNull();

    // Another member's complete graph remains intact.
    expect(await byId('users', 'id', olderMember.user.id)).not.toBeNull();
    expect(await byId('plans', 'id', survivorGraph.planId)).not.toBeNull();
    expect(
      await byId('activities', 'id', survivorGraph.activityId),
    ).not.toBeNull();

    const shared = await byId('groups', 'id', sharedGroup);
    expect(shared?.created_by).toBe(olderMember.user.id);
    expect(await byId('groups', 'id', emptyGroup)).toBeNull();
    expect((await byId('groups', 'id', foreignGroup))?.created_by).toBe(
      olderMember.user.id,
    );
    expect(
      await env.DB
        .prepare(
          'SELECT 1 AS x FROM group_members WHERE group_id=?1 AND user_id=?2',
        )
        .bind(sharedGroup, target.user.id)
        .first(),
    ).toBeNull();
    expect(await byId('group_invites', 'code', targetInvite)).toBeNull();
    expect(
      (await byId('group_invites', 'code', survivorInvite))?.used_by,
    ).toBeNull();

    // Every copied app JWT is revoked by the now-missing live subject.
    const oldBearer = await SELF.fetch(`${BASE}/api/me`, {
      headers: auth(target.jwt),
    });
    expect(oldBearer.status).toBe(401);
    const renew = await SELF.fetch(`${BASE}/auth/renew`, {
      method: 'POST',
      headers: auth(target.jwt),
    });
    expect(renew.status).toBe(401);

    // A lost success response is safe to retry with the same key even though
    // the JWT principal row is gone. A different key cannot probe or reuse the
    // receipt.
    const retry = await SELF.fetch(`${BASE}/api/me`, {
      method: 'DELETE',
      headers: deletionAuth(target.jwt, deletionKey),
    });
    expect(retry.status).toBe(200);
    expect(await retry.json()).toEqual({
      ok: true,
      owner_tombstoned: false,
      apple_revocation: 'manual_required',
    });
    const differentRetry = await SELF.fetch(`${BASE}/api/me`, {
      method: 'DELETE',
      headers: deletionAuth(target.jwt, crypto.randomUUID()),
    });
    expect(differentRetry.status).toBe(404);
    expect(await differentRetry.json()).toEqual({
      error: 'account_not_found',
    });

    // Late in-flight writes that passed authentication before deletion cannot
    // recreate rows in tables without users foreign keys.
    await expect(
      env.DB
        .prepare(
          `INSERT INTO external_activities
             (id,user_id,source,external_id,date,kind,synced_at)
           VALUES (?1,?2,'healthkit',?3,'2026-08-29','walk',?4)`,
        )
        .bind(
          `late-activity-${crypto.randomUUID()}`,
          target.user.id,
          `late-upstream-${crypto.randomUUID()}`,
          Date.now(),
        )
        .run(),
    ).rejects.toThrow('deleted_user');
    await expect(
      env.DB
        .prepare(
          `INSERT INTO oauth_tokens
             (access_token,refresh_token,client_id,scope,expires_at,created_at,user_id)
           VALUES (?1,?2,'late-client','mcp',?3,?4,?5)`,
        )
        .bind(
          `late-access-${crypto.randomUUID()}`,
          `late-refresh-${crypto.randomUUID()}`,
          Date.now() + 60_000,
          Date.now(),
          target.user.id,
        )
        .run(),
    ).rejects.toThrow('deleted_user');
  });

  it('tombstones a seeded owner without promoting or recreating a member', async () => {
    const owner = await ensureOwnerUser(env.DB, undefined);
    expect(owner).not.toBeNull();
    const seededOwner = owner!;
    const ownerJwt = await issueAppJwt(seededOwner.id, 'test-secret');
    const deletionKey = crypto.randomUUID();
    const survivor = await makeUser('owner-survivor');
    const groupId = `owner-group-${crypto.randomUUID()}`;
    const legacyAccess = `legacy-owner-${crypto.randomUUID()}`;
    const ts = Date.now();
    await env.DB.batch([
      env.DB
        .prepare(
          `INSERT INTO groups (id,name,created_by,created_at)
           VALUES (?1,'Owner Shared',?2,?3)`,
        )
        .bind(groupId, seededOwner.id, ts),
      env.DB
        .prepare(
          `INSERT INTO group_members (group_id,user_id,joined_at)
           VALUES (?1,?2,?3), (?1,?4,?5)`,
        )
        .bind(groupId, seededOwner.id, ts, survivor.user.id, ts + 1),
      env.DB
        .prepare(
          `INSERT INTO oauth_tokens
             (access_token,refresh_token,client_id,scope,expires_at,created_at)
           VALUES (?1,?2,'legacy-client','mcp',?3,?4)`,
        )
        .bind(
          legacyAccess,
          `legacy-refresh-${crypto.randomUUID()}`,
          ts + 60_000,
          ts,
        ),
    ]);

    const response = await SELF.fetch(`${BASE}/api/me`, {
      method: 'DELETE',
      headers: deletionAuth(ownerJwt, deletionKey),
    });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      ok: true,
      owner_tombstoned: true,
      apple_revocation: 'manual_required',
    });

    expect(await byId('users', 'id', seededOwner.id)).toBeNull();
    expect(await findOwnerRow(env.DB, undefined)).toBeNull();
    expect(await ensureOwnerUser(env.DB, undefined)).toBeNull();
    expect(
      await claimOrCreateOwner(
        env.DB,
        seededOwner.apple_sub,
        null,
        null,
        false,
      ),
    ).toBeNull();
    expect((await byId('groups', 'id', groupId))?.created_by).toBe(
      survivor.user.id,
    );
    expect(
      await byId('oauth_tokens', 'access_token', legacyAccess),
    ).toBeNull();

    const tombstone = await env.DB
      .prepare('SELECT * FROM owner_deletion_tombstone WHERE singleton=1')
      .first<{ apple_sub_sha256: string; deleted_at: number }>();
    expect(tombstone?.apple_sub_sha256).toMatch(/^[0-9a-f]{64}$/);
    expect(tombstone?.apple_sub_sha256).not.toBe(seededOwner.apple_sub);
    expect(tombstone?.deleted_at).toBeGreaterThan(0);

    // The open-sign-in path performs the digest check in the INSERT itself,
    // so a stale request cannot recreate this exact identity after deletion.
    expect(
      await upsertUserUnlessDeletedOwner(
        env.DB,
        seededOwner.apple_sub,
        null,
        null,
      ),
    ).toBeNull();
    expect(
      await upsertUserUnlessDeletedOwner(
        env.DB,
        `new-member-${crypto.randomUUID()}`,
        null,
        'New member',
      ),
    ).not.toBeNull();

    const staticMcp = await SELF.fetch(`${BASE}/mcp`, {
      method: 'POST',
      headers: {
        Authorization: 'Bearer test-mcp-token',
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        jsonrpc: '2.0',
        id: 1,
        method: 'tools/list',
        params: {},
      }),
    });
    expect(staticMcp.status).toBe(401);

    const devRecreate = await SELF.fetch(`${BASE}/auth/dev`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ secret: 'test-dev' }),
    });
    expect(devRecreate.status).toBe(410);
    expect(await devRecreate.json()).toEqual({
      error: 'owner_account_deleted',
    });

    // The survivor remains an ordinary account; they are never promoted.
    const survivorMe = await SELF.fetch(`${BASE}/api/me`, {
      headers: auth(survivor.jwt),
    });
    expect(survivorMe.status).toBe(200);
    expect((await survivorMe.json<any>()).claude.is_owner).toBe(false);

    // Removing only the identity tombstone is not sufficient recovery. The
    // durable owner-marked receipt keeps legacy no-allowlist lookup from
    // promoting the earliest survivor or silently seeding another owner.
    await env.DB
      .prepare('DELETE FROM owner_deletion_tombstone WHERE singleton = 1')
      .run();
    expect(await findOwnerRow(env.DB, undefined)).toBeNull();
    expect(await ensureOwnerUser(env.DB, undefined)).toBeNull();

    const staticAfterTombstoneRemoval = await SELF.fetch(`${BASE}/mcp`, {
      method: 'POST',
      headers: {
        Authorization: 'Bearer test-mcp-token',
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        jsonrpc: '2.0',
        id: 2,
        method: 'tools/list',
        params: {},
      }),
    });
    expect(staticAfterTombstoneRemoval.status).toBe(401);
    expect((await SELF.fetch(`${BASE}/api/me`, {
      headers: auth(survivor.jwt),
    })).status).toBe(200);

    // A configured replacement is explicit recovery and gets a new row; it
    // never aliases or promotes the surviving member.
    const replacement = await ensureOwnerUser(
      env.DB,
      `replacement-owner-${crypto.randomUUID()}`,
    );
    expect(replacement).not.toBeNull();
    expect(replacement!.id).not.toBe(survivor.user.id);
  });
});
