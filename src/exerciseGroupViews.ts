import type { EnrichedTemplateExercise, PlanTree } from './types';

/** Unknown capabilities are ignored so independently released features compose. */
export function readCapabilities(header: string | undefined): ReadonlySet<string> {
  return new Set((header ?? '').split(',').map((value) => value.trim()).filter(Boolean));
}

/** Compatibility is a response projection; stored per-slot rests never change. */
export function planForCapabilities(tree: PlanTree, capabilities: ReadonlySet<string>) {
  if (capabilities.has('groups')) return tree;
  return {
    ...tree,
    workouts: tree.workouts.map((day) => ({
      ...day,
      exercises: day.exercises.map((slot) => {
        const { group_id, group_rest_seconds, group_transition_seconds: _transition, ...ordinary } = slot;
        return { ...ordinary, rest_seconds: group_id ? group_rest_seconds ?? slot.rest_seconds : slot.rest_seconds };
      }),
    })),
  };
}

function groupLetter(index: number): string {
  let value = index + 1;
  let label = '';
  while (value > 0) {
    value--;
    label = String.fromCharCode(65 + value % 26) + label;
    value = Math.floor(value / 26);
  }
  return label;
}

/** Stable A1/A2 labels in the canonical slot order, local to each workout. */
export function coachGroupSlots(slots: EnrichedTemplateExercise[]) {
  const groups = new Map<string, { label: string; members: number }>();
  return slots.map((slot) => {
    if (!slot.group_id) return slot;
    let group = groups.get(slot.group_id);
    if (!group) {
      group = { label: groupLetter(groups.size), members: 0 };
      groups.set(slot.group_id, group);
    }
    group.members++;
    return { ...slot, group_label: `${group.label}${group.members}` };
  });
}

/** Every workout in the plan with coach-facing group labels on its slots. */
export function coachWorkouts(tree: PlanTree) {
  return tree.workouts.map((workout) => ({
    ...workout,
    exercises: coachGroupSlots(workout.exercises),
  }));
}

export function coachGroupSummary(slots: EnrichedTemplateExercise[]) {
  return coachGroupSlots(slots).filter((slot) => slot.group_id).map((slot) => ({
    template_exercise_id: slot.id,
    exercise: slot.exercise_name,
    group_id: slot.group_id,
    label: 'group_label' in slot ? slot.group_label : null,
    rounds: slot.target_sets,
    round_rest: slot.group_rest_seconds,
    transition_rest: slot.group_transition_seconds,
    is_warmup: slot.is_warmup,
  }));
}
