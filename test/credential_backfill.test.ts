import { applyD1Migrations, env } from 'cloudflare:test';
import { beforeAll, expect, it } from 'vitest';
import * as codec from '../src/credentials';
import { activateIntervalsSourceFence, getUserIntervalsCreds, rotateOAuthRefreshToken } from '../src/db';
import { validateBearer } from '../src/oauth';
// @ts-expect-error The release CLI is JavaScript; exercise its real SQL and REST encoding.
import { backfillCredentials, encodeQuery } from '../scripts/backfill-security-credentials.mjs';

beforeAll(async () => { await applyD1Migrations(env.DB, env.TEST_MIGRATIONS); });
async function query(sql: string, params: unknown[] = []): Promise<any[]> {
  const encoded = encodeQuery(sql, params);
  return (await env.DB.prepare(encoded.sql).bind(...encoded.params).all()).results;
}
async function seed() {
  const id = crypto.randomUUID();
  await env.DB.prepare(`INSERT INTO users(id,apple_sub,created_at,intervals_api_key,intervals_athlete_id)
    VALUES (?1,?1,1,'legacy-provider-secret','legacy-athlete')`).bind(id).run();
  await env.DB.prepare(`INSERT INTO oauth_clients(client_id,redirect_uris,created_at) VALUES ('legacy-client','[]',1)`).run();
  await env.DB.prepare(`INSERT INTO oauth_tokens(access_token,refresh_token,client_id,scope,expires_at,created_at,user_id)
    VALUES ('legacy-access','legacy-refresh','legacy-client','mcp',?1,1,?2)`)
    .bind(Math.floor(Date.now()/1000)+3600,id).run();
  return id;
}

it.each([false,true])('backfills without breaking clients, fences old writers, and is idempotent (source fence=%s)', async enabled => {
  const id = await seed();
  if (enabled) await activateIntervalsSourceFence(env.DB,Date.now());
  const before = await env.DB.prepare('SELECT intervals_credential_generation AS generation FROM users WHERE id=?1').bind(id).first<{generation:number}>();
  expect(await backfillCredentials(query,codec,env.CREDENTIAL_ENCRYPTION_KEY))
    .toEqual({ providerRows:1,coachRows:1,enforced:true });
  expect((await getUserIntervalsCreds(env.DB,id,env.CREDENTIAL_ENCRYPTION_KEY)).api_key).toBe('legacy-provider-secret');
  expect((await getUserIntervalsCreds(env.DB,id,env.CREDENTIAL_ENCRYPTION_KEY)).credential_generation).toBe(before!.generation+1);
  const stored = await env.DB.prepare('SELECT intervals_api_key AS value FROM users WHERE id=?1').bind(id).first<{value:string}>();
  expect(stored!.value).toMatch(/^sealed:v1:/);
  expect(await validateBearer(env,'legacy-access')).toBe(id);
  expect(await validateBearer(env,await codec.oauthTokenDigest('legacy-access'))).toBeNull();
  expect(await backfillCredentials(query,codec,env.CREDENTIAL_ENCRYPTION_KEY))
    .toEqual({ providerRows:0,coachRows:0,enforced:true });
  await expect(query("UPDATE users SET intervals_api_key='raw' WHERE id=?1",[id])).rejects.toThrow('plaintext_provider_credential');
  await expect(query("UPDATE oauth_tokens SET refresh_token='raw'")).rejects.toThrow('plaintext_coach_credential');
  await expect(query('UPDATE credential_storage_policy SET enforced=0')).rejects.toThrow('credential_storage_not_ready');
});

it('rejects the wrong key before changing any row and does not claim completion', async () => {
  const id = await seed();
  const other = crypto.randomUUID();
  const encrypted = await codec.sealCredential('existing',env.CREDENTIAL_ENCRYPTION_KEY,other,'intervals-api-key');
  await query('INSERT INTO users(id,apple_sub,created_at,intervals_api_key) VALUES (?1,?1,1,?2)',[other,encrypted]);
  const wrongKey = btoa('x'.repeat(32));
  await expect(backfillCredentials(query,codec,wrongKey)).rejects.toThrow('credential_decryption_failed');
  expect((await query('SELECT intervals_api_key AS value FROM users WHERE id=?1',[id]))[0].value).toBe('legacy-provider-secret');
  expect((await query('SELECT enforced FROM credential_storage_policy'))[0].enforced).toBe(0);
});

it('does not overwrite a concurrent connection replacement or activate with plaintext remaining', async () => {
  const id = await seed();
  let replaced = false;
  const racedQuery = async (sql: string, params: unknown[] = []) => {
    if (!replaced && sql.startsWith('UPDATE users')) {
      replaced = true;
      await query("UPDATE users SET intervals_api_key='replacement',intervals_credential_generation=intervals_credential_generation+1 WHERE id=?1",[id]);
    }
    return query(sql,params);
  };
  await expect(backfillCredentials(racedQuery,codec,env.CREDENTIAL_ENCRYPTION_KEY)).rejects.toThrow('credential_storage_not_ready');
  expect((await query('SELECT intervals_api_key AS value FROM users WHERE id=?1',[id]))[0].value).toBe('replacement');
  expect((await query('SELECT enforced FROM credential_storage_policy'))[0].enforced).toBe(0);
  expect(await backfillCredentials(query,codec,env.CREDENTIAL_ENCRYPTION_KEY)).toMatchObject({providerRows:1,enforced:true});
});

it('allows a refresh validated before backfill to rotate once after enforcement', async () => {
  const id = await seed();
  const [validated] = await query('SELECT * FROM oauth_tokens');
  await backfillCredentials(query,codec,env.CREDENTIAL_ENCRYPTION_KEY);
  const rotation = {
    ...validated, presented_refresh_token:'legacy-refresh', presented_client_id:'legacy-client',
    access_token:'successor-access', refresh_token:'successor-refresh',
    access_expires_at:Math.floor(Date.now()/1000)+600,
    consumed_refresh_sha256:await codec.credentialDigest('legacy-refresh'),
  };
  expect(await rotateOAuthRefreshToken(env.DB,rotation)).toMatchObject({access_token:'successor-access'});
  expect(await validateBearer(env,'successor-access')).toBe(id);
  expect(await rotateOAuthRefreshToken(env.DB,rotation)).toBeNull();
  expect((await query('SELECT access_token FROM oauth_tokens'))[0].access_token).toBe(await codec.oauthTokenDigest('successor-access'));
});
