import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';

const BASE = 'https://tres-fort.test';
// Matches INTERVALS_WEBHOOK_SECRET injected by vitest.config.ts.
const SECRET = 'test-webhook-secret';

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

const auth = (jwt: string) => ({
  'content-type': 'application/json',
  Authorization: `Bearer ${jwt}`,
});

/**
 * Connect the single owner user to an intervals.icu athlete via the same REST
 * path iOS uses (PATCH /api/me/integrations/intervals) so the webhook receiver
 * can resolve athlete_id → user. Returns the connected athlete_id.
 */
async function connectAthlete(athleteId: string): Promise<string> {
  const H = auth(await devJwt());
  const r = await SELF.fetch(`${BASE}/api/me/integrations/intervals`, {
    method: 'PATCH',
    headers: H,
    body: JSON.stringify({ api_key: 'webhook-test-key', athlete_id: athleteId }),
  });
  expect(r.status).toBe(200);
  expect(await r.json()).toEqual({ connected: true });
  return athleteId;
}

function post(body: unknown, headers: Record<string, string> = {}) {
  return SELF.fetch(`${BASE}/webhooks/intervals`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
}

describe('POST /webhooks/intervals — intervals.icu push receiver', () => {
  it('is PUBLIC (no app-JWT / MCP bearer required) and accepts a valid secret', async () => {
    const athleteId = await connectAthlete('wh-athlete-1');
    const r = await post({
      secret: SECRET,
      events: [{ athlete_id: athleteId, type: 'CALENDAR_UPDATED', timestamp: '2026-05-31T00:00:00Z' }],
    });
    // The triggered syncs no-op gracefully (no real intervals network in
    // tests). The receiver must still return a clean 200 — and explicitly NOT
    // 500 (a crash) nor 204 (which intervals historically retried).
    expect(r.status).toBe(200);
    expect(r.status).not.toBe(204);
    expect(await r.json()).toEqual({ ok: true });
  });

  it('CALENDAR_UPDATED for a known athlete routes to BOTH syncs and returns 200 (not 204)', async () => {
    const athleteId = await connectAthlete('wh-athlete-2');
    const r = await post({
      secret: SECRET,
      // A duplicated batch (intervals can send multiple CALENDAR_UPDATED for
      // one change) — must be deduped and still a clean single 200.
      events: [
        { athlete_id: athleteId, type: 'CALENDAR_UPDATED', timestamp: 't1' },
        { athlete_id: athleteId, type: 'CALENDAR_UPDATED', timestamp: 't2' },
      ],
    });
    expect(r.status).toBe(200);
    expect(r.status).not.toBe(204);
    expect(await r.json()).toEqual({ ok: true });
  });

  it('ACTIVITY_* events for a known athlete are accepted with 200', async () => {
    const athleteId = await connectAthlete('wh-athlete-3');
    for (const type of ['ACTIVITY_UPLOADED', 'ACTIVITY_ANALYZED', 'ACTIVITY_UPDATED', 'ACTIVITY_DELETED']) {
      const r = await post({ secret: SECRET, events: [{ athlete_id: athleteId, type }] });
      expect(r.status, type).toBe(200);
      expect(await r.json(), type).toEqual({ ok: true });
    }
  });

  it('WELLNESS_UPDATED / FITNESS_UPDATED are accepted as a no-op (200, no fitness store yet)', async () => {
    const athleteId = await connectAthlete('wh-athlete-4');
    for (const type of ['WELLNESS_UPDATED', 'FITNESS_UPDATED']) {
      const r = await post({ secret: SECRET, events: [{ athlete_id: athleteId, type }] });
      expect(r.status, type).toBe(200);
      expect(await r.json(), type).toEqual({ ok: true });
    }
  });

  it('missing secret → 401 and no work', async () => {
    const athleteId = await connectAthlete('wh-athlete-5');
    const r = await post({ events: [{ athlete_id: athleteId, type: 'CALENDAR_UPDATED' }] });
    expect(r.status).toBe(401);
  });

  it('wrong secret → 401', async () => {
    const athleteId = await connectAthlete('wh-athlete-6');
    const r = await post({
      secret: 'not-the-secret',
      events: [{ athlete_id: athleteId, type: 'CALENDAR_UPDATED' }],
    });
    expect(r.status).toBe(401);
  });

  it('malformed JSON body → 401 (unauthenticated by definition)', async () => {
    const r = await post('{not valid json');
    expect(r.status).toBe(401);
  });

  it('unknown athlete_id → 200 no-op (accepted gracefully)', async () => {
    const r = await post({
      secret: SECRET,
      events: [{ athlete_id: 'nobody-owns-this', type: 'CALENDAR_UPDATED', timestamp: 't' }],
    });
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ ok: true });
  });

  it('unknown event type and empty batch → 200 (accepted gracefully)', async () => {
    const athleteId = await connectAthlete('wh-athlete-7');
    const unknownType = await post({
      secret: SECRET,
      events: [{ athlete_id: athleteId, type: 'SOMETHING_NEW' }],
    });
    expect(unknownType.status).toBe(200);

    const emptyBatch = await post({ secret: SECRET, events: [] });
    expect(emptyBatch.status).toBe(200);

    const noEventsKey = await post({ secret: SECRET });
    expect(noEventsKey.status).toBe(200);
  });
});
