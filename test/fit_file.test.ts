import { describe, expect, it } from 'vitest';
import { FitParseError, fitKind, parseFit } from '../src/fitFile';
import { activityFit, FitWriter, fitTime } from './fitWriter';

// FIT reader (docs/plans/endurance-training-load P4).

const code = (bytes: Uint8Array) => {
  try {
    parseFit(bytes);
    return 'ok';
  } catch (e) {
    return e instanceof FitParseError ? e.code : String(e);
  }
};

describe('parseFit', () => {
  it('reads a ride summary and its samples', () => {
    const fit = parseFit(activityFit({
      start: '2026-10-25T03:00:00Z', seconds: 3600, hr: 150, power: 200, distanceM: 30000, normalizedPower: 205,
    }));
    expect(fit).toMatchObject({
      kind: 'ride',
      start_utc_ms: Date.parse('2026-10-25T03:00:00Z'),
      local_offset_sec: -7 * 3600,
      elapsed_sec: 3600,
      timer_sec: 3600,
      distance_m: 30000,
      calories: 600,
      avg_hr: 150,
      max_hr: 160,
      avg_power: 200,
      normalized_power: 205,
      ascent_m: 120,
    });
    expect(fit.hr).toHaveLength(3600);
    expect(fit.power[0]).toEqual({ t: 0, v: 200 });
    expect(fit.power[3599]).toEqual({ t: 3599, v: 200 });
  });

  it('leaves invalid values out rather than reading them as numbers', () => {
    const fit = parseFit(activityFit({ start: '2026-10-25T03:00:00Z', seconds: 600, hr: 140, power: null, localOffsetSec: null }));
    expect(fit.power).toEqual([]);
    expect(fit.avg_power).toBeNull();
    expect(fit.normalized_power).toBeNull();
    expect(fit.local_offset_sec).toBeNull();
    expect(fit.hr).toHaveLength(600);
  });

  it('expands compressed timestamps, rolling over every 32 seconds', () => {
    const start = fitTime('2026-10-25T03:00:00Z');
    const w = new FitWriter()
      .define(0, 0, [{ num: 0, type: 'enum' }]).data(0, [4])
      .define(1, 20, [{ num: 253, type: 'uint32' }, { num: 3, type: 'uint8' }])
      .data(1, [start, 120])
      .define(2, 20, [{ num: 3, type: 'uint8' }]);
    for (let t = 1; t < 100; t++) w.compressed(2, (start + t) % 32, [120 + (t % 3)]);
    const fit = parseFit(w.bytes());
    expect(fit.hr.map(s => s.t)).toEqual(Array.from({ length: 100 }, (_, i) => i));
    expect(fit.kind).toBe('other');
    expect(fit.timer_sec).toBe(99);
  });

  it('skips developer fields and reads big-endian definitions', () => {
    const start = fitTime('2026-10-25T03:00:00Z');
    const w = new FitWriter()
      .define(0, 0, [{ num: 0, type: 'enum' }]).data(0, [4])
      .define(1, 20, [{ num: 253, type: 'uint32' }, { num: 7, type: 'uint16' }], { devSizes: [4, 2], bigEndian: true });
    for (let t = 0; t < 60; t++) w.data(1, [start + t, 250 + t]);
    w.define(2, 18, [{ num: 2, type: 'uint32' }, { num: 5, type: 'enum' }, { num: 8, type: 'uint32' }])
      .data(2, [start, 2, 60_000]);
    const fit = parseFit(w.bytes());
    expect(fit.kind).toBe('ride');
    expect(fit.power).toHaveLength(60);
    expect(fit.power[59]).toEqual({ t: 59, v: 309 });
    expect(fit.timer_sec).toBe(60);
  });

  it('reads chained files as one workout', () => {
    const start = fitTime('2026-10-25T03:00:00Z');
    const w = new FitWriter()
      .define(0, 0, [{ num: 0, type: 'enum' }]).data(0, [4])
      .define(1, 20, [{ num: 253, type: 'uint32' }, { num: 3, type: 'uint8' }]);
    for (let t = 0; t < 30; t++) w.data(1, [start + t, 130]);
    w.chain().define(5, 20, [{ num: 253, type: 'uint32' }, { num: 3, type: 'uint8' }]);
    for (let t = 30; t < 60; t++) w.data(5, [start + t, 131]);
    expect(parseFit(w.bytes()).hr).toHaveLength(60);
  });

  it('refuses what it cannot score', () => {
    expect(code(new TextEncoder().encode('<gpx></gpx> not a fit file at all'))).toBe('not_fit');
    const whole = activityFit({ start: '2026-10-25T03:00:00Z', seconds: 60, hr: 140 });
    expect(code(whole.slice(0, 200))).toBe('truncated');
    const course = new FitWriter().define(0, 0, [{ num: 0, type: 'enum' }]).data(0, [6]).bytes();
    expect(code(course)).toBe('not_an_activity');
    const empty = new FitWriter().define(0, 0, [{ num: 0, type: 'enum' }]).data(0, [4]).bytes();
    expect(code(empty)).toBe('no_data');
    const start = fitTime('2026-10-25T03:00:00Z');
    const triathlon = new FitWriter()
      .define(0, 0, [{ num: 0, type: 'enum' }]).data(0, [4])
      .define(1, 18, [{ num: 2, type: 'uint32' }, { num: 5, type: 'enum' }])
      .data(1, [start, 5]).data(1, [start + 1800, 2]).data(1, [start + 5400, 1])
      .bytes();
    expect(code(triathlon)).toBe('multisport');
  });

  it('maps sports to the kinds other sources use', () => {
    expect([fitKind(1, 0), fitKind(2, 58), fitKind(5, 0), fitKind(4, 14), fitKind(4, 6), fitKind(10, 0)])
      .toEqual(['run', 'ride', 'swim', 'row', 'ride', 'other']);
  });
});
