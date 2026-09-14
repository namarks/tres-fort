/** Read-only metric policy. Exercise identity includes the catalog variation;
 * no normalization across variations, implements, assistance or hold loads. */
export type MetricExercise = {
  modality: string;
  unit: string;
  laterality: string;
  load_mode: string;
};
export type MetricSet = {
  exercise_id: string;
  weight: number;
  reps: number;
  duration_s: number | null;
  is_timed: number;
};
const epley = (weight: number, reps: number) =>
  Math.round(weight * (1 + reps / 30) * 10) / 10;
const timedDurationSeconds = (set: Pick<MetricSet, 'duration_s' | 'reps'>) =>
  set.duration_s ?? set.reps;

export function estimatedOneRepMax(set: MetricSet, exercise: MetricExercise): number | null {
  // Positive BW load is only the added load, never the system load.
  return set.is_timed !== 1 && set.weight > 0
    && ['barbell', 'dumbbell', 'machine'].includes(exercise.modality)
    ? epley(set.weight, set.reps) : null;
}

export function positiveSetTonnage(set: MetricSet, exercise: MetricExercise): number | null {
  if (set.is_timed === 1 || set.weight <= 0) return null;
  return set.weight * set.reps
    * (exercise.laterality === 'unilateral' ? 2 : 1)
    * (exercise.load_mode === 'per_hand' ? 2 : 1);
}

export function metricCohorts<T extends MetricSet>(rows: T[], exercise: MetricExercise) {
  const groups = new Map<string, T[]>();
  for (const row of rows) {
    const key = JSON.stringify([row.exercise_id, row.is_timed === 1, row.weight,
      exercise.unit, exercise.laterality, exercise.load_mode]);
    const group = groups.get(key) ?? [];
    group.push(row);
    groups.set(key, group);
  }
  return [...groups].map(([key, sets]) => {
    const timed = sets[0]!.is_timed === 1;
    const score = (set: T) => timed ? timedDurationSeconds(set) : set.reps;
    const top = sets.reduce((best, row) => score(row) > score(best) ? row : best);
    const tonnages = sets.map((set) => positiveSetTonnage(set, exercise))
      .filter((value): value is number => value != null);
    return {
      key, exercise_id: top.exercise_id, ...exercise,
      weight: top.weight,
      load_condition: top.weight < 0 ? 'assisted' : top.weight > 0 ? 'added' : 'zero',
      is_timed: timed,
      metric: timed ? 'duration' as const : 'reps' as const,
      top: timed ? { ...top, duration_s: timedDurationSeconds(top) } : top,
      best_reps: timed ? null : top.reps,
      best_duration_s: timed ? timedDurationSeconds(top) : null,
      est_1rm: estimatedOneRepMax(top, exercise),
      total_reps: timed ? null : sets.reduce((sum, set) => sum + set.reps
        * (exercise.laterality === 'unilateral' ? 2 : 1), 0),
      set_count: sets.length,
      tonnage: tonnages.length ? tonnages.reduce((a, b) => a + b, 0) : null,
      tonnage_basis: 'external_load' as const,
    };
  });
}
