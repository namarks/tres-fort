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

async function currentVersion(): Promise<number> {
  return (await call('get_current_plan', {})).version as number;
}

// Authored-intent fixtures shared by the per-tool cases and the read-path
// case, so the shapes each side asserts on cannot drift apart.
const RACE = {
  name: 'Salem 70.3',
  date: '2027-07-18',
  discipline: 'triathlon',
  distance: '70.3',
  priority: 'A',
  location: 'Salem, OR',
};
const PHASES = [
  { phase: 'base', start: '2026-06-01', end: '2026-10-31', strength_emphasis: 'hypertrophy', weekly_load_target: 350 },
  { phase: 'build', start: '2026-11-01', end: '2027-04-30' },
];
// can_train_light is deliberately false: the read path defaults a missing
// field to true, so only a false value proves the field actually round-trips.
const TRIP = { start: '2026-08-15', end: '2026-08-25', type: 'travel', can_train_light: false, note: 'Italy' };
const STRESS_MODEL = {
  discipline_weights: { run: { aerobic: 1, neuromuscular: 0.4, impact: 1 }, swim: { aerobic: 1, impact: 0 } },
  interference_rules: ['heavy_lower_body >= 48h from key_run_or_brick'],
  age_modifiers: { athlete_age: 75, recovery_multiplier: 1.4 },
};

describe('plan meta: race / periodization / trips / stress_model (M2)', () => {
  // One seed for the whole block. vitest-pool-workers' default isolatedStorage
  // keeps beforeAll writes visible to every `it` below and undoes each `it`'s
  // own writes after it runs, so every case starts from this same base plan at
  // the same version. The cases are independent by design: a single sequential
  // case covering all of them made ~22 Worker round-trips and sat right at
  // vitest's 5 s default per-test timeout on a CI runner.
  let jwt: string;
  let base: number;

  beforeAll(async () => {
    // Mint the dev JWT FIRST so the dev-owner user is the earliest row: with
    // OWNER_APPLE_SUB unset, the MCP owner resolves to "earliest by created_at",
    // so the MCP writes below attach to this same user (single-user invariant)
    // and the /api/state read sees them.
    jwt = await devJwt();

    // Minimal active plan so there is something to attach meta to.
    const built = await call('update_plan', {
      name: 'Multisport',
      days: [
        { day_label: 'A', name: 'Full Body', exercises: [{ exercise: 'squat', target_sets: 3, target_reps: 5 }] },
      ],
    });
    expect(built.conflict).toBe(false);
    base = built.plan.version as number;
  });

  it('set_race stores the race, bumps the version, and writes audit + Claude note', async () => {
    const race = await call('set_race', RACE);
    expect(race.ok).toBe(true);
    expect(race.version).toBe(base + 1);
    expect(race.race).toMatchObject({ name: 'Salem 70.3', date: '2027-07-18', priority: 'A', location: 'Salem, OR' });
    expect((await call('get_current_plan', {})).race).toMatchObject({ name: 'Salem 70.3', discipline: 'triathlon' });

    // every meta write is audited; plan-change notes are Claude-authored
    const audit = await env.DB.prepare("SELECT COUNT(*) AS c FROM audit_log WHERE tool = 'set_race'").first<{ c: number }>();
    expect(audit!.c).toBe(1);
    const note = await env.DB.prepare(
      "SELECT COUNT(*) AS c FROM notes WHERE author='claude' AND body LIKE 'Set A-race%'",
    ).first<{ c: number }>();
    expect(note!.c).toBe(1);
  });

  it('set_race rejects a malformed date with no write', async () => {
    const bad = await call('set_race', { name: 'x', date: 'July 4th', discipline: 'running' });
    expect(bad).toMatchObject({ error: 'invalid_date' });
    expect(await currentVersion()).toBe(base);
  });

  it('set_periodization replaces the full ordered array and rejects an inverted phase', async () => {
    const per = await call('set_periodization', { phases: PHASES });
    expect(per.ok).toBe(true);
    expect(per.version).toBe(base + 1);
    expect(per.periodization).toHaveLength(2);
    expect(per.periodization[0]).toMatchObject({ phase: 'base', weekly_load_target: 350 });

    // An inverted phase (start > end) covers no dates → rejected (Codex #64 P2), no write.
    const inverted = await call('set_periodization', {
      phases: [{ phase: 'base', start: '2026-10-31', end: '2026-06-01' }],
    });
    expect(inverted).toMatchObject({ error: 'invalid_range' });
    const cp = await call('get_current_plan', {});
    expect(cp.version).toBe(per.version);
    expect(cp.periodization).toHaveLength(2);
  });

  it('trips: add → update (preserving unset fields) → remove, each bumping the version and audited', async () => {
    const t1 = await call('add_trip', TRIP);
    expect(t1.ok).toBe(true);
    expect(typeof t1.id).toBe('string');
    expect(t1.version).toBe(base + 1);
    const tripId = t1.id as string;

    const t2 = await call('update_trip', { id: tripId, note: 'Italy — running shoes only' });
    expect(t2.ok).toBe(true);
    expect(t2.version).toBe(base + 2);
    const updated = t2.trips.find((x: any) => x.id === tripId);
    expect(updated.note).toBe('Italy — running shoes only');
    expect(updated.can_train_light).toBe(false); // preserved in the returned merge
    // ...and persisted: this is a re-parsed read, where a dropped field would
    // read back as true.
    expect((await call('get_current_plan', {})).trips[0]).toMatchObject({
      id: tripId,
      note: 'Italy — running shoes only',
      can_train_light: false,
    });

    const rm = await call('remove_trip', { id: tripId });
    expect(rm.ok).toBe(true);
    expect(rm.version).toBe(base + 3);
    expect((await call('get_current_plan', {})).trips).toHaveLength(0);
    // the removal rides /api/state too
    const stateRes = await SELF.fetch(`${BASE}/api/state?since=0`, {
      headers: { Authorization: `Bearer ${jwt}` },
    });
    expect(stateRes.status).toBe(200);
    const state = await stateRes.json<any>();
    expect(state.plan_version).toBe(rm.version);
    expect(state.plan.trips).toEqual([]);

    const audit = await env.DB.prepare(
      "SELECT COUNT(*) AS c FROM audit_log WHERE tool IN ('add_trip','update_trip','remove_trip')",
    ).first<{ c: number }>();
    expect(audit!.c).toBe(3);
  });

  it('trips: a missing id and inverted ranges (add + update) are rejected with no write', async () => {
    const t1 = await call('add_trip', TRIP);
    expect(t1.ok).toBe(true);

    const missing = await call('update_trip', { id: 'not-a-real-id', note: 'x' });
    expect(missing).toMatchObject({ error: 'trip_not_found' });

    // Inverted range (start > end) covers no dates → rejected (Codex #64 P2),
    // on both add and update.
    const inverted = await call('add_trip', { start: '2026-09-10', end: '2026-09-01' });
    expect(inverted).toMatchObject({ error: 'invalid_range' });
    const invertUpdate = await call('update_trip', { id: t1.id, start: '2026-08-30' }); // > existing end 08-25
    expect(invertUpdate).toMatchObject({ error: 'invalid_range' });

    const cp = await call('get_current_plan', {});
    expect(cp.version).toBe(t1.version);
    expect(cp.trips).toHaveLength(1);
    expect(cp.trips[0]).toMatchObject({ id: t1.id, start: '2026-08-15', end: '2026-08-25' });
  });

  it('set_stress_model passes freeform dimensions through', async () => {
    const sm = await call('set_stress_model', STRESS_MODEL);
    expect(sm.ok).toBe(true);
    expect(sm.version).toBe(base + 1);
    const cp = await call('get_current_plan', {});
    expect(cp.stress_model.age_modifiers.athlete_age).toBe(75);
    expect(cp.stress_model.discipline_weights.run).toMatchObject({ aerobic: 1, neuromuscular: 0.4, impact: 1 });
    expect(cp.stress_model.interference_rules).toEqual(['heavy_lower_body >= 48h from key_run_or_brick']);
  });

  it('a stale expected_version conflicts with no write', async () => {
    // Any value other than the current version is stale; base - 1 is never it.
    const stale = await call('set_race', { ...RACE, name: 'y', expected_version: base - 1 });
    expect(stale).toMatchObject({ conflict: true, current_version: base });
    const cp = await call('get_current_plan', {});
    expect(cp.version).toBe(base);
    expect(cp.race).toBeNull();
  });

  it('every authored field rides get_current_plan and /api/state inside the plan payload', async () => {
    await call('set_race', RACE);
    await call('set_periodization', { phases: PHASES });
    await call('add_trip', TRIP);
    const sm = await call('set_stress_model', STRESS_MODEL);
    expect(sm.ok).toBe(true);
    expect(sm.version).toBe(base + 4);

    // get_current_plan exposes every authored field, pre-parsed
    const cp = await call('get_current_plan', {});
    expect(cp.version).toBe(sm.version);
    expect(cp.race.name).toBe('Salem 70.3');
    expect(cp.periodization).toHaveLength(2);
    expect(cp.trips).toHaveLength(1);
    expect(cp.stress_model.age_modifiers.athlete_age).toBe(75);

    // rides /api/state inside the plan payload (same owner as the MCP writes)
    const stateRes = await SELF.fetch(`${BASE}/api/state?since=0`, {
      headers: { Authorization: `Bearer ${jwt}` },
    });
    expect(stateRes.status).toBe(200);
    const state = await stateRes.json<any>();
    expect(state.plan_version).toBe(sm.version);
    expect(state.plan.race.name).toBe('Salem 70.3');
    expect(state.plan.periodization).toHaveLength(2);
    expect(state.plan.trips).toHaveLength(1);
    expect(state.plan.trips[0]).toMatchObject({ note: 'Italy', can_train_light: false });
    expect(state.plan.stress_model.age_modifiers.athlete_age).toBe(75);
    // schedule still rides alongside (unchanged behaviour)
    expect(state.plan.schedule).toBeTruthy();

    // removing the trip leaves the sibling meta intact
    const rm = await call('remove_trip', { id: state.plan.trips[0].id });
    expect(rm.version).toBe(sm.version + 1);
    const after = await call('get_current_plan', {});
    expect(after.version).toBe(rm.version);
    expect(after.trips).toEqual([]);
    expect(after.race.name).toBe('Salem 70.3');
    expect(after.periodization).toHaveLength(2);
    expect(after.stress_model.age_modifiers.athlete_age).toBe(75);

    // every meta write is audited
    const audit = await env.DB.prepare(
      "SELECT COUNT(*) AS c FROM audit_log WHERE tool IN ('set_race','set_periodization','add_trip','set_stress_model','remove_trip')",
    ).first<{ c: number }>();
    expect(audit!.c).toBe(5);
  });
});
