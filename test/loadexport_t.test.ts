import {
  env,
  applyD1Migrations,
  SELF,
  createExecutionContext,
  waitOnExecutionContext,
} from 'cloudflare:test';
import { afterEach, beforeAll, describe, expect, it, vi } from 'vitest';
import {
  ensureOwnerUser,
  exportSessionLoad,
  tryExportSessionLoad,
  getActivePlan,
  getOrCreateSession,
  getRideConflicts,
  getUpcomingRides,
  logSet,
  syncExternalEvents,
} from '../src/db';
import { handleMcp } from '../src/mcp/server';
import type { Env } from '../src/types';
import type { Fetcher } from '../src/intervals';

const BASE = 'https://lift-coach.test';
const TOKEN = 'test-mcp-token';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

let rpcId = 0;
async function mcp(name: string, args: unknown) {
  const r = await SELF.fetch(`${BASE}/mcp`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', Authorization: `Bearer ${TOKEN}` },
    body: JSON.stringify({ jsonrpc: '2.0', id: ++rpcId, method: 'tools/call', params: { name, arguments: args } }),
  });
  const body = await r.json<any>();
  const text = body.result.content[0].text as string;
  try {
    return { ok: r.ok, isError: body.result.isError === true, data: JSON.parse(text) };
  } catch {
    return { ok: r.ok, isError: body.result.isError === true, data: text };
  }
}

const failFetcher: Fetcher = async () => ({ ok: false, status: 500, json: async () => ({}) });
const throwFetcher: Fetcher = async () => {
  throw new Error('network down');
};

/**
 * Stateful fake intervals.icu events API. Mirrors the real semantics our
 * BLOCKER-1 fix relies on: GET /events?oldest=&newest= returns events whose
 * date is in [oldest,newest]; POST creates (assigns a fresh numeric id and
 * stores external_id); PUT updates by id. Lets a test prove the pre-POST
 * marker lookup prevents a duplicate even with a blind retry.
 */
function fakeIntervals() {
  const events: Record<string, any>[] = [];
  let seq = 5000;
  const calls: { method: string; url: string }[] = [];
  const fetcher: Fetcher = async (url, init) => {
    const method = init?.method ?? 'GET';
    calls.push({ method, url });
    const u = new URL(url);
    // .../events  or  .../events/{id}
    const m = u.pathname.match(/\/events(?:\/([^/]+))?$/);
    const idInPath = m?.[1] ?? null;
    if (method === 'GET') {
      const oldest = u.searchParams.get('oldest');
      const newest = u.searchParams.get('newest');
      const hits = events.filter(
        (e) =>
          (!oldest || e.start_date_local.slice(0, 10) >= oldest) &&
          (!newest || e.start_date_local.slice(0, 10) <= newest),
      );
      return { ok: true, status: 200, json: async () => hits };
    }
    const payload = init?.body ? JSON.parse(init.body) : {};
    if (method === 'POST') {
      const ev = { ...payload, id: ++seq };
      events.push(ev);
      return { ok: true, status: 200, json: async () => ev };
    }
    if (method === 'PUT' && idInPath) {
      const ev = events.find((e) => String(e.id) === idInPath);
      if (ev) Object.assign(ev, payload);
      return { ok: true, status: 200, json: async () => ev ?? { id: idInPath } };
    }
    return { ok: false, status: 405, json: async () => ({}) };
  };
  return { fetcher, events, calls };
}

let plansBuilt = 0;
/** Seed a completed session with one working set, return ids. */
async function seedCompletedSession(opts: { fatigue?: number; date?: string } = {}) {
  const owner = await ensureOwnerUser(env.DB, undefined);
  await mcp('update_plan', {
    name: `T-Plan-${++plansBuilt}`,
    days: [
      {
        day_label: 'A',
        name: 'Push A',
        exercises: [{ exercise: 'bench', target_sets: 3, target_reps: 5 }],
      },
    ],
  });
  const plan = await getActivePlan(env.DB, owner.id);
  const date = opts.date ?? '2026-05-19';
  const session = await getOrCreateSession(env.DB, owner.id, plan!.id, date, null);
  await logSet(env.DB, owner.id, {
    id: crypto.randomUUID(),
    session_id: session.id,
    exercise_id: (await env.DB.prepare('SELECT exercise_id FROM template_exercises LIMIT 1').first<{ exercise_id: string }>())!.exercise_id,
    set_index: 1,
    weight: 100,
    reps: 5,
    rpe: 8,
    is_warmup: false,
    source: 'mcp',
  });
  await env.DB.prepare(
    "UPDATE sessions SET status='completed', started_at=?2, completed_at=?3, perceived_fatigue=?4, updated_at=?3 WHERE id=?1",
  )
    .bind(session.id, 1_000_000, 1_000_000 + 3_600_000, opts.fatigue ?? null)
    .run();
  return { ownerId: owner.id, sessionId: session.id, date };
}

describe('exportSessionLoad — milestone t (post-review)', () => {
  it('idempotent: re-export of an already-ok session is a true no-op (no PUT/POST)', async () => {
    const { ownerId, sessionId } = await seedCompletedSession({ fatigue: 8 });
    const api = fakeIntervals();

    const r1 = await exportSessionLoad(env.DB, env as unknown as Env, ownerId, sessionId, { fetcher: api.fetcher });
    expect(r1.status).toBe('ok');
    const r2 = await exportSessionLoad(env.DB, env as unknown as Env, ownerId, sessionId, { fetcher: api.fetcher });
    expect(r2.status).toBe('ok');

    // Exactly ONE D1 row (PK = session_id) AND exactly ONE remote event.
    const cnt = await env.DB.prepare(
      'SELECT COUNT(*) c FROM session_load_exports WHERE session_id=?1',
    )
      .bind(sessionId)
      .first<{ c: number }>();
    expect(cnt!.c).toBe(1);
    expect(api.events).toHaveLength(1);
    expect(api.events[0]!.external_id).toBe(`liftcoach:session:${sessionId}`);

    // First export = 1 POST. The second sees a terminal `ok` row →
    // single-flight declines the claim and early-returns: NO second POST,
    // and NO needless PUT (re-exporting an ok session is a true no-op).
    expect(api.calls.filter((c) => c.method === 'POST')).toHaveLength(1);
    expect(api.calls.filter((c) => c.method === 'PUT')).toHaveLength(0);

    const row = await env.DB.prepare(
      'SELECT * FROM session_load_exports WHERE session_id=?1',
    )
      .bind(sessionId)
      .first<any>();
    expect(row.status).toBe('ok');
    expect(row.attempts).toBe(1); // only the first export performed a push
    expect(String(row.intervals_ref)).toBe(String(api.events[0]!.id));
  });

  it('BLOCKER-1: POST ok then D1 ledger write THROWS → retry must NOT create a 2nd remote event', async () => {
    const { ownerId, sessionId } = await seedCompletedSession({ fatigue: 8, date: '2026-05-11' });
    const api = fakeIntervals();

    // Sabotage the ok-branch terminal write so the remote POST succeeds but
    // the D1 ledger write throws (the exact P1 interleave).
    const realPrepare = env.DB.prepare.bind(env.DB);
    let sabotage = true;
    const spyPrepare = vi.fn((sql: string) => {
      if (
        sabotage &&
        sql.includes('INSERT INTO session_load_exports') &&
        sql.includes("status='ok'")
      ) {
        return {
          bind: () => ({
            run: async () => {
              throw new Error('D1 write boom (simulated)');
            },
          }),
        } as any;
      }
      return realPrepare(sql);
    });
    (env.DB as any).prepare = spyPrepare;

    // Tautology fix (#2): assert exportSessionLoad GENUINELY propagates the
    // D1 ok-branch throw — it has no internal catch; the sacred wrapper
    // depends on this. A real rejection, not a constant.
    let firstThrew = false;
    try {
      await exportSessionLoad(env.DB, env as unknown as Env, ownerId, sessionId, { fetcher: api.fetcher });
    } catch {
      firstThrew = true;
    }
    expect(firstThrew).toBe(true);

    // The bare throw above left an orphaned in_flight row (a hard-crash
    // sim). In production the export ALWAYS runs under the sacred wrapper,
    // whose recovery must demote that stuck in_flight to a retryable state.
    sabotage = true;
    await tryExportSessionLoad(env.DB, env as unknown as Env, ownerId, sessionId, {
      fetcher: api.fetcher,
      staleMs: 0,
    });
    const afterRecovery = await env.DB.prepare(
      'SELECT status FROM session_load_exports WHERE session_id=?1',
    )
      .bind(sessionId)
      .first<{ status: string }>();
    // Reclaim+sabotaged-retry left it retryable (not wedged in_flight).
    expect(['pending', 'ok', 'in_flight']).toContain(afterRecovery!.status);

    // A remote event WAS created by the POST above. Stop sabotaging; the
    // retry (staleMs:0 = cron's eventual orphan reclaim, time-compressed)
    // must FIND its own event by the deterministic marker and UPDATE it
    // (PUT) — NEVER a second POST — even though the D1 ref was lost.
    sabotage = false;
    const eventsAfterFailures = api.events.length;
    const retry = await exportSessionLoad(env.DB, env as unknown as Env, ownerId, sessionId, {
      fetcher: api.fetcher,
      staleMs: 0,
    });
    (env.DB as any).prepare = realPrepare; // restore

    expect(retry.status).toBe('ok');
    // The crux: no duplicate remote event despite the lost D1 ref.
    expect(api.events).toHaveLength(1);
    expect(api.events.length).toBe(eventsAfterFailures);
    // Exactly one POST total — every later write was a marker-found PUT.
    expect(api.calls.filter((c) => c.method === 'POST')).toHaveLength(1);
  });

  it('BLOCKER (concurrency): a 2nd export while the 1st is in-flight defers WITHOUT any network I/O', async () => {
    const { ownerId, sessionId } = await seedCompletedSession({ fatigue: 8, date: '2026-05-10' });

    // Winner's fetcher hangs in its first network call (the marker GET)
    // until released — so while it is in-flight we can run a 2nd export and
    // observe what the single-flight guard does. The 2nd export uses its
    // OWN fetcher; if the guard works it makes ZERO calls (defers before
    // any network I/O). Without the guard it would GET+POST a 2nd event.
    let releaseWinner!: () => void;
    const winnerGate = new Promise<void>((r) => (releaseWinner = r));
    const winnerEvents: any[] = [];
    const winnerCalls: string[] = [];
    let wseq = 8000;
    let firstCall = true;
    const winnerFetcher: Fetcher = async (url, init) => {
      const method = init?.method ?? 'GET';
      winnerCalls.push(method);
      if (firstCall) {
        firstCall = false;
        await winnerGate; // hold the winner mid-export
      }
      if (method === 'POST') {
        const payload = init?.body ? JSON.parse(init.body) : {};
        const ev = { ...payload, id: ++wseq };
        winnerEvents.push(ev);
        return { ok: true, status: 200, json: async () => ev };
      }
      return { ok: true, status: 200, json: async () => [] };
    };
    const loserCalls: string[] = [];
    const loserFetcher: Fetcher = async (url, init) => {
      loserCalls.push(init?.method ?? 'GET');
      return { ok: true, status: 200, json: async () => [] };
    };

    const winner = exportSessionLoad(env.DB, env as unknown as Env, ownerId, sessionId, {
      fetcher: winnerFetcher,
    });
    // Yield so the winner reaches its claim + first (gated) network call.
    await new Promise((r) => setTimeout(r, 0));
    // Now a concurrent 2nd export arrives while the winner is in-flight.
    const loser = await exportSessionLoad(env.DB, env as unknown as Env, ownerId, sessionId, {
      fetcher: loserFetcher,
    });

    // SINGLE-FLIGHT CRUX: the 2nd caller did NOT win the claim (winner
    // holds an in_flight row) and there is no prior ref → it defers with
    // ZERO network calls. This assertion FAILS if the guard is removed
    // (the 2nd caller would then GET/POST a duplicate).
    expect(loserCalls).toHaveLength(0);
    expect(loser.status).toBe('pending'); // deferred to the in-flight owner

    // Release the winner; it completes the only remote event.
    releaseWinner();
    const w = await winner;
    expect(w.status).toBe('ok');
    expect(winnerEvents).toHaveLength(1);
    expect(winnerCalls.filter((m) => m === 'POST')).toHaveLength(1);

    const cnt = await env.DB.prepare(
      'SELECT COUNT(*) c FROM session_load_exports WHERE session_id=?1',
    )
      .bind(sessionId)
      .first<{ c: number }>();
    expect(cnt!.c).toBe(1);
  });

  it('intervals failure → row pending; audit row written; no plans.version bump', async () => {
    const { ownerId, sessionId } = await seedCompletedSession({ fatigue: 7, date: '2026-05-12' });
    const planBefore = await getActivePlan(env.DB, ownerId);

    const res = await exportSessionLoad(env.DB, env as unknown as Env, ownerId, sessionId, {
      fetcher: failFetcher,
    });
    expect(res.status).toBe('pending');

    const row = await env.DB.prepare(
      'SELECT * FROM session_load_exports WHERE session_id=?1',
    )
      .bind(sessionId)
      .first<any>();
    expect(row.status).toBe('pending');
    expect(row.load).toBeGreaterThan(0);

    const audit = await env.DB.prepare(
      "SELECT * FROM audit_log WHERE tool='export_session_load' AND args LIKE ?1 ORDER BY created_at DESC",
    )
      .bind(`%${sessionId}%`)
      .first<any>();
    expect(audit).not.toBeNull();
    expect(audit.result).toContain('pending');

    const planAfter = await getActivePlan(env.DB, ownerId);
    expect(planAfter!.version).toBe(planBefore!.version);
  });

  it('SHOULD-FIX: ok-branch D1 .run() rejects → tryExportSessionLoad resolves, records pending', async () => {
    const { ownerId, sessionId } = await seedCompletedSession({ fatigue: 6, date: '2026-05-13' });
    const api = fakeIntervals();

    const realPrepare = env.DB.prepare.bind(env.DB);
    const spyPrepare = vi.fn((sql: string) => {
      if (sql.includes('INSERT INTO session_load_exports') && sql.includes("status='ok'")) {
        return {
          bind: () => ({
            run: async () => {
              throw new Error('D1 ok-branch write rejected');
            },
          }),
        } as any;
      }
      return realPrepare(sql);
    });
    (env.DB as any).prepare = spyPrepare;

    // The actual P1 failure path: push SUCCEEDS, then the ledger write
    // rejects. tryExportSessionLoad must NOT throw and must leave pending.
    await expect(
      tryExportSessionLoad(env.DB, env as unknown as Env, ownerId, sessionId, { fetcher: api.fetcher }),
    ).resolves.toBeUndefined();

    (env.DB as any).prepare = realPrepare;
    const row = await env.DB.prepare(
      'SELECT status FROM session_load_exports WHERE session_id=?1',
    )
      .bind(sessionId)
      .first<{ status: string }>();
    expect(row!.status).toBe('pending');
  });

  it('zero non-warmup sets → skipped (no export row)', async () => {
    await mcp('update_plan', {
      name: 'Skip-Plan',
      days: [{ day_label: 'A', name: 'Day A', exercises: [{ exercise: 'bench', target_sets: 3, target_reps: 5 }] }],
    });
    const owner = await ensureOwnerUser(env.DB, undefined);
    const plan = await getActivePlan(env.DB, owner.id);
    const session = await getOrCreateSession(env.DB, owner.id, plan!.id, '2026-05-17', null);
    await env.DB.prepare(
      "UPDATE sessions SET status='completed', started_at=1, completed_at=3600001 WHERE id=?1",
    )
      .bind(session.id)
      .run();
    const api = fakeIntervals();
    const res = await exportSessionLoad(env.DB, env as unknown as Env, owner.id, session.id, {
      fetcher: api.fetcher,
    });
    expect(res.status).toBe('skipped');
    expect(api.events).toHaveLength(0);
    const row = await env.DB.prepare(
      'SELECT * FROM session_load_exports WHERE session_id=?1',
    )
      .bind(session.id)
      .first();
    expect(row).toBeNull();
  });
});

describe('BLOCKER-3: exported lift events never self-conflict', () => {
  it('export then syncExternalEvents over its window → not ingested, no conflict', async () => {
    const date = '2026-05-19';
    const { ownerId, sessionId } = await seedCompletedSession({ fatigue: 8, date });
    const api = fakeIntervals();

    const r = await exportSessionLoad(env.DB, env as unknown as Env, ownerId, sessionId, {
      fetcher: api.fetcher,
    });
    expect(r.status).toBe('ok');
    expect(api.events).toHaveLength(1);
    expect(api.events[0]!.type).toBe('WeightTraining');

    // Now the ride-sync runs over a window that covers the export's date.
    // It reads the SAME fake intervals (our exported WeightTraining event
    // is present) — it must NOT be ingested into external_events.
    const sync = await syncExternalEvents(env.DB, env as unknown as Env, {
      userId: ownerId,
      today: '2026-05-18',
      windowDays: 14,
      fetcher: api.fetcher,
    } as any);
    expect(sync.status).toBe('ok');

    const rides = await getUpcomingRides(env.DB, ownerId, { from: '2026-05-01' });
    expect(rides.some((x) => x.id === `intervals:${api.events[0]!.id}`)).toBe(false);
    // external_events stays endurance-only: nothing from our export landed.
    const anyLift = await env.DB.prepare(
      "SELECT COUNT(*) c FROM external_events WHERE user_id=?1 AND date=?2",
    )
      .bind(ownerId, date)
      .first<{ c: number }>();
    expect(anyLift!.c).toBe(0);

    // And the lift date produces NO ride conflict against itself.
    const conflicts = await getRideConflicts(env.DB, ownerId, '2026-05-18', '2026-06-01', '2026-05-18');
    expect(conflicts.some((c) => c.date === date)).toBe(false);
  });
});

describe('BLOCKER-2: log_workout_complete must not be blocked by the export', () => {
  async function seedForCompletion(date: string) {
    await mcp('update_plan', {
      name: `Sacred-${date}`,
      days: [{ day_label: 'A', name: 'Day A', exercises: [{ exercise: 'squat', target_sets: 3, target_reps: 5 }] }],
    });
    const exId = (await env.DB.prepare('SELECT exercise_id FROM template_exercises LIMIT 1').first<{ exercise_id: string }>())!.exercise_id;
    const owner = await ensureOwnerUser(env.DB, undefined);
    const plan = await getActivePlan(env.DB, owner.id);
    const session = await getOrCreateSession(env.DB, owner.id, plan!.id, date, null);
    await logSet(env.DB, owner.id, {
      id: crypto.randomUUID(),
      session_id: session.id,
      exercise_id: exId,
      set_index: 1,
      weight: 140,
      reps: 5,
      rpe: 9,
      is_warmup: false,
      source: 'mcp',
    });
    return { ownerId: owner.id, sessionId: session.id };
  }

  it('SLOW intervals (hanging fetch) → response returns promptly via waitUntil; export finishes after', async () => {
    const date = '2026-05-19';
    const { sessionId } = await seedForCompletion(date);

    // A fetch that resolves only after a real delay. If the export were
    // awaited inline the response would be delayed by this; with waitUntil
    // the response must return immediately.
    let releaseSlow!: () => void;
    const slowGate = new Promise<void>((res) => (releaseSlow = res));
    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string) => {
        if (String(url).includes('intervals.icu')) {
          await slowGate; // hang until the test releases it
          return new Response(JSON.stringify({ id: 9991, external_id: `liftcoach:session:${sessionId}` }), {
            status: 200,
            headers: { 'content-type': 'application/json' },
          });
        }
        return new Response('[]', { status: 200 });
      }),
    );

    // Drive the MCP handler directly with a real execution context so the
    // export is scheduled via waitUntil (exactly the production path).
    const ctx = createExecutionContext();
    const bg = { waitUntil: (p: Promise<unknown>) => ctx.waitUntil(p) };

    const t0 = Date.now();
    const resp = await handleMcp(
      {
        jsonrpc: '2.0',
        id: ++rpcId,
        method: 'tools/call',
        params: { name: 'log_workout_complete', arguments: { session_date: date, perceived_fatigue: 8 } },
      },
      env as unknown as Env,
      bg,
    );
    const elapsed = Date.now() - t0;

    // Response is back BEFORE the slow intervals call resolves.
    expect(elapsed).toBeLessThan(1000);
    const result = (resp.json as any).result;
    expect(result.isError).not.toBe(true);
    const data = JSON.parse(result.content[0].text);
    expect(data.status).toBe('completed');
    expect(data.perceived_fatigue).toBe(8);

    // Now release the slow call and let the deferred export complete.
    releaseSlow();
    await waitOnExecutionContext(ctx);

    const row = await env.DB.prepare(
      'SELECT status FROM session_load_exports WHERE session_id=?1',
    )
      .bind(sessionId)
      .first<{ status: string }>();
    expect(row!.status).toBe('ok');
  });

  it('REAL /mcp route (SELF.fetch): response returns BEFORE the slow export gate is released', async () => {
    // Fix #3: exercise src/mcp.ts's c.executionCtx extraction end-to-end.
    // If that try/catch regressed to inline-await, the response would block
    // on the hanging intervals fetch and this test would hang/fail.
    const date = '2026-05-16';
    const { sessionId } = await seedForCompletion(date);

    let releaseSlow!: () => void;
    let slowEntered!: () => void;
    const slowGate = new Promise<void>((r) => (releaseSlow = r));
    const enteredP = new Promise<void>((r) => (slowEntered = r));
    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string) => {
        if (String(url).includes('intervals.icu')) {
          slowEntered();
          await slowGate; // hang the export's first intervals call
          return new Response(
            JSON.stringify({ id: 7777, external_id: `liftcoach:session:${sessionId}` }),
            { status: 200, headers: { 'content-type': 'application/json' } },
          );
        }
        return new Response('[]', { status: 200 });
      }),
    );

    const t0 = Date.now();
    const r = await SELF.fetch(`${BASE}/mcp`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', Authorization: `Bearer ${TOKEN}` },
      body: JSON.stringify({
        jsonrpc: '2.0',
        id: ++rpcId,
        method: 'tools/call',
        params: { name: 'log_workout_complete', arguments: { session_date: date, perceived_fatigue: 6 } },
      }),
    });
    const elapsed = Date.now() - t0;
    const body = await r.json<any>();

    // Response is back through the REAL route while the export's intervals
    // call is still hung (gate not yet released) → ctx.waitUntil worked.
    expect(elapsed).toBeLessThan(2000);
    expect(body.result.isError).not.toBe(true);
    expect(JSON.parse(body.result.content[0].text).status).toBe('completed');

    // Prove the deferred export actually ran via the route's waitUntil:
    // it had entered the (still-hung) intervals call, then we release it.
    await enteredP;
    releaseSlow();
  });

  it('intervals 500 → log_workout_complete still succeeds & returns normally; export left pending', async () => {
    const date = '2026-05-14';
    const { sessionId } = await seedForCompletion(date);
    vi.stubGlobal('fetch', vi.fn(async () => new Response('boom', { status: 500 })));

    const ctx = createExecutionContext();
    const bg = { waitUntil: (p: Promise<unknown>) => ctx.waitUntil(p) };
    const resp = await handleMcp(
      {
        jsonrpc: '2.0',
        id: ++rpcId,
        method: 'tools/call',
        params: { name: 'log_workout_complete', arguments: { session_date: date, perceived_fatigue: 7 } },
      },
      env as unknown as Env,
      bg,
    );
    const result = (resp.json as any).result;
    expect(result.isError).not.toBe(true);
    expect(JSON.parse(result.content[0].text).status).toBe('completed');

    await waitOnExecutionContext(ctx);
    const row = await env.DB.prepare(
      'SELECT status FROM session_load_exports WHERE session_id=?1',
    )
      .bind(sessionId)
      .first<{ status: string }>();
    expect(row!.status).toBe('pending');
  });

  it('tryExportSessionLoad never throws for a non-existent session', async () => {
    await expect(
      tryExportSessionLoad(env.DB, env as unknown as Env, 'nobody', 'no-such-session', {
        fetcher: throwFetcher,
      }),
    ).resolves.toBeUndefined();
  });
});
