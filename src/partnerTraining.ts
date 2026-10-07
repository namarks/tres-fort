import type { TemplateExerciseRow } from './types';
import { isGroupId } from './exerciseGroups';

/** The complete writable slot, with fresh IDs chosen once by the joining phone. */
export type PartnerSlot = Omit<TemplateExerciseRow, 'workout_id' | 'created_at' | 'updated_at'>;
export interface PartnerWorkoutInput {
  workout_id: string;
  name: string;
  expected_plan_id: string | null;
  expected_version: number;
  slots: PartnerSlot[];
}
export interface PartnerStartInput {
  id: string;
  session_id: string;
  partner_workout_id: string;
  date: string;
  workout_id: string;
  expected_plan_id: string;
  expected_version: number;
  expected_attempt: number;
}

const record = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === 'object' && !Array.isArray(value);
const exactKeys = (value: Record<string, unknown>, keys: readonly string[]) =>
  Object.keys(value).every(key => keys.includes(key));
const integer = (value: unknown, min = 0) => Number.isSafeInteger(value) && Number(value) >= min;
export const partnerSlotKeys = ['id', 'exercise_id', 'order_index', 'target_sets', 'target_reps',
  'target_reps_max', 'target_rpe', 'rest_seconds', 'target_weight', 'target_weight_unit',
  'target_duration_s', 'progression', 'cues', 'is_warmup', 'group_id', 'group_rest_seconds',
  'group_transition_seconds'] as const;

export function isPartnerWorkoutInput(value: unknown): value is PartnerWorkoutInput {
  if (!record(value) || !exactKeys(value, ['workout_id','name','expected_plan_id','expected_version','slots'])
      || !isGroupId(value.workout_id) || typeof value.name !== 'string'
      || !value.name.trim() || value.name.length > 200
      || !(value.expected_plan_id === null || isGroupId(value.expected_plan_id))
      || !integer(value.expected_version) || !Array.isArray(value.slots)
      || value.slots.length < 1 || value.slots.length > 50) return false;
  return value.slots.every((slot, index) => record(slot) && exactKeys(slot, partnerSlotKeys)
    && isGroupId(slot.id) && typeof slot.exercise_id === 'string' && slot.exercise_id.length > 0
    && slot.order_index === index && integer(slot.target_sets, 1) && Number(slot.target_sets) <= 100
    && integer(slot.rest_seconds) && (slot.target_weight_unit === 'lb' || slot.target_weight_unit === 'kg')
    && (slot.is_warmup === 0 || slot.is_warmup === 1)
    && (slot.progression === null || typeof slot.progression === 'string'));
}

export function isPartnerStartInput(value: unknown): value is PartnerStartInput {
  if (!record(value) || !exactKeys(value, ['id','session_id','partner_workout_id','date','workout_id',
    'expected_plan_id','expected_version','expected_attempt'])) return false;
  return ['id','session_id','partner_workout_id','workout_id','expected_plan_id'].every(key => isGroupId(value[key]))
    && typeof value.date === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value.date)
    && Number.isFinite(new Date(`${value.date}T12:00:00Z`).getTime())
    && new Date(`${value.date}T12:00:00Z`).toISOString().slice(0, 10) === value.date
    && integer(value.expected_version, 1) && integer(value.expected_attempt);
}

/** Canonical object order makes retries independent of JSON encoder key order. */
export function partnerRequestJSON(value: unknown): string {
  const normalize = (item: unknown): unknown => Array.isArray(item) ? item.map(normalize)
    : record(item) ? Object.fromEntries(Object.keys(item).sort().map(key => [key, normalize(item[key])])) : item;
  return JSON.stringify(normalize(value));
}

export function isActivePartnerWorkout(error: unknown): boolean {
  return error instanceof Error && error.message.includes('active_partner_workout');
}
