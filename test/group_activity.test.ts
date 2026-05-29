// Group activity-series endpoint (week/month/year zoom data).
//
// Covers GET /api/groups/:id/activity?days=N: per-member per-day counts
// kept by source (sessions / rides / activities-by-type), sparse rows,
// the trailing-window clamp, cross-member independence, planned-session
// exclusion, soft-delete handling, and the 404/403 guards.
import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { issueAppJwt } from '../src/auth';

const BASE = 'https://lift-coach.test';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

async function devJwt(): Promise<{ id: string; jwt: string }> {
  const r = await SELF.fetch(`${BASE}/auth/dev`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ secret: 'test-dev' }),
  });
  expect(r.status).toBe(200);
  const body = await r.json<{ jwt: string; user: { id: string } }>();
  return { id: body.user.id, jwt: body.jwt };
}

const headers = (jwt: string) => ({
  'content-type': 'application/json',
  Authorization: `Bearer ${jwt}`,
});

async function makeUser(label: string): Promise<{ id: string; jwt: string }> {
  const id = crypto.randomUUID();
  await env.DB.prepare(
    'INSERT INTO users (id,apple_sub,email,display_name,created_at,timezone) VALUES (?1,?2,?3,?4,?5,NULL)',
  )
    .bind(id, `sub-${label}-${id}`, `${label}@test`, label, Date.now())
    .run();
  return { id, jwt: await issueAppJwt(id, 'test-secret') };
}

async function createGroup(jwt: string, name: string): Promise<string> {
  const r = await SELF.fetch(`${BASE}/api/groups`, {
    method: 'POST',
    headers: headers(jwt),
    body: JSON.stringify({ name }),
  });
  expect(r.status).toBe(201);
  return (await r.json<{ id: string }>()).id;
}

async function inviteAndJoin(creatorJwt: string, joinerJwt: string, groupId: string) {
  const mint = await SELF.fetch(`${BASE}/api/groups/${groupId}/invites`, {
    method: 'POST',
    headers: headers(creatorJwt),
    body: JSON.stringify({}),
  });
  const { code } = await mint.json<{ code: string }>();
  const join = await SELF.fetch(`${BASE}/api/groups/join`, {
    method: 'POST',
    headers: headers(joinerJwt),
    body: JSON.stringify({ code }),
  });
  expect(join.status).toBe(200);
}

// ---- seeders, one per source ------------------------------------------

async function seedActivity(
  userId: string,
  date: string,
  type: string,
  deletedAt: number | null = null,
) {
  await env.DB.prepare(
    `INSERT INTO activities
       (id,user_id,date,type,title,duration_minutes,notes,logged_at,source,deleted_at)
     VALUES (?1,?2,?3,?4,NULL,30,NULL,?5,'ios',?6)`,
  )
    .bind(crypto.randomUUID(), userId, date, type, Date.now(), deletedAt)
    .run();
}

async function seedRide(userId: string, date: string, deletedAt: number | null = null) {
  await env.DB.prepare(
    `INSERT INTO external_activities
       (id,user_id,source,external_id,date,kind,synced_at,deleted_at)
     VALUES (?1,?2,'intervals',?3,?4,'ride',?5,?6)`,
  )
    .bind(crypto.randomUUID(), userId, crypto.randomUUID(), date, Date.now(), deletedAt)
    .run();
}

// A started/completed strength session needs a plan + day_template (FKs).
async function seedSession(userId: string, date: string, status = 'completed') {
  const planId = crypto.randomUUID();
  const dayId = crypto.randomUUID();
  const ts = Date.now();
  await env.DB.prepare(
    "INSERT INTO plans (id,user_id,name,status,version,meta,created_at,updated_at) VALUES (?1,?2,'P','active',1,NULL,?3,?3)",
  )
    .bind(planId, userId, ts)
    .run();
  await env.DB.prepare(
    "INSERT INTO day_templates (id,plan_id,name,day_label,order_index,notes,created_at,updated_at) VALUES (?1,?2,'Push','A',0,NULL,?3,?3)",
  )
    .bind(dayId, planId, ts)
    .run();
  await env.DB.prepare(
    'INSERT INTO sessions (id,user_id,plan_id,day_template_id,date,status,started_at,completed_at,perceived_fatigue,notes,created_at,updated_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?7,NULL,NULL,?7,?7)',
  )
    .bind(crypto.randomUUID(), userId, planId, dayId, date, status, ts)
    .run();
}

function todayUtc(): string {
  return new Date().toISOString().slice(0, 10);
}
function addDaysIso(ymd: string, n: number): string {
  return new Date(Date.parse(`${ymd}T00:00:00Z`) + n * 86_400_000).toISOString().slice(0, 10);
}

async function fetchSeries(jwt: string, groupId: string, days?: number) {
  const q = days == null ? '' : `?days=${days}`;
  const r = await SELF.fetch(`${BASE}/api/groups/${groupId}/activity${q}`, {
    headers: headers(jwt),
  });
  return r;
}

describe('group activity series: authorization', () => {
  it('non-member -> 403', async () => {
    const a = await devJwt();
    const b = await makeUser('act-nonmember');
    const groupId = await createGroup(a.jwt, 'private-act');
    const r = await fetchSeries(b.jwt, groupId);
    expect(r.status).toBe(403);
  });

  it('unknown group id -> 404', async () => {
    const a = await devJwt();
    const r = await fetchSeries(a.jwt, crypto.randomUUID());
    expect(r.status).toBe(404);
  });
});

describe('group activity series: per-day counts by source', () => {
  it('buckets sessions / rides / activities-by-type per civil date', async () => {
    const a = await devJwt();
    const groupId = await createGroup(a.jwt, 'sources');
    const today = todayUtc();
    const d1 = addDaysIso(today, -1);

    await seedSession(a.id, today); // lift today
    await seedRide(a.id, today); // ride today
    await seedActivity(a.id, today, 'pilates'); // pilates today
    await seedActivity(a.id, d1, 'yoga'); // yoga yesterday
    await seedActivity(a.id, d1, 'yoga'); // second yoga yesterday → count 2

    const r = await fetchSeries(a.jwt, groupId);
    expect(r.status).toBe(200);
    const body = await r.json<any>();
    expect(body.group_id).toBe(groupId);
    const me = body.members.find((m: any) => m.user_id === a.id);
    const byDate: Record<string, any> = {};
    for (const d of me.days) byDate[d.date] = d;

    expect(byDate[today].sessions).toBe(1);
    expect(byDate[today].rides).toBe(1);
    expect(byDate[today].activities.pilates).toBe(1);
    expect(byDate[d1].activities.yoga).toBe(2);
    // sparse: only the two active dates are present.
    expect(me.days.length).toBe(2);
  });

  it('planned sessions are excluded; soft-deleted rides/activities are excluded', async () => {
    const a = await devJwt();
    const groupId = await createGroup(a.jwt, 'excluded');
    const today = todayUtc();

    await seedSession(a.id, today, 'planned'); // intent, not activity
    await seedRide(a.id, today, Date.now()); // soft-deleted
    await seedActivity(a.id, today, 'walk', Date.now()); // soft-deleted

    const r = await fetchSeries(a.jwt, groupId);
    const body = await r.json<any>();
    const me = body.members.find((m: any) => m.user_id === a.id);
    expect(me.days.length).toBe(0);
  });
});

describe('group activity series: window + independence', () => {
  it('days window clamps how far back rows are returned', async () => {
    const a = await devJwt();
    const groupId = await createGroup(a.jwt, 'window');
    const today = todayUtc();
    await seedActivity(a.id, today, 'pilates'); // in window
    await seedActivity(a.id, addDaysIso(today, -10), 'pilates'); // out of a 7d window

    const r = await fetchSeries(a.jwt, groupId, 7);
    const body = await r.json<any>();
    expect(body.days).toBe(7);
    const me = body.members.find((m: any) => m.user_id === a.id);
    expect(me.days.length).toBe(1);
    expect(me.days[0].date).toBe(today);
  });

  it('each member computed in isolation', async () => {
    const a = await devJwt();
    const b = await makeUser('act-iso');
    const groupId = await createGroup(a.jwt, 'act-iso-grp');
    await inviteAndJoin(a.jwt, b.jwt, groupId);
    const today = todayUtc();
    await seedActivity(a.id, today, 'pilates');
    await seedActivity(a.id, addDaysIso(today, -1), 'pilates');
    await seedRide(b.id, today);

    const r = await fetchSeries(a.jwt, groupId);
    const body = await r.json<any>();
    const ma = body.members.find((m: any) => m.user_id === a.id);
    const mb = body.members.find((m: any) => m.user_id === b.id);
    expect(ma.days.length).toBe(2);
    expect(mb.days.length).toBe(1);
    expect(mb.days[0].rides).toBe(1);
  });
});
