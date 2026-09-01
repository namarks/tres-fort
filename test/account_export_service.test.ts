import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { issueAppJwt } from '../src/auth';
import { createInvite, exportUserData, upsertUser } from '../src/db';

const BASE = 'https://lift-coach.test';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

describe('account export projection', () => {
  it('reads the complete projection through one D1 batch snapshot', async () => {
    const userId = crypto.randomUUID();
    const preparedSql: string[] = [];
    let batchCalls = 0;
    let batchSize = 0;
    const fakeDb = {
      prepare(sql: string) {
        const statement = {
          bind(..._values: unknown[]) {
            preparedSql.push(sql);
            return statement;
          },
        };
        return statement;
      },
      async batch(statements: unknown[]) {
        batchCalls += 1;
        batchSize = statements.length;
        return Array.from({ length: 15 }, (_, index) => ({
          results: index === 0 ? [{ id: userId }] : [],
        }));
      },
    } as unknown as D1Database;

    const exported = await exportUserData(fakeDb, userId);

    expect(batchCalls).toBe(1);
    expect(batchSize).toBe(15);
    expect(preparedSql).toHaveLength(15);
    expect(exported).toMatchObject({
      account: { id: userId },
      training: { plans: [], sessions: [], set_logs: [] },
      group_memberships: [],
    });
  });

  it('contains the caller training graph without secrets or another member data', async () => {
    const suffix = crypto.randomUUID();
    const caller = await upsertUser(
      env.DB,
      `export-caller-sub-${suffix}`,
      `export-caller-${suffix}@test`,
      'Export Caller',
    );
    const other = await upsertUser(
      env.DB,
      `export-other-sub-${suffix}`,
      `export-other-${suffix}@test`,
      'Export Other',
    );
    const callerSecret = `caller-secret-${suffix}`;
    const otherPrivate = `other-private-${suffix}`;
    const exerciseId = `export-exercise-${suffix}`;
    const planId = `export-plan-${suffix}`;
    const dayId = `export-day-${suffix}`;
    const templateExerciseId = `export-template-exercise-${suffix}`;
    const sessionId = `export-session-${suffix}`;
    const setId = `export-set-${suffix}`;
    const groupId = `export-group-${suffix}`;
    const ts = Date.now();

    await env.DB.batch([
      env.DB.prepare(
        `UPDATE users SET intervals_api_key=?2,
                          mcp_passphrase_hash=?2,
                          mcp_passphrase_salt=?2
         WHERE id=?1`,
      ).bind(caller.id, callerSecret),
      env.DB.prepare(
        `INSERT INTO exercises
           (id,name,primary_muscle,unit,aliases,created_at)
         VALUES (?1,'Export Lift','legs','lb','["export lift alias"]',?2)`,
      ).bind(exerciseId, ts),
      env.DB.prepare(
        `INSERT INTO exercises
           (id,name,primary_muscle,unit,created_at)
         VALUES (?1,'Unreferenced Lift','back','lb',?2)`,
      ).bind(`unreferenced-exercise-${suffix}`, ts),
      env.DB.prepare(
        `INSERT INTO plans
           (id,user_id,name,status,version,created_at,updated_at)
         VALUES (?1,?2,'Caller Plan','active',1,?3,?3)`,
      ).bind(planId, caller.id, ts),
      env.DB.prepare(
        `INSERT INTO day_templates
           (id,plan_id,name,order_index,created_at,updated_at)
         VALUES (?1,?2,'Caller Day',0,?3,?3)`,
      ).bind(dayId, planId, ts),
      env.DB.prepare(
        `INSERT INTO template_exercises
           (id,day_template_id,exercise_id,order_index,target_sets,target_reps,
            rest_seconds,created_at,updated_at)
         VALUES (?1,?2,?3,0,3,5,120,?4,?4)`,
      ).bind(templateExerciseId, dayId, exerciseId, ts),
      env.DB.prepare(
        `INSERT INTO sessions
           (id,user_id,plan_id,day_template_id,date,status,created_at,updated_at)
         VALUES (?1,?2,?3,?4,'2026-08-29','completed',?5,?5)`,
      ).bind(sessionId, caller.id, planId, dayId, ts),
      env.DB.prepare(
        `INSERT INTO set_logs
           (id,session_id,exercise_id,template_exercise_id,set_index,weight,reps,
            logged_at,source)
         VALUES (?1,?2,?3,?4,1,100,5,?5,'ios')`,
      ).bind(setId, sessionId, exerciseId, templateExerciseId, ts),
      env.DB.prepare(
        `INSERT INTO notes (id,user_id,scope,author,body,created_at)
         VALUES (?1,?2,'user','ios','caller note',?3)`,
      ).bind(`export-note-${suffix}`, caller.id, ts),
      env.DB.prepare(
        `INSERT INTO notes (id,user_id,scope,author,body,created_at)
         VALUES (?1,?2,'user','ios',?3,?4)`,
      ).bind(`export-other-note-${suffix}`, other.id, otherPrivate, ts),
      env.DB.prepare(
        `INSERT INTO activities
           (id,user_id,date,type,logged_at,source)
         VALUES (?1,?2,'2026-08-29','walk',?3,'ios')`,
      ).bind(`export-activity-${suffix}`, caller.id, ts),
      env.DB.prepare(
        `INSERT INTO activities
           (id,user_id,date,type,title,logged_at,source)
         VALUES (?1,?2,'2026-08-29','walk',?3,?4,'ios')`,
      ).bind(`export-other-activity-${suffix}`, other.id, otherPrivate, ts),
      env.DB.prepare(
        `INSERT INTO groups (id,name,created_by,created_at)
         VALUES (?1,'Shared Group',?2,?3)`,
      ).bind(groupId, other.id, ts),
      env.DB.prepare(
        `INSERT INTO group_members (group_id,user_id,display_name,joined_at)
         VALUES (?1,?2,'Caller in group',?4),
                (?1,?3,?5,?4)`,
      ).bind(groupId, caller.id, other.id, ts, otherPrivate),
    ]);

    const invite = await createInvite(env.DB, caller.id, groupId);
    const legacyInviteAuditId = `export-invite-audit-${suffix}`;
    await env.DB
      .prepare(
        `INSERT INTO audit_log
           (id,user_id,actor,tool,args,result,created_at)
         VALUES (?1,?2,'ios','create_invite',?3,'created',?4)`,
      )
      .bind(
        legacyInviteAuditId,
        caller.id,
        JSON.stringify({ group_id: groupId, code: invite.code }),
        ts,
      )
      .run();

    const exported = await exportUserData(env.DB, caller.id);
    expect(exported).not.toBeNull();
    if (!exported) throw new Error('expected caller export');
    const serialized = JSON.stringify(exported);
    const training = exported.training as {
      plans: Array<{ id: string }>;
      day_templates: Array<{ id: string }>;
      template_exercises: Array<{ id: string }>;
      exercises: Array<{
        id: string;
        name: string;
        unit: string;
        aliases: string;
      }>;
      sessions: Array<{ id: string }>;
      set_logs: Array<{ id: string }>;
      audit_log: Array<{ id: string; tool: string; args: string }>;
    };

    expect(exported.schema_version).toBe(1);
    expect((exported.account as { id: string }).id).toBe(caller.id);
    expect(training.plans.map((row) => row.id)).toEqual([planId]);
    expect(training.day_templates.map((row) => row.id)).toEqual([dayId]);
    expect(training.template_exercises.map((row) => row.id)).toEqual([
      templateExerciseId,
    ]);
    expect(training.exercises).toEqual([
      expect.objectContaining({
        id: exerciseId,
        name: 'Export Lift',
        unit: 'lb',
        aliases: '["export lift alias"]',
      }),
    ]);
    expect(training.sessions.map((row) => row.id)).toEqual([sessionId]);
    expect(training.set_logs.map((row) => row.id)).toEqual([setId]);
    const legacyInviteAudit = training.audit_log.find(
      (row) => row.id === legacyInviteAuditId,
    );
    expect(legacyInviteAudit).toBeDefined();
    expect(JSON.parse(legacyInviteAudit?.args ?? '{}')).toEqual({
      group_id: groupId,
    });
    expect(exported.group_memberships).toEqual([
      {
        group_id: groupId,
        group_name: 'Shared Group',
        display_name: 'Caller in group',
        joined_at: ts,
      },
    ]);
    expect(serialized).not.toContain(callerSecret);
    expect(serialized).not.toContain(invite.code);
    expect(serialized).not.toContain(other.id);
    expect(serialized).not.toContain(otherPrivate);
    expect(await exportUserData(env.DB, crypto.randomUUID())).toBeNull();
  });
});

describe('GET /api/me/export', () => {
  it('requires an authenticated app session', async () => {
    const response = await SELF.fetch(`${BASE}/api/me/export`);
    expect(response.status).toBe(401);
  });

  it('downloads only the signed caller as a non-cacheable JSON attachment', async () => {
    const suffix = crypto.randomUUID();
    const caller = await upsertUser(
      env.DB,
      `route-export-caller-sub-${suffix}`,
      `route-export-caller-${suffix}@test`,
      'Route Export Caller',
    );
    const other = await upsertUser(
      env.DB,
      `route-export-other-sub-${suffix}`,
      `route-export-other-${suffix}@test`,
      'Route Export Other',
    );
    const jwt = await issueAppJwt(caller.id, 'test-secret');

    // Even a caller-supplied selector is inert: the JWT subject remains the
    // only principal accepted by this endpoint.
    const response = await SELF.fetch(
      `${BASE}/api/me/export?user_id=${encodeURIComponent(other.id)}`,
      { headers: { Authorization: `Bearer ${jwt}` } },
    );

    expect(response.status).toBe(200);
    expect(response.headers.get('content-type')).toBe(
      'application/json; charset=utf-8',
    );
    expect(response.headers.get('content-disposition')).toMatch(
      /^attachment; filename="tres-fort-account-export-\d{4}-\d{2}-\d{2}\.json"$/,
    );
    expect(response.headers.get('cache-control')).toBe('no-store');
    expect(response.headers.get('x-content-type-options')).toBe('nosniff');

    const exported = await response.json<{
      schema_version: number;
      account: { id: string; email: string };
    }>();
    expect(exported.schema_version).toBe(1);
    expect(exported.account.id).toBe(caller.id);
    expect(exported.account.email).toBe(caller.email);
    expect(JSON.stringify(exported)).not.toContain(other.id);
    expect(JSON.stringify(exported)).not.toContain(other.email);
  });
});
