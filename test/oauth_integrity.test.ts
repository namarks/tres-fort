import { oauthTokenDigest } from '../src/credentials';
import { applyD1Migrations, env, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { issueAppJwt } from '../src/auth';
import {
  activateOAuthGrantLifecyclePolicy,
  listOAuthGrants,
  OAUTH_GRANT_ABSOLUTE_MS,
  OAUTH_GRANT_INACTIVITY_MS,
  redeemOAuthAuthorizationCode,
  refreshOAuthGrant,
  rotateOAuthRefreshToken,
} from '../src/db';
import { validateBearer } from '../src/oauth';

const BASE = 'https://tres-fort.test';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

async function challenge(verifier: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier));
  return btoa(String.fromCharCode(...new Uint8Array(digest)))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

async function hexDigest(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('');
}

async function seedCode(options: { expired?: boolean; userId?: string; clientId?: string } = {}) {
  const suffix = crypto.randomUUID();
  const userId = options.userId ?? `oauth-user-${suffix}`;
  const clientId = options.clientId ?? `oauth-client-${suffix}`;
  const code = `oauth-code-${suffix}`;
  const verifier = `oauth-verifier-${suffix}`;
  const redirect = `https://client.example/${suffix}`;
  const now = Date.now();
  await env.DB.batch([
    env.DB.prepare(
      `INSERT OR IGNORE INTO users (id, apple_sub, display_name, created_at)
       VALUES (?1, ?2, 'OAuth test', ?3)`,
    ).bind(userId, `oauth-sub-${userId}`, now),
    env.DB.prepare(
      `INSERT OR IGNORE INTO oauth_clients
         (client_id, client_secret, redirect_uris, client_name, created_at)
       VALUES (?1, NULL, ?2, 'OAuth integrity', ?3)`,
    ).bind(clientId, JSON.stringify([redirect]), now),
    env.DB.prepare(
      `INSERT INTO oauth_codes
         (code, client_id, redirect_uri, code_challenge, code_challenge_method,
          scope, resource, expires_at, created_at, user_id)
       VALUES (?1, ?2, ?3, ?4, 'S256', 'mcp', NULL, ?5, ?6, ?7)`,
    ).bind(code, clientId, redirect, await challenge(verifier), options.expired ? now - 1 : now + 60_000, now, userId),
  ]);
  return { code, verifier, redirect, clientId, userId, createdAt: now };
}

function codeRequest(grant: Awaited<ReturnType<typeof seedCode>>, overrides: Record<string, string> = {}) {
  const form = new FormData();
  form.set('grant_type', 'authorization_code');
  form.set('code', grant.code);
  form.set('client_id', grant.clientId);
  form.set('redirect_uri', grant.redirect);
  form.set('code_verifier', grant.verifier);
  for (const [key, value] of Object.entries(overrides)) form.set(key, value);
  return SELF.fetch(`${BASE}/oauth/token`, { method: 'POST', body: form });
}

async function seedRefresh(options: { expired?: boolean; userId?: string } = {}) {
  const suffix = crypto.randomUUID();
  const userId = options.userId ?? `refresh-user-${suffix}`;
  const clientId = `refresh-client-${suffix}`;
  const refresh = `refresh-${suffix}`;
  const access = `access-${suffix}`;
  const now = Math.floor(Date.now() / 1000);
  await env.DB.batch([
    env.DB.prepare(
      `INSERT OR IGNORE INTO users (id, apple_sub, display_name, created_at)
       VALUES (?1, ?2, 'Refresh test', ?3)`,
    ).bind(userId, `refresh-sub-${userId}`, Date.now()),
    env.DB.prepare(
      `INSERT INTO oauth_tokens
         (access_token, refresh_token, client_id, scope, expires_at, created_at, user_id)
       VALUES (?1, ?2, ?3, 'mcp', ?4, ?5, ?6)`,
    ).bind(access, refresh, clientId, options.expired ? now - 1 : now + 600, now, userId),
  ]);
  return { access, refresh, clientId, userId };
}

function refreshRequest(grant: Awaited<ReturnType<typeof seedRefresh>>, clientId = grant.clientId) {
  const form = new FormData();
  form.set('grant_type', 'refresh_token');
  form.set('refresh_token', grant.refresh);
  form.set('client_id', clientId);
  return SELF.fetch(`${BASE}/oauth/token`, { method: 'POST', body: form });
}

describe('atomic OAuth grant transitions', () => {
  it('allows exactly one concurrent authorization-code redemption', async () => {
    const grant = await seedCode();
    const responses = await Promise.all([codeRequest(grant), codeRequest(grant)]);
    expect(responses.map((response) => response.status).sort()).toEqual([200, 400]);
    expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM oauth_tokens WHERE user_id = ?1')
      .bind(grant.userId).first<{ n: number }>('n')).toBe(1);
  });

  it('allows exactly one concurrent refresh and preserves the grant binding', async () => {
    const grant = await seedRefresh();
    const responses = await Promise.all([refreshRequest(grant), refreshRequest(grant)]);
    expect(responses.map((response) => response.status).sort()).toEqual([200, 400]);
    const row = await env.DB.prepare(
      'SELECT client_id, scope, user_id FROM oauth_tokens WHERE user_id = ?1',
    ).bind(grant.userId).first<{ client_id: string; scope: string; user_id: string }>();
    expect(row).toBeNull();
  });

  it('does not consume a code for a wrong client, verifier, redirect, or expiry', async () => {
    for (const [kind, overrides] of [
      ['client', { client_id: 'wrong-client' }],
      ['verifier', { code_verifier: 'wrong-verifier' }],
      ['redirect', { redirect_uri: 'https://attacker.example/cb' }],
    ] as const) {
      const grant = await seedCode();
      const response = await codeRequest(grant, overrides);
      expect(response.status, kind).toBe(400);
      expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM oauth_codes WHERE code = ?1')
        .bind(grant.code).first<number>('n')).toBe(1);
    }
    const expired = await seedCode({ expired: true });
    expect((await codeRequest(expired)).status).toBe(400);
    expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM oauth_codes WHERE code = ?1')
      .bind(expired.code).first<number>('n')).toBe(1);
  });

  it('keeps the code when successor insertion fails', async () => {
    const grant = await seedCode();
    await env.DB.prepare(
      `CREATE TRIGGER oauth_integrity_fail_insert
       BEFORE INSERT ON oauth_tokens WHEN NEW.client_id = '${grant.clientId}'
       BEGIN SELECT RAISE(ABORT, 'synthetic_insert_failure'); END`,
    ).run();
    try {
      expect((await codeRequest(grant)).status).toBe(500);
      expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM oauth_codes WHERE code = ?1')
        .bind(grant.code).first<number>('n')).toBe(1);
      expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM oauth_tokens WHERE client_id = ?1')
        .bind(grant.clientId).first<number>('n')).toBe(0);
    } finally {
      await env.DB.prepare('DROP TRIGGER oauth_integrity_fail_insert').run();
    }
  });

  it('rejects refresh client mismatch without consuming the grant', async () => {
    const grant = await seedRefresh();
    expect((await refreshRequest(grant, 'wrong-client')).status).toBe(400);
    expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM oauth_tokens WHERE refresh_token = ?1')
      .bind(grant.refresh).first<number>('n')).toBe(1);
  });

  it('continues to refresh after access expiry without choosing a P1 lifetime policy', async () => {
    const grant = await seedRefresh({ expired: true });
    expect((await refreshRequest(grant)).status).toBe(200);
    expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM oauth_tokens WHERE user_id = ?1')
      .bind(grant.userId).first<number>('n')).toBe(1);
  });

  it('fences code redemption and refresh rotation once account deletion starts', async () => {
    const code = await seedCode();
    const refresh = await seedRefresh({ userId: code.userId });
    await env.DB.prepare(
      `INSERT INTO account_deletion_intents
         (user_id, idempotency_key_sha256, apple_revocation, created_at)
       VALUES (?1, 'test-digest', NULL, ?2)`,
    ).bind(code.userId, Date.now()).run();
    expect((await codeRequest(code)).status).toBe(400);
    expect((await refreshRequest(refresh)).status).toBe(400);
    expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM oauth_codes WHERE code = ?1')
      .bind(code.code).first<number>('n')).toBe(1);
    expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM oauth_tokens WHERE refresh_token = ?1')
      .bind(refresh.refresh).first<number>('n')).toBe(1);
  });

  it('does not consume a scoped code when its explicit principal disappeared', async () => {
    const grant = await seedCode();
    await env.DB.prepare('DELETE FROM users WHERE id = ?1').bind(grant.userId).run();
    expect((await codeRequest(grant)).status).toBe(400);
    expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM oauth_codes WHERE code = ?1')
      .bind(grant.code).first<number>('n')).toBe(1);
  });

  it('turns a retry after a lost successful response into invalid_grant', async () => {
    const grant = await seedCode();
    const lost = await codeRequest(grant);
    expect(lost.status).toBe(200);
    // The client never receives the body. Replaying does not disclose the
    // committed successor; reauthorization is the recovery path.
    expect((await codeRequest(grant)).status).toBe(400);
    expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM oauth_tokens WHERE user_id = ?1')
      .bind(grant.userId).first<number>('n')).toBe(1);
  });

  it('rechecks deletion after stale code validation and preserves the code', async () => {
    const grant = await seedCode();
    const row = await env.DB.prepare('SELECT * FROM oauth_codes WHERE code = ?1')
      .bind(grant.code).first<any>();
    await env.DB.prepare(
      `INSERT INTO account_deletion_intents
         (user_id, idempotency_key_sha256, apple_revocation, created_at)
       VALUES (?1, 'stale-validation', NULL, ?2)`,
    ).bind(grant.userId, Date.now()).run();
    const result = await redeemOAuthAuthorizationCode(env.DB, {
      ...row,
      access_token: `stale-access-${crypto.randomUUID()}`,
      refresh_token: `stale-refresh-${crypto.randomUUID()}`,
      access_expires_at: Math.floor(Date.now() / 1000) + 600,
      grant_id: crypto.randomUUID(),
    });
    expect(result).toBeNull();
    expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM oauth_codes WHERE code = ?1')
      .bind(grant.code).first<number>('n')).toBe(1);
  });

  it('rolls back a failed refresh update and preserves the original pair', async () => {
    const grant = await seedRefresh();
    await env.DB.prepare(
      `CREATE TRIGGER oauth_integrity_fail_update
       BEFORE UPDATE ON oauth_tokens WHEN OLD.client_id = '${grant.clientId}'
       BEGIN SELECT RAISE(ABORT, 'synthetic_update_failure'); END`,
    ).run();
    try {
      expect((await refreshRequest(grant)).status).toBe(500);
      expect(await validateBearer(env, grant.access)).toBe(grant.userId);
      expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM oauth_tokens WHERE refresh_token = ?1')
        .bind(grant.refresh).first<number>('n')).toBe(1);
    } finally {
      await env.DB.prepare('DROP TRIGGER oauth_integrity_fail_update').run();
    }
  });

  it('rechecks deletion after stale refresh validation without family or history residue', async () => {
    const grant = await seedRefresh();
    const row = await env.DB.prepare('SELECT * FROM oauth_tokens WHERE refresh_token = ?1')
      .bind(grant.refresh).first<any>();
    await env.DB.prepare(
      `INSERT INTO account_deletion_intents
         (user_id, idempotency_key_sha256, apple_revocation, created_at)
       VALUES (?1, 'stale-refresh', NULL, ?2)`,
    ).bind(grant.userId, Date.now()).run();
    expect(await rotateOAuthRefreshToken(env.DB, {
      ...row,
      presented_refresh_token: grant.refresh,
      presented_client_id: grant.clientId,
      access_token: `next-access-${crypto.randomUUID()}`,
      refresh_token: `next-refresh-${crypto.randomUUID()}`,
      access_expires_at: Math.floor(Date.now() / 1000) + 600,
      grant_id: null,
      consumed_refresh_sha256: await hexDigest(grant.refresh),
    })).toBeNull();
    expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM oauth_grants WHERE user_id = ?1')
      .bind(grant.userId).first<number>('n')).toBe(0);
    expect(await env.DB.prepare(
      'SELECT COUNT(*) AS n FROM oauth_refresh_history WHERE token_sha256 = ?1',
    ).bind(await hexDigest(grant.refresh)).first<number>('n')).toBe(0);
  });
});

describe('OAuth grant families and caller revocation', () => {
  it('revokes only the matching family successor when a consumed refresh token is replayed', async () => {
    const first = await seedRefresh();
    const independent = await seedRefresh({ userId: first.userId });
    const rotated = await refreshRequest(first);
    expect(rotated.status).toBe(200);
    const successor = await rotated.json<{ access_token: string; refresh_token: string }>();
    expect((await refreshRequest(first)).status).toBe(400);
    expect(await validateBearer(env, successor.access_token)).toBeNull();
    expect(await validateBearer(env, independent.access)).toBe(first.userId);
  });

  it('does not revoke a family when replay uses the wrong client binding', async () => {
    const grant = await seedRefresh();
    const rotated = await refreshRequest(grant);
    const successor = await rotated.json<{ access_token: string }>();
    expect((await refreshRequest(grant, 'wrong-client')).status).toBe(400);
    expect(await validateBearer(env, successor.access_token)).toBe(grant.userId);
  });

  it('revokes the winner after two refresh contenders share the same pre-read snapshot', async () => {
    const grant = await seedRefresh();
    const snapshot = await env.DB.prepare('SELECT * FROM oauth_tokens WHERE refresh_token = ?1')
      .bind(grant.refresh).first<any>();
    const makeRotation = () => ({
      ...snapshot,
      presented_refresh_token: grant.refresh,
      presented_client_id: grant.clientId,
      access_token: `shared-access-${crypto.randomUUID()}`,
      refresh_token: `shared-refresh-${crypto.randomUUID()}`,
      access_expires_at: Math.floor(Date.now() / 1000) + 600,
      grant_id: null,
      consumed_refresh_sha256: '',
    });
    const digest = await hexDigest(grant.refresh);
    const first = makeRotation(); first.consumed_refresh_sha256 = digest;
    const second = makeRotation(); second.consumed_refresh_sha256 = digest;
    const results = await Promise.all([
      refreshOAuthGrant(env.DB, first),
      refreshOAuthGrant(env.DB, second),
    ]);
    expect(results.filter(Boolean)).toHaveLength(1);
    expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM oauth_tokens WHERE user_id = ?1')
      .bind(grant.userId).first<number>('n')).toBe(0);
  });

  it('lists no credentials and revokes only caller-scoped grants idempotently', async () => {
    const caller = await seedRefresh();
    const other = await seedRefresh();
    const jwt = await issueAppJwt(caller.userId, 'test-secret');
    const listed = await SELF.fetch(`${BASE}/api/me/coach-grants`, {
      headers: { Authorization: `Bearer ${jwt}` },
    });
    expect(listed.status).toBe(200);
    const body = await listed.json<{ grants: Array<{ id: string }> }>();
    expect(body.grants).toHaveLength(1);
    expect(JSON.stringify(body)).not.toContain(caller.access);
    expect(JSON.stringify(body)).not.toContain(caller.refresh);
    expect(JSON.stringify(body)).not.toContain(other.refresh);

    const grantId = body.grants[0]!.id;
    const remove = () => SELF.fetch(`${BASE}/api/me/coach-grants/${grantId}`, {
      method: 'DELETE', headers: { Authorization: `Bearer ${jwt}` },
    });
    expect((await remove()).status).toBe(200);
    expect((await remove()).status).toBe(200);
    expect(await validateBearer(env, caller.access)).toBeNull();
    expect(await validateBearer(env, other.access)).toBe(other.userId);
  });

  it('adopts a grant_id-null row inserted after migration and disconnects it', async () => {
    const grant = await seedRefresh();
    const jwt = await issueAppJwt(grant.userId, 'test-secret');
    const listed = await SELF.fetch(`${BASE}/api/me/coach-grants`, {
      headers: { Authorization: `Bearer ${jwt}` },
    });
    const body = await listed.json<{ grants: Array<{ id: string; legacy: boolean }> }>();
    expect(body.grants).toHaveLength(1);
    expect(body.grants[0]!.legacy).toBe(true);
    expect((await SELF.fetch(`${BASE}/api/me/coach-grants`, {
      method: 'DELETE', headers: { Authorization: `Bearer ${jwt}` },
    })).status).toBe(200);
    expect(await validateBearer(env, grant.access)).toBeNull();
  });

  it('does not adopt an untracked grant after account deletion is claimed', async () => {
    const grant = await seedRefresh();
    await env.DB.prepare(
      `INSERT INTO account_deletion_intents
         (user_id, idempotency_key_sha256, apple_revocation, created_at)
       VALUES (?1, 'adoption-race', NULL, ?2)`,
    ).bind(grant.userId, Date.now()).run();
    expect(await listOAuthGrants(env.DB, grant.userId, undefined)).toEqual([]);
    expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM oauth_grants WHERE user_id = ?1')
      .bind(grant.userId).first<number>('n')).toBe(0);
  });

  it('rolls revocation back when its required audit insertion fails', async () => {
    const grant = await seedRefresh();
    const jwt = await issueAppJwt(grant.userId, 'test-secret');
    await SELF.fetch(`${BASE}/api/me/coach-grants`, {
      headers: { Authorization: `Bearer ${jwt}` },
    });
    await env.DB.prepare(
      `CREATE TRIGGER oauth_integrity_fail_revoke_audit
       BEFORE INSERT ON audit_log WHEN NEW.tool = 'revoke_coach_grants'
       BEGIN SELECT RAISE(ABORT, 'synthetic_audit_failure'); END`,
    ).run();
    try {
      const response = await SELF.fetch(`${BASE}/api/me/coach-grants`, {
        method: 'DELETE', headers: { Authorization: `Bearer ${jwt}` },
      });
      expect(response.status).toBe(500);
      expect(await validateBearer(env, grant.access)).toBe(grant.userId);
    } finally {
      await env.DB.prepare('DROP TRIGGER oauth_integrity_fail_revoke_audit').run();
    }
  });
});

describe('OAuth grant lifecycle policy', () => {
  it('activates atomically once, initializes only live grants, and binds retries to the full request', async () => {
    const live = await seedRefresh();
    const revoked = await seedRefresh();
    await listOAuthGrants(env.DB, live.userId, undefined);
    await listOAuthGrants(env.DB, revoked.userId, undefined);
    await env.DB.prepare(
      `UPDATE oauth_grants SET revoked_at = ?2 WHERE user_id = ?1`,
    ).bind(revoked.userId, Date.now()).run();

    await expect(env.DB.prepare(
      `UPDATE oauth_grant_lifecycle_policy
          SET activated_at = 0, activation_nonce = '' WHERE id = 1`,
    ).run()).rejects.toThrow();

    await env.DB.prepare(
      `UPDATE oauth_grants SET absolute_expires_at = ?2 WHERE user_id = ?1`,
    ).bind(live.userId, Date.now() + OAUTH_GRANT_ABSOLUTE_MS).run();
    await expect(activateOAuthGrantLifecyclePolicy(env.DB, Date.now(), 'malformed-policy'))
      .rejects.toThrow('unexpected deadlines');
    expect(await env.DB.prepare(
      'SELECT activated_at FROM oauth_grant_lifecycle_policy WHERE id = 1',
    ).first<number>('activated_at')).toBeNull();
    await env.DB.prepare(
      `UPDATE oauth_grants SET absolute_expires_at = NULL WHERE user_id = ?1`,
    ).bind(live.userId).run();

    await env.DB.prepare(
      `CREATE TRIGGER oauth_lifecycle_fail_initialization
       BEFORE UPDATE ON oauth_grants WHEN OLD.user_id = '${live.userId}'
       BEGIN SELECT RAISE(ABORT, 'synthetic_activation_failure'); END`,
    ).run();
    const activatedAt = Date.now();
    try {
      await expect(activateOAuthGrantLifecyclePolicy(env.DB, activatedAt, 'activation-1'))
        .rejects.toThrow();
      expect(await env.DB.prepare(
        'SELECT activated_at FROM oauth_grant_lifecycle_policy WHERE id = 1',
      ).first<number>('activated_at')).toBeNull();
    } finally {
      await env.DB.prepare('DROP TRIGGER oauth_lifecycle_fail_initialization').run();
    }

    expect(await activateOAuthGrantLifecyclePolicy(env.DB, activatedAt, 'activation-1'))
      .toEqual({ newly_activated: true, activated_at: activatedAt });
    expect(await activateOAuthGrantLifecyclePolicy(env.DB, activatedAt, 'activation-1'))
      .toEqual({ newly_activated: false, activated_at: activatedAt });
    await expect(activateOAuthGrantLifecyclePolicy(env.DB, activatedAt + 1, 'activation-1'))
      .rejects.toThrow('already activated');
    await expect(activateOAuthGrantLifecyclePolicy(env.DB, activatedAt, 'activation-2'))
      .rejects.toThrow('already activated');

    const liveFamily = await env.DB.prepare(
      `SELECT inactivity_expires_at, absolute_expires_at FROM oauth_grants WHERE user_id = ?1`,
    ).bind(live.userId).first<{ inactivity_expires_at: number; absolute_expires_at: number }>();
    expect(liveFamily).toEqual({
      inactivity_expires_at: activatedAt + OAUTH_GRANT_INACTIVITY_MS,
      absolute_expires_at: activatedAt + OAUTH_GRANT_ABSOLUTE_MS,
    });
    const revokedFamily = await env.DB.prepare(
      `SELECT inactivity_expires_at, absolute_expires_at FROM oauth_grants WHERE user_id = ?1`,
    ).bind(revoked.userId).first<{ inactivity_expires_at: number | null; absolute_expires_at: number | null }>();
    expect(revokedFamily).toEqual({ inactivity_expires_at: null, absolute_expires_at: null });
  });

  it('starts new grants at authorization and caps issued access tokens', async () => {
    await activateOAuthGrantLifecyclePolicy(env.DB, Date.now() - 1, 'new-grant-policy');
    const grant = await seedCode();
    const response = await codeRequest(grant);
    expect(response.status).toBe(200);
    const body = await response.json<{ access_token: string; expires_in: number }>();
    const row = await env.DB.prepare(
      `SELECT g.created_at, g.inactivity_expires_at, g.absolute_expires_at, t.expires_at
         FROM oauth_grants g JOIN oauth_tokens t ON t.grant_id = g.id
        WHERE t.access_token = ?1`,
    ).bind(await oauthTokenDigest(body.access_token)).first<any>();
    expect(row.inactivity_expires_at).toBe(grant.createdAt + OAUTH_GRANT_INACTIVITY_MS);
    expect(row.absolute_expires_at).toBe(grant.createdAt + OAUTH_GRANT_ABSOLUTE_MS);
    expect(row.expires_at).toBeLessThanOrEqual(Math.floor(row.inactivity_expires_at / 1000));
    expect(body.expires_in).toBeLessThanOrEqual(30 * 24 * 60 * 60);
  });

  it('rechecks activation after stale code and legacy refresh pre-reads', async () => {
    const code = await seedCode();
    const refresh = await seedRefresh();
    const codeSnapshot = await env.DB.prepare(
      'SELECT * FROM oauth_codes WHERE code = ?1',
    ).bind(code.code).first<any>();
    const refreshSnapshot = await env.DB.prepare(
      'SELECT * FROM oauth_tokens WHERE refresh_token = ?1',
    ).bind(refresh.refresh).first<any>();
    const activatedAt = Date.now();
    await activateOAuthGrantLifecyclePolicy(env.DB, activatedAt, 'stale-read-policy');

    const redeemed = await redeemOAuthAuthorizationCode(env.DB, {
      ...codeSnapshot,
      access_token: `stale-policy-access-${crypto.randomUUID()}`,
      refresh_token: `stale-policy-refresh-${crypto.randomUUID()}`,
      access_expires_at: Math.floor(Date.now() / 1000) + 30 * 24 * 60 * 60,
      grant_id: crypto.randomUUID(),
    });
    expect(redeemed).not.toBeNull();
    const redeemedFamily = await env.DB.prepare(
      `SELECT inactivity_expires_at, absolute_expires_at
         FROM oauth_grants WHERE id = ?1`,
    ).bind(redeemed!.grant_id).first<any>();
    expect(redeemedFamily.inactivity_expires_at).toBe(activatedAt + OAUTH_GRANT_INACTIVITY_MS);
    expect(redeemedFamily.absolute_expires_at).toBe(activatedAt + OAUTH_GRANT_ABSOLUTE_MS);

    const rotated = await rotateOAuthRefreshToken(env.DB, {
      ...refreshSnapshot,
      presented_refresh_token: refresh.refresh,
      presented_client_id: refresh.clientId,
      access_token: `stale-legacy-access-${crypto.randomUUID()}`,
      refresh_token: `stale-legacy-refresh-${crypto.randomUUID()}`,
      access_expires_at: Math.floor(Date.now() / 1000) + 30 * 24 * 60 * 60,
      grant_id: null,
      consumed_refresh_sha256: await hexDigest(refresh.refresh),
    });
    expect(rotated).not.toBeNull();
    const rotatedFamily = await env.DB.prepare(
      `SELECT inactivity_expires_at, absolute_expires_at
         FROM oauth_grants WHERE id = ?1`,
    ).bind(rotated!.grant_id).first<any>();
    expect(rotatedFamily.absolute_expires_at).toBe(activatedAt + OAUTH_GRANT_ABSOLUTE_MS);
    expect(rotatedFamily.inactivity_expires_at).toBeGreaterThanOrEqual(
      activatedAt + OAUTH_GRANT_INACTIVITY_MS,
    );
  });

  it('fails closed at lifecycle boundaries for bearer, refresh, and listing', async () => {
    await activateOAuthGrantLifecyclePolicy(env.DB, Date.now() - 1, 'boundary-policy');
    const grant = await seedRefresh();
    await listOAuthGrants(env.DB, grant.userId, undefined);
    const snapshot = await env.DB.prepare(
      'SELECT * FROM oauth_tokens WHERE refresh_token = ?1',
    ).bind(grant.refresh).first<any>();
    await env.DB.prepare(
      `UPDATE oauth_grants
          SET inactivity_expires_at = CAST(unixepoch('subsec') * 1000 AS INTEGER),
              absolute_expires_at = CAST(unixepoch('subsec') * 1000 AS INTEGER) + 100000
        WHERE id = ?1`,
    ).bind(snapshot.grant_id).run();
    expect(await validateBearer(env, grant.access)).toBeNull();
    expect(await rotateOAuthRefreshToken(env.DB, {
      ...snapshot,
      presented_refresh_token: grant.refresh,
      presented_client_id: grant.clientId,
      access_token: `boundary-access-${crypto.randomUUID()}`,
      refresh_token: `boundary-refresh-${crypto.randomUUID()}`,
      access_expires_at: Math.floor(Date.now() / 1000) + 600,
      consumed_refresh_sha256: await hexDigest(grant.refresh),
    })).toBeNull();
    expect(await env.DB.prepare(
      'SELECT COUNT(*) AS n FROM oauth_tokens WHERE refresh_token = ?1',
    ).bind(grant.refresh).first<number>('n')).toBe(1);
    expect(await listOAuthGrants(env.DB, grant.userId, undefined)).toEqual([]);
  });

  it('slides inactivity on successful refresh but never past the absolute deadline', async () => {
    await activateOAuthGrantLifecyclePolicy(env.DB, Date.now() - 1, 'sliding-policy');
    const grant = await seedRefresh();
    await listOAuthGrants(env.DB, grant.userId, undefined);
    const absolute = Date.now() + 2 * 24 * 60 * 60 * 1000;
    await env.DB.prepare(
      `UPDATE oauth_grants
          SET inactivity_expires_at = ?2, absolute_expires_at = ?3
        WHERE user_id = ?1`,
    ).bind(grant.userId, Date.now() + 60_000, absolute).run();
    const response = await refreshRequest(grant);
    expect(response.status).toBe(200);
    const successor = await response.json<{ access_token: string }>();
    const row = await env.DB.prepare(
      `SELECT g.inactivity_expires_at, g.absolute_expires_at, t.expires_at
         FROM oauth_grants g JOIN oauth_tokens t ON t.grant_id = g.id
        WHERE t.access_token = ?1`,
    ).bind(await oauthTokenDigest(successor.access_token)).first<any>();
    expect(row.inactivity_expires_at).toBe(row.absolute_expires_at);
    expect(row.absolute_expires_at).toBe(absolute);
    expect(row.expires_at).toBeLessThanOrEqual(Math.floor(absolute / 1000));
    expect(await validateBearer(env, successor.access_token)).toBe(grant.userId);
  });

  it('rejects partially initialized deadline state without mutating either grant', async () => {
    await activateOAuthGrantLifecyclePolicy(env.DB, Date.now() - 1, 'partial-policy');
    const inactivityMissing = await seedRefresh();
    const absoluteMissing = await seedRefresh();
    await listOAuthGrants(env.DB, inactivityMissing.userId, undefined);
    await listOAuthGrants(env.DB, absoluteMissing.userId, undefined);
    await env.DB.prepare(
      `UPDATE oauth_grants SET inactivity_expires_at = NULL WHERE user_id = ?1`,
    ).bind(inactivityMissing.userId).run();
    await env.DB.prepare(
      `UPDATE oauth_grants SET absolute_expires_at = NULL WHERE user_id = ?1`,
    ).bind(absoluteMissing.userId).run();

    for (const grant of [inactivityMissing, absoluteMissing]) {
      const snapshot = await env.DB.prepare(
        'SELECT * FROM oauth_tokens WHERE refresh_token = ?1',
      ).bind(grant.refresh).first<any>();
      expect(await validateBearer(env, grant.access)).toBeNull();
      expect(await listOAuthGrants(env.DB, grant.userId, undefined)).toEqual([]);
      expect(await rotateOAuthRefreshToken(env.DB, {
        ...snapshot,
        presented_refresh_token: grant.refresh,
        presented_client_id: grant.clientId,
        access_token: `partial-access-${crypto.randomUUID()}`,
        refresh_token: `partial-refresh-${crypto.randomUUID()}`,
        access_expires_at: Math.floor(Date.now() / 1000) + 600,
        consumed_refresh_sha256: await hexDigest(grant.refresh),
      })).toBeNull();
      expect(await env.DB.prepare(
        'SELECT COUNT(*) AS n FROM oauth_tokens WHERE refresh_token = ?1',
      ).bind(grant.refresh).first<number>('n')).toBe(1);
    }
  });

  it('protects policy state and fails closed if the singleton is missing', async () => {
    const activatedAt = Date.now();
    await activateOAuthGrantLifecyclePolicy(env.DB, activatedAt, 'protected-policy');
    await expect(env.DB.prepare(
      `UPDATE oauth_grant_lifecycle_policy
          SET activated_at = ?1, activation_nonce = 'rewritten' WHERE id = 1`,
    ).bind(activatedAt + 1).run()).rejects.toThrow('monotonic');
    await expect(env.DB.prepare(
      'DELETE FROM oauth_grant_lifecycle_policy WHERE id = 1',
    ).run()).rejects.toThrow('cannot be deleted');

    const refresh = await seedRefresh();
    const code = await seedCode();
    await listOAuthGrants(env.DB, refresh.userId, undefined);
    await env.DB.prepare('DROP TRIGGER oauth_grant_lifecycle_no_delete').run();
    await env.DB.prepare('DELETE FROM oauth_grant_lifecycle_policy WHERE id = 1').run();
    expect(await validateBearer(env, refresh.access)).toBeNull();
    expect((await refreshRequest(refresh)).status).toBe(400);
    expect((await codeRequest(code)).status).toBe(400);
    expect(await env.DB.prepare(
      'SELECT COUNT(*) AS n FROM oauth_tokens WHERE refresh_token = ?1',
    ).bind(refresh.refresh).first<number>('n')).toBe(1);
    expect(await env.DB.prepare(
      'SELECT COUNT(*) AS n FROM oauth_codes WHERE code = ?1',
    ).bind(code.code).first<number>('n')).toBe(1);
  });
});
