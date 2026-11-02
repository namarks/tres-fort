// Apple Maps on the web (MapKit JS), loaded only when a route is shown.
// docs/plans/run-recorder P5: the owner chose Apple Maps for the web, as in
// the app. Nothing is requested from Apple until a member opens a day with
// a recorded route, and never when the site has no MapKit JS token.
import { fetchMapToken } from './api';
import type { LatLon } from './routeMap';

/** The parts of the MapKit JS namespace the route map uses. */
export interface MapKitApi {
  load(libraries: string[]): Promise<unknown>;
  addEventListener(type: 'error', listener: (event: unknown) => void): void;
  Map: new (parent: HTMLElement, options?: Record<string, unknown>) => MapKitMap;
  Coordinate: new (latitude: number, longitude: number) => unknown;
  PolylineOverlay: new (points: unknown[], options?: { style?: MapKitStyle }) => unknown;
  Style: new (options?: Record<string, unknown>) => MapKitStyle;
  Padding: new (top: number, right: number, bottom: number, left: number) => unknown;
}

export interface MapKitMap {
  addOverlays(overlays: unknown[]): unknown;
  showItems(items: unknown[], options?: Record<string, unknown>): unknown;
  destroy(): void;
}

export interface MapKitStyle {
  strokeColor: string;
}

declare global {
  interface Window {
    mapkit?: MapKitApi;
  }
}

/** MapKit JS 6, the current major version, as Apple's own loader picks it. */
export const MAPKIT_SCRIPT = 'https://cdn.apple-mapkit.com/mk/6/mapkit.core.js';
/** A basic map and its overlays; no search, annotations or user location. */
export const MAPKIT_LIBRARIES = ['map', 'overlays'];
const READY_CALLBACK = 'tresFortMapKitReady';

export class MapUnavailableError extends Error {}

export interface MapKitLoaderDeps {
  fetchToken(): Promise<string | null>;
  /** Adds the script element and settles when it has loaded or failed. */
  appendScript(attributes: Record<string, string>): Promise<void>;
  current(): MapKitApi | undefined;
}

/**
 * Loads MapKit JS with the site's token, the way Apple's mapkit-loader does:
 * a script element carrying the token and libraries, then `mapkit.load`.
 * Rejects without contacting Apple when the site has no token.
 */
export async function startMapKit(deps: MapKitLoaderDeps, onError: () => void): Promise<MapKitApi> {
  const token = await deps.fetchToken();
  if (!token) throw new MapUnavailableError('not_configured');
  let mapkit = deps.current();
  if (!mapkit) {
    await deps.appendScript({
      src: MAPKIT_SCRIPT,
      'data-callback': READY_CALLBACK,
      'data-libraries': MAPKIT_LIBRARIES.join(','),
      'data-token': token,
    });
    mapkit = deps.current();
  }
  if (!mapkit || typeof mapkit.load !== 'function') throw new MapUnavailableError('not_loaded');
  // MapKit checks the token after the script runs; a refused token (wrong
  // domain, revoked, expired) arrives later as this event.
  mapkit.addEventListener('error', onError);
  await mapkit.load(MAPKIT_LIBRARIES);
  return mapkit;
}

const browserDeps: MapKitLoaderDeps = {
  fetchToken: fetchMapToken,
  appendScript(attributes) {
    return new Promise((resolve, reject) => {
      const callbacks = window as unknown as Record<string, unknown>;
      callbacks[READY_CALLBACK] ??= () => {};
      const script = document.createElement('script');
      script.async = true;
      script.crossOrigin = 'anonymous';
      for (const [name, value] of Object.entries(attributes)) script.setAttribute(name, value);
      script.addEventListener('load', () => resolve(), { once: true });
      script.addEventListener('error', () => reject(new MapUnavailableError('script_failed')), { once: true });
      document.head.appendChild(script);
    });
  },
  current: () => window.mapkit,
};

let loading: Promise<MapKitApi> | null = null;
let failed = false;
const failureListeners = new Set<() => void>();

function markFailed() {
  failed = true;
  for (const listener of failureListeners) listener();
}

/** MapKit JS, loaded once per page. A failure lasts until the page reloads. */
export function loadMapKit(): Promise<MapKitApi> {
  loading ??= startMapKit(browserDeps, markFailed).catch((error: unknown) => {
    markFailed();
    throw error;
  });
  return loading;
}

/** Calls `listener` when MapKit fails, now or later; returns an unsubscribe. */
export function onMapKitFailure(listener: () => void): () => void {
  if (failed) {
    queueMicrotask(listener);
    return () => {};
  }
  failureListeners.add(listener);
  return () => failureListeners.delete(listener);
}

/** The site's accent color, read from the page so the line matches the theme. */
export function accentColor(element: Element): string {
  return getComputedStyle(element).getPropertyValue('--accent').trim() || '#37577f';
}

/** Draws each segment as its own line and frames the whole route. */
export function drawRoute(mapkit: MapKitApi, element: HTMLElement, segments: LatLon[][]) {
  const map = new mapkit.Map(element, {
    colorScheme: 'adaptive',
    showsPointsOfInterest: false,
    showsMapTypeControl: false,
    isRotationEnabled: false,
    showsCompass: 'hidden',
    showsScale: 'adaptive',
  });
  const color = accentColor(element);
  const styles = segments.map(() => new mapkit.Style({ lineWidth: 4, lineJoin: 'round', lineCap: 'round', strokeColor: color }));
  const lines = segments.map((segment, i) =>
    new mapkit.PolylineOverlay(segment.map((p) => new mapkit.Coordinate(p.lat, p.lon)), { style: styles[i] }));
  map.addOverlays(lines);
  map.showItems(lines, { animate: false, padding: new mapkit.Padding(24, 24, 24, 24) });
  return { map, styles };
}
