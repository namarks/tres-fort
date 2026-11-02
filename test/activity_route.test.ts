// The GPS route encoding (src/activityRoute.ts) and the TCX reader
// (src/tcxFile.ts) behind runs recorded in the app
// (docs/plans/run-recorder P5). Pure functions; no D1.
import { describe, expect, it } from 'vitest';
import {
  MAX_ROUTE_POINTS, decodeRoute, encodeRoute, parseStoredRoute, routePointCount, type RoutePoint,
} from '../src/activityRoute';
import { TcxParseError, parseTcx } from '../src/tcxFile';

const T0 = Date.parse('2026-11-01T02:00:00Z');
const point = (i: number, alt: number | null = 15.3): RoutePoint =>
  ({ t: T0 + i * 1_000, lat: 45.5190001 + i * 0.000027, lon: -122.6793 - i * 0.000011, alt });

describe('route encoding', () => {
  it('round-trips segments to a micro-degree, a millisecond and a decimeter', () => {
    const segments = [[point(0), point(1), point(2, null)], [point(30), point(31)]];
    const encoded = encodeRoute(segments)!;
    expect(encoded.breaks).toEqual([3]);
    expect(routePointCount(encoded)).toBe(5);
    expect(encoded.dt.slice(0, 2)).toEqual([0, 1_000]);
    const decoded = decodeRoute(encoded);
    expect(decoded.map((s) => s.length)).toEqual([3, 2]);
    decoded.flat().forEach((p, i) => {
      const want = segments.flat()[i]!;
      expect(p.t).toBe(want.t);
      expect(Math.abs(p.lat - want.lat)).toBeLessThanOrEqual(0.0000005);
      expect(Math.abs(p.lon - want.lon)).toBeLessThanOrEqual(0.0000005);
      expect(p.alt).toBe(want.alt === null ? null : Math.round(want.alt * 10) / 10);
    });
    expect(parseStoredRoute(JSON.stringify(encoded))).toEqual(encoded);
  });

  it('drops impossible and backward points and empty segments', () => {
    const encoded = encodeRoute([
      [],
      [point(0), { ...point(1), lat: 91 }, { ...point(2), lon: Number.NaN }, point(3)],
      [point(2)],
      [point(4)],
    ])!;
    expect(decodeRoute(encoded).map((s) => s.map((p) => p.t))).toEqual([[T0, T0 + 3_000], [T0 + 4_000]]);
    expect(encodeRoute([[], [{ ...point(0), lat: Number.POSITIVE_INFINITY }]])).toBeNull();
  });

  it('thins only a route longer than twelve hours of fixes, keeping each segment\'s ends', () => {
    const long = Array.from({ length: MAX_ROUTE_POINTS + 10 }, (_, i) => point(i));
    const encoded = encodeRoute([long, [point(MAX_ROUTE_POINTS + 20), point(MAX_ROUTE_POINTS + 21)]])!;
    expect(routePointCount(encoded)).toBeLessThanOrEqual(MAX_ROUTE_POINTS);
    const [first, second] = decodeRoute(encoded);
    expect(first![0]!.t).toBe(long[0]!.t);
    expect(first![first!.length - 1]!.t).toBe(long[long.length - 1]!.t);
    expect(second!.length).toBe(2);
    // A three-hour run keeps every fix, well under D1's row limit.
    const run = encodeRoute([Array.from({ length: 10_800 }, (_, i) => point(i))])!;
    expect(routePointCount(run)).toBe(10_800);
    expect(JSON.stringify(run).length).toBeLessThan(300_000);
  });

  it('refuses stored text that is not a route', () => {
    expect(parseStoredRoute('not json')).toBeNull();
    expect(parseStoredRoute('{}')).toBeNull();
    const ok = encodeRoute([[point(0), point(1)]])!;
    expect(parseStoredRoute(JSON.stringify({ ...ok, v: 2 }))).toBeNull();
    expect(parseStoredRoute(JSON.stringify({ ...ok, dlat: [1] }))).toBeNull();
    expect(parseStoredRoute(JSON.stringify({ ...ok, alt: [1.5, null] }))).toBeNull();
    expect(parseStoredRoute(JSON.stringify({ ...ok, breaks: [0] }))).toBeNull();
  });
});

describe('TCX reader', () => {
  const tp = (iso: string, inner: string) => `<Trackpoint><Time>${iso}</Time>${inner}</Trackpoint>`;
  const pos = (lat: number, lon: number) =>
    `<Position><LatitudeDegrees>${lat}</LatitudeDegrees><LongitudeDegrees>${lon}</LongitudeDegrees></Position>`;
  const doc = (activity: string) =>
    `<?xml version="1.0"?><TrainingCenterDatabase xmlns="x"><Activities>${activity}</Activities></TrainingCenterDatabase>`;

  it('reads laps, tracks, heart rate and positions, and leaves out what is missing', () => {
    const run = parseTcx(doc(`<Activity Sport="Running"><Id>2026-11-01T02:00:00Z</Id>
      <Lap StartTime="2026-11-01T02:00:00Z"><TotalTimeSeconds>60</TotalTimeSeconds><DistanceMeters>200</DistanceMeters>
        <Calories>12</Calories>
        <Track>
          ${tp('2026-11-01T02:00:00Z', `${pos(45.5, -122.6)}<AltitudeMeters>10.5</AltitudeMeters><DistanceMeters>0</DistanceMeters><HeartRateBpm><Value>140</Value></HeartRateBpm>`)}
          ${tp('2026-11-01T02:00:30Z', `${pos(45.501, -122.6)}<HeartRateBpm><Value>0</Value></HeartRateBpm>`)}
          ${tp('2026-11-01T02:00:20Z', pos(45.6, -122.6))}
          ${tp('2026-11-01T02:01:00Z', '<HeartRateBpm><Value>160</Value></HeartRateBpm>')}
        </Track>
      </Lap>
      <Lap StartTime="2026-11-01T02:05:00Z"><TotalTimeSeconds>30</TotalTimeSeconds><DistanceMeters>100</DistanceMeters>
        <Track>${tp('2026-11-01T02:05:00Z', `${pos(0, 0)}<HeartRateBpm><Value>150</Value></HeartRateBpm>`)}
          ${tp('2026-11-01T02:05:30Z', pos(45.51, -122.6))}</Track>
      </Lap></Activity>`));
    expect(run).toMatchObject({
      start_utc_ms: T0, moving_sec: 90, distance_m: 300, calories: 12, elapsed_sec: 330, avg_hr: 150, max_hr: 160,
    });
    // Moving time: the second track starts where the first ended (60 s).
    expect(run.hr).toEqual([{ t: 0, v: 140 }, { t: 60, v: 160 }, { t: 60, v: 150 }]);
    // The backward point is dropped, and so are points with no fix or a 0,0 one.
    expect(run.segments.map((s) => s.map((p) => [p.lat, p.alt]))).toEqual([
      [[45.5, 10.5], [45.501, null]],
      [[45.51, null]],
    ]);
  });

  it('refuses a file that is not a TCX run', () => {
    const code = (text: string) => {
      try {
        parseTcx(text);
      } catch (e) {
        return e instanceof TcxParseError ? e.code : 'other';
      }
      return null;
    };
    expect(code('<gpx></gpx>')).toBe('not_tcx');
    expect(code(doc(''))).toBe('no_data');
    expect(code(doc('<Activity Sport="Biking"><Id>2026-11-01T02:00:00Z</Id></Activity>'))).toBe('not_a_run');
    expect(code(doc('<Activity Sport="Running"><Id>2026-11-01T02:00:00Z</Id><Lap StartTime="2026-11-01T02:00:00Z"></Lap></Activity>')))
      .toBe('no_data');
  });
});
