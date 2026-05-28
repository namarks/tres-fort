// M2: Groups + invite-gated sign-in.
//
// Covers the REST surface (POST/GET/PATCH/DELETE under /api/groups*),
// cross-user isolation, the invite lifecycle (create -> redeem -> race),
// per-group display_name overrides, and that each mutation lands an
// audit_log row (the visible/reversible trail the project relies on as a
// scopes substitute).
import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { issueAppJwt } from '../src/auth';

const BASE = 'https://lift-coach.test';

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

const headers = (jwt: string) => ({
  'content-type': 'application/json',
  Authorization: `Bearer ${jwt}`,
});

/**
 * Mint a JWT for a freshly-inserted secondary user. /auth/dev is owner-
 * locked (one row), so we drop a user row directly and issue a JWT with
 * the production issuer — the same pattern test/activities.test.ts uses.
 */
async function makeUser(label: string): Promise<{ id: string; jwt: string }> {
  const id = crypto.randomUUID();
  await env.DB.prepare(
    'INSERT INTO users (id,apple_sub,email,display_name,created_at) VALUES (?1,?2,?3,?4,?5)',
  )
    .bind(id, `sub-${label}-${id}`, `${label}@test`, label, Date.now())
    .run();
  const jwt = await issueAppJwt(id, 'test-secret');
  return { id, jwt };
}

describe('groups REST: create + list + detail', () => {
  it('POST /api/groups creates a group and auto-adds the creator as a member', async () => {
    const a = await devJwt();
    const r = await SELF.fetch(`${BASE}/api/groups`, {
      method: 'POST',
      headers: headers(a.jwt),
      body: JSON.stringify({ name: 'Bike Buddies' }),
    });
    expect(r.status).toBe(201);
    const g = await r.json<any>();
    expect(g.name).toBe('Bike Buddies');
    expect(g.created_by).toBe(a.id);
    expect(Array.isArray(g.members)).toBe(true);
    expect(g.members).toHaveLength(1);
    expect(g.members[0].user_id).toBe(a.id);

    // audit_log gained a create_group row tied to the creator.
    const audit = await env.DB
      .prepare(
        "SELECT * FROM audit_log WHERE tool = 'create_group' AND user_id = ?1 ORDER BY created_at DESC LIMIT 1",
      )
      .bind(a.id)
      .first<any>();
    expect(audit).toBeTruthy();
    expect(audit.actor).toBe('ios');
  });

  it('GET /api/groups returns only the caller\'s groups', async () => {
    const a = await devJwt();
    const b = await makeUser('user-list');

    // A creates one, B creates a different one — neither sees the other's.
    const ra = await SELF.fetch(`${BASE}/api/groups`, {
      method: 'POST',
      headers: headers(a.jwt),
      body: JSON.stringify({ name: 'A-only group' }),
    });
    const aGroup = await ra.json<any>();

    const rb = await SELF.fetch(`${BASE}/api/groups`, {
      method: 'POST',
      headers: headers(b.jwt),
      body: JSON.stringify({ name: 'B-only group' }),
    });
    const bGroup = await rb.json<any>();

    const listA = await (
      await SELF.fetch(`${BASE}/api/groups`, { headers: headers(a.jwt) })
    ).json<{ groups: any[] }>();
    expect(listA.groups.find((g) => g.id === aGroup.id)).toBeDefined();
    expect(listA.groups.find((g) => g.id === bGroup.id)).toBeUndefined();

    const listB = await (
      await SELF.fetch(`${BASE}/api/groups`, { headers: headers(b.jwt) })
    ).json<{ groups: any[] }>();
    expect(listB.groups.find((g) => g.id === bGroup.id)).toBeDefined();
    expect(listB.groups.find((g) => g.id === aGroup.id)).toBeUndefined();
  });

  it('GET /api/groups/:id forbids non-members, 404s unknown ids', async () => {
    const a = await devJwt();
    const b = await makeUser('user-detail');
    const ra = await SELF.fetch(`${BASE}/api/groups`, {
      method: 'POST',
      headers: headers(a.jwt),
      body: JSON.stringify({ name: 'private' }),
    });
    const aGroup = await ra.json<any>();

    // B is NOT a member -> 403.
    const denied = await SELF.fetch(`${BASE}/api/groups/${aGroup.id}`, {
      headers: headers(b.jwt),
    });
    expect(denied.status).toBe(403);

    // A is a member -> 200 with members hydrated.
    const ok = await SELF.fetch(`${BASE}/api/groups/${aGroup.id}`, {
      headers: headers(a.jwt),
    });
    expect(ok.status).toBe(200);
    const detail = await ok.json<any>();
    expect(detail.members.find((m: any) => m.user_id === a.id)).toBeDefined();

    // Unknown id -> 404.
    const missing = await SELF.fetch(`${BASE}/api/groups/${crypto.randomUUID()}`, {
      headers: headers(a.jwt),
    });
    expect(missing.status).toBe(404);
  });

  it('POST /api/groups rejects empty/missing names', async () => {
    const a = await devJwt();
    const r1 = await SELF.fetch(`${BASE}/api/groups`, {
      method: 'POST',
      headers: headers(a.jwt),
      body: JSON.stringify({ name: '' }),
    });
    expect(r1.status).toBe(400);
    const r2 = await SELF.fetch(`${BASE}/api/groups`, {
      method: 'POST',
      headers: headers(a.jwt),
      body: JSON.stringify({}),
    });
    expect(r2.status).toBe(400);
  });
});

describe('groups invite lifecycle', () => {
  async function freshGroup(label: string): Promise<{
    creator: { id: string; jwt: string };
    groupId: string;
  }> {
    const creator = await makeUser(label);
    const r = await SELF.fetch(`${BASE}/api/groups`, {
      method: 'POST',
      headers: headers(creator.jwt),
      body: JSON.stringify({ name: `g-${label}` }),
    });
    const g = await r.json<any>();
    return { creator, groupId: g.id };
  }

  it('member can mint an invite; non-member 403s', async () => {
    const { creator, groupId } = await freshGroup('inv-mint');
    const stranger = await makeUser('inv-stranger');

    // Member -> 201 with a 6-char code and an expires_at ~30 days out.
    const ok = await SELF.fetch(`${BASE}/api/groups/${groupId}/invites`, {
      method: 'POST',
      headers: headers(creator.jwt),
      body: JSON.stringify({}),
    });
    expect(ok.status).toBe(201);
    const invite = await ok.json<any>();
    expect(invite.code).toMatch(/^[A-Z2-9]{6}$/);
    expect(invite.group_id).toBe(groupId);
    expect(invite.expires_at).toBeGreaterThan(Date.now());
    // Default TTL is 30d; allow a comfortable window for clock drift.
    const thirtyDays = 30 * 24 * 60 * 60 * 1000;
    expect(invite.expires_at - Date.now()).toBeGreaterThan(thirtyDays - 60_000);
    expect(invite.expires_at - Date.now()).toBeLessThan(thirtyDays + 60_000);

    // create_invite audited.
    const audit = await env.DB
      .prepare(
        "SELECT * FROM audit_log WHERE tool = 'create_invite' AND user_id = ?1 ORDER BY created_at DESC LIMIT 1",
      )
      .bind(creator.id)
      .first<any>();
    expect(audit).toBeTruthy();

    // Stranger -> 403 (group exists but they're not in it).
    const denied = await SELF.fetch(`${BASE}/api/groups/${groupId}/invites`, {
      method: 'POST',
      headers: headers(stranger.jwt),
      body: JSON.stringify({}),
    });
    expect(denied.status).toBe(403);
  });

  it('POST /api/groups/join redeems an invite and adds the user to the group', async () => {
    const { creator, groupId } = await freshGroup('inv-redeem');
    const joiner = await makeUser('inv-joiner');

    const mint = await SELF.fetch(`${BASE}/api/groups/${groupId}/invites`, {
      method: 'POST',
      headers: headers(creator.jwt),
      body: JSON.stringify({}),
    });
    const { code } = await mint.json<any>();

    const join = await SELF.fetch(`${BASE}/api/groups/join`, {
      method: 'POST',
      headers: headers(joiner.jwt),
      body: JSON.stringify({ code }),
    });
    expect(join.status).toBe(200);
    const body = await join.json<any>();
    expect(body.ok).toBe(true);
    expect(body.group.id).toBe(groupId);
    expect(body.group.members.find((m: any) => m.user_id === joiner.id)).toBeDefined();

    // Invite now flagged used.
    const inv = await env.DB
      .prepare('SELECT * FROM group_invites WHERE code = ?1')
      .bind(code)
      .first<any>();
    expect(inv.used_at).toBeGreaterThan(0);
    expect(inv.used_by).toBe(joiner.id);

    // redeem_invite audit landed for the joiner.
    const audit = await env.DB
      .prepare(
        "SELECT * FROM audit_log WHERE tool = 'redeem_invite' AND user_id = ?1 ORDER BY created_at DESC LIMIT 1",
      )
      .bind(joiner.id)
      .first<any>();
    expect(audit).toBeTruthy();
    expect(audit.actor).toBe('ios');
  });

  it('redeeming a used code returns 410 and does not re-add', async () => {
    const { creator, groupId } = await freshGroup('inv-used');
    const first = await makeUser('inv-first');
    const second = await makeUser('inv-second');

    const mint = await SELF.fetch(`${BASE}/api/groups/${groupId}/invites`, {
      method: 'POST',
      headers: headers(creator.jwt),
      body: JSON.stringify({}),
    });
    const { code } = await mint.json<any>();

    const ok = await SELF.fetch(`${BASE}/api/groups/join`, {
      method: 'POST',
      headers: headers(first.jwt),
      body: JSON.stringify({ code }),
    });
    expect(ok.status).toBe(200);

    const used = await SELF.fetch(`${BASE}/api/groups/join`, {
      method: 'POST',
      headers: headers(second.jwt),
      body: JSON.stringify({ code }),
    });
    expect(used.status).toBe(410);

    // second is NOT in the group.
    const detail = await (
      await SELF.fetch(`${BASE}/api/groups/${groupId}`, { headers: headers(creator.jwt) })
    ).json<any>();
    expect(detail.members.find((m: any) => m.user_id === second.id)).toBeUndefined();
  });

  it('expired invite returns 410 and is NOT consumed', async () => {
    const { creator, groupId } = await freshGroup('inv-exp');
    const joiner = await makeUser('inv-exp-joiner');

    // Mint with an explicit past expiry.
    const mint = await SELF.fetch(`${BASE}/api/groups/${groupId}/invites`, {
      method: 'POST',
      headers: headers(creator.jwt),
      body: JSON.stringify({ expires_at: Date.now() - 1000 }),
    });
    expect(mint.status).toBe(201);
    const { code } = await mint.json<any>();

    const join = await SELF.fetch(`${BASE}/api/groups/join`, {
      method: 'POST',
      headers: headers(joiner.jwt),
      body: JSON.stringify({ code }),
    });
    expect(join.status).toBe(410);

    // Code still NOT marked used (expired != consumed; could be re-issued).
    const inv = await env.DB
      .prepare('SELECT * FROM group_invites WHERE code = ?1')
      .bind(code)
      .first<any>();
    expect(inv.used_at).toBeNull();
  });

  it('unknown code -> 404, malformed body -> 400', async () => {
    const a = await devJwt();
    const r1 = await SELF.fetch(`${BASE}/api/groups/join`, {
      method: 'POST',
      headers: headers(a.jwt),
      body: JSON.stringify({ code: 'ZZZZZZ' }),
    });
    expect(r1.status).toBe(404);
    const r2 = await SELF.fetch(`${BASE}/api/groups/join`, {
      method: 'POST',
      headers: headers(a.jwt),
      body: JSON.stringify({}),
    });
    expect(r2.status).toBe(400);
  });

  it('already-a-member redemption returns 409 and code is NOT consumed', async () => {
    const { creator, groupId } = await freshGroup('inv-already');
    // Creator is already a member of the group they own — try redeeming
    // a code minted for that same group.
    const mint = await SELF.fetch(`${BASE}/api/groups/${groupId}/invites`, {
      method: 'POST',
      headers: headers(creator.jwt),
      body: JSON.stringify({}),
    });
    const { code } = await mint.json<any>();
    const join = await SELF.fetch(`${BASE}/api/groups/join`, {
      method: 'POST',
      headers: headers(creator.jwt),
      body: JSON.stringify({ code }),
    });
    expect(join.status).toBe(409);
    const body = await join.json<any>();
    expect(body.error).toBe('already_member');

    // Code is intact — a different user can still redeem it.
    const inv = await env.DB
      .prepare('SELECT * FROM group_invites WHERE code = ?1')
      .bind(code)
      .first<any>();
    expect(inv.used_at).toBeNull();

    const other = await makeUser('inv-already-other');
    const join2 = await SELF.fetch(`${BASE}/api/groups/join`, {
      method: 'POST',
      headers: headers(other.jwt),
      body: JSON.stringify({ code }),
    });
    expect(join2.status).toBe(200);
  });

  it('expires_at: null mints a never-expiring code', async () => {
    const { creator, groupId } = await freshGroup('inv-forever');
    const r = await SELF.fetch(`${BASE}/api/groups/${groupId}/invites`, {
      method: 'POST',
      headers: headers(creator.jwt),
      body: JSON.stringify({ expires_at: null }),
    });
    expect(r.status).toBe(201);
    const inv = await r.json<any>();
    expect(inv.expires_at).toBeNull();
  });
});

describe('groups membership: leave + display_name override', () => {
  async function joined(label: string): Promise<{
    creator: { id: string; jwt: string };
    joiner: { id: string; jwt: string };
    groupId: string;
    code: string;
  }> {
    const creator = await makeUser(`${label}-c`);
    const joiner = await makeUser(`${label}-j`);
    const g = await (
      await SELF.fetch(`${BASE}/api/groups`, {
        method: 'POST',
        headers: headers(creator.jwt),
        body: JSON.stringify({ name: label }),
      })
    ).json<any>();
    const inv = await (
      await SELF.fetch(`${BASE}/api/groups/${g.id}/invites`, {
        method: 'POST',
        headers: headers(creator.jwt),
        body: JSON.stringify({}),
      })
    ).json<any>();
    await SELF.fetch(`${BASE}/api/groups/join`, {
      method: 'POST',
      headers: headers(joiner.jwt),
      body: JSON.stringify({ code: inv.code }),
    });
    return { creator, joiner, groupId: g.id, code: inv.code };
  }

  it('DELETE /api/groups/:id/members/me removes membership and is idempotent', async () => {
    const { joiner, groupId } = await joined('leave');

    const d1 = await SELF.fetch(`${BASE}/api/groups/${groupId}/members/me`, {
      method: 'DELETE',
      headers: headers(joiner.jwt),
    });
    expect(d1.status).toBe(200);
    const body1 = await d1.json<any>();
    expect(body1.removed).toBe(true);

    // No longer a member.
    const after = await SELF.fetch(`${BASE}/api/groups/${groupId}`, {
      headers: headers(joiner.jwt),
    });
    expect(after.status).toBe(403);

    // Second DELETE -> still 200 (idempotent); removed=false.
    const d2 = await SELF.fetch(`${BASE}/api/groups/${groupId}/members/me`, {
      method: 'DELETE',
      headers: headers(joiner.jwt),
    });
    expect(d2.status).toBe(200);
    const body2 = await d2.json<any>();
    expect(body2.removed).toBe(false);

    // leave_group audit landed once (only on the first, successful delete).
    const audits = await env.DB
      .prepare(
        "SELECT COUNT(*) AS c FROM audit_log WHERE tool = 'leave_group' AND user_id = ?1",
      )
      .bind(joiner.id)
      .first<{ c: number }>();
    expect(audits?.c).toBe(1);
  });

  it('PATCH /api/groups/:id/members/me sets/clears the per-group nickname', async () => {
    const { joiner, groupId } = await joined('rename');

    // Set the override.
    const set = await SELF.fetch(`${BASE}/api/groups/${groupId}/members/me`, {
      method: 'PATCH',
      headers: headers(joiner.jwt),
      body: JSON.stringify({ display_name: 'Speedy' }),
    });
    expect(set.status).toBe(200);
    const detail = await set.json<any>();
    const me = detail.members.find((m: any) => m.user_id === joiner.id);
    expect(me.display_name).toBe('Speedy');
    expect(me.effective_display_name).toBe('Speedy');

    // Clear back to fallback (users.display_name) via null.
    const clear = await SELF.fetch(`${BASE}/api/groups/${groupId}/members/me`, {
      method: 'PATCH',
      headers: headers(joiner.jwt),
      body: JSON.stringify({ display_name: null }),
    });
    expect(clear.status).toBe(200);
    const cleared = await clear.json<any>();
    const me2 = cleared.members.find((m: any) => m.user_id === joiner.id);
    expect(me2.display_name).toBeNull();
    // joiner's underlying users.display_name was set when we INSERTed them
    // (makeUser sets display_name = label, so the joiner is "rename-j").
    expect(me2.effective_display_name).toBe('rename-j');
  });

  it('PATCH /api/groups/:id/members/me 403s for non-members', async () => {
    const { groupId } = await joined('rename-stranger');
    const stranger = await makeUser('rename-outsider');
    const r = await SELF.fetch(`${BASE}/api/groups/${groupId}/members/me`, {
      method: 'PATCH',
      headers: headers(stranger.jwt),
      body: JSON.stringify({ display_name: 'NopeNope' }),
    });
    expect(r.status).toBe(403);
  });
});
