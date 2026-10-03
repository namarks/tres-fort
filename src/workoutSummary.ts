import { metricCohorts, type MetricExercise, type MetricSet } from './metrics';

export type SummarySet = MetricSet & {
  id: string; template_exercise_id: string | null; is_warmup: number;
  deleted_at: number | null; rpe: number | null;
};
export type SummaryExercise = MetricExercise & { id: string; name: string };
export interface RunnerTarget {
  slot_id: string; exercise_id: string; name: string; is_warmup: number; is_timed: number;
  sets: number; reps: number; reps_max: number | null; weight: number | null;
  duration_s: number | null; rpe: number | null;
}
export interface RunnerTargetSnapshot {
  version: 1; captured_at: number; plan_version: number; slots: RunnerTarget[];
}

export function parseRunnerTargets(raw: string | null | undefined): RunnerTargetSnapshot | null {
  if (!raw) return null;
  try {
    const value = JSON.parse(raw) as RunnerTargetSnapshot;
    return value.version === 1 && Array.isArray(value.slots) ? value : null;
  } catch { return null; }
}

const POUNDS_PER_KG = 1 / 0.45359237;
const pounds = (load: { weight: number; unit: string }) =>
  load.unit === 'kg' ? load.weight * POUNDS_PER_KG : load.weight;

/** The same physical load, whichever unit logged it. One unit compares
 * exactly; across units a dual-labelled implement (24 kg / 53 lb, 32 kg /
 * 70 lb) matches within its label rounding, while a 45 lb bar stays distinct
 * from a 20 kg one. */
export function sameLoad(a: { weight: number; unit: string }, b: { weight: number; unit: string }) {
  if (a.weight === 0 || b.weight === 0 || (a.unit === 'kg') === (b.unit === 'kg')) return a.weight === b.weight;
  const x = pounds(a), y = pounds(b);
  return Math.sign(x) === Math.sign(y)
    && Math.abs(x - y) <= Math.max(0.5, 0.01 * Math.max(Math.abs(x), Math.abs(y)));
}

/** One completion policy, fed exclusively by persisted rows. The app renders
 * this result; history and MCP use this same projection. No body-mass/e1RM
 * proxy is introduced for bodyweight work. */
export function summarizeWorkout(
  session: { id: string; date: string; attempt: number; status: string },
  sets: SummarySet[], previousBests: MetricSet[], exercises: SummaryExercise[],
  targets: RunnerTargetSnapshot | null,
) {
  const live = sets.filter((set) => set.deleted_at == null && set.is_warmup === 0);
  const cohorts = exercises.flatMap((exercise) => metricCohorts(
    live.filter((set) => set.exercise_id === exercise.id), exercise)
    .map((cohort) => ({ ...cohort, name: exercise.name })));
  const previous = exercises.flatMap((exercise) => metricCohorts(
    previousBests.filter((set) => set.exercise_id === exercise.id), exercise));
  const score = (cohort: { best_duration_s: number | null; best_reps: number | null }) =>
    cohort.best_duration_s ?? cohort.best_reps ?? 0;
  const comparable = (a: typeof previous[number], b: typeof previous[number]) =>
    a.exercise_id === b.exercise_id && a.is_timed === b.is_timed && sameLoad(a, b);
  const records = session.status !== 'completed' ? [] : cohorts.flatMap((cohort, index) => {
    const value = score(cohort);
    // The same load logged in both units this session is one record, not two.
    if (cohorts.some((other, j) => j !== index && comparable(other, cohort)
      && (score(other) > value || (score(other) === value && j < index)))) return [];
    // A previous best counts in either unit: 24 kg × 6 beats 53 lb × 5.
    const old = previous.filter((candidate) => comparable(candidate, cohort))
      .reduce<typeof previous[number] | undefined>((best, candidate) =>
        best == null || score(candidate) > score(best) ? candidate : best, undefined);
    const prior = old == null ? undefined : score(old);
    // An initial baseline or a different assistance/load condition is not a PR.
    return old != null && prior != null && value > prior ? [{
      exercise_id: cohort.exercise_id, name: cohort.name, weight: cohort.weight,
      unit: cohort.unit, modality: cohort.modality, laterality: cohort.laterality,
      load_mode: cohort.load_mode, metric: cohort.metric, value, previous: prior,
      previous_weight: old.weight, previous_unit: old.unit,
    }] : [];
  });
  const targetResults = (targets?.slots ?? []).filter((target) => target.is_warmup === 0).map((target) => {
    const actual = live.filter((set) => set.template_exercise_id === target.slot_id
      && set.exercise_id === target.exercise_id && set.is_timed === target.is_timed);
    // Plan rebuilds detach old slot foreign keys. Do not turn that loss of
    // attribution into a false missed-target claim.
    const comparisonAvailable = !live.some((set) => set.exercise_id === target.exercise_id
      && set.template_exercise_id == null && set.is_timed === target.is_timed);
    const changed = actual.filter((set) =>
      (target.weight != null && set.weight !== target.weight)
      || (target.is_timed === 1
        ? (set.duration_s ?? set.reps) !== (target.duration_s ?? target.reps)
        : set.reps < target.reps || set.reps > (target.reps_max ?? target.reps))
      || (target.rpe != null && set.rpe != null && set.rpe !== target.rpe)).length;
    const below = actual.filter((set) => target.is_timed === 1
      ? (set.duration_s ?? set.reps) < (target.duration_s ?? target.reps)
      : set.reps < target.reps).length;
    return { ...target, comparison_available: comparisonAvailable, actual_sets: actual.length, missed_sets: Math.max(0, target.sets - actual.length),
      changed_sets: changed, below_target_sets: below };
  });
  const volumes = new Map<string, { unit: string; value: number; contributing_sets: number }>();
  for (const cohort of cohorts) {
    if (cohort.tonnage == null) continue;
    const volume = volumes.get(cohort.unit) ?? { unit: cohort.unit, value: 0, contributing_sets: 0 };
    volume.value += cohort.tonnage;
    volume.contributing_sets += cohort.set_count;
    volumes.set(cohort.unit, volume);
  }
  const byUnit = [...volumes.values()].sort((a, b) => a.unit.localeCompare(b.unit));
  return {
    version: 1 as const, session_id: session.id, date: session.date, attempt: session.attempt,
    final: session.status === 'completed', working_sets: live.length,
    total_reps: cohorts.reduce((sum, cohort) => sum + (cohort.total_reps ?? 0), 0),
    // The scalar is valid only for one unit; lb and kg are never summed.
    external_load_volume: byUnit.length === 1 ? byUnit[0]!.value : null,
    external_load_volume_by_unit: byUnit,
    cohorts: cohorts.map((cohort) => ({ exercise_id: cohort.exercise_id, name: cohort.name,
      weight: cohort.weight, unit: cohort.unit, modality: cohort.modality, laterality: cohort.laterality,
      load_mode: cohort.load_mode, metric: cohort.metric, value: cohort.best_duration_s ?? cohort.best_reps ?? 0,
      set_count: cohort.set_count })),
    records, targets_available: targets != null, targets_captured_at: targets?.captured_at ?? null,
    targets: targetResults,
  };
}
export type WorkoutSummary = ReturnType<typeof summarizeWorkout>;
