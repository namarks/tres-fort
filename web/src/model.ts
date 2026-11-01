/**
 * Pure helpers that turn GET /api/state into what the screens show. The
 * calendar itself is the Worker's own projection (src/calendarProjection.ts),
 * imported here so the web runs the same rules as the API and the app.
 */
import {
  addDays,
  projectCalendarWindow,
  weekdayOf,
  type CalendarCell,
  type CalendarInputs,
} from '../../src/calendarProjection';
import { coachGroupSlots } from '../../src/exerciseGroupViews';
import { parseRunSteps, type RunPlanItem, type RunStep, type RunStepTarget } from '../../src/runSteps';
import { WEEKDAYS, type EnrichedTemplateExercise, type Trip, type Weekday } from '../../src/types';
import type { StateActivity, StatePlan, StateResponse } from './api';

export type { CalendarCell };
export type Workout = StatePlan['workouts'][number];
export type Slot = EnrichedTemplateExercise & { group_label?: string };

/** The browser's own civil date: the client owns the "today" boundary. */
export function localToday(now: Date = new Date()): string {
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
}

export function monthOf(date: string): string {
  return date.slice(0, 7);
}

export function shiftMonth(month: string, delta: number): string {
  const [year, mon] = month.split('-').map(Number) as [number, number];
  const index = year * 12 + (mon - 1) + delta;
  return `${String(Math.floor(index / 12)).padStart(4, '0')}-${String((index % 12) + 1).padStart(2, '0')}`;
}

/** Monday-first weeks covering the whole month. */
export function monthWeeks(month: string): string[][] {
  const first = `${month}-01`;
  const last = addDays(`${shiftMonth(month, 1)}-01`, -1);
  const weeks: string[][] = [];
  for (let start = addDays(first, -WEEKDAYS.indexOf(weekdayOf(first))); start <= last; start = addDays(start, 7)) {
    weeks.push(Array.from({ length: 7 }, (_, i) => addDays(start, i)));
  }
  return weeks;
}

export function calendarInputs(state: StateResponse): CalendarInputs | null {
  const plan = state.plan;
  if (!plan) return null;
  return {
    plan: { id: plan.id },
    schedule: plan.schedule,
    trips: plan.trips ?? [],
    liveDayIds: plan.workouts.filter((w) => !w.archived_at).map((w) => w.id),
    plannedEvents: state.external_events.filter((e) => e.deleted_at === null),
    completedActivities: state.external_activities.filter((a) => a.deleted_at === null),
    sessions: state.sessions,
  };
}

/** One projected cell per date in [from, to]; past dates without history have none. */
export function projectRange(
  inputs: CalendarInputs,
  from: string,
  to: string,
  today: string,
): Map<string, CalendarCell> {
  return new Map(projectCalendarWindow(inputs, from, to, today).map((cell) => [cell.date, cell]));
}

export interface ShownLoad {
  load: number;
  /** How the load was worked out (`load_method`), or null for a planned event. */
  method: string | null;
}

/**
 * The load a completed activity shows: `effective_load` and its
 * `load_method`, never the provider's raw `training_load` alone (AGENTS.md).
 * An API Worker without migration 0060 sends no effective load; its provider
 * load is then shown as such. Missing data stays unknown.
 */
export function activityLoad(activity: StateActivity): ShownLoad | null {
  if (activity.effective_load !== undefined) {
    return activity.effective_load === null ? null : { load: activity.effective_load, method: activity.load_method ?? null };
  }
  return activity.training_load === null ? null : { load: activity.training_load, method: 'provider' };
}

/** Shown loads of completed activities by id, for the day panel. */
export function activityLoads(state: StateResponse): Map<string, ShownLoad | null> {
  return new Map(state.external_activities.map((a) => [a.id, activityLoad(a)]));
}

/** A calendar item's load: a completed activity's shown load, or a planned event's own. */
export function itemLoad(item: CalendarCell['items'][number], loads: Map<string, ShownLoad | null>): ShownLoad | null {
  if (item.completed) return loads.get(item.id) ?? null;
  return item.training_load === null ? null : { load: item.training_load, method: null };
}

export const LOAD_METHOD_LABELS: Record<string, string> = {
  provider: 'from the provider',
  power: 'from power',
  power_summary: 'from average power',
  heart_rate: 'from heart rate',
  heart_rate_average: 'from average heart rate',
  pace: 'from pace',
};

export function tripOn(date: string, trips: Trip[]): Trip | null {
  return trips.find((trip) => trip.start <= date && date <= trip.end) ?? null;
}

export const WEEKDAY_LABELS: Record<Weekday, string> = {
  mon: 'Monday', tue: 'Tuesday', wed: 'Wednesday', thu: 'Thursday',
  fri: 'Friday', sat: 'Saturday', sun: 'Sunday',
};

export function formatLongDate(date: string): string {
  const [y, m, d] = date.split('-').map(Number) as [number, number, number];
  return new Date(y, m - 1, d).toLocaleDateString(undefined, {
    weekday: 'long', month: 'long', day: 'numeric', year: 'numeric',
  });
}

export function formatMonth(month: string): string {
  const [y, m] = month.split('-').map(Number) as [number, number];
  return new Date(y, m - 1, 1).toLocaleDateString(undefined, { month: 'long', year: 'numeric' });
}

export function formatClock(totalSeconds: number): string {
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = Math.round(totalSeconds % 60);
  const mm = hours ? String(minutes).padStart(2, '0') : String(minutes);
  return `${hours ? `${hours}:` : ''}${mm}:${String(seconds).padStart(2, '0')}`;
}

export const STATUS_LABELS: Record<CalendarCell['status'], string> = {
  projected: 'Planned (weekly routine)',
  planned: 'Planned',
  in_progress: 'In progress',
  completed: 'Done',
  skipped: 'Skipped',
  rest: 'Rest',
  unavailable: 'Away',
  light: 'Away, light training',
};

/** Exercise slots in order, with A1/A2 labels for supersets and circuits. */
export function orderedSlots(workout: Workout): Slot[] {
  const slots = [...workout.exercises].sort((a, b) => a.order_index - b.order_index);
  return coachGroupSlots(slots) as Slot[];
}

export interface SlotBlock {
  /** A superset or circuit; null for a single exercise. */
  group: { title: string; rounds: number; roundRest: number; transitionRest: number } | null;
  members: Slot[];
}

/**
 * Slots in order, with each superset or circuit gathered into one block, as
 * the app's ExerciseGroupBlock shows them. A group's rests are the ones the
 * runner uses: transition rest between exercises, round rest after the last.
 */
export function slotBlocks(workout: Workout): SlotBlock[] {
  const blocks: SlotBlock[] = [];
  for (const slot of orderedSlots(workout)) {
    const last = blocks[blocks.length - 1];
    if (slot.group_id && last?.group && last.members[0]!.group_id === slot.group_id) {
      last.members.push(slot);
      last.group.title = `${last.members.length === 2 ? 'Superset' : 'Circuit'} ${(slot.group_label ?? '').replace(/\d+$/, '')}`;
      continue;
    }
    blocks.push({
      group: slot.group_id
        ? {
            title: `Superset ${(slot.group_label ?? '').replace(/\d+$/, '')}`,
            rounds: slot.target_sets,
            roundRest: slot.group_rest_seconds ?? slot.rest_seconds,
            transitionRest: slot.group_transition_seconds ?? 0,
          }
        : null,
      members: [slot],
    });
  }
  return blocks;
}

/** "4 rounds · round rest 1:30 · 0:15 between exercises" */
export function describeGroup(group: NonNullable<SlotBlock['group']>): string {
  const parts = [`${group.rounds} ${group.rounds === 1 ? 'round' : 'rounds'}`, `round rest ${formatClock(group.roundRest)}`];
  if (group.transitionRest > 0) parts.push(`${formatClock(group.transitionRest)} between exercises`);
  return parts.join(' · ');
}

/**
 * "3 × 5–8 @ 225 lb · RPE 8 · rest 2:00". A grouped slot's own rest is kept
 * only for ungrouping, so it is not shown; its group's rests are.
 */
export function describeSlot(slot: Slot): string {
  const parts: string[] = [];
  const sets = `${slot.target_sets} ×`;
  if (slot.target_duration_s) {
    parts.push(`${sets} ${formatClock(slot.target_duration_s)}`);
  } else {
    const reps = slot.target_reps_max && slot.target_reps_max > slot.target_reps
      ? `${slot.target_reps}–${slot.target_reps_max}`
      : `${slot.target_reps}`;
    const each = slot.exercise_laterality === 'unilateral' ? ' each side' : '';
    parts.push(`${sets} ${reps}${each}`);
  }
  if (slot.target_weight !== null && slot.target_weight !== undefined) {
    const hand = slot.exercise_load_mode === 'per_hand' ? ' each hand' : '';
    parts[0] += ` @ ${trimNumber(slot.target_weight)} ${slot.target_weight_unit ?? 'lb'}${hand}`;
  }
  if (slot.target_rpe !== null) parts.push(`RPE ${trimNumber(slot.target_rpe)}`);
  if (slot.rest_seconds > 0 && !slot.group_id) parts.push(`rest ${formatClock(slot.rest_seconds)}`);
  return parts.join(' · ');
}

/** Up to two decimals without trailing zeros: "225", "22.5", "1.25". */
function trimNumber(value: number): string {
  return String(Math.round(value * 100) / 100);
}

/** Whether to show distances and paces in miles (US, UK, Liberia, Myanmar). */
export function prefersMiles(locale: string = typeof navigator === 'undefined' ? 'en-US' : navigator.language): boolean {
  try {
    const region = new Intl.Locale(locale).maximize().region;
    return region === 'US' || region === 'GB' || region === 'LR' || region === 'MM';
  } catch {
    return false;
  }
}

const METERS_PER_MILE = 1609.344;

function range(low: string, high: string): string {
  return low === high ? low : `${low}–${high}`;
}

function describeTarget(target: RunStepTarget, miles: boolean): string {
  if (target.type === 'heart_rate') return `${range(String(target.min_bpm), String(target.max_bpm))} bpm`;
  const scale = miles ? METERS_PER_MILE / 1000 : 1;
  const fast = formatClock(Math.round(target.fastest_s_per_km * scale));
  const slow = formatClock(Math.round(target.slowest_s_per_km * scale));
  return `${range(fast, slow)} /${miles ? 'mi' : 'km'}`;
}

/**
 * As the app's RunPlan reads them: under a kilometer in meters, as track
 * intervals are planned; otherwise up to two decimals of a mile or km.
 */
export function describeDistance(meters: number, miles: boolean): string {
  if (meters < 1000) return `${Math.round(meters)} m`;
  return `${trimNumber(meters / (miles ? METERS_PER_MILE : 1000))} ${miles ? 'mi' : 'km'}`;
}

function describeStep(step: RunStep, miles: boolean): string {
  const kind = { warmup: 'Warm up', work: 'Run', recovery: 'Recover', cooldown: 'Cool down' }[step.kind];
  let amount = '';
  if (step.duration_s !== undefined) amount = formatClock(step.duration_s);
  else if (step.distance_m !== undefined) amount = describeDistance(step.distance_m, miles);
  const target = step.target ? ` at ${describeTarget(step.target, miles)}` : '';
  return `${kind}${amount ? ` ${amount}` : ''}${target}`;
}

/** One line per planned run step; repeats read "4 × (Run 800 m, Recover 2:00)". */
export function describeRunSteps(raw: string | null | undefined, miles: boolean): string[] {
  if (!raw) return [];
  let decoded: unknown;
  try {
    decoded = JSON.parse(raw);
  } catch {
    return [];
  }
  const parsed = parseRunSteps(decoded);
  if (!parsed.ok) return [];
  return parsed.items.map((item: RunPlanItem) =>
    'repeat' in item
      ? `${item.repeat} × (${item.steps.map((step) => describeStep(step, miles)).join(', ')})`
      : describeStep(item, miles));
}

export const ENDURANCE_LABELS: Record<string, string> = {
  ride: 'Ride', run: 'Run', swim: 'Swim', walk: 'Walk', other: 'Activity',
};
