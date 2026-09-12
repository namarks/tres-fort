import type { EnrichedTemplateExercise } from './types';

export interface SessionExerciseSwap {
  original: EnrichedTemplateExercise;
  replacement: EnrichedTemplateExercise;
  exercise_ids: string[];
}
export interface SessionExerciseSwaps {
  attempt: number;
  revision: number;
  entries: SessionExerciseSwap[];
}

// Written only by the service; a missing column value represents an unswapped session.
export function parseSessionExerciseSwaps(value?: string | null, attempt?: number): SessionExerciseSwaps {
  const empty = { attempt: attempt ?? 0, revision: 0, entries: [] };
  if (!value) return empty;
  const parsed = JSON.parse(value) as SessionExerciseSwaps;
  return attempt === undefined || parsed.attempt === attempt ? parsed : empty;
}

export function applicableSessionSwap(value: string | null | undefined, slot: EnrichedTemplateExercise, attempt: number) {
  const keys = Object.keys(slot) as (keyof EnrichedTemplateExercise)[];
  return parseSessionExerciseSwaps(value, attempt).entries.find((entry) =>
    keys.every((key) => entry.original[key] === slot[key]));
}
