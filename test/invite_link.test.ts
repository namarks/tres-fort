// Universal-Link invites (M6): the AASA file, the /join/:code landing page,
// and the GET /api/groups/invite/:code preview that backs the in-app
// join-confirm sheet. The redeem path itself is covered by groups.test.ts —
// here we only assert the *advertise* + *preview* surface (no mutation).
import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { issueAppJwt } from '../src/auth';

const BASE = 'https://lift-coach.test';

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

const headers = (jwt: string) => ({
  'content-type': 'application/json',
  Authorization: `Bearer ${jwt}`,
});

/** Create a group with `name`, mint an invite, return its code. */
async function makeInvite(jwt: string, name: string): Promise<string> {
  const g = await SELF.fetch(`${BASE}/api/groups`, {
    method: 'POST',
    headers: headers(jwt),
    body: JSON.stringify({ name }),
  });
  expect(g.status).toBe(201);
  const group = await g.json<{ id: string }>();
  const inv = await SELF.fetch(`${BASE}/api/groups/${group.id}/invites`, {
    method: 'POST',
    headers: headers(jwt),
    body: '{}',
  });
  expect(inv.status).toBe(201);
  return (await inv.json<{ code: string }>()).code;
}

/** Mint a JWT for a fresh secondary user (devJwt is owner-locked to one row). */
async function makeUser(label: string): Promise<string> {
  const id = crypto.randomUUID();
  await env.DB.prepare(
    'INSERT INTO users (id,apple_sub,email,display_name,created_at) VALUES (?1,?2,?3,?4,?5)',
  )
    .bind(id, `sub-${label}-${id}`, `${label}@test`, label, Date.now())
    .run();
  return issueAppJwt(id, 'test-secret');
}

describe('AASA file', () => {
  it('serves apple-app-site-association at /.well-known with the app id and /join path', async () => {
    const r = await SELF.fetch(`${BASE}/.well-known/apple-app-site-association`);
    expect(r.status).toBe(200);
    expect(r.headers.get('content-type')).toContain('application/json');
    const j = await r.json<any>();
    expect(j.applinks.details[0].appIDs).toContain('8BA2RY6RCA.com.nmarkspdx.tresfort');
    expect(j.applinks.details[0].components[0]['/']).toBe('/join/*');
  });

  it('also serves at the bare root path (Apple checks both)', async () => {
    const r = await SELF.fetch(`${BASE}/apple-app-site-association`);
    expect(r.status).toBe(200);
    expect(r.headers.get('content-type')).toContain('application/json');
  });
});

describe('/join/:code landing page', () => {
  it('renders the group name and code for a valid invite', async () => {
    const code = await makeInvite(await devJwt(), 'Nick + Dad');
    const r = await SELF.fetch(`${BASE}/join/${code}`);
    expect(r.status).toBe(200);
    expect(r.headers.get('content-type')).toContain('text/html');
    const html = await r.text();
    expect(html).toContain('Nick + Dad');
    expect(html).toContain(code);
  });

  it('emits Open Graph tags (dynamic title + brand image) for a rich preview', async () => {
    const code = await makeInvite(await devJwt(), 'Nick + Dad');
    const html = await (await SELF.fetch(`${BASE}/join/${code}`)).text();
    expect(html).toContain('property="og:title" content="Join Nick + Dad on Très Fort"');
    expect(html).toContain('property="og:image"');
    expect(html).toContain('/join-card.png');
    expect(html).toContain('name="twitter:card" content="summary_large_image"');
  });

  it('shows an "invalid" page for an unknown but well-formed code', async () => {
    const r = await SELF.fetch(`${BASE}/join/ZZZZZZ`);
    expect(r.status).toBe(200);
    expect((await r.text()).toLowerCase()).toContain('no longer valid');
  });

  it('shows an "invalid" page for a malformed code (wrong length/alphabet)', async () => {
    const r = await SELF.fetch(`${BASE}/join/abc`);
    expect(r.status).toBe(200);
    expect((await r.text()).toLowerCase()).toContain('no longer valid');
  });

  it('HTML-escapes the group name (XSS guard)', async () => {
    const code = await makeInvite(await devJwt(), '<script>alert(1)</script>');
    const html = await (await SELF.fetch(`${BASE}/join/${code}`)).text();
    expect(html).not.toContain('<script>alert(1)</script>');
    expect(html).toContain('&lt;script&gt;');
  });

  it('escapes a malformed code so it cannot break out of the og:url attribute', async () => {
    // raw decoded path segment = `"><img>` → must not appear unescaped
    const r = await SELF.fetch(`${BASE}/join/%22%3E%3Cimg%3E`);
    expect(r.status).toBe(200);
    const html = await r.text();
    expect(html).not.toContain('"><img>');
    expect(html.toLowerCase()).toContain('no longer valid');
  });
});

describe('GET /api/groups/invite/:code preview', () => {
  it('returns the group name + valid status for a live code', async () => {
    const jwt = await devJwt();
    const code = await makeInvite(jwt, 'Lift Crew');
    const r = await SELF.fetch(`${BASE}/api/groups/invite/${code}`, { headers: headers(jwt) });
    expect(r.status).toBe(200);
    const j = await r.json<{ status: string; group_name: string | null }>();
    expect(j.status).toBe('valid');
    expect(j.group_name).toBe('Lift Crew');
  });

  it('returns unknown for a bogus code without consuming anything', async () => {
    const jwt = await devJwt();
    const r = await SELF.fetch(`${BASE}/api/groups/invite/ZZZZZZ`, { headers: headers(jwt) });
    const j = await r.json<{ status: string }>();
    expect(j.status).toBe('unknown');
  });

  it('returns "used" once the code has been redeemed', async () => {
    const owner = await devJwt();
    const code = await makeInvite(owner, 'Used Crew');
    // A second user redeems it (the owner is already a member → would be a
    // no-op "already_member" that does NOT consume the code).
    const member = await makeUser('redeemer');
    const join = await SELF.fetch(`${BASE}/api/groups/join`, {
      method: 'POST',
      headers: headers(member),
      body: JSON.stringify({ code }),
    });
    expect(join.status).toBe(200);
    const r = await SELF.fetch(`${BASE}/api/groups/invite/${code}`, { headers: headers(owner) });
    expect((await r.json<{ status: string }>()).status).toBe('used');
  });

  it('returns "expired" for a past-expiry code', async () => {
    const owner = await devJwt();
    const g = await SELF.fetch(`${BASE}/api/groups`, {
      method: 'POST',
      headers: headers(owner),
      body: JSON.stringify({ name: 'Expired Crew' }),
    });
    const group = await g.json<{ id: string }>();
    const inv = await SELF.fetch(`${BASE}/api/groups/${group.id}/invites`, {
      method: 'POST',
      headers: headers(owner),
      body: JSON.stringify({ expires_at: Date.now() - 60_000 }),
    });
    const { code } = await inv.json<{ code: string }>();
    const r = await SELF.fetch(`${BASE}/api/groups/invite/${code}`, { headers: headers(owner) });
    expect((await r.json<{ status: string }>()).status).toBe('expired');
  });

  it('is case-insensitive (lowercased code resolves the same invite)', async () => {
    const owner = await devJwt();
    const code = await makeInvite(owner, 'Case Crew');
    const r = await SELF.fetch(`${BASE}/api/groups/invite/${code.toLowerCase()}`, {
      headers: headers(owner),
    });
    const j = await r.json<{ status: string; group_name: string | null }>();
    expect(j.status).toBe('valid');
    expect(j.group_name).toBe('Case Crew');
  });

  it('requires auth', async () => {
    const r = await SELF.fetch(`${BASE}/api/groups/invite/ZZZZZZ`);
    expect(r.status).toBe(401);
  });
});

describe('og:image brand card', () => {
  it('serves /join-card.png as a real PNG', async () => {
    const r = await SELF.fetch(`${BASE}/join-card.png`);
    expect(r.status).toBe(200);
    expect(r.headers.get('content-type')).toBe('image/png');
    const buf = await r.arrayBuffer();
    expect(buf.byteLength).toBeGreaterThan(1000);
    // PNG magic number: 89 50 4E 47
    expect([...new Uint8Array(buf.slice(0, 4))]).toEqual([0x89, 0x50, 0x4e, 0x47]);
  });
});
