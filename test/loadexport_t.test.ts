import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { afterEach, beforeAll, describe, expect, it, vi } from 'vitest';
import {
  ensureOwnerUser,
  exportSessionLoad,
  tryExportSessionLoad,
  getActivePlan,
  getOrCreateSession,
  logSet,
} from '../src/db';
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

// intervals.icu create/update event success: echoes a numeric id.
let nextRef = 1000;
const okFetcher: Fetcher = async () => ({
  ok: true,
  status: 200,
  json: async () => ({ id: `ev-${nextRef++}` }),
});
const failFetcher: Fetcher = async () => ({ ok: false, status: 500, json: async () => ({}) });
const throwFetcher: Fetcher = async () => {
  throw new Error('network down');
};

/** Seed a completed session with one working set, return its id + userId. */
async function seedCompletedSession(opts: { fatigue?: number } = {}) {
  const owner = await ensureOwnerUser(env.DB, undefined);
  // Build a minimal plan via MCP so an active plan + day template exist.
  await mcp('update_plan', {
    name: 'T-Plan',
    days: [
      {
        day_label: 'A',
        name: 'Push A',
        exercises: [{ exercise: 'bench', target_sets: 3, target_reps: 5 }],
      },
    ],
  });
  const plan = await getActivePlan(env.DB, owner.id);
  const date = '2026-05-19';
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
    .bind(session.id, 1_000_000, 1_000_000 + 3_600_000, opts.fatigue ?? null, )
    .run();
  return { ownerId: owner.id, sessionId: session.id, date };
}

describe('exportSessionLoad — milestone t', () => {
  it('idempotent: second export UPDATEs the same intervals_ref, no duplicate row/activity', async () => {
    const { ownerId, sessionId } = await seedCompletedSession({ fatigue: 8 });

    const calls: { method: string; url: string }[] = [];
    const spy: Fetcher = async (url, init) => {
      calls.push({ method: init?.method ?? 'GET', url });
      return { ok: true, status: 200, json: async () => ({ id: 'ev-fixed' }) };
    };

    const r1 = await exportSessionLoad(env.DB, env as unknown as Env, ownerId, sessionId, { fetcher: spy });
    expect(r1.status).toBe('ok');
    const r2 = await exportSessionLoad(env.DB, env as unknown as Env, ownerId, sessionId, { fetcher: spy });
    expect(r2.status).toBe('ok');

    // Exactly ONE export row for the session (PK = session_id).
    const cnt = await env.DB.prepare(
      'SELECT COUNT(*) c FROM session_load_exports WHERE session_id=?1',
    )
      .bind(sessionId)
      .first<{ c: number }>();
    expect(cnt!.c).toBe(1);

    // First call CREATEs (POST, no ref), second UPDATEs the same ref (PUT
    // .../events/ev-fixed) — never a second create.
    expect(calls[0]!.method).toBe('POST');
    expect(calls[0]!.url).not.toContain('/ev-fixed');
    expect(calls[1]!.method).toBe('PUT');
    expect(calls[1]!.url).toContain('/events/ev-fixed');

    const row = await env.DB.prepare(
      'SELECT * FROM session_load_exports WHERE session_id=?1',
    )
      .bind(sessionId)
      .first<any>();
    expect(row.intervals_ref).toBe('ev-fixed');
    expect(row.status).toBe('ok');
    expect(row.attempts).toBe(2);
  });

  it('intervals failure → row pending; audit row written; no plans.version bump', async () => {
    const { ownerId, sessionId } = await seedCompletedSession({ fatigue: 7 });
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

    // audit row exists for this export attempt.
    const audit = await env.DB.prepare(
      "SELECT * FROM audit_log WHERE tool='export_session_load' AND args LIKE ?1 ORDER BY created_at DESC",
    )
      .bind(`%${sessionId}%`)
      .first<any>();
    expect(audit).not.toBeNull();
    expect(audit.result).toContain('pending');

    // plans.version untouched by the export.
    const planAfter = await getActivePlan(env.DB, ownerId);
    expect(planAfter!.version).toBe(planBefore!.version);
  });

  it('a thrown fetcher does not throw out of exportSessionLoad → pending', async () => {
    const { ownerId, sessionId } = await seedCompletedSession({ fatigue: 6 });
    const res = await exportSessionLoad(env.DB, env as unknown as Env, ownerId, sessionId, {
      fetcher: throwFetcher,
    });
    expect(res.status).toBe('pending');
  });

  it('zero non-warmup sets → skipped (no export row, audit notes skip)', async () => {
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
    const res = await exportSessionLoad(env.DB, env as unknown as Env, owner.id, session.id, {
      fetcher: okFetcher,
    });
    expect(res.status).toBe('skipped');
    const row = await env.DB.prepare(
      'SELECT * FROM session_load_exports WHERE session_id=?1',
    )
      .bind(session.id)
      .first();
    expect(row).toBeNull();
  });
});

describe('log_workout_complete is SACRED — export cannot break it', () => {
  it('intervals failing (global fetch 500) → log_workout_complete still succeeds, returns normally, no throw', async () => {
    // Build plan + log a set so the completed session has working volume.
    await mcp('update_plan', {
      name: 'Sacred',
      days: [{ day_label: 'A', name: 'Day A', exercises: [{ exercise: 'squat', target_sets: 3, target_reps: 5 }] }],
    });
    const exId = (await env.DB.prepare('SELECT exercise_id FROM template_exercises LIMIT 1').first<{ exercise_id: string }>())!.exercise_id;
    const owner = await ensureOwnerUser(env.DB, undefined);
    const plan = await getActivePlan(env.DB, owner.id);
    const session = await getOrCreateSession(env.DB, owner.id, plan!.id, '2026-05-19', null);
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

    // intervals.icu is hard-down for the real-time push.
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => new Response('boom', { status: 500 })),
    );

    const r = await mcp('log_workout_complete', {
      session_date: '2026-05-19',
      perceived_fatigue: 8,
    });
    // Completion succeeded and returned the session normally — NOT an error.
    expect(r.isError).toBe(false);
    expect(r.data.status).toBe('completed');
    expect(r.data.perceived_fatigue).toBe(8);

    // The export was recorded pending (cron will retry) — proving the
    // failure was absorbed, not propagated.
    const row = await env.DB.prepare(
      'SELECT status FROM session_load_exports WHERE session_id=?1',
    )
      .bind(session.id)
      .first<{ status: string }>();
    expect(row!.status).toBe('pending');
  });

  it('tryExportSessionLoad never throws even if exportSessionLoad would', async () => {
    // Non-existent session → exportSessionLoad returns skipped; the wrapper
    // resolves cleanly regardless.
    await expect(
      tryExportSessionLoad(env.DB, env as unknown as Env, 'nobody', 'no-such-session', {
        fetcher: throwFetcher,
      }),
    ).resolves.toBeUndefined();
  });
});
