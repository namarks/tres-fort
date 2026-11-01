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
import type { StatePlan, StateResponse } from './api';

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

/** "3 × 5–8 @ 225 lb · RPE 8 · rest 2:00" */
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
  if (slot.rest_seconds > 0) parts.push(`rest ${formatClock(slot.rest_seconds)}`);
  return parts.join(' · ');
}

function trimNumber(value: number): string {
  return Number.isInteger(value) ? String(value) : value.toFixed(1).replace(/\.0$/, '');
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

function describeTarget(target: RunStepTarget, miles: boolean): string {
  if (target.type === 'heart_rate') return `${target.min_bpm}–${target.max_bpm} bpm`;
  const scale = miles ? METERS_PER_MILE / 1000 : 1;
  const fast = formatClock(Math.round(target.fastest_s_per_km * scale));
  const slow = formatClock(Math.round(target.slowest_s_per_km * scale));
  return `${fast}–${slow} /${miles ? 'mi' : 'km'}`;
}

function describeStep(step: RunStep, miles: boolean): string {
  const kind = { warmup: 'Warm up', work: 'Run', recovery: 'Recover', cooldown: 'Cool down' }[step.kind];
  let amount = '';
  if (step.duration_s !== undefined) amount = formatClock(step.duration_s);
  else if (step.distance_m !== undefined) {
    amount = miles
      ? `${trimNumber(Math.round((step.distance_m / METERS_PER_MILE) * 100) / 100)} mi`
      : step.distance_m >= 1000
        ? `${trimNumber(Math.round(step.distance_m / 10) / 100)} km`
        : `${step.distance_m} m`;
  }
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
