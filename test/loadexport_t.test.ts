import {
  env,
  applyD1Migrations,
  SELF,
  createExecutionContext,
  waitOnExecutionContext,
} from 'cloudflare:test';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  ensureOwnerUser,
  exportSessionLoad,
  tryExportSessionLoad,
  getActivePlan,
  getRideConflicts,
  getUpcomingRides,
  logSet,
  syncExternalEvents,
} from '../src/db';
import { handleMcp } from '../src/mcp/server';
import type { Env } from '../src/types';
import type { Fetcher } from '../src/intervals';

const BASE = 'https://tres-fort.test';
const TOKEN = 'test-mcp-token';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

// HERMETICITY (root-cause fix): the vitest pool runs every suite in ONE
// shared singleWorker D1, and the single-user invariant means
// ensureOwnerUser + getOrCreateSession(owner,date) reuse the SAME session
// id across tests/suites that share a hardcoded date. session_load_exports
// is keyed by session_id and is NEVER truncated by applyD1Migrations, so a
// row left by an earlier suite (catalog.test.ts presence shifts file
// order) makes the single-flight claim correctly REFUSE → the export
// defers and never reaches `ok`. Purging Option-C-owned ledger rows before
// AND after every test makes the suite order-independent without weakening
// the single-flight guard or any assertion. (The export feature is
// behaving correctly — this is test isolation only.)
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

/**
 * Per-test DB fault injector that NEVER mutates the shared singleton
 * `env.DB`. The previous approach reassigned `env.DB.prepare = spy` and
 * captured `realPrepare = env.DB.prepare.bind(env.DB)`; with the catalog
 * suite shifting file order/timing and waitUntil-deferred exports running
 * AFTER the test that "restored" the spy, one test's realPrepare could
 * capture another test's still-installed spy and then reinstall it
 * permanently — leaking a saboteur across the shared D1 so later exports
 * ended pending/in_flight with attempts=0 and no audit (the integrated-
 * tree flake). This wrapper is a local object passed explicitly as the
 * `db` arg; it delegates to env.DB and throws only for `shouldThrow(sql)`.
 * Nothing global is touched, so there is nothing to leak or restore.
 */
function faultingDb(shouldThrow: (sql: string) => boolean): D1Database {
  return new Proxy(env.DB, {
    get(target, prop, receiver) {
      if (prop === 'prepare') {
        return (sql: string) => {
          const stmt = target.prepare(sql);
          if (!shouldThrow(sql)) return stmt;
          return new Proxy(stmt, {
            get(s, p, r) {
              if (p === 'bind') {
                return (...args: unknown[]) => {
                  const bound = (s.bind as (...a: unknown[]) => D1PreparedStatement)(...args);
                  return new Proxy(bound, {
                    get(b, bp, br) {
                      if (bp === 'run') {
                        return async () => {
                          throw new Error(`injected D1 fault: ${sql.slice(0, 40)}`);
                        };
                      }
                      return Reflect.get(b, bp, br);
                    },
                  });
                };
              }
              if (p === 'run') {
                return async () => {
                  throw new Error(`injected D1 fault: ${sql.slice(0, 40)}`);
                };
              }
              return Reflect.get(s, p, r);
            },
          });
        };
      }
      return Reflect.get(target, prop, receiver);
    },
  }) as unknown as D1Database;
}

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

/**
 * Create a session with a GLOBALLY-UNIQUE id (root-cause fix). The single-
 * user invariant forces one owner and getOrCreateSession keys by
 * (owner,date), so any two tests sharing a hardcoded date reused the SAME
 * session id → the SAME session_load_exports PK row in the shared
 * singleWorker D1 (never truncated by applyD1Migrations). With
 * catalog.test.ts present the file order shifts and a prior suite's
 * terminal/in_flight ledger row made the single-flight claim correctly
 * refuse → the export deferred and never reached `ok`. Inserting the
 * session row directly with a fresh UUID removes ALL cross-test session
 * (hence ledger) sharing regardless of date/owner/suite-order/interleave,
 * without weakening the single-flight guard or any assertion. `date` is
 * preserved verbatim for tests that assert on it.
 */
async function freshSession(
  db: typeof env.DB,
  ownerId: string,
  planId: string,
  date: string,
): Promise<{ id: string }> {
  const id = crypto.randomUUID();
  const ts = Date.now();
  await db
    .prepare(
      'INSERT INTO sessions (id,user_id,plan_id,day_template_id,date,status,started_at,completed_at,perceived_fatigue,notes,created_at,updated_at) VALUES (?1,?2,?3,NULL,?4,?5,NULL,NULL,NULL,NULL,?6,?6)',
    )
    .bind(id, ownerId, planId, date, 'planned', ts)
    .run();
  return { id };
}

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
  const session = await freshSession(env.DB, owner.id, plan!.id, date);
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

    // Sabotage ONLY the ok-branch terminal UPSERT (its VALUES tuple), not
    // the recovery query (which also contains the substring status='ok'
    // since the P2 CASE guard). faultingDb is a LOCAL wrapper — env.DB is
    // never mutated, so no saboteur can leak across the shared D1.
    const sabotagedDb = faultingDb(
      (sql) =>
        sql.includes('INSERT INTO session_load_exports') &&
        sql.includes("VALUES (?1,?2,?3,'ok'"),
    );

    // Tautology fix (#2): assert exportSessionLoad GENUINELY propagates the
    // D1 ok-branch throw — it has no internal catch; the sacred wrapper
    // depends on this. A real rejection, not a constant.
    let firstThrew = false;
    try {
      await exportSessionLoad(sabotagedDb, env as unknown as Env, ownerId, sessionId, { fetcher: api.fetcher });
    } catch {
      firstThrew = true;
    }
    expect(firstThrew).toBe(true);

    // The bare throw above left an orphaned in_flight row (a hard-crash
    // sim). Backdate its updated_at well into the past so it is GENUINELY
    // stale by the real production window (avoids a same-millisecond
    // boundary flake: the reclaim predicate is strict `updated_at <
    // now-staleMs`, correct for prod's 15min but racy if the orphan's
    // timestamp equals `now` in sub-ms test execution).
    await env.DB.prepare(
      'UPDATE session_load_exports SET updated_at = ?2 WHERE session_id = ?1',
    )
      .bind(sessionId, Date.now() - 60 * 60_000)
      .run();

    // In production the export ALWAYS runs under the sacred wrapper, whose
    // recovery (default 15min stale window) must reclaim+demote that stuck
    // in_flight to a retryable state.
    await tryExportSessionLoad(sabotagedDb, env as unknown as Env, ownerId, sessionId, {
      fetcher: api.fetcher,
    });
    const afterRecovery = await env.DB.prepare(
      'SELECT status FROM session_load_exports WHERE session_id=?1',
    )
      .bind(sessionId)
      .first<{ status: string }>();
    // Reclaim+sabotaged-retry left it retryable — a genuinely wedged
    // in_flight row must fail this (no in_flight in the allowed set).
    expect(['pending', 'ok']).toContain(afterRecovery!.status);

    // A remote event WAS created by the POST above. Re-backdate (the
    // sabotaged retry refreshed updated_at) then run the real retry
    // through env.DB: it must FIND its own event by the deterministic
    // marker and UPDATE it (PUT) — NEVER a second POST.
    await env.DB.prepare(
      'UPDATE session_load_exports SET updated_at = ?2 WHERE session_id = ?1',
    )
      .bind(sessionId, Date.now() - 60 * 60_000)
      .run();
    const eventsAfterFailures = api.events.length;
    const retry = await exportSessionLoad(env.DB, env as unknown as Env, ownerId, sessionId, {
      fetcher: api.fetcher,
    });

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

    // Deterministic: select the SPECIFIC pending audit row by its result
    // prefix, not "latest by created_at" — two audit rows for one session
    // can share a Date.now() ms, making a bare created_at order pick the
    // wrong row (~flake). created_at DESC, rowid DESC is a stable
    // tie-breaker (rowid is monotonic on insert; id is a TEXT PK so an
    // implicit rowid exists).
    const audit = await env.DB.prepare(
      "SELECT * FROM audit_log WHERE tool='export_session_load' AND args LIKE ?1 AND result LIKE 'pending%' ORDER BY created_at DESC, rowid DESC LIMIT 1",
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

    // Local fault wrapper (no env.DB mutation): only the ok-branch UPSERT
    // rejects; push SUCCEEDS, then the ledger write rejects.
    const sabotagedDb = faultingDb(
      (sql) =>
        sql.includes('INSERT INTO session_load_exports') &&
        sql.includes("VALUES (?1,?2,?3,'ok'"),
    );

    // The actual P1 failure path: tryExportSessionLoad must NOT throw and
    // must leave the row pending.
    await expect(
      tryExportSessionLoad(sabotagedDb, env as unknown as Env, ownerId, sessionId, { fetcher: api.fetcher }),
    ).resolves.toBeUndefined();

    const row = await env.DB.prepare(
      'SELECT status FROM session_load_exports WHERE session_id=?1',
    )
      .bind(sessionId)
      .first<{ status: string }>();
    expect(row!.status).toBe('pending');
  });

  it('P2: ok UPSERT commits then writeAudit THROWS → recovery must NOT downgrade ok→pending', async () => {
    const { ownerId, sessionId } = await seedCompletedSession({ fatigue: 8, date: '2026-05-15' });
    const api = fakeIntervals();

    // Let the ok UPSERT commit (real env.DB through the wrapper), but make
    // the AUDIT insert that immediately follows it throw — the exact
    // "threw AFTER the ok UPSERT" interleave the P2 status guard protects.
    // Local wrapper only; env.DB is never mutated.
    const sabotagedDb = faultingDb((sql) => sql.includes('INSERT INTO audit_log'));

    // Sacred wrapper absorbs the post-ok throw; its recovery runs.
    await expect(
      tryExportSessionLoad(sabotagedDb, env as unknown as Env, ownerId, sessionId, { fetcher: api.fetcher }),
    ).resolves.toBeUndefined();

    const row = await env.DB.prepare(
      'SELECT status, intervals_ref FROM session_load_exports WHERE session_id=?1',
    )
      .bind(sessionId)
      .first<{ status: string; intervals_ref: string | null }>();
    // CRUX: the row stays terminal ok with its ref intact — NOT downgraded
    // to pending (which would trigger a needless ok→pending→ok cron loop).
    // This FAILS if the CASE WHEN status='ok' guard is removed.
    expect(row!.status).toBe('ok');
    expect(row!.intervals_ref).toBe(String(api.events[0]!.id));
    expect(api.events).toHaveLength(1); // no duplicate remote event
  });

  it('zero non-warmup sets → skipped (no export row)', async () => {
    await mcp('update_plan', {
      name: 'Skip-Plan',
      days: [{ day_label: 'A', name: 'Day A', exercises: [{ exercise: 'bench', target_sets: 3, target_reps: 5 }] }],
    });
    const owner = await ensureOwnerUser(env.DB, undefined);
    const plan = await getActivePlan(env.DB, owner.id);
    const session = await freshSession(env.DB, owner.id, plan!.id, '2026-05-17');
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
    const session = await freshSession(env.DB, owner.id, plan!.id, date);
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

    // Full chain end-to-end through the REAL HTTP route: the response
    // already returned (above); now the route's ctx.waitUntil-scheduled
    // export must finish and drive the ledger row to terminal `ok`. Poll
    // (bounded) since waitUntil completes asynchronously after the
    // response — no fixed sleep.
    let status: string | undefined;
    for (let i = 0; i < 50; i++) {
      const row = await env.DB.prepare(
        'SELECT status FROM session_load_exports WHERE session_id=?1',
      )
        .bind(sessionId)
        .first<{ status: string }>();
      status = row?.status;
      if (status === 'ok') break;
      await new Promise((res) => setTimeout(res, 10));
    }
    expect(status).toBe('ok');
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

// ---------------------------------------------------------------------------
// P2 (Codex bot, merged PR #5): once a row is terminal `ok`, the single-
// flight claim never matches it, so a later exportSessionLoad fell into an
// UNCONDITIONAL early-return that recomputed sRPE load locally but NEVER
// propagated it to intervals.icu. Post-completion corrections (re-running
// log_workout_complete after editing perceived_fatigue / sets / RPE) kept
// the stale remote load. The fix recomputes-and-compares in the
// prior?.status==='ok' branch: unchanged → no-op (no network); changed →
// idempotent PUT to the known ref (no GET/POST ⇒ duplicate-free under
// concurrency); PUT failure → row NOT downgraded from ok.
//
// Revert-detection (honest accounting): FOUR of the five tests genuinely
// FAIL if the recompute-and-compare is reverted to the unconditional
// `return { status:'ok', load: prior.load ?? computed.load }` early-return:
//   1. 'UNCHANGED inputs re-export' — its paired SUBSEQUENT changed-input
//      re-export asserts row.load updates (the no-op assertions alone do
//      NOT distinguish; the paired tail does).
//   2. 'CHANGED inputs re-export' — asserts the PUT + new row.load.
//   3. 'two CONCURRENT changed-load re-exports' — asserts convergence.
//   4. 'PUT FAILURE on a changed-load re-export' — asserts ok-not-
//      downgraded with the new-vs-prior load distinction.
// The fifth ('changed-load re-export under tryExportSessionLoad never
// throws') is a sacred-path guard, NOT a revert-detector: it passes under
// the old code too (the early-return also never throws). It is kept for
// the decoupling/no-throw invariant, not claimed as load-bearing here.
// ---------------------------------------------------------------------------
describe('P2: post-completion load corrections propagate to intervals.icu', () => {
  /** Change perceived_fatigue (scales sRPE load ⇒ computed.load changes). */
  async function setFatigue(sessionId: string, fatigue: number) {
    await env.DB.prepare(
      'UPDATE sessions SET perceived_fatigue=?2, updated_at=?3 WHERE id=?1',
    )
      .bind(sessionId, fatigue, Date.now())
      .run();
  }

  it('UNCHANGED inputs re-export: true no-op — no PUT/POST, row stays ok at the same load', async () => {
    const { ownerId, sessionId } = await seedCompletedSession({ fatigue: 8, date: '2026-05-21' });
    const api = fakeIntervals();

    const r1 = await exportSessionLoad(env.DB, env as unknown as Env, ownerId, sessionId, { fetcher: api.fetcher });
    expect(r1.status).toBe('ok');
    const loadX = r1.load!;
    expect(loadX).toBeGreaterThan(0);
    const postsAfterFirst = api.calls.filter((c) => c.method === 'POST').length;
    expect(postsAfterFirst).toBe(1);

    // Re-export with NOTHING changed.
    const r2 = await exportSessionLoad(env.DB, env as unknown as Env, ownerId, sessionId, { fetcher: api.fetcher });
    expect(r2.status).toBe('ok');
    expect(r2.load).toBe(loadX);

    // Crux: zero further network — no PUT, no extra POST, one remote event.
    expect(api.calls.filter((c) => c.method === 'POST')).toHaveLength(1);
    expect(api.calls.filter((c) => c.method === 'PUT')).toHaveLength(0);
    expect(api.events).toHaveLength(1);

    const row = await env.DB.prepare('SELECT * FROM session_load_exports WHERE session_id=?1')
      .bind(sessionId)
      .first<any>();
    expect(row.status).toBe('ok');
    expect(row.load).toBe(loadX);
    expect(row.attempts).toBe(1); // only the first export pushed

    // Paired revert-detector: a SUBSEQUENT changed-input re-export on the
    // same now-ok row MUST update row.load. Under the pre-fix unconditional
    // early-return this would NOT happen (row.load would stay loadX), so
    // this test as a UNIT genuinely fails if the recompute-and-compare is
    // reverted — the no-op assertions above alone do not distinguish.
    await setFatigue(sessionId, 4);
    const r3 = await exportSessionLoad(env.DB, env as unknown as Env, ownerId, sessionId, { fetcher: api.fetcher });
    expect(r3.status).toBe('ok');
    expect(r3.load).not.toBe(loadX);
    const rowAfter = await env.DB.prepare('SELECT load, status FROM session_load_exports WHERE session_id=?1')
      .bind(sessionId)
      .first<{ load: number; status: string }>();
    expect(rowAfter!.status).toBe('ok');
    expect(rowAfter!.load).toBe(r3.load);
    expect(rowAfter!.load).not.toBe(loadX); // FAILS under the reverted early-return
  });

  it('CHANGED inputs re-export: exactly one PUT to the SAME ref (no GET, no POST), row→new load, audit written', async () => {
    const { ownerId, sessionId } = await seedCompletedSession({ fatigue: 8, date: '2026-05-22' });
    const api = fakeIntervals();

    const r1 = await exportSessionLoad(env.DB, env as unknown as Env, ownerId, sessionId, { fetcher: api.fetcher });
    expect(r1.status).toBe('ok');
    const loadX = r1.load!;
    const ref = String(api.events[0]!.id);

    // User edits perceived_fatigue → recomputed load changes (Y ≠ X).
    await setFatigue(sessionId, 4);

    const callsBefore = api.calls.length;
    const r2 = await exportSessionLoad(env.DB, env as unknown as Env, ownerId, sessionId, { fetcher: api.fetcher });
    expect(r2.status).toBe('ok');
    const loadY = r2.load!;
    expect(loadY).not.toBe(loadX);

    // Crux: the RE-EXPORT itself issued EXACTLY ONE call — a PUT to the
    // same known ref. No GET (known ref ⇒ NO marker lookup) and no POST (no
    // new event) DURING the re-export. (The initial export legitimately did
    // one marker GET + one POST; those predate callsBefore.)
    const reexportCalls = api.calls.slice(callsBefore);
    expect(reexportCalls).toHaveLength(1);
    expect(reexportCalls[0]!.method).toBe('PUT');
    expect(reexportCalls[0]!.url).toContain(`/events/${ref}`);
    expect(reexportCalls.filter((c) => c.method === 'GET')).toHaveLength(0);
    expect(reexportCalls.filter((c) => c.method === 'POST')).toHaveLength(0);
    expect(api.calls.filter((c) => c.method === 'POST')).toHaveLength(1); // only the initial export ever POSTed

    // One remote event, now carrying the NEW load.
    expect(api.events).toHaveLength(1);
    expect(String(api.events[0]!.id)).toBe(ref);
    expect(api.events[0]!.icu_training_load).toBe(loadY);

    const row = await env.DB.prepare('SELECT * FROM session_load_exports WHERE session_id=?1')
      .bind(sessionId)
      .first<any>();
    expect(row.status).toBe('ok');
    expect(row.load).toBe(loadY);
    expect(String(row.intervals_ref)).toBe(ref);

    // Deterministic: target the specific reexport_load_changed row (the
    // initial export also wrote an ok:ref=... row for this session; both
    // can share a Date.now() ms). Filtering by the exact result + a
    // rowid DESC tie-breaker removes the created_at-collision flake. Still
    // revert-detecting: under the reverted early-return this row is never
    // written, so .first() is null and audit!.result throws → test fails.
    const audit = await env.DB.prepare(
      "SELECT result FROM audit_log WHERE tool='export_session_load' AND args LIKE ?1 AND result LIKE 'ok:%:reexport_load_changed' ORDER BY created_at DESC, rowid DESC LIMIT 1",
    )
      .bind(`%${sessionId}%`)
      .first<{ result: string }>();
    expect(audit!.result).toContain('reexport_load_changed');
  });

  it('two CONCURRENT changed-load re-exports of an ok session: at most one remote activity, row converges to new load', async () => {
    const { ownerId, sessionId } = await seedCompletedSession({ fatigue: 8, date: '2026-05-23' });
    const api = fakeIntervals();

    const r1 = await exportSessionLoad(env.DB, env as unknown as Env, ownerId, sessionId, { fetcher: api.fetcher });
    expect(r1.status).toBe('ok');
    const ref = String(api.events[0]!.id);

    await setFatigue(sessionId, 5);

    const callsBefore = api.calls.length;
    // Fire two re-exports concurrently against the now-ok row.
    const [a, b] = await Promise.all([
      exportSessionLoad(env.DB, env as unknown as Env, ownerId, sessionId, { fetcher: api.fetcher }),
      exportSessionLoad(env.DB, env as unknown as Env, ownerId, sessionId, { fetcher: api.fetcher }),
    ]);
    expect(a.status).toBe('ok');
    expect(b.status).toBe('ok');

    // Crux: still exactly ONE remote activity. Both racing re-exports see
    // the terminal `ok` row, recompute the changed load, and issue an
    // idempotent PUT to the SAME known ref — NO marker GET, NO POST during
    // the re-exports, so concurrency cannot create a duplicate.
    const reexportCalls = api.calls.slice(callsBefore);
    expect(reexportCalls.filter((c) => c.method === 'GET')).toHaveLength(0);
    expect(reexportCalls.filter((c) => c.method === 'POST')).toHaveLength(0);
    expect(reexportCalls.every((c) => c.method === 'PUT')).toBe(true);
    expect(api.events).toHaveLength(1);
    expect(String(api.events[0]!.id)).toBe(ref);
    expect(api.calls.filter((c) => c.method === 'POST')).toHaveLength(1); // only the initial export

    const cnt = await env.DB.prepare('SELECT COUNT(*) c FROM session_load_exports WHERE session_id=?1')
      .bind(sessionId)
      .first<{ c: number }>();
    expect(cnt!.c).toBe(1);
    const row = await env.DB.prepare('SELECT status, load FROM session_load_exports WHERE session_id=?1')
      .bind(sessionId)
      .first<{ status: string; load: number }>();
    expect(row!.status).toBe('ok');
    // Both winners recompute the same load; the row converges to it and is
    // no longer the original (pre-correction) value.
    expect(a.load).toBe(b.load);
    expect(row!.load).toBe(a.load);
    expect(row!.load).not.toBe(r1.load);
  });

  it('PUT FAILURE on a changed-load re-export: ok row NOT downgraded, prior load kept, no throw', async () => {
    const { ownerId, sessionId } = await seedCompletedSession({ fatigue: 8, date: '2026-05-24' });

    // First export succeeds via a healthy fake intervals.
    const okApi = fakeIntervals();
    const r1 = await exportSessionLoad(env.DB, env as unknown as Env, ownerId, sessionId, { fetcher: okApi.fetcher });
    expect(r1.status).toBe('ok');
    const loadX = r1.load!;
    const ref = String(okApi.events[0]!.id);

    await setFatigue(sessionId, 3);

    // Re-export with a fetcher whose PUT (the known-ref update) 500s.
    const putFailCalls: { method: string; url: string }[] = [];
    const putFailFetcher: Fetcher = async (url, init) => {
      const method = init?.method ?? 'GET';
      putFailCalls.push({ method, url });
      if (method === 'PUT') return { ok: false, status: 500, json: async () => ({}) };
      // No GET/POST should occur on a known-ref update; be safe if they do.
      return { ok: true, status: 200, json: async () => [] };
    };

    const r2 = await exportSessionLoad(env.DB, env as unknown as Env, ownerId, sessionId, { fetcher: putFailFetcher });

    // Crux: response unaffected — still ok, reporting the LAST GOOD load
    // (the stored remote value), NOT the un-pushed recomputed one.
    expect(r2.status).toBe('ok');
    expect(r2.load).toBe(loadX);
    // Exactly one PUT attempt, no GET/POST.
    expect(putFailCalls.filter((c) => c.method === 'PUT')).toHaveLength(1);
    expect(putFailCalls.filter((c) => c.method === 'GET')).toHaveLength(0);
    expect(putFailCalls.filter((c) => c.method === 'POST')).toHaveLength(0);

    // Row stays terminal ok with the prior load + ref — NOT downgraded to
    // pending (P2 ok-not-downgraded recovery guard preserved).
    const row = await env.DB.prepare('SELECT status, load, intervals_ref FROM session_load_exports WHERE session_id=?1')
      .bind(sessionId)
      .first<{ status: string; load: number; intervals_ref: string }>();
    expect(row!.status).toBe('ok');
    expect(row!.load).toBe(loadX);
    expect(String(row!.intervals_ref)).toBe(ref);

    // Deterministic: target the specific reexport_update_failed row. The
    // session has an earlier ok:ref=... row (initial export) that can
    // collide on Date.now() ms; the exact-result filter + rowid DESC
    // tie-breaker is collision-proof. Still revert-detecting: under the
    // reverted early-return the PUT-failure path never runs, this row is
    // never written, .first() is null and audit!.result throws → fails.
    const audit = await env.DB.prepare(
      "SELECT result FROM audit_log WHERE tool='export_session_load' AND args LIKE ?1 AND result LIKE 'ok:reexport_update_failed:%' ORDER BY created_at DESC, rowid DESC LIMIT 1",
    )
      .bind(`%${sessionId}%`)
      .first<{ result: string }>();
    expect(audit!.result).toContain('reexport_update_failed');
  });

  it('changed-load re-export under tryExportSessionLoad never throws into the sacred path', async () => {
    const { ownerId, sessionId } = await seedCompletedSession({ fatigue: 8, date: '2026-05-25' });
    const api = fakeIntervals();
    await exportSessionLoad(env.DB, env as unknown as Env, ownerId, sessionId, { fetcher: api.fetcher });

    await setFatigue(sessionId, 2);
    await expect(
      tryExportSessionLoad(env.DB, env as unknown as Env, ownerId, sessionId, { fetcher: api.fetcher }),
    ).resolves.toBeUndefined();

    const row = await env.DB.prepare('SELECT status, load FROM session_load_exports WHERE session_id=?1')
      .bind(sessionId)
      .first<{ status: string; load: number }>();
    expect(row!.status).toBe('ok');
    expect(api.events).toHaveLength(1); // still one activity, updated in place
  });
});
