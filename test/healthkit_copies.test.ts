import { applyD1Migrations, env } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { dedupeHealthKitAgainstIntervals, getRecentActivities, getState,
  upsertHealthKitActivity, type HealthKitActivityInput } from '../src/db';
import type { ExternalActivityRow } from '../src/types';

// Apple Health can hold one workout several times, each copy with its own
// workout id (Garmin Connect wrote one run into Health over and over; Strava
// adds its own copy of a run Garmin recorded). Only one copy is shown.

beforeAll(async () => { await applyD1Migrations(env.DB, env.TEST_MIGRATIONS); });

const start = Date.parse('2020-12-27T18:09:31Z');
const minute = 60_000;

async function user() {
  const id = crypto.randomUUID();
  await env.DB.prepare('INSERT INTO users (id,apple_sub,created_at) VALUES (?1,?1,1)').bind(id).run();
  return id;
}

/** A legacy push: no source instant, like the rows Garmin Connect left. */
function copy(overrides: Partial<HealthKitActivityInput> = {}): HealthKitActivityInput {
  return { id: crypto.randomUUID().toUpperCase(), date: '2020-12-27', kind: 'run', name: 'Run',
    start_date_local_ms: start, moving_time_sec: 1124, elapsed_time_sec: 1124, distance_m: 4990,
    average_watts: null, average_hr: null, max_hr: null, calories: 340, elevation_gain_m: null,
    raw: '{"hk_activity_type":37,"source":"Connect"}', ...overrides };
}

async function rows(userId: string) {
  return (await env.DB.prepare(
    "SELECT * FROM external_activities WHERE user_id=?1 AND source='healthkit' ORDER BY id",
  ).bind(userId).all<ExternalActivityRow>()).results;
}

const shown = (all: ExternalActivityRow[]) => all.filter(r => r.deleted_at === null);

describe('Apple Health copies of one workout', () => {
  it('shows one of many identical copies and hides the rest reversibly', async () => {
    const userId = await user();
    const pushed = Array.from({ length: 6 }, () => copy());
    for (const w of pushed) await upsertHealthKitActivity(env.DB, userId, w);

    const all = await rows(userId);
    expect(all).toHaveLength(6);
    const live = shown(all);
    expect(live).toHaveLength(1);
    const winner = live[0]!;
    // Equal data, so the lowest id is shown, whatever the push order.
    expect(winner.id).toBe(all[0]!.id);
    expect(winner.canonical).toBe(1);
    for (const hidden of all.filter(r => r.id !== winner.id)) {
      expect(hidden.deleted_at).not.toBeNull();
      expect(hidden.canonical).toBe(0);
      expect(hidden.duplicate_of).toBe(winner.id);
    }

    const recent = await getRecentActivities(env.DB, userId, { to: '2020-12-31', range: 30 });
    expect(recent.map(a => a.id)).toEqual([winner.id]);
    expect((await getState(env.DB, userId, 0, 0, 0, 0)).external_activities.map(a => a.id))
      .toEqual([winner.id]);
    // A phone that already has the copies receives them as tombstones.
    const delta = (await getState(env.DB, userId, 0, 0, 0, 1)).external_activities;
    expect(delta.filter(a => a.deleted_at === null).map(a => a.id)).toEqual([winner.id]);
    expect(delta.filter(a => a.deleted_at !== null)).toHaveLength(5);
  });

  it('keeps the copy carrying more data when two apps saved one run', async () => {
    const userId = await user();
    const strava = copy({ moving_time_sec: 1322, elapsed_time_sec: 1322, distance_m: 4653, calories: 462,
      raw: '{"hk_activity_type":37,"source":"Strava"}', id: '00000000-0000-4000-8000-000000000001' });
    const garmin = copy({ average_hr: 158, max_hr: 175, id: 'FFFFFFFF-0000-4000-8000-000000000001' });
    await upsertHealthKitActivity(env.DB, userId, strava);
    await upsertHealthKitActivity(env.DB, userId, garmin);

    const live = shown(await rows(userId));
    expect(live.map(r => r.external_id)).toEqual([garmin.id]);
  });

  it('leaves separate workouts alone: a later start, another kind, another member', async () => {
    const userId = await user();
    const other = await user();
    const first = copy();
    await upsertHealthKitActivity(env.DB, userId, first);
    await upsertHealthKitActivity(env.DB, userId, copy({ start_date_local_ms: start + 3 * minute }));
    await upsertHealthKitActivity(env.DB, userId, copy({ kind: 'walk', name: 'Walk' }));
    await upsertHealthKitActivity(env.DB, other, copy({ id: first.id }));

    expect(shown(await rows(userId))).toHaveLength(3);
    expect(shown(await rows(other))).toHaveLength(1);
  });

  it('matches on source instants, and on wall time for a copy without one', async () => {
    const userId = await user();
    const utc = Date.parse('2026-06-18T17:00:00Z');
    const local = Date.parse('2026-06-18T10:00:00Z');
    const at = (offset: number) => ({ date: '2026-06-18', start_date_local_ms: local + offset,
      start_date_utc_ms: utc + offset, source_timezone: 'America/Los_Angeles' });
    await upsertHealthKitActivity(env.DB, userId, copy(at(0)));
    await upsertHealthKitActivity(env.DB, userId, copy(at(minute)));
    // A legacy copy of the same run, known only by its wall clock.
    await upsertHealthKitActivity(env.DB, userId, copy({ date: '2026-06-18', start_date_local_ms: local }));
    // Ten minutes later: another run.
    await upsertHealthKitActivity(env.DB, userId, copy(at(10 * minute)));

    const live = shown(await rows(userId));
    expect(live).toHaveLength(2);
    // A copy with a known instant carries more, so it is the one shown.
    expect(live.every(r => r.start_date_utc_ms !== null)).toBe(true);
  });

  it('shows a hidden copy again when the shown one goes, and settles without churn', async () => {
    const userId = await user();
    for (let i = 0; i < 3; i += 1) await upsertHealthKitActivity(env.DB, userId, copy());
    const [winner] = shown(await rows(userId));
    // The member deleted the shown copy (a tombstone with no duplicate_of).
    await env.DB.prepare(
      'UPDATE external_activities SET deleted_at = 5, duplicate_of = NULL, canonical = 1 WHERE id = ?1',
    ).bind(winner!.id).run();
    await dedupeHealthKitAgainstIntervals(env.DB, userId);

    const all = await rows(userId);
    const live = shown(all);
    expect(live).toHaveLength(1);
    expect(live[0]!.id).not.toBe(winner!.id);
    const hidden = all.filter(r => r.id !== winner!.id && r.id !== live[0]!.id);
    expect(hidden).toHaveLength(1);
    expect(hidden[0]!.duplicate_of).toBe(live[0]!.id);

    const before = all.map(r => [r.id, r.synced_at, r.deleted_at, r.duplicate_of]);
    expect(await dedupeHealthKitAgainstIntervals(env.DB, userId)).toBe(0);
    expect((await rows(userId)).map(r => [r.id, r.synced_at, r.deleted_at, r.duplicate_of])).toEqual(before);
  });

  it('hides every copy behind an intervals.icu activity, and none comes back on its own', async () => {
    const userId = await user();
    for (let i = 0; i < 3; i += 1) await upsertHealthKitActivity(env.DB, userId, copy());
    expect(shown(await rows(userId))).toHaveLength(1);

    const intervalsId = `intervals:activity:${userId}:i1`;
    await env.DB.prepare(`INSERT INTO external_activities
      (id,user_id,source,external_id,date,kind,start_date_local_ms,synced_at)
      VALUES (?1,?2,'intervals','i1','2020-12-27','run',?3,1)`).bind(intervalsId, userId, start).run();
    await dedupeHealthKitAgainstIntervals(env.DB, userId);
    let all = await rows(userId);
    expect(shown(all)).toHaveLength(0);
    expect(all.every(r => r.duplicate_of === intervalsId)).toBe(true);

    // The intervals.icu activity goes: the Health copies come back as one.
    await env.DB.prepare('UPDATE external_activities SET deleted_at = 9 WHERE id = ?1').bind(intervalsId).run();
    await dedupeHealthKitAgainstIntervals(env.DB, userId);
    all = await rows(userId);
    const live = shown(all);
    expect(live).toHaveLength(1);
    expect(all.filter(r => r.id !== live[0]!.id).every(r => r.duplicate_of === live[0]!.id)).toBe(true);
  });

  it('keeps a member-deleted copy deleted', async () => {
    const userId = await user();
    const deleted = copy({ id: '00000000-0000-4000-8000-0000000000AA' });
    await upsertHealthKitActivity(env.DB, userId, deleted);
    await env.DB.prepare(
      "UPDATE external_activities SET deleted_at = 5 WHERE user_id = ?1 AND source = 'healthkit'",
    ).bind(userId).run();
    await upsertHealthKitActivity(env.DB, userId, copy());

    const all = await rows(userId);
    const tombstone = all.find(r => r.external_id === deleted.id)!;
    expect(tombstone.deleted_at).toBe(5);
    expect(tombstone.duplicate_of).toBeNull();
    expect(shown(all)).toHaveLength(1);
  });

  it('moves an effort rating on an older copy to the copy shown, with its load', async () => {
    const userId = await user();
    const insert = (suffix: string, effort: number | null) => env.DB.prepare(`INSERT INTO external_activities
      (id,user_id,source,external_id,date,kind,name,start_date_local_ms,moving_time_sec,elapsed_time_sec,
       distance_m,calories,synced_at,canonical,effort)
      VALUES (?1,?2,'healthkit',?3,'2020-12-27','run','Run',?4,1124,1124,4990,340,1,1,?5)`)
      .bind(`healthkit:activity:${userId}:${suffix}`, userId, suffix, start, effort).run();
    await insert('A-SHOWN', null);
    await insert('B-RATED', 7);
    // Today's push reconciles the whole history.
    await upsertHealthKitActivity(env.DB, userId, copy({ date: '2026-06-18',
      start_date_local_ms: Date.parse('2026-06-18T10:00:00Z') }));

    const winner = (await rows(userId)).find(r => r.external_id === 'A-SHOWN')!;
    expect(winner.deleted_at).toBeNull();
    expect(winner.effort).toBe(7);
    expect(winner.load_method).toBe('effort');
    expect(winner.effective_load).not.toBeNull();
  });

  it('keeps the copy with stream summaries, which score its load', async () => {
    const userId = await user();
    const power = Array.from({ length: 3600 }, (_, t) => ({ t, v: 200 }));
    const ride = (id: string, withStreams: boolean) => copy({ id, kind: 'ride', name: 'Ride',
      date: '2026-06-18', start_date_local_ms: Date.parse('2026-06-18T10:00:00Z'),
      start_date_utc_ms: Date.parse('2026-06-18T17:00:00Z'), source_timezone: 'America/Los_Angeles',
      moving_time_sec: 3600, elapsed_time_sec: 3600, average_watts: 200,
      ...(withStreams ? { streams: { power } } : {}) });
    // The plain copy has the lower id, so only the summary can win it.
    await upsertHealthKitActivity(env.DB, userId, ride('00000000-0000-4000-8000-0000000000B1', false));
    await upsertHealthKitActivity(env.DB, userId, ride('FFFFFFFF-0000-4000-8000-0000000000B2', true));

    const live = shown(await rows(userId));
    expect(live).toHaveLength(1);
    expect(live[0]!.external_id).toBe('FFFFFFFF-0000-4000-8000-0000000000B2');
    expect(live[0]!.stream_np_w).not.toBeNull();
  });
});
