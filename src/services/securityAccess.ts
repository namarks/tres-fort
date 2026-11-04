import { credentialDigest, randomSecret } from '../credentials';

export async function isAppSessionRevoked(db: D1Database, userId: string, sessionId: string): Promise<boolean> {
  return !!await db.prepare('SELECT 1 FROM app_session_revocations WHERE session_id=?1 AND user_id=?2')
    .bind(sessionId, userId).first();
}

export async function revokeAppSession(db: D1Database, userId: string, sessionId: string, expiresAt: number): Promise<void> {
  await db.batch([
    db.prepare('DELETE FROM app_session_revocations WHERE expires_at < ?1').bind(Date.now()),
    db.prepare(`INSERT INTO app_session_revocations(session_id,user_id,expires_at) VALUES (?1,?2,?3)
      ON CONFLICT(session_id) DO UPDATE SET expires_at=MAX(expires_at,excluded.expires_at)`)
      .bind(sessionId, userId, expiresAt),
  ]);
}

export async function createCoachConnectCode(db: D1Database, userId: string): Promise<{ code: string; expires_at: number }> {
  const code = randomSecret(), expires_at = Date.now() + 10 * 60_000;
  const result = await db.prepare(`INSERT INTO coach_connect_codes(user_id,code_sha256,expires_at)
    SELECT ?1,?2,?3 FROM users WHERE id=?1
      AND NOT EXISTS (SELECT 1 FROM account_deletion_intents WHERE user_id=?1)
    ON CONFLICT(user_id) DO UPDATE SET code_sha256=excluded.code_sha256,expires_at=excluded.expires_at`)
    .bind(userId, await credentialDigest(code), expires_at).run();
  if (result.meta.changes !== 1) throw new Error('account_unavailable');
  return { code, expires_at };
}

/** D1 atomic counters are shared across isolates and OAuth client registrations. */
export async function allowCoachAuthorization(db: D1Database, address: string): Promise<{ allowed: boolean; retryAfter: number }> {
  const now = Date.now(), window = Math.floor(now / 60_000) * 60_000;
  const bucket = `coach:ip:${await credentialDigest(address)}`;
  const results = await db.batch<{ attempts?: number }>([
    db.prepare('DELETE FROM auth_rate_limits WHERE window_start < ?1').bind(window - 60_000),
    db.prepare(`INSERT INTO auth_rate_limits(bucket,window_start,attempts) VALUES (?1,?2,1)
      ON CONFLICT(bucket) DO UPDATE SET window_start=excluded.window_start,
        attempts=CASE WHEN window_start=excluded.window_start THEN attempts+1 ELSE 1 END
      RETURNING attempts`).bind(bucket, window),
  ]);
  return { allowed: Number(results[1]!.results[0]?.attempts) <= 10,
    retryAfter: Math.max(1, Math.ceil((window + 60_000 - now) / 1000)) };
}

export async function authorizeCoachConnectCode(db: D1Database, connectCode: string, input: {
  code: string; client_id: string; redirect_uri: string; code_challenge: string;
  scope: string; resource: string | null; expires_at: number;
}): Promise<boolean> {
  if (!/^[A-Za-z0-9_-]{43}$/.test(connectCode)) return false;
  const digest = await credentialDigest(connectCode), now = Date.now();
  const [inserted] = await db.batch([
    db.prepare(`INSERT INTO oauth_codes(code,client_id,redirect_uri,code_challenge,code_challenge_method,scope,resource,expires_at,created_at,user_id)
      SELECT ?1,?2,?3,?4,'S256',?5,?6,?7,?8,c.user_id FROM coach_connect_codes c
      JOIN users u ON u.id=c.user_id WHERE c.code_sha256=?9 AND c.expires_at>?8
        AND NOT EXISTS (SELECT 1 FROM account_deletion_intents WHERE user_id=c.user_id)
        AND NOT EXISTS (SELECT 1 FROM account_deletion_receipts WHERE user_id=c.user_id)`)
      .bind(input.code,input.client_id,input.redirect_uri,input.code_challenge,input.scope,input.resource,input.expires_at,now,digest),
    db.prepare('DELETE FROM coach_connect_codes WHERE code_sha256=?1 AND changes()=1').bind(digest),
  ]);
  return inserted!.meta.changes === 1;
}
