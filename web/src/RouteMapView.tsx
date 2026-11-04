import { useEffect, useRef, useState } from 'react';
import { fetchActivityRoute } from './api';
import { accentColor, drawRoute, loadMapKit, onMapKitFailure } from './mapkit';
import { drawableSegments, routeOutline, type LatLon } from './routeMap';

/**
 * A run's route under its card: Apple Maps when the site has a MapKit JS
 * token, otherwise (or when the map can't load) the route's shape on its
 * own. Shows nothing for an activity without a route, or while
 * intervals.icu can't send its track.
 */
export function RouteMap({ activityId, label }: { activityId: string; label: string }) {
  const [loaded, setLoaded] = useState<{ id: string; segments: LatLon[][] } | null>(null);

  useEffect(() => {
    let live = true;
    fetchActivityRoute(activityId)
      .then((found) => {
        if (live) setLoaded({ id: activityId, segments: found ? drawableSegments(found.route) : [] });
      })
      .catch(() => {
        if (live) setLoaded({ id: activityId, segments: [] });
      });
    return () => {
      live = false;
    };
  }, [activityId]);

  const segments = loaded?.id === activityId ? loaded.segments : [];
  if (segments.length === 0) return null;
  return <RouteView key={activityId} segments={segments} label={label} />;
}

function RouteView({ segments, label }: { segments: LatLon[][]; label: string }) {
  const element = useRef<HTMLDivElement>(null);
  const [lineOnly, setLineOnly] = useState(false);

  useEffect(() => {
    const parent = element.current;
    if (lineOnly || !parent) return;
    let cancelled = false;
    let drawn: ReturnType<typeof drawRoute> | null = null;
    const stopWatching = onMapKitFailure(() => setLineOnly(true));
    const media = window.matchMedia('(prefers-color-scheme: dark)');
    const recolor = () => {
      for (const style of drawn?.styles ?? []) style.strokeColor = accentColor(parent);
    };
    media.addEventListener('change', recolor);
    loadMapKit()
      .then((mapkit) => {
        if (!cancelled) drawn = drawRoute(mapkit, parent, segments);
      })
      .catch(() => {
        if (!cancelled) setLineOnly(true);
      });
    return () => {
      cancelled = true;
      stopWatching();
      media.removeEventListener('change', recolor);
      drawn?.map.destroy();
    };
  }, [segments, lineOnly]);

  if (lineOnly) return <RouteOutline segments={segments} label={label} />;
  return <div ref={element} className="route-map" role="group" aria-label={label} />;
}

const OUTLINE_WIDTH = 320;
const OUTLINE_HEIGHT = 200;

function RouteOutline({ segments, label }: { segments: LatLon[][]; label: string }) {
  const paths = routeOutline(segments, OUTLINE_WIDTH, OUTLINE_HEIGHT);
  return (
    <div className="route-map outline">
      <svg viewBox={`0 0 ${OUTLINE_WIDTH} ${OUTLINE_HEIGHT}`} role="img" aria-label={label}>
        {paths.map((d, i) => <path key={i} d={d} className="route-line" />)}
      </svg>
    </div>
  );
}
