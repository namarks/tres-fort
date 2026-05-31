// #926 — getOrCreateSession must HONOR an explicitly-provided day_template_id
// on a row that doesn't have one yet, without ever auto-resolving from the
// schedule (that would freeze a stale template, violating "calendar is
// computed, not stored") and without clobbering an existing pin.
import { env, applyD1Migrations } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { getOrCreateSession } from '../src/db';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

async function makeUserAndPlan(): Promise<{
  userId: string;
  planId: string;
  dayA: string;
  dayB: string;
}> {
  const userId = crypto.randomUUID();
  const planId = crypto.randomUUID();
  const dayA = crypto.randomUUID();
  const dayB = crypto.randomUUID();
  const ts = Date.now();
  await env.DB.prepare(
    'INSERT INTO users (id,apple_sub,email,display_name,created_at) VALUES (?1,?2,?3,?4,?5)',
  )
    .bind(userId, `sub-${userId}`, null, 'T', ts)
    .run();
  await env.DB.prepare(
    "INSERT INTO plans (id,user_id,name,status,version,meta,created_at,updated_at) VALUES (?1,?2,?3,'active',1,NULL,?4,?4)",
  )
    .bind(planId, userId, 'P', ts)
    .run();
  // Real day_templates so the sessions FK to day_template_id holds.
  for (const [id, label] of [
    [dayA, 'A'],
    [dayB, 'B'],
  ] as const) {
    await env.DB.prepare(
      'INSERT INTO day_templates (id,plan_id,name,day_label,order_index,notes,created_at,updated_at) VALUES (?1,?2,?3,?4,?5,NULL,?6,?6)',
    )
      .bind(id, planId, `Day ${label}`, label, label === 'A' ? 0 : 1, ts)
      .run();
  }
  return { userId, planId, dayA, dayB };
}

describe('#926 getOrCreateSession honors an explicit day_template_id', () => {
  it('backfills a NULL slot when a later caller passes an explicit template', async () => {
    const { userId, planId, dayA } = await makeUserAndPlan();
    const date = '2026-06-10';
    // First creator (GET /today, MCP log_set) passes null → template resolved
    // from the schedule at display time.
    const first = await getOrCreateSession(env.DB, userId, planId, date, null);
    expect(first.day_template_id).toBeNull();
    // Later explicit creator (POST /api/sessions / iOS createSession) names
    // the day → must be honored on the SAME (user,date) row, not dropped.
    const second = await getOrCreateSession(env.DB, userId, planId, date, dayA);
    expect(second.id).toBe(first.id);
    expect(second.day_template_id).toBe(dayA);
  });

  it('never clobbers an existing pin', async () => {
    const { userId, planId, dayA, dayB } = await makeUserAndPlan();
    const date = '2026-06-11';
    await getOrCreateSession(env.DB, userId, planId, date, dayA);
    const again = await getOrCreateSession(env.DB, userId, planId, date, dayB);
    expect(again.day_template_id).toBe(dayA);
  });

  it('passing null leaves NULL (schedule stays the source of truth)', async () => {
    const { userId, planId } = await makeUserAndPlan();
    const date = '2026-06-12';
    await getOrCreateSession(env.DB, userId, planId, date, null);
    const again = await getOrCreateSession(env.DB, userId, planId, date, null);
    expect(again.day_template_id).toBeNull();
  });
});
