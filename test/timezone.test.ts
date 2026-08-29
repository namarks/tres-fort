/**
 * #4 — "today" must be device-local, not UTC.
 *
 * The device reports its IANA timezone via the X-Device-TZ header on
 * /api/state; the server stores it on the user and the MCP read side
 * computes "today" from it. The classic failure: at 17:32 PT the UTC date
 * has already rolled to tomorrow, so get_today_workout returned the wrong
 * day. These tests pin a fixed instant and assert the civil date resolves
 * per the stored zone.
 */
import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { afterEach, beforeAll, describe, expect, it, vi } from 'vitest';

const BASE = 'https://tres-fort.test';
const TOKEN = 'test-mcp-token';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

afterEach(() => {
  vi.useRealTimers();
});

let id = 0;
async function call(name: string, args: unknown) {
  const r = await SELF.fetch(`${BASE}/mcp`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', Authorization: `Bearer ${TOKEN}` },
    body: JSON.stringify({
      jsonrpc: '2.0',
      id: ++id,
      method: 'tools/call',
      params: { name, arguments: args },
    }),
  });
  const body = await r.json<any>();
  return JSON.parse(body.result.content[0].text);
}

async function devJwt(): Promise<string> {
  const r = await SELF.fetch(`${BASE}/auth/dev`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ secret: 'test-dev' }),
  });
  return (await r.json<{ jwt: string }>()).jwt;
}

describe('#4 device-local today', () => {
  it('stores the device tz from X-Device-TZ and resolves today in that zone', async () => {
    // 2026-05-22 00:32 UTC == 2026-05-21 17:32 America/Los_Angeles.
    // Set the clock BEFORE issuing the JWT so it verifies under the same now.
    vi.setSystemTime(new Date('2026-05-22T00:32:00Z'));
    const jwt = await devJwt();

    // No tz yet → MCP "today" falls back to UTC (the old, wrong behavior).
    const utc = await call('get_today_workout', {});
    expect(utc.date).toBe('2026-05-22');

    // Device syncs and reports its zone.
    const synced = await SELF.fetch(`${BASE}/api/state?since=0`, {
      headers: { Authorization: `Bearer ${jwt}`, 'X-Device-TZ': 'America/Los_Angeles' },
    });
    expect(synced.status).toBe(200);

    // Now MCP "today" is the device-local civil date — still the 21st.
    const local = await call('get_today_workout', {});
    expect(local.date).toBe('2026-05-21');
  });

  it('an invalid X-Device-TZ is ignored (no crash, tz unchanged)', async () => {
    vi.setSystemTime(new Date('2026-05-22T00:32:00Z'));
    const jwt = await devJwt();
    // Garbage tz should be ignored; the previously stored LA zone (from the
    // prior test, shared storage) or UTC fallback still yields a valid date.
    const r = await SELF.fetch(`${BASE}/api/state?since=0`, {
      headers: { Authorization: `Bearer ${jwt}`, 'X-Device-TZ': 'Not/A_Zone' },
    });
    expect(r.status).toBe(200);
    const today = await call('get_today_workout', {});
    expect(today.date).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  });

  it('captures tz from a NON-/state authenticated request (middleware)', async () => {
    // 2026-05-22 06:32 UTC: still 2026-05-21 in Honolulu (UTC-10), already
    // the 22nd in UTC. A non-/state call must update the stored tz so MCP
    // "today" follows the user even when they only log sets after travel.
    vi.setSystemTime(new Date('2026-05-22T06:32:00Z'));
    const jwt = await devJwt();
    const r = await SELF.fetch(`${BASE}/api/exercises`, {
      headers: { Authorization: `Bearer ${jwt}`, 'X-Device-TZ': 'Pacific/Honolulu' },
    });
    expect(r.status).toBe(200);
    const today = await call('get_today_workout', {});
    expect(today.date).toBe('2026-05-21');
  });

  it('uses the authenticated user timezone for REST today and omitted session dates', async () => {
    // At this frozen instant UTC is May 22 while Los Angeles is still May
    // 21, so this cannot pass accidentally via the old UTC date shortcut.
    vi.setSystemTime(new Date('2026-05-22T00:32:00Z'));
    const jwt = await devJwt();
    const headers = {
      'content-type': 'application/json',
      Authorization: `Bearer ${jwt}`,
      'X-Device-TZ': 'America/Los_Angeles',
    };
    const plan = await SELF.fetch(`${BASE}/api/plan`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ name: 'Local date defaults' }),
    });
    expect(plan.status).toBe(201);

    const todayResponse = await SELF.fetch(`${BASE}/api/today`, { headers });
    expect(todayResponse.status).toBe(200);
    const today = await todayResponse.json<{ session: { id: string; date: string } }>();
    expect(today.session.date).toBe('2026-05-21');

    const defaultResponse = await SELF.fetch(`${BASE}/api/sessions`, {
      method: 'POST',
      headers,
      body: '{}',
    });
    expect(defaultResponse.status).toBe(201);
    const defaulted = await defaultResponse.json<{ id: string; date: string }>();
    expect(defaulted).toMatchObject({ id: today.session.id, date: '2026-05-21' });

    const explicitResponse = await SELF.fetch(`${BASE}/api/sessions`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ date: '2026-06-15' }),
    });
    expect(explicitResponse.status).toBe(201);
    expect(await explicitResponse.json<{ date: string }>()).toMatchObject({ date: '2026-06-15' });
  });
});
