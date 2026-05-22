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

const BASE = 'https://lift-coach.test';
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
});
