// M4: group stats endpoint.
//
// Covers GET /api/groups/:id/stats?range=...: per-member workout_count
// (DISTINCT active dates) and streak_days (consecutive days back from
// today/yesterday), independence across members, range param semantics,
// and the 403 non-member guard.
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

async function makeUser(label: string, opts: {
  displayName?: string | null;
  timezone?: string | null;
} = {}): Promise<{ id: string; jwt: string }> {
  const id = crypto.randomUUID();
  await env.DB
    .prepare(
      'INSERT INTO users (id,apple_sub,email,display_name,created_at,timezone) VALUES (?1,?2,?3,?4,?5,?6)',
    )
    .bind(
      id,
      `sub-${label}-${id}`,
      `${label}@test`,
      opts.displayName === undefined ? label : opts.displayName,
      Date.now(),
      opts.timezone ?? null,
    )
    .run();
  const jwt = await issueAppJwt(id, 'test-secret');
  return { id, jwt };
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

// Tiny seeder for the activities log only — stats use the activities
// table, set_logs/sessions, and external_activities, but counting
// distinct DATES per source is the same algorithm. Using one source
// keeps the test focused on the rollup semantics.
async function seedActivity(userId: string, date: string, loggedAt: number) {
  await env.DB
    .prepare(
      `INSERT INTO activities
         (id,user_id,date,type,title,duration_minutes,notes,logged_at,source,deleted_at)
       VALUES (?1,?2,?3,'pilates','class',60,NULL,?4,'ios',NULL)`,
    )
    .bind(crypto.randomUUID(), userId, date, loggedAt)
    .run();
}

// Compute "today" the SAME way the server does (UTC fallback when the
// user has no timezone set). Locks the test against runtime clock drift
// across the suite without freezing time.
function todayUtc(): string {
  return new Date().toISOString().slice(0, 10);
}

function addDaysIso(ymd: string, n: number): string {
  return new Date(Date.parse(`${ymd}T00:00:00Z`) + n * 86_400_000)
    .toISOString()
    .slice(0, 10);
}

describe('group stats: authorization', () => {
  it('non-member -> 403', async () => {
    const a = await devJwt();
    const b = await makeUser('stats-nonmember');
    const groupId = await createGroup(a.jwt, 'private');
    const r = await SELF.fetch(`${BASE}/api/groups/${groupId}/stats`, {
      headers: headers(b.jwt),
    });
    expect(r.status).toBe(403);
  });

  it('unknown group id -> 404', async () => {
    const a = await devJwt();
    const r = await SELF.fetch(
      `${BASE}/api/groups/${crypto.randomUUID()}/stats`,
      { headers: headers(a.jwt) },
    );
    expect(r.status).toBe(404);
  });

  it('invalid range -> 400', async () => {
    const a = await devJwt();
    const groupId = await createGroup(a.jwt, 'badrange');
    for (const bad of ['1w', '7', 'abc', '0d', '500d']) {
      const r = await SELF.fetch(
        `${BASE}/api/groups/${groupId}/stats?range=${bad}`,
        { headers: headers(a.jwt) },
      );
      expect(r.status).toBe(400);
    }
  });
});

describe('group stats: workout_count + streak_days', () => {
  it('three activities on the same day count as ONE distinct date', async () => {
    const a = await devJwt();
    const groupId = await createGroup(a.jwt, 'distinct');
    const today = todayUtc();
    await seedActivity(a.id, today, Date.now() - 3000);
    await seedActivity(a.id, today, Date.now() - 2000);
    await seedActivity(a.id, today, Date.now() - 1000);
    const r = await SELF.fetch(
      `${BASE}/api/groups/${groupId}/stats?range=7d`,
      { headers: headers(a.jwt) },
    );
    expect(r.status).toBe(200);
    const body = await r.json<any>();
    const me = body.members.find((m: any) => m.user_id === a.id);
    expect(me.workout_count).toBe(1);
    // Streak: today is active → 1 day streak.
    expect(me.streak_days).toBe(1);
    expect(me.is_me).toBe(true);
  });

  it('consecutive prior days build a streak; gap breaks it', async () => {
    const a = await devJwt();
    const groupId = await createGroup(a.jwt, 'streak');
    const today = todayUtc();
    // Active: today, yesterday, day-before-yesterday. Gap on day -3.
    // Active again on day -4 / -5 (should NOT count — broken by -3).
    await seedActivity(a.id, today, Date.now());
    await seedActivity(a.id, addDaysIso(today, -1), Date.now() - 86_400_000);
    await seedActivity(a.id, addDaysIso(today, -2), Date.now() - 2 * 86_400_000);
    await seedActivity(a.id, addDaysIso(today, -4), Date.now() - 4 * 86_400_000);
    await seedActivity(a.id, addDaysIso(today, -5), Date.now() - 5 * 86_400_000);
    const r = await SELF.fetch(
      `${BASE}/api/groups/${groupId}/stats?range=14d`,
      { headers: headers(a.jwt) },
    );
    const body = await r.json<any>();
    const me = body.members.find((m: any) => m.user_id === a.id);
    expect(me.streak_days).toBe(3); // today + 2 prior; gap at -3 breaks
    // workout_count over 14d: today, -1, -2, -4, -5 = 5 distinct dates.
    expect(me.workout_count).toBe(5);
  });

  it("streak counts back from yesterday when today is empty (but yesterday has activity)", async () => {
    const a = await devJwt();
    const groupId = await createGroup(a.jwt, 'streak-yest');
    const today = todayUtc();
    // No activity today; -1 and -2 are active. Streak = 2.
    await seedActivity(a.id, addDaysIso(today, -1), Date.now() - 86_400_000);
    await seedActivity(a.id, addDaysIso(today, -2), Date.now() - 2 * 86_400_000);
    const r = await SELF.fetch(
      `${BASE}/api/groups/${groupId}/stats?range=7d`,
      { headers: headers(a.jwt) },
    );
    const body = await r.json<any>();
    const me = body.members.find((m: any) => m.user_id === a.id);
    expect(me.streak_days).toBe(2);
  });

  it('streak = 0 when neither today nor yesterday have activity', async () => {
    const a = await devJwt();
    const groupId = await createGroup(a.jwt, 'streak-zero');
    const today = todayUtc();
    // Only -2 active. Today + yesterday both empty → streak resets to 0.
    await seedActivity(a.id, addDaysIso(today, -2), Date.now() - 2 * 86_400_000);
    const r = await SELF.fetch(
      `${BASE}/api/groups/${groupId}/stats?range=7d`,
      { headers: headers(a.jwt) },
    );
    const body = await r.json<any>();
    const me = body.members.find((m: any) => m.user_id === a.id);
    expect(me.streak_days).toBe(0);
    expect(me.workout_count).toBe(1);
  });
});

describe('group stats: cross-member independence', () => {
  it('each member is computed in isolation; A and B do not share counts', async () => {
    const a = await devJwt();
    const b = await makeUser('stats-iso');
    const groupId = await createGroup(a.jwt, 'iso');
    await inviteAndJoin(a.jwt, b.jwt, groupId);
    const today = todayUtc();
    // A: 3 active days (today, -1, -2). B: 1 active day (today).
    await seedActivity(a.id, today, Date.now());
    await seedActivity(a.id, addDaysIso(today, -1), Date.now() - 86_400_000);
    await seedActivity(a.id, addDaysIso(today, -2), Date.now() - 2 * 86_400_000);
    await seedActivity(b.id, today, Date.now() - 500);
    const r = await SELF.fetch(
      `${BASE}/api/groups/${groupId}/stats?range=7d`,
      { headers: headers(a.jwt) },
    );
    const body = await r.json<any>();
    const ma = body.members.find((m: any) => m.user_id === a.id);
    const mb = body.members.find((m: any) => m.user_id === b.id);
    expect(ma.workout_count).toBe(3);
    expect(ma.streak_days).toBe(3);
    expect(ma.is_me).toBe(true);
    expect(mb.workout_count).toBe(1);
    expect(mb.streak_days).toBe(1);
    expect(mb.is_me).toBe(false);
  });
});

describe('group stats: range parameter', () => {
  it('range=7d only includes activity in the last 7 days', async () => {
    const a = await devJwt();
    const groupId = await createGroup(a.jwt, 'range7');
    const today = todayUtc();
    await seedActivity(a.id, today, Date.now()); // in 7d
    await seedActivity(a.id, addDaysIso(today, -10), Date.now() - 10 * 86_400_000); // out
    const r = await SELF.fetch(
      `${BASE}/api/groups/${groupId}/stats?range=7d`,
      { headers: headers(a.jwt) },
    );
    const body = await r.json<any>();
    const me = body.members.find((m: any) => m.user_id === a.id);
    expect(me.workout_count).toBe(1);
    expect(body.range).toBe('7d');
  });

  it('range=30d catches activity further back than the 7d window does', async () => {
    const a = await devJwt();
    const groupId = await createGroup(a.jwt, 'range30');
    const today = todayUtc();
    await seedActivity(a.id, today, Date.now());
    await seedActivity(a.id, addDaysIso(today, -10), Date.now() - 10 * 86_400_000);
    await seedActivity(a.id, addDaysIso(today, -25), Date.now() - 25 * 86_400_000);
    const r = await SELF.fetch(
      `${BASE}/api/groups/${groupId}/stats?range=30d`,
      { headers: headers(a.jwt) },
    );
    const body = await r.json<any>();
    const me = body.members.find((m: any) => m.user_id === a.id);
    expect(me.workout_count).toBe(3);
  });

  it('default range is 7d when ?range= is omitted', async () => {
    const a = await devJwt();
    const groupId = await createGroup(a.jwt, 'range-default');
    const today = todayUtc();
    await seedActivity(a.id, today, Date.now());
    await seedActivity(a.id, addDaysIso(today, -10), Date.now() - 10 * 86_400_000);
    const r = await SELF.fetch(
      `${BASE}/api/groups/${groupId}/stats`,
      { headers: headers(a.jwt) },
    );
    const body = await r.json<any>();
    expect(body.range).toBe('7d');
    const me = body.members.find((m: any) => m.user_id === a.id);
    expect(me.workout_count).toBe(1);
  });
});

describe('group stats: avatar_initials + last_active', () => {
  it('avatar_initials derived from display name, last_active reflects most recent activity', async () => {
    const a = await devJwt();
    const groupId = await createGroup(a.jwt, 'avatar');
    const b = await makeUser('peer-b', { displayName: 'Sarah Kim' });
    await inviteAndJoin(a.jwt, b.jwt, groupId);
    const today = todayUtc();
    await seedActivity(b.id, today, Date.now());
    const r = await SELF.fetch(
      `${BASE}/api/groups/${groupId}/stats`,
      { headers: headers(a.jwt) },
    );
    const body = await r.json<any>();
    const mb = body.members.find((m: any) => m.user_id === b.id);
    expect(mb.avatar_initials).toBe('SK');
    expect(mb.display_name).toBe('Sarah Kim');
    // last_active is midnight UTC of the most-recent active date.
    expect(mb.last_active).toBe(Date.parse(`${today}T00:00:00Z`));

    // A is also a member but has zero activity → workout_count=0,
    // streak=0, last_active=null.
    const ma = body.members.find((m: any) => m.user_id === a.id);
    expect(ma.workout_count).toBe(0);
    expect(ma.streak_days).toBe(0);
    expect(ma.last_active).toBeNull();
  });
});
