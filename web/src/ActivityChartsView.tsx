import { useEffect, useState, type PointerEvent } from 'react';
import { fetchActivityStreams } from './api';
import {
  activityCharts, linePaths, nearestIndex, valueDomain, type ActivityStreams, type Charts, type Series,
} from './activityCharts';

const WIDTH = 320;
const HEIGHT = 80;

/**
 * Pace, heart rate and elevation charts under an activity's card
 * (docs/plans/run-detail-charts P2). Shows nothing for an activity with
 * nothing to chart, or while intervals.icu can't send its streams. Pointing
 * at any chart reads all of them at that point.
 */
export function ActivityCharts({ activityId, kind, miles }: { activityId: string; kind: string; miles: boolean }) {
  const [loaded, setLoaded] = useState<{ id: string; streams: ActivityStreams | null } | null>(null);
  const [index, setIndex] = useState<number | null>(null);

  useEffect(() => {
    let live = true;
    setIndex(null);
    fetchActivityStreams(activityId)
      .then((found) => {
        if (live) setLoaded({ id: activityId, streams: found?.streams ?? null });
      })
      .catch(() => {
        if (live) setLoaded({ id: activityId, streams: null });
      });
    return () => {
      live = false;
    };
  }, [activityId]);

  const streams = loaded?.id === activityId ? loaded.streams : null;
  const charts = streams ? activityCharts(streams, kind, miles) : null;
  if (!charts) return null;

  const point = (event: PointerEvent<SVGSVGElement>) => {
    const box = event.currentTarget.getBoundingClientRect();
    setIndex(nearestIndex(charts.xs, box.width > 0 ? (event.clientX - box.left) / box.width : 0));
  };

  return (
    <div className="activity-charts">
      {charts.series.map((series) => (
        <SeriesChart key={series.key} charts={charts} series={series} index={index}
          onPoint={point} onLeave={() => setIndex(null)} />
      ))}
      <p className="muted chart-at">
        {index === null ? 'Point at a chart to read it.' : `At ${charts.formatX(charts.xs[index]!)}`}
      </p>
    </div>
  );
}

function SeriesChart({ charts, series, index, onPoint, onLeave }: {
  charts: Charts;
  series: Series;
  index: number | null;
  onPoint: (event: PointerEvent<SVGSVGElement>) => void;
  onLeave: () => void;
}) {
  const paths = linePaths(charts.xs, series.values, WIDTH, HEIGHT, series.reversed);
  const domain = valueDomain(series.values);
  const reading = index === null ? null : series.values[index] ?? null;
  const mean = series.average;
  const x0 = charts.xs[0] ?? 0;
  const x1 = charts.xs[charts.xs.length - 1] ?? 1;
  const cursor = index === null || x1 === x0 ? null : ((charts.xs[index]! - x0) / (x1 - x0)) * WIDTH;
  const [top, bottom] = domain
    ? (series.reversed ? [domain[0], domain[1]] : [domain[1], domain[0]])
    : [null, null];
  return (
    <figure className={`chart chart-${series.key}`}>
      <figcaption>
        <span className="chart-title">{series.title}</span>
        <span className="chart-value">
          {index !== null
            ? (reading !== null ? series.format(reading) : '–')
            : (mean !== null ? `avg ${series.format(mean)}` : '')}
        </span>
      </figcaption>
      <div className="chart-body">
        <div className="chart-ticks" aria-hidden="true">
          <span>{top === null ? '' : series.tick(top)}</span>
          <span>{bottom === null ? '' : series.tick(bottom)}</span>
        </div>
        <svg viewBox={`0 0 ${WIDTH} ${HEIGHT}`} preserveAspectRatio="none" role="img"
          aria-label={`${series.title}${mean !== null ? `, average ${series.format(mean)}` : ''}`}
          onPointerMove={onPoint} onPointerDown={onPoint} onPointerLeave={onLeave}>
          {paths.map((d, i) => <path key={i} d={d} className="chart-line" vectorEffect="non-scaling-stroke" />)}
          {cursor === null ? null : (
            <line x1={cursor} x2={cursor} y1={0} y2={HEIGHT} className="chart-cursor" vectorEffect="non-scaling-stroke" />
          )}
        </svg>
      </div>
    </figure>
  );
}
