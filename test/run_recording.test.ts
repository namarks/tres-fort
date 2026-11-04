// POST /api/activities/recordings: Tres Fort keeps a run recorded in the app,
// with its GPS route (docs/plans/run-recorder P5), and uploads the file to
// intervals.icu when the member has a connection (P0). Retries are idempotent
// on the recording id; a provider failure keeps its error and says the run
// is stored. No real network: fetchMock.
import { env, applyD1Migrations, fetchMock, SELF } from 'cloudflare:test';
import { afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { dedupeHealthKitAgainstIntervals, getUserIntervalsCreds, recordingFormat } from '../src/db';
import { decodeRoute } from '../src/activityRoute';
import { issueAppJwt } from '../src/auth';

const BASE = 'https://tres-fort.test';
const ORIGIN = 'https://intervals.icu';
const ATHLETE = 'i12345';
const DATE = '2026-10-27';
const UPLOAD_PATH = `/api/v1/athlete/${ATHLETE}/activities`;

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

/** A minimal FIT header: 14 bytes with ".FIT" at offset 8. */
function fitBytes(extra = 64): Uint8Array {
  const b = new Uint8Array(14 + extra);
  b.set([14, 0x20, 0x5c, 0x08], 0);
  b.set([...'.FIT'].map((ch) => ch.charCodeAt(0)), 8);
  return b;
}

const GPX = '<?xml version="1.0"?><gpx version="1.1" creator="Tres Fort"><trk><trkseg></trkseg></trk></gpx>';

const START_MS = Date.parse('2026-10-27T14:00:00Z');

/** A run as the app's RecordedRunTCX writes it: two tracks of 60 points five
 * seconds apart, split by a two-minute pause, heart rate 150 throughout. */
function tcxRun(opts: { sport?: string; startMs?: number; tracks?: number } = {}): string {
  const start = opts.startMs ?? START_MS;
  const iso = (ms: number) => new Date(ms).toISOString().replace('.000Z', 'Z');
  let xml = `<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
  <Activities>
    <Activity Sport="${opts.sport ?? 'Running'}">
      <Id>${iso(start)}</Id>
      <Lap StartTime="${iso(start)}">
        <TotalTimeSeconds>600.0</TotalTimeSeconds>
        <DistanceMeters>1600.0</DistanceMeters>
        <Calories>0</Calories>
        <Intensity>Active</Intensity>
        <TriggerMethod>Manual</TriggerMethod>
`;
  let distance = 0;
  for (let track = 0; track < (opts.tracks ?? 2); track++) {
    xml += '        <Track>\n';
    const trackStart = start + track * 420_000;
    for (let i = 0; i < 60; i++) {
      const step = track * 60 + i;
      xml += `          <Trackpoint><Time>${iso(trackStart + i * 5_000)}</Time>`
        + `<Position><LatitudeDegrees>${(45.519 + step * 0.0001).toFixed(7)}</LatitudeDegrees>`
        + `<LongitudeDegrees>-122.6793000</LongitudeDegrees></Position>`
        + `<AltitudeMeters>${(15 + step * 0.1).toFixed(1)}</AltitudeMeters>`
        + `<DistanceMeters>${distance.toFixed(1)}</DistanceMeters>`
        + `<HeartRateBpm><Value>150</Value></HeartRateBpm></Trackpoint>\n`;
      distance += 13.3;
    }
    xml += '        </Track>\n';
  }
  return xml + '      </Lap>\n    </Activity>\n  </Activities>\n</TrainingCenterDatabase>\n';
}

const tcxFile = (id: string, text = tcxRun()) => ({ bytes: text, name: `${id}.tcx` });

async function memberJwt(): Promise<{ id: string; jwt: string }> {
  await devJwt(); // The owner row exists, so the env credential stays the owner's.
  const id = crypto.randomUUID();
  await env.DB.prepare('INSERT INTO users (id,apple_sub,created_at) VALUES (?1,?1,?2)').bind(id, Date.now()).run();
  return { id, jwt: await issueAppJwt(id, 'test-secret') };
}

async function ownerId(): Promise<string> {
  const owner = await env.DB.prepare('SELECT id FROM users ORDER BY created_at LIMIT 1').first<{ id: string }>();
  return owner!.id;
}

async function route(jwt: string, activityId: string) {
  const r = await SELF.fetch(`${BASE}/api/activities/${encodeURIComponent(activityId)}/route`, {
    headers: { Authorization: `Bearer ${jwt}` },
  });
  return { status: r.status, body: await r.json<any>() };
}

function recordingForm(fields: Record<string, string>, file?: { bytes: Uint8Array | string; name: string }): FormData {
  const form = new FormData();
  for (const [k, v] of Object.entries(fields)) form.append(k, v);
  if (file) form.append('file', new Blob([file.bytes]), file.name);
  return form;
}

async function post(jwt: string | null, form: FormData) {
  const r = await SELF.fetch(`${BASE}/api/activities/recordings`, {
    method: 'POST',
    headers: jwt ? { Authorization: `Bearer ${jwt}` } : {},
    body: form,
  });
  return { status: r.status, body: await r.json<any>() };
}

const query = (path: string) => new URL(path, ORIGIN).searchParams;
/** The earlier-upload check asks for a day either side of the run. */
const lookup = (path: string) => {
  const u = new URL(path, ORIGIN);
  return u.pathname === UPLOAD_PATH && u.searchParams.get('oldest') === '2026-10-26'
    && u.searchParams.get('newest') === '2026-10-28';
};
/** The post-upload refresh asks for a wider window. */
const refreshWindow = (path: string) => {
  const u = new URL(path, ORIGIN);
  return u.pathname === UPLOAD_PATH && u.searchParams.has('oldest') && !lookup(path);
};
const upload = (path: string) => {
  const u = new URL(path, ORIGIN);
  return u.pathname === UPLOAD_PATH && u.searchParams.has('external_id');
};

describe('recorded run file format', () => {
  it('accepts FIT, GPX and TCX only when the content matches the extension', () => {
    const enc = (s: string) => new TextEncoder().encode(s);
    expect(recordingFormat('run.fit', fitBytes())).toBe('fit');
    expect(recordingFormat('RUN.FIT', fitBytes())).toBe('fit');
    expect(recordingFormat('run.gpx', enc(GPX))).toBe('gpx');
    expect(recordingFormat('run.tcx', enc('<?xml version="1.0"?><TrainingCenterDatabase>'))).toBe('tcx');
    expect(recordingFormat('run.fit', enc(GPX))).toBeNull();
    expect(recordingFormat('run.gpx', fitBytes())).toBeNull();
    expect(recordingFormat('run.csv', enc('a,b'))).toBeNull();
    expect(recordingFormat('run', fitBytes())).toBeNull();
  });
});

describe('POST /api/activities/recordings', () => {
  beforeEach(() => {
    fetchMock.activate();
    fetchMock.disableNetConnect();
  });
  afterEach(() => {
    fetchMock.deactivate();
    fetchMock.enableNetConnect();
  });

  it('keeps the run and its route, then uploads the file to intervals.icu', async () => {
    const jwt = await devJwt();
    const owner = await ownerId();
    const id = crypto.randomUUID();
    const provider = fetchMock.get(ORIGIN);
    provider.intercept({ method: 'GET', path: lookup }).reply(200, []);
    let sentPath = '';
    let sentBody = '';
    provider.intercept({ method: 'POST', path: upload }).reply(201, (opts) => {
      sentPath = String(opts.path);
      sentBody = String(opts.body);
      return { icu_athlete_id: ATHLETE, id: 'i950', activities: [{ icu_athlete_id: ATHLETE, id: 'i950' }] };
    });
    provider.intercept({ method: 'GET', path: refreshWindow }).reply(200, []);

    const res = await post(jwt, recordingForm({ id, date: DATE, name: ' Morning Run ' }, tcxFile(id)));

    const activityId = `recording:activity:${owner}:${id}`;
    expect(res.status).toBe(201);
    expect(res.body).toEqual({
      ok: true,
      destination: 'tres-fort',
      deduplicated: false,
      recording_id: id,
      activity_id: activityId,
      intervals_activity_id: 'i950',
      intervals: { status: 'uploaded', deduplicated: false, activity_id: 'i950' },
      refresh: { status: 'ok', synced: 0 },
    });
    expect(query(sentPath).get('external_id')).toBe(`tresfort:recording:${id}`);
    expect(query(sentPath).get('name')).toBe('Morning Run');
    expect(sentBody).toContain(`filename="${id}.tcx"`);
    fetchMock.assertNoPendingInterceptors();

    const row = await env.DB.prepare('SELECT * FROM external_activities WHERE id = ?1').bind(activityId).first<any>();
    expect(row).toMatchObject({
      user_id: owner, source: 'recording', external_id: id, date: DATE, kind: 'run', name: 'Morning Run',
      moving_time_sec: 600, elapsed_time_sec: 715, distance_m: 1600, average_hr: 150, max_hr: 150,
      calories: null, start_date_utc_ms: START_MS, deleted_at: null, canonical: 1,
    });
    // Heart rate on moving time: the two-minute pause is taken out.
    expect(row.stream_hr_rms).toBeCloseTo(150, 5);
    expect(row.stream_hr_sec).toBeGreaterThan(580);
    expect(row.stream_hr_sec).toBeLessThanOrEqual(600);

    const served = await route(jwt, activityId);
    expect(served.status).toBe(200);
    expect(served.body).toMatchObject({ activity_id: activityId, recording_id: id });
    const segments = decodeRoute(served.body.route);
    expect(segments.map((s) => s.length)).toEqual([60, 60]);
    expect(segments[0]![0]).toEqual({ t: START_MS, lat: 45.519, lon: -122.6793, alt: 15 });
    expect(segments[1]![0]!.t).toBe(START_MS + 420_000);
    expect(segments[1]![59]!.lat).toBeCloseTo(45.519 + 119 * 0.0001, 6);
  });

  it('finds the kept run and the earlier upload on a retry', async () => {
    const jwt = await devJwt();
    const id = crypto.randomUUID();
    const provider = fetchMock.get(ORIGIN);
    provider.intercept({ method: 'GET', path: lookup }).reply(200, []);
    provider.intercept({ method: 'POST', path: upload }).reply(201, { id: 'i955', activities: [{ id: 'i955' }] });
    provider.intercept({ method: 'GET', path: refreshWindow }).reply(200, []);
    expect((await post(jwt, recordingForm({ id, date: DATE }, tcxFile(id)))).status).toBe(201);

    provider.intercept({ method: 'GET', path: lookup }).reply(200, [
      { id: 'i960', type: 'Run', start_date_local: `${DATE}T07:00:00`, moving_time: 1800 },
      { id: 'i955', type: 'Run', start_date_local: '2026-10-27T07:00:00', moving_time: 600, external_id: `tresfort:recording:${id}` },
    ]);
    provider.intercept({ method: 'GET', path: refreshWindow }).reply(200, []);
    // No upload interceptor: an upload would fail closed under disableNetConnect.
    const res = await post(jwt, recordingForm({ id, date: DATE }, tcxFile(id)));
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({
      ok: true, deduplicated: true, recording_id: id, intervals_activity_id: 'i955',
      intervals: { status: 'uploaded', deduplicated: true },
    });
    const kept = await env.DB.prepare(`SELECT COUNT(*) AS n FROM external_activities WHERE source = 'recording' AND external_id = ?1`)
      .bind(id).first<{ n: number }>();
    expect(kept?.n).toBe(1);
    fetchMock.assertNoPendingInterceptors();
  });

  it('keeps the run for a member without an intervals.icu connection', async () => {
    const member = await memberJwt();
    const id = crypto.randomUUID();
    const res = await post(member.jwt, recordingForm({ id, date: DATE }, tcxFile(id)));
    const activityId = `recording:activity:${member.id}:${id}`;
    expect(res.status).toBe(201);
    expect(res.body).toEqual({
      ok: true, destination: 'tres-fort', deduplicated: false, recording_id: id, activity_id: activityId,
      intervals_activity_id: null, intervals: { status: 'not_connected' },
    });
    expect((await route(member.jwt, activityId)).status).toBe(200);
    const again = await post(member.jwt, recordingForm({ id, date: DATE }, tcxFile(id)));
    expect(again).toMatchObject({ status: 200, body: { deduplicated: true, intervals: { status: 'not_connected' } } });
  });

  it('keeps the run and reports a write rejection without disconnecting the read credential', async () => {
    const jwt = await devJwt();
    const id = crypto.randomUUID();
    const provider = fetchMock.get(ORIGIN);
    provider.intercept({ method: 'GET', path: lookup }).reply(200, []);
    provider.intercept({ method: 'POST', path: upload }).reply(403, { error: 'insufficient scope' });
    const res = await post(jwt, recordingForm({ id, date: DATE }, tcxFile(id)));
    expect(res.status).toBe(409);
    expect(res.body).toMatchObject({ error: 'intervals_write_forbidden', status: 403, stored: true, recording_id: id });
    const owner = await ownerId();
    const creds = await getUserIntervalsCreds(env.DB, owner);
    expect(creds.athlete_id).toBe(ATHLETE);
    expect(creds.api_key).not.toBeNull();
    const kept = await env.DB.prepare('SELECT deleted_at FROM external_activities WHERE id = ?1')
      .bind(`recording:activity:${owner}:${id}`).first<{ deleted_at: number | null }>();
    expect(kept).toEqual({ deleted_at: null });
  });

  it.each([
    [500, 502, 'intervals_unavailable'],
    [422, 422, 'intervals_rejected'],
  ])('maps a provider %i to HTTP %i %s with the run kept', async (providerStatus, status, error) => {
    const jwt = await devJwt();
    const id = crypto.randomUUID();
    const provider = fetchMock.get(ORIGIN);
    provider.intercept({ method: 'GET', path: lookup }).reply(200, []);
    provider.intercept({ method: 'POST', path: upload }).reply(providerStatus, { error: 'synthetic failure' });
    const res = await post(jwt, recordingForm({ id, date: DATE }, tcxFile(id)));
    expect(res.status).toBe(status);
    expect(res.body).toMatchObject({ error, status: providerStatus, stored: true });
  });

  it('keeps the run when the earlier-upload check cannot reach intervals.icu', async () => {
    const jwt = await devJwt();
    const id = crypto.randomUUID();
    fetchMock.get(ORIGIN).intercept({ method: 'GET', path: lookup }).reply(503, {});
    const res = await post(jwt, recordingForm({ id, date: DATE }, tcxFile(id)));
    expect(res.status).toBe(502);
    expect(res.body).toMatchObject({ error: 'intervals_unavailable', status: 503, stored: true });
  });

  it('validates the form and the file before keeping or uploading anything', async () => {
    const jwt = await devJwt();
    const id = crypto.randomUUID();
    const file = tcxFile(id);
    expect(await post(null, recordingForm({ id, date: DATE }, file))).toMatchObject({ status: 401 });
    expect(await post(jwt, recordingForm({ id: 'nope', date: DATE }, file))).toMatchObject({ status: 400, body: { error: 'invalid_id' } });
    expect(await post(jwt, recordingForm({ id, date: '10/27/2026' }, file))).toMatchObject({ status: 400, body: { error: 'invalid_date' } });
    expect(await post(jwt, recordingForm({ id, date: DATE, name: 'x'.repeat(201) }, file)))
      .toMatchObject({ status: 400, body: { error: 'invalid_name' } });
    expect(await post(jwt, recordingForm({ id, date: DATE }))).toMatchObject({ status: 400, body: { error: 'invalid_file' } });
    expect(await post(jwt, recordingForm({ id, date: DATE }, { bytes: '', name: 'run.tcx' })))
      .toMatchObject({ status: 400, body: { error: 'invalid_file' } });
    // The recorder sends TCX; Tres Fort reads only that.
    expect(await post(jwt, recordingForm({ id, date: DATE }, { bytes: fitBytes(), name: 'run.fit' })))
      .toMatchObject({ status: 400, body: { error: 'unsupported_file' } });
    expect(await post(jwt, recordingForm({ id, date: DATE }, { bytes: GPX, name: 'run.gpx' })))
      .toMatchObject({ status: 400, body: { error: 'unsupported_file' } });
    expect(await post(jwt, recordingForm({ id, date: DATE }, tcxFile(id, tcxRun({ sport: 'Biking' })))))
      .toMatchObject({ status: 422, body: { error: 'not_a_run' } });
    expect(await post(jwt, recordingForm({ id, date: DATE }, tcxFile(id, '<?xml version="1.0"?><TrainingCenterDatabase></TrainingCenterDatabase>'))))
      .toMatchObject({ status: 422, body: { error: 'no_data' } });
    expect(await post(jwt, recordingForm({ id, date: DATE }, { bytes: fitBytes(10 * 1024 * 1024), name: 'run.tcx' })))
      .toMatchObject({ status: 413, body: { error: 'file_too_large' } });
    const kept = await env.DB.prepare(`SELECT COUNT(*) AS n FROM external_activities WHERE external_id = ?1`)
      .bind(id).first<{ n: number }>();
    expect(kept?.n).toBe(0);
    // No interceptors were registered, so nothing reached the provider.
    fetchMock.assertNoPendingInterceptors();
  });
});

describe('a recorded run among other copies of the same run', () => {
  async function insertActivity(userId: string, source: string, externalId: string, startMs: number) {
    const id = `${source}:activity:${userId}:${externalId}`;
    await env.DB.prepare(
      `INSERT INTO external_activities
         (id,user_id,source,external_id,date,start_date_local_ms,start_date_utc_ms,kind,name,moving_time_sec,synced_at)
       VALUES (?1,?2,?3,?4,?5,?6,?6,'run','Run',600,?7)`,
    ).bind(id, userId, source, externalId, DATE, startMs, Date.now()).run();
    return id;
  }
  const state = (id: string) => env.DB.prepare('SELECT deleted_at, duplicate_of FROM external_activities WHERE id = ?1')
    .bind(id).first<{ deleted_at: number | null; duplicate_of: string | null }>();

  it('hides Apple Health\'s copy, and hides behind intervals.icu\'s copy, which then serves the route', async () => {
    const member = await memberJwt();
    const health = await insertActivity(member.id, 'healthkit', crypto.randomUUID(), START_MS + 1_000);
    const id = crypto.randomUUID();
    expect((await post(member.jwt, recordingForm({ id, date: DATE }, tcxFile(id)))).status).toBe(201);
    const recording = `recording:activity:${member.id}:${id}`;
    expect(await state(health)).toMatchObject({ duplicate_of: recording });
    expect(await state(recording)).toEqual({ deleted_at: null, duplicate_of: null });

    // intervals.icu's copy arrives through its sync, which reconciles.
    const intervals = await insertActivity(member.id, 'intervals', 'i990', START_MS - 2_000);
    await dedupeHealthKitAgainstIntervals(env.DB, member.id);
    expect(await state(recording)).toMatchObject({ duplicate_of: intervals });
    expect(await state(health)).toMatchObject({ duplicate_of: intervals });

    const served = await route(member.jwt, intervals);
    expect(served).toMatchObject({ status: 200, body: { activity_id: recording, recording_id: id } });
    expect((await route(member.jwt, recording)).status).toBe(200);
    // Another member never sees it, even with the ids.
    const stranger = await memberJwt();
    expect((await route(stranger.jwt, intervals)).status).toBe(404);
    expect((await route(stranger.jwt, recording)).status).toBe(404);
  });

  it('names the recording behind a run recorded without GPS, so the app can still delete it', async () => {
    const member = await memberJwt();
    const id = crypto.randomUUID();
    const noGps = tcxRun().replace(/<Position>.*?<\/Position>/g, '');
    expect((await post(member.jwt, recordingForm({ id, date: DATE }, tcxFile(id, noGps)))).status).toBe(201);
    const recording = `recording:activity:${member.id}:${id}`;
    expect(await route(member.jwt, recording)).toEqual({
      status: 200, body: { activity_id: recording, source: 'recording', recording_id: id, route: null },
    });
    const intervals = await insertActivity(member.id, 'intervals', 'i991', START_MS - 2_000);
    await dedupeHealthKitAgainstIntervals(env.DB, member.id);
    expect(await state(recording)).toMatchObject({ duplicate_of: intervals });
    expect(await route(member.jwt, intervals)).toEqual({
      status: 200, body: { activity_id: recording, source: 'recording', recording_id: id, route: null },
    });
    const stranger = await memberJwt();
    expect((await route(stranger.jwt, intervals)).status).toBe(404);
  });

  const del = (jwt: string, recordingId: string, healthIds: string[] = []) => {
    const q = healthIds.map((h) => `health_workout_id=${encodeURIComponent(h)}`).join('&');
    return SELF.fetch(`${BASE}/api/activities/recordings/${recordingId}${q ? `?${q}` : ''}`, {
      method: 'DELETE', headers: { Authorization: `Bearer ${jwt}` },
    });
  };

  it('deletes a recording, its route and the Apple Health copy the app names, and doesn\'t take the run again', async () => {
    const member = await memberJwt();
    const hk = crypto.randomUUID().toUpperCase();
    const health = await insertActivity(member.id, 'healthkit', hk, START_MS + 1_000);
    // Another Health workout, three hours later: not a copy of this run.
    const laterHk = crypto.randomUUID().toUpperCase();
    const later = await insertActivity(member.id, 'healthkit', laterHk, START_MS + 3 * 3_600_000);
    const id = crypto.randomUUID();
    expect((await post(member.jwt, recordingForm({ id, date: DATE }, tcxFile(id)))).status).toBe(201);
    const recording = `recording:activity:${member.id}:${id}`;
    expect(await state(health)).toMatchObject({ duplicate_of: recording });

    const stranger = await memberJwt();
    expect((await del(stranger.jwt, id)).status).toBe(404);
    expect((await del(member.jwt, 'nope')).status).toBe(400);
    expect((await del(member.jwt, id, ['not-a-uuid'])).status).toBe(400);
    expect(await state(recording)).toEqual({ deleted_at: null, duplicate_of: null });

    const res = await del(member.jwt, id.toUpperCase(), [hk.toLowerCase(), laterHk]);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({
      ok: true, recording_id: id, intervals: { status: 'not_connected' }, health_removed: 1,
    });
    expect((await state(recording))?.deleted_at).not.toBeNull();
    expect((await route(member.jwt, recording)).status).toBe(404);
    const left = await env.DB.prepare('SELECT COUNT(*) AS n FROM activity_routes WHERE activity_id = ?1')
      .bind(recording).first<{ n: number }>();
    expect(left?.n).toBe(0);
    // The Health copy stays gone, even when dedup runs again.
    await dedupeHealthKitAgainstIntervals(env.DB, member.id);
    const gone = await state(health);
    expect(gone?.deleted_at).not.toBeNull();
    expect(gone?.duplicate_of).toBeNull();
    expect(await state(later)).toEqual({ deleted_at: null, duplicate_of: null });
    expect((await del(member.jwt, id)).status).toBe(404);

    // A phone that still holds the file can't bring it back.
    const retry = await post(member.jwt, recordingForm({ id, date: DATE }, tcxFile(id)));
    expect(retry).toMatchObject({ status: 200, body: { deleted: true, intervals: { status: 'skipped' } } });
    expect((await route(member.jwt, recording)).status).toBe(404);
  });

  it('keeps a named Health workout deleted when Apple Health pushes it after the run was deleted', async () => {
    const member = await memberJwt();
    const push = (healthId: string, movingSec: number) => SELF.fetch(`${BASE}/api/activities/healthkit`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${member.jwt}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        id: healthId, date: DATE, start_date_local_ms: START_MS + 1_000, kind: 'run', name: 'Outdoor Run',
        moving_time_sec: movingSec, elapsed_time_sec: movingSec, distance_m: 2000,
      }),
    });
    // One Health copy synced before the delete, one Apple Health hadn't pushed yet.
    const synced = crypto.randomUUID().toUpperCase();
    expect((await push(synced, 600)).status).toBeLessThan(300);
    const unsynced = crypto.randomUUID().toUpperCase();
    const id = crypto.randomUUID();
    expect((await post(member.jwt, recordingForm({ id, date: DATE }, tcxFile(id)))).status).toBe(201);
    const res = await del(member.jwt, id, [synced, unsynced]);
    expect(await res.json()).toMatchObject({ ok: true, health_removed: 1 });

    // The late first push, and a revision of the synced copy, both stay deleted.
    expect((await push(unsynced, 600)).status).toBeLessThan(300);
    expect((await push(synced, 640)).status).toBeLessThan(300);
    for (const healthId of [synced, unsynced]) {
      const row = await state(`healthkit:activity:${member.id}:${healthId}`);
      expect(row?.deleted_at).not.toBeNull();
      expect(row?.duplicate_of).toBeNull();
    }
    await dedupeHealthKitAgainstIntervals(env.DB, member.id);
    const live = await env.DB.prepare(
      `SELECT COUNT(*) AS n FROM external_activities WHERE user_id = ?1 AND date = ?2 AND deleted_at IS NULL`,
    ).bind(member.id, DATE).first<{ n: number }>();
    expect(live?.n).toBe(0);
  });

  it('brings back a Health copy the app doesn\'t name', async () => {
    const member = await memberJwt();
    const health = await insertActivity(member.id, 'healthkit', crypto.randomUUID(), START_MS + 1_000);
    const id = crypto.randomUUID();
    expect((await post(member.jwt, recordingForm({ id, date: DATE }, tcxFile(id)))).status).toBe(201);
    const res = await del(member.jwt, id);
    expect(await res.json()).toMatchObject({ ok: true, health_removed: 0 });
    expect(await state(health)).toEqual({ deleted_at: null, duplicate_of: null });
  });

  describe('with an intervals.icu connection', () => {
    beforeEach(() => {
      fetchMock.activate();
      fetchMock.disableNetConnect();
    });
    afterEach(() => {
      fetchMock.deactivate();
      fetchMock.enableNetConnect();
    });

    /** Records and uploads a run as the owner; intervals.icu answers with `intervalsId`. */
    async function recordUploaded(jwt: string, intervalsId: string) {
      const id = crypto.randomUUID();
      const provider = fetchMock.get(ORIGIN);
      provider.intercept({ method: 'GET', path: lookup }).reply(200, []);
      provider.intercept({ method: 'POST', path: upload }).reply(201, { id: intervalsId, activities: [{ id: intervalsId }] });
      provider.intercept({ method: 'GET', path: refreshWindow }).reply(200, []);
      expect((await post(jwt, recordingForm({ id, date: DATE }, tcxFile(id)))).status).toBe(201);
      return id;
    }

    /** The intervals.icu copy as the activity sync caches it. */
    async function cacheIntervalsCopy(userId: string, intervalsId: string, recordingId: string) {
      const id = `intervals:activity:${userId}:${intervalsId}`;
      await env.DB.prepare(
        `INSERT INTO external_activities
           (id,user_id,source,external_id,date,start_date_local_ms,start_date_utc_ms,kind,name,moving_time_sec,raw,synced_at)
         VALUES (?1,?2,'intervals',?3,?4,?5,?5,'run','Run',600,?6,?7)`,
      ).bind(id, userId, intervalsId, DATE, START_MS - 2_000,
        JSON.stringify({ id: intervalsId, external_id: `tresfort:recording:${recordingId}` }), Date.now()).run();
      await dedupeHealthKitAgainstIntervals(env.DB, userId);
      return id;
    }

    it('deletes the intervals.icu upload first, then the run, its cached copy and the Health copy', async () => {
      const jwt = await devJwt();
      const owner = await ownerId();
      const hk = crypto.randomUUID().toUpperCase();
      const health = await insertActivity(owner, 'healthkit', hk, START_MS + 1_000);
      const id = await recordUploaded(jwt, 'i970');
      const intervals = await cacheIntervalsCopy(owner, 'i970', id);
      const recording = `recording:activity:${owner}:${id}`;
      expect(await state(recording)).toMatchObject({ duplicate_of: intervals });
      expect(await state(health)).toMatchObject({ duplicate_of: intervals });
      expect((await route(jwt, intervals)).status).toBe(200);

      const provider = fetchMock.get(ORIGIN);
      provider.intercept({ method: 'DELETE', path: '/api/v1/activity/i970' }).reply(200, {});
      provider.intercept({ method: 'GET', path: refreshWindow }).reply(200, []);
      const res = await del(jwt, id, [hk]);
      expect(res.status).toBe(200);
      expect(await res.json()).toEqual({
        ok: true, recording_id: id, intervals: { status: 'deleted', activity_id: 'i970' }, health_removed: 1,
      });
      fetchMock.assertNoPendingInterceptors();
      await dedupeHealthKitAgainstIntervals(env.DB, owner);
      for (const row of [recording, intervals, health]) {
        expect((await state(row))?.deleted_at, row).not.toBeNull();
      }
      expect((await state(health))?.duplicate_of).toBeNull();
      expect((await route(jwt, intervals)).status).toBe(404);
    });

    it('finds an upload the sync hasn\'t cached yet on intervals.icu, and deletes a run never uploaded', async () => {
      const jwt = await devJwt();
      const id = await recordUploaded(jwt, 'i980');
      const provider = fetchMock.get(ORIGIN);
      provider.intercept({ method: 'GET', path: lookup }).reply(200, [
        { id: 'i981', type: 'Run', start_date_local: `${DATE}T09:00:00`, moving_time: 900 },
        { id: 'i980', type: 'Run', start_date_local: `${DATE}T07:00:00`, moving_time: 600, external_id: `tresfort:recording:${id}` },
      ]);
      provider.intercept({ method: 'DELETE', path: '/api/v1/activity/i980' }).reply(200, {});
      provider.intercept({ method: 'GET', path: refreshWindow }).reply(200, []);
      expect(await (await del(jwt, id)).json()).toMatchObject({ ok: true, intervals: { status: 'deleted', activity_id: 'i980' } });

      const never = await recordUploaded(jwt, 'i985');
      provider.intercept({ method: 'GET', path: lookup }).reply(200, []);
      expect(await (await del(jwt, never)).json()).toMatchObject({ ok: true, intervals: { status: 'not_found' } });
      fetchMock.assertNoPendingInterceptors();
    });

    it('deletes nothing when intervals.icu can\'t delete the upload', async () => {
      const jwt = await devJwt();
      const owner = await ownerId();
      const hk = crypto.randomUUID().toUpperCase();
      const health = await insertActivity(owner, 'healthkit', hk, START_MS + 1_000);
      const id = await recordUploaded(jwt, 'i990');
      const intervals = await cacheIntervalsCopy(owner, 'i990', id);
      const recording = `recording:activity:${owner}:${id}`;
      const before = await Promise.all([recording, intervals, health].map(state));

      const provider = fetchMock.get(ORIGIN);
      provider.intercept({ method: 'DELETE', path: '/api/v1/activity/i990' }).reply(503, {});
      const down = await del(jwt, id, [hk]);
      expect(down.status).toBe(502);
      expect(await down.json()).toMatchObject({ error: 'intervals_unavailable', deleted: false });
      provider.intercept({ method: 'DELETE', path: '/api/v1/activity/i990' }).reply(403, {});
      const refused = await del(jwt, id, [hk]);
      expect(refused.status).toBe(409);
      expect(await refused.json()).toMatchObject({ error: 'intervals_write_forbidden', deleted: false });
      fetchMock.assertNoPendingInterceptors();

      expect(await Promise.all([recording, intervals, health].map(state))).toEqual(before);
      expect((await route(jwt, intervals)).status).toBe(200);
    });
  });
});
