// Pure rules for log_activity's endurance route: which free-form activity
// types are endurance sessions, how they map to intervals.icu activity types,
// and the unit/pace arithmetic. No I/O here; the provider write lives in
// services/intervalsActivityWrite.ts and the HTTP in intervals.ts.

export type EnduranceFamily = 'run' | 'ride' | 'swim' | 'walk';
export type DistanceUnit = 'mi' | 'km' | 'm';
export type PaceUnit = 'min/mi' | 'min/km';

interface Alias {
  family: EnduranceFamily;
  /** The alias itself names an indoor session ("treadmill", "spin"). */
  indoor?: true;
}

const ALIASES: Record<string, Alias> = {
  run: { family: 'run' },
  running: { family: 'run' },
  jog: { family: 'run' },
  jogging: { family: 'run' },
  'trail run': { family: 'run' },
  'road run': { family: 'run' },
  treadmill: { family: 'run', indoor: true },
  'treadmill run': { family: 'run', indoor: true },
  'indoor run': { family: 'run', indoor: true },
  ride: { family: 'ride' },
  bike: { family: 'ride' },
  biking: { family: 'ride' },
  cycle: { family: 'ride' },
  cycling: { family: 'ride' },
  'bike ride': { family: 'ride' },
  'road ride': { family: 'ride' },
  'gravel ride': { family: 'ride' },
  'mountain bike': { family: 'ride' },
  'indoor ride': { family: 'ride', indoor: true },
  'indoor cycling': { family: 'ride', indoor: true },
  'virtual ride': { family: 'ride', indoor: true },
  'trainer ride': { family: 'ride', indoor: true },
  'stationary bike': { family: 'ride', indoor: true },
  spin: { family: 'ride', indoor: true },
  'spin class': { family: 'ride', indoor: true },
  swim: { family: 'swim' },
  swimming: { family: 'swim' },
  'pool swim': { family: 'swim' },
  'lap swim': { family: 'swim' },
  'open water swim': { family: 'swim' },
  walk: { family: 'walk' },
  walking: { family: 'walk' },
  'treadmill walk': { family: 'walk', indoor: true },
  'indoor walk': { family: 'walk', indoor: true },
};

/** Lower-case, trim, and fold "-", "_" and repeated spaces to one space. */
export function normalizeActivityType(type: string): string {
  return type.toLowerCase().replace(/[-_]+/g, ' ').replace(/\s+/g, ' ').trim();
}

/** The endurance family for a free-form type, or null for a local-only type. */
export function enduranceAlias(type: string): Alias | null {
  return ALIASES[normalizeActivityType(type)] ?? null;
}

export interface IntervalsTypeMapping {
  family: EnduranceFamily;
  /** intervals.icu activity type. */
  type: 'Run' | 'Ride' | 'VirtualRide' | 'Swim' | 'Walk';
  trainer: boolean;
  /** Default activity name when the caller gives no title. */
  label: string;
}

/**
 * Map an endurance alias plus the optional `indoor` flag to intervals.icu.
 * An explicit `indoor` wins over the alias; "treadmill" is Run with
 * trainer=true and an indoor ride is VirtualRide. Swims never set trainer.
 */
export function intervalsTypeFor(alias: Alias, indoor?: boolean): IntervalsTypeMapping {
  const isIndoor = indoor ?? alias.indoor === true;
  switch (alias.family) {
    case 'run':
      return { family: 'run', type: 'Run', trainer: isIndoor, label: isIndoor ? 'Treadmill Run' : 'Run' };
    case 'ride':
      return isIndoor
        ? { family: 'ride', type: 'VirtualRide', trainer: true, label: 'Indoor Ride' }
        : { family: 'ride', type: 'Ride', trainer: false, label: 'Ride' };
    case 'swim':
      return { family: 'swim', type: 'Swim', trainer: false, label: 'Swim' };
    case 'walk':
      return { family: 'walk', type: 'Walk', trainer: isIndoor, label: isIndoor ? 'Treadmill Walk' : 'Walk' };
  }
}

export const METERS_PER: Record<DistanceUnit, number> = { mi: 1609.344, km: 1000, m: 1 };
const PACE_METERS: Record<PaceUnit, number> = { 'min/mi': 1609.344, 'min/km': 1000 };

export function isDistanceUnit(v: unknown): v is DistanceUnit {
  return v === 'mi' || v === 'km' || v === 'm';
}

export function isPaceUnit(v: unknown): v is PaceUnit {
  return v === 'min/mi' || v === 'min/km';
}

export function toMeters(distance: number, unit: DistanceUnit): number {
  return distance * METERS_PER[unit];
}

/**
 * Seconds per pace unit from "M:SS" (or "MM:SS") or a positive number of
 * minutes (8.5 = 8:30). Returns null for anything else.
 */
export function parsePaceSeconds(pace: unknown): number | null {
  if (typeof pace === 'number') {
    return Number.isFinite(pace) && pace > 0 ? Math.round(pace * 60) : null;
  }
  if (typeof pace !== 'string') return null;
  const m = /^(\d{1,3}):([0-5]\d)$/.exec(pace.trim());
  if (!m) return null;
  const seconds = Number(m[1]) * 60 + Number(m[2]);
  return seconds > 0 ? seconds : null;
}

/** Meters covered in `durationS` at `paceS` seconds per pace unit. */
export function distanceFromPace(durationS: number, paceS: number, unit: PaceUnit): number {
  return (durationS / paceS) * PACE_METERS[unit];
}

/** Seconds to cover `meters` at `paceS` seconds per pace unit. */
export function durationFromPace(meters: number, paceS: number, unit: PaceUnit): number {
  return (meters / PACE_METERS[unit]) * paceS;
}

/** "HH:MM" 24-hour clock, or null. */
export function parseClock(v: unknown): string | null {
  if (typeof v !== 'string') return null;
  const m = /^([01]?\d|2[0-3]):([0-5]\d)$/.exec(v.trim());
  return m ? `${m[1]!.padStart(2, '0')}:${m[2]}` : null;
}

/** The current "HH:MM" wall clock in an IANA timezone (UTC when invalid). */
export function clockInTz(tz: string | null | undefined, at: Date = new Date()): string {
  let zone = 'UTC';
  if (tz) {
    try {
      new Intl.DateTimeFormat('en-US', { timeZone: tz });
      zone = tz;
    } catch {
      zone = 'UTC';
    }
  }
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: zone,
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  }).formatToParts(at);
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? '00';
  return `${get('hour')}:${get('minute')}`;
}

/** Coarse family of an intervals.icu type, for duplicate matching. */
export function familyOfIntervalsType(type: string | null): EnduranceFamily | null {
  const t = (type ?? '').toLowerCase();
  if (t.includes('ride') || t.includes('cycl') || t.includes('bike')) return 'ride';
  if (t.includes('run')) return 'run';
  if (t.includes('swim')) return 'swim';
  if (t.includes('walk')) return 'walk';
  return null;
}

export interface ActivityMetrics {
  /** Whole seconds; duration_s, else duration_minutes, else distance at pace. */
  duration_s: number | null;
  distance_m: number | null;
  avg_hr: number | null;
  calories: number | null;
  indoor: boolean | undefined;
  start_time: string | null;
  /** Which value was computed rather than supplied. */
  derived: Array<'distance_from_pace' | 'duration_from_pace'>;
}

const positiveNumber = (v: unknown): v is number =>
  typeof v === 'number' && Number.isFinite(v) && v > 0;

/**
 * Validate and normalize log_activity's optional metric arguments. Returns
 * the invalid field names, or the resolved metrics. duration_s takes
 * precedence over duration_minutes; a pace fills in whichever of distance
 * and duration is missing.
 */
export function parseActivityMetrics(
  a: Record<string, unknown>,
): { invalid: string[] } | { metrics: ActivityMetrics } {
  const invalid: string[] = [];
  const has = (k: string) => Object.prototype.hasOwnProperty.call(a, k) && a[k] !== null;
  if (has('duration_s') && !positiveNumber(a.duration_s)) invalid.push('duration_s');
  if (
    has('duration_minutes') &&
    !(Number.isSafeInteger(a.duration_minutes) && (a.duration_minutes as number) >= 0)
  ) {
    invalid.push('duration_minutes');
  }
  if (has('distance') && !positiveNumber(a.distance)) invalid.push('distance');
  if (has('distance') ? !isDistanceUnit(a.distance_unit) : has('distance_unit') && !isDistanceUnit(a.distance_unit)) {
    invalid.push('distance_unit');
  }
  const paceS = has('pace') ? parsePaceSeconds(a.pace) : null;
  if (has('pace') && paceS === null) invalid.push('pace');
  if (has('pace') ? !isPaceUnit(a.pace_unit) : has('pace_unit') && !isPaceUnit(a.pace_unit)) {
    invalid.push('pace_unit');
  }
  if (
    has('avg_hr') &&
    !(Number.isSafeInteger(a.avg_hr) && (a.avg_hr as number) >= 20 && (a.avg_hr as number) <= 250)
  ) {
    invalid.push('avg_hr');
  }
  if (has('calories') && !(typeof a.calories === 'number' && Number.isFinite(a.calories) && a.calories >= 0)) {
    invalid.push('calories');
  }
  if (has('indoor') && typeof a.indoor !== 'boolean') invalid.push('indoor');
  const startTime = has('start_time') ? parseClock(a.start_time) : null;
  if (has('start_time') && startTime === null) invalid.push('start_time');
  if (invalid.length > 0) return { invalid };

  const derived: ActivityMetrics['derived'] = [];
  let durationS: number | null = has('duration_s')
    ? Math.round(a.duration_s as number)
    : has('duration_minutes')
      ? (a.duration_minutes as number) * 60
      : null;
  if (durationS === 0) durationS = null;
  let distanceM: number | null = has('distance')
    ? toMeters(a.distance as number, a.distance_unit as DistanceUnit)
    : null;
  if (paceS !== null) {
    const unit = a.pace_unit as PaceUnit;
    if (distanceM === null && durationS !== null) {
      distanceM = distanceFromPace(durationS, paceS, unit);
      derived.push('distance_from_pace');
    } else if (durationS === null && distanceM !== null) {
      durationS = Math.round(durationFromPace(distanceM, paceS, unit));
      derived.push('duration_from_pace');
    }
  }
  return {
    metrics: {
      duration_s: durationS,
      distance_m: distanceM === null ? null : Math.round(distanceM * 10) / 10,
      avg_hr: has('avg_hr') ? (a.avg_hr as number) : null,
      calories: has('calories') ? Math.round(a.calories as number) : null,
      indoor: has('indoor') ? (a.indoor as boolean) : undefined,
      start_time: startTime,
      derived,
    },
  };
}
