// M4: group feed endpoint.
//
// Covers GET /api/groups/:id/feed: cross-source merge (sessions + rides +
// activities), ordering by occurred_at DESC, the privacy contract
// (notes/rpe/perceived_fatigue NEVER serialized), pagination via `since`/
// `next_since`, cross-group isolation, and `is_me` server-stamping.
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

async function makeUser(label: string, displayName?: string | null): Promise<{
  id: string;
  jwt: string;
}> {
  const id = crypto.randomUUID();
  await env.DB.prepare(
    'INSERT INTO users (id,apple_sub,email,display_name,created_at) VALUES (?1,?2,?3,?4,?5)',
  )
    .bind(
      id,
      `sub-${label}-${id}`,
      `${label}@test`,
      displayName === undefined ? label : displayName,
      Date.now(),
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
  const g = await r.json<{ id: string }>();
  return g.id;
}

async function inviteAndJoin(
  creatorJwt: string,
  joinerJwt: string,
  groupId: string,
): Promise<void> {
  const mint = await SELF.fetch(`${BASE}/api/groups/${groupId}/invites`, {
    method: 'POST',
    headers: headers(creatorJwt),
    body: JSON.stringify({}),
  });
  expect(mint.status).toBe(201);
  const { code } = await mint.json<{ code: string }>();
  const join = await SELF.fetch(`${BASE}/api/groups/join`, {
    method: 'POST',
    headers: headers(joinerJwt),
    body: JSON.stringify({ code }),
  });
  expect(join.status).toBe(200);
}

// Seed a full strength session (plan, day_template, session, sets) for a
// given user. Returns the session id so the test can assert against it.
async function seedSession(
  userId: string,
  opts: {
    date: string;
    completedAt: number | null;
    startedAt?: number | null;
    perceivedFatigue?: number | null;
    sessionNotes?: string | null;
    setNotes?: string | null;
    setRpe?: number | null;
    dayName?: string;
    dayLabel?: string | null;
    // [exerciseId, weight, reps, isWarmup][]
    sets: Array<[string, number, number, boolean]>;
  },
): Promise<{ sessionId: string; dayTemplateId: string }> {
  const planId = crypto.randomUUID();
  const dayId = crypto.randomUUID();
  const sessionId = crypto.randomUUID();
  const ts = Date.now();
  await env.DB
    .prepare(
      "INSERT INTO plans (id,user_id,name,status,version,meta,created_at,updated_at) VALUES (?1,?2,'Test Plan','active',1,NULL,?3,?3)",
    )
    .bind(planId, userId, ts)
    .run();
  await env.DB
    .prepare(
      'INSERT INTO day_templates (id,plan_id,name,day_label,order_index,notes,created_at,updated_at) VALUES (?1,?2,?3,?4,0,NULL,?5,?5)',
    )
    .bind(dayId, planId, opts.dayName ?? 'Lower A', opts.dayLabel ?? 'A', ts)
    .run();
  await env.DB
    .prepare(
      'INSERT INTO sessions (id,user_id,plan_id,day_template_id,date,status,started_at,completed_at,perceived_fatigue,notes,created_at,updated_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?11)',
    )
    .bind(
      sessionId,
      userId,
      planId,
      dayId,
      opts.date,
      opts.completedAt != null ? 'completed' : 'in_progress',
      opts.startedAt ?? (opts.completedAt != null ? opts.completedAt - 3_600_000 : ts),
      opts.completedAt,
      opts.perceivedFatigue ?? null,
      opts.sessionNotes ?? null,
      opts.completedAt ?? ts,
    )
    .run();
  for (let i = 0; i < opts.sets.length; i++) {
    const [exerciseId, weight, reps, isWarmup] = opts.sets[i]!;
    await env.DB
      .prepare(
        'INSERT INTO set_logs (id,session_id,exercise_id,template_exercise_id,set_index,weight,reps,rpe,is_warmup,notes,logged_at,source,deleted_at) VALUES (?1,?2,?3,NULL,?4,?5,?6,?7,?8,?9,?10,?11,NULL)',
      )
      .bind(
        crypto.randomUUID(),
        sessionId,
        exerciseId,
        i + 1,
        weight,
        reps,
        opts.setRpe ?? null,
        isWarmup ? 1 : 0,
        opts.setNotes ?? null,
        opts.completedAt ?? ts,
        'ios',
      )
      .run();
  }
  return { sessionId, dayTemplateId: dayId };
}

async function seedRide(
  userId: string,
  opts: {
    date: string;
    syncedAt: number;
    kind?: string;
    name?: string;
    distanceM?: number;
    movingTimeSec?: number;
    averageWatts?: number;
  },
): Promise<string> {
  const id = `intervals:activity:${crypto.randomUUID()}`;
  await env.DB
    .prepare(
      `INSERT INTO external_activities
         (id,user_id,source,external_id,date,kind,name,moving_time_sec,
          elapsed_time_sec,distance_m,average_watts,weighted_avg_watts,
          average_hr,max_hr,training_load,intensity,calories,
          elevation_gain_m,raw,synced_at,deleted_at)
       VALUES (?1,?2,'intervals',?3,?4,?5,?6,?7,?7,?8,?9,NULL,NULL,NULL,
               NULL,NULL,NULL,NULL,NULL,?10,NULL)`,
    )
    .bind(
      id,
      userId,
      id.split(':')[2],
      opts.date,
      opts.kind ?? 'ride',
      opts.name ?? 'Morning Ride',
      opts.movingTimeSec ?? 3600,
      opts.distanceM ?? 30000,
      opts.averageWatts ?? 180,
      opts.syncedAt,
    )
    .run();
  return id;
}

async function seedActivity(
  userId: string,
  opts: {
    date: string;
    loggedAt: number;
    type?: string;
    title?: string | null;
    durationMinutes?: number | null;
    notes?: string | null;
    deleted?: boolean;
  },
): Promise<string> {
  const id = crypto.randomUUID();
  await env.DB
    .prepare(
      `INSERT INTO activities
         (id,user_id,date,type,title,duration_minutes,notes,logged_at,source,deleted_at)
       VALUES (?1,?2,?3,?4,?5,?6,?7,?8,'ios',?9)`,
    )
    .bind(
      id,
      userId,
      opts.date,
      opts.type ?? 'pilates',
      opts.title ?? null,
      opts.durationMinutes ?? null,
      opts.notes ?? null,
      opts.loggedAt,
      opts.deleted ? opts.loggedAt + 1000 : null,
    )
    .run();
  return id;
}

describe('group feed: authorization', () => {
  it('404 on unknown group id', async () => {
    const a = await devJwt();
    const r = await SELF.fetch(
      `${BASE}/api/groups/${crypto.randomUUID()}/feed`,
      { headers: headers(a.jwt) },
    );
    expect(r.status).toBe(404);
  });

  it('403 when caller is not a member of the group', async () => {
    const a = await devJwt();
    const b = await makeUser('feed-nonmember');
    const groupId = await createGroup(a.jwt, 'A-only');
    const r = await SELF.fetch(`${BASE}/api/groups/${groupId}/feed`, {
      headers: headers(b.jwt),
    });
    expect(r.status).toBe(403);
  });

  it('member of group X cannot see group Y feed (cross-group isolation)', async () => {
    const a = await devJwt();
    const b = await makeUser('feed-iso-b');
    const gX = await createGroup(a.jwt, 'X');
    const gY = await createGroup(b.jwt, 'Y');
    // A is in X but not Y; trying to read Y's feed must 403.
    const r = await SELF.fetch(`${BASE}/api/groups/${gY}/feed`, {
      headers: headers(a.jwt),
    });
    expect(r.status).toBe(403);
    // Sanity: A can read X.
    const okX = await SELF.fetch(`${BASE}/api/groups/${gX}/feed`, {
      headers: headers(a.jwt),
    });
    expect(okX.status).toBe(200);
  });
});

describe('group feed: empty + single-member', () => {
  it('empty group (no activity yet) returns items=[] and next_since=null', async () => {
    const a = await devJwt();
    const groupId = await createGroup(a.jwt, 'empty-feed');
    const r = await SELF.fetch(`${BASE}/api/groups/${groupId}/feed`, {
      headers: headers(a.jwt),
    });
    expect(r.status).toBe(200);
    const body = await r.json<any>();
    expect(body.group_id).toBe(groupId);
    expect(Array.isArray(body.items)).toBe(true);
    expect(body.items).toHaveLength(0);
    expect(body.next_since).toBeNull();
    expect(typeof body.server_time).toBe('number');
  });

  it('caller-owned strength session shows up with is_me=true', async () => {
    const a = await devJwt();
    const groupId = await createGroup(a.jwt, 'single-feed');
    const completedAt = Date.now() - 3600_000;
    await seedSession(a.id, {
      date: '2026-05-20',
      completedAt,
      startedAt: completedAt - 1_800_000,
      perceivedFatigue: 7,
      sessionNotes: 'shoulder twinge — private',
      setNotes: 'felt weak — private',
      setRpe: 9,
      sets: [['ex_back_squat', 225, 5, false]],
    });
    const r = await SELF.fetch(`${BASE}/api/groups/${groupId}/feed`, {
      headers: headers(a.jwt),
    });
    expect(r.status).toBe(200);
    const body = await r.json<any>();
    expect(body.items).toHaveLength(1);
    const it = body.items[0];
    expect(it.type).toBe('session');
    expect(it.user_id).toBe(a.id);
    expect(it.is_me).toBe(true);
    expect(it.date).toBe('2026-05-20');
    expect(it.occurred_at).toBe(completedAt);
    expect(it.session.day_name).toBe('Lower A');
    expect(it.session.set_count).toBe(1);
    expect(it.session.top_sets).toHaveLength(1);
    expect(it.session.top_sets[0].exercise).toBe('Back Squat');
    expect(it.session.top_sets[0].weight).toBe(225);
    expect(it.session.top_sets[0].reps).toBe(5);
    // duration_sec computed from started_at/completed_at delta.
    expect(it.session.duration_sec).toBe(1800);
  });
});

describe('group feed: privacy contract', () => {
  it('strength session item never exposes notes, perceived_fatigue, set notes, or set rpe', async () => {
    const a = await devJwt();
    const groupId = await createGroup(a.jwt, 'privacy');
    const completedAt = Date.now() - 3600_000;
    await seedSession(a.id, {
      date: '2026-05-21',
      completedAt,
      perceivedFatigue: 9,
      sessionNotes: 'PRIVATE-SESSION-NOTE',
      setNotes: 'PRIVATE-SET-NOTE',
      setRpe: 10,
      sets: [['ex_bench', 185, 5, false]],
    });
    const r = await SELF.fetch(`${BASE}/api/groups/${groupId}/feed`, {
      headers: headers(a.jwt),
    });
    const body = await r.json<any>();
    const wire = JSON.stringify(body);
    expect(wire).not.toContain('PRIVATE-SESSION-NOTE');
    expect(wire).not.toContain('PRIVATE-SET-NOTE');
    // No `notes` or `perceived_fatigue` or `rpe` key anywhere in a session
    // item. Walk every depth to be sure.
    const it = body.items[0];
    expect(it.type).toBe('session');
    expect(Object.keys(it)).not.toContain('notes');
    expect(Object.keys(it)).not.toContain('perceived_fatigue');
    expect(Object.keys(it.session)).not.toContain('notes');
    expect(Object.keys(it.session)).not.toContain('perceived_fatigue');
    for (const ts of it.session.top_sets) {
      expect(Object.keys(ts)).not.toContain('rpe');
      expect(Object.keys(ts)).not.toContain('notes');
    }
  });

  it('activity item INCLUDES notes (per the privacy contract — notes ARE the description for activities)', async () => {
    const a = await devJwt();
    const groupId = await createGroup(a.jwt, 'activity-notes');
    await seedActivity(a.id, {
      date: '2026-05-22',
      loggedAt: Date.now() - 1000,
      type: 'pilates',
      title: 'Reformer',
      durationMinutes: 60,
      notes: 'felt great today',
    });
    const r = await SELF.fetch(`${BASE}/api/groups/${groupId}/feed`, {
      headers: headers(a.jwt),
    });
    const body = await r.json<any>();
    const it = body.items[0];
    expect(it.type).toBe('activity');
    expect(it.activity.notes).toBe('felt great today');
    expect(it.activity.title).toBe('Reformer');
    expect(it.activity.duration_min).toBe(60);
  });

  // Codex PR #36 P2: GET /api/today auto-creates a status='planned'
  // session via getOrCreateSession before the user logs anything. Without
  // a filter on session status, those planned rows leak into the group
  // feed as 0-set "session" items — a groupmate who just opened Today
  // would show up as having "trained." Only started/completed sessions
  // count as activity.
  it('planned sessions (auto-created by /api/today) are EXCLUDED from the feed', async () => {
    const a = await devJwt();
    const groupId = await createGroup(a.jwt, 'planned-leak');

    // Hand-craft a planned session (status='planned', no started_at,
    // no completed_at) directly — seedSession only writes completed /
    // in_progress, which is precisely the legitimate states we want
    // to keep in the feed. This row mirrors what getOrCreateSession
    // writes when the user opens Today.
    const planId = crypto.randomUUID();
    const dayId = crypto.randomUUID();
    const sessionId = crypto.randomUUID();
    const ts = Date.now();
    await env.DB.prepare(
      "INSERT INTO plans (id,user_id,name,status,version,meta,created_at,updated_at) VALUES (?1,?2,'P','active',1,NULL,?3,?3)",
    )
      .bind(planId, a.id, ts)
      .run();
    await env.DB.prepare(
      "INSERT INTO day_templates (id,plan_id,name,day_label,order_index,notes,created_at,updated_at) VALUES (?1,?2,'Lower A','A',0,NULL,?3,?3)",
    )
      .bind(dayId, planId, ts)
      .run();
    await env.DB.prepare(
      "INSERT INTO sessions (id,user_id,plan_id,day_template_id,date,status,started_at,completed_at,perceived_fatigue,notes,created_at,updated_at) VALUES (?1,?2,?3,?4,?5,'planned',NULL,NULL,NULL,NULL,?6,?6)",
    )
      .bind(sessionId, a.id, planId, dayId, '2026-05-26', ts)
      .run();

    const r = await SELF.fetch(`${BASE}/api/groups/${groupId}/feed`, {
      headers: headers(a.jwt),
    });
    const body = await r.json<any>();
    // Without the fix, this would return 1 item (the planned row).
    expect(body.items).toHaveLength(0);
  });

  it('soft-deleted activities are excluded from the feed', async () => {
    const a = await devJwt();
    const groupId = await createGroup(a.jwt, 'activity-deleted');
    await seedActivity(a.id, {
      date: '2026-05-23',
      loggedAt: Date.now() - 5000,
      type: 'pilates',
      title: 'kept',
    });
    await seedActivity(a.id, {
      date: '2026-05-23',
      loggedAt: Date.now() - 4000,
      type: 'pilates',
      title: 'gone',
      deleted: true,
    });
    const r = await SELF.fetch(`${BASE}/api/groups/${groupId}/feed`, {
      headers: headers(a.jwt),
    });
    const body = await r.json<any>();
    expect(body.items).toHaveLength(1);
    expect(body.items[0].activity.title).toBe('kept');
  });
});

describe('group feed: multi-member ordering + is_me', () => {
  it('items from multiple members interleave by occurred_at DESC, is_me stamped correctly', async () => {
    const a = await devJwt();
    const b = await makeUser('feed-multi-b');
    const groupId = await createGroup(a.jwt, 'multi');
    await inviteAndJoin(a.jwt, b.jwt, groupId);

    const now = Date.now();
    // A logs at T-30s, B at T-20s, A again at T-10s. Expected order: A,B,A
    // newest-first. Use rides+activities so we exercise multiple sources.
    await seedRide(a.id, { date: '2026-05-24', syncedAt: now - 30_000 });
    await seedActivity(b.id, {
      date: '2026-05-24',
      loggedAt: now - 20_000,
      type: 'yoga',
      title: 'flow',
    });
    await seedActivity(a.id, {
      date: '2026-05-24',
      loggedAt: now - 10_000,
      type: 'pilates',
      title: 'reformer',
    });

    const r = await SELF.fetch(`${BASE}/api/groups/${groupId}/feed`, {
      headers: headers(a.jwt),
    });
    const body = await r.json<any>();
    expect(body.items).toHaveLength(3);
    const occurred = body.items.map((it: any) => it.occurred_at);
    expect(occurred[0]).toBeGreaterThan(occurred[1]);
    expect(occurred[1]).toBeGreaterThan(occurred[2]);
    // is_me correctness: A asked → A's items have is_me=true, B's don't.
    const userToIsMe = new Map<string, boolean>();
    for (const it of body.items) userToIsMe.set(it.user_id, it.is_me);
    expect(userToIsMe.get(a.id)).toBe(true);
    expect(userToIsMe.get(b.id)).toBe(false);

    // The same group fetched as B → only B's items report is_me=true.
    const rb = await SELF.fetch(`${BASE}/api/groups/${groupId}/feed`, {
      headers: headers(b.jwt),
    });
    const bodyB = await rb.json<any>();
    const isMeFromB = new Map<string, boolean>();
    for (const it of bodyB.items) isMeFromB.set(it.user_id, it.is_me);
    expect(isMeFromB.get(b.id)).toBe(true);
    expect(isMeFromB.get(a.id)).toBe(false);
  });
});

describe('group feed: top-set semantics', () => {
  it('top_set per exercise picks the highest est_1rm working set; warmups excluded', async () => {
    const a = await devJwt();
    const groupId = await createGroup(a.jwt, 'topset');
    const completedAt = Date.now();
    // Two working sets at same weight, different reps. Higher reps → higher
    // est_1rm under Epley. A 99-rep "warmup" must NOT win even though its
    // est_1rm would be huge.
    await seedSession(a.id, {
      date: '2026-05-25',
      completedAt,
      sets: [
        ['ex_bench', 50, 99, true], // warmup with absurd reps — must be ignored
        ['ex_bench', 185, 5, false],
        ['ex_bench', 185, 6, false], // wins: same weight, more reps → higher est_1rm
      ],
    });
    const r = await SELF.fetch(`${BASE}/api/groups/${groupId}/feed`, {
      headers: headers(a.jwt),
    });
    const body = await r.json<any>();
    const it = body.items[0];
    expect(it.session.set_count).toBe(2); // warmup excluded from count
    expect(it.session.top_sets).toHaveLength(1);
    const top = it.session.top_sets[0];
    expect(top.exercise).toBe('Bench Press');
    expect(top.weight).toBe(185);
    expect(top.reps).toBe(6);
    expect(top.est_1rm).toBeGreaterThan(0);
  });
});

describe('group feed: pagination + limit cap', () => {
  it('since=X filters to occurred_at < X; next_since == smallest returned ts', async () => {
    const a = await devJwt();
    const groupId = await createGroup(a.jwt, 'pag');
    const base = Date.now();
    // Three activities at base, base+1000, base+2000.
    await seedActivity(a.id, { date: '2026-05-26', loggedAt: base, type: 'walk', title: 'old' });
    await seedActivity(a.id, {
      date: '2026-05-26',
      loggedAt: base + 1000,
      type: 'walk',
      title: 'mid',
    });
    await seedActivity(a.id, {
      date: '2026-05-26',
      loggedAt: base + 2000,
      type: 'walk',
      title: 'new',
    });

    // No since → newest 30. All three.
    const r1 = await SELF.fetch(`${BASE}/api/groups/${groupId}/feed`, {
      headers: headers(a.jwt),
    });
    const b1 = await r1.json<any>();
    expect(b1.items).toHaveLength(3);
    expect(b1.items[0].activity.title).toBe('new');
    expect(b1.next_since).toBe(base);

    // Page back: since=base. Strictly OLDER than base → none of the seeded
    // rows qualify, items empty, next_since null.
    const r2 = await SELF.fetch(
      `${BASE}/api/groups/${groupId}/feed?since=${base}`,
      { headers: headers(a.jwt) },
    );
    const b2 = await r2.json<any>();
    expect(b2.items).toHaveLength(0);
    expect(b2.next_since).toBeNull();

    // since=base+1500 → only base & base+1000 qualify (both < 1500).
    const r3 = await SELF.fetch(
      `${BASE}/api/groups/${groupId}/feed?since=${base + 1500}`,
      { headers: headers(a.jwt) },
    );
    const b3 = await r3.json<any>();
    expect(b3.items).toHaveLength(2);
    expect(b3.items[0].activity.title).toBe('mid');
    expect(b3.items[1].activity.title).toBe('old');
    expect(b3.next_since).toBe(base);
  });

  // Codex PR #36 P2: when N rows share the SAME occurred_at at a page
  // boundary, a plain "occurred_at < since" cursor would skip every
  // remaining tied row on the next page. The fix is a composite
  // (occurred_at, id) cursor — iOS passes since_id alongside since.
  it('composite cursor (since + since_id) preserves rows tied at the boundary', async () => {
    const a = await devJwt();
    const groupId = await createGroup(a.jwt, 'tie');
    // Five activities all logged at the SAME logged_at — the worst case
    // for the old cursor (every row at the boundary would get skipped).
    const t = Date.now();
    for (let i = 0; i < 5; i++) {
      await seedActivity(a.id, {
        date: '2026-05-26',
        loggedAt: t,
        type: 'walk',
        title: `tied-${i}`,
      });
    }

    // First page, limit=2. Returns 2 of the tied items. The pagination
    // contract returns the TAIL item's (occurred_at, id) as the cursor.
    const r1 = await SELF.fetch(
      `${BASE}/api/groups/${groupId}/feed?limit=2`,
      { headers: headers(a.jwt) },
    );
    const b1 = await r1.json<any>();
    expect(b1.items).toHaveLength(2);
    expect(b1.next_since).toBe(t);
    expect(typeof b1.next_since_id).toBe('string');
    expect(b1.next_since_id.length).toBeGreaterThan(0);

    // Without the composite cursor, page 2 with just `since=t` would
    // skip every tied row → empty page → 3 rows lost forever. With the
    // composite cursor passing since_id, the remaining 3 ARE returned.
    const r2 = await SELF.fetch(
      `${BASE}/api/groups/${groupId}/feed?since=${b1.next_since}&since_id=${b1.next_since_id}&limit=10`,
      { headers: headers(a.jwt) },
    );
    const b2 = await r2.json<any>();
    expect(b2.items).toHaveLength(3);
    // And the union of page-1 + page-2 ids covers all 5 seeded rows.
    const ids = new Set<string>([
      ...b1.items.map((it: any) => it.id),
      ...b2.items.map((it: any) => it.id),
    ]);
    expect(ids.size).toBe(5);

    // Backward-compat sanity: a legacy client sending only `since=t` (no
    // since_id) still gets strict-older semantics — none of the tied
    // rows leak duplicates onto the next page.
    const r3 = await SELF.fetch(
      `${BASE}/api/groups/${groupId}/feed?since=${t}`,
      { headers: headers(a.jwt) },
    );
    const b3 = await r3.json<any>();
    expect(b3.items).toHaveLength(0);
  });

  it('limit=200 is capped at 100', async () => {
    const a = await devJwt();
    const groupId = await createGroup(a.jwt, 'cap');
    // Seed 5 activities — easier than 100, and we just need to read the
    // shape: a clamp of 200→100 still returns ≤5 here. The contract we
    // verify is the request succeeds and the returned count ≤ 100.
    const base = Date.now();
    for (let i = 0; i < 5; i++) {
      await seedActivity(a.id, {
        date: '2026-05-26',
        loggedAt: base + i,
        type: 'walk',
        title: `n${i}`,
      });
    }
    const r = await SELF.fetch(
      `${BASE}/api/groups/${groupId}/feed?limit=200`,
      { headers: headers(a.jwt) },
    );
    expect(r.status).toBe(200);
    const body = await r.json<any>();
    expect(body.items.length).toBeLessThanOrEqual(100);
    expect(body.items.length).toBe(5);
  });

  it('limit=2 caps the page even when more items exist', async () => {
    const a = await devJwt();
    const groupId = await createGroup(a.jwt, 'cap2');
    const base = Date.now();
    for (let i = 0; i < 4; i++) {
      await seedActivity(a.id, {
        date: '2026-05-26',
        loggedAt: base + i,
        type: 'walk',
        title: `n${i}`,
      });
    }
    const r = await SELF.fetch(
      `${BASE}/api/groups/${groupId}/feed?limit=2`,
      { headers: headers(a.jwt) },
    );
    const body = await r.json<any>();
    expect(body.items).toHaveLength(2);
    expect(body.items[0].activity.title).toBe('n3');
    expect(body.items[1].activity.title).toBe('n2');
    // next_since is the smaller of the two = base+2.
    expect(body.next_since).toBe(base + 2);
  });
});

describe('group feed: display name resolution', () => {
  it('uses per-group display_name override, falls back to users.display_name, then email prefix', async () => {
    const a = await devJwt(); // dev/owner gets display_name='Owner' (via /auth/dev seed)
    const groupId = await createGroup(a.jwt, 'names');
    // Three peer users with progressively-weaker name sources.
    const b = await makeUser('peer-b', 'Beth Smith'); // global display_name
    const c = await makeUser('peer-c', null); // no display_name → email prefix
    await inviteAndJoin(a.jwt, b.jwt, groupId);
    await inviteAndJoin(a.jwt, c.jwt, groupId);
    // Override B's display name within this group only.
    const patch = await SELF.fetch(
      `${BASE}/api/groups/${groupId}/members/me`,
      {
        method: 'PATCH',
        headers: headers(b.jwt),
        body: JSON.stringify({ display_name: 'BethInTheGroup' }),
      },
    );
    expect(patch.status).toBe(200);

    // Each member seeds a single activity so all three appear in the feed.
    await seedActivity(a.id, { date: '2026-05-26', loggedAt: Date.now() - 3000, type: 'walk' });
    await seedActivity(b.id, { date: '2026-05-26', loggedAt: Date.now() - 2000, type: 'walk' });
    await seedActivity(c.id, { date: '2026-05-26', loggedAt: Date.now() - 1000, type: 'walk' });

    const r = await SELF.fetch(`${BASE}/api/groups/${groupId}/feed`, {
      headers: headers(a.jwt),
    });
    const body = await r.json<any>();
    const byUser = new Map<string, any>();
    for (const it of body.items) byUser.set(it.user_id, it);
    expect(byUser.get(b.id)?.user_display_name).toBe('BethInTheGroup');
    // C has no global display name → email prefix 'peer-c'.
    expect(byUser.get(c.id)?.user_display_name).toBe('peer-c');
  });
});

describe('group feed: Apple Health opt-in gating (Codex P1 / migration 0028)', () => {
  it("hides a member's healthkit activity until they opt in; intervals always shows", async () => {
    const owner = await devJwt();
    const member = await makeUser('hkmember');
    const groupId = await createGroup(owner.jwt, 'Fam');
    await inviteAndJoin(owner.jwt, member.jwt, groupId);

    // The member has an intervals ride (permissive terms — always visible) and
    // a pushed Apple Health workout (private — opt-in gated), same day.
    const rideId = await seedRide(member.id, {
      date: '2026-06-18',
      syncedAt: Date.parse('2026-06-18T10:00:00Z'),
    });
    const hkId = `healthkit:activity:${member.id}:${crypto.randomUUID()}`;
    await env.DB.prepare(
      `INSERT INTO external_activities
         (id,user_id,source,external_id,date,kind,name,start_date_local_ms,
          synced_at,deleted_at,canonical,duplicate_of)
       VALUES (?1,?2,'healthkit',?3,?4,'run','Treadmill',?5,?5,NULL,1,NULL)`,
    )
      .bind(hkId, member.id, 'hk1', '2026-06-18', Date.parse('2026-06-18T11:00:00Z'))
      .run();

    const feedIds = async (): Promise<string[]> => {
      const r = await SELF.fetch(`${BASE}/api/groups/${groupId}/feed`, {
        headers: headers(owner.jwt),
      });
      expect(r.status).toBe(200);
      const body = await r.json<{ items: { id: string }[] }>();
      return body.items.map((i) => i.id);
    };

    // Default off: intervals visible to the owner, healthkit hidden.
    let ids = await feedIds();
    expect(ids).toContain(rideId);
    expect(ids).not.toContain(hkId);

    // Member opts in.
    const patch = await SELF.fetch(`${BASE}/api/me/health-sharing`, {
      method: 'PATCH',
      headers: headers(member.jwt),
      body: JSON.stringify({ enabled: true }),
    });
    expect(patch.status).toBe(200);
    expect(await patch.json()).toMatchObject({ sharing_in_group: true });

    // Now the healthkit row surfaces to the group.
    ids = await feedIds();
    expect(ids).toContain(hkId);

    // /api/me reflects the flag for the member's own toggle state.
    const me = await SELF.fetch(`${BASE}/api/me`, { headers: headers(member.jwt) });
    expect(await me.json()).toMatchObject({ health: { sharing_in_group: true } });

    // Opting back off hides it again.
    await SELF.fetch(`${BASE}/api/me/health-sharing`, {
      method: 'PATCH',
      headers: headers(member.jwt),
      body: JSON.stringify({ enabled: false }),
    });
    ids = await feedIds();
    expect(ids).not.toContain(hkId);
  });
});
