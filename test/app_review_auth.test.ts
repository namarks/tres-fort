import { applyD1Migrations, env } from 'cloudflare:test';
import { Hono } from 'hono';
import { beforeAll, describe, expect, it } from 'vitest';
import { decode } from 'hono/jwt';
import { APP_REVIEW_SUB, APP_REVIEW_USERNAME } from '../src/appReview';
import { issueAppJwt } from '../src/auth';
import { ensureAppReviewUser, ensureOwnerUser, findOwnerRow, getPlanTree, getActivePlan, createGroup, createInvite, isBootstrapClaimEligible } from '../src/db';
import { createAuthRoutes } from '../src/routes/auth';
import { apiRoutes } from '../src/routes/api';
import { intervalsAuthRoutes } from '../src/routes/intervalsAuth';
import type { Env, HonoEnv } from '../src/types';

const PASSWORD = 'synthetic-review-password-only-for-tests';
let bindings: Env;
const app = new Hono<HonoEnv>().route('/auth', createAuthRoutes())
  .route('/auth/intervals', intervalsAuthRoutes).route('/api', apiRoutes);
async function request(path: string, method = 'GET', body?: unknown, jwt?: string, overrides: Partial<Env> = {}, headers: Record<string,string> = {}) {
  return app.request(`https://review.test${path}`, { method, headers: {
    'Content-Type': 'application/json', ...(jwt ? { Authorization: `Bearer ${jwt}` } : {}), ...headers,
  }, ...(body === undefined || method === 'GET' ? {} : { body: JSON.stringify(body) }) }, { ...bindings, ...overrides });
}
async function login() {
  const response = await request('/auth/review', 'POST', { username: APP_REVIEW_USERNAME, password: PASSWORD });
  expect(response.status).toBe(200);
  expect(response.headers.get('Cache-Control')).toBe('no-store');
  return response.json<{jwt:string; user:{id:string}}>();
}
beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(PASSWORD));
  bindings = { DB: env.DB, APPLE_BUNDLE_ID: 'test.bundle', APP_JWT_SECRET: 'synthetic-jwt-secret',
    OWNER_APPLE_SUB: 'real-owner-sub', APP_REVIEW_PASSWORD_SHA256: Array.from(new Uint8Array(digest), b => b.toString(16).padStart(2, '0')).join('') };
});

describe('dedicated reviewer authentication', () => {
  it('fails closed without configuration, owner identity, or correct bounded credentials', async () => {
    const body = { username: APP_REVIEW_USERNAME, password: PASSWORD };
    for (const override of [{APP_REVIEW_PASSWORD_SHA256: undefined}, {APP_REVIEW_PASSWORD_SHA256:'bad'}, {OWNER_APPLE_SUB:undefined}, {OWNER_APPLE_SUB:APP_REVIEW_SUB}]) {
      expect((await request('/auth/review', 'POST', body, undefined, override)).status).toBe(404);
    }
    for (const bad of [null, [], {}, {...body, username:'real-owner-sub'}, {...body, password:'incorrect'}, {...body, password:PASSWORD+'x'}, {...body,password:42}]) {
      expect((await request('/auth/review', 'POST', bad)).status).toBe(401);
    }
    expect((await request('/auth/review','POST',{...body,password:'x'.repeat(3000)})).status).toBe(413);
    expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM users').first<number>('n')).toBe(0);
  });

  it('atomically seeds only one sample account and preserves edits on repeat/concurrent login', async () => {
    const owner = (await ensureOwnerUser(env.DB, bindings.OWNER_APPLE_SUB))!;
    const before = await env.DB.prepare('SELECT * FROM users WHERE id=?1').bind(owner.id).first();
    const [a,b] = await Promise.all([login(),login()]);
    expect(a.user.id).toBe(b.user.id);
    expect(a.user.id).not.toBe(owner.id);
    expect(decode(a.jwt).payload.app_review).toBe(true);
    const plan = (await getActivePlan(env.DB, a.user.id))!;
    const tree = await getPlanTree(env.DB, a.user.id);
    expect(tree!.workouts).toHaveLength(1);
    expect(tree!.workouts[0]!.exercises).toHaveLength(3);
    expect(await env.DB.prepare('SELECT COUNT(*) AS n FROM plan_snapshots WHERE user_id=?1').bind(a.user.id).first<number>('n')).toBe(1);
    expect((await request('/api/me/profile','PATCH',{display_name:'Review edits'},a.jwt)).status).toBe(200);
    await login();
    expect(await env.DB.prepare('SELECT display_name FROM users WHERE id=?1').bind(a.user.id).first<string>('display_name')).toBe('Review edits');
    expect(await env.DB.prepare('SELECT * FROM users WHERE id=?1').bind(owner.id).first()).toEqual(before);
  });

  it('cannot become the owner even before an owner exists or after configuration changes', async () => {
    const review = (await ensureAppReviewUser(env.DB))!;
    expect(await findOwnerRow(env.DB,undefined)).toBeNull();
    expect(await findOwnerRow(env.DB,APP_REVIEW_SUB)).toBeNull();
    expect(await ensureOwnerUser(env.DB,APP_REVIEW_SUB)).toBeNull();
    expect(await isBootstrapClaimEligible(env.DB)).toBe(true);
    const owner = (await ensureOwnerUser(env.DB,undefined))!;
    expect(owner.id).not.toBe(review.id);
    expect(owner.apple_sub).toBe('mcp-owner');
  });

  it('uses ordinary account-scoped workout, state and export paths and denies personal sources and groups', async () => {
    const owner = (await ensureOwnerUser(env.DB,bindings.OWNER_APPLE_SUB))!;
    const group = await createGroup(env.DB,owner.id,'Private real group');
    const invite = await createInvite(env.DB,owner.id,group.id);
    const {jwt,user} = await login();
    const state = await request('/api/state','GET',undefined,jwt);
    expect(state.status).toBe(200);
    const exported = await request('/api/me/export','GET',undefined,jwt);
    expect(exported.status).toBe(200);
    const text = await exported.text();
    expect(text).toContain(user.id);
    expect(text).not.toContain(owner.id);
    expect(text).not.toContain('Private real group');
    const groups = await request('/api/groups','GET',undefined,jwt);
    expect(groups.status).toBe(200);
    expect(await groups.text()).not.toContain(group.id);
    for (const [method,path] of [
      ['POST','/api/groups'], ['POST','/api/groups/join'], ['GET',`/api/groups/invite/${invite.code}`],
      ['GET',`/api/groups/${group.id}/feed`], ['POST','/api/activities/healthkit'],
      ['PATCH','/api/me/integrations/intervals'], ['POST','/api/me/mcp-passphrase'],
      ['PATCH','/api/me/health-sharing'], ['PUT',`/api/me/group-blocks/${owner.id}`],
      ['POST','/auth/intervals/start'], ['POST','/api/future-sensitive-feature'],
    ]) {
      expect((await request(path!,method!,{},jwt)).status, path).toBe(403);
    }
    expect((await request('/api/me','GET',undefined,jwt,{APP_REVIEW_PASSWORD_SHA256:undefined})).status).toBe(401);
    const wrongClaim = await issueAppJwt(owner.id,bindings.APP_JWT_SECRET,{appReview:true});
    expect((await request('/api/me','GET',undefined,wrongClaim)).status).toBe(401);
    const missingClaim = await issueAppJwt(user.id,bindings.APP_JWT_SECRET);
    expect((await request('/api/me','GET',undefined,missingClaim)).status).toBe(401);
  });

  it('logs and completes a sample workout through normal REST and cannot edit another account session', async () => {
    const {jwt,user} = await login();
    const tree = (await getPlanTree(env.DB,user.id))!;
    const workout = tree.workouts[0]!;
    const created = await request('/api/sessions','POST',{date:'2026-09-12',workout_id:workout.id},jwt);
    expect(created.status).toBe(201);
    const session = await created.json<{id:string}>();
    const slot = workout.exercises[0]!;
    const logged = await request(`/api/sessions/${session.id}/sets`,'POST',{
      id:crypto.randomUUID(), exercise_id:slot.exercise_id, template_exercise_id:slot.id,
      set_index:1, weight:95, reps:5,
    },jwt);
    expect(logged.status).toBe(201);
    expect((await request(`/api/sessions/${session.id}`,'PATCH',{status:'completed'},jwt)).status).toBe(200);
    const summary = await request(`/api/sessions/${session.id}/summary`,'GET',undefined,jwt);
    expect(summary.status).toBe(200);
    expect(await summary.text()).toContain('95');
    const owner = (await ensureOwnerUser(env.DB,bindings.OWNER_APPLE_SUB))!;
    const ownerJwt = await issueAppJwt(owner.id,bindings.APP_JWT_SECRET);
    expect((await request(`/api/sessions/${session.id}/summary`,'GET',undefined,ownerJwt)).status).toBe(404);
    expect((await request(`/api/sessions/${session.id}`,'PATCH',{status:'completed'},ownerJwt)).status).toBe(404);
  });

  it('preserves reviewer restrictions through renewal and revokes deleted account bearers', async () => {
    const original = await login();
    const renewal = await request('/auth/renew','POST',{},original.jwt);
    expect(renewal.status).toBe(200);
    const {jwt} = await renewal.json<{jwt:string}>();
    expect(decode(jwt).payload.app_review).toBe(true);
    expect((await request('/api/groups/join','POST',{},jwt)).status).toBe(403);
    const headers = {'X-Account-Deletion-Key': crypto.randomUUID()};
    expect((await request('/api/me','DELETE',undefined,jwt,{},headers)).status).toBe(200);
    expect((await request('/api/me','DELETE',undefined,jwt,{},headers)).status).toBe(200);
    const fresh = await login();
    expect(fresh.user.id).not.toBe(original.user.id);
    expect((await request('/api/state','GET',undefined,jwt)).status).toBe(401);
    expect((await request('/auth/renew','POST',{},jwt)).status).toBe(401);
    expect((await request('/api/state','GET',undefined,fresh.jwt)).status).toBe(200);
  });
});
