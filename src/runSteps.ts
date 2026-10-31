/**
 * Planned run steps (docs/plans/planned-runs). A run slot of a plan workout
 * can carry ordered steps, each ending after a duration or a distance, with
 * an optional pace or heart rate range. Repeat groups cover intervals.
 *
 * Stored as canonical JSON text in `template_exercises.run_steps`
 * (migration 0058), so it travels with the versioned plan document, its
 * snapshots and `/api/state` exactly like `progression`.
 */

/** The outdoor run catalog exercise; the only slot that may carry steps. */
export const RUN_EXERCISE_ID = 'ex_outdoor_run';

export const RUN_STEP_KINDS = ['warmup', 'work', 'recovery', 'cooldown'] as const;
export type RunStepKind = typeof RUN_STEP_KINDS[number];

export type RunStepTarget =
  | { type: 'pace'; fastest_s_per_km: number; slowest_s_per_km: number }
  | { type: 'heart_rate'; min_bpm: number; max_bpm: number };

export interface RunStep {
  kind: RunStepKind;
  duration_s?: number;
  distance_m?: number;
  target?: RunStepTarget;
}

export interface RunRepeat {
  repeat: number;
  steps: RunStep[];
}

export type RunPlanItem = RunStep | RunRepeat;

export const RUN_STEP_LIMITS = {
  items: 50,
  repeatSteps: 10,
  repeat: 50,
  expandedSteps: 200,
  durationSeconds: 6 * 60 * 60,
  distanceMeters: 100_000,
  paceSecondsPerKm: { min: 120, max: 1200 },
  heartRateBpm: { min: 40, max: 230 },
} as const;

const record = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === 'object' && !Array.isArray(value);
const onlyKeys = (value: Record<string, unknown>, keys: readonly string[]) =>
  Object.keys(value).every((key) => keys.includes(key));
const integerIn = (value: unknown, min: number, max: number) =>
  Number.isSafeInteger(value) && (value as number) >= min && (value as number) <= max;

export type RunStepsParse =
  | { ok: true; items: RunPlanItem[] }
  | { ok: false; fields: string[] };

function parseTarget(value: unknown, path: string, bad: string[]): RunStepTarget | undefined {
  if (!record(value)) { bad.push(path); return undefined; }
  if (value.type === 'pace') {
    const { min, max } = RUN_STEP_LIMITS.paceSecondsPerKm;
    if (!onlyKeys(value, ['type', 'fastest_s_per_km', 'slowest_s_per_km'])
        || !integerIn(value.fastest_s_per_km, min, max) || !integerIn(value.slowest_s_per_km, min, max)
        || (value.fastest_s_per_km as number) > (value.slowest_s_per_km as number)) {
      bad.push(path);
      return undefined;
    }
    return { type: 'pace', fastest_s_per_km: value.fastest_s_per_km as number,
      slowest_s_per_km: value.slowest_s_per_km as number };
  }
  if (value.type === 'heart_rate') {
    const { min, max } = RUN_STEP_LIMITS.heartRateBpm;
    if (!onlyKeys(value, ['type', 'min_bpm', 'max_bpm'])
        || !integerIn(value.min_bpm, min, max) || !integerIn(value.max_bpm, min, max)
        || (value.min_bpm as number) > (value.max_bpm as number)) {
      bad.push(path);
      return undefined;
    }
    return { type: 'heart_rate', min_bpm: value.min_bpm as number, max_bpm: value.max_bpm as number };
  }
  bad.push(path);
  return undefined;
}

function parseStep(value: unknown, path: string, bad: string[]): RunStep | undefined {
  if (!record(value) || !onlyKeys(value, ['kind', 'duration_s', 'distance_m', 'target'])) {
    bad.push(path);
    return undefined;
  }
  const before = bad.length;
  if (!RUN_STEP_KINDS.includes(value.kind as RunStepKind)) bad.push(`${path}.kind`);
  const hasDuration = value.duration_s !== undefined;
  const hasDistance = value.distance_m !== undefined;
  // Each step ends after exactly one of a duration or a distance.
  if (hasDuration === hasDistance) bad.push(`${path}.${hasDuration ? 'distance_m' : 'duration_s'}`);
  if (hasDuration && !integerIn(value.duration_s, 1, RUN_STEP_LIMITS.durationSeconds)) bad.push(`${path}.duration_s`);
  if (hasDistance && (typeof value.distance_m !== 'number' || !Number.isFinite(value.distance_m)
      || value.distance_m <= 0 || value.distance_m > RUN_STEP_LIMITS.distanceMeters)) bad.push(`${path}.distance_m`);
  const target = value.target === undefined ? undefined : parseTarget(value.target, `${path}.target`, bad);
  if (bad.length !== before) return undefined;
  // Canonical key order keeps stored text and snapshot comparisons stable.
  return {
    kind: value.kind as RunStepKind,
    ...(hasDuration ? { duration_s: value.duration_s as number } : { distance_m: value.distance_m as number }),
    ...(target ? { target } : {}),
  };
}

/** Validate run steps from a caller (an array) or from storage (its JSON
 * text). Field paths are relative to `run_steps`, e.g. `run_steps.1.steps.0.target`. */
export function parseRunSteps(raw: unknown): RunStepsParse {
  let value = raw;
  if (typeof raw === 'string') {
    try { value = JSON.parse(raw); } catch { return { ok: false, fields: ['run_steps'] }; }
  }
  if (!Array.isArray(value) || value.length === 0 || value.length > RUN_STEP_LIMITS.items) {
    return { ok: false, fields: ['run_steps'] };
  }
  const bad: string[] = [];
  const items: RunPlanItem[] = [];
  let expanded = 0;
  value.forEach((item, index) => {
    const path = `run_steps.${index}`;
    if (record(item) && 'repeat' in item) {
      if (!onlyKeys(item, ['repeat', 'steps'])) { bad.push(path); return; }
      if (!integerIn(item.repeat, 1, RUN_STEP_LIMITS.repeat)) bad.push(`${path}.repeat`);
      // Repeats hold plain steps only: one level of nesting.
      if (!Array.isArray(item.steps) || item.steps.length === 0
          || item.steps.length > RUN_STEP_LIMITS.repeatSteps) {
        bad.push(`${path}.steps`);
        return;
      }
      const steps = item.steps.map((step, stepIndex) => parseStep(step, `${path}.steps.${stepIndex}`, bad));
      if (steps.every((step): step is RunStep => step !== undefined) && Number.isSafeInteger(item.repeat)) {
        items.push({ repeat: item.repeat as number, steps });
        expanded += (item.repeat as number) * steps.length;
      }
      return;
    }
    const step = parseStep(item, path, bad);
    if (step) { items.push(step); expanded += 1; }
  });
  if (bad.length === 0 && expanded > RUN_STEP_LIMITS.expandedSteps) bad.push('run_steps');
  return bad.length ? { ok: false, fields: bad } : { ok: true, items };
}

/** Canonical stored text for valid steps; null clears them. */
export function serializeRunSteps(raw: unknown): string | null {
  if (raw === null) return null;
  const parsed = parseRunSteps(raw);
  if (!parsed.ok) throw new Error('invalid_run_steps');
  return JSON.stringify(parsed.items);
}
