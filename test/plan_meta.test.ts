import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';

// M2 (docs/MULTISPORT.md §4): authored multisport intent — race, periodization,
// trips, stress_model — lives in plans.meta as a VERSIONED document. These
// tools ride the same optimistic-concurrency / audit+note path as set_schedule
// and surface on /api/state inside the plan payload. No projection change here.

const BASE = 'https://tres-fort.test';
const TOKEN = 'test-mcp-token';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

let rpcId = 0;
async function call(name: string, args: unknown) {
  const r = await SELF.fetch(`${BASE}/mcp`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', Authorization: `Bearer ${TOKEN}` },
    body: JSON.stringify({ jsonrpc: '2.0', id: ++rpcId, method: 'tools/call', params: { name, arguments: args } }),
  });
  const body = await r.json<any>();
  const text = body.result.content[0].text as string;
  try {
    return JSON.parse(text);
  } catch {
    return { error: text };
  }
}

async function devJwt(): Promise<string> {
  const r = await SELF.fetch(`${BASE}/auth/dev`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ secret: 'test-dev' }),
  });
  expect(r.status).toBe(200);
  return (await r.json<{ jwt: string }>()).jwt;
}

describe('plan meta: race / periodization / trips / stress_model (M2)', () => {
  it('sets all authored intent, versioned + audited, with trips CRUD and a stale-version conflict, and rides /api/state', async () => {
    // Mint the dev JWT FIRST so the dev-owner user is the earliest row: with
    // OWNER_APPLE_SUB unset, the MCP owner resolves to "earliest by created_at",
    // so the MCP writes below attach to this same user (single-user invariant)
    // and the /api/state read at the end sees them.
    const jwt = await devJwt();

    // Minimal active plan so there is something to attach meta to.
    const built = await call('update_plan', {
      name: 'Multisport',
      days: [
        { day_label: 'A', name: 'Full Body', exercises: [{ exercise: 'squat', target_sets: 3, target_reps: 5 }] },
      ],
    });
    expect(built.conflict).toBe(false);
    let v = built.plan.version as number;

    // set_race: stores fields, +1 version
    const race = await call('set_race', {
      name: 'Salem 70.3',
      date: '2027-07-18',
      discipline: 'triathlon',
      distance: '70.3',
      priority: 'A',
      location: 'Salem, OR',
    });
    expect(race.ok).toBe(true);
    expect(race.version).toBe(v + 1);
    expect(race.race).toMatchObject({ name: 'Salem 70.3', date: '2027-07-18', priority: 'A', location: 'Salem, OR' });
    v = race.version;

    // malformed date is rejected with no write (version unchanged)
    const bad = await call('set_race', { name: 'x', date: 'July 4th', discipline: 'running' });
    expect(bad).toMatchObject({ error: 'invalid_date' });
    expect((await call('get_current_plan', {})).version).toBe(v);

    // set_periodization: replaces the full ordered array
    const per = await call('set_periodization', {
      phases: [
        { phase: 'base', start: '2026-06-01', end: '2026-10-31', strength_emphasis: 'hypertrophy', weekly_load_target: 350 },
        { phase: 'build', start: '2026-11-01', end: '2027-04-30' },
      ],
    });
    expect(per.ok).toBe(true);
    expect(per.version).toBe(v + 1);
    expect(per.periodization).toHaveLength(2);
    expect(per.periodization[0]).toMatchObject({ phase: 'base', weekly_load_target: 350 });
    v = per.version;

    // An inverted phase (start > end) covers no dates → rejected (Codex #64 P2).
    const invertedPhase = await call('set_periodization', {
      phases: [{ phase: 'base', start: '2026-10-31', end: '2026-06-01' }],
    });
    expect(invertedPhase).toMatchObject({ error: 'invalid_range' });

    // trips: add → update → (reject missing) → later remove
    const t1 = await call('add_trip', { start: '2026-08-15', end: '2026-08-25', type: 'travel', can_train_light: true, note: 'Italy' });
    expect(t1.ok).toBe(true);
    expect(typeof t1.id).toBe('string');
    expect(t1.version).toBe(v + 1);
    const tripId = t1.id as string;
    v = t1.version;

    const t2 = await call('update_trip', { id: tripId, note: 'Italy — running shoes only' });
    expect(t2.ok).toBe(true);
    expect(t2.version).toBe(v + 1);
    expect(t2.trips.find((x: any) => x.id === tripId).note).toBe('Italy — running shoes only');
    expect(t2.trips.find((x: any) => x.id === tripId).can_train_light).toBe(true); // preserved
    v = t2.version;

    const missing = await call('update_trip', { id: 'not-a-real-id', note: 'x' });
    expect(missing).toMatchObject({ error: 'trip_not_found' });

    // Inverted range (start > end) covers no dates → rejected (Codex #64 P2),
    // on both add and update.
    const inverted = await call('add_trip', { start: '2026-09-10', end: '2026-09-01' });
    expect(inverted).toMatchObject({ error: 'invalid_range' });
    const invertUpdate = await call('update_trip', { id: tripId, start: '2026-08-30' }); // > existing end 08-25
    expect(invertUpdate).toMatchObject({ error: 'invalid_range' });

    // stress model: freeform dimensions pass through
    const sm = await call('set_stress_model', {
      discipline_weights: { run: { aerobic: 1, neuromuscular: 0.4, impact: 1 }, swim: { aerobic: 1, impact: 0 } },
      interference_rules: ['heavy_lower_body >= 48h from key_run_or_brick'],
      age_modifiers: { athlete_age: 75, recovery_multiplier: 1.4 },
    });
    expect(sm.ok).toBe(true);
    expect(sm.version).toBe(v + 1);
    v = sm.version;

    // optimistic concurrency: a stale expected_version conflicts, no write
    const stale = await call('set_race', { name: 'y', date: '2027-01-01', discipline: 'running', expected_version: 1 });
    expect(stale).toMatchObject({ conflict: true, current_version: v });
    expect((await call('get_current_plan', {})).version).toBe(v);

    // get_current_plan exposes every authored field, pre-parsed
    const cp = await call('get_current_plan', {});
    expect(cp.race.name).toBe('Salem 70.3');
    expect(cp.periodization).toHaveLength(2);
    expect(cp.trips).toHaveLength(1);
    expect(cp.stress_model.age_modifiers.athlete_age).toBe(75);

    // remove the trip → version bump, trips empty
    const rm = await call('remove_trip', { id: tripId });
    expect(rm.ok).toBe(true);
    expect(rm.version).toBe(v + 1);
    expect((await call('get_current_plan', {})).trips).toHaveLength(0);
    v = rm.version;

    // rides /api/state inside the plan payload (same owner as the MCP writes)
    const stateRes = await SELF.fetch(`${BASE}/api/state?since=0`, {
      headers: { Authorization: `Bearer ${jwt}` },
    });
    expect(stateRes.status).toBe(200);
    const state = await stateRes.json<any>();
    expect(state.plan_version).toBe(v);
    expect(state.plan.race.name).toBe('Salem 70.3');
    expect(state.plan.periodization).toHaveLength(2);
    expect(state.plan.trips).toHaveLength(0);
    expect(state.plan.stress_model.age_modifiers.athlete_age).toBe(75);
    // schedule still rides alongside (unchanged behaviour)
    expect(state.plan.schedule).toBeTruthy();

    // every meta write is audited; plan-change notes are Claude-authored
    const audit = await env.DB.prepare(
      "SELECT COUNT(*) AS c FROM audit_log WHERE tool IN ('set_race','set_periodization','add_trip','update_trip','remove_trip','set_stress_model')",
    ).first<{ c: number }>();
    expect(audit!.c).toBeGreaterThanOrEqual(6);
    const note = await env.DB.prepare(
      "SELECT COUNT(*) AS c FROM notes WHERE author='claude' AND body LIKE 'Set A-race%'",
    ).first<{ c: number }>();
    expect(note!.c).toBeGreaterThanOrEqual(1);
  });
});
