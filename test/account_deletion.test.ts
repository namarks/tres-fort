import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { issueAppJwt } from '../src/auth';
import {
  claimOrCreateOwner,
  ensureOwnerUser,
  findOwnerRow,
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
  it('requires an authenticated app session', async () => {
    const response = await SELF.fetch(`${BASE}/api/me`, { method: 'DELETE' });
    expect(response.status).toBe(401);
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
    });
    const differentRetry = await SELF.fetch(`${BASE}/api/me`, {
      method: 'DELETE',
      headers: deletionAuth(target.jwt, crypto.randomUUID()),
    });
    expect(differentRetry.status).toBe(404);

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
  });
});
