// Reader for the TCX (Garmin Training Center v2) files the app's run recorder
// uploads (docs/plans/run-recorder P5). Pure: text in, the run's totals, its
// heart-rate samples and its GPS route out. It reads only Activity, Lap,
// Track and Trackpoint elements, the shape RecordedRunTCX writes and Garmin
// tools share, and ignores everything else.

import type { RoutePoint } from './activityRoute';
import type { Sample } from './trainingLoad';

export class TcxParseError extends Error {
  constructor(readonly code: 'not_tcx' | 'not_a_run' | 'no_data') {
    super(code);
  }
}

export interface TcxRun {
  start_utc_ms: number;
  /** Lap time totals: moving time, pauses excluded. */
  moving_sec: number | null;
  /** First point to last, pauses included. */
  elapsed_sec: number | null;
  distance_m: number | null;
  calories: number | null;
  avg_hr: number | null;
  max_hr: number | null;
  /** `t` is moving seconds from the start: paused time is taken out, as in
   * a FIT file's timer time. */
  hr: Sample[];
  /** One segment per track; the recorder starts a new track after a pause. */
  segments: RoutePoint[][];
}

const tagPatterns = new Map<string, RegExp>();
/** The text of the first `name` element in `body`. */
const tag = (body: string, name: string): string | null => {
  let pattern = tagPatterns.get(name);
  if (!pattern) {
    pattern = new RegExp(`<${name}\\b[^>]*>([^<]*)</${name}>`);
    tagPatterns.set(name, pattern);
  }
  return pattern.exec(body)?.[1]?.trim() ?? null;
};

const num = (text: string | null): number | null => {
  if (text === null || text === '') return null;
  const n = Number(text);
  return Number.isFinite(n) ? n : null;
};

const time = (text: string | null): number | null => {
  if (text === null) return null;
  const ms = Date.parse(text);
  return Number.isFinite(ms) ? ms : null;
};

interface Trackpoint {
  t: number;
  lat: number | null;
  lon: number | null;
  alt: number | null;
  hr: number | null;
}

function readTrackpoint(body: string): Trackpoint | null {
  const t = time(tag(body, 'Time'));
  if (t === null) return null;
  const lat = num(tag(body, 'LatitudeDegrees'));
  const lon = num(tag(body, 'LongitudeDegrees'));
  const placed = lat !== null && lon !== null && Math.abs(lat) <= 90 && Math.abs(lon) <= 180
    && !(lat === 0 && lon === 0);
  const hrBlock = /<HeartRateBpm\b[^>]*>([\s\S]*?)<\/HeartRateBpm>/.exec(body)?.[1] ?? null;
  const hr = hrBlock === null ? null : num(tag(hrBlock, 'Value'));
  return {
    t,
    lat: placed ? lat : null,
    lon: placed ? lon : null,
    alt: num(tag(body, 'AltitudeMeters')),
    hr: hr !== null && hr > 0 && hr < 300 ? hr : null,
  };
}

/** Parse a TCX running activity. Throws TcxParseError. */
export function parseTcx(text: string): TcxRun {
  if (!text.includes('<TrainingCenterDatabase')) throw new TcxParseError('not_tcx');
  const activity = /<Activity\b([^>]*)>([\s\S]*?)<\/Activity>/.exec(text);
  if (!activity) throw new TcxParseError('no_data');
  const sport = /\bSport="([^"]*)"/.exec(activity[1]!)?.[1] ?? '';
  if (sport !== 'Running') throw new TcxParseError('not_a_run');

  let lapStart: number | null = null;
  let moving: number | null = null;
  let distance: number | null = null;
  let calories: number | null = null;
  const tracks: Trackpoint[][] = [];
  for (const lap of activity[2]!.matchAll(/<Lap\b([^>]*)>([\s\S]*?)<\/Lap>/g)) {
    const startAttr = /\bStartTime="([^"]*)"/.exec(lap[1]!)?.[1] ?? null;
    const start = time(startAttr);
    if (start !== null && (lapStart === null || start < lapStart)) lapStart = start;
    const body = lap[2]!;
    // Lap totals come before its first track, whose points repeat the names.
    const head = body.slice(0, body.search(/<Track\b/) < 0 ? body.length : body.search(/<Track\b/));
    const lapSeconds = num(tag(head, 'TotalTimeSeconds'));
    const lapMeters = num(tag(head, 'DistanceMeters'));
    const lapCalories = num(tag(head, 'Calories'));
    if (lapSeconds !== null && lapSeconds >= 0) moving = (moving ?? 0) + lapSeconds;
    if (lapMeters !== null && lapMeters >= 0) distance = (distance ?? 0) + lapMeters;
    if (lapCalories !== null && lapCalories > 0) calories = (calories ?? 0) + lapCalories;
    for (const track of body.matchAll(/<Track\b[^>]*>([\s\S]*?)<\/Track>/g)) {
      const points: Trackpoint[] = [];
      for (const tp of track[1]!.matchAll(/<Trackpoint\b[^>]*>([\s\S]*?)<\/Trackpoint>/g)) {
        const point = readTrackpoint(tp[1]!);
        if (point && (points.length === 0 || point.t >= points[points.length - 1]!.t)) points.push(point);
      }
      if (points.length > 0) tracks.push(points);
    }
  }
  tracks.sort((a, b) => a[0]!.t - b[0]!.t);

  const firstPoint = tracks[0]?.[0]?.t ?? null;
  const start = lapStart ?? firstPoint ?? time(tag(activity[2]!, 'Id'));
  if (start === null || (tracks.length === 0 && !moving)) throw new TcxParseError('no_data');
  const lastTrack = tracks[tracks.length - 1];
  const lastPoint = lastTrack?.[lastTrack.length - 1]?.t ?? null;

  // Heart rate on moving time: each track continues where the last one ended.
  const hr: Sample[] = [];
  let offset = 0;
  for (const track of tracks) {
    const trackStart = track[0]!.t;
    for (const p of track) {
      if (p.hr !== null) hr.push({ t: offset + Math.max(0, p.t - trackStart) / 1000, v: p.hr });
    }
    offset += Math.max(0, track[track.length - 1]!.t - trackStart) / 1000;
  }
  const readings = hr.map((s) => s.v);

  return {
    start_utc_ms: start,
    moving_sec: moving,
    elapsed_sec: lastPoint !== null && lastPoint >= start ? (lastPoint - start) / 1000 : moving,
    distance_m: distance,
    calories,
    avg_hr: readings.length > 0 ? readings.reduce((a, b) => a + b, 0) / readings.length : null,
    max_hr: readings.length > 0 ? readings.reduce((a, b) => Math.max(a, b)) : null,
    hr,
    segments: tracks.map((track) => track
      .filter((p) => p.lat !== null && p.lon !== null)
      .map((p) => ({ t: p.t, lat: p.lat!, lon: p.lon!, alt: p.alt }))),
  };
}
