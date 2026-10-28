// log_activity's endurance route: run/ride/swim/walk sessions are created on
// intervals.icu (never the local activities table), with type mapping, unit
// and pace conversion, duplicate detection and a clear failure path. Local
// types keep writing the activities table, now with optional metrics.
// delete_activity soft-deletes local rows and deletes Tres Fort-created
// intervals.icu activities by external_id. No real network: fetchMock.
import { env, applyD1Migrations, fetchMock, SELF } from 'cloudflare:test';
import { afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import {
  clockInTz,
  enduranceAlias,
  intervalsTypeFor,
  parseActivityMetrics,
  parsePaceSeconds,
} from '../src/enduranceActivity';
import { getUserIntervalsCreds, logEnduranceActivity } from '../src/db';

const BASE = 'https://tres-fort.test';
const TOKEN = 'test-mcp-token';
const ORIGIN = 'https://intervals.icu';
const ATHLETE = 'i12345';
const DATE = '2026-10-27';
const BACKFILL_ID = '3f0c1d2e-4b5a-4c6d-8e7f-9a0b1c2d3e4f';
const BACKFILL_EXT = `tresfort:activity:${BACKFILL_ID}`;

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
    return { raw: text };
  }
}

async function ownerId(): Promise<string> {
  await call('get_coach_brief', {});
  const row = await env.DB.prepare('SELECT id FROM users ORDER BY created_at LIMIT 1').first<{ id: string }>();
  return row!.id;
}

async function localCount(): Promise<number> {
  return (await env.DB.prepare('SELECT COUNT(*) AS c FROM activities').first<{ c: number }>())!.c;
}

const activitiesPath = (pred: (q: URLSearchParams) => boolean) => (path: string) => {
  const u = new URL(path, ORIGIN);
  return u.pathname === `/api/v1/athlete/${ATHLETE}/activities` && pred(u.searchParams);
};
/** The duplicate check asks for exactly the activity's date. */
const dayLookup = (date: string) => activitiesPath((q) => q.get('oldest') === date && q.get('newest') === date);
/** The post-write refresh asks for the 90-day window. */
const refreshWindow = activitiesPath((q) => q.get('oldest') !== q.get('newest'));

function created(body: any, id = 'i900') {
  return {
    id,
    type: body.type,
    name: body.name,
    start_date_local: body.start_date_local,
    start_date: `${body.start_date_local}Z`,
    moving_time: body.moving_time,
    elapsed_time: body.elapsed_time,
    distance: body.distance ?? null,
    external_id: body.external_id,
  };
}

describe('endurance type mapping and unit math (pure)', () => {
  it.each([
    ['run', 'Run', false],
    ['Jog', 'Run', false],
    ['treadmill', 'Run', true],
    ['Treadmill-Run', 'Run', true],
    ['ride', 'Ride', false],
    ['cycling', 'Ride', false],
    ['spin', 'VirtualRide', true],
    ['indoor ride', 'VirtualRide', true],
    ['swim', 'Swim', false],
    ['walk', 'Walk', false],
    ['treadmill walk', 'Walk', true],
  ])('%s maps to %s (trainer=%s)', (type, intervalsType, trainer) => {
    const alias = enduranceAlias(type);
    expect(alias).not.toBeNull();
    expect(intervalsTypeFor(alias!)).toMatchObject({ type: intervalsType, trainer });
  });

  it('lets indoor override the alias default', () => {
    expect(intervalsTypeFor(enduranceAlias('ride')!, true)).toMatchObject({ type: 'VirtualRide', trainer: true });
    expect(intervalsTypeFor(enduranceAlias('run')!, true)).toMatchObject({ type: 'Run', trainer: true });
    expect(intervalsTypeFor(enduranceAlias('treadmill')!, false)).toMatchObject({ type: 'Run', trainer: false });
    // A pool is indoors, but trainer is never set on a swim.
    expect(intervalsTypeFor(enduranceAlias('swim')!, true)).toMatchObject({ type: 'Swim', trainer: false });
  });

  it.each(['pilates', 'yoga', 'jump rope', 'other', 'hiit'])('%s stays local', (type) => {
    expect(enduranceAlias(type)).toBeNull();
  });

  it('converts distance units to meters', () => {
    const m = (distance: number, distance_unit: string) =>
      (parseActivityMetrics({ distance, distance_unit, duration_s: 60 }) as any).metrics.distance_m;
    expect(m(3.01, 'mi')).toBeCloseTo(4844.1, 1);
    expect(m(5, 'km')).toBe(5000);
    expect(m(400, 'm')).toBe(400);
  });

  it('prefers duration_s over duration_minutes', () => {
    const r = parseActivityMetrics({ duration_s: 1447, duration_minutes: 24 }) as any;
    expect(r.metrics.duration_s).toBe(1447);
    expect((parseActivityMetrics({ duration_minutes: 24 }) as any).metrics.duration_s).toBe(1440);
  });

  it('derives distance from pace and duration (24:07 at 8:00 min/mi is ~3.01 mi)', () => {
    const r = parseActivityMetrics({ duration_s: 1447, pace: '8:00', pace_unit: 'min/mi' }) as any;
    expect(r.metrics.derived).toEqual(['distance_from_pace']);
    expect(r.metrics.distance_m / 1609.344).toBeCloseTo(3.01, 2);
    const km = parseActivityMetrics({ duration_s: 1500, pace: '5:00', pace_unit: 'min/km' }) as any;
    expect(km.metrics.distance_m).toBe(5000);
  });

  it('derives duration from pace and distance, and never overrides a supplied distance', () => {
    const r = parseActivityMetrics({ distance: 5, distance_unit: 'km', pace: '5:30', pace_unit: 'min/km' }) as any;
    expect(r.metrics).toMatchObject({ duration_s: 1650, distance_m: 5000, derived: ['duration_from_pace'] });
    const both = parseActivityMetrics({
      duration_s: 1447, distance: 3, distance_unit: 'mi', pace: '8:00', pace_unit: 'min/mi',
    }) as any;
    expect(both.metrics.distance_m).toBeCloseTo(4828.0, 1);
    expect(both.metrics.derived).toEqual([]);
  });

  it('parses pace strings and minutes, and rejects bad inputs', () => {
    expect(parsePaceSeconds('8:00')).toBe(480);
    expect(parsePaceSeconds('10:05')).toBe(605);
    expect(parsePaceSeconds(8.5)).toBe(510);
    expect(parsePaceSeconds('8:75')).toBeNull();
    expect(parsePaceSeconds('fast')).toBeNull();
    expect(parseActivityMetrics({ distance: 3 })).toEqual({ invalid: ['distance_unit'] });
    expect(parseActivityMetrics({ pace: '8:00' })).toEqual({ invalid: ['pace_unit'] });
    expect(parseActivityMetrics({ avg_hr: 400, start_time: '25:00', indoor: 'yes' })).toEqual({
      invalid: ['avg_hr', 'indoor', 'start_time'],
    });
  });

  it('reads the wall clock in the member timezone', () => {
    const at = new Date('2026-10-28T02:15:00Z');
    expect(clockInTz('America/Los_Angeles', at)).toBe('19:15');
    expect(clockInTz(null, at)).toBe('02:15');
    expect(clockInTz('Not/AZone', at)).toBe('02:15');
  });
});

describe('MCP log_activity endurance route', () => {
  beforeEach(() => {
    fetchMock.activate();
    fetchMock.disableNetConnect();
  });
  afterEach(() => {
    fetchMock.deactivate();
    fetchMock.enableNetConnect();
  });

  it('creates a treadmill run on intervals.icu with every mapped field and writes nothing locally', async () => {
    await ownerId();
    const before = await localCount();
    const provider = fetchMock.get(ORIGIN);
    provider.intercept({ method: 'GET', path: dayLookup(DATE) }).reply(200, []);
    let sent: any = null;
    provider
      .intercept({ method: 'POST', path: `/api/v1/athlete/${ATHLETE}/activities/manual` })
      .reply(200, (opts) => {
        sent = JSON.parse(String(opts.body));
        return created(sent);
      });
    provider.intercept({ method: 'GET', path: refreshWindow }).reply(200, []);

    const res = await call('log_activity', {
      type: 'treadmill',
      date: DATE,
      start_time: '7:30',
      duration_s: 1447,
      pace: '8:00',
      pace_unit: 'min/mi',
      avg_hr: 151,
      calories: 347,
      notes: 'Easy effort',
      activity_id: BACKFILL_ID,
    });

    expect(res).toMatchObject({
      ok: true,
      destination: 'intervals.icu',
      deduplicated: false,
      activity_id: BACKFILL_ID,
      derived: ['distance_from_pace'],
      refresh: { status: 'ok' },
    });
    expect(res.message).toBe('Logged 24:07 Treadmill Run (3.01 mi) on 2026-10-27 to intervals.icu');
    expect(sent).toMatchObject({
      name: 'Treadmill Run',
      type: 'Run',
      trainer: true,
      start_date_local: '2026-10-27T07:30:00',
      moving_time: 1447,
      elapsed_time: 1447,
      average_heartrate: 151,
      calories: 347,
      description: 'Easy effort',
      external_id: BACKFILL_EXT,
    });
    expect(sent.distance / 1609.344).toBeCloseTo(3.01, 2);
    fetchMock.assertNoPendingInterceptors();
    expect(await localCount()).toBe(before);
    const audit = await env.DB
      .prepare("SELECT COUNT(*) AS c FROM audit_log WHERE tool='log_activity'")
      .first<{ c: number }>();
    expect(audit!.c).toBe(1);
  });

  it('maps an outdoor ride with km distance and omits fields that were not given', async () => {
    await ownerId();
    const provider = fetchMock.get(ORIGIN);
    provider.intercept({ method: 'GET', path: dayLookup(DATE) }).reply(200, []);
    let sent: any = null;
    provider
      .intercept({ method: 'POST', path: `/api/v1/athlete/${ATHLETE}/activities/manual` })
      .reply(200, (opts) => {
        sent = JSON.parse(String(opts.body));
        return created(sent);
      });
    provider.intercept({ method: 'GET', path: refreshWindow }).reply(200, []);
    const res = await call('log_activity', {
      type: 'Bike', title: 'Coffee ride', date: DATE, start_time: '09:05', duration_minutes: 75, distance: 32.5, distance_unit: 'km',
    });
    expect(res.ok).toBe(true);
    expect(sent).toEqual({
      name: 'Coffee ride',
      type: 'Ride',
      start_date_local: '2026-10-27T09:05:00',
      moving_time: 4500,
      elapsed_time: 4500,
      distance: 32500,
      trainer: false,
      external_id: `tresfort:activity:${res.activity_id}`,
    });
  });

  it('returns an existing same-day activity of the same sport within a minute instead of creating one', async () => {
    await ownerId();
    fetchMock.get(ORIGIN).intercept({ method: 'GET', path: dayLookup(DATE) }).reply(200, [
      { id: 'i700', type: 'Ride', start_date_local: `${DATE}T06:00:00`, moving_time: 1440 },
      { id: 'i701', type: 'VirtualRun', start_date_local: `${DATE}T18:00:00`, moving_time: 1480, external_id: 'garmin-1' },
    ]);
    fetchMock.get(ORIGIN).intercept({ method: 'GET', path: refreshWindow }).reply(200, []);
    // No POST interceptor: a create would fail closed under disableNetConnect.
    const res = await call('log_activity', { type: 'treadmill', date: DATE, duration_s: 1447, start_time: '18:00' });
    // A watch import is reported, but it is not ours to delete.
    expect(res).toMatchObject({
      ok: true, deduplicated: true, activity_id: null, intervals_activity: { id: 'i701' }, refresh: { status: 'ok' },
    });
    expect(res.message).toMatch(/^Already on intervals.icu/);
    fetchMock.assertNoPendingInterceptors();
    // Audited, but no coach note for a no-op.
    const note = await env.DB.prepare("SELECT COUNT(*) AS c FROM notes WHERE body LIKE 'Logged activity:%'").first<{ c: number }>();
    expect(note!.c).toBe(0);
  });

  it('returns the activity already created with the same activity_id', async () => {
    await ownerId();
    fetchMock.get(ORIGIN).intercept({ method: 'GET', path: dayLookup(DATE) }).reply(200, [
      { id: 'i702', type: 'Run', start_date_local: `${DATE}T07:30:00`, moving_time: 3000, external_id: BACKFILL_EXT },
    ]);
    // The retry still reconciles the cache around the matched activity's date.
    let oldest: string | null = null;
    fetchMock.get(ORIGIN).intercept({ method: 'GET', path: refreshWindow }).reply(200, (opts) => {
      oldest = new URL(String(opts.path), ORIGIN).searchParams.get('oldest');
      return [];
    });
    const res = await call('log_activity', { type: 'run', date: DATE, duration_s: 1447, activity_id: BACKFILL_ID });
    expect(res).toMatchObject({
      ok: true, deduplicated: true, activity_id: BACKFILL_ID, intervals_activity: { id: 'i702' }, refresh: { status: 'ok' },
    });
    expect(oldest! <= DATE).toBe(true);
    fetchMock.assertNoPendingInterceptors();
  });

  it('does not treat a different sport or a longer session as a duplicate', async () => {
    await ownerId();
    const provider = fetchMock.get(ORIGIN);
    provider.intercept({ method: 'GET', path: dayLookup(DATE) }).reply(200, [
      { id: 'i703', type: 'Ride', start_date_local: `${DATE}T07:00:00`, moving_time: 1447 },
      { id: 'i704', type: 'Run', start_date_local: `${DATE}T07:00:00`, moving_time: 1447 + 61 },
    ]);
    provider
      .intercept({ method: 'POST', path: `/api/v1/athlete/${ATHLETE}/activities/manual` })
      .reply(200, (opts) => created(JSON.parse(String(opts.body))));
    provider.intercept({ method: 'GET', path: refreshWindow }).reply(200, []);
    const res = await call('log_activity', { type: 'run', date: DATE, duration_s: 1447 });
    expect(res).toMatchObject({ ok: true, deduplicated: false });
  });

  it.each([
    [500, 'intervals_unavailable'],
    [422, 'intervals_rejected'],
  ])('reports a provider %i as %s and never falls back to the local table', async (status, error) => {
    await ownerId();
    const before = await localCount();
    const provider = fetchMock.get(ORIGIN);
    provider.intercept({ method: 'GET', path: dayLookup(DATE) }).reply(200, []);
    provider
      .intercept({ method: 'POST', path: `/api/v1/athlete/${ATHLETE}/activities/manual` })
      .reply(status, { error: 'synthetic failure' });
    const res = await call('log_activity', { type: 'swim', date: DATE, duration_minutes: 40 });
    expect(res).toMatchObject({ error, status });
    expect(res.message).toMatch(/Nothing was/);
    expect(await localCount()).toBe(before);
    const note = await env.DB.prepare("SELECT COUNT(*) AS c FROM notes WHERE body LIKE 'Logged activity:%'").first<{ c: number }>();
    expect(note!.c).toBe(0);
  });

  it('reports a write rejection without disconnecting the read credential', async () => {
    const userId = await ownerId();
    const provider = fetchMock.get(ORIGIN);
    provider.intercept({ method: 'GET', path: dayLookup(DATE) }).reply(200, []);
    provider
      .intercept({ method: 'POST', path: `/api/v1/athlete/${ATHLETE}/activities/manual` })
      .reply(403, { error: 'insufficient scope' });
    const res = await call('log_activity', { type: 'walk', date: DATE, duration_minutes: 30 });
    expect(res).toMatchObject({ error: 'intervals_write_forbidden', status: 403 });
    expect(res.message).toMatch(/Reconnect intervals.icu/);
    const creds = await getUserIntervalsCreds(env.DB, userId);
    expect(creds.athlete_id).toBe(ATHLETE);
    expect(creds.api_key).not.toBeNull();
  });

  it('fails when the duplicate check cannot reach intervals.icu, without creating anything', async () => {
    await ownerId();
    fetchMock.get(ORIGIN).intercept({ method: 'GET', path: dayLookup(DATE) }).reply(503, {});
    const res = await call('log_activity', { type: 'run', date: DATE, duration_minutes: 30 });
    expect(res).toMatchObject({ error: 'intervals_unavailable', status: 503 });
  });

  it('requires a duration for endurance and validates fields', async () => {
    expect(await call('log_activity', { type: 'run', distance: 3, distance_unit: 'mi' })).toMatchObject({
      error: 'duration_required',
    });
    expect(await call('log_activity', { type: 'run', duration_s: 60, date: '10/27/2026', pace: 'quick', pace_unit: 'min/mi' }))
      .toEqual({ error: 'invalid_fields', fields: ['date', 'pace'] });
  });

  it('tells a member without an intervals.icu connection that nothing was saved', async () => {
    await ownerId();
    const id = crypto.randomUUID();
    await env.DB.prepare('INSERT INTO users (id,apple_sub,created_at) VALUES (?1,?1,?2)').bind(id, Date.now()).run();
    const res = await logEnduranceActivity(env.DB, env, id, {
      activity_id: crypto.randomUUID(),
      date: DATE,
      start_time: '07:00',
      mapping: intervalsTypeFor(enduranceAlias('run')!),
      name: 'Run',
      duration_s: 1800,
      distance_m: null,
      avg_hr: null,
      calories: null,
      notes: null,
    });
    expect(res).toMatchObject({ error: 'intervals_not_connected' });
  });
});

describe('MCP log_activity local route', () => {
  it('keeps non-endurance types local with the new optional metrics', async () => {
    const res = await call('log_activity', {
      type: 'Jump Rope', date: DATE, duration_s: 610, avg_hr: 160, calories: 120.4, distance: 1, distance_unit: 'mi',
    });
    expect(res).toMatchObject({
      ok: true,
      destination: 'local',
      ignored_fields: ['distance', 'distance_unit'],
      activity: { type: 'jump rope', duration_s: 610, duration_minutes: 10, avg_hr: 160, calories: 120, source: 'mcp' },
    });
    expect(res.message).toBe('Logged 10:10 jump rope on 2026-10-27');
  });

  it('is idempotent on activity_id', async () => {
    const id = crypto.randomUUID();
    const first = await call('log_activity', { type: 'yoga', date: DATE, duration_minutes: 30, activity_id: id });
    const second = await call('log_activity', { type: 'yoga', date: DATE, duration_minutes: 45, activity_id: id });
    expect(second.activity).toEqual(first.activity);
    const rows = await env.DB.prepare('SELECT COUNT(*) AS c FROM activities WHERE id=?1').bind(id).first<{ c: number }>();
    expect(rows!.c).toBe(1);
  });
});

describe('MCP delete_activity', () => {
  beforeEach(() => {
    fetchMock.activate();
    fetchMock.disableNetConnect();
  });
  afterEach(() => {
    fetchMock.deactivate();
    fetchMock.enableNetConnect();
  });

  it('soft-deletes a local activity', async () => {
    const logged = await call('log_activity', { type: 'pilates', date: DATE, duration_minutes: 50 });
    const res = await call('delete_activity', { id: logged.activity.id });
    expect(res).toEqual({ ok: true, destination: 'local', id: logged.activity.id });
    const row = await env.DB.prepare('SELECT deleted_at FROM activities WHERE id=?1').bind(logged.activity.id).first<any>();
    expect(row.deleted_at).not.toBeNull();
  });

  it('deletes the Tres Fort-created intervals.icu activity matched by external_id', async () => {
    await ownerId();
    const provider = fetchMock.get(ORIGIN);
    provider.intercept({ method: 'GET', path: dayLookup(DATE) }).reply(200, [
      { id: 'i800', type: 'Run', start_date_local: `${DATE}T07:30:00`, external_id: 'someone-else' },
      { id: 'i801', type: 'Run', start_date_local: `${DATE}T07:30:00`, external_id: BACKFILL_EXT },
    ]);
    provider.intercept({ method: 'DELETE', path: '/api/v1/activity/i801' }).reply(200, {});
    provider.intercept({ method: 'GET', path: refreshWindow }).reply(200, []);
    const res = await call('delete_activity', { id: BACKFILL_ID, date: DATE });
    expect(res).toMatchObject({
      ok: true, destination: 'intervals.icu', activity_id: BACKFILL_ID, intervals_activity_id: 'i801',
    });
    fetchMock.assertNoPendingInterceptors();
  });

  it('uses the synced cache to find the provider id and refreshes a window containing its date', async () => {
    const userId = await ownerId();
    // Older than the default 90-day sync window.
    const old = new Date(Date.now() - 200 * 86_400_000).toISOString().slice(0, 10);
    await env.DB.prepare(
      `INSERT INTO external_activities (id,user_id,source,external_id,date,kind,raw,synced_at)
       VALUES (?1,?2,'intervals','i802',?3,'run',?4,1)`,
    ).bind(`intervals:${userId}:i802`, userId, old, JSON.stringify({ id: 'i802', external_id: BACKFILL_EXT })).run();
    const provider = fetchMock.get(ORIGIN);
    provider.intercept({ method: 'DELETE', path: '/api/v1/activity/i802' }).reply(204, '');
    let oldest: string | null = null;
    provider
      .intercept({ method: 'GET', path: refreshWindow })
      .reply(200, (opts) => {
        oldest = new URL(String(opts.path), ORIGIN).searchParams.get('oldest');
        return [];
      });
    // The prefixed external_id is accepted as well as the bare id.
    const res = await call('delete_activity', { id: BACKFILL_EXT });
    expect(res).toMatchObject({ ok: true, activity_id: BACKFILL_ID, intervals_activity_id: 'i802', refresh: { status: 'ok' } });
    fetchMock.assertNoPendingInterceptors();
    expect(oldest! <= old).toBe(true);
    const row = await env.DB.prepare('SELECT deleted_at FROM external_activities WHERE id=?1')
      .bind(`intervals:${userId}:i802`).first<any>();
    expect(row.deleted_at).not.toBeNull();
  });

  it('reconciles the cache when a repeated delete finds the activity already gone', async () => {
    const userId = await ownerId();
    const old = new Date(Date.now() - 200 * 86_400_000).toISOString().slice(0, 10);
    await env.DB.prepare(
      `INSERT INTO external_activities (id,user_id,source,external_id,date,kind,raw,synced_at)
       VALUES (?1,?2,'intervals','i804',?3,'run',?4,1)`,
    ).bind(`intervals:${userId}:i804`, userId, old, JSON.stringify({ id: 'i804', external_id: BACKFILL_EXT })).run();
    const provider = fetchMock.get(ORIGIN);
    provider.intercept({ method: 'DELETE', path: '/api/v1/activity/i804' }).reply(404, { error: 'Not found' });
    provider.intercept({ method: 'GET', path: refreshWindow }).reply(200, []);
    const res = await call('delete_activity', { id: BACKFILL_ID });
    expect(res).toMatchObject({ ok: true, already_deleted: true, intervals_activity_id: 'i804', refresh: { status: 'ok' } });
    fetchMock.assertNoPendingInterceptors();
    const row = await env.DB.prepare('SELECT deleted_at FROM external_activities WHERE id=?1')
      .bind(`intervals:${userId}:i804`).first<any>();
    expect(row.deleted_at).not.toBeNull();
  });

  it.each(['i803', 'garmin-2'])('never deletes a provider activity Tres Fort did not create (id %s)', async (id) => {
    const userId = await ownerId();
    // Even an exact external_id match in the cache is not enough without the marker.
    await env.DB.prepare(
      `INSERT INTO external_activities (id,user_id,source,external_id,date,kind,raw,synced_at)
       VALUES (?1,?2,'intervals','i803',?3,'run',?4,1)`,
    ).bind(`intervals:${userId}:i803`, userId, DATE, JSON.stringify({ id: 'i803', external_id: 'garmin-2' })).run();
    fetchMock.get(ORIGIN).intercept({ method: 'GET', path: dayLookup(DATE) }).reply(200, [
      { id: 'i803', type: 'Run', start_date_local: `${DATE}T07:30:00`, external_id: 'garmin-2' },
    ]);
    const res = await call('delete_activity', { id, date: DATE });
    expect(res).toMatchObject({ error: 'not_found' });
  });
});
