/** Stable SQLite RAISE() reason emitted when a pre-fence writer reaches D1. */
export const WORKOUT_WRITE_FENCE_ACTIVE = 'workout_write_fence_active';
export const WORKOUT_WRITE_FENCE_NOT_ACTIVE = 'workout_write_fence_not_active';

/**
 * Returns true for the D1 exception raised by the database cutover fence.
 * Callers may use this to translate the failure into their retryable transport
 * shape without hiding unrelated database errors.
 */
export function isWorkoutWriteFenceActiveError(error: unknown): boolean {
  return error instanceof Error && error.message.includes(WORKOUT_WRITE_FENCE_ACTIVE);
}

/** Matches either side of the cutover: premature v1 or an unpermitted write. */
export function isWorkoutWriteFenceError(error: unknown): boolean {
  return (
    error instanceof Error &&
    (error.message.includes(WORKOUT_WRITE_FENCE_ACTIVE) ||
      error.message.includes(WORKOUT_WRITE_FENCE_NOT_ACTIVE))
  );
}

/** Protocol-v1 admission opens only at the irreversible database cutover. */
export async function isWorkoutWriteFenceEnabled(
  db: D1Database,
): Promise<boolean> {
  const row = await db
    .prepare('SELECT enabled FROM workout_write_fence WHERE id = 1')
    .first<{ enabled: number }>();
  return row?.enabled === 1;
}

/**
 * Execute session/set mutations under the database's transaction-local
 * workout-write permit.
 *
 * Cloudflare D1 batches are SQL transactions: statements execute sequentially
 * and a failure rolls the whole sequence back.  The singleton permit therefore
 * exists only while the protected statements execute and cannot leak if one of
 * them fails.  Concurrent batches serialize on the singleton insert.
 */
export async function runWorkoutWriteBatch<T = Record<string, unknown>>(
  db: D1Database,
  statements: readonly D1PreparedStatement[],
): Promise<D1Result<T>[]> {
  if (statements.length === 0) return [];

  const results = await db.batch<T>([
    db.prepare('INSERT INTO workout_write_permit (id) VALUES (1)'),
    ...statements,
    db.prepare('DELETE FROM workout_write_permit WHERE id = 1'),
  ]);

  return results.slice(1, -1);
}

/** Execute one protected statement while preserving its typed D1 result. */
export async function runWorkoutWriteStatement<T = Record<string, unknown>>(
  db: D1Database,
  statement: D1PreparedStatement,
): Promise<D1Result<T>> {
  const [result] = await runWorkoutWriteBatch<T>(db, [statement]);
  if (!result) throw new Error('workout_write_batch_missing_result');
  return result;
}
