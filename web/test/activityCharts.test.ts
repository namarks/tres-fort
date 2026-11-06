// The web's pace, heart rate and elevation charts (docs/plans/run-detail-charts
// P2): the series in the member's units and the SVG line paths.
import { describe, expect, it } from 'vitest';
import {
  activityCharts, average, chartableActivities, clampToPercentiles, formatPace, linePaths, nearestIndex,
  type ActivityStreams,
} from '../src/activityCharts';
import type { StateResponse } from '../src/api';

const streams: ActivityStreams = {
  v: 1,
  t: [3, 8, 13, 18, 23, 28, 33, 38, 43, 48, 53, 58],
  distance_m: [15, 30, 45, 60, 75, 90, 105, 125, 145, 165, 185, 205],
  speed_mps: [3, 3, 3, 3, 3, 0.2, null, 4, 4, 4, 4, 4],
  heart_rate: [140, 141, 142, 143, null, 150, 151, 152, 153, 154, 155, 156],
  elevation_m: [10, 10, 11, 12, 12, 13, 14, 14, 15, 16, 16, 17],
  moving_s: 60,
  total_distance_m: 205,
  elevation_gain_m: 7,
};

describe('activityCharts', () => {
  it('charts a run over kilometers with pace, heart rate and elevation', () => {
    const c = activityCharts(streams, 'run', false)!;
    expect(c.xUnit).toBe('km');
    expect(c.xs[0]).toBeCloseTo(0.015);
    expect(c.series.map((s) => s.key)).toEqual(['pace', 'heart_rate', 'elevation']);
    const pace = c.series[0]!;
    expect(pace.reversed).toBe(true);
    expect(pace.values[5]).toBeNull();
    expect(pace.format(pace.values[0]!)).toBe('5:33 /km');
    expect(c.series[2]!.title).toBe('Elevation · 7 m climb');
    expect(c.formatX(1.5)).toBe('1.50 km');
  });

  it('averages pace from moving time and distance, not the points', () => {
    // 300 s at 2 m/s then 300 s at 4 m/s: 1,800 m in 600 s is 5:33 a km.
    const t = Array.from({ length: 120 }, (_, i) => i * 5 + 2.5);
    const c = activityCharts({
      v: 1, t, distance_m: t.map((x) => (x < 300 ? 2 * x : 600 + 4 * (x - 300))),
      speed_mps: t.map((x) => (x < 300 ? 2 : 4)), heart_rate: null, elevation_m: null,
      moving_s: 600, total_distance_m: 1800, elevation_gain_m: null,
    }, 'run', false)!;
    const pace = c.series[0]!;
    expect(pace.format(pace.average!)).toBe('5:33 /km');
    const ride = activityCharts({ ...streams }, 'ride', false)!;
    expect(ride.series[0]!.average).toBeCloseTo(0.205 / (60 / 3600));
    expect(ride.series[1]!.average).toBeCloseTo(148.82, 1);
  });

  it('shows speed for a ride and feet with miles', () => {
    const c = activityCharts(streams, 'ride', true)!;
    const speed = c.series[0]!;
    expect(speed.title).toBe('Speed');
    expect(speed.reversed).toBe(false);
    expect(speed.format(18.64)).toBe('18.6 mph');
    expect(c.series[2]!.title).toBe('Elevation · 23 ft climb');
  });

  it('charts heart rate alone over moving time', () => {
    const c = activityCharts({
      v: 1, t: [30, 90, 150], distance_m: null, speed_mps: null, heart_rate: [120, 130, 140],
      elevation_m: null, moving_s: 180, total_distance_m: null, elevation_gain_m: null,
    }, 'soccer', true)!;
    expect(c.xUnit).toBe('min');
    expect(c.xs).toEqual([0.5, 1.5, 2.5]);
    expect(c.series.map((s) => s.key)).toEqual(['heart_rate']);
    expect(c.formatX(2.5)).toBe('2:30');
  });

  it('is null with nothing to draw', () => {
    expect(activityCharts({ ...streams, speed_mps: null, heart_rate: null, elevation_m: null }, 'run', true)).toBeNull();
  });
});

describe('chart helpers', () => {
  it('breaks the line at a missing value and puts faster pace higher', () => {
    const paths = linePaths([0, 1, 2, 3, 4], [300, 240, null, 300, 360], 100, 50, true);
    expect(paths).toEqual(['M0.0,25.0 L25.0,0.0', 'M75.0,25.0 L100.0,50.0']);
  });

  it('holds one outlier to the percentiles', () => {
    const values: (number | null)[] = Array(60).fill(300);
    values[30] = 3000;
    expect(clampToPercentiles(values)[30]).toBe(300);
  });

  it('reads the nearest point and the mean', () => {
    expect(nearestIndex([0, 1, 2, 3], 0.6)).toBe(2);
    expect(average([1, null, 3])).toBe(2);
    expect(formatPace(485)).toBe('8:05');
    expect(formatPace(4000)).toBe('–');
  });

  it('offers charts for intervals.icu activities and runs with a route only', () => {
    const activity = (id: string, source: string, kind: string, deleted_at: number | null = null) =>
      ({ id, source, kind, deleted_at });
    const state = {
      external_activities: [
        activity('a', 'intervals', 'other'),
        activity('b', 'healthkit', 'run'),
        activity('c', 'healthkit', 'ride'),
        activity('d', 'recording', 'run', 1),
        activity('e', 'manual', 'run'),
      ],
    } as unknown as StateResponse;
    expect([...chartableActivities(state)]).toEqual([['a', 'other'], ['b', 'run']]);
  });
});
