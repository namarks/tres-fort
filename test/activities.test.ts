// M3: generic activities log. Covers the REST path (POST/DELETE, idempotency,
// cross-user isolation), the /api/state delta cursor, and the MCP
// `log_activity` write tool (audit row written, row visible).
import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { issueAppJwt } from '../src/auth';

const BASE = 'https://lift-coach.test';
const MCP_TOKEN = 'test-mcp-token';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

async function devJwt(): Promise<string> {
  const r = await SELF.fetch(`${BASE}/auth/dev`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ secret: 'test-dev' }),
  });
  expect(r.status).toBe(200);
  return (await r.json<{ jwt: string }>()).jwt;
}

const headers = (jwt: string) => ({
  'content-type': 'application/json',
  Authorization: `Bearer ${jwt}`,
});

/**
 * Mint a JWT for a freshly-inserted second user, sidestepping /auth/dev
 * (which is owner-locked). Used for cross-user isolation checks — the same
 * direct-insert pattern test/calendar.test.ts uses to seed extra users.
 */
async function makeSecondUser(): Promise<{ id: string; jwt: string }> {
  const id = crypto.randomUUID();
  await env.DB.prepare(
    'INSERT INTO users (id,apple_sub,email,display_name,created_at) VALUES (?1,?2,?3,?4,?5)',
  )
    .bind(id, `sub-${id}`, `${id}@test`, 'Second', Date.now())
    .run();
  // Reuse the production issuer with the test APP_JWT_SECRET that miniflare
  // injects (vitest.config.ts). issueAppJwt is the same function /auth/dev
  // and /auth/apple use, so the produced JWT is indistinguishable from a
  // real one as far as requireAppJwt is concerned.
  const jwt = await issueAppJwt(id, 'test-secret');
  return { id, jwt };
}

const uuid = () => crypto.randomUUID();

describe('activities REST', () => {
  it('POST creates a row, idempotent on the client-generated id', async () => {
    const jwt = await devJwt();
    const H = headers(jwt);
    const id = uuid();
    const body = {
      id,
      date: '2026-05-27',
      type: 'pilates',
      title: 'Reformer class',
      duration_minutes: 60,
      notes: 'felt great',
      logged_at: Date.now(),
    };
    const r1 = await SELF.fetch(`${BASE}/api/activities`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify(body),
    });
    expect(r1.status).toBe(201);
    const row1 = await r1.json<any>();
    expect(row1.id).toBe(id);
    expect(row1.type).toBe('pilates');
    expect(row1.title).toBe('Reformer class');
    expect(row1.duration_minutes).toBe(60);
    expect(row1.source).toBe('ios');
    expect(row1.deleted_at).toBeNull();
    expect(row1.user_id).toBeTruthy();

    // Retry with the same id — server returns the SAME row (not a 4xx) and
    // doesn't duplicate. This is the iOS-outbox safe-retry contract.
    const r2 = await SELF.fetch(`${BASE}/api/activities`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ ...body, title: 'overwritten?' }),
    });
    expect(r2.status).toBe(201);
    const row2 = await r2.json<any>();
    expect(row2.id).toBe(id);
    // The ORIGINAL row wins — title is not overwritten on retry.
    expect(row2.title).toBe('Reformer class');

    const count = await env.DB
      .prepare('SELECT COUNT(*) AS c FROM activities WHERE id = ?1')
      .bind(id)
      .first<{ c: number }>();
    expect(count?.c).toBe(1);
  });

  it('POST rejects malformed input', async () => {
    const jwt = await devJwt();
    const H = headers(jwt);
    // missing id
    let r = await SELF.fetch(`${BASE}/api/activities`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ date: '2026-05-27', type: 'walk', logged_at: 1 }),
    });
    expect(r.status).toBe(400);
    // bad uuid
    r = await SELF.fetch(`${BASE}/api/activities`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ id: 'nope', date: '2026-05-27', type: 'walk', logged_at: 1 }),
    });
    expect(r.status).toBe(400);
    // bad date
    r = await SELF.fetch(`${BASE}/api/activities`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ id: uuid(), date: 'tomorrow', type: 'walk', logged_at: 1 }),
    });
    expect(r.status).toBe(400);
    // empty type
    r = await SELF.fetch(`${BASE}/api/activities`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ id: uuid(), date: '2026-05-27', type: '', logged_at: 1 }),
    });
    expect(r.status).toBe(400);
    // uppercase type
    r = await SELF.fetch(`${BASE}/api/activities`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ id: uuid(), date: '2026-05-27', type: 'Pilates', logged_at: 1 }),
    });
    expect(r.status).toBe(400);
    // logged_at not a number
    r = await SELF.fetch(`${BASE}/api/activities`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ id: uuid(), date: '2026-05-27', type: 'walk', logged_at: 'now' }),
    });
    expect(r.status).toBe(400);
  });

  it('DELETE soft-deletes; second DELETE 404s', async () => {
    const jwt = await devJwt();
    const H = headers(jwt);
    const id = uuid();
    const r1 = await SELF.fetch(`${BASE}/api/activities`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({
        id,
        date: '2026-05-27',
        type: 'yoga',
        logged_at: Date.now(),
      }),
    });
    expect(r1.status).toBe(201);

    const d1 = await SELF.fetch(`${BASE}/api/activities/${id}`, {
      method: 'DELETE',
      headers: H,
    });
    expect(d1.status).toBe(200);
    // Row still exists, with deleted_at populated (soft delete).
    const row = await env.DB
      .prepare('SELECT * FROM activities WHERE id = ?1')
      .bind(id)
      .first<{ deleted_at: number | null }>();
    expect(row?.deleted_at).toBeGreaterThan(0);

    // Second DELETE returns 404 because the WHERE clause excludes already-
    // soft-deleted rows.
    const d2 = await SELF.fetch(`${BASE}/api/activities/${id}`, {
      method: 'DELETE',
      headers: H,
    });
    expect(d2.status).toBe(404);
  });

  it('DELETE is scoped per user (A cannot delete B\'s activity)', async () => {
    const jwtA = await devJwt();
    const HA = headers(jwtA);
    const b = await makeSecondUser();
    const HB = headers(b.jwt);

    // User B logs an activity.
    const id = uuid();
    const r = await SELF.fetch(`${BASE}/api/activities`, {
      method: 'POST',
      headers: HB,
      body: JSON.stringify({
        id,
        date: '2026-05-27',
        type: 'walk',
        logged_at: Date.now(),
      }),
    });
    expect(r.status).toBe(201);

    // User A tries to delete it -> 404 (do not leak existence).
    const dA = await SELF.fetch(`${BASE}/api/activities/${id}`, {
      method: 'DELETE',
      headers: HA,
    });
    expect(dA.status).toBe(404);

    // B's row is intact.
    const row = await env.DB
      .prepare('SELECT * FROM activities WHERE id = ?1')
      .bind(id)
      .first<{ deleted_at: number | null; user_id: string }>();
    expect(row?.deleted_at).toBeNull();
    expect(row?.user_id).toBe(b.id);

    // B can delete their own row.
    const dB = await SELF.fetch(`${BASE}/api/activities/${id}`, {
      method: 'DELETE',
      headers: HB,
    });
    expect(dB.status).toBe(200);
  });
});

describe('activities /api/state deltas', () => {
  it('includes activities in /api/state; cursor advances', async () => {
    const jwt = await devJwt();
    const H = headers(jwt);

    const id1 = uuid();
    const t1 = Date.now();
    await SELF.fetch(`${BASE}/api/activities`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ id: id1, date: '2026-05-27', type: 'cardio', logged_at: t1 }),
    });

    // Full reload (log_since absent) returns all the caller's non-deleted
    // activities. /auth/dev is owner-scoped, so we filter to id1 to ignore
    // anything other tests in this file dropped on the same user.
    const full = await (
      await SELF.fetch(`${BASE}/api/state`, { headers: H })
    ).json<{ activities: any[] }>();
    expect(Array.isArray(full.activities)).toBe(true);
    expect(full.activities.find((a) => a.id === id1)).toBeDefined();

    // Incremental with log_since = t1 -> nothing newer.
    const empty = await (
      await SELF.fetch(`${BASE}/api/state?log_since=${t1}`, { headers: H })
    ).json<{ activities: any[] }>();
    expect(empty.activities.find((a) => a.id === id1)).toBeUndefined();

    // Drop a new one with a later logged_at; incremental at t1 returns it.
    const id2 = uuid();
    const t2 = t1 + 1000;
    await SELF.fetch(`${BASE}/api/activities`, {
      method: 'POST',
      headers: H,
      body: JSON.stringify({ id: id2, date: '2026-05-28', type: 'yoga', logged_at: t2 }),
    });
    const incr = await (
      await SELF.fetch(`${BASE}/api/state?log_since=${t1}`, { headers: H })
    ).json<{ activities: any[] }>();
    expect(incr.activities.find((a) => a.id === id2)).toBeDefined();
    expect(incr.activities.find((a) => a.id === id1)).toBeUndefined();

    // Soft-delete id2 -> incremental at t1 still surfaces it (as a
    // tombstone — deleted_at populated) so a syncing client can apply the
    // removal. This is the set_logs / external_events delta+tombstone
    // pattern (DESIGN §7).
    const dRes = await SELF.fetch(`${BASE}/api/activities/${id2}`, {
      method: 'DELETE',
      headers: H,
    });
    expect(dRes.status).toBe(200);
    const tomb = await (
      await SELF.fetch(`${BASE}/api/state?log_since=${t1}`, { headers: H })
    ).json<{ activities: any[] }>();
    const row = tomb.activities.find((a) => a.id === id2);
    expect(row).toBeDefined();
    expect(row.deleted_at).toBeGreaterThan(0);
  });

  it('state activities are scoped per user', async () => {
    const jwtA = await devJwt();
    const HA = headers(jwtA);
    const b = await makeSecondUser();
    const HB = headers(b.jwt);

    const idB = uuid();
    await SELF.fetch(`${BASE}/api/activities`, {
      method: 'POST',
      headers: HB,
      body: JSON.stringify({
        id: idB,
        date: '2026-05-27',
        type: 'pilates',
        logged_at: Date.now(),
      }),
    });

    const stateA = await (
      await SELF.fetch(`${BASE}/api/state`, { headers: HA })
    ).json<{ activities: any[] }>();
    expect(stateA.activities.find((a) => a.id === idB)).toBeUndefined();

    const stateB = await (
      await SELF.fetch(`${BASE}/api/state`, { headers: HB })
    ).json<{ activities: any[] }>();
    expect(stateB.activities.find((a) => a.id === idB)).toBeDefined();
  });
});

describe('MCP log_activity', () => {
  let rpcId = 0;
  async function call(name: string, args: unknown) {
    const r = await SELF.fetch(`${BASE}/mcp`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', Authorization: `Bearer ${MCP_TOKEN}` },
      body: JSON.stringify({
        jsonrpc: '2.0',
        id: ++rpcId,
        method: 'tools/call',
        params: { name, arguments: args },
      }),
    });
    const body = await r.json<any>();
    const text = body.result.content[0].text as string;
    try {
      return JSON.parse(text);
    } catch {
      return { raw: text };
    }
  }

  it('logs a row, defaults date to today, writes an audit_log entry', async () => {
    const before = await env.DB
      .prepare("SELECT COUNT(*) AS c FROM audit_log WHERE tool = 'log_activity'")
      .first<{ c: number }>();

    const res = await call('log_activity', {
      type: 'pilates',
      title: 'Reformer class at Studio MDR',
      duration_minutes: 60,
    });
    expect(res.ok).toBe(true);
    expect(res.activity).toBeDefined();
    expect(res.activity.type).toBe('pilates');
    expect(res.activity.source).toBe('mcp');
    expect(res.activity.duration_minutes).toBe(60);
    expect(res.activity.title).toBe('Reformer class at Studio MDR');
    // Default date == today in the user's tz; user tz is unset in tests, so
    // todayInTz falls back to UTC's YYYY-MM-DD. We just check it's a valid
    // ISO date — the exact value depends on the runtime clock.
    expect(res.activity.date).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    // Server-minted UUID.
    expect(res.activity.id).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
    );

    // audit_log gained exactly one row for this tool call (visible/
    // reversible trail per project convention).
    const after = await env.DB
      .prepare("SELECT COUNT(*) AS c FROM audit_log WHERE tool = 'log_activity'")
      .first<{ c: number }>();
    expect((after?.c ?? 0) - (before?.c ?? 0)).toBe(1);

    // Row is actually in the DB.
    const row = await env.DB
      .prepare('SELECT * FROM activities WHERE id = ?1')
      .bind(res.activity.id)
      .first<any>();
    expect(row).toBeTruthy();
    expect(row.source).toBe('mcp');
  });

  it('honors an explicit date and lower-cases the type', async () => {
    const res = await call('log_activity', {
      type: 'YOGA',
      date: '2026-04-01',
      duration_minutes: 45,
    });
    expect(res.ok).toBe(true);
    expect(res.activity.date).toBe('2026-04-01');
    expect(res.activity.type).toBe('yoga');
    expect(res.message).toContain('45min yoga on 2026-04-01');
  });
});
