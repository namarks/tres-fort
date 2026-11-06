// An activity's pace, heart rate and elevation charts on the web
// (docs/plans/run-detail-charts P2). Pure: the SVG is drawn by
// ActivityChartsView.tsx, from the series GET /api/activities/:id/streams
// serves (src/activityStreams.ts). Mirrors the app's ActivityChartSeries.
import type { ActivityStreams } from '../../src/activityStreams';
import type { StateResponse } from './api';

export type { ActivityStreams };

/** `GET /api/activities/:id/streams`. */
export interface ActivityStreamsResponse {
  activity_id: string;
  source: 'intervals' | 'recording' | 'healthkit' | 'fit';
  streams: ActivityStreams;
}

const METERS_PER_MILE = 1609.344;
const FEET_PER_METER = 3.28084;
/** Slower than this is standing still, not a pace to draw. */
const SLOWEST_MOVING_MPS = 0.8;
const ROUTE_SOURCES = new Set(['recording', 'intervals', 'healthkit']);
/** Sources whose heart-rate readings Tres Fort keeps (P3). */
const HEART_RATE_SOURCES = new Set(['recording', 'healthkit', 'fit']);

/** The activities the server can chart, by id, with their kind: anything
 * from intervals.icu (its streams carry heart rate for any sport), every
 * run with a route, and any workout with heart rate whose readings Tres
 * Fort keeps. */
export function chartableActivities(state: StateResponse): Map<string, string> {
  return new Map(state.external_activities
    .filter((a) => a.deleted_at === null
      && (a.source === 'intervals' || (a.kind === 'run' && ROUTE_SOURCES.has(a.source))
        || (HEART_RATE_SOURCES.has(a.source) && a.average_hr !== null && a.average_hr !== undefined)))
    .map((a) => [a.id, a.kind]));
}

export interface Series {
  key: 'pace' | 'heart_rate' | 'elevation';
  title: string;
  /** One value per point, null where there is none. */
  values: (number | null)[];
  /** Pace: faster (smaller) is drawn higher. */
  reversed: boolean;
  format: (v: number) => string;
  /** Axis label: the value without its unit. */
  tick: (v: number) => string;
  /** The value shown with no point picked: for pace or speed, the whole
   * activity's, from moving time and distance; otherwise the mean. */
  average: number | null;
}

export interface Charts {
  /** Distance in miles or kilometers, else moving minutes. */
  xs: number[];
  xUnit: 'mi' | 'km' | 'min';
  series: Series[];
  formatX: (x: number) => string;
}

/** "8:05" for seconds per unit; slower than an hour reads as a dash. */
export function formatPace(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds <= 0 || seconds >= 3600) return '–';
  const total = Math.round(seconds);
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`;
}

function formatClock(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = String(total % 60).padStart(2, '0');
  return h > 0 ? `${h}:${String(m).padStart(2, '0')}:${s}` : `${m}:${s}`;
}

/** Values held between the 2nd and 98th percentile, so one GPS hiccup
 * doesn't squash the rest of the chart. */
export function clampToPercentiles(values: (number | null)[]): (number | null)[] {
  const known = values.filter((v): v is number => v !== null).sort((a, b) => a - b);
  if (known.length < 10) return values;
  const lo = known[Math.floor((known.length - 1) * 0.02)]!;
  const hi = known[Math.floor((known.length - 1) * 0.98)]!;
  return values.map((v) => (v === null ? null : Math.min(Math.max(v, lo), hi)));
}

const at = (a: (number | null)[] | null, i: number) => a?.[i] ?? null;

/** The charts of one activity in the member's units, or null with nothing
 * to draw. A ride shows speed; anything else with distance shows pace. */
export function activityCharts(s: ActivityStreams, kind: string, miles: boolean): Charts | null {
  if (s.v !== 1 || s.t.length === 0) return null;
  const unit = miles ? METERS_PER_MILE : 1000;
  const unitName = miles ? 'mi' : 'km';
  const n = s.t.length;
  const byDistance = (s.total_distance_m ?? 0) > 0 && !!s.distance_m && s.distance_m.every((d) => d !== null);
  const xs = s.t.map((t, i) => (byDistance ? s.distance_m![i]! / unit : t / 60));
  const series: Series[] = [];

  if (s.speed_mps) {
    const ride = kind === 'ride';
    const values = clampToPercentiles(Array.from({ length: n }, (_, i) => {
      const mps = at(s.speed_mps, i);
      if (mps === null) return null;
      if (ride) return mps > 0 ? (mps * 3600) / unit : null;
      return mps >= SLOWEST_MOVING_MPS ? unit / mps : null;
    }));
    const speedUnit = miles ? 'mph' : 'km/h';
    const units = (s.total_distance_m ?? 0) / unit;
    const overall = units > 0 && s.moving_s > 0
      ? (ride ? units / (s.moving_s / 3600) : s.moving_s / units)
      : average(values);
    if (values.some((v) => v !== null)) {
      series.push(ride
        ? { key: 'pace', title: 'Speed', values, reversed: false, average: overall,
            format: (v) => `${v.toFixed(1)} ${speedUnit}`, tick: (v) => v.toFixed(0) }
        : { key: 'pace', title: 'Pace', values, reversed: true, average: overall,
            format: (v) => `${formatPace(v)} /${unitName}`, tick: formatPace });
    }
  }
  if (s.heart_rate?.some((v) => v !== null)) {
    series.push({ key: 'heart_rate', title: 'Heart rate', values: s.heart_rate, reversed: false,
      average: average(s.heart_rate),
      format: (v) => `${Math.round(v)} bpm`, tick: (v) => `${Math.round(v)}` });
  }
  if (s.elevation_m?.some((v) => v !== null)) {
    const toUnit = miles ? FEET_PER_METER : 1;
    const elevUnit = miles ? 'ft' : 'm';
    const climb = s.elevation_gain_m === null ? null : Math.round(s.elevation_gain_m * toUnit);
    const elevation = s.elevation_m.map((v) => (v === null ? null : v * toUnit));
    series.push({
      key: 'elevation',
      title: climb === null ? 'Elevation' : `Elevation · ${climb} ${elevUnit} climb`,
      values: elevation,
      average: average(elevation),
      reversed: false,
      format: (v) => `${Math.round(v)} ${elevUnit}`,
      tick: (v) => `${Math.round(v)}`,
    });
  }
  if (series.length === 0) return null;
  return {
    xs,
    xUnit: byDistance ? unitName : 'min',
    series,
    formatX: byDistance ? (x) => `${x.toFixed(2)} ${unitName}` : (x) => formatClock(x * 60),
  };
}

/** The smallest and largest known value, widened when they are equal. */
export function valueDomain(values: (number | null)[]): [number, number] | null {
  const known = values.filter((v): v is number => v !== null);
  if (known.length === 0) return null;
  let lo = Math.min(...known);
  let hi = Math.max(...known);
  if (hi - lo < 1e-9) {
    lo -= 1;
    hi += 1;
  }
  return [lo, hi];
}

/** SVG path data for each unbroken run of values, in a `width` x `height`
 * box. A null value breaks the line. */
export function linePaths(xs: number[], values: (number | null)[], width: number, height: number, reversed: boolean): string[] {
  const domain = valueDomain(values);
  const x0 = xs[0] ?? 0;
  const x1 = xs[xs.length - 1] ?? 1;
  if (!domain) return [];
  const [lo, hi] = domain;
  const px = (x: number) => (x1 === x0 ? 0 : ((x - x0) / (x1 - x0)) * width);
  const py = (y: number) => {
    const f = (y - lo) / (hi - lo);
    return (reversed ? f : 1 - f) * height;
  };
  const paths: string[] = [];
  let current: string[] = [];
  values.forEach((v, i) => {
    if (v === null) {
      if (current.length > 1) paths.push(current.join(' '));
      current = [];
      return;
    }
    current.push(`${current.length === 0 ? 'M' : 'L'}${px(xs[i]!).toFixed(1)},${py(v).toFixed(1)}`);
  });
  if (current.length > 1) paths.push(current.join(' '));
  return paths;
}

/** The index of the point nearest a fraction (0 to 1) across the chart. */
export function nearestIndex(xs: number[], fraction: number): number {
  if (xs.length === 0) return -1;
  const x0 = xs[0]!;
  const x1 = xs[xs.length - 1]!;
  const target = x0 + Math.min(1, Math.max(0, fraction)) * (x1 - x0);
  let best = 0;
  for (let i = 1; i < xs.length; i++) {
    if (Math.abs(xs[i]! - target) < Math.abs(xs[best]! - target)) best = i;
  }
  return best;
}

/** The mean of the known values. */
export function average(values: (number | null)[]): number | null {
  const known = values.filter((v): v is number => v !== null);
  return known.length === 0 ? null : known.reduce((a, b) => a + b, 0) / known.length;
}
