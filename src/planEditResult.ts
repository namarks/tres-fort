import type { TemplateExerciseRow } from './types';

export type PlanVersionConflict = { conflict: true; current_version: number };
export type PlanEditError =
  | { error: 'invalid_fields' | 'unknown_fields' | 'group_conflict'; fields: string[] }
  | { error: 'no_active_plan' | 'not_found' };

/** Keep successful rows and legacy missing-slot results compatible while all
 * edit writers share the same actionable failure vocabulary. */
export type SlotEditResult = TemplateExerciseRow | PlanVersionConflict | PlanEditError | null;

export interface SlotEditOptions {
  expectedVersion?: number;
  /** One retry is permitted only for an unversioned write whose CAS lost. */
  retryLegacyConflict?: boolean;
}

export function slotEditResponse(result: SlotEditResult, successStatus: 200 | 201 = 200) {
  if (result === null) return { body: { error: 'not_found' }, status: 404 as const };
  if ('conflict' in result) return { body: result, status: 409 as const };
  if ('error' in result) return { body: result,
    status: result.error === 'not_found' ? 404 as const : 400 as const };
  return { body: result, status: successStatus };
}
