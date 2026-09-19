import type { PlanTree } from './types';
import { parsePlanMeta } from './types';

export interface PlanSnapshotExercise {
  group_id?: string | null;
  group_rest_seconds?: number | null;
  group_transition_seconds?: number | null;
  id: string;
  exercise_id: string;
  order_index: number;
  target_sets: number;
  target_reps: number;
  target_reps_max: number | null;
  target_rpe: number | null;
  rest_seconds: number;
  target_weight: number | null;
  target_duration_s: number | null;
  progression: string | null;
  cues: string | null;
  is_warmup: number;
}

export interface PlanSnapshotWorkout {
  tags?: string;
  archived_at?: number | null;
  id: string;
  name: string;
  day_label: string | null;
  order_index: number;
  notes: string | null;
  exercises: PlanSnapshotExercise[];
}

export interface PlanSnapshotDocument {
  schema_version: 2;
  plan: { name: string; meta: string | null };
  workouts: PlanSnapshotWorkout[];
}

export interface PlanSnapshotChange {
  kind: 'plan' | 'schedule' | 'day' | 'exercise';
  path: string;
  before: unknown;
  after: unknown;
}

export interface PlanSnapshotSummary {
  plan_fields: number;
  schedule_days: number;
  days_added: number;
  days_removed: number;
  days_changed: number;
  exercises_added: number;
  exercises_removed: number;
  exercises_changed: number;
}

export function serializePlanSnapshot(tree: PlanTree): PlanSnapshotDocument {
  return {
    schema_version: 2,
    plan: { name: tree.name, meta: tree.meta },
    workouts: tree.workouts.map((day) => ({
      id: day.id,
      name: day.name,
      day_label: day.day_label,
      order_index: day.order_index,
      notes: day.notes,
      tags: day.tags ?? '[]',
      archived_at: day.archived_at ?? null,
      exercises: day.exercises.map((slot) => ({
        id: slot.id,
        exercise_id: slot.exercise_id,
        order_index: slot.order_index,
        target_sets: slot.target_sets,
        target_reps: slot.target_reps,
        target_reps_max: slot.target_reps_max,
        target_rpe: slot.target_rpe,
        rest_seconds: slot.rest_seconds,
        target_weight: slot.target_weight,
        target_duration_s: slot.target_duration_s,
        progression: slot.progression,
        cues: slot.cues,
        is_warmup: slot.is_warmup,
        group_id: slot.group_id ?? null,
        group_rest_seconds: slot.group_rest_seconds ?? null,
        group_transition_seconds: slot.group_transition_seconds ?? null,
      })),
    })),
  };
}

export function parsePlanSnapshot(raw: string): PlanSnapshotDocument {
  const value: unknown = JSON.parse(raw);
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('invalid_plan_snapshot');
  const stored = value as { schema_version?: unknown; plan?: PlanSnapshotDocument['plan']; days?: PlanSnapshotWorkout[]; workouts?: PlanSnapshotWorkout[] };
  const workouts = stored.schema_version === 1 ? stored.days : stored.workouts;
  if ((stored.schema_version !== 1 && stored.schema_version !== 2) || !stored.plan || !Array.isArray(workouts)) {
    throw new Error('unsupported_plan_snapshot');
  }
  // Read old immutable documents without rewriting their stored bytes.
  const doc: PlanSnapshotDocument = { schema_version: 2, plan: stored.plan, workouts };
  for (const day of doc.workouts) {
    day.tags ??= '[]';
    day.archived_at ??= null;
  }
  // Pre-group snapshots remain writable and compare as explicitly ungrouped.
  for (const day of doc.workouts) for (const slot of day.exercises) {
    slot.group_id ??= null;
    slot.group_rest_seconds ??= null;
    slot.group_transition_seconds ??= null;
  }
  return doc as PlanSnapshotDocument;
}

const stable = (value: unknown): string => JSON.stringify(value);

export interface PlanSnapshotComparisonOptions {
  /** Catalog labels are resolved at read time; canonical snapshots retain IDs. */
  exerciseNames?: ReadonlyMap<string, string> | Readonly<Record<string, string>>;
}

function exerciseName(id: string, options: PlanSnapshotComparisonOptions): string | null {
  const names = options.exerciseNames;
  if (!names) return null;
  if (typeof (names as ReadonlyMap<string, string>).get === 'function') {
    return (names as ReadonlyMap<string, string>).get(id) ?? null;
  }
  return (names as Readonly<Record<string, string>>)[id] ?? null;
}

function dayIdentity(day: PlanSnapshotWorkout) {
  return { day_id: day.id, day_name: day.name, day_label: day.day_label };
}

function readableSlot(slot: PlanSnapshotExercise, options: PlanSnapshotComparisonOptions) {
  return { ...slot, exercise_name: exerciseName(slot.exercise_id, options) };
}

function readableDay(day: PlanSnapshotWorkout, options: PlanSnapshotComparisonOptions) {
  return { ...dayIdentity(day), order_index: day.order_index, notes: day.notes, tags: day.tags ?? '[]', archived_at: day.archived_at ?? null,
    exercises: day.exercises.map((slot) => readableSlot(slot, options)) };
}

function uniqueMatches<T>(
  before: T[], after: T[], beforeKey: (value: T) => string | null, afterKey = beforeKey,
): Array<[T, T]> {
  const oldByKey = new Map<string, T[]>();
  const newByKey = new Map<string, T[]>();
  for (const value of before) {
    const key = beforeKey(value);
    if (key != null) oldByKey.set(key, [...(oldByKey.get(key) ?? []), value]);
  }
  for (const value of after) {
    const key = afterKey(value);
    if (key != null) newByKey.set(key, [...(newByKey.get(key) ?? []), value]);
  }
  const matches: Array<[T, T]> = [];
  for (const [key, oldValues] of oldByKey) {
    const newValues = newByKey.get(key);
    if (oldValues.length === 1 && newValues?.length === 1) matches.push([oldValues[0]!, newValues[0]!]);
  }
  return matches;
}

function matchDays(before: PlanSnapshotWorkout[], after: PlanSnapshotWorkout[]) {
  const pairs: Array<[PlanSnapshotWorkout, PlanSnapshotWorkout]> = [];
  const usedBefore = new Set<PlanSnapshotWorkout>();
  const usedAfter = new Set<PlanSnapshotWorkout>();
  const take = (candidates: Array<[PlanSnapshotWorkout, PlanSnapshotWorkout]>) => {
    for (const [oldDay, newDay] of candidates) if (!usedBefore.has(oldDay) && !usedAfter.has(newDay)) {
      pairs.push([oldDay, newDay]); usedBefore.add(oldDay); usedAfter.add(newDay);
    }
  };
  take(uniqueMatches(before, after, (day) => day.id));
  take(uniqueMatches(
    before.filter((day) => !usedBefore.has(day)), after.filter((day) => !usedAfter.has(day)),
    (day) => day.day_label?.trim() || null,
  ));
  take(uniqueMatches(
    before.filter((day) => !usedBefore.has(day)), after.filter((day) => !usedAfter.has(day)),
    (day) => day.name.trim() || null,
  ));
  return { pairs, removed: before.filter((day) => !usedBefore.has(day)), added: after.filter((day) => !usedAfter.has(day)) };
}

function matchSlots(before: PlanSnapshotExercise[], after: PlanSnapshotExercise[]) {
  const pairs: Array<[PlanSnapshotExercise, PlanSnapshotExercise]> = [];
  const usedBefore = new Set<PlanSnapshotExercise>();
  const usedAfter = new Set<PlanSnapshotExercise>();
  for (const [oldSlot, newSlot] of uniqueMatches(before, after, (slot) => slot.id)) {
    pairs.push([oldSlot, newSlot]); usedBefore.add(oldSlot); usedAfter.add(newSlot);
  }
  // Rebuilt trees regenerate slot IDs. Match the nth occurrence of the same
  // exercise and warm-up role, in canonical order, without guessing across roles.
  const grouped = (slots: PlanSnapshotExercise[], used: Set<PlanSnapshotExercise>) => {
    const result = new Map<string, PlanSnapshotExercise[]>();
    for (const slot of slots.filter((value) => !used.has(value))) {
      const key = `${slot.exercise_id}:${slot.is_warmup}`;
      result.set(key, [...(result.get(key) ?? []), slot]);
    }
    return result;
  };
  const oldGroups = grouped(before, usedBefore);
  const newGroups = grouped(after, usedAfter);
  for (const [key, oldSlots] of oldGroups) {
    const newSlots = newGroups.get(key) ?? [];
    for (let index = 0; index < Math.min(oldSlots.length, newSlots.length); index++) {
      const oldSlot = oldSlots[index]!; const newSlot = newSlots[index]!;
      pairs.push([oldSlot, newSlot]); usedBefore.add(oldSlot); usedAfter.add(newSlot);
    }
  }
  return { pairs, removed: before.filter((slot) => !usedBefore.has(slot)), added: after.filter((slot) => !usedAfter.has(slot)) };
}

function slotPath(
  day: PlanSnapshotWorkout,
  slot: PlanSnapshotExercise,
  options: PlanSnapshotComparisonOptions,
): string {
  const matching = day.exercises.filter((candidate) =>
    candidate.exercise_id === slot.exercise_id && candidate.is_warmup === slot.is_warmup);
  const occurrence = matching.findIndex((candidate) => candidate === slot) + 1;
  const suffix = matching.length > 1 ? ` · occurrence ${occurrence}` : '';
  return `${day.name} · ${exerciseName(slot.exercise_id, options) ?? 'Exercise'}${suffix}`;
}

export function comparePlanSnapshots(
  before: PlanSnapshotDocument,
  after: PlanSnapshotDocument,
  options: PlanSnapshotComparisonOptions = {},
): { changes: PlanSnapshotChange[]; summary: PlanSnapshotSummary } {
  const changes: PlanSnapshotChange[] = [];
  const summary: PlanSnapshotSummary = {
    plan_fields: 0, schedule_days: 0, days_added: 0, days_removed: 0,
    days_changed: 0, exercises_added: 0, exercises_removed: 0, exercises_changed: 0,
  };
  if (before.plan.name !== after.plan.name) {
    changes.push({ kind: 'plan', path: 'name', before: before.plan.name, after: after.plan.name });
    summary.plan_fields++;
  }
  const parsedBeforeMeta = parsePlanMeta(before.plan.meta);
  const parsedAfterMeta = parsePlanMeta(after.plan.meta);
  const matchedDays = matchDays(before.workouts, after.workouts);
  const replacementIds = new Map(matchedDays.pairs.map(([oldDay, newDay]) => [oldDay.id, newDay.id]));
  const beforeMeta = { ...parsedBeforeMeta, schedule: undefined };
  const afterMeta = { ...parsedAfterMeta, schedule: undefined };
  if (stable(beforeMeta) !== stable(afterMeta)) {
    changes.push({ kind: 'plan', path: 'meta', before: beforeMeta, after: afterMeta });
    summary.plan_fields++;
  }
  for (const weekday of ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'] as const) {
    const a = parsedBeforeMeta.schedule.week[weekday];
    const b = parsedAfterMeta.schedule.week[weekday];
    if (a !== b && (a == null || replacementIds.get(a) !== b)) {
      const oldDay = before.workouts.find((day) => day.id === a);
      const newDay = after.workouts.find((day) => day.id === b);
      changes.push({ kind: 'schedule', path: `Weekly schedule · ${weekday}`, before: oldDay ? dayIdentity(oldDay) : null, after: newDay ? dayIdentity(newDay) : null });
      summary.schedule_days++;
    }
  }
  for (const day of matchedDays.removed) {
    changes.push({ kind: 'day', path: `Workout · ${day.name}`, before: readableDay(day, options), after: null });
    summary.days_removed++;
    summary.exercises_removed += day.exercises.length;
  }
  for (const day of matchedDays.added) {
    changes.push({ kind: 'day', path: `Workout · ${day.name}`, before: null, after: readableDay(day, options) });
    summary.days_added++;
    summary.exercises_added += day.exercises.length;
  }
  for (const [prior, day] of matchedDays.pairs) {
    const beforeFields = { name: prior.name, day_label: prior.day_label, order_index: prior.order_index, notes: prior.notes, tags: prior.tags ?? '[]', archived_at: prior.archived_at ?? null };
    const afterFields = { name: day.name, day_label: day.day_label, order_index: day.order_index, notes: day.notes, tags: day.tags ?? '[]', archived_at: day.archived_at ?? null };
    if (stable(beforeFields) !== stable(afterFields)) {
      changes.push({ kind: 'day', path: `Workout · ${day.name}`, before: { ...dayIdentity(prior), ...beforeFields }, after: { ...dayIdentity(day), ...afterFields } });
      summary.days_changed++;
    }
    const slots = matchSlots(prior.exercises, day.exercises);
    for (const slot of slots.removed) {
      changes.push({ kind: 'exercise', path: slotPath(prior, slot, options), before: readableSlot(slot, options), after: null });
      summary.exercises_removed++;
    }
    for (const slot of slots.added) {
      changes.push({ kind: 'exercise', path: slotPath(day, slot, options), before: null, after: readableSlot(slot, options) });
      summary.exercises_added++;
    }
    for (const [old, slot] of slots.pairs) {
      const comparable = (value: PlanSnapshotExercise) => {
        const { group_id, group_rest_seconds, group_transition_seconds, ...fields } = value;
        return { ...fields, id: undefined, group_id: group_id ?? null,
          group_rest_seconds: group_rest_seconds ?? null, group_transition_seconds: group_transition_seconds ?? null };
      };
      const oldComparable = comparable(old);
      const newComparable = comparable(slot);
      if (stable(oldComparable) !== stable(newComparable)) {
        changes.push({ kind: 'exercise', path: slotPath(day, slot, options), before: readableSlot(old, options), after: readableSlot(slot, options) });
        summary.exercises_changed++;
      }
    }
  }
  return { changes, summary };
}
