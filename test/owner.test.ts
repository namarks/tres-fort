import { env, applyD1Migrations } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import {
  claimOrCreateOwner,
  createPlan,
  ensureOwnerUser,
  findOwnerRow,
  upsertUser,
} from '../src/db';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

describe('single-owner claim (MCP bootstrap -> Sign in with Apple)', () => {
  it('claims the MCP bootstrap row so MCP-seeded data stays on one user', async () => {
    // MCP created the owner + a plan before any iOS sign-in.
    const boot = await ensureOwnerUser(env.DB, undefined);
    await createPlan(env.DB, boot.id, 'Starter');

    // First Sign in with Apple (owner not locked) claims that same row.
    const claimed = await claimOrCreateOwner(env.DB, 'apple-sub-real', 'me@x.com', 'Me', false);
    expect(claimed.id).toBe(boot.id);
    expect(claimed.apple_sub).toBe('apple-sub-real');

    const users = await env.DB.prepare('SELECT COUNT(*) AS c FROM users').first<{ c: number }>();
    expect(users!.c).toBe(1); // no duplicate user

    const plan = await env.DB
      .prepare('SELECT user_id FROM plans WHERE user_id = ?1')
      .bind(boot.id)
      .first();
    expect(plan).not.toBeNull(); // seeded plan preserved under the claimed id

    // Idempotent: same Apple sub returns the same user.
    const again = await claimOrCreateOwner(env.DB, 'apple-sub-real', null, null, false);
    expect(again.id).toBe(boot.id);
  });

  it('does not silently claim when the owner is locked', async () => {
    await ensureOwnerUser(env.DB, undefined); // one bootstrap user
    const created = await claimOrCreateOwner(env.DB, 'other-sub', null, null, true);
    const users = await env.DB.prepare('SELECT COUNT(*) AS c FROM users').first<{ c: number }>();
    expect(users!.c).toBe(2); // locked -> new user, not a claim
    expect(created.apple_sub).toBe('other-sub');
  });
});

// Codex PR #38 P1: open sign-in (Path 4 of /auth/apple) can insert a
// non-owner user before the configured OWNER_APPLE_SUB owner has signed
// in or been MCP-seeded. The pre-fix `ensureOwnerUser` ran
// `SELECT * FROM users ORDER BY created_at LIMIT 1` and would hand the
// reviewer's row to MCP as the "owner," attributing Claude's plan and
// intervals creds to the wrong user. Fix: when OWNER_APPLE_SUB is set,
// findOwnerRow looks up by apple_sub specifically.
describe('open sign-in does not capture owner state (Codex PR#38 P1)', () => {
  it('ensureOwnerUser with OWNER_APPLE_SUB ignores an earlier non-owner row', async () => {
    await env.DB.prepare('DELETE FROM users').run();

    // Simulate: a reviewer / random new user signed in via Path 4 BEFORE
    // the owner or MCP touched the system. upsertUser is the same primitive
    // Path 4 invokes, so this mirrors the production scenario.
    const reviewerSub = `reviewer-${crypto.randomUUID()}`;
    const reviewer = await upsertUser(env.DB, reviewerSub, 'reviewer@test', 'Reviewer');
    expect(reviewer.apple_sub).toBe(reviewerSub);

    // Pre-fix: ensureOwnerUser returns the reviewer row (earliest by
    // created_at). Post-fix: it CREATES the owner row under OWNER_APPLE_SUB.
    const owner = await ensureOwnerUser(env.DB, 'configured-owner-sub');
    expect(owner.apple_sub).toBe('configured-owner-sub');
    expect(owner.id).not.toBe(reviewer.id);

    // Both rows now coexist; the reviewer is NOT mistaken for the owner.
    const count = await env.DB.prepare('SELECT COUNT(*) AS c FROM users').first<{ c: number }>();
    expect(count!.c).toBe(2);
  });

  it('findOwnerRow returns null when OWNER_APPLE_SUB owner row does not exist yet', async () => {
    await env.DB.prepare('DELETE FROM users').run();
    await upsertUser(env.DB, 'random-1', null, null);
    await upsertUser(env.DB, 'random-2', null, null);

    // With OWNER_APPLE_SUB set, "earliest user" semantics are deliberately
    // NOT used — findOwnerRow returns null until the configured owner sub
    // actually exists, so callers can choose whether to seed (ensureOwnerUser
    // does) or no-op (seedOwnerIntervalsCredsFromEnv does).
    const missing = await findOwnerRow(env.DB, 'never-seen-owner');
    expect(missing).toBeNull();

    // Once the owner does sign in / get seeded, findOwnerRow returns them.
    const seeded = await upsertUser(env.DB, 'never-seen-owner', null, 'Owner');
    const found = await findOwnerRow(env.DB, 'never-seen-owner');
    expect(found?.id).toBe(seeded.id);
  });

  it('findOwnerRow falls back to earliest-by-created_at when OWNER_APPLE_SUB unset', async () => {
    await env.DB.prepare('DELETE FROM users').run();
    const first = await upsertUser(env.DB, 'first-sub', null, null);
    await upsertUser(env.DB, 'second-sub', null, null);

    // Without OWNER_APPLE_SUB the earliest-by-created_at semantic is the
    // intended one (Path 3 of /auth/apple is the only path that creates
    // users without an explicit allowlist, and it always installs the
    // first signer as owner).
    const found = await findOwnerRow(env.DB, undefined);
    expect(found?.id).toBe(first.id);
  });
});
