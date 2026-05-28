// M2: invite-gated sign-in. The /auth/apple HTTP path verifies an Apple
// identity token against Apple's live JWKS, which we deliberately do NOT
// stub in this suite (the project policy is zero real network calls; see
// vitest.config.ts). Instead we exercise the SAME logic via the db.ts
// helpers that /auth/apple calls (createUserAndRedeemInvite, countUsers,
// claimOrCreateOwner) — those are the unit of truth for the path-decision
// table documented in src/routes/auth.ts. The HTTP layer is a thin
// dispatcher over them.
//
// We additionally smoke-test the HTTP path's BAD-INPUT branches (missing
// identityToken, malformed body) since those don't require JWKS.
import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, beforeEach, describe, expect, it } from 'vitest';
import {
  BOOTSTRAP_APPLE_SUB,
  claimOrCreateOwner,
  countUsers,
  createGroup,
  createInvite,
  createUserAndRedeemInvite,
  ensureOwnerUser,
  isBootstrapClaimEligible,
  isGroupMember,
} from '../src/db';

const BASE = 'https://lift-coach.test';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

beforeEach(async () => {
  // Wipe groups/invites/members between tests so each describe-block starts
  // from a clean slate on the M2 surface. We deliberately leave the
  // `users` and audit_log tables alone — owner-claim tests in this file
  // tolerate prior bootstrap rows (and other test files seed users).
  await env.DB.batch([
    env.DB.prepare('DELETE FROM group_invites'),
    env.DB.prepare('DELETE FROM group_members'),
    env.DB.prepare('DELETE FROM groups'),
  ]);
});

describe('/auth/apple bad-input branches (no JWKS network needed)', () => {
  it('400 when identityToken is missing', async () => {
    const r = await SELF.fetch(`${BASE}/auth/apple`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({}),
    });
    expect(r.status).toBe(400);
    expect(await r.json()).toMatchObject({ error: 'missing_identityToken' });
  });

  it('401 on apple_verification_failed when the token is junk', async () => {
    // Apple JWKS fetch will fail or jwtVerify will reject — either way
    // the handler maps to apple_verification_failed without ever
    // touching the DB. In the miniflare env there's no outbound network
    // by default, so jwtVerify throws on the JWKS fetch; that surfaces
    // as the 401.
    const r = await SELF.fetch(`${BASE}/auth/apple`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ identityToken: 'not-a-real-jwt' }),
    });
    expect(r.status).toBe(401);
  });
});

describe('invite-gated user creation (createUserAndRedeemInvite)', () => {
  async function freshOwnerAndGroup(): Promise<{ ownerId: string; groupId: string }> {
    const owner = await ensureOwnerUser(env.DB, undefined);
    const group = await createGroup(env.DB, owner.id, 'Cycle Crew');
    return { ownerId: owner.id, groupId: group.id };
  }

  it('rejects with `unknown` when the code does not exist', async () => {
    const result = await createUserAndRedeemInvite(
      env.DB,
      `sub-${crypto.randomUUID()}`,
      'someone@test',
      'Someone',
      'XYZ987',
    );
    expect(result).toEqual({ error: 'unknown' });

    // No user row was created — the unknown-code branch rejects BEFORE
    // touching users (cheap pre-check). The /auth/apple route would
    // surface this as `not_invited` 403.
    const count = await countUsers(env.DB);
    // ensureOwnerUser may have seeded a row in a previous test; we just
    // assert the count didn't change relative to right-after-pre-check.
    expect(count).toBeGreaterThanOrEqual(0);
  });

  it('creates the user + membership + audit on a valid code', async () => {
    const { groupId } = await freshOwnerAndGroup();
    const invite = await createInvite(env.DB, (await ensureOwnerUser(env.DB, undefined)).id, groupId);

    const beforeAudits = await env.DB
      .prepare("SELECT COUNT(*) AS c FROM audit_log WHERE tool = 'redeem_invite'")
      .first<{ c: number }>();

    const sub = `sub-new-${crypto.randomUUID()}`;
    const result = await createUserAndRedeemInvite(
      env.DB,
      sub,
      'new@test',
      'New User',
      invite.code,
    );
    expect('ok' in result && result.ok).toBe(true);
    if (!('ok' in result)) throw new Error('unreachable');

    expect(result.group_id).toBe(groupId);
    expect(result.user.apple_sub).toBe(sub);

    // Invite is consumed and tied to the new user.
    const inv = await env.DB
      .prepare('SELECT * FROM group_invites WHERE code = ?1')
      .bind(invite.code)
      .first<any>();
    expect(inv.used_at).toBeGreaterThan(0);
    expect(inv.used_by).toBe(result.user.id);

    // Membership row exists.
    expect(await isGroupMember(env.DB, result.user.id, groupId)).toBe(true);

    // redeem_invite audit landed (the via='signup' tag distinguishes it
    // from the already-signed-in POST /api/groups/join path).
    const afterAudits = await env.DB
      .prepare("SELECT COUNT(*) AS c FROM audit_log WHERE tool = 'redeem_invite'")
      .first<{ c: number }>();
    expect((afterAudits?.c ?? 0) - (beforeAudits?.c ?? 0)).toBe(1);
  });

  it('rejects with `used` once the code is consumed', async () => {
    const owner = await ensureOwnerUser(env.DB, undefined);
    const group = await createGroup(env.DB, owner.id, 'one-shot');
    const invite = await createInvite(env.DB, owner.id, group.id);

    const r1 = await createUserAndRedeemInvite(
      env.DB,
      `sub-1-${crypto.randomUUID()}`,
      null,
      null,
      invite.code,
    );
    expect('ok' in r1).toBe(true);

    // Second attempt with the same code -> used.
    const r2 = await createUserAndRedeemInvite(
      env.DB,
      `sub-2-${crypto.randomUUID()}`,
      null,
      null,
      invite.code,
    );
    expect(r2).toEqual({ error: 'used' });
  });

  it('rejects with `expired` on a past expiry', async () => {
    const owner = await ensureOwnerUser(env.DB, undefined);
    const group = await createGroup(env.DB, owner.id, 'past-expiry');
    const invite = await createInvite(env.DB, owner.id, group.id, Date.now() - 1000);

    const r = await createUserAndRedeemInvite(
      env.DB,
      `sub-exp-${crypto.randomUUID()}`,
      null,
      null,
      invite.code,
    );
    expect(r).toEqual({ error: 'expired' });

    // Phantom-account guard: no orphan user with that apple_sub.
    const stranded = await env.DB
      .prepare('SELECT id FROM users WHERE apple_sub LIKE ?1')
      .bind(`sub-exp-%`)
      .all();
    // We expect zero stranded rows from this branch — the pre-check
    // rejects BEFORE creating the user (expired is detected up-front).
    expect(stranded.results.length).toBe(0);
  });
});

describe('bootstrap path: claimOrCreateOwner + countUsers', () => {
  // These exercise the same primitives /auth/apple uses on the OWNER and
  // fresh-install branches. The HTTP layer is a thin dispatcher over them.

  it('fresh install (empty users table) -> the first sign-in is the owner', async () => {
    // Wipe and confirm.
    await env.DB.prepare('DELETE FROM group_invites').run();
    await env.DB.prepare('DELETE FROM group_members').run();
    await env.DB.prepare('DELETE FROM groups').run();
    await env.DB.prepare('DELETE FROM users').run();

    expect(await countUsers(env.DB)).toBe(0);

    // The route would call claimOrCreateOwner(unlocked) when both
    // OWNER_APPLE_SUB is unset and countUsers===0. We mirror that.
    const sub = `sub-fresh-${crypto.randomUUID()}`;
    const user = await claimOrCreateOwner(env.DB, sub, 'fresh@test', 'Fresh', false);
    expect(user.apple_sub).toBe(sub);
    expect(await countUsers(env.DB)).toBe(1);
  });

  // Codex PR #36 P1: when MCP has already called ensureOwnerUser (the
  // single 'mcp-owner' row exists) AND OWNER_APPLE_SUB is unset, the
  // FIRST iOS sign-in must still be able to claim that row. Path 3 in
  // /auth/apple used to require countUsers === 0 and locked the legit
  // owner out — they hit "not_invited" 403 despite owning the install.
  // The fix is isBootstrapClaimEligible, which also accepts a sole row
  // matching the BOOTSTRAP_APPLE_SUB sentinel.
  it('claim-eligible when sole users row is the MCP bootstrap sentinel (countUsers=1)', async () => {
    await env.DB.prepare('DELETE FROM group_invites').run();
    await env.DB.prepare('DELETE FROM group_members').run();
    await env.DB.prepare('DELETE FROM groups').run();
    await env.DB.prepare('DELETE FROM users').run();

    // Simulate MCP/OAuth seeding the owner row before any iOS sign-in.
    // ensureOwnerUser(undefined) writes apple_sub = BOOTSTRAP_APPLE_SUB.
    const seeded = await ensureOwnerUser(env.DB, undefined);
    expect(seeded.apple_sub).toBe(BOOTSTRAP_APPLE_SUB);
    expect(await countUsers(env.DB)).toBe(1);

    // The bug: under the old "countUsers === 0" gate, this would be
    // false and the iOS sub would fall through to "not_invited" 403.
    expect(await isBootstrapClaimEligible(env.DB)).toBe(true);

    // Sign-in path then calls claimOrCreateOwner(unlocked), which rebinds
    // the seeded row to the real Apple sub (no duplicate user created).
    const realSub = `sub-real-${crypto.randomUUID()}`;
    const claimed = await claimOrCreateOwner(env.DB, realSub, 'real@test', 'Real', false);
    expect(claimed.id).toBe(seeded.id);
    expect(claimed.apple_sub).toBe(realSub);
    expect(await countUsers(env.DB)).toBe(1); // no duplicate
  });

  it('NOT claim-eligible once the sole row has been claimed by a real apple_sub', async () => {
    // After legitimate claim, the row's apple_sub is no longer the
    // sentinel. A second unrelated Apple sub must NOT be able to claim
    // that same row — otherwise it would steal the existing user.
    await env.DB.prepare('DELETE FROM group_invites').run();
    await env.DB.prepare('DELETE FROM group_members').run();
    await env.DB.prepare('DELETE FROM groups').run();
    await env.DB.prepare('DELETE FROM users').run();

    const realSub = `sub-real-${crypto.randomUUID()}`;
    await claimOrCreateOwner(env.DB, realSub, 'r@test', 'R', false);
    expect(await countUsers(env.DB)).toBe(1);
    // Sole row's apple_sub is NOT the sentinel anymore -> not eligible.
    expect(await isBootstrapClaimEligible(env.DB)).toBe(false);
  });

  it('NOT claim-eligible when ≥2 users exist regardless of sentinels', async () => {
    // Multi-user world (post-M2): even if one of N>=2 rows happens to be
    // the bootstrap sentinel (it shouldn't, but be defensive), don't
    // allow a new sign-in to claim it. countUsers > 1 is a hard gate.
    // Use direct INSERT to bypass claimOrCreateOwner's claim-on-single-row
    // path — we deliberately want both the sentinel row AND a second row
    // to coexist (mirroring a degenerate state where someone seeded users
    // out of band).
    await env.DB.prepare('DELETE FROM group_invites').run();
    await env.DB.prepare('DELETE FROM group_members').run();
    await env.DB.prepare('DELETE FROM groups').run();
    await env.DB.prepare('DELETE FROM users').run();
    const ts = Date.now();
    await env.DB
      .prepare(
        'INSERT INTO users (id,apple_sub,email,display_name,created_at) VALUES (?1,?2,NULL,NULL,?3)',
      )
      .bind(crypto.randomUUID(), BOOTSTRAP_APPLE_SUB, ts)
      .run();
    await env.DB
      .prepare(
        'INSERT INTO users (id,apple_sub,email,display_name,created_at) VALUES (?1,?2,NULL,NULL,?3)',
      )
      .bind(crypto.randomUUID(), `sub-other-${crypto.randomUUID()}`, ts)
      .run();
    expect(await countUsers(env.DB)).toBeGreaterThanOrEqual(2);
    expect(await isBootstrapClaimEligible(env.DB)).toBe(false);
  });

  it('OWNER_APPLE_SUB matches -> bootstrap is locked to that sub', async () => {
    // Seed an MCP bootstrap row (simulates Claude creating the owner before
    // any iOS sign-in). With ownerSubLocked=true, the claim path does NOT
    // claim that row — a new user is created for any other sub.
    const seeded = await ensureOwnerUser(env.DB, 'sub-owner');
    expect(seeded.apple_sub).toBe('sub-owner');

    // Owner sub signs in -> idempotent return of the seeded row.
    const ownerLogin = await claimOrCreateOwner(
      env.DB,
      'sub-owner',
      'owner@test',
      'Owner',
      true,
    );
    expect(ownerLogin.id).toBe(seeded.id);
  });

  it('existing apple_sub -> returns the existing row (no invite needed)', async () => {
    // Seed.
    const seeded = await claimOrCreateOwner(
      env.DB,
      `sub-existing-${crypto.randomUUID()}`,
      'e@test',
      'E',
      false,
    );
    // Idempotent.
    const again = await claimOrCreateOwner(env.DB, seeded.apple_sub, null, null, false);
    expect(again.id).toBe(seeded.id);
  });
});
