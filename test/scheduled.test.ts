import {
  env,
  applyD1Migrations,
  createScheduledController,
  createExecutionContext,
  waitOnExecutionContext,
} from 'cloudflare:test';
import { afterEach, beforeAll, describe, expect, it, vi } from 'vitest';
import worker from '../src/index';
import { ensureOwnerUser, getUpcomingRides } from '../src/db';

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

const intervalsRow = {
  id: 'sched-1',
  category: 'WORKOUT',
  type: 'Ride',
  start_date_local: '2026-05-21T06:00:00',
  name: 'Cron-synced ride',
  moving_time: 5400,
  icu_training_load: 80,
};

describe('scheduled() cron entrypoint', () => {
  it('invokes syncExternalEvents and reconciles the cache (offline stub)', async () => {
    // Stub global fetch so the scheduled handler's default fetcher never
    // touches the network — the suite stays fully offline.
    const stub = vi.fn((..._args: unknown[]) =>
      Promise.resolve(
        new Response(JSON.stringify([intervalsRow]), {
          status: 200,
          headers: { 'content-type': 'application/json' },
        }),
      ),
    );
    vi.stubGlobal('fetch', stub);

    const owner = (await ensureOwnerUser(env.DB, undefined))!;
    const ctrl = createScheduledController({ scheduledTime: new Date(), cron: '0 */6 * * *' });
    const ctx = createExecutionContext();
    await worker.scheduled!(ctrl, env, ctx);
    await waitOnExecutionContext(ctx);

    // Two intervals.icu fetches fire: the planned /events sync AND the
    // completed /activities sync. Both URLs hit the athlete API.
    expect(stub).toHaveBeenCalledTimes(2);
    expect(String(stub.mock.calls[0]![0])).toContain('intervals.icu/api/v1/athlete/');
    const urls = stub.mock.calls.map((c) => String(c[0]));
    expect(urls.some((u) => u.includes('/events?'))).toBe(true);
    expect(urls.some((u) => u.includes('/activities?'))).toBe(true);
    const rows = await getUpcomingRides(env.DB, owner.id, { from: '2026-05-18' });
    expect(rows.some((r) => r.id === `intervals:${owner.id}:sched-1`)).toBe(true);
  });

  it('a failing fetch does not throw and leaves the cache untouched', async () => {
    // Seed via a good run first.
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => new Response(JSON.stringify([intervalsRow]), { status: 200 })),
    );
    const owner = (await ensureOwnerUser(env.DB, undefined))!;
    let ctx = createExecutionContext();
    await worker.scheduled!(
      createScheduledController({ scheduledTime: new Date(), cron: '0 */6 * * *' }),
      env,
      ctx,
    );
    await waitOnExecutionContext(ctx);
    const before = await getUpcomingRides(env.DB, owner.id, { from: '2026-05-18' });
    expect(before.length).toBeGreaterThan(0);

    // Now the cron fires while intervals.icu 500s — must not throw, cache kept.
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => new Response('boom', { status: 500 })),
    );
    ctx = createExecutionContext();
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
    const after = await getUpcomingRides(env.DB, owner.id, { from: '2026-05-18' });
    expect(after.map((r) => r.id).sort()).toEqual(before.map((r) => r.id).sort());
  });
});
