import { afterEach, describe, expect, it, vi } from 'vitest';
import { ApiError, fetchActivityRoute, fetchMapToken, type StateResponse } from '../src/api';
import { MAPKIT_LIBRARIES, MAPKIT_SCRIPT, MapUnavailableError, startMapKit, type MapKitApi } from '../src/mapkit';
import { drawableSegments, routableActivityIds, routeOutline } from '../src/routeMap';

/** The shape src/activityRoute.ts serves: two segments split by a pause. */
const ROUTE = {
  v: 1,
  start_ms: 1761962400000,
  dt: [0, 1000, 1000, 60000, 1000],
  dlat: [45519000, 27, 27, 500, 27],
  dlon: [-122679300, -11, -11, -300, -11],
  alt: [153, null, 154, 150, 150],
  breaks: [3],
};

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('a recorded route', () => {
  it('decodes into the lines a map draws', () => {
    const segments = drawableSegments(ROUTE);
    expect(segments.map((s) => s.length)).toEqual([3, 2]);
    expect(segments[0]![0]!.lat).toBeCloseTo(45.519, 9);
    expect(segments[0]![0]!.lon).toBeCloseTo(-122.6793, 9);
    expect(segments[1]![0]!.lat).toBeCloseTo(45.519554, 9);
    expect(segments[1]![0]!.lon).toBeCloseTo(-122.679622, 9);
  });

  it('draws no line for a lone point or a route that is not well formed', () => {
    expect(drawableSegments({ ...ROUTE, breaks: [2, 4] }).map((s) => s.length)).toEqual([2, 2]);
    expect(drawableSegments({ ...ROUTE, dlon: [-122679300] })).toEqual([]);
    expect(drawableSegments({ ...ROUTE, v: 2 })).toEqual([]);
    expect(drawableSegments(null)).toEqual([]);
    expect(drawableSegments({ ...ROUTE, dlat: [95000000, 0, 0, 0, 0] })).toEqual([]);
  });

  it('is looked for only on runs recorded in the app or their intervals.icu copy', () => {
    const activity = (id: string, source: string, kind: string, deleted_at: number | null = null) =>
      ({ id, source, kind, deleted_at });
    const state = {
      external_activities: [
        activity('recording:activity:u:r1', 'recording', 'run'),
        activity('intervals:activity:i1', 'intervals', 'run'),
        activity('healthkit:h1', 'healthkit', 'run'),
        activity('intervals:activity:i2', 'intervals', 'ride'),
        activity('recording:activity:u:r2', 'recording', 'run', 5),
      ],
    } as unknown as StateResponse;
    expect([...routableActivityIds(state)]).toEqual(['recording:activity:u:r1', 'intervals:activity:i1']);
  });
});

describe('the route without a map', () => {
  it('fits every point inside the margin without stretching the shape', () => {
    // About 1 km east and 1 km north at 45 degrees: a square, not a 1.4:1 box.
    const north = 1000 / 111_320;
    const east = 1000 / (111_320 * Math.cos((45 * Math.PI) / 180));
    const segments = [[{ lat: 45, lon: -122 }, { lat: 45, lon: -122 + east }, { lat: 45 + north, lon: -122 + east }]];
    const [path] = routeOutline(segments, 320, 200, 10);
    const points = path!.slice(1).split('L').map((pair) => pair.split(' ').map(Number) as [number, number]);
    for (const [x, y] of points) {
      expect(x).toBeGreaterThanOrEqual(10 - 0.05);
      expect(x).toBeLessThanOrEqual(310 + 0.05);
      expect(y).toBeGreaterThanOrEqual(10 - 0.05);
      expect(y).toBeLessThanOrEqual(190 + 0.05);
    }
    const width = points[1]![0] - points[0]![0];
    const height = points[1]![1] - points[2]![1];
    expect(width / height).toBeCloseTo(1, 1);
    // North is up.
    expect(points[2]![1]).toBeLessThan(points[1]![1]);
  });

  it('keeps each segment its own line and handles a route that never moved', () => {
    expect(routeOutline(drawableSegments(ROUTE), 320, 200)).toHaveLength(2);
    expect(routeOutline([], 320, 200)).toEqual([]);
    const still = routeOutline([[{ lat: 45, lon: -122 }, { lat: 45, lon: -122 }]], 320, 200);
    expect(still).toEqual(['M160.0 100.0L160.0 100.0']);
  });
});

describe('reading a route and the map token', () => {
  function stubFetch(status: number, body: unknown) {
    const fetch = vi.fn(async () => new Response(JSON.stringify(body), { status }));
    vi.stubGlobal('fetch', fetch);
    return fetch;
  }

  it('asks for the activity route with the page header and reads a not found as no route', async () => {
    const fetch = stubFetch(200, { activity_id: 'recording:activity:u:r1', recording_id: 'r1', route: ROUTE });
    const found = await fetchActivityRoute('intervals:activity:i1');
    expect(found?.recording_id).toBe('r1');
    const [url, init] = fetch.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe('/api/activities/intervals%3Aactivity%3Ai1/route');
    expect((init.headers as Record<string, string>)['x-tres-fort-web']).toBe('1');

    stubFetch(404, { error: 'not_found' });
    expect(await fetchActivityRoute('a')).toBeNull();
    stubFetch(500, {});
    await expect(fetchActivityRoute('a')).rejects.toBeInstanceOf(ApiError);
  });

  it('reads the map token, or none when maps are not set up', async () => {
    stubFetch(200, { token: 'mapkit-token' });
    expect(await fetchMapToken()).toBe('mapkit-token');
    stubFetch(404, { error: 'not_configured' });
    expect(await fetchMapToken()).toBeNull();
  });
});

describe('loading Apple Maps', () => {
  function fakeMapKit() {
    return {
      load: vi.fn(async () => undefined),
      addEventListener: vi.fn(),
    } as unknown as MapKitApi & { load: ReturnType<typeof vi.fn>; addEventListener: ReturnType<typeof vi.fn> };
  }

  it('never contacts Apple when the site has no token', async () => {
    const appendScript = vi.fn(async () => undefined);
    const onError = vi.fn();
    await expect(startMapKit({ fetchToken: async () => null, appendScript, current: () => undefined }, onError))
      .rejects.toBeInstanceOf(MapUnavailableError);
    expect(appendScript).not.toHaveBeenCalled();
  });

  it('loads MapKit JS with the token and only the map and overlay libraries', async () => {
    const mapkit = fakeMapKit();
    let loaded: MapKitApi | undefined;
    const appendScript = vi.fn(async () => {
      loaded = mapkit;
    });
    const onError = vi.fn();
    const result = await startMapKit({ fetchToken: async () => 'mapkit-token', appendScript, current: () => loaded }, onError);
    expect(result).toBe(mapkit);
    expect(appendScript).toHaveBeenCalledWith(expect.objectContaining({
      src: MAPKIT_SCRIPT,
      'data-token': 'mapkit-token',
      'data-libraries': 'map,overlays',
    }));
    expect(MAPKIT_SCRIPT.startsWith('https://cdn.apple-mapkit.com/')).toBe(true);
    expect(mapkit.load).toHaveBeenCalledWith(MAPKIT_LIBRARIES);
    // A token Apple refuses is reported later, as MapKit's error event.
    expect(mapkit.addEventListener).toHaveBeenCalledWith('error', onError);
  });

  it('fails when the script loads without MapKit', async () => {
    await expect(startMapKit({
      fetchToken: async () => 'mapkit-token', appendScript: async () => undefined, current: () => undefined,
    }, vi.fn())).rejects.toBeInstanceOf(MapUnavailableError);
  });
});
