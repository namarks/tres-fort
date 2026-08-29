// Open sign-in path. /auth/apple verifies an Apple identity token against
// Apple's live JWKS, which we deliberately do NOT stub here (the project
// policy is zero real network calls; see vitest.config.ts). So this file
// exercises the SAME logic via the db.ts helpers /auth/apple calls
// (upsertUser, claimOrCreateOwner, isBootstrapClaimEligible) — those are
// the unit of truth for the path-decision table documented in
// src/routes/auth.ts. The HTTP layer is a thin dispatcher over them.
//
// We additionally smoke-test the HTTP path's BAD-INPUT branches (missing
// identityToken, malformed body) since those don't require JWKS.
//
// Note: there is NO invite-code-on-signin path anymore — the prior
// `createUserAndRedeemInvite` shortcut was removed because it created an
// existing-user vs new-user asymmetry that silently dropped codes on
// repeat sign-ins. Invite redemption now lives exclusively in
// POST /api/groups/join (see groups.test.ts).
import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, beforeEach, describe, expect, it } from 'vitest';
import {
  BOOTSTRAP_APPLE_SUB,
  claimOrCreateOwner,
  countUsers,
  createGroup,
  createInvite,
  ensureOwnerUser,
  isBootstrapClaimEligible,
  isGroupMember,
  redeemInvite,
  upsertUser,
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

// Codex PR#38 P2: /auth/apple Path 4 now also redeems a supplied
// `invite_code` best-effort so build 12 and earlier iOS clients (which
// still post the field from the old "Have an invite code?" reveal) keep
// landing in the inviter's group instead of "signed in but never
// joined." Failure does NOT block sign-in — new clients send no code
// and skip the redemption step entirely. This describe-block walks the
// SAME db primitives /auth/apple invokes (upsertUser then redeemInvite),
// proving the back-compat sequence is well-behaved at all branches.
describe('Path 4 back-compat: legacy invite_code shim (Codex PR#38 P2)', () => {
  it('valid code → user created, joined to inviter\'s group, group_id returned', async () => {
    const owner = (await ensureOwnerUser(env.DB, undefined))!;
    const group = await createGroup(env.DB, owner.id, 'BackCompat');
    const invite = await createInvite(env.DB, owner.id, group.id);

    const sub = `legacy-${crypto.randomUUID()}`;
    const user = await upsertUser(env.DB, sub, 'legacy@test', 'Legacy');
    const r = await redeemInvite(env.DB, invite.code, user.id);
    expect('ok' in r && r.ok).toBe(true);
    if (!('ok' in r)) throw new Error('unreachable');
    expect(r.group_id).toBe(group.id);

    // Membership row exists; legacy iOS reads group_id from AuthResponse
    // and pre-selects the joined group on first open.
    expect(await isGroupMember(env.DB, user.id, group.id)).toBe(true);

    // Code is consumed; not reusable.
    const inv = await env.DB
      .prepare('SELECT used_at FROM group_invites WHERE code = ?1')
      .bind(invite.code)
      .first<{ used_at: number | null }>();
    expect(inv!.used_at).not.toBeNull();
  });

  it('bad code → user STILL signed in (sign-in is not blocked)', async () => {
    const sub = `bad-${crypto.randomUUID()}`;
    const user = await upsertUser(env.DB, sub, null, null);
    // The Path 4 contract: redeemInvite failure is swallowed; user is
    // already created above, the JWT path would proceed unchanged.
    const r = await redeemInvite(env.DB, 'NOSUCH', user.id);
    expect(r).toEqual({ error: 'unknown' });

    // User row persists — they're signed in, just without auto-join.
    // They can paste a fresh code from the in-app Group tab.
    const stillThere = await env.DB
      .prepare('SELECT id FROM users WHERE apple_sub = ?1')
      .bind(sub)
      .first<{ id: string }>();
    expect(stillThere?.id).toBe(user.id);
  });

  it('expired code → user STILL signed in, code stays unused', async () => {
    const owner = (await ensureOwnerUser(env.DB, undefined))!;
    const group = await createGroup(env.DB, owner.id, 'Stale');
    const invite = await createInvite(env.DB, owner.id, group.id, Date.now() - 1000);

    const sub = `exp-${crypto.randomUUID()}`;
    const user = await upsertUser(env.DB, sub, null, null);
    const r = await redeemInvite(env.DB, invite.code, user.id);
    expect(r).toEqual({ error: 'expired' });

    // No membership formed; the legacy code stays unused (caller didn't
    // burn it on a failed attempt).
    expect(await isGroupMember(env.DB, user.id, group.id)).toBe(false);
    const inv = await env.DB
      .prepare('SELECT used_at FROM group_invites WHERE code = ?1')
      .bind(invite.code)
      .first<{ used_at: number | null }>();
    expect(inv!.used_at).toBeNull();
  });
});

// /auth/apple Path 4 is open sign-in: any new Apple sub creates an
// account with zero group memberships. Groups themselves remain
// invite-only — the user creates a group or redeems an invite from the
// iOS Group tab post-sign-in (POST /api/groups, POST /api/groups/join).
// This describe-block exercises the underlying
// primitive `upsertUser` that Path 4 now calls on the no-code branch.
describe('open sign-in path (Path 4 without invite_code)', () => {
  it('upsertUser INSERTs a fresh user with NO group memberships', async () => {
    await env.DB.prepare('DELETE FROM group_invites').run();
    await env.DB.prepare('DELETE FROM group_members').run();
    await env.DB.prepare('DELETE FROM groups').run();
    await env.DB.prepare('DELETE FROM users').run();

    const sub = `sub-open-${crypto.randomUUID()}`;
    const user = await upsertUser(env.DB, sub, 'open@test', 'Open Signer');
    expect(user.apple_sub).toBe(sub);
    expect(user.id).toMatch(/^[0-9a-f-]{36}$/);

    // Crucially: no memberships were created. Open sign-in does NOT
    // auto-enroll a user in any group — that's the invariant that keeps
    // groups invite-only even after we opened up account creation.
    const memberships = await env.DB
      .prepare('SELECT COUNT(*) AS c FROM group_members WHERE user_id = ?1')
      .bind(user.id)
      .first<{ c: number }>();
    expect(memberships!.c).toBe(0);
  });

  it('upsertUser is idempotent on a re-seen apple_sub (matches Path 1)', async () => {
    // Path 1 short-circuits known subs in the route; this exists as a
    // belt-and-suspenders check that upsertUser would also be safe even
    // if Path 1 were ever bypassed.
    const sub = `sub-rep-${crypto.randomUUID()}`;
    const first = await upsertUser(env.DB, sub, 'rep@test', 'Rep');
    const second = await upsertUser(env.DB, sub, 'rep@test', 'Rep');
    expect(second.id).toBe(first.id);
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
    const user = (await claimOrCreateOwner(env.DB, sub, 'fresh@test', 'Fresh', false))!;
    expect(user.apple_sub).toBe(sub);
    expect(await countUsers(env.DB)).toBe(1);
  });

  // Codex PR #36 P1: when MCP has already called ensureOwnerUser (the
  // single 'mcp-owner' row exists) AND OWNER_APPLE_SUB is unset, the
  // FIRST iOS sign-in must still be able to claim that row. Path 3 in
  // /auth/apple used to require countUsers === 0 and locked the legit
  // owner out — they fall through to Path 4 (open sign-in) and create a
  // SECOND user row, when claimOrCreateOwner is built to rebind the seed.
  // The fix is isBootstrapClaimEligible, which also accepts a sole row
  // matching the BOOTSTRAP_APPLE_SUB sentinel.
  it('claim-eligible when sole users row is the MCP bootstrap sentinel (countUsers=1)', async () => {
    await env.DB.prepare('DELETE FROM group_invites').run();
    await env.DB.prepare('DELETE FROM group_members').run();
    await env.DB.prepare('DELETE FROM groups').run();
    await env.DB.prepare('DELETE FROM users').run();

    // Simulate MCP/OAuth seeding the owner row before any iOS sign-in.
    // ensureOwnerUser(undefined) writes apple_sub = BOOTSTRAP_APPLE_SUB.
    const seeded = (await ensureOwnerUser(env.DB, undefined))!;
    expect(seeded.apple_sub).toBe(BOOTSTRAP_APPLE_SUB);
    expect(await countUsers(env.DB)).toBe(1);

    // The bug: under the old "countUsers === 0" gate, this would be
    // false and the iOS sub would fall through to Path 4 (open sign-in)
    // and create a phantom second user row alongside the bootstrap row.
    expect(await isBootstrapClaimEligible(env.DB)).toBe(true);

    // Sign-in path then calls claimOrCreateOwner(unlocked), which rebinds
    // the seeded row to the real Apple sub (no duplicate user created).
    const realSub = `sub-real-${crypto.randomUUID()}`;
    const claimed = (await claimOrCreateOwner(env.DB, realSub, 'real@test', 'Real', false))!;
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
    const seeded = (await ensureOwnerUser(env.DB, 'sub-owner'))!;
    expect(seeded.apple_sub).toBe('sub-owner');

    // Owner sub signs in -> idempotent return of the seeded row.
    const ownerLogin = (await claimOrCreateOwner(
      env.DB,
      'sub-owner',
      'owner@test',
      'Owner',
      true,
    ))!;
    expect(ownerLogin.id).toBe(seeded.id);
  });

  it('existing apple_sub -> returns the existing row (no invite needed)', async () => {
    // Seed.
    const seeded = (await claimOrCreateOwner(
      env.DB,
      `sub-existing-${crypto.randomUUID()}`,
      'e@test',
      'E',
      false,
    ))!;
    // Idempotent.
    const again = (await claimOrCreateOwner(env.DB, seeded.apple_sub, null, null, false))!;
    expect(again.id).toBe(seeded.id);
  });
});
