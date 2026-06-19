import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';

// Phase 1 — Apple Health (HealthKit) on-device push ingest.
// HealthKit lives only on the phone; the iOS app reads HKWorkout and POSTs to
// POST /api/activities/healthkit, which upserts into the SAME external_activities
// cache the intervals pull writes (source='healthkit'), client-UUID idempotent.

const BASE = 'https://tres-fort.test';

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

const uuid = () => crypto.randomUUID();

const workout = (over: Record<string, unknown> = {}) => ({
  id: uuid(),
  date: '2026-06-18',
  start_date_local_ms: Date.parse('2026-06-18T10:00:00Z'),
  kind: 'run',
  name: 'Treadmill Run',
  moving_time_sec: 1800,
  elapsed_time_sec: 1850,
  distance_m: 5000,
  average_hr: 145,
  max_hr: 168,
  calories: 320,
  ...over,
});

describe('POST /api/activities/healthkit — Apple Health push ingest', () => {
  it('requires auth', async () => {
    const r = await SELF.fetch(`${BASE}/api/activities/healthkit`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(workout()),
    });
    expect(r.status).toBe(401);
  });

  it('ingests a workout into external_activities with source=healthkit', async () => {
    const jwt = await devJwt();
    const w = workout();
    const r = await SELF.fetch(`${BASE}/api/activities/healthkit`, {
      method: 'POST',
      headers: auth(jwt),
      body: JSON.stringify(w),
    });
    expect(r.status).toBe(201);
    const row = await r.json<{
      id: string;
      source: string;
      kind: string;
      average_hr: number | null;
      training_load: number | null;
      canonical: number;
    }>();
    expect(row.source).toBe('healthkit');
    expect(row.id).toMatch(/^healthkit:activity:.+:/);
    expect(row.id.endsWith(w.id)).toBe(true);
    expect(row.kind).toBe('run');
    expect(row.average_hr).toBe(145);
    // We do not fabricate a load number without per-user HR anchors.
    expect(row.training_load).toBeNull();
    expect(row.canonical).toBe(1);

    // It rides the normal sync surface (activities_since watermark).
    const state = await SELF.fetch(`${BASE}/api/state?activities_since=0`, { headers: auth(jwt) });
    const body = await state.json<{ external_activities: { id: string; source: string }[] }>();
    expect(body.external_activities.some((a) => a.id === row.id && a.source === 'healthkit')).toBe(true);
  });

  it('is idempotent on the client id; a re-push updates in place (no duplicate)', async () => {
    const jwt = await devJwt();
    const w = workout({ average_hr: 140 });
    const first = await SELF.fetch(`${BASE}/api/activities/healthkit`, {
      method: 'POST',
      headers: auth(jwt),
      body: JSON.stringify(w),
    });
    const firstRow = await first.json<{ id: string }>();
    // Same id, revised stats (HealthKit can re-summarise a workout).
    const second = await SELF.fetch(`${BASE}/api/activities/healthkit`, {
      method: 'POST',
      headers: auth(jwt),
      body: JSON.stringify({ ...w, average_hr: 152, distance_m: 5200 }),
    });
    expect(second.status).toBe(201);
    const secondRow = await second.json<{ id: string; average_hr: number; distance_m: number }>();
    expect(secondRow.id).toBe(firstRow.id);
    expect(secondRow.average_hr).toBe(152);
    expect(secondRow.distance_m).toBe(5200);

    const cnt = await env.DB.prepare(
      "SELECT COUNT(*) AS c FROM external_activities WHERE id = ?1",
    )
      .bind(firstRow.id)
      .first<{ c: number }>();
    expect(cnt!.c).toBe(1);
  });

  it('rejects a bad id / date / kind', async () => {
    const jwt = await devJwt();
    const bad = async (over: Record<string, unknown>) =>
      (
        await SELF.fetch(`${BASE}/api/activities/healthkit`, {
          method: 'POST',
          headers: auth(jwt),
          body: JSON.stringify(workout(over)),
        })
      ).status;
    expect(await bad({ id: 'not-a-uuid' })).toBe(400);
    expect(await bad({ date: '06/18/2026' })).toBe(400);
    expect(await bad({ kind: 'Run' })).toBe(400); // must be lowercase
    expect(await bad({ kind: '' })).toBe(400);
  });

  it('coerces non-finite numeric fields to null rather than persisting junk', async () => {
    const jwt = await devJwt();
    const r = await SELF.fetch(`${BASE}/api/activities/healthkit`, {
      method: 'POST',
      headers: auth(jwt),
      body: JSON.stringify(workout({ distance_m: null, average_watts: undefined, max_hr: 'oops' })),
    });
    expect(r.status).toBe(201);
    const row = await r.json<{ distance_m: number | null; average_watts: number | null; max_hr: number | null }>();
    expect(row.distance_m).toBeNull();
    expect(row.average_watts).toBeNull();
    expect(row.max_hr).toBeNull();
  });
});
