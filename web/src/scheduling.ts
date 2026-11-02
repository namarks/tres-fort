/**
 * Pure rules for changing the weekly routine, single dates and away dates on
 * the web. They follow the app (SyncModel.calendarAssignmentUnavailableReason,
 * calendarMoveUnavailableReason and AwayDatesView.swift); the Worker checks
 * every write again.
 */
import { WEEKDAYS, type Trip, type Weekday } from '../../src/types';
import type { CalendarCell, Workout } from './model';
import type { StateResponse } from './api';

type Session = StateResponse['sessions'][number];
export type Week = Record<Weekday, string | null>;

/**
 * The whole week with one day changed. The Worker replaces the whole week on
 * every write, so a day left out would become rest.
 */
export function weekWith(week: Partial<Week>, day: Weekday, workoutId: string | null): Week {
  const full = Object.fromEntries(WEEKDAYS.map((d) => [d, week[d] ?? null])) as Week;
  return { ...full, [day]: workoutId };
}

/**
 * The sessions row a date assignment is checked against: the date's first
 * row, as the Worker reads it. Its attempt is the token a write sends; 0 means
 * no row was seen.
 */
export function dateSession(sessions: readonly Session[], date: string): Session | undefined {
  return sessions
    .filter((session) => session.date === date)
    .sort((a, b) => a.created_at - b.created_at || a.id.localeCompare(b.id))[0];
}

export const attemptOn = (sessions: readonly Session[], date: string): number => dateSession(sessions, date)?.attempt ?? 0;

/** Why this date can't take another workout or rest, or null when it can. */
export function dateChangeBlocked(date: string, today: string, cell: CalendarCell | undefined, sessions: readonly Session[]): string | null {
  if (date < today) return 'Past dates keep what happened.';
  const started = sessions.some((session) => session.date === date
    && (session.status === 'in_progress' || session.status === 'completed'));
  if (started) return 'A workout was started on this date, so it can’t be changed or moved.';
  if (cell?.status === 'unavailable') return 'You’re away with no training on this date. Change your away dates to plan it.';
  return null;
}

/** Why a workout can't move from one date to another, or null. */
export function moveBlocked(args: {
  from: string;
  to: string;
  today: string;
  fromCell: CalendarCell | undefined;
  toCell: CalendarCell | undefined;
  sessions: readonly Session[];
}): string | null {
  const { from, to, today, fromCell, toCell, sessions } = args;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(to)) return 'Choose a date.';
  if (from === to) return 'Choose a different date.';
  const fromProblem = dateChangeBlocked(from, today, fromCell, sessions);
  if (fromProblem) return fromProblem;
  if (to < today) return 'Choose today or a later date.';
  const toProblem = dateChangeBlocked(to, today, toCell, sessions);
  if (toProblem) return toProblem;
  if (hasWorkout(toCell)) return 'That date already has a workout. Choose an empty date.';
  return null;
}

/** A date shows a strength workout (planned, from the routine, or under light travel). */
export function hasWorkout(cell: CalendarCell | undefined): boolean {
  return !!cell?.workout_id && cell.status !== 'rest' && cell.status !== 'unavailable' && cell.status !== 'skipped';
}

/** Workouts that can go on a weekday or a date: not archived, in the plan's order. */
export function choosableWorkouts(workouts: readonly Workout[]): Workout[] {
  return workouts.filter((workout) => !workout.archived_at).sort((a, b) => a.order_index - b.order_index);
}

// ---- away dates --------------------------------------------------------------

export const AWAY_KINDS = [
  { type: 'travel', label: 'Travel' },
  { type: 'rest', label: 'Rest' },
  { type: 'injury', label: 'Injury' },
  { type: 'other', label: 'Other' },
] as const;

export interface AwayDraft {
  start: string;
  end: string;
  type: Trip['type'];
  canTrain: boolean;
  note: string;
}

export const NOTE_LIMIT = 500;

export function awayDraft(trip: Trip | null, today: string): AwayDraft {
  if (!trip) return { start: today, end: today, type: 'travel', canTrain: true, note: '' };
  return {
    start: trip.start, end: trip.end < trip.start ? trip.start : trip.end,
    type: trip.type ?? 'other', canTrain: trip.can_train_light ?? true, note: trip.note ?? '',
  };
}

/**
 * The request fields: all of them for new away dates, only what changed for
 * an edit, so a coach's change to another field isn't overwritten.
 */
export function awayFields(draft: AwayDraft, original: Trip | null): { ok: true; fields: Record<string, unknown> } | { ok: false; error: string } {
  const valid = (date: string) => /^\d{4}-\d{2}-\d{2}$/.test(date);
  if (!valid(draft.start) || !valid(draft.end)) return { ok: false, error: 'Choose a first and last day.' };
  if (draft.end < draft.start) return { ok: false, error: 'The last day can’t be before the first day.' };
  const note = draft.note.trim();
  if (note.length > NOTE_LIMIT) return { ok: false, error: `Keep the note under ${NOTE_LIMIT} characters.` };
  if (!original) {
    return {
      ok: true,
      fields: { start: draft.start, end: draft.end, type: draft.type, can_train_light: draft.canTrain, ...(note ? { note } : {}) },
    };
  }
  const fields: Record<string, unknown> = {};
  if (draft.start !== original.start) fields.start = draft.start;
  if (draft.end !== original.end) fields.end = draft.end;
  if (draft.type !== (original.type ?? 'other')) fields.type = draft.type;
  if (draft.canTrain !== (original.can_train_light ?? true)) fields.can_train_light = draft.canTrain;
  if (note !== (original.note ?? '')) fields.note = note;
  return { ok: true, fields };
}

/** Away dates that haven't ended, soonest first, then the past ones, latest first. */
export function splitTrips(trips: readonly Trip[], today: string): { upcoming: Trip[]; past: Trip[] } {
  const sorted = [...trips].sort((a, b) => a.start.localeCompare(b.start) || a.end.localeCompare(b.end));
  return {
    upcoming: sorted.filter((trip) => trip.end >= today),
    past: sorted.filter((trip) => trip.end < today).reverse(),
  };
}

export function awayKindLabel(trip: Trip): string {
  const kind = AWAY_KINDS.find((entry) => entry.type === trip.type)?.label ?? 'Other';
  return (trip.can_train_light ?? true) ? kind : `${kind} · no training`;
}
