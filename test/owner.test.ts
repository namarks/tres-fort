import { env, applyD1Migrations } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { claimOrCreateOwner, createPlan, ensureOwnerUser } from '../src/db';

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
