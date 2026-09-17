/** Retired identity fields must fail before a writer chooses a default workout
 * or interprets a missing tree as empty. Stored snapshots have separate readers. */
export function hasRetiredWorkoutFields(value: Record<string, unknown>): boolean {
  if (['days', 'day_template_id', 'plan_days'].some((key) => Object.hasOwn(value, key))) return true;
  const target = value.target;
  return target !== null && typeof target === 'object' && !Array.isArray(target)
    && Object.hasOwn(target, 'day_template_id');
}
