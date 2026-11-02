/**
 * Plan changes, as the app's PlanHistoryView shows them: who changed the plan
 * and why, then a comparison of a saved version with the plan now before it
 * is restored. The web lays a comparison out field by field, since it has the
 * room; the Worker (comparePlanSnapshots) decides what changed.
 */
import { WEEKDAYS, type Weekday } from '../../src/types';
import { describeRunSteps, describeSlot, formatClock, WEEKDAY_LABELS, type Slot } from './model';

export interface HistorySummary {
  plan_fields: number;
  schedule_days: number;
  days_added: number;
  days_removed: number;
  days_changed: number;
  exercises_added: number;
  exercises_removed: number;
  exercises_changed: number;
}

export interface HistoryItem {
  version: number;
  actor: string;
  operation: string;
  reason: string | null;
  created_at: number;
  summary: HistorySummary | null;
  previous_version: number | null;
  affected?: string[];
}

export interface HistoryPage {
  plan_id: string;
  current_version: number;
  items: HistoryItem[];
  next_before_version: number | null;
}

export interface PlanChange {
  kind: 'plan' | 'schedule' | 'day' | 'exercise';
  path: string;
  before: unknown;
  after: unknown;
}

export interface Comparison {
  plan_id: string;
  from_version: number;
  to_version: number;
  changes: PlanChange[];
}

// ---- who and what ------------------------------------------------------------

const ACTORS: Record<string, string> = {
  mcp: 'Coach',
  ios: 'You, in the app',
  web: 'You, on the web',
  system: 'Tres Fort',
};

export function actorLabel(actor: string): string {
  return ACTORS[actor] ?? humanize(actor);
}

const OPERATIONS: Record<string, string> = {
  update_plan: 'Training plan updated',
  restore_plan: 'Earlier version restored',
  create_plan: 'Training plan created',
  ensure_active_plan: 'Training plan created',
  baseline: 'First saved version',
  set_schedule: 'Weekly routine changed',
  adjust_today: 'Training targets adjusted',
  add_day: 'Workout added',
  add_workout: 'Workout added',
  update_day: 'Workout changed',
  update_workout: 'Workout changed',
  delete_day: 'Workout removed',
  delete_workout: 'Workout removed',
  add_exercise: 'Exercise added',
  update_exercise: 'Exercise changed',
  swap_exercise: 'Exercise replaced',
  delete_exercise: 'Exercise removed',
  group_exercises: 'Superset or circuit set up',
  ungroup_exercises: 'Exercises ungrouped',
  normalize_exercise_order: 'Exercise order tidied',
  add_trip: 'Away dates added',
  update_trip: 'Away dates changed',
  remove_trip: 'Away dates removed',
  set_race: 'Race goal set',
  set_periodization: 'Training phases set',
  set_stress_model: 'Load model set',
  create_partner_workout: 'Partner workout added',
  accept_starter_workout: 'Starter workout added',
};

export function operationLabel(operation: string): string {
  return OPERATIONS[operation] ?? humanize(operation);
}

/** What a version touched, in words: "Upper A · Bench Press; Weekly routine · Monday". */
export function affectedText(item: HistoryItem, limit = 4): string | null {
  const affected = (item.affected ?? []).map(readablePath);
  if (affected.length) {
    const shown = affected.slice(0, limit).join('; ');
    return affected.length > limit ? `${shown}; and ${affected.length - limit} more` : shown;
  }
  const total = item.summary ? Object.values(item.summary).reduce((sum, count) => sum + count, 0) : 0;
  return total > 0 ? `${total} change${total === 1 ? '' : 's'}` : null;
}

function readablePath(path: string): string {
  const day = /^Weekly schedule · (mon|tue|wed|thu|fri|sat|sun)$/.exec(path);
  if (day) return `Weekly routine · ${WEEKDAY_LABELS[day[1] as Weekday]}`;
  if (path === 'Training context') return 'Plan settings';
  if (path === 'Training plan name') return 'Plan name';
  return path.replace(/^Workout · /, '').replace(/ · occurrence (\d+)$/, ' ($1)');
}

/** The writer's reason, if one was given (the coach gives one; edits in the apps don't). */
export function reasonText(item: HistoryItem): string | null {
  return item.reason?.trim() || null;
}

// ---- one comparison ----------------------------------------------------------

export interface ChangeRow {
  label: string;
  /** The saved version's value. */
  then: string;
  /** The plan's value now. */
  now: string;
}

export interface ChangeView {
  key: string;
  title: string;
  /** Relative to the saved version: what happened since. */
  status: 'added' | 'removed' | 'changed';
  rows: ChangeRow[];
}

const NONE = '—';
type Fields = Record<string, unknown>;

/**
 * The comparison as titled groups of rows, the saved version on one side
 * and the plan now on the other. Weekday changes share one group.
 */
export function changeViews(changes: readonly PlanChange[], miles: boolean): ChangeView[] {
  const views: ChangeView[] = [];
  const routine: ChangeRow[] = [];
  changes.forEach((change, index) => {
    const key = `${index}:${change.path}`;
    if (change.kind === 'schedule') {
      const day = /· (mon|tue|wed|thu|fri|sat|sun)$/.exec(change.path)?.[1] as Weekday | undefined;
      routine.push({
        label: day ? WEEKDAY_LABELS[day] : change.path,
        then: workoutName(change.before) ?? 'Rest',
        now: workoutName(change.after) ?? 'Rest',
      });
      return;
    }
    const status = change.before == null ? 'added' : change.after == null ? 'removed' : 'changed';
    const before = asFields(change.before);
    const after = asFields(change.after);
    if (change.kind === 'plan') {
      views.push(change.path === 'name'
        ? { key, title: 'Plan name', status, rows: [{ label: 'Name', then: text(change.before), now: text(change.after) }] }
        : { key, title: 'Plan settings', status, rows: metaRows(before ?? {}, after ?? {}) });
      return;
    }
    if (change.kind === 'day') {
      const name = text((after ?? before)?.day_name);
      views.push({ key, title: `Workout · ${name}`, status, rows: dayRows(before, after) });
      return;
    }
    views.push({ key, title: readablePath(change.path), status, rows: slotRows(before, after, miles) });
  });
  if (routine.length) {
    routine.sort((a, b) => weekdayIndex(a.label) - weekdayIndex(b.label));
    views.unshift({ key: 'routine', title: 'Weekly routine', status: 'changed', rows: routine });
  }
  return views;
}

function weekdayIndex(label: string): number {
  return WEEKDAYS.findIndex((day) => WEEKDAY_LABELS[day] === label);
}

function dayRows(before: Fields | null, after: Fields | null): ChangeRow[] {
  if (!before || !after) {
    const exercises = ((before ?? after)?.exercises as Fields[] | undefined) ?? [];
    const list = exercises.length ? exercises.map((slot) => text(slot.exercise_name ?? 'Exercise')).join(', ') : 'No exercises';
    return [{ label: 'Exercises', then: before ? list : NONE, now: after ? list : NONE }];
  }
  const rows: ChangeRow[] = [];
  const add = (label: string, a: string, b: string) => { if (a !== b) rows.push({ label, then: a, now: b }); };
  add('Name', text(before.day_name), text(after.day_name));
  add('Label', text(before.day_label), text(after.day_label));
  add('Position', position(before.order_index), position(after.order_index));
  add('Notes', text(before.notes), text(after.notes));
  add('Tags', tagsText(before.tags), tagsText(after.tags));
  add('Status', before.archived_at ? 'Archived' : 'Active', after.archived_at ? 'Archived' : 'Active');
  return rows;
}

/** Field names a slot comparison handles itself, or never shows. */
const SLOT_HANDLED = new Set([
  'id', 'exercise_id', 'exercise_name', 'target_sets', 'target_reps', 'target_reps_max', 'target_duration_s',
  'target_weight', 'target_weight_unit', 'target_rpe', 'rest_seconds', 'is_warmup', 'cues', 'progression',
  'run_steps', 'order_index', 'group_id', 'group_rest_seconds', 'group_transition_seconds',
]);

function slotRows(before: Fields | null, after: Fields | null, miles: boolean): ChangeRow[] {
  if (!before || !after) {
    return [{ label: 'Prescription', then: before ? prescription(before, miles) : NONE, now: after ? prescription(after, miles) : NONE }];
  }
  const rows: ChangeRow[] = [];
  const add = (label: string, a: string, b: string) => { if (a !== b) rows.push({ label, then: a, now: b }); };
  // A replaced exercise keeps its slot (and often its prescription).
  if (before.exercise_id !== after.exercise_id) {
    rows.push({ label: 'Exercise', then: exerciseText(before), now: exerciseText(after) });
  }
  add('Sets', text(before.target_sets), text(after.target_sets));
  add('Reps', repsText(before), repsText(after));
  add('Time', clockText(before.target_duration_s), clockText(after.target_duration_s));
  add('Load', loadText(before), loadText(after));
  add('Effort (RPE)', text(before.target_rpe), text(after.target_rpe));
  add('Rest', clockText(before.rest_seconds), clockText(after.rest_seconds));
  add('Warm-up', before.is_warmup ? 'Yes' : 'No', after.is_warmup ? 'Yes' : 'No');
  add('Cues', text(before.cues), text(after.cues));
  add('Progression', progressionText(before.progression), progressionText(after.progression));
  add('Run steps', runStepsText(before.run_steps, miles), runStepsText(after.run_steps, miles));
  add('Position', position(before.order_index), position(after.order_index));
  const [groupThen, groupNow] = groupTexts(before.group_id, after.group_id);
  add('Superset or circuit', groupThen, groupNow);
  add('Rest after each round', clockText(before.group_rest_seconds), clockText(after.group_rest_seconds));
  add('Rest between exercises', clockText(before.group_transition_seconds), clockText(after.group_transition_seconds));
  for (const key of new Set([...Object.keys(before), ...Object.keys(after)])) {
    if (SLOT_HANDLED.has(key) || key.endsWith('_id')) continue;
    add(humanize(key), text(before[key]), text(after[key]));
  }
  return rows;
}

const META_LABELS: Record<string, string> = {
  race: 'Race goal',
  periodization: 'Training phases',
  trips: 'Away dates',
  stress_model: 'Load model',
};

function metaRows(before: Fields, after: Fields): ChangeRow[] {
  const rows: ChangeRow[] = [];
  for (const key of new Set([...Object.keys(before), ...Object.keys(after)])) {
    if (key === 'schedule' || JSON.stringify(before[key]) === JSON.stringify(after[key])) continue;
    let a = metaText(key, before[key]);
    let b = metaText(key, after[key]);
    // The short form leaves something out: show every field rather than
    // hide a difference a restore would apply.
    if (a === b) {
      a = text(before[key]);
      b = text(after[key]);
    }
    rows.push({ label: META_LABELS[key] ?? humanize(key), then: a, now: b });
  }
  return rows;
}

function metaText(key: string, value: unknown): string {
  if (value == null || (Array.isArray(value) && value.length === 0)) return 'None';
  if (key === 'trips' && Array.isArray(value)) return value.map(tripText).join('; ');
  if (key === 'periodization' && Array.isArray(value)) return value.map(phaseText).join('; ');
  if (key === 'race' && typeof value === 'object') {
    const race = value as Fields;
    return parts([
      race.name, race.distance, race.discipline, race.date && shortDate(race.date),
      race.priority && `${text(race.priority)} race`, race.location,
    ]);
  }
  return text(value);
}

/** "Dec 20, 2026 to Dec 28, 2026 (Travel, no training) “Hotel gym”". */
function tripText(trip: Fields): string {
  const kind = humanize(text(trip.type ?? 'other'));
  const training = trip.can_train_light === false ? ', no training' : '';
  const note = typeof trip.note === 'string' && trip.note ? ` “${trip.note}”` : '';
  return `${rangeText(trip.start, trip.end)} (${kind}${training})${note}`;
}

function phaseText(phase: Fields): string {
  const extra = parts([
    phase.focus,
    typeof phase.weekly_load_target === 'number' && `weekly load ${text(phase.weekly_load_target)}`,
    phase.strength_emphasis && `${text(phase.strength_emphasis)} strength`,
  ]);
  return `${humanize(text(phase.phase))} ${rangeText(phase.start, phase.end)}${extra ? ` (${extra})` : ''}`;
}

function parts(values: unknown[]): string {
  return values.filter((part) => part != null && part !== '' && part !== false).map(text).join(', ');
}

function exerciseText(slot: Fields): string {
  return typeof slot.exercise_name === 'string' && slot.exercise_name ? slot.exercise_name : 'An exercise no longer in the catalog';
}

// ---- values ------------------------------------------------------------------

function asFields(value: unknown): Fields | null {
  return value && typeof value === 'object' && !Array.isArray(value) ? value as Fields : null;
}

function workoutName(value: unknown): string | null {
  const fields = asFields(value);
  return fields && typeof fields.day_name === 'string' ? fields.day_name : null;
}

/** Plain text for a stored value; objects read as "key: value" pairs without IDs. */
export function text(value: unknown): string {
  if (value == null || value === '') return 'None';
  if (typeof value === 'boolean') return value ? 'Yes' : 'No';
  if (typeof value === 'number') return String(Math.round(value * 1000) / 1000);
  if (typeof value === 'string') return value;
  if (Array.isArray(value)) return value.length ? value.map(text).join(', ') : 'None';
  const entries = Object.entries(value as Fields)
    .filter(([key, entry]) => key !== 'id' && !key.endsWith('_id') && entry != null);
  return entries.length ? entries.map(([key, entry]) => `${humanize(key)}: ${text(entry)}`).join(', ') : 'None';
}

function humanize(key: string): string {
  const words = key.replace(/_/g, ' ').trim();
  return words ? words[0]!.toUpperCase() + words.slice(1) : key;
}

const position = (index: unknown) => (typeof index === 'number' ? String(index + 1) : 'None');
const clockText = (seconds: unknown) => (typeof seconds === 'number' && seconds > 0 ? formatClock(seconds) : 'None');

function repsText(slot: Fields): string {
  if (typeof slot.target_duration_s === 'number' && slot.target_duration_s > 0) return 'None';
  const reps = slot.target_reps;
  const max = slot.target_reps_max;
  if (typeof reps !== 'number') return 'None';
  return typeof max === 'number' && max > reps ? `${reps}–${max}` : String(reps);
}

function loadText(slot: Fields): string {
  if (typeof slot.target_weight !== 'number') return 'None';
  return `${text(slot.target_weight)} ${slot.target_weight_unit === 'kg' ? 'kg' : 'lb'}`;
}

function tagsText(raw: unknown): string {
  if (typeof raw !== 'string') return 'None';
  try {
    const tags = JSON.parse(raw) as unknown;
    return Array.isArray(tags) && tags.length ? tags.map(text).join(', ') : 'None';
  } catch {
    return raw;
  }
}

function progressionText(raw: unknown): string {
  if (typeof raw !== 'string' || !raw) return 'None';
  try {
    return text(JSON.parse(raw));
  } catch {
    return raw;
  }
}

function runStepsText(raw: unknown, miles: boolean): string {
  if (typeof raw !== 'string' || !raw) return 'None';
  const lines = describeRunSteps(raw, miles);
  return lines.length ? lines.join('; ') : 'Steps the web can’t show';
}

function groupTexts(before: unknown, after: unknown): [string, string] {
  if (before && after && before !== after) return ['In a group', 'In a different group'];
  return [before ? 'In a group' : 'Not grouped', after ? 'In a group' : 'Not grouped'];
}

/** "Dec 20, 2026"; anything that isn't a civil date reads as stored. */
export function shortDate(value: unknown): string {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return text(value);
  const [y, m, d] = value.split('-').map(Number) as [number, number, number];
  return new Date(y, m - 1, d).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' });
}

function rangeText(start: unknown, end: unknown): string {
  return start === end || end == null ? shortDate(start) : `${shortDate(start)} to ${shortDate(end)}`;
}

/** "3 × 5 @ 135 lb · rest 2:00", with warm-up and run steps when set. */
function prescription(slot: Fields, miles: boolean): string {
  const parts = [describeSlot(slot as unknown as Slot)];
  if (slot.is_warmup) parts.push('warm-up');
  if (typeof slot.run_steps === 'string' && slot.run_steps) parts.push(runStepsText(slot.run_steps, miles));
  return parts.join(' · ');
}
