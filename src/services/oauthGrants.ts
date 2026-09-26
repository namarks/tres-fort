// Internal grant lifecycle service. Routes and MCP import the db.ts facade.

import type { User } from '../types';
const now = () => Date.now();
const uuid = () => crypto.randomUUID();
// ---- OAuth grant transitions --------------------------------------------

export interface OAuthCodeRedemption {
  code: string;
  client_id: string;
  redirect_uri: string;
  code_challenge: string;
  code_challenge_method: string;
  scope: string | null;
  resource: string | null;
  expires_at: number;
  user_id: string | null;
  access_token: string;
  refresh_token: string;
  access_expires_at: number;
  grant_id: string;
  owner_apple_sub?: string;
}

export interface OAuthRefreshRotation {
  presented_refresh_token: string;
  presented_client_id: string;
  client_id: string;
  scope: string | null;
  expires_at: number;
  user_id: string | null;
  access_token: string;
  refresh_token: string;
  access_expires_at: number;
  grant_id: string | null;
  consumed_refresh_sha256: string;
  owner_apple_sub?: string;
}

export interface OAuthTokenPair {
  access_token: string;
  refresh_token: string;
  scope: string;
  grant_id: string;
  access_expires_at: number;
}

export const OAUTH_GRANT_INACTIVITY_MS = 90 * 24 * 60 * 60 * 1000;
export const OAUTH_GRANT_ABSOLUTE_MS = 365 * 24 * 60 * 60 * 1000;

export interface OAuthGrantSummary {
  id: string;
  client_id: string;
  scope: string;
  created_at: number;
  last_refreshed_at: number | null;
  legacy: boolean;
}

/** Owner resolution stays in the identity service; injection avoids a cycle
 * back through the public facade. Grant SQL and CAS transitions live here. */
export function createOAuthGrantService(
  findOwnerRow: (db: D1Database, ownerAppleSub: string | undefined) => Promise<User | null>,
) {
  /**
   * One-time administrative policy activation. Migration 0042's trigger makes
   * the conditional claim and every existing-grant update one transaction, so
   * failure rolls the whole activation back.
   * Existing deadlines are never overwritten, including a retry with the same
   * nonce. Migration 0042's trigger initializes existing grants in the same
   * transaction as this one conditional UPDATE.
   */
  async function activateOAuthGrantLifecyclePolicy(
    db: D1Database,
    activatedAt: number,
    nonce: string,
  ): Promise<{ newly_activated: boolean; activated_at: number }> {
    if (!Number.isSafeInteger(activatedAt) || activatedAt <= 0 || !nonce) {
      throw new Error('invalid OAuth grant lifecycle activation');
    }
    const claimed = await db
      .prepare(
        `UPDATE oauth_grant_lifecycle_policy
            SET activated_at = ?1, activation_nonce = ?2
          WHERE id = 1 AND activated_at IS NULL
        RETURNING id`,
      )
      .bind(activatedAt, nonce)
      .run();
    const policy = await db.prepare(
      'SELECT activated_at, activation_nonce FROM oauth_grant_lifecycle_policy WHERE id = 1',
    ).first<{ activated_at: number; activation_nonce: string }>();
    if (!policy) throw new Error('OAuth grant lifecycle policy row missing');
    if (policy.activation_nonce !== nonce || policy.activated_at !== activatedAt) {
      throw new Error('OAuth grant lifecycle policy already activated');
    }
    return { newly_activated: claimed.results.length === 1, activated_at: policy.activated_at };
  }

  /**
   * Consume one already-validated authorization-code snapshot and insert its
   * sole successor in one D1 transaction. Every immutable validation input is
   * repeated at the write boundary. If insertion fails, D1 rolls the batch back
   * and leaves the code available for a corrected retry.
   */
  async function redeemOAuthAuthorizationCode(
    db: D1Database,
    redemption: OAuthCodeRedemption,
  ): Promise<OAuthTokenPair | null> {
    // Legacy unscoped grants belong only to an existing distinguished owner.
    // Do not bootstrap a replacement identity while redeeming old credentials.
    const principal = redemption.user_id
      ? await db.prepare('SELECT id FROM users WHERE id = ?1').bind(redemption.user_id).first<{ id: string }>()
      : await findOwnerRow(db, redemption.owner_apple_sub);
    if (!principal) return null;

    const nowMs = now();
    const tokenCreatedAt = Math.floor(nowMs / 1000);
    const legacy = redemption.user_id === null;
    const [family, inserted, consumed, cleaned] = await db.batch([
      db.prepare(
        `INSERT INTO oauth_grants
           (id, user_id, client_id, scope, created_at, last_refreshed_at, legacy,
            inactivity_expires_at, absolute_expires_at)
         SELECT ?1, ?2, c.client_id, COALESCE(c.scope, 'mcp'), ?3, ?3, ?15,
                CASE WHEN p.activated_at IS NULL THEN NULL
                     ELSE MAX(c.created_at, p.activated_at) + ?16 END,
                CASE WHEN p.activated_at IS NULL THEN NULL
                     ELSE MAX(c.created_at, p.activated_at) + ?17 END
           FROM oauth_codes c
           LEFT JOIN oauth_grant_lifecycle_policy p ON p.id = 1
          WHERE c.code = ?4
            AND p.id = 1
            AND c.client_id = ?5
            AND c.redirect_uri = ?6
            AND c.code_challenge = ?7
            AND c.code_challenge_method = ?8
            AND c.expires_at = ?9
            AND c.expires_at >= ?10
            AND c.scope IS ?11
            AND c.resource IS ?12
            AND (c.user_id = ?13 OR (?14 = 1 AND c.user_id IS NULL))
            AND EXISTS (SELECT 1 FROM users WHERE id = ?2)
            AND NOT EXISTS (SELECT 1 FROM account_deletion_intents WHERE user_id = ?2)
            AND NOT EXISTS (SELECT 1 FROM account_deletion_receipts WHERE user_id = ?2)`,
      ).bind(
        redemption.grant_id,
        principal.id,
        nowMs,
        redemption.code,
        redemption.client_id,
        redemption.redirect_uri,
        redemption.code_challenge,
        redemption.code_challenge_method,
        redemption.expires_at,
        nowMs,
        redemption.scope,
        redemption.resource,
        redemption.user_id,
        legacy ? 1 : 0,
        legacy ? 1 : 0,
        OAUTH_GRANT_INACTIVITY_MS,
        OAUTH_GRANT_ABSOLUTE_MS,
      ),
      db.prepare(
        `INSERT INTO oauth_tokens
           (access_token, refresh_token, client_id, scope, expires_at, created_at, user_id, grant_id)
         SELECT ?1, ?2, c.client_id, COALESCE(c.scope, 'mcp'),
                CASE WHEN g.inactivity_expires_at IS NULL THEN ?3
                     ELSE MIN(?3, CAST(g.inactivity_expires_at / 1000 AS INTEGER),
                                  CAST(g.absolute_expires_at / 1000 AS INTEGER)) END,
                ?4, ?5, ?17
           FROM oauth_codes c
           JOIN oauth_grants g ON g.id = ?17
          WHERE c.code = ?6
            AND c.client_id = ?7
            AND c.redirect_uri = ?8
            AND c.code_challenge = ?9
            AND c.code_challenge_method = ?10
            AND c.expires_at = ?11
            AND c.expires_at >= ?12
            AND c.scope IS ?13
            AND c.resource IS ?14
            AND (c.user_id = ?15 OR (?16 = 1 AND c.user_id IS NULL))
            AND EXISTS (SELECT 1 FROM users WHERE id = ?5)
            AND NOT EXISTS (SELECT 1 FROM account_deletion_intents WHERE user_id = ?5)
            AND NOT EXISTS (SELECT 1 FROM account_deletion_receipts WHERE user_id = ?5)
            AND changes() = 1
         RETURNING expires_at`,
      ).bind(
        redemption.access_token,
        redemption.refresh_token,
        redemption.access_expires_at,
        tokenCreatedAt,
        principal.id,
        redemption.code,
        redemption.client_id,
        redemption.redirect_uri,
        redemption.code_challenge,
        redemption.code_challenge_method,
        redemption.expires_at,
        nowMs,
        redemption.scope,
        redemption.resource,
        redemption.user_id,
        legacy ? 1 : 0,
        redemption.grant_id,
      ),
      db.prepare(
        `DELETE FROM oauth_codes
          WHERE code = ?1
            AND client_id = ?2
            AND redirect_uri = ?3
            AND code_challenge = ?4
            AND code_challenge_method = ?5
            AND expires_at = ?6
            AND expires_at >= ?7
            AND scope IS ?8
            AND resource IS ?9
            AND (user_id = ?10 OR (?11 = 1 AND user_id IS NULL))
            AND changes() = 1`,
      ).bind(
        redemption.code,
        redemption.client_id,
        redemption.redirect_uri,
        redemption.code_challenge,
        redemption.code_challenge_method,
        redemption.expires_at,
        nowMs,
        redemption.scope,
        redemption.resource,
        redemption.user_id,
        legacy ? 1 : 0,
      ),
      db.prepare(
        `DELETE FROM oauth_grants
          WHERE id = ?1
            AND NOT EXISTS (SELECT 1 FROM oauth_tokens WHERE grant_id = ?1)`,
      ).bind(redemption.grant_id),
    ]);
    if (
      family?.meta.changes !== 1 ||
      inserted?.meta.changes !== 1 ||
      consumed?.meta.changes !== 1 ||
      cleaned?.meta.changes !== 0
    ) return null;
    return {
      access_token: redemption.access_token,
      refresh_token: redemption.refresh_token,
      scope: redemption.scope ?? 'mcp',
      grant_id: redemption.grant_id,
      access_expires_at: (inserted.results?.[0] as { expires_at: number }).expires_at,
    };
  }

  /** Rotate a refresh credential with one conditional write. */
  async function rotateOAuthRefreshToken(
    db: D1Database,
    rotation: OAuthRefreshRotation,
  ): Promise<OAuthTokenPair | null> {
    if (!rotation.presented_client_id || rotation.presented_client_id !== rotation.client_id) {
      return null;
    }
    const principal = rotation.user_id
      ? await db.prepare('SELECT id FROM users WHERE id = ?1').bind(rotation.user_id).first<{ id: string }>()
      : await findOwnerRow(db, rotation.owner_apple_sub);
    if (!principal) return null;

    const refreshedAt = now();
    const tokenCreatedAt = Math.floor(refreshedAt / 1000);
    const legacy = rotation.user_id === null;
    const grantId = rotation.grant_id ?? crypto.randomUUID();
    const [adopted, , rotated, archived, touched, cleaned] = await db.batch([
      db.prepare(
        `INSERT INTO oauth_grants
           (id, user_id, client_id, scope, created_at, last_refreshed_at, legacy,
            inactivity_expires_at, absolute_expires_at)
         SELECT ?1, ?2, t.client_id, t.scope, t.created_at * 1000, ?3, 1,
                CASE WHEN p.activated_at IS NULL THEN NULL
                     ELSE MAX(t.created_at * 1000, p.activated_at) + ?10 END,
                CASE WHEN p.activated_at IS NULL THEN NULL
                     ELSE MAX(t.created_at * 1000, p.activated_at) + ?11 END
           FROM oauth_tokens t
           LEFT JOIN oauth_grant_lifecycle_policy p ON p.id = 1
          WHERE t.refresh_token = ?4
            AND p.id = 1
            AND t.client_id = ?5
            AND t.expires_at = ?6
            AND t.scope IS ?7
            AND t.grant_id IS NULL
            AND (t.user_id = ?8 OR (?9 = 1 AND t.user_id IS NULL))
            AND EXISTS (SELECT 1 FROM users WHERE id = ?2)
            AND NOT EXISTS (SELECT 1 FROM account_deletion_intents WHERE user_id = ?2)
            AND NOT EXISTS (SELECT 1 FROM account_deletion_receipts WHERE user_id = ?2)
         ON CONFLICT(id) DO NOTHING`,
      ).bind(
        grantId,
        principal.id,
        refreshedAt,
        rotation.presented_refresh_token,
        rotation.client_id,
        rotation.expires_at,
        rotation.scope,
        rotation.user_id,
        legacy ? 1 : 0,
        OAUTH_GRANT_INACTIVITY_MS,
        OAUTH_GRANT_ABSOLUTE_MS,
      ),
      db.prepare(
        `UPDATE oauth_grants
            SET inactivity_expires_at = MAX(created_at, p.activated_at) + ?2,
                absolute_expires_at = MAX(created_at, p.activated_at) + ?3
           FROM oauth_grant_lifecycle_policy p
          WHERE oauth_grants.id = ?1
            AND p.id = 1 AND p.activated_at IS NOT NULL
            AND oauth_grants.revoked_at IS NULL
            AND oauth_grants.inactivity_expires_at IS NULL
            AND oauth_grants.absolute_expires_at IS NULL`,
      ).bind(grantId, OAUTH_GRANT_INACTIVITY_MS, OAUTH_GRANT_ABSOLUTE_MS),
      db.prepare(
      `UPDATE oauth_tokens
          SET access_token = ?1,
              refresh_token = ?2,
              expires_at = CASE
                WHEN g.inactivity_expires_at IS NULL AND g.absolute_expires_at IS NULL
                     AND p.activated_at IS NULL THEN ?3
                ELSE MIN(?3,
                         CAST(MIN(CAST(unixepoch('subsec') * 1000 AS INTEGER) + ?14,
                                      g.absolute_expires_at) / 1000 AS INTEGER))
              END,
              created_at = CAST(unixepoch('subsec') AS INTEGER),
              user_id = ?5,
              grant_id = ?12
         FROM oauth_grants g
         LEFT JOIN oauth_grant_lifecycle_policy p ON p.id = 1
        WHERE oauth_tokens.refresh_token = ?6
          AND oauth_tokens.client_id = ?7
          AND oauth_tokens.expires_at = ?8
          AND (oauth_tokens.user_id = ?9 OR (?10 = 1 AND oauth_tokens.user_id IS NULL))
          AND EXISTS (SELECT 1 FROM users WHERE id = ?5)
          AND NOT EXISTS (SELECT 1 FROM account_deletion_intents WHERE user_id = ?5)
          AND NOT EXISTS (SELECT 1 FROM account_deletion_receipts WHERE user_id = ?5)
          AND oauth_tokens.scope IS ?11
          AND (oauth_tokens.grant_id = ?12 OR oauth_tokens.grant_id IS NULL)
          AND g.id = ?12 AND g.revoked_at IS NULL
          AND (
            (p.id = 1 AND p.activated_at IS NULL
             AND g.inactivity_expires_at IS NULL AND g.absolute_expires_at IS NULL)
            OR
            (p.id = 1 AND p.activated_at IS NOT NULL
             AND g.inactivity_expires_at > CAST(unixepoch('subsec') * 1000 AS INTEGER)
             AND g.absolute_expires_at > CAST(unixepoch('subsec') * 1000 AS INTEGER))
          )
          AND NOT EXISTS (
                SELECT 1 FROM oauth_refresh_history WHERE token_sha256 = ?13
              )
        RETURNING expires_at`,
    ).bind(
      rotation.access_token,
      rotation.refresh_token,
      rotation.access_expires_at,
      tokenCreatedAt,
      principal.id,
      rotation.presented_refresh_token,
      rotation.client_id,
      rotation.expires_at,
      rotation.user_id,
      legacy ? 1 : 0,
      rotation.scope,
      grantId,
      rotation.consumed_refresh_sha256,
      OAUTH_GRANT_INACTIVITY_MS,
    ),
      db.prepare(
        `INSERT INTO oauth_refresh_history (token_sha256, grant_id, client_id, consumed_at)
         SELECT ?1, ?2, ?3, ?4
          WHERE changes() = 1`,
      ).bind(rotation.consumed_refresh_sha256, grantId, rotation.client_id, refreshedAt),
      db.prepare(
        `UPDATE oauth_grants
            SET last_refreshed_at = CAST(unixepoch('subsec') * 1000 AS INTEGER),
                inactivity_expires_at = CASE
                  WHEN inactivity_expires_at IS NULL THEN NULL
                  ELSE MIN(CAST(unixepoch('subsec') * 1000 AS INTEGER) + ?3,
                           absolute_expires_at)
                END
          WHERE id = ?1 AND revoked_at IS NULL AND changes() = 1`,
      ).bind(grantId, refreshedAt, OAUTH_GRANT_INACTIVITY_MS),
      db.prepare(
        `DELETE FROM oauth_grants
          WHERE id = ?1 AND ?2 = 1
            AND NOT EXISTS (SELECT 1 FROM oauth_tokens WHERE grant_id = ?1)
            AND NOT EXISTS (SELECT 1 FROM oauth_refresh_history WHERE grant_id = ?1)`,
      ).bind(grantId, rotation.grant_id === null ? 1 : 0),
    ]);
    if (rotated?.meta.changes !== 1 || archived?.meta.changes !== 1 || touched?.meta.changes !== 1) {
      return null;
    }
    if (cleaned?.meta.changes !== 0) return null;
    if (rotation.grant_id === null && adopted?.meta.changes !== 1) return null;
    return {
      access_token: rotation.access_token,
      refresh_token: rotation.refresh_token,
      scope: rotation.scope ?? 'mcp',
      grant_id: grantId,
      access_expires_at: (rotated.results?.[0] as { expires_at: number }).expires_at,
    };
  }

  /**
   * Complete refresh behavior for one validated snapshot. A clean CAS loss may
   * mean another contender just consumed the same credential, so check history
   * before returning invalid_grant and revoke that family's surviving token.
   */
  async function refreshOAuthGrant(
    db: D1Database,
    rotation: OAuthRefreshRotation,
  ): Promise<OAuthTokenPair | null> {
    const tokens = await rotateOAuthRefreshToken(db, rotation);
    if (tokens) return tokens;
    await revokeOAuthGrantOnRefreshReplay(
      db,
      rotation.consumed_refresh_sha256,
      rotation.presented_client_id,
      rotation.owner_apple_sub,
    );
    return null;
  }

  /**
   * A matching replay of a consumed refresh credential invalidates only its
   * family. A wrong client id has no effect: public client ids bind requests but
   * do not authenticate whoever presented the stale credential.
   */
  async function revokeOAuthGrantOnRefreshReplay(
    db: D1Database,
    tokenSha256: string,
    clientId: string,
    ownerAppleSub: string | undefined,
  ): Promise<boolean> {
    const replay = await db.prepare(
      `SELECT g.id, g.user_id FROM oauth_refresh_history h
         JOIN oauth_grants g ON g.id = h.grant_id
        WHERE h.token_sha256 = ?1
          AND h.client_id = ?2
          AND g.client_id = ?2`,
    ).bind(tokenSha256, clientId).first<{ id: string; user_id: string | null }>();
    if (!replay) return false;
    const principal = replay.user_id
      ? await db.prepare('SELECT id FROM users WHERE id = ?1').bind(replay.user_id).first<{ id: string }>()
      : await findOwnerRow(db, ownerAppleSub);
    if (!principal) return false;
    const revokedAt = now();
    const [revoked, removed] = await db.batch([
      db.prepare(
        `UPDATE oauth_grants SET revoked_at = ?2
          WHERE id = ?1 AND revoked_at IS NULL
            AND (user_id = ?3 OR (?4 = 1 AND user_id IS NULL))`,
      ).bind(replay.id, revokedAt, replay.user_id, replay.user_id === null ? 1 : 0),
      db.prepare('DELETE FROM oauth_tokens WHERE grant_id = ?1 AND changes() = 1')
        .bind(replay.id),
    ]);
    return revoked?.meta.changes === 1 && (removed?.meta.changes ?? 0) <= 1;
  }

  async function adoptUntrackedOAuthGrants(
    db: D1Database,
    userId: string,
    includeLegacyOwner: boolean,
  ): Promise<void> {
    const rows = await db.prepare(
      `SELECT access_token, user_id, client_id, scope, created_at
         FROM oauth_tokens
        WHERE grant_id IS NULL
          AND (user_id = ?1 OR (?2 = 1 AND user_id IS NULL))`,
    ).bind(userId, includeLegacyOwner ? 1 : 0).all<{
      access_token: string;
      user_id: string | null;
      client_id: string;
      scope: string | null;
      created_at: number;
    }>();
    for (const row of rows.results) {
      const grantId = crypto.randomUUID();
      await db.batch([
        db.prepare(
          `INSERT INTO oauth_grants
             (id, user_id, client_id, scope, created_at, last_refreshed_at, legacy,
              inactivity_expires_at, absolute_expires_at)
           SELECT ?1, ?2, t.client_id, t.scope, t.created_at * 1000, t.created_at * 1000, 1,
                  CASE WHEN p.activated_at IS NULL THEN NULL
                       ELSE MAX(t.created_at * 1000, p.activated_at) + ?5 END,
                  CASE WHEN p.activated_at IS NULL THEN NULL
                       ELSE MAX(t.created_at * 1000, p.activated_at) + ?6 END
             FROM oauth_tokens t
             LEFT JOIN oauth_grant_lifecycle_policy p ON p.id = 1
            WHERE access_token = ?3 AND grant_id IS NULL
              AND (user_id = ?2 OR (?4 = 1 AND user_id IS NULL))
              AND EXISTS (SELECT 1 FROM users WHERE id = ?2)
              AND NOT EXISTS (SELECT 1 FROM account_deletion_intents WHERE user_id = ?2)
              AND NOT EXISTS (SELECT 1 FROM account_deletion_receipts WHERE user_id = ?2)`,
        ).bind(
          grantId,
          row.user_id ?? userId,
          row.access_token,
          row.user_id === null ? 1 : 0,
          OAUTH_GRANT_INACTIVITY_MS,
          OAUTH_GRANT_ABSOLUTE_MS,
        ),
        db.prepare(
          `UPDATE oauth_tokens SET grant_id = ?2
            WHERE access_token = ?1 AND grant_id IS NULL AND changes() = 1`,
        ).bind(row.access_token, grantId),
        db.prepare(
          `DELETE FROM oauth_grants
            WHERE id = ?1
              AND NOT EXISTS (SELECT 1 FROM oauth_tokens WHERE grant_id = ?1)`,
        ).bind(grantId),
      ]);
    }
  }

  async function listOAuthGrants(
    db: D1Database,
    userId: string,
    ownerAppleSub: string | undefined,
  ): Promise<OAuthGrantSummary[]> {
    const owner = await findOwnerRow(db, ownerAppleSub);
    const isOwner = owner?.id === userId;
    await adoptUntrackedOAuthGrants(db, userId, isOwner);
    const rows = await db.prepare(
      `SELECT g.id, g.client_id, COALESCE(g.scope, 'mcp') AS scope, g.created_at,
              g.last_refreshed_at, g.legacy
         FROM oauth_grants g
         JOIN oauth_grant_lifecycle_policy p ON p.id = 1
        WHERE g.revoked_at IS NULL
          AND (
            (p.activated_at IS NULL
             AND g.inactivity_expires_at IS NULL AND g.absolute_expires_at IS NULL)
            OR
            (p.activated_at IS NOT NULL
             AND g.inactivity_expires_at > CAST(unixepoch('subsec') * 1000 AS INTEGER)
             AND g.absolute_expires_at > CAST(unixepoch('subsec') * 1000 AS INTEGER))
          )
          AND (g.user_id = ?1 OR (?2 = 1 AND g.user_id IS NULL))
        ORDER BY g.created_at DESC, g.id`,
    ).bind(userId, isOwner ? 1 : 0).all<{
      id: string;
      client_id: string;
      scope: string;
      created_at: number;
      last_refreshed_at: number | null;
      legacy: number;
    }>();
    return rows.results.map((row) => ({ ...row, legacy: row.legacy === 1 }));
  }

  /** Caller-scoped and idempotent; never returns or audits credential values. */
  async function revokeOAuthGrant(
    db: D1Database,
    userId: string,
    grantId: string,
    ownerAppleSub: string | undefined,
  ): Promise<boolean> {
    const owner = await findOwnerRow(db, ownerAppleSub);
    const isOwner = owner?.id === userId;
    const grant = await db.prepare(
      `SELECT id FROM oauth_grants
        WHERE id = ?1 AND (user_id = ?2 OR (?3 = 1 AND user_id IS NULL))`,
    ).bind(grantId, userId, isOwner ? 1 : 0).first<{ id: string }>();
    if (!grant) return false;
    await db.batch([
      db.prepare(
        `INSERT INTO audit_log (id,user_id,actor,tool,args,result,created_at)
         VALUES (?1,?2,'ios','revoke_coach_grant',?3,'revoked',?4)`,
      ).bind(uuid(), userId, JSON.stringify({ grant_id: grantId }), now()),
      db.prepare(
        'UPDATE oauth_grants SET revoked_at = COALESCE(revoked_at, ?2) WHERE id = ?1',
      ).bind(grantId, now()),
      db.prepare('DELETE FROM oauth_tokens WHERE grant_id = ?1').bind(grantId),
    ]);
    return true;
  }

  async function revokeAllOAuthGrants(
    db: D1Database,
    userId: string,
    ownerAppleSub: string | undefined,
  ): Promise<number> {
    const owner = await findOwnerRow(db, ownerAppleSub);
    const isOwner = owner?.id === userId;
    await adoptUntrackedOAuthGrants(db, userId, isOwner);
    const [, revoked] = await db.batch([
      db.prepare(
        `INSERT INTO audit_log (id,user_id,actor,tool,args,result,created_at)
         VALUES (?1,?2,'ios','revoke_coach_grants',?3,'revoked',?4)`,
      ).bind(uuid(), userId, JSON.stringify({ scope: 'all' }), now()),
      db.prepare(
        `UPDATE oauth_grants SET revoked_at = COALESCE(revoked_at, ?3)
          WHERE revoked_at IS NULL
            AND (user_id = ?1 OR (?2 = 1 AND user_id IS NULL))`,
      ).bind(userId, isOwner ? 1 : 0, now()),
      db.prepare(
        `DELETE FROM oauth_tokens
          WHERE grant_id IN (
            SELECT id FROM oauth_grants
             WHERE revoked_at IS NOT NULL
               AND (user_id = ?1 OR (?2 = 1 AND user_id IS NULL))
          )`,
      ).bind(userId, isOwner ? 1 : 0),
      // Stop approved-but-not-yet-exchanged connections as well as tokens.
      db.prepare(`DELETE FROM oauth_codes
        WHERE user_id = ?1 OR (?2 = 1 AND user_id IS NULL)`)
        .bind(userId, isOwner ? 1 : 0),
    ]);
    return revoked?.meta.changes ?? 0;
  }
  return { activateOAuthGrantLifecyclePolicy, redeemOAuthAuthorizationCode, rotateOAuthRefreshToken, refreshOAuthGrant, revokeOAuthGrantOnRefreshReplay, listOAuthGrants, revokeOAuthGrant, revokeAllOAuthGrants };
}
