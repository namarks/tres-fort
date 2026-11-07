/**
 * Laps of a planned run recorded in the app (docs/plans/planned-runs P9).
 * The recorder follows the run's steps (src/runSteps.ts) and sends one lap
 * per step it ran with `POST /api/activities/recordings` (multipart field
 * `laps`, a JSON array): the lap's moving time, distance and heart rate, the
 * step it ran and that step's planned amount and target. Anything run after
 * the plan finished is a last lap with no step, so a walk to cool down never
 * blurs how the intervals went.
 *
 * Kept as canonical JSON text in `activity_laps` (migration 0069) and served
 * with the run's route. Private to the member, like routes.
 */
import { RUN_STEP_KINDS, RUN_STEP_LIMITS, type RunStepKind, type RunStepTarget } from './runSteps';

/** How a lap ended: its step was done, the member skipped it, or the run
 * stopped during it (the last lap). */
export const RUN_LAP_ENDS = ['completed', 'skipped', 'stopped'] as const;
export type RunLapEnd = typeof RUN_LAP_ENDS[number];

export interface RunLap {
  /** 1-based position of the step in the plan with repeats unrolled; null
   * for the stretch run after the plan finished. */
  step: number | null;
  kind: RunStepKind | null;
  /** Which time through a repeat this was, and how many times it repeats;
   * null outside a repeat. */
  round: number | null;
  rounds: number | null;
  /** What the step planned: a time or a distance. */
  planned_duration_s: number | null;
  planned_distance_m: number | null;
  target: RunStepTarget | null;
  /** Moving seconds from the run's start to the lap's start. */
  start_s: number;
  moving_s: number;
  distance_m: number;
  avg_hr: number | null;
  max_hr: number | null;
  end: RunLapEnd;
}

export const RUN_LAP_LIMITS = {
  /** Every unrolled step once, plus the stretch after the plan. */
  laps: RUN_STEP_LIMITS.expandedSteps + 1,
  seconds: 24 * 60 * 60,
  meters: 1_000_000,
  heartRateBpm: { min: 20, max: 250 },
} as const;

const record = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === 'object' && !Array.isArray(value);
const integerIn = (value: unknown, min: number, max: number): value is number =>
  Number.isSafeInteger(value) && (value as number) >= min && (value as number) <= max;
const numberIn = (value: unknown, min: number, max: number): value is number =>
  typeof value === 'number' && Number.isFinite(value) && value >= min && value <= max;
/** Seconds and meters keep a tenth, like the TCX the recorder writes. */
const tenth = (value: number) => Math.round(value * 10) / 10;

const LAP_KEYS = [
  'step', 'kind', 'round', 'rounds', 'planned_duration_s', 'planned_distance_m', 'target',
  'start_s', 'moving_s', 'distance_m', 'avg_hr', 'max_hr', 'end',
] as const;

function parseTarget(value: unknown): RunStepTarget | null | undefined {
  if (value === null || value === undefined) return null;
  if (!record(value)) return undefined;
  if (value.type === 'pace') {
    const { min, max } = RUN_STEP_LIMITS.paceSecondsPerKm;
    if (Object.keys(value).length !== 3 || !integerIn(value.fastest_s_per_km, min, max)
        || !integerIn(value.slowest_s_per_km, min, max) || value.fastest_s_per_km > value.slowest_s_per_km) {
      return undefined;
    }
    return { type: 'pace', fastest_s_per_km: value.fastest_s_per_km, slowest_s_per_km: value.slowest_s_per_km };
  }
  if (value.type === 'heart_rate') {
    const { min, max } = RUN_STEP_LIMITS.heartRateBpm;
    if (Object.keys(value).length !== 3 || !integerIn(value.min_bpm, min, max)
        || !integerIn(value.max_bpm, min, max) || value.min_bpm > value.max_bpm) {
      return undefined;
    }
    return { type: 'heart_rate', min_bpm: value.min_bpm, max_bpm: value.max_bpm };
  }
  return undefined;
}

const nullable = <T>(value: unknown, check: (v: unknown) => v is T): T | null | undefined =>
  value === null || value === undefined ? null : check(value) ? value : undefined;

function parseLap(value: unknown): RunLap | undefined {
  if (!record(value) || !Object.keys(value).every((key) => (LAP_KEYS as readonly string[]).includes(key))) {
    return undefined;
  }
  const limits = RUN_STEP_LIMITS;
  const hr = RUN_LAP_LIMITS.heartRateBpm;
  const step = nullable(value.step, (v): v is number => integerIn(v, 1, limits.expandedSteps));
  const kind = nullable(value.kind, (v): v is RunStepKind => RUN_STEP_KINDS.includes(v as RunStepKind));
  const round = nullable(value.round, (v): v is number => integerIn(v, 1, limits.repeat));
  const rounds = nullable(value.rounds, (v): v is number => integerIn(v, 1, limits.repeat));
  const plannedDuration = nullable(value.planned_duration_s,
    (v): v is number => integerIn(v, 1, limits.durationSeconds));
  const plannedDistance = nullable(value.planned_distance_m,
    (v): v is number => numberIn(v, 0, limits.distanceMeters) && v > 0);
  const target = parseTarget(value.target);
  const avgHr = nullable(value.avg_hr, (v): v is number => integerIn(v, hr.min, hr.max));
  const maxHr = nullable(value.max_hr, (v): v is number => integerIn(v, hr.min, hr.max));
  const end = RUN_LAP_ENDS.includes(value.end as RunLapEnd) ? value.end as RunLapEnd : undefined;
  if (step === undefined || kind === undefined || round === undefined || rounds === undefined
      || plannedDuration === undefined || plannedDistance === undefined || target === undefined
      || avgHr === undefined || maxHr === undefined || end === undefined
      || !numberIn(value.start_s, 0, RUN_LAP_LIMITS.seconds)
      || !numberIn(value.moving_s, 0, RUN_LAP_LIMITS.seconds)
      || !numberIn(value.distance_m, 0, RUN_LAP_LIMITS.meters)) {
    return undefined;
  }
  // A lap ran a step, with its kind, or is the stretch after the plan, with
  // neither and nothing planned.
  if ((step === null) !== (kind === null)) return undefined;
  if (step === null && (round !== null || rounds !== null || plannedDuration !== null
      || plannedDistance !== null || target !== null || end !== 'stopped')) return undefined;
  if (step !== null && (plannedDuration === null) === (plannedDistance === null)) return undefined;
  if ((round === null) !== (rounds === null) || (round !== null && round > rounds!)) return undefined;
  if (avgHr !== null && maxHr !== null && avgHr > maxHr) return undefined;
  return {
    step, kind, round, rounds,
    planned_duration_s: plannedDuration,
    planned_distance_m: plannedDistance === null ? null : tenth(plannedDistance),
    target,
    start_s: tenth(value.start_s),
    moving_s: tenth(value.moving_s),
    distance_m: tenth(value.distance_m),
    avg_hr: avgHr,
    max_hr: maxHr,
    end,
  };
}

/** Laps from the recorder's `laps` field (JSON text) or from storage.
 * Null when they aren't well formed: steps in order, laps one after
 * another, and only the last lap after the plan. */
export function parseRunLaps(raw: unknown): RunLap[] | null {
  let value = raw;
  if (typeof raw === 'string') {
    try { value = JSON.parse(raw); } catch { return null; }
  }
  if (!Array.isArray(value) || value.length === 0 || value.length > RUN_LAP_LIMITS.laps) return null;
  const laps: RunLap[] = [];
  for (const item of value) {
    const lap = parseLap(item);
    if (!lap) return null;
    const previous = laps[laps.length - 1];
    if (previous) {
      if (previous.step === null) return null;
      if (lap.step !== null && lap.step <= previous.step) return null;
      // Rounding to a tenth can't move a lap's start before the last one's.
      if (lap.start_s < previous.start_s) return null;
    }
    laps.push(lap);
  }
  return laps;
}

/** Canonical stored text for well-formed laps. */
export function serializeRunLaps(laps: RunLap[]): string {
  return JSON.stringify(laps.map((lap) => Object.fromEntries(LAP_KEYS.map((key) => [key, lap[key]]))));
}
