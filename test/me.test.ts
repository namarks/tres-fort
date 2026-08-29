// GET /api/me — account/setup snapshot for the iOS Profile tab.
//
// Covers display_name/email passthrough, intervals connection derived from
// the user row, Claude connection derived from a durable OAuth grant, and
// last_active derived from MCP audit rows ONLY (REST actor='ios' excluded).
import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { issueAppJwt } from '../src/auth';

const BASE = 'https://lift-coach.test';

// A non-owner user (not the OWNER_APPLE_SUB / earliest-created row).
async function makeUser(label: string): Promise<{ id: string; jwt: string }> {
  const id = crypto.randomUUID();
  await env.DB.prepare(
    'INSERT INTO users (id,apple_sub,email,display_name,created_at) VALUES (?1,?2,?3,?4,?5)',
  )
    .bind(id, `sub-${label}-${id}`, `${label}@test`, label, Date.now())
    .run();
  return { id, jwt: await issueAppJwt(id, 'test-secret') };
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

async function devJwt(): Promise<{ id: string; jwt: string }> {
  const r = await SELF.fetch(`${BASE}/auth/dev`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ secret: 'test-dev' }),
  });
  expect(r.status).toBe(200);
  const body = await r.json<{ jwt: string; user: { id: string } }>();
  return { id: body.user.id, jwt: body.jwt };
}

const auth = (jwt: string) => ({ Authorization: `Bearer ${jwt}` });

async function getMe(jwt: string) {
  const r = await SELF.fetch(`${BASE}/api/me`, { headers: auth(jwt) });
  return r;
}

describe('GET /api/me', () => {
  it('requires auth', async () => {
    const r = await SELF.fetch(`${BASE}/api/me`);
    expect(r.status).toBe(401);
  });

  it('fresh owner: name/email present, nothing connected', async () => {
    const a = await devJwt();
    const r = await getMe(a.jwt);
    expect(r.status).toBe(200);
    const me = await r.json<any>();
    // /auth/dev upserts 'Dev Owner' / 'dev@local'.
    expect(me.display_name).toBe('Dev Owner');
    expect(me.email).toBe('dev@local');
    expect(me.intervals.connected).toBe(false);
    expect(me.intervals.athlete_id).toBeNull();
    // The dev user is the owner (OWNER_APPLE_SUB / earliest row).
    expect(me.claude.is_owner).toBe(true);
    expect(me.claude.connected).toBe(false);
    expect(me.claude.last_active).toBeNull();
    // never leak the api_key shape
    expect(me.intervals.api_key).toBeUndefined();
  });

  it('intervals.connected reflects the user row athlete_id', async () => {
    const a = await devJwt();
    await env.DB.prepare(
      "UPDATE users SET intervals_api_key = 'secret', intervals_athlete_id = 'i12345' WHERE id = ?1",
    )
      .bind(a.id)
      .run();
    const me = await (await getMe(a.jwt)).json<any>();
    expect(me.intervals.connected).toBe(true);
    expect(me.intervals.athlete_id).toBe('i12345');
  });

  it('claude.connected is true once a durable OAuth grant (refresh_token) exists', async () => {
    const a = await devJwt();
    let me = await (await getMe(a.jwt)).json<any>();
    expect(me.claude.connected).toBe(false);

    await env.DB.prepare(
      'INSERT INTO oauth_tokens (access_token, refresh_token, client_id, scope, expires_at, created_at) VALUES (?1,?2,?3,?4,?5,?6)',
    )
      .bind('acc-tok', 'ref-tok', 'claude-client', 'mcp', Date.now() + 3600_000, Date.now())
      .run();

    me = await (await getMe(a.jwt)).json<any>();
    expect(me.claude.is_owner).toBe(true);
    expect(me.claude.connected).toBe(true);
  });

  // M3 makes Claude per-user: a non-owner sees THEIR OWN grant, never the
  // owner's, and their own MCP activity surfaces in last_active.
  it('Claude status is per-user (M3): a non-owner sees only their own grant', async () => {
    const owner = await devJwt();
    const friend = await makeUser('me-friend');
    // The owner's durable grant (legacy NULL user_id, as pre-M3 issued).
    await env.DB.prepare(
      'INSERT INTO oauth_tokens (access_token, refresh_token, client_id, scope, expires_at, created_at) VALUES (?1,?2,?3,?4,?5,?6)',
    )
      .bind(crypto.randomUUID(), crypto.randomUUID(), 'c', 'mcp', Date.now() + 3600_000, Date.now())
      .run();
    // The friend has used MCP as themselves but has NOT bound their own grant.
    await env.DB.prepare(
      "INSERT INTO audit_log (id,user_id,actor,tool,args,result,created_at) VALUES (?1,?2,'mcp','x',NULL,NULL,?3)",
    )
      .bind(crypto.randomUUID(), friend.id, Date.now())
      .run();

    let friendMe = await (await getMe(friend.jwt)).json<any>();
    expect(friendMe.claude.is_owner).toBe(false);
    // Isolation: the owner's grant is NOT the friend's → still not connected.
    expect(friendMe.claude.connected).toBe(false);
    // …but last_active IS per-user now: the friend's own MCP activity shows.
    expect(friendMe.claude.last_active).not.toBeNull();

    // The friend binds their OWN grant (a token scoped to them, M3) → their
    // Profile now reports connected, without ever seeing the owner's.
    await env.DB.prepare(
      'INSERT INTO oauth_tokens (access_token, refresh_token, client_id, scope, expires_at, created_at, user_id) VALUES (?1,?2,?3,?4,?5,?6,?7)',
    )
      .bind(crypto.randomUUID(), crypto.randomUUID(), 'c', 'mcp', Date.now() + 3600_000, Date.now(), friend.id)
      .run();
    friendMe = await (await getMe(friend.jwt)).json<any>();
    expect(friendMe.claude.connected).toBe(true);

    // The owner still sees their own (NULL-user_id) grant connected.
    const ownerMe = await (await getMe(owner.jwt)).json<any>();
    expect(ownerMe.claude.is_owner).toBe(true);
    expect(ownerMe.claude.connected).toBe(true);
  });

  it('claude.last_active uses MCP audit rows only (ios writes excluded)', async () => {
    const a = await devJwt();
    const mcpAt = 1_700_000_000_000;
    const iosAt = 1_800_000_000_000; // newer, but actor='ios' → must NOT win
    await env.DB.prepare(
      "INSERT INTO audit_log (id,user_id,actor,tool,args,result,created_at) VALUES (?1,?2,'mcp','adjust_today',NULL,NULL,?3)",
    )
      .bind(crypto.randomUUID(), a.id, mcpAt)
      .run();
    await env.DB.prepare(
      "INSERT INTO audit_log (id,user_id,actor,tool,args,result,created_at) VALUES (?1,?2,'ios','create_group',NULL,NULL,?3)",
    )
      .bind(crypto.randomUUID(), a.id, iosAt)
      .run();

    const me = await (await getMe(a.jwt)).json<any>();
    expect(me.claude.last_active).toBe(mcpAt);
  });
});

describe('PATCH /api/me/profile', () => {
  it('requires an authenticated app session', async () => {
    const response = await SELF.fetch(`${BASE}/api/me/profile`, {
      method: 'PATCH',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ display_name: 'No session' }),
    });
    expect(response.status).toBe(401);
  });

  it('trims and updates only the caller without auditing the name value', async () => {
    const caller = await makeUser('profile-caller');
    const other = await makeUser('profile-other');

    const response = await SELF.fetch(`${BASE}/api/me/profile`, {
      method: 'PATCH',
      headers: {
        ...auth(caller.jwt),
        'content-type': 'application/json',
      },
      body: JSON.stringify({ display_name: '  Renée Test  ' }),
    });

    expect(response.status).toBe(200);
    expect((await response.json<any>()).display_name).toBe('Renée Test');
    expect(
      await env.DB.prepare('SELECT display_name FROM users WHERE id = ?1')
        .bind(caller.id)
        .first<{ display_name: string }>('display_name'),
    ).toBe('Renée Test');
    expect(
      await env.DB.prepare('SELECT display_name FROM users WHERE id = ?1')
        .bind(other.id)
        .first<{ display_name: string }>('display_name'),
    ).toBe('profile-other');

    const audit = await env.DB.prepare(
      "SELECT actor, args, result FROM audit_log WHERE user_id = ?1 AND tool = 'update_profile' ORDER BY created_at DESC LIMIT 1",
    )
      .bind(caller.id)
      .first<{ actor: string; args: string; result: string }>();
    expect(audit).toEqual({
      actor: 'ios',
      args: JSON.stringify({ field: 'display_name' }),
      result: 'ok',
    });
    expect(audit?.args).not.toContain('Renée Test');
  });

  it('rejects malformed, blank, non-string, and overlong names', async () => {
    const caller = await makeUser('profile-invalid');
    const requests: Array<{ body: string; contentType?: string }> = [
      { body: '{', contentType: 'application/json' },
      { body: JSON.stringify({ display_name: '   ' }) },
      { body: JSON.stringify({ display_name: 42 }) },
      { body: JSON.stringify({ display_name: 'x'.repeat(81) }) },
    ];

    for (const request of requests) {
      const response = await SELF.fetch(`${BASE}/api/me/profile`, {
        method: 'PATCH',
        headers: {
          ...auth(caller.jwt),
          'content-type': request.contentType ?? 'application/json',
        },
        body: request.body,
      });
      expect(response.status).toBe(400);
    }

    expect(
      await env.DB.prepare('SELECT display_name FROM users WHERE id = ?1')
        .bind(caller.id)
        .first<{ display_name: string }>('display_name'),
    ).toBe('profile-invalid');
  });
});
