/**
 * #7 — duplicate set_index inside one session must be impossible.
 *
 * iOS sends its own set_index; MCP computes one independently. Two writers
 * picking the same index for the same (session, exercise, is_warmup) used to
 * produce colliding rows (two set_index=3 squats). logSet now renumbers on
 * collision (bump to max+1), backed by the partial unique index ux_set_slot
 * (migration 0013). Warmups share the index space with working sets only via
 * the is_warmup discriminator; soft-deleted rows free their slot.
 */
import { env, applyD1Migrations, SELF } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';

const BASE = 'https://tres-fort.test';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

async function devJwt(): Promise<string> {
  const r = await SELF.fetch(`${BASE}/auth/dev`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ secret: 'test-dev' }),
  });
  return (await r.json<{ jwt: string }>()).jwt;
}
const auth = (jwt: string) => ({
  'content-type': 'application/json',
  Authorization: `Bearer ${jwt}`,
});

async function newSession(H: Record<string, string>, date: string): Promise<string> {
  await SELF.fetch(`${BASE}/api/plan`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify({ name: 'Idx ' + date }),
  });
  const s = await (
    await SELF.fetch(`${BASE}/api/sessions`, { method: 'POST', headers: H, body: JSON.stringify({ date }) })
  ).json<{ id: string }>();
  return s.id;
}

function setBody(over: Record<string, unknown> = {}) {
  return {
    id: crypto.randomUUID(),
    exercise_id: 'ex_back_squat',
    set_index: 1,
    weight: 225,
    reps: 5,
    ...over,
  };
}

async function logSet(H: Record<string, string>, sid: string, body: Record<string, unknown>) {
  const r = await SELF.fetch(`${BASE}/api/sessions/${sid}/sets`, {
    method: 'POST',
    headers: H,
    body: JSON.stringify(body),
  });
  return { status: r.status, json: await r.json<any>() };
}

describe('#7 set_index collision safety', () => {
  it('renumbers a colliding set_index instead of duplicating the slot', async () => {
    const H = auth(await devJwt());
    const sid = await newSession(H, '2026-06-01');

    const a = await logSet(H, sid, setBody({ weight: 225, reps: 5 }));
    expect(a.json.set.set_index).toBe(1);

    // Same exercise, same explicit set_index=1 → must be bumped, not collide.
    const b = await logSet(H, sid, setBody({ weight: 185, reps: 5 }));
    expect(b.json.set.set_index).toBe(2);

    // Both rows live, distinct indices.
    const rows = await env.DB
      .prepare(
        "SELECT set_index FROM set_logs WHERE session_id=?1 AND exercise_id='ex_back_squat' AND deleted_at IS NULL ORDER BY set_index",
      )
      .bind(sid)
      .all<{ set_index: number }>();
    expect(rows.results.map((r) => r.set_index)).toEqual([1, 2]);
  });

  it('a warmup and a working set can share set_index 1 (is_warmup discriminates)', async () => {
    const H = auth(await devJwt());
    const sid = await newSession(H, '2026-06-02');

    const work = await logSet(H, sid, setBody({ set_index: 1, is_warmup: false }));
    expect(work.json.set.set_index).toBe(1);
    const warm = await logSet(H, sid, setBody({ set_index: 1, is_warmup: true, weight: 95 }));
    // Not bumped — different is_warmup is a different slot.
    expect(warm.json.set.set_index).toBe(1);
    expect(warm.json.set.is_warmup).toBe(1);
  });

  it('a soft-deleted set frees its slot for reuse at the same index', async () => {
    const H = auth(await devJwt());
    const sid = await newSession(H, '2026-06-03');

    const first = await logSet(H, sid, setBody({ set_index: 1, weight: 225 }));
    expect(first.json.set.set_index).toBe(1);
    // Soft-delete it.
    const del = await SELF.fetch(`${BASE}/api/sets/${first.json.set.id}`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ deleted: true }),
    });
    expect(del.status).toBe(200);
    // Re-log at index 1 — the freed slot means no bump.
    const second = await logSet(H, sid, setBody({ set_index: 1, weight: 235 }));
    expect(second.json.set.set_index).toBe(1);

    // Tombstones are one-way. Reanimating the original could attach an
    // old-attempt set after a discard/restart, so the public API rejects it.
    const undel = await SELF.fetch(`${BASE}/api/sets/${first.json.set.id}`, {
      method: 'PATCH',
      headers: H,
      body: JSON.stringify({ deleted: false }),
    });
    expect(undel.status).toBe(400);
    const undelBody = await undel.json<any>();
    expect(undelBody).toEqual({ error: 'invalid_fields', fields: ['deleted'] });
    // Only the replacement remains live.
    const live = await env.DB
      .prepare(
        "SELECT set_index FROM set_logs WHERE session_id=?1 AND exercise_id='ex_back_squat' AND deleted_at IS NULL ORDER BY set_index",
      )
      .bind(sid)
      .all<{ set_index: number }>();
    expect(live.results.map((r) => r.set_index)).toEqual([1]);
  });

  it('idempotent retry by id still dedupes (no bump, no second row)', async () => {
    const H = auth(await devJwt());
    const sid = await newSession(H, '2026-06-04');
    const body = setBody({ set_index: 1 });
    const a = await logSet(H, sid, body);
    expect(a.json.deduped).toBe(false);
    const b = await logSet(H, sid, body); // same id
    expect(b.json.deduped).toBe(true);
    expect(b.json.set.set_index).toBe(1);
    const count = await env.DB
      .prepare('SELECT COUNT(*) AS c FROM set_logs WHERE id = ?1')
      .bind(body.id)
      .first<{ c: number }>();
    expect(count!.c).toBe(1);
  });
});
