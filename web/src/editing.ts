/**
 * Pure rules for editing workouts and exercise slots on the web. They follow
 * the iPhone app's editor (ios/TresFort/EditWorkoutSheet.swift and
 * SlotLoadDraft.swift) so a slot means the same thing whichever client wrote
 * it, and the Worker's own validation stays the final word.
 */
import { RUN_EXERCISE_ID } from '../../src/runSteps';
import { slotBlocks, type Slot, type Workout } from './model';

/** One row of GET /api/exercises. */
export interface CatalogExercise {
  id: string;
  name: string;
  primary_muscle: string;
  modality: string;
  unit: string;
  laterality: string;
  load_mode: string;
  demo_slug: string | null;
  aliases: string | null;
}

export type WeightUnit = 'lb' | 'kg';
/** Reps, a timed hold, or a cardio duration. */
export type Measure = 'reps' | 'hold' | 'duration';

/** What the form needs to know about the exercise in a slot. */
export interface ExerciseFacts {
  id: string;
  modality: string;
  laterality: string;
  loadMode: string;
}

export const factsOfSlot = (slot: Slot): ExerciseFacts => ({
  id: slot.exercise_id,
  modality: slot.exercise_modality,
  laterality: slot.exercise_laterality,
  loadMode: slot.exercise_load_mode,
});

export const factsOfCatalog = (exercise: CatalogExercise): ExerciseFacts => ({
  id: exercise.id,
  modality: exercise.modality,
  laterality: exercise.laterality,
  loadMode: exercise.load_mode,
});

/** Cardio is always a duration and timed catalog rows always a hold. */
export function fixedMeasure(modality: string): Measure | null {
  if (modality === 'cardio') return 'duration';
  if (modality === 'timed') return 'hold';
  return null;
}

/** Bodyweight and hold loads are relative to bodyweight, so they may be negative (assistance). */
export const allowsAssistance = (modality: string): boolean => modality === 'bw' || modality === 'timed';

/** Cardio efforts have no load. */
export const showsLoad = (modality: string): boolean => modality !== 'cardio';

export const isRun = (facts: ExerciseFacts): boolean => facts.id === RUN_EXERCISE_ID;

/** The editor's form, as text so a half-typed number is never lost. */
export interface SlotDraft {
  isWarmup: boolean;
  measure: Measure;
  sets: string;
  reps: string;
  useRange: boolean;
  repsMax: string;
  holdSeconds: string;
  minutes: string;
  rest: string;
  weight: string;
  unit: WeightUnit;
  rpe: string;
  /** The saved load target, so showing it in the other unit loses nothing. */
  stored: { value: number; unit: WeightUnit } | null;
}

/** A new slot starts where the app's add screen does: 3 × 8, 2:00 rest, no load target. */
export function newDraft(facts: ExerciseFacts, options: { warmup: boolean; unit: WeightUnit }): SlotDraft {
  return {
    isWarmup: options.warmup,
    measure: fixedMeasure(facts.modality) ?? 'reps',
    sets: facts.modality === 'cardio' ? '1' : '3',
    reps: '8',
    useRange: false,
    repsMax: '12',
    holdSeconds: '45',
    minutes: '5',
    rest: '120',
    weight: '',
    unit: options.unit,
    rpe: '',
    stored: null,
  };
}

/** Held seconds of a timed slot; older slots stored the hold in target_reps. */
function holdSecondsOf(slot: Slot): number {
  return Math.max(1, slot.target_duration_s ?? slot.target_reps);
}

function isTimedSlot(slot: Slot): boolean {
  return slot.exercise_modality === 'timed' || slot.exercise_modality === 'cardio' || slot.target_duration_s != null;
}

export function draftFromSlot(slot: Slot): SlotDraft {
  const timed = isTimedSlot(slot);
  const measure: Measure = fixedMeasure(slot.exercise_modality) ?? (timed ? 'hold' : 'reps');
  // A hold switched back to reps starts from a sensible rep count, not its seconds.
  const reps = timed ? 8 : slot.target_reps;
  const seconds = holdSecondsOf(slot);
  return {
    isWarmup: slot.is_warmup === 1,
    measure,
    sets: String(slot.target_sets),
    reps: String(reps),
    useRange: !timed && slot.target_reps_max != null,
    repsMax: String(Math.max(reps, timed ? reps : slot.target_reps_max ?? reps)),
    holdSeconds: String(seconds),
    minutes: trimDecimals(seconds / 60, 2),
    rest: String(slot.rest_seconds),
    weight: slot.target_weight == null ? '' : weightText(slot.target_weight),
    unit: slot.target_weight_unit ?? 'lb',
    rpe: slot.target_rpe == null ? '' : String(slot.target_rpe),
    stored: slot.target_weight == null ? null : { value: slot.target_weight, unit: slot.target_weight_unit ?? 'lb' },
  };
}

const KG_IN_LB = 0.45359237;

export function convertWeight(value: number, from: WeightUnit, to: WeightUnit): number {
  if (from === to) return value;
  return from === 'lb' ? value * KG_IN_LB : value / KG_IN_LB;
}

function trimDecimals(value: number, places: number): string {
  return value.toFixed(places).replace(/\.?0+$/, '');
}

/** Up to three decimals without trailing zeros, as the app writes a load. */
export function weightText(value: number): string {
  return trimDecimals(value, 3);
}

/** A comma decimal separator is accepted too. */
export function parseNumber(text: string): number | null {
  const trimmed = text.trim().replace(',', '.');
  if (!/^[-+]?(\d+\.?\d*|\.\d+)$/.test(trimmed)) return null;
  const value = Number(trimmed);
  return Number.isFinite(value) ? value : null;
}

/** The saved load, exactly, in `unit`; null once the member has typed another one. */
function storedLoadIn(draft: SlotDraft, unit: WeightUnit): number | null {
  const stored = draft.stored;
  if (!stored || draft.weight !== weightText(convertWeight(stored.value, stored.unit, draft.unit))) return null;
  return convertWeight(stored.value, stored.unit, unit);
}

/**
 * A saved load is shown in the other unit (the same weight, as the app does);
 * a number the member typed keeps its digits, so "60" then "kg" means 60 kg.
 */
export function switchUnit(draft: SlotDraft, next: WeightUnit): SlotDraft {
  if (next === draft.unit) return draft;
  const stored = storedLoadIn(draft, next);
  return { ...draft, unit: next, weight: stored === null ? draft.weight : weightText(stored) };
}

export type DraftResult =
  | { ok: true; fields: Record<string, unknown> }
  | { ok: false; errors: string[] };

function wholeNumber(text: string, min: number, max: number): number | null {
  const value = parseNumber(text);
  return value !== null && Number.isInteger(value) && value >= min && value <= max ? value : null;
}

/**
 * The request fields for adding a slot, or for editing one (only what changed).
 * Grouped slots leave sets and rest to their group, as the Worker requires.
 */
export function prescriptionFields(
  draft: SlotDraft,
  facts: ExerciseFacts,
  editing?: Slot,
): DraftResult {
  const errors: string[] = [];
  const grouped = !!editing?.group_id;
  const measure = fixedMeasure(facts.modality) ?? draft.measure;
  const sets = wholeNumber(draft.sets, 1, 99);
  if (sets === null && !grouped) errors.push('Sets must be a whole number from 1 to 99.');
  const rest = wholeNumber(draft.rest, 0, 3600);
  if (rest === null && !grouped) errors.push('Rest must be 0 to 3600 seconds.');

  let targetReps: number | null = null;
  let targetRepsMax: number | null = null;
  let duration: number | null = null;
  if (measure === 'reps') {
    targetReps = wholeNumber(draft.reps, 1, 1000);
    if (targetReps === null) errors.push('Reps must be a whole number from 1 to 1000.');
    if (draft.useRange) {
      targetRepsMax = wholeNumber(draft.repsMax, 1, 1000);
      if (targetRepsMax === null || (targetReps !== null && targetRepsMax < targetReps)) {
        errors.push('The top of the rep range must be at least the minimum.');
      }
    }
  } else if (measure === 'hold') {
    duration = wholeNumber(draft.holdSeconds, 1, 7200);
    if (duration === null) errors.push('Hold must be 1 to 7200 seconds.');
    targetReps = duration;
  } else {
    const minutes = parseNumber(draft.minutes);
    duration = minutes === null ? null : Math.round(minutes * 60);
    if (duration === null || duration < 1 || duration > 6 * 3600) {
      errors.push('Duration must be more than 0 and at most 360 minutes.');
      duration = null;
    }
    // A cardio slot's reps are not shown; keep what is stored.
    targetReps = editing ? editing.target_reps : 1;
  }

  let weight: number | null = null;
  let rpe: number | null = null;
  if (showsLoad(facts.modality)) {
    if (draft.weight.trim() !== '') {
      weight = storedLoadIn(draft, draft.unit) ?? parseNumber(draft.weight);
      if (weight === null) errors.push('Enter the weight as a number.');
      else if (weight < 0 && !allowsAssistance(facts.modality)) errors.push('Enter a weight of 0 or more.');
    }
    if (draft.rpe.trim() !== '') {
      rpe = parseNumber(draft.rpe);
      if (rpe === null || rpe < 1 || rpe > 10) {
        errors.push('RPE must be from 1 to 10.');
        rpe = null;
      }
    }
  }
  if (errors.length) return { ok: false, errors };

  const next: Record<string, unknown> = {
    is_warmup: draft.isWarmup,
    target_reps: targetReps,
    target_reps_max: targetRepsMax,
    target_duration_s: duration,
  };
  if (!grouped) {
    next.target_sets = sets;
    next.rest_seconds = rest;
  }
  if (!editing) {
    if (weight !== null) {
      next.target_weight = weight;
      next.target_weight_unit = draft.unit;
    }
    if (rpe !== null) next.target_rpe = rpe;
    if (next.target_reps_max === null) delete next.target_reps_max;
    if (next.target_duration_s === null) delete next.target_duration_s;
    return { ok: true, fields: next };
  }

  const fields: Record<string, unknown> = {};
  const current: Record<string, unknown> = {
    is_warmup: editing.is_warmup === 1,
    target_reps: editing.target_reps,
    target_reps_max: editing.target_reps_max,
    target_duration_s: editing.target_duration_s,
    target_sets: editing.target_sets,
    rest_seconds: editing.rest_seconds,
  };
  for (const [key, value] of Object.entries(next)) {
    if (value !== current[key]) fields[key] = value;
  }
  if (showsLoad(facts.modality)) {
    const unit = editing.target_weight_unit ?? 'lb';
    const sameWeight = weight === null
      ? editing.target_weight == null
      : editing.target_weight != null && unit === draft.unit && Math.abs(editing.target_weight - weight) < 1e-9;
    if (!sameWeight) {
      fields.target_weight = weight;
      if (weight !== null) fields.target_weight_unit = draft.unit;
    }
    if (rpe !== (editing.target_rpe ?? null)) fields.target_rpe = rpe;
  }
  return { ok: true, fields };
}

/**
 * Where an exercise lands when moved one place up (-1) or down (+1): past the
 * whole neighboring block, so it never lands inside a superset or circuit.
 * Null when it cannot move that way or is itself in a group.
 */
export function moveDestination(workout: Workout, slotId: string, direction: -1 | 1): number | null {
  const blocks = slotBlocks(workout);
  const index = blocks.findIndex((block) => block.members.some((member) => member.id === slotId));
  const block = blocks[index];
  if (!block || block.group) return null;
  const target = index + direction;
  if (target < 0 || target >= blocks.length) return null;
  const reordered = [...blocks];
  reordered.splice(index, 1);
  reordered.splice(target, 0, block);
  return reordered.slice(0, target).reduce((count, other) => count + other.members.length, 0);
}

function aliasesOf(exercise: CatalogExercise): string[] {
  if (!exercise.aliases) return [];
  try {
    const parsed = JSON.parse(exercise.aliases) as unknown;
    return Array.isArray(parsed) ? parsed.filter((alias): alias is string => typeof alias === 'string') : [];
  } catch {
    return [];
  }
}

/** Catalog matches for a search: name starts, then word starts, then anywhere, then aliases. */
export function searchCatalog(catalog: CatalogExercise[], query: string, limit = 40): CatalogExercise[] {
  const needle = query.trim().toLowerCase();
  const sorted = [...catalog].sort((a, b) => a.name.localeCompare(b.name));
  if (!needle) return sorted.slice(0, limit);
  const rank = (exercise: CatalogExercise): number => {
    const name = exercise.name.toLowerCase();
    if (name.startsWith(needle)) return 0;
    if (name.split(/[\s-]+/).some((word) => word.startsWith(needle))) return 1;
    if (name.includes(needle)) return 2;
    if (aliasesOf(exercise).some((alias) => alias.toLowerCase().includes(needle))) return 3;
    if (exercise.primary_muscle.toLowerCase().startsWith(needle)) return 4;
    return -1;
  };
  return sorted
    .map((exercise) => ({ exercise, rank: rank(exercise) }))
    .filter((entry) => entry.rank >= 0)
    .sort((a, b) => a.rank - b.rank)
    .slice(0, limit)
    .map((entry) => entry.exercise);
}

/** Tags as the Worker stores them: trimmed, lower case, unique, at most 12 of 32 characters. */
export function parseTags(text: string): { ok: true; tags: string[] } | { ok: false; error: string } {
  const tags = [...new Set(text.split(',').map((tag) => tag.trim().toLowerCase()).filter(Boolean))];
  if (tags.length > 12) return { ok: false, error: 'Use at most 12 tags.' };
  if (tags.some((tag) => tag.length > 32)) return { ok: false, error: 'Keep each tag to 32 characters.' };
  return { ok: true, tags };
}

export function tagsOf(workout: Workout): string[] {
  if (!workout.tags) return [];
  try {
    const parsed = JSON.parse(workout.tags) as unknown;
    return Array.isArray(parsed) ? parsed.filter((tag): tag is string => typeof tag === 'string') : [];
  } catch {
    return [];
  }
}

const ERROR_MESSAGES: Record<string, string> = {
  active_workout: 'This workout is in progress in the app. Finish or discard it there first.',
  day_in_progress: 'This workout is in progress in the app. Finish or discard it there first.',
  group_conflict: 'Sets and rest of a superset or circuit belong to the group. Change them in the app for now.',
  unknown_exercise: 'That exercise isn’t in the catalog.',
  no_active_plan: 'There is no plan to edit yet.',
  not_found: 'That workout or exercise is no longer in your plan.',
  incompatible_measure: 'That exercise is measured differently, so it can’t replace this one.',
};

/** A sentence for a refused write; field names are shown as the API names them. */
export function describeWriteError(body: unknown): string {
  const record = (body ?? {}) as { error?: unknown; fields?: unknown };
  const code = typeof record.error === 'string' ? record.error : '';
  if (ERROR_MESSAGES[code]) return ERROR_MESSAGES[code];
  if ((code === 'invalid_fields' || code === 'unknown_fields') && Array.isArray(record.fields)) {
    return `The plan didn’t accept: ${record.fields.join(', ')}.`;
  }
  return 'That change didn’t save. Please try again.';
}
