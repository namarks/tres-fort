/**
 * Planning a run's steps on the web, as the app's run planner does
 * (ios/TresFort/RunRecorder/RunPlanEditing.swift): each part of the plan is
 * one step or a repeat group; a step ends after a time or a distance and can
 * carry a pace or heart rate range. The Worker's parser (src/runSteps.ts) has
 * the final word on what is stored.
 */
import {
  parseRunSteps,
  RUN_STEP_LIMITS,
  type RunPlanItem,
  type RunStep,
  type RunStepKind,
  type RunStepTarget,
} from '../../src/runSteps';
import { formatClock } from './model';

export type DistanceUnit = 'm' | 'km' | 'mi';
export const DISTANCE_UNITS: DistanceUnit[] = ['m', 'km', 'mi'];
const UNIT_METERS: Record<DistanceUnit, number> = { m: 1, km: 1000, mi: 1609.344 };

export const STEP_KINDS: { kind: RunStepKind; label: string }[] = [
  { kind: 'warmup', label: 'Warm-up' },
  { kind: 'work', label: 'Work' },
  { kind: 'recovery', label: 'Recovery' },
  { kind: 'cooldown', label: 'Cool-down' },
];

export type TargetChoice = 'none' | 'pace' | 'heart_rate';

/** One step as the member types it. */
export interface StepDraft {
  id: string;
  kind: RunStepKind;
  ends: 'time' | 'distance';
  /** "10:00", "1:05:00", or whole minutes such as "10". */
  time: string;
  distance: string;
  unit: DistanceUnit;
  target: TargetChoice;
  /** Paces as "m:ss" per mile or kilometer. */
  fastest: string;
  slowest: string;
  low: string;
  high: string;
  /**
   * What was stored, kept exactly while its text is unchanged: the text shows
   * rounded values, and re-reading them must not move a saved plan.
   */
  stored?: {
    meters?: { value: number; text: string; unit: DistanceUnit };
    pace?: { fastest: number; slowest: number; fastestText: string; slowestText: string };
  };
}

/** One step (repeats null) or a repeat group. */
export interface ItemDraft {
  id: string;
  repeats: string | null;
  steps: StepDraft[];
}

const newId = () => crypto.randomUUID();

/** "4:05" for a stored pace, per mile or kilometer. */
export function paceText(secondsPerKm: number, miles: boolean): string {
  const perUnit = Math.round(secondsPerKm * (miles ? UNIT_METERS.mi : 1000) / 1000);
  return `${Math.floor(perUnit / 60)}:${String(perUnit % 60).padStart(2, '0')}`;
}

/** Seconds from "m:ss", or null. */
export function parsePace(text: string): number | null {
  const match = /^(\d{1,2}):([0-5]\d)$/.exec(text.trim());
  return match ? Number(match[1]) * 60 + Number(match[2]) : null;
}

/** Seconds from "m:ss", "h:mm:ss" or whole minutes, or null. */
export function parseDuration(text: string): number | null {
  const trimmed = text.trim();
  if (/^\d{1,3}$/.test(trimmed)) return Number(trimmed) * 60;
  const short = /^(\d{1,3}):([0-5]\d)$/.exec(trimmed);
  if (short) return Number(short[1]) * 60 + Number(short[2]);
  const long = /^(\d{1,2}):([0-5]\d):([0-5]\d)$/.exec(trimmed);
  if (long) return Number(long[1]) * 3600 + Number(long[2]) * 60 + Number(long[3]);
  return null;
}

/** The unit a stored distance reads best in, and its text, as the app shows it. */
export function distanceDisplay(meters: number, miles: boolean): { unit: DistanceUnit; text: string } {
  if (meters < 1000) return { unit: 'm', text: String(Math.round(meters)) };
  const unit: DistanceUnit = miles ? 'mi' : 'km';
  return { unit, text: String(Math.round((meters / UNIT_METERS[unit]) * 100) / 100) };
}

function stepDraft(step: RunStep, miles: boolean): StepDraft {
  const draft = blankStep(step.kind, miles);
  if (step.distance_m !== undefined) {
    const shown = distanceDisplay(step.distance_m, miles);
    draft.ends = 'distance';
    draft.distance = shown.text;
    draft.unit = shown.unit;
    draft.stored = { meters: { value: step.distance_m, ...shown } };
  } else {
    draft.time = formatClock(step.duration_s ?? 600);
  }
  if (step.target?.type === 'pace') {
    draft.target = 'pace';
    draft.fastest = paceText(step.target.fastest_s_per_km, miles);
    draft.slowest = paceText(step.target.slowest_s_per_km, miles);
    draft.stored = {
      ...draft.stored,
      pace: {
        fastest: step.target.fastest_s_per_km, slowest: step.target.slowest_s_per_km,
        fastestText: draft.fastest, slowestText: draft.slowest,
      },
    };
  } else if (step.target?.type === 'heart_rate') {
    draft.target = 'heart_rate';
    draft.low = String(step.target.min_bpm);
    draft.high = String(step.target.max_bpm);
  }
  return draft;
}

function blankStep(kind: RunStepKind, miles: boolean): StepDraft {
  return {
    id: newId(), kind, ends: 'time', time: '10:00', distance: '1', unit: miles ? 'mi' : 'km',
    target: 'none', fastest: '', slowest: '', low: '130', high: '145',
  };
}

/** A new step: ten minutes of work, as the app adds one. */
export function newStep(miles: boolean, kind: RunStepKind = 'work', time = '10:00'): StepDraft {
  return { ...blankStep(kind, miles), time };
}

/** "4 × (work 3:00, recovery 1:30)", the usual interval shape. */
export function newRepeat(miles: boolean): ItemDraft {
  return { id: newId(), repeats: '4', steps: [newStep(miles, 'work', '3:00'), newStep(miles, 'recovery', '1:30')] };
}

/**
 * The editor's starting point for a run slot: its steps, none, or null when
 * the stored steps can't be read (a newer format), so only removing them is
 * offered rather than losing them in an edit.
 */
export function draftFromRunSteps(raw: string | null | undefined, miles: boolean): ItemDraft[] | null {
  if (raw == null) return [];
  const parsed = parseRunSteps(raw);
  if (!parsed.ok) return null;
  return parsed.items.map((item) =>
    'repeat' in item
      ? { id: newId(), repeats: String(item.repeat), steps: item.steps.map((step) => stepDraft(step, miles)) }
      : { id: newId(), repeats: null, steps: [stepDraft(item, miles)] });
}

function stepMeters(step: StepDraft): number | null {
  const stored = step.stored?.meters;
  if (stored && step.distance === stored.text && step.unit === stored.unit) return stored.value;
  const trimmed = step.distance.trim().replace(',', '.');
  if (!/^(\d+\.?\d*|\.\d+)$/.test(trimmed)) return null;
  const value = Number(trimmed) * UNIT_METERS[step.unit];
  return value > 0 ? value : null;
}

function paceRange(step: StepDraft, miles: boolean): { fastest: number; slowest: number } | null {
  const stored = step.stored?.pace;
  if (stored && step.fastest.trim() === stored.fastestText && step.slowest.trim() === stored.slowestText) {
    return { fastest: stored.fastest, slowest: stored.slowest };
  }
  const fastest = parsePace(step.fastest);
  const slowest = parsePace(step.slowest);
  if (fastest === null || slowest === null) return null;
  const perKm = (seconds: number) => Math.round(seconds * 1000 / (miles ? UNIT_METERS.mi : 1000));
  return { fastest: perKm(fastest), slowest: perKm(slowest) };
}

const wholeIn = (text: string, min: number, max: number): number | null => {
  const trimmed = text.trim();
  if (!/^\d+$/.test(trimmed)) return null;
  const value = Number(trimmed);
  return value >= min && value <= max ? value : null;
};

/** The stored step, or why it can't be saved, in the app's words. */
export function stepFromDraft(draft: StepDraft, miles: boolean): { ok: true; step: RunStep } | { ok: false; error: string } {
  let ending: Pick<RunStep, 'duration_s' | 'distance_m'>;
  if (draft.ends === 'time') {
    const seconds = parseDuration(draft.time);
    if (seconds === null || seconds < 1) return { ok: false, error: 'Enter a time, such as 10:00 or 1:05:00.' };
    if (seconds > RUN_STEP_LIMITS.durationSeconds) return { ok: false, error: 'A step can be at most 6 hours.' };
    ending = { duration_s: seconds };
  } else {
    const meters = stepMeters(draft);
    if (meters === null) return { ok: false, error: 'Enter a distance, such as 800 m or 1.5 km.' };
    if (meters > RUN_STEP_LIMITS.distanceMeters) return { ok: false, error: 'A step can be at most 100 km.' };
    ending = { distance_m: meters };
  }
  let target: RunStepTarget | undefined;
  if (draft.target === 'pace') {
    const range = paceRange(draft, miles);
    if (!range) return { ok: false, error: 'Enter paces as minutes and seconds, such as 4:05.' };
    const { min, max } = RUN_STEP_LIMITS.paceSecondsPerKm;
    if ([range.fastest, range.slowest].some((pace) => pace < min || pace > max)) {
      return { ok: false, error: 'Pace must be between 2:00 and 20:00 per kilometer.' };
    }
    if (range.fastest > range.slowest) {
      return { ok: false, error: 'The fast end of the pace range must be quicker than the slow end.' };
    }
    target = { type: 'pace', fastest_s_per_km: range.fastest, slowest_s_per_km: range.slowest };
  } else if (draft.target === 'heart_rate') {
    const { min, max } = RUN_STEP_LIMITS.heartRateBpm;
    const low = wholeIn(draft.low, min, max);
    const high = wholeIn(draft.high, min, max);
    if (low === null || high === null) return { ok: false, error: 'Heart rate must be between 40 and 230 bpm.' };
    if (low > high) return { ok: false, error: 'The low end of the heart rate range must be below the high end.' };
    target = { type: 'heart_rate', min_bpm: low, max_bpm: high };
  }
  return { ok: true, step: { kind: draft.kind, ...ending, ...(target ? { target } : {}) } };
}

export type RunPlanResult =
  | { ok: true; items: RunPlanItem[] | null }
  | { ok: false; errors: string[] };

/**
 * The steps to save (null when there are none, which keeps the run without
 * steps), or every reason they can't be saved yet.
 */
export function runStepsFromDraft(items: readonly ItemDraft[], miles: boolean): RunPlanResult {
  const errors: string[] = [];
  const plan: RunPlanItem[] = [];
  if (items.length > RUN_STEP_LIMITS.items) errors.push('A plan can have at most 50 parts.');
  items.forEach((item, index) => {
    const steps = item.steps.map((step) => stepFromDraft(step, miles));
    steps.forEach((result, stepIndex) => {
      if (!result.ok) errors.push(`${partName(items, index, item.repeats === null ? null : stepIndex)}: ${result.error}`);
    });
    const valid = steps.flatMap((result) => (result.ok ? [result.step] : []));
    if (item.repeats === null) {
      if (valid[0]) plan.push(valid[0]);
      return;
    }
    const repeats = wholeIn(item.repeats, 1, RUN_STEP_LIMITS.repeat);
    if (repeats === null) errors.push(`${partName(items, index, null)}: a repeat runs 1 to 50 times.`);
    if (item.steps.length === 0) errors.push(`${partName(items, index, null)} needs at least one step.`);
    if (item.steps.length > RUN_STEP_LIMITS.repeatSteps) errors.push('A repeat can hold at most 10 steps.');
    if (repeats !== null && valid.length) plan.push({ repeat: repeats, steps: valid });
  });
  if (errors.length) return { ok: false, errors };
  if (plan.length === 0) return { ok: true, items: null };
  const expanded = plan.reduce((total, item) => total + ('repeat' in item ? item.repeat * item.steps.length : 1), 0);
  if (expanded > RUN_STEP_LIMITS.expandedSteps) return { ok: false, errors: ['With repeats, a plan can have at most 200 steps.'] };
  const checked = parseRunSteps(plan);
  if (!checked.ok) return { ok: false, errors: ['These steps can’t be saved. Check each step and try again.'] };
  return { ok: true, items: checked.items };
}

/** "Step 2" or "Repeat 3" (a part of the plan), or "Repeat 3, step 1". */
export function partName(items: readonly ItemDraft[], index: number, stepIndex: number | null): string {
  const item = items[index]!;
  if (item.repeats === null) return `Step ${index + 1}`;
  return stepIndex === null ? `Repeat ${index + 1}` : `Repeat ${index + 1}, step ${stepIndex + 1}`;
}

/** Whether saving these steps would change what is stored. */
export function sameRunSteps(raw: string | null | undefined, items: RunPlanItem[] | null): boolean {
  if (raw == null || items === null) return (raw ?? null) === null && items === null;
  const stored = parseRunSteps(raw);
  return stored.ok && JSON.stringify(stored.items) === JSON.stringify(items);
}

/** The list with one entry moved a place up (-1) or down (+1); unchanged at either end. */
export function moved<T extends { id: string }>(list: readonly T[], id: string, direction: -1 | 1): T[] {
  const index = list.findIndex((entry) => entry.id === id);
  const target = index + direction;
  if (index < 0 || target < 0 || target >= list.length) return [...list];
  const next = [...list];
  [next[index], next[target]] = [next[target]!, next[index]!];
  return next;
}
