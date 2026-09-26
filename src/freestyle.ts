import type { SetLogRow } from './types';

export interface FreestylePrescription {
  exercise_id: string;
  target_sets: number;
  target_reps: number;
  target_duration_s: number | null;
  target_weight: number;
  rest_seconds: number;
}

export interface FreestyleCohort extends FreestylePrescription {
  source_set_ids: string[];
  is_timed: boolean;
}

/** Derive within one movement, execution mode and exact external load.
 * Order is first performed, never catalog order or highest load. */
export function deriveFreestylePrescriptions(sets: SetLogRow[]): FreestyleCohort[] {
  const cohorts = new Map<string, SetLogRow[]>();
  for (const set of [...sets].sort((a,b) => a.logged_at-b.logged_at || a.id.localeCompare(b.id))) {
    if (set.deleted_at != null || set.is_warmup) continue;
    const key = JSON.stringify([set.exercise_id, set.is_timed === 1, set.weight]);
    const cohort = cohorts.get(key) ?? [];
    cohort.push(set);
    cohorts.set(key, cohort);
  }
  return [...cohorts.values()].map(rows => {
    const first = rows[0]!;
    const timed = first.is_timed === 1;
    const values = rows.map(row => timed ? row.duration_s ?? row.reps : row.reps).sort((a,b)=>a-b);
    const middle = Math.floor(values.length/2);
    const median = Math.max(1, Math.round(values.length%2 ? values[middle]!
      : (values[middle-1]!+values[middle]!)/2));
    return { exercise_id: first.exercise_id, target_sets: rows.length,
      target_reps: timed ? 1 : median, target_duration_s: timed ? median : null,
      target_weight: first.weight, rest_seconds: 120, is_timed: timed,
      source_set_ids: rows.map(row=>row.id) };
  });
}
