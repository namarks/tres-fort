// Chart series for one activity's detail view (docs/plans/run-detail-charts
// P0): speed (pace for a run), heart rate and elevation over moving time,
// ready to draw. Pure: no D1, no network. The inputs are a GPS route kept by
// Tres Fort (src/activityRoute.ts) or a provider's per-second streams; the
// output is a few hundred evenly spaced points, so a phone draws it as is.

import { decodeRoute, type EncodedRoute } from './activityRoute';

/** One sample of the activity's timeline. */
export interface TrackSample {
  /** Seconds after the activity's start (elapsed, pauses included). */
  t: number;
  /** Meters covered since the start, or null when unknown. */
  d: number | null;
  /** Meters above sea level, or null. */
  alt: number | null;
  /** True on the first sample after a pause the device recorded. */
  newSegment?: boolean;
}

/** One reading of a value at a time (seconds after the start). */
export interface ValueSample {
  t: number;
  v: number;
}

export interface ActivityStreams {
  v: 1;
  /** Seconds of moving time at the middle of each point. */
  t: number[];
  /** Meters covered by the end of each point; null when unknown. */
  distance_m: (number | null)[] | null;
  /** Meters a second around each point (pace for a run is its inverse);
   * null when unknown. Standing still is 0. */
  speed_mps: (number | null)[] | null;
  /** Beats a minute. */
  heart_rate: (number | null)[] | null;
  /** Meters above sea level, lightly smoothed. */
  elevation_m: (number | null)[] | null;
  /** Total moving seconds. */
  moving_s: number;
  /** Total meters, when distance is known. */
  total_distance_m: number | null;
  /** Meters climbed, ignoring rises under the noise threshold. */
  elevation_gain_m: number | null;
}

/** A recording gap longer than this is a pause, as a watch's auto-pause
 * leaves no samples behind. */
export const PAUSE_GAP_S = 30;
/** At most this many points are served. */
export const MAX_POINTS = 500;
/** No point is finer than this many seconds. */
export const MIN_BUCKET_S = 5;
/** Speed is measured over this many seconds around each point. */
const SPEED_WINDOW_S = 30;
/** Elevation is averaged over this many seconds around each point, which
 * calms GPS altitude noise without flattening real hills. */
const ELEVATION_WINDOW_S = 30;
/** A climb counts once it rises this far above the last low point. */
const GAIN_THRESHOLD_M = 3;
/** Faster than this is a GPS jump, not a person. */
const MAX_SPEED_MPS = 30;

const EARTH_RADIUS_M = 6_371_008.8;

/** Great-circle meters between two points. */
export function haversineMeters(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const rad = Math.PI / 180;
  const dLat = (lat2 - lat1) * rad;
  const dLon = (lon2 - lon1) * rad;
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(dLon / 2) ** 2;
  return 2 * EARTH_RADIUS_M * Math.asin(Math.min(1, Math.sqrt(a)));
}

/**
 * Meters walked along GPS fixes, leg by leg. A leg faster than a person
 * moves is a bad fix: it adds nothing and the next leg is measured from the
 * last good fix, so neither the jump nor the return counts. When fixes keep
 * disagreeing with the last good one for longer than a pause, the walker
 * starts again from the newest fix instead of rejecting the rest.
 */
class GpsDistance {
  meters = 0;
  private last: { t: number; lat: number; lon: number } | null = null;
  private rejectedSince: number | null = null;

  /** Forget the last fix, as after a pause; nothing is added across it. */
  restart(): void {
    this.last = null;
    this.rejectedSince = null;
  }

  /** Add the leg to a fix at `t` seconds; the total so far. */
  add(t: number, lat: number, lon: number): number {
    const last = this.last;
    if (!last) {
      this.last = { t, lat, lon };
      return this.meters;
    }
    const leg = haversineMeters(last.lat, last.lon, lat, lon);
    if (leg <= MAX_SPEED_MPS * Math.max(1, t - last.t)) {
      this.meters += leg;
      this.last = { t, lat, lon };
      this.rejectedSince = null;
    } else {
      this.rejectedSince ??= t;
      if (t - this.rejectedSince > PAUSE_GAP_S) {
        this.last = { t, lat, lon };
        this.rejectedSince = null;
      }
    }
    return this.meters;
  }
}

/** A stored route's timeline: distance walked point to point within each
 * segment, a new segment after each pause. */
export function trackFromRoute(route: EncodedRoute): TrackSample[] {
  const segments = decodeRoute(route);
  const start = route.start_ms;
  const track: TrackSample[] = [];
  const gps = new GpsDistance();
  for (const segment of segments) {
    gps.restart();
    for (let i = 0; i < segment.length; i++) {
      const p = segment[i]!;
      const t = (p.t - start) / 1000;
      const d = gps.add(t, p.lat, p.lon);
      track.push({ t, d, alt: p.alt, newSegment: i === 0 && track.length > 0 });
    }
  }
  return track;
}

/** A provider's index-aligned streams, as intervals.icu sends them. */
export interface ProviderStreams {
  /** Seconds after the start; null means one second per sample. */
  time: readonly (number | null)[] | null;
  /** Cumulative meters. */
  distance: readonly (number | null)[] | null;
  heartrate: readonly (number | null)[] | null;
  altitude: readonly (number | null)[] | null;
  lat: readonly (number | null)[] | null;
  lon: readonly (number | null)[] | null;
}

/** The longest stream's length, so a missing one never shortens the rest. */
function streamLength(s: ProviderStreams): number {
  return Math.max(0, ...[s.time, s.distance, s.heartrate, s.altitude, s.lat].map((a) => a?.length ?? 0));
}

/** A provider's streams as a timeline and heart-rate readings. Distance comes
 * from the provider's own distance stream (a foot pod or wheel works indoors
 * too), else from the GPS positions. */
export function samplesFromProvider(s: ProviderStreams): { track: TrackSample[]; heartRate: ValueSample[] } {
  const n = streamLength(s);
  const track: TrackSample[] = [];
  const heartRate: ValueSample[] = [];
  const useGps = !s.distance?.some((v) => v != null) && !!s.lat && !!s.lon;
  const gps = new GpsDistance();
  let lastT = -Infinity;
  for (let i = 0; i < n; i++) {
    const t = s.time ? s.time[i] : i;
    if (t == null || !Number.isFinite(t) || t < lastT) continue;
    lastT = t;
    let d: number | null = null;
    if (useGps) {
      const lat = s.lat![i];
      const lon = s.lon![i];
      if (lat != null && lon != null && !(lat === 0 && lon === 0)) {
        d = gps.add(t, lat, lon);
      }
    } else {
      const v = s.distance?.[i];
      d = v != null && Number.isFinite(v) && v >= 0 ? v : null;
    }
    const alt = s.altitude?.[i];
    track.push({ t, d, alt: alt != null && Number.isFinite(alt) ? alt : null });
    const hr = s.heartrate?.[i];
    if (hr != null && Number.isFinite(hr)) heartRate.push({ t, v: hr });
  }
  return { track, heartRate };
}

/** Elapsed seconds to moving seconds: pauses are cut out. */
interface Clock {
  /** Moving seconds at elapsed `t`, or null inside a pause. */
  moving(t: number): number | null;
  total: number;
}

function clockFrom(timeline: readonly TrackSample[]): Clock {
  // Each run of samples with no pause between them is one stretch.
  const stretches: { start: number; end: number; movingBefore: number }[] = [];
  let movingBefore = 0;
  for (let i = 0; i < timeline.length; i++) {
    const s = timeline[i]!;
    const current = stretches[stretches.length - 1];
    const paused = !current || s.newSegment || s.t - current.end > PAUSE_GAP_S;
    if (paused) {
      if (current) movingBefore += current.end - current.start;
      stretches.push({ start: s.t, end: s.t, movingBefore });
    } else {
      current.end = s.t;
    }
  }
  const last = stretches[stretches.length - 1];
  const total = last ? last.movingBefore + (last.end - last.start) : 0;
  return {
    total,
    moving(t: number) {
      let lo = 0;
      let hi = stretches.length - 1;
      while (lo <= hi) {
        const mid = (lo + hi) >> 1;
        const s = stretches[mid]!;
        if (t < s.start) hi = mid - 1;
        else if (t > s.end) lo = mid + 1;
        else return s.movingBefore + (t - s.start);
      }
      return null;
    },
  };
}

const round = (v: number, places: number) => {
  const f = 10 ** places;
  return Math.round(v * f) / f;
};

const allNull = (a: readonly (number | null)[]) => a.every((v) => v === null);

/** Mean of each bucket's readings, or null for an empty bucket. */
function bucketMeans(
  readings: readonly ValueSample[],
  clock: Clock,
  width: number,
  count: number,
  valid: (v: number) => boolean,
): (number | null)[] {
  const sum = new Array<number>(count).fill(0);
  const n = new Array<number>(count).fill(0);
  for (const r of readings) {
    if (!valid(r.v)) continue;
    const m = clock.moving(r.t);
    if (m === null) continue;
    const b = Math.min(count - 1, Math.floor(m / width));
    sum[b] = sum[b]! + r.v;
    n[b] = n[b]! + 1;
  }
  return sum.map((s, i) => (n[i]! > 0 ? s / n[i]! : null));
}

/** Centered mean over `radius` points either side, skipping nulls. */
function smooth(values: readonly (number | null)[], radius: number): (number | null)[] {
  return values.map((v, i) => {
    if (v === null) return null;
    let s = 0;
    let n = 0;
    for (let j = Math.max(0, i - radius); j <= Math.min(values.length - 1, i + radius); j++) {
      const w = values[j];
      if (w !== null && w !== undefined) {
        s += w;
        n += 1;
      }
    }
    return s / n;
  });
}

/** Meters climbed, counting a rise once it clears the noise threshold. */
export function elevationGain(values: readonly (number | null)[]): number | null {
  const known = values.filter((v): v is number => v !== null);
  if (known.length < 2) return null;
  let gain = 0;
  let low = known[0]!;
  for (const v of known) {
    if (v < low) low = v;
    else if (v - low >= GAIN_THRESHOLD_M) {
      gain += v - low;
      low = v;
    }
  }
  return gain;
}

/**
 * The chart series of one activity: a timeline (times, distance, altitude)
 * and any heart-rate readings, on the same elapsed-seconds clock. The
 * timeline's gaps and segment starts are the pauses; with no timeline the
 * heart-rate readings set the clock. Null when there is under one bucket's
 * worth of moving time or nothing to draw.
 */
export function buildActivityStreams(
  track: readonly TrackSample[],
  heartRate: readonly ValueSample[] = [],
): ActivityStreams | null {
  const timeline = track.length > 0
    ? track
    : heartRate.map((r) => ({ t: r.t, d: null, alt: null }));
  const clock = clockFrom(timeline);
  if (clock.total < MIN_BUCKET_S * 2) return null;
  const width = Math.max(MIN_BUCKET_S, Math.ceil(clock.total / MAX_POINTS));
  const count = Math.max(1, Math.ceil(clock.total / width));

  // Distance at the end of each bucket, and the moving time it was reached:
  // the last accepted value at or before it. A reading that goes backwards,
  // or forwards faster than a person moves since the last accepted one, is a
  // glitch and is skipped, so one bad sample can't hold the distance up for
  // the rest of the activity.
  const lastD = new Array<number | null>(count).fill(null);
  const lastM = new Array<number>(count).fill(0);
  let accepted: { d: number; m: number } | null = null;
  for (const s of track) {
    if (s.d === null) continue;
    const m = clock.moving(s.t);
    if (m === null) continue;
    if (accepted && (s.d < accepted.d || s.d - accepted.d > MAX_SPEED_MPS * Math.max(1, m - accepted.m))) continue;
    accepted = { d: s.d, m };
    const b = Math.min(count - 1, Math.floor(m / width));
    if (lastD[b] === null || s.d >= lastD[b]!) {
      lastD[b] = s.d;
      lastM[b] = m;
    }
  }
  const distance: (number | null)[] = [];
  const reachedAt: (number | null)[] = [];
  let carried: { d: number; m: number } | null = null;
  for (let i = 0; i < count; i++) {
    const d = lastD[i];
    if (d !== null && d !== undefined && (carried === null || d >= carried.d)) carried = { d, m: lastM[i]! };
    distance.push(carried?.d ?? null);
    reachedAt.push(carried?.m ?? null);
  }

  // Speed over a window either side, from moving time, so a pause doesn't
  // slow the pace drawn on either side of it.
  const k = Math.max(1, Math.round(SPEED_WINDOW_S / width / 2));
  const speed = distance.map((_, i) => {
    const a = Math.max(0, i - k);
    const b = Math.min(count - 1, i + k);
    const da = distance[a];
    const db = distance[b];
    const ma = reachedAt[a];
    const mb = reachedAt[b];
    if (da == null || db == null || ma == null || mb == null || mb <= ma) return null;
    const v = (db - da) / (mb - ma);
    return v >= 0 && v <= MAX_SPEED_MPS ? v : null;
  });

  const hr = bucketMeans(heartRate, clock, width, count, (v) => v >= 25 && v <= 250);
  const altReadings = track.flatMap((s) => (s.alt === null ? [] : [{ t: s.t, v: s.alt }]));
  const elevation = smooth(
    bucketMeans(altReadings, clock, width, count, (v) => Math.abs(v) < 10_000),
    Math.max(1, Math.round(ELEVATION_WINDOW_S / width / 2)),
  );

  const hasDistance = !allNull(distance) && (distance[count - 1] ?? 0) > 0;
  const hasHr = !allNull(hr);
  const hasElevation = !allNull(elevation);
  if (!hasDistance && !hasHr && !hasElevation) return null;
  const totalDistance = hasDistance ? distance[count - 1]! : null;
  const gain = hasElevation ? elevationGain(elevation) : null;
  return {
    v: 1,
    t: Array.from({ length: count }, (_, i) => Math.round(Math.min(clock.total, (i + 0.5) * width))),
    distance_m: hasDistance ? distance.map((d) => (d === null ? null : round(d, 0))) : null,
    speed_mps: hasDistance ? speed.map((v) => (v === null ? null : round(v, 2))) : null,
    heart_rate: hasHr ? hr.map((v) => (v === null ? null : Math.round(v))) : null,
    elevation_m: hasElevation ? elevation.map((v) => (v === null ? null : round(v, 1))) : null,
    moving_s: Math.round(clock.total),
    total_distance_m: totalDistance === null ? null : round(totalDistance, 0),
    elevation_gain_m: gain === null ? null : Math.round(gain),
  };
}
