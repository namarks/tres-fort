// Laps of a planned run recorded in the app (docs/plans/planned-runs P9):
// the lap format, the TCX reader joining a track split where a step ended,
// and keeping and serving laps with the recording.
import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { decodeRoute } from '../src/activityRoute';
import { issueAppJwt } from '../src/auth';
import { parseRunLaps, serializeRunLaps, type RunLap } from '../src/runLaps';
import { parseTcx } from '../src/tcxFile';

const BASE = 'https://tres-fort.test';
const DATE = '2026-11-06';
const START_MS = Date.parse('2026-11-06T14:00:00Z');

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

const iso = (ms: number) => new Date(ms).toISOString().replace('.000Z', 'Z');

/** A warm-up, one 400 m interval, then a walk after the plan. */
const LAPS: RunLap[] = [
  {
    step: 1, kind: 'warmup', round: null, rounds: null, planned_duration_s: 300, planned_distance_m: null,
    target: null, start_s: 0, moving_s: 300, distance_m: 900.04, avg_hr: 132, max_hr: 141, end: 'completed',
  },
  {
    step: 2, kind: 'work', round: 1, rounds: 4, planned_duration_s: null, planned_distance_m: 400,
    target: { type: 'pace', fastest_s_per_km: 230, slowest_s_per_km: 240 },
    start_s: 300, moving_s: 93.26, distance_m: 400, avg_hr: 168, max_hr: 176, end: 'completed',
  },
  {
    step: null, kind: null, round: null, rounds: null, planned_duration_s: null, planned_distance_m: null,
    target: null, start_s: 393.3, moving_s: 207, distance_m: 300, avg_hr: 121, max_hr: 160, end: 'stopped',
  },
];

/** The recorder's TCX for a planned run: one lap per step, each lap's track
 * starting on the point the last one ended on, and a pause (a new track)
 * inside the last lap. A point every 10 s at 150 bpm. */
function lappedTcx(): string {
  const point = (i: number, ms: number) =>
    `<Trackpoint><Time>${iso(ms)}</Time><Position><LatitudeDegrees>${(45.5 + i * 0.0001).toFixed(7)}`
    + `</LatitudeDegrees><LongitudeDegrees>-122.6000000</LongitudeDegrees></Position>`
    + `<HeartRateBpm><Value>150</Value></HeartRateBpm></Trackpoint>`;
  const lap = (startMs: number, seconds: number, meters: number, tracks: number[][]) =>
    `<Lap StartTime="${iso(startMs)}"><TotalTimeSeconds>${seconds}</TotalTimeSeconds>`
    + `<DistanceMeters>${meters}</DistanceMeters><Intensity>Active</Intensity><TriggerMethod>Manual</TriggerMethod>`
    + tracks.map((t) => `<Track>${t.map((i) => point(i, START_MS + i * 10_000)).join('')}</Track>`).join('')
    + '</Lap>';
  // Points 0..30 run the warm-up, 30..39 the interval (point 30 repeats),
  // then 39..45, a pause, and 60..80 after the plan.
  const range = (from: number, to: number) => Array.from({ length: to - from + 1 }, (_, k) => from + k);
  return '<?xml version="1.0"?><TrainingCenterDatabase><Activities><Activity Sport="Running">'
    + `<Id>${iso(START_MS)}</Id>`
    + lap(START_MS, 300, 900, [range(0, 30)])
    + lap(START_MS + 300_000, 90, 400, [range(30, 39)])
    + lap(START_MS + 390_000, 260, 300, [range(39, 45), range(60, 80)])
    + '</Activity></Activities></TrainingCenterDatabase>';
}

describe('lap format', () => {
  it('keeps well-formed laps to a tenth, in a fixed key order', () => {
    const parsed = parseRunLaps(JSON.stringify(LAPS));
    expect(parsed).not.toBeNull();
    expect(parsed![0]!.distance_m).toBe(900);
    expect(parsed![1]!.moving_s).toBe(93.3);
    expect(parsed![1]!.target).toEqual({ type: 'pace', fastest_s_per_km: 230, slowest_s_per_km: 240 });
    const text = serializeRunLaps(parsed!);
    expect(Object.keys(JSON.parse(text)[0])).toEqual([
      'step', 'kind', 'round', 'rounds', 'planned_duration_s', 'planned_distance_m', 'target',
      'start_s', 'moving_s', 'distance_m', 'avg_hr', 'max_hr', 'end',
    ]);
    expect(parseRunLaps(text)).toEqual(parsed);
    // A skipped step and a run stopped mid-step are laps too.
    expect(parseRunLaps([{ ...LAPS[0], end: 'skipped' }, { ...LAPS[1], end: 'stopped' }])).not.toBeNull();
  });

  it('refuses laps that are not well formed', () => {
    const [warmup, work, after] = LAPS as [RunLap, RunLap, RunLap];
    const bad: unknown[] = [
      'not json',
      [],
      {},
      [{ ...warmup, extra: 1 }],
      [{ ...warmup, kind: 'sprint' }],
      [{ ...warmup, step: 0 }],
      [{ ...warmup, step: null }],
      [{ ...warmup, planned_distance_m: 400 }],
      [{ ...warmup, planned_duration_s: null }],
      [{ ...warmup, moving_s: -1 }],
      [{ ...warmup, distance_m: 'far' }],
      [{ ...warmup, avg_hr: 300 }],
      [{ ...warmup, avg_hr: 150, max_hr: 140 }],
      [{ ...warmup, avg_hr: 150.5 }],
      [{ ...warmup, end: 'done' }],
      [{ ...work, round: 5 }],
      [{ ...work, rounds: null }],
      [{ ...work, target: { type: 'pace', fastest_s_per_km: 250, slowest_s_per_km: 240 } }],
      [{ ...work, target: { type: 'power', watts: 300 } }],
      // Steps run in order, one after another, and only the last lap is after the plan.
      [work, warmup],
      [warmup, { ...work, step: 1 }],
      [warmup, { ...work, start_s: -1 }],
      [after, warmup],
      [warmup, { ...after, end: 'completed' }],
      [warmup, { ...after, planned_duration_s: 60 }],
      Array.from({ length: 202 }, (_, i) => ({ ...warmup, step: i + 1, start_s: i })),
    ];
    for (const value of bad) expect(parseRunLaps(value), JSON.stringify(value).slice(0, 120)).toBeNull();
  });
});

describe('TCX laps', () => {
  it('joins a track split where a step ended, and keeps a pause a break', () => {
    const run = parseTcx(lappedTcx());
    // Lap totals still add up to the run.
    expect(run.moving_sec).toBe(650);
    expect(run.distance_m).toBe(1600);
    // Points 0..45 are one stretch (the repeated points join), then 60..80.
    expect(run.segments.map((s) => s.length)).toEqual([46, 21]);
    expect(run.segments[0]![30]!.t).toBe(START_MS + 300_000);
    expect(run.segments[0]![31]!.t).toBe(START_MS + 310_000);
    // Heart rate on moving time: one reading per point, none twice, the
    // pause taken out.
    expect(run.hr).toHaveLength(67);
    expect(run.hr[45]!.t).toBe(450);
    expect(run.hr[46]!.t).toBe(450);
    expect(run.hr[66]!.t).toBe(650);
  });
});

async function memberJwt(): Promise<{ id: string; jwt: string }> {
  // The owner row comes first, so the test's intervals.icu credential stays
  // the owner's and these members have no connection.
  const dev = await SELF.fetch(`${BASE}/auth/dev`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ secret: 'test-dev' }),
  });
  expect(dev.status).toBe(200);
  const id = crypto.randomUUID();
  await env.DB.prepare('INSERT INTO users (id,apple_sub,created_at) VALUES (?1,?1,?2)').bind(id, Date.now()).run();
  return { id, jwt: await issueAppJwt(id, 'test-secret') };
}

async function post(jwt: string, fields: Record<string, string>) {
  const form = new FormData();
  for (const [k, v] of Object.entries(fields)) form.append(k, v);
  form.append('file', new Blob([lappedTcx()]), `${fields.id}.tcx`);
  const r = await SELF.fetch(`${BASE}/api/activities/recordings`, {
    method: 'POST', headers: { Authorization: `Bearer ${jwt}` }, body: form,
  });
  return { status: r.status, body: await r.json<any>() };
}

async function route(jwt: string, activityId: string) {
  const r = await SELF.fetch(`${BASE}/api/activities/${encodeURIComponent(activityId)}/route`, {
    headers: { Authorization: `Bearer ${jwt}` },
  });
  return { status: r.status, body: await r.json<any>() };
}

const lapCount = async (activityId: string) => (await env.DB
  .prepare('SELECT COUNT(*) AS n FROM activity_laps WHERE activity_id = ?1')
  .bind(activityId).first<{ n: number }>())!.n;

describe('laps of a recorded planned run', () => {
  it('keeps the laps with the recording and serves them with its route, to its member only', async () => {
    const member = await memberJwt();
    const id = crypto.randomUUID();
    const res = await post(member.jwt, { id, date: DATE, laps: JSON.stringify(LAPS) });
    expect(res.status).toBe(201);
    const activityId = `recording:activity:${member.id}:${id}`;
    const served = await route(member.jwt, activityId);
    expect(served.status).toBe(200);
    expect(served.body.laps).toEqual(parseRunLaps(LAPS));
    expect(served.body.laps.map((lap: RunLap) => lap.end)).toEqual(['completed', 'completed', 'stopped']);
    // The route runs straight across the step boundaries.
    expect(decodeRoute(served.body.route).map((s) => s.length)).toEqual([46, 21]);
    // The run's own figures are the file's, laps or not.
    const row = await env.DB.prepare('SELECT moving_time_sec, distance_m FROM external_activities WHERE id = ?1')
      .bind(activityId).first();
    expect(row).toEqual({ moving_time_sec: 650, distance_m: 1600 });

    const stranger = await memberJwt();
    expect((await route(stranger.jwt, activityId)).status).toBe(404);

    // A retry never replaces kept laps.
    const changed = [{ ...LAPS[0]!, avg_hr: 100 }];
    expect((await post(member.jwt, { id, date: DATE, laps: JSON.stringify(changed) })).status).toBe(200);
    expect((await route(member.jwt, activityId)).body.laps[0].avg_hr).toBe(132);

    // The export carries them.
    const exported = await SELF.fetch(`${BASE}/api/me/export`, { headers: { Authorization: `Bearer ${member.jwt}` } });
    const training = (await exported.json<any>()).training;
    const kept = training.activity_laps.find((x: any) => x.activity_id === activityId);
    expect(kept).toMatchObject({ lap_count: 3 });
    expect(kept.laps).toEqual(parseRunLaps(LAPS));
  });

  it('fills laps a first attempt without them left out, and has none for a run without a plan', async () => {
    const member = await memberJwt();
    const id = crypto.randomUUID();
    const activityId = `recording:activity:${member.id}:${id}`;
    expect((await post(member.jwt, { id, date: DATE })).status).toBe(201);
    expect((await route(member.jwt, activityId)).body.laps).toBeNull();
    expect(await lapCount(activityId)).toBe(0);
    expect((await post(member.jwt, { id, date: DATE, laps: JSON.stringify(LAPS) })).status).toBe(200);
    expect((await route(member.jwt, activityId)).body.laps).toHaveLength(3);
  });

  it('refuses malformed laps before keeping anything', async () => {
    const member = await memberJwt();
    for (const laps of ['[', '[]', JSON.stringify([{ ...LAPS[0], kind: 'sprint' }]), 'x'.repeat(140_000)]) {
      const id = crypto.randomUUID();
      expect(await post(member.jwt, { id, date: DATE, laps })).toEqual({ status: 400, body: { error: 'invalid_laps' } });
      const kept = await env.DB.prepare('SELECT COUNT(*) AS n FROM external_activities WHERE external_id = ?1')
        .bind(id).first<{ n: number }>();
      expect(kept!.n).toBe(0);
    }
  });

  it('removes the laps with the recording, and with the account', async () => {
    const member = await memberJwt();
    const id = crypto.randomUUID();
    const activityId = `recording:activity:${member.id}:${id}`;
    expect((await post(member.jwt, { id, date: DATE, laps: JSON.stringify(LAPS) })).status).toBe(201);
    expect(await lapCount(activityId)).toBe(1);
    const deleted = await SELF.fetch(`${BASE}/api/activities/recordings/${id}`, {
      method: 'DELETE', headers: { Authorization: `Bearer ${member.jwt}` },
    });
    expect(deleted.status).toBe(200);
    expect(await lapCount(activityId)).toBe(0);
    // The phone's retry can't bring them back.
    expect((await post(member.jwt, { id, date: DATE, laps: JSON.stringify(LAPS) })).body).toMatchObject({ deleted: true });
    expect(await lapCount(activityId)).toBe(0);
  });
});
