// POST /api/activities/recordings: a run recorded in the app is uploaded to
// intervals.icu as an activity file (docs/plans/run-recorder P0). Retries are
// idempotent on the recording's external_id, the file is never stored
// locally, and provider failures are errors. No real network: fetchMock.
import { env, applyD1Migrations, fetchMock, SELF } from 'cloudflare:test';
import { afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { getUserIntervalsCreds, recordingFormat } from '../src/db';
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

  it('uploads the file with the recording external_id and refreshes the cache', async () => {
    const jwt = await devJwt();
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

    const res = await post(jwt, recordingForm({ id, date: DATE, name: ' Morning Run ' }, { bytes: fitBytes(), name: 'whatever.fit' }));

    expect(res.status).toBe(201);
    expect(res.body).toEqual({
      ok: true,
      destination: 'intervals.icu',
      deduplicated: false,
      recording_id: id,
      intervals_activity_id: 'i950',
      refresh: { status: 'ok', synced: 0 },
    });
    expect(query(sentPath).get('external_id')).toBe(`tresfort:recording:${id}`);
    expect(query(sentPath).get('name')).toBe('Morning Run');
    // The provider sees the file under the recording id with its format.
    expect(sentBody).toContain(`filename="${id}.fit"`);
    expect(sentBody).toContain('.FIT');
    fetchMock.assertNoPendingInterceptors();
  });

  it('returns the earlier upload on a retry instead of uploading again', async () => {
    const jwt = await devJwt();
    const id = crypto.randomUUID();
    const provider = fetchMock.get(ORIGIN);
    provider.intercept({ method: 'GET', path: lookup }).reply(200, [
      { id: 'i960', type: 'Run', start_date_local: `${DATE}T07:00:00`, moving_time: 1800 },
      { id: 'i961', type: 'Run', start_date_local: '2026-10-28T00:10:00', moving_time: 1800, external_id: `tresfort:recording:${id}` },
    ]);
    provider.intercept({ method: 'GET', path: refreshWindow }).reply(200, []);
    // No upload interceptor: an upload would fail closed under disableNetConnect.
    const res = await post(jwt, recordingForm({ id, date: DATE }, { bytes: GPX, name: 'run.gpx' }));
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ ok: true, deduplicated: true, recording_id: id, intervals_activity_id: 'i961' });
    fetchMock.assertNoPendingInterceptors();
  });

  it('reports a file intervals.icu already had as a duplicate', async () => {
    const jwt = await devJwt();
    const provider = fetchMock.get(ORIGIN);
    provider.intercept({ method: 'GET', path: lookup }).reply(200, []);
    provider.intercept({ method: 'POST', path: upload }).reply(200, [{ icu_athlete_id: ATHLETE, id: 'i970' }]);
    provider.intercept({ method: 'GET', path: refreshWindow }).reply(200, []);
    const res = await post(jwt, recordingForm({ id: crypto.randomUUID(), date: DATE }, { bytes: fitBytes(), name: 'run.fit' }));
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ ok: true, deduplicated: true, intervals_activity_id: 'i970' });
  });

  it('reports a write rejection without disconnecting the read credential', async () => {
    const jwt = await devJwt();
    const provider = fetchMock.get(ORIGIN);
    provider.intercept({ method: 'GET', path: lookup }).reply(200, []);
    provider.intercept({ method: 'POST', path: upload }).reply(403, { error: 'insufficient scope' });
    const res = await post(jwt, recordingForm({ id: crypto.randomUUID(), date: DATE }, { bytes: fitBytes(), name: 'run.fit' }));
    expect(res.status).toBe(409);
    expect(res.body).toMatchObject({ error: 'intervals_write_forbidden', status: 403 });
    const owner = await env.DB.prepare('SELECT id FROM users ORDER BY created_at LIMIT 1').first<{ id: string }>();
    const creds = await getUserIntervalsCreds(env.DB, owner!.id);
    expect(creds.athlete_id).toBe(ATHLETE);
    expect(creds.api_key).not.toBeNull();
  });

  it.each([
    [500, 502, 'intervals_unavailable'],
    [422, 422, 'intervals_rejected'],
  ])('maps a provider %i to HTTP %i %s', async (providerStatus, status, error) => {
    const jwt = await devJwt();
    const provider = fetchMock.get(ORIGIN);
    provider.intercept({ method: 'GET', path: lookup }).reply(200, []);
    provider.intercept({ method: 'POST', path: upload }).reply(providerStatus, { error: 'synthetic failure' });
    const res = await post(jwt, recordingForm({ id: crypto.randomUUID(), date: DATE }, { bytes: fitBytes(), name: 'run.fit' }));
    expect(res.status).toBe(status);
    expect(res.body).toMatchObject({ error, status: providerStatus });
  });

  it('fails without uploading when the earlier-upload check cannot reach intervals.icu', async () => {
    const jwt = await devJwt();
    fetchMock.get(ORIGIN).intercept({ method: 'GET', path: lookup }).reply(503, {});
    const res = await post(jwt, recordingForm({ id: crypto.randomUUID(), date: DATE }, { bytes: fitBytes(), name: 'run.fit' }));
    expect(res.status).toBe(502);
    expect(res.body).toMatchObject({ error: 'intervals_unavailable', status: 503 });
  });

  it('tells a member without an intervals.icu connection that nothing was uploaded', async () => {
    await devJwt(); // The owner row exists, so the env credential stays the owner's.
    const id = crypto.randomUUID();
    await env.DB.prepare('INSERT INTO users (id,apple_sub,created_at) VALUES (?1,?1,?2)').bind(id, Date.now()).run();
    const jwt = await issueAppJwt(id, 'test-secret');
    const res = await post(jwt, recordingForm({ id: crypto.randomUUID(), date: DATE }, { bytes: fitBytes(), name: 'run.fit' }));
    expect(res.status).toBe(409);
    expect(res.body).toMatchObject({ error: 'intervals_not_connected' });
  });

  it('validates the form before contacting intervals.icu', async () => {
    const jwt = await devJwt();
    const id = crypto.randomUUID();
    const fit = { bytes: fitBytes(), name: 'run.fit' };
    expect(await post(null, recordingForm({ id, date: DATE }, fit))).toMatchObject({ status: 401 });
    expect(await post(jwt, recordingForm({ id: 'nope', date: DATE }, fit))).toMatchObject({ status: 400, body: { error: 'invalid_id' } });
    expect(await post(jwt, recordingForm({ id, date: '10/27/2026' }, fit))).toMatchObject({ status: 400, body: { error: 'invalid_date' } });
    expect(await post(jwt, recordingForm({ id, date: DATE, name: 'x'.repeat(201) }, fit)))
      .toMatchObject({ status: 400, body: { error: 'invalid_name' } });
    expect(await post(jwt, recordingForm({ id, date: DATE }))).toMatchObject({ status: 400, body: { error: 'invalid_file' } });
    expect(await post(jwt, recordingForm({ id, date: DATE }, { bytes: '', name: 'run.fit' })))
      .toMatchObject({ status: 400, body: { error: 'invalid_file' } });
    expect(await post(jwt, recordingForm({ id, date: DATE }, { bytes: GPX, name: 'run.fit' })))
      .toMatchObject({ status: 400, body: { error: 'unsupported_file' } });
    expect(await post(jwt, recordingForm({ id, date: DATE }, { bytes: fitBytes(10 * 1024 * 1024), name: 'run.fit' })))
      .toMatchObject({ status: 413, body: { error: 'file_too_large' } });
    // No interceptors were registered, so nothing reached the provider.
    fetchMock.assertNoPendingInterceptors();
  });
});
