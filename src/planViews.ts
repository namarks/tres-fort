import { parsePlanMeta, WEEKDAYS } from './types';
import type { PlanTree, Weekday } from './types';

/**
 * Resolve the recurring weekly schedule to human-readable weekday → workout
 * name (null = rest), for coaching context.
 *
 * Pure projection of a plan tree the caller already holds: the schedule lives
 * in `plans.meta` and the names are on `tree.workouts`, so this needs no D1
 * read of its own.
 */
export function resolvedScheduleNames(tree: PlanTree): Record<Weekday, string | null> {
  const week = parsePlanMeta(tree.meta).schedule.week;
  const nameById = new Map(tree.workouts.map((workout) => [workout.id, workout.name]));
  const out = {} as Record<Weekday, string | null>;
  for (const weekday of WEEKDAYS) {
    const id = week[weekday];
    out[weekday] = id ? nameById.get(id) ?? null : null;
  }
  return out;
}
