#!/usr/bin/env node
// Explicit release operation. No credentials, SQL parameters or provider replies
// are printed or written to disk. See docs/audits/security-2026-11-release.md.
export async function backfillCredentials(query, codec, key) {
  // Validate the key before reading any credentials, including an empty DB.
  await codec.sealCredential('validation', key, 'migration', 'validation');
  const users = await query(`SELECT id,intervals_api_key,intervals_oauth_access_token,
    intervals_oauth_refresh_token,intervals_credential_generation FROM users`);
  const prepared = [];
  for (const user of users) {
    const columns = ['intervals_api_key','intervals_oauth_access_token','intervals_oauth_refresh_token'];
    const purposes = ['intervals-api-key','intervals-access-token','intervals-refresh-token'];
    const old = columns.map(column => user[column]);
    // Authenticate every existing ciphertext before writing anything. A wrong
    // deployment key must not produce a partially converted mixed-key database.
    const next = await Promise.all(old.map(async (value, index) => codec.sealCredential(
      await codec.openCredential(value, key, user.id, purposes[index]), key, user.id, purposes[index], value,
    )));
    if (next.some((value, index) => value !== old[index])) prepared.push({ user, old, next });
  }
  let providerRows = 0, coachRows = 0;
  for (const { user, old, next } of prepared) {
    const changed = await query(`UPDATE users SET intervals_api_key=?1,intervals_oauth_access_token=?2,
      intervals_oauth_refresh_token=?3,intervals_credential_generation=intervals_credential_generation+1,
      intervals_events_synced_at=NULL,intervals_activities_synced_at=NULL,
      intervals_events_sync_attempt=0,intervals_activities_sync_attempt=0,
      intervals_protocol_write_seq=intervals_protocol_write_seq
        + COALESCE((SELECT enabled FROM intervals_source_fence WHERE singleton=1),0)
      WHERE id=?4 AND intervals_api_key IS ?5 AND intervals_oauth_access_token IS ?6
        AND intervals_oauth_refresh_token IS ?7 AND intervals_credential_generation=?8
      RETURNING 1 AS changed`, [...next,user.id,...old,user.intervals_credential_generation]);
    providerRows += changed.length;
  }
  const tokens = await query('SELECT access_token,refresh_token FROM oauth_tokens');
  for (const token of tokens) {
    const old = [token.access_token,token.refresh_token];
    const next = await Promise.all(old.map(value => value.startsWith('sha256:') ? value : codec.oauthTokenDigest(value)));
    if (next.every((value,index) => value === old[index])) continue;
    coachRows += (await query(`UPDATE oauth_tokens SET access_token=?1,refresh_token=?2
      WHERE access_token=?3 AND refresh_token=?4 RETURNING 1 AS changed`, [...next,...old])).length;
  }
  // A database trigger checks every row atomically. Concurrent legacy writes
  // cannot slip through between the scan and irreversible enforcement.
  const enforced = await query('UPDATE credential_storage_policy SET enforced=1 WHERE id=1 RETURNING enforced');
  if (enforced[0]?.enforced !== 1) throw new Error('credential_storage_not_enforced');
  return { providerRows, coachRows, enforced: true };
}

// The REST API documents string parameters. Bind one JSON array and extract
// typed values in SQLite so null credentials stay NULL, never the string "null".
export function encodeQuery(sql, params = []) {
  return params.length ? {
    sql: sql.replace(/\?(\d+)/g, (_, index) => `json_extract(?1,'$[${Number(index) - 1}]')`),
    params: [JSON.stringify(params)],
  } : { sql, params: [] };
}

async function main() {
  if (process.argv.slice(2).join(' ') !== '--apply') throw new Error('explicit_apply_required');
  const { CLOUDFLARE_ACCOUNT_ID: account, CLOUDFLARE_D1_DATABASE_ID: database,
    CLOUDFLARE_API_TOKEN: token, CREDENTIAL_ENCRYPTION_KEY: key } = process.env;
  if (!/^[a-f0-9]{32}$/i.test(account ?? '') || !/^[a-f0-9-]{36}$/i.test(database ?? '') || !token || !key) {
    throw new Error('missing_release_environment');
  }
  // Node 22.18+ can load this pure TypeScript module without a generated copy.
  const codec = await import('../src/credentials.ts');
  const query = async (sql, params = []) => {
    const response = await fetch(`https://api.cloudflare.com/client/v4/accounts/${account}/d1/database/${database}/query`, {
      method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(encodeQuery(sql, params)), signal: AbortSignal.timeout(30_000),
    });
    const body = await response.json();
    if (!response.ok || !body.success || !body.result?.[0]?.success) throw new Error('credential_backfill_query_failed');
    return body.result[0].results;
  };
  console.log(JSON.stringify(await backfillCredentials(query, codec, key)));
}

if (typeof process !== 'undefined' && process.argv[1]?.endsWith('/backfill-security-credentials.mjs')) {
  main().catch(() => { console.error('Credential backfill did not complete. Inspect value-free storage status; do not log query parameters.'); process.exitCode = 1; });
}
