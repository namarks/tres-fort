import {
  env,
  applyD1Migrations,
  SELF,
  createScheduledController,
  createExecutionContext,
  waitOnExecutionContext,
} from 'cloudflare:test';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import worker from '../src/index';
import {
  ensureOwnerUser,
  exportSessionLoad,
  getActivePlan,
  logSet,
} from '../src/db';
import type { Env } from '../src/types';
import type { Fetcher } from '../src/intervals';

const BASE = 'https://tres-forte.test';
const TOKEN = 'test-mcp-token';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

// HERMETICITY (root-cause fix — see the long note in loadexport_t.test.ts):
// the shared singleWorker D1 + single-user invariant make
// getOrCreateSession reuse the same session id across suites that share a
// hardcoded date (this file and loadexport_t both use 2026-05-19).
// session_load_exports is keyed by session_id and never truncated by
// applyD1Migrations, so a row left by another suite makes the single-flight
// claim correctly refuse → export defers, never `ok`. Purge before+after
// every test so order can't matter; the guard/assertions are untouched.
async function purgeExportLedger() {
  await env.DB.prepare('DELETE FROM session_load_exports').run();
}

beforeEach(async () => {
  await purgeExportLedger();
});

afterEach(async () => {
  vi.unstubAllGlobals();
  await purgeExportLedger();
});

let rpcId = 0;
async function mcp(name: string, args: unknown) {
  const r = await SELF.fetch(`${BASE}/mcp`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', Authorization: `Bearer ${TOKEN}` },
    body: JSON.stringify({ jsonrpc: '2.0', id: ++rpcId, method: 'tools/call', params: { name, arguments: args } }),
  });
  return r.json<any>();
}

const failFetcher: Fetcher = async () => ({ ok: false, status: 503, json: async () => ({}) });

async function seedPendingExport(fatigue: number) {
  await mcp('update_plan', {
    name: 'U-Plan',
    days: [{ day_label: 'A', name: 'Pull A', exercises: [{ exercise: 'deadlift', target_sets: 3, target_reps: 5 }] }],
  });
  const owner = await ensureOwnerUser(env.DB, undefined);
  const plan = await getActivePlan(env.DB, owner.id);
  // Globally-unique session id (root-cause fix — see note above): never
  // reuse a (owner,date)-keyed session, so this suite's
  // session_load_exports PK can't collide with loadexport_t's.
  const sessionId = crypto.randomUUID();
  const seedTs = Date.now();
  await env.DB
    .prepare(
      'INSERT INTO sessions (id,user_id,plan_id,day_template_id,date,status,started_at,completed_at,perceived_fatigue,notes,created_at,updated_at) VALUES (?1,?2,?3,NULL,?4,?5,NULL,NULL,NULL,NULL,?6,?6)',
    )
    .bind(sessionId, owner.id, plan!.id, '2026-05-19', 'planned', seedTs)
    .run();
  const session = { id: sessionId };
  const exId = (await env.DB.prepare('SELECT exercise_id FROM template_exercises LIMIT 1').first<{ exercise_id: string }>())!.exercise_id;
  await logSet(env.DB, owner.id, {
    id: crypto.randomUUID(),
    session_id: session.id,
    exercise_id: exId,
    set_index: 1,
    weight: 180,
    reps: 5,
    rpe: 9,
    is_warmup: false,
    source: 'mcp',
  });
  await env.DB.prepare(
    "UPDATE sessions SET status='completed', started_at=1000000, completed_at=4600000, perceived_fatigue=?2 WHERE id=?1",
  )
    .bind(session.id, fatigue)
    .run();
  // Force a pending export via a failing push.
  const r = await exportSessionLoad(env.DB, env as unknown as Env, owner.id, session.id, {
    fetcher: failFetcher,
  });
  expect(r.status).toBe('pending');
  return { ownerId: owner.id, sessionId: session.id };
}

describe('scheduled() cron — retry pending lifting-load exports (milestone u)', () => {
  it('pending → cron retry → success flips status to ok (idempotent same row)', async () => {
    const { sessionId } = await seedPendingExport(8);

    // intervals.icu now healthy; cron's default fetcher is global fetch.
    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string, init?: any) => {
        if (String(url).includes('intervals.icu')) {
          return new Response(JSON.stringify({ id: 'ev-cron-1' }), {
            status: 200,
            headers: { 'content-type': 'application/json' },
          });
        }
        return new Response('[]', { status: 200 });
      }),
    );

    const ctx = createExecutionContext();
    await worker.scheduled!(
      createScheduledController({ scheduledTime: new Date(), cron: '0 */6 * * *' }),
      env,
      ctx,
    );
    await waitOnExecutionContext(ctx);

    const row = await env.DB.prepare(
      'SELECT * FROM session_load_exports WHERE session_id=?1',
    )
      .bind(sessionId)
      .first<any>();
    expect(row.status).toBe('ok');
    expect(row.intervals_ref).toBe('ev-cron-1');
    expect(row.attempts).toBe(2); // 1 (initial fail) + 1 (cron retry)

    // Still exactly one row — idempotent by session_id.
    const cnt = await env.DB.prepare(
      'SELECT COUNT(*) c FROM session_load_exports WHERE session_id=?1',
    )
      .bind(sessionId)
      .first<{ c: number }>();
    expect(cnt!.c).toBe(1);
  });

  it('a failing retry stays pending and the cron does not throw', async () => {
    const { sessionId } = await seedPendingExport(7);

    // intervals.icu still down; ride-sync also 500s — cron must absorb both.
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => new Response('down', { status: 500 })),
    );

    const ctx = createExecutionContext();
    await expect(
      (async () => {
        await worker.scheduled!(
          createScheduledController({ scheduledTime: new Date(), cron: '0 */6 * * *' }),
          env,
          ctx,
        );
        await waitOnExecutionContext(ctx);
      })(),
    ).resolves.toBeUndefined();

    const row = await env.DB.prepare(
      'SELECT status, attempts FROM session_load_exports WHERE session_id=?1',
    )
      .bind(sessionId)
      .first<{ status: string; attempts: number }>();
    expect(row!.status).toBe('pending');
    expect(row!.attempts).toBe(2); // bumped on the failed retry
  });
});
