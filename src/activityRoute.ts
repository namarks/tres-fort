// GPS routes of runs recorded in the app (docs/plans/run-recorder P5,
// migration 0063). Pure: no D1. A route is kept as parallel arrays of small
// integers, each the change from the point before, so a long run stays far
// below D1's 2 MB row limit while keeping every recorded fix.

export interface RoutePoint {
  /** Epoch milliseconds. */
  t: number;
  lat: number;
  lon: number;
  /** Meters above sea level, when the fix carried one. */
  alt: number | null;
}

/**
 * The stored and served form. Point i's time is `start_ms` plus the sum of
 * `dt[0..i]`; its latitude is the sum of `dlat[0..i]` micro-degrees, and the
 * same for longitude. `dt[0]`, `dlat[0]` and `dlon[0]` are therefore the
 * first point itself (0 ms, and absolute micro-degrees). Altitude is
 * absolute, in decimeters, or null. A pause starts a new segment: `breaks`
 * lists the index of each segment's first point after the first segment.
 */
export interface EncodedRoute {
  v: 1;
  start_ms: number;
  dt: number[];
  dlat: number[];
  dlon: number[];
  alt: (number | null)[];
  breaks: number[];
}

/** Twelve hours of fixes at one a second. A longer route keeps every
 * segment's ends and an even share of the points between them. */
export const MAX_ROUTE_POINTS = 43_200;

const MICRO = 1_000_000;

function validPoint(p: RoutePoint): boolean {
  return Number.isSafeInteger(p.t) && p.t >= 0
    && Number.isFinite(p.lat) && p.lat >= -90 && p.lat <= 90
    && Number.isFinite(p.lon) && p.lon >= -180 && p.lon <= 180
    && (p.alt === null || (Number.isFinite(p.alt) && Math.abs(p.alt) < 100_000));
}

/** Every `step`-th point, keeping the segment's first and last. */
function thin(points: RoutePoint[], step: number): RoutePoint[] {
  if (step <= 1 || points.length <= 2) return points;
  const kept = points.filter((_, i) => i % step === 0);
  if (kept[kept.length - 1] !== points[points.length - 1]) kept.push(points[points.length - 1]!);
  return kept;
}

/**
 * Encode a route's segments, in time order. Invalid points, points that go
 * back in time and empty segments are dropped. Null when nothing is left.
 */
export function encodeRoute(segments: readonly (readonly RoutePoint[])[]): EncodedRoute | null {
  const cleaned: RoutePoint[][] = [];
  let last = -Infinity;
  for (const segment of segments) {
    const kept: RoutePoint[] = [];
    for (const p of segment) {
      if (!validPoint(p) || p.t < last) continue;
      kept.push(p);
      last = p.t;
    }
    if (kept.length > 0) cleaned.push(kept);
  }
  const total = cleaned.reduce((n, s) => n + s.length, 0);
  if (total === 0) return null;
  const step = Math.ceil(total / MAX_ROUTE_POINTS);
  const thinned = cleaned.map((s) => thin(s, step));

  const route: EncodedRoute = {
    v: 1, start_ms: thinned[0]![0]!.t, dt: [], dlat: [], dlon: [], alt: [], breaks: [],
  };
  let t = route.start_ms;
  let lat = 0;
  let lon = 0;
  for (const segment of thinned) {
    if (route.dt.length > 0) route.breaks.push(route.dt.length);
    for (const p of segment) {
      const plat = Math.round(p.lat * MICRO);
      const plon = Math.round(p.lon * MICRO);
      route.dt.push(p.t - t);
      route.dlat.push(plat - lat);
      route.dlon.push(plon - lon);
      route.alt.push(p.alt === null ? null : Math.round(p.alt * 10));
      t = p.t;
      lat = plat;
      lon = plon;
    }
  }
  return route;
}

/** The points of each segment, in order. */
export function decodeRoute(route: EncodedRoute): RoutePoint[][] {
  const segments: RoutePoint[][] = [];
  const breaks = new Set(route.breaks);
  let t = route.start_ms;
  let lat = 0;
  let lon = 0;
  let current: RoutePoint[] = [];
  for (let i = 0; i < route.dt.length; i++) {
    if (breaks.has(i) && current.length > 0) {
      segments.push(current);
      current = [];
    }
    t += route.dt[i]!;
    lat += route.dlat[i]!;
    lon += route.dlon[i]!;
    const alt = route.alt[i];
    current.push({ t, lat: lat / MICRO, lon: lon / MICRO, alt: alt === null || alt === undefined ? null : alt / 10 });
  }
  if (current.length > 0) segments.push(current);
  return segments;
}

export function routePointCount(route: EncodedRoute): number {
  return route.dt.length;
}

const isInt = (v: unknown): v is number => typeof v === 'number' && Number.isSafeInteger(v);

/** Reads a stored route back, or null when the text isn't one. */
export function parseStoredRoute(text: string): EncodedRoute | null {
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    return null;
  }
  if (typeof value !== 'object' || value === null) return null;
  const r = value as Record<string, unknown>;
  const n = Array.isArray(r.dt) ? r.dt.length : -1;
  if (r.v !== 1 || !isInt(r.start_ms) || n <= 0) return null;
  const arrays = [r.dt, r.dlat, r.dlon] as unknown[];
  if (!arrays.every((a) => Array.isArray(a) && a.length === n && a.every(isInt))) return null;
  if (!Array.isArray(r.alt) || r.alt.length !== n || !r.alt.every((a) => a === null || isInt(a))) return null;
  if (!Array.isArray(r.breaks) || !r.breaks.every((b) => isInt(b) && b > 0 && b < n)) return null;
  return value as EncodedRoute;
}
