// A recorded run's route on the web (docs/plans/run-recorder P5). Pure: the
// map itself is drawn by RouteMapView.tsx.
import { asEncodedRoute, decodeRoute } from '../../src/activityRoute';
import type { StateResponse } from './api';

export interface LatLon {
  lat: number;
  lon: number;
}

/** `GET /api/activities/:id/route`. */
export interface ActivityRouteResponse {
  /** The recording that carries the route, which can differ from the
   * activity asked for when that is the intervals.icu copy of the run. */
  activity_id: string;
  recording_id: string;
  /** Null for a run recorded without GPS fixes. */
  route: unknown;
}

/**
 * The activities whose card may show a route: runs recorded in the app,
 * either the recording itself or the intervals.icu copy it was matched to.
 * The same rule as the iPhone app (`mayHaveRecordedRoute`).
 */
export function routableActivityIds(state: StateResponse): Set<string> {
  return new Set(state.external_activities
    .filter((a) => a.deleted_at === null && a.kind === 'run' && (a.source === 'recording' || a.source === 'intervals'))
    .map((a) => a.id));
}

const isCoordinate = (p: LatLon) =>
  Number.isFinite(p.lat) && Number.isFinite(p.lon) && Math.abs(p.lat) <= 90 && Math.abs(p.lon) <= 180;

/** The lines a map draws: each segment's valid points, when it has two or
 * more. Nothing for a route that isn't well formed. */
export function drawableSegments(route: unknown): LatLon[][] {
  const encoded = asEncodedRoute(route);
  if (!encoded) return [];
  return decodeRoute(encoded)
    .map((segment) => segment.map(({ lat, lon }) => ({ lat, lon })).filter(isCoordinate))
    .filter((segment) => segment.length > 1);
}

/**
 * SVG path data for the route's shape, fitted into a `width` x `height` box
 * with `margin` on every side and centered. Longitude is scaled by the
 * cosine of the middle latitude so the shape isn't stretched. Used when no
 * map can be shown.
 */
export function routeOutline(segments: LatLon[][], width: number, height: number, margin = 12): string[] {
  const points = segments.flat();
  const first = points[0];
  if (!first) return [];
  let minLat = first.lat, maxLat = first.lat, minLon = first.lon, maxLon = first.lon;
  for (const p of points) {
    minLat = Math.min(minLat, p.lat);
    maxLat = Math.max(maxLat, p.lat);
    minLon = Math.min(minLon, p.lon);
    maxLon = Math.max(maxLon, p.lon);
  }
  const kx = Math.cos((((minLat + maxLat) / 2) * Math.PI) / 180);
  const spanX = (maxLon - minLon) * kx;
  const spanY = maxLat - minLat;
  const fit = (room: number, span: number) => (span > 0 ? Math.max(room, 0) / span : Infinity);
  let scale = Math.min(fit(width - 2 * margin, spanX), fit(height - 2 * margin, spanY));
  if (!Number.isFinite(scale)) scale = 0;
  const left = (width - spanX * scale) / 2;
  const top = (height - spanY * scale) / 2;
  const at = (p: LatLon) => `${(left + (p.lon - minLon) * kx * scale).toFixed(1)} ${(top + (maxLat - p.lat) * scale).toFixed(1)}`;
  return segments
    .filter((segment) => segment.length > 1)
    .map((segment) => segment.map((p, i) => `${i === 0 ? 'M' : 'L'}${at(p)}`).join(''));
}
