import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';

// Away dates from the app (docs/plans/coach-free-planning P0): the member's
// own add, edit and remove of plans.meta.trips, through the same versioned
// plan-meta writer the coach's add_trip / update_trip / remove_trip use.

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

interface TripRow {
  id: string;
  start: string;
  end: string;
  type: string;
  can_train_light?: boolean;
  note?: string;
}

async function freshPlan(H: Record<string, string>): Promise<{ id: string; version: number }> {
  const created = await SELF.fetch(`${BASE}/api/plan`, {
    method: 'POST', headers: H, body: JSON.stringify({ name: 'Away Dates Plan' }),
  });
  expect(created.status).toBeLessThan(300);
  return (await SELF.fetch(`${BASE}/api/plan/active`, { headers: H }))
    .json<{ id: string; version: number }>();
}

async function storedTrips(planId: string): Promise<TripRow[]> {
  const row = await env.DB.prepare('SELECT meta FROM plans WHERE id=?1')
    .bind(planId).first<{ meta: string | null }>();
  return (JSON.parse(row?.meta ?? '{}') as { trips?: TripRow[] }).trips ?? [];
}

describe('away dates over REST', () => {
  it('adds, edits and removes a trip with version checks and an ios audit row', async () => {
    const H = auth(await devJwt());
    const plan = await freshPlan(H);

    const added = await SELF.fetch(`${BASE}/api/plan/trips`, {
      method: 'POST', headers: H,
      body: JSON.stringify({
        start: '2026-12-20', end: '2026-12-27', type: 'travel',
        can_train_light: false, note: 'Family visit', expected_version: plan.version,
      }),
    });
    expect(added.status).toBe(200);
    const addBody = await added.json<{ ok: true; version: number; id: string; trips: TripRow[] }>();
    expect(addBody.version).toBe(plan.version + 1);
    expect(addBody.trips).toEqual([{
      id: addBody.id, start: '2026-12-20', end: '2026-12-27', type: 'travel',
      can_train_light: false, note: 'Family visit',
    }]);
    expect(await storedTrips(plan.id)).toEqual(addBody.trips);

    const stale = await SELF.fetch(`${BASE}/api/plan/trips/${addBody.id}`, {
      method: 'PATCH', headers: H,
      body: JSON.stringify({ end: '2026-12-28', expected_version: plan.version }),
    });
    expect(stale.status).toBe(409);
    expect(await stale.json()).toEqual({ conflict: true, current_version: addBody.version });

    const edited = await SELF.fetch(`${BASE}/api/plan/trips/${addBody.id}`, {
      method: 'PATCH', headers: H,
      body: JSON.stringify({ end: '2026-12-28', can_train_light: true, expected_version: addBody.version }),
    });
    expect(edited.status).toBe(200);
    const editBody = await edited.json<{ version: number; trips: TripRow[] }>();
    expect(editBody.version).toBe(addBody.version + 1);
    expect(editBody.trips).toEqual([{
      id: addBody.id, start: '2026-12-20', end: '2026-12-28', type: 'travel',
      can_train_light: true, note: 'Family visit',
    }]);

    const removed = await SELF.fetch(
      `${BASE}/api/plan/trips/${addBody.id}?expected_version=${editBody.version}`,
      { method: 'DELETE', headers: H },
    );
    expect(removed.status).toBe(200);
    const removeBody = await removed.json<{ version: number; trips: TripRow[] }>();
    expect(removeBody.version).toBe(editBody.version + 1);
    expect(removeBody.trips).toEqual([]);
    expect(await storedTrips(plan.id)).toEqual([]);

    const audits = await env.DB.prepare(
      `SELECT tool FROM audit_log WHERE actor='ios' AND tool IN ('add_trip','update_trip','remove_trip')
        AND created_at >= (SELECT created_at FROM plans WHERE id=?1)`,
    ).bind(plan.id).all<{ tool: string }>();
    expect(audits.results.map((row) => row.tool).sort()).toEqual(['add_trip', 'remove_trip', 'update_trip']);
  });

  it('defaults the type to travel and rejects bad input without a write', async () => {
    const H = auth(await devJwt());
    const plan = await freshPlan(H);
    const post = (body: Record<string, unknown>) => SELF.fetch(`${BASE}/api/plan/trips`, {
      method: 'POST', headers: H, body: JSON.stringify(body),
    });

    const missingVersion = await post({ start: '2026-12-01', end: '2026-12-02' });
    expect(missingVersion.status).toBe(400);
    expect(await missingVersion.json()).toEqual({ error: 'invalid_fields', fields: ['expected_version'] });

    const bad = await post({
      start: '12/01/2026', end: '2026-12-02', type: 'holiday', can_train_light: 'no',
      surprise: 1, expected_version: plan.version,
    });
    expect(bad.status).toBe(400);
    const badBody = await bad.json<{ fields: string[] }>();
    expect(badBody.fields.sort()).toEqual(['can_train_light', 'start', 'surprise', 'type']);

    const inverted = await post({ start: '2026-12-05', end: '2026-12-01', expected_version: plan.version });
    expect(inverted.status).toBe(400);
    expect(await inverted.json()).toEqual({ error: 'invalid_range' });

    const tooLong = await post({
      start: '2026-12-01', end: '2026-12-02', note: 'x'.repeat(501), expected_version: plan.version,
    });
    expect(tooLong.status).toBe(400);

    const active = await (await SELF.fetch(`${BASE}/api/plan/active`, { headers: H }))
      .json<{ version: number }>();
    expect(active.version).toBe(plan.version);
    expect(await storedTrips(plan.id)).toEqual([]);

    const plain = await post({ start: '2026-12-01', end: '2026-12-01', expected_version: plan.version });
    expect(plain.status).toBe(200);
    const plainBody = await plain.json<{ id: string; version: number; trips: TripRow[] }>();
    expect(plainBody.trips).toEqual([{ id: plainBody.id, start: '2026-12-01', end: '2026-12-01', type: 'travel' }]);

    const inverting = await SELF.fetch(`${BASE}/api/plan/trips/${plainBody.id}`, {
      method: 'PATCH', headers: H,
      body: JSON.stringify({ start: '2026-12-09', expected_version: plainBody.version }),
    });
    expect(inverting.status).toBe(400);
    expect(await inverting.json()).toEqual({ error: 'invalid_range' });

    const missing = await SELF.fetch(`${BASE}/api/plan/trips/not-a-trip?expected_version=${plainBody.version}`, {
      method: 'DELETE', headers: H,
    });
    expect(missing.status).toBe(404);
    expect(await missing.json()).toEqual({ error: 'trip_not_found' });

    const noVersion = await SELF.fetch(`${BASE}/api/plan/trips/${plainBody.id}`, {
      method: 'DELETE', headers: H,
    });
    expect(noVersion.status).toBe(400);
    expect(await storedTrips(plan.id)).toHaveLength(1);
  });
});
