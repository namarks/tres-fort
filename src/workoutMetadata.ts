/** Bounded member-authored labels, shared by REST, MCP and document writes. */
export function validWorkoutTags(value: unknown): value is string[] {
  return Array.isArray(value) && value.length <= 12 && value.every(tag =>
    typeof tag === 'string' && tag.trim().length > 0 && tag.trim().toLowerCase().length <= 32
      && !/[,\u0000-\u001f\u007f]/.test(tag));
}
export function normalizeWorkoutTags(tags: string[]): string {
  return JSON.stringify([...new Set(tags.map(tag => tag.trim().toLowerCase()))]);
}
export function validArchivedAt(value: unknown): value is number | null {
  return value === null || (typeof value === 'number' && Number.isSafeInteger(value) && value > 0);
}

/** Stable trigger reason, never returned with database details. */
export function isArchivedWorkoutAssignment(error: unknown): boolean {
  return error instanceof Error && error.message.includes('workout_archived_assignment');
}
