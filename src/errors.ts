/** Diagnostic categories are fixed values, never an Error's mutable name. */
export function diagnosticErrorType(error: unknown): string {
  if (error instanceof TypeError) return 'TypeError';
  if (error instanceof RangeError) return 'RangeError';
  if (error instanceof SyntaxError) return 'SyntaxError';
  return error instanceof Error ? 'Error' : 'unknown';
}

// These service failures describe caller-actionable conditions. Return only
// their fixed codes; unexpected database/provider errors stay internal.
const PUBLIC_TOOL_ERRORS = new Set([
  'no_active_plan',
  'plan_write_conflict',
  'session_not_found',
  'session_expected_attempt_missing',
  'set_undelete_unsupported',
  'set_correction_conflict',
  'invalid_adjustment',
]);

export function publicToolErrorCode(error: unknown): string | null {
  if (!(error instanceof Error)) return null;
  if (PUBLIC_TOOL_ERRORS.has(error.message)) return error.message;
  // Exercise lookup historically appended caller input. The code is enough
  // to explain the failure without reflecting arbitrary text into a response.
  if (error.message.startsWith('unknown_exercise:')) return 'unknown_exercise';
  return null;
}

export function logUnexpectedError(surface: 'http' | 'mcp_tool' | 'scheduled', error: unknown): void {
  console.error({
    event: 'unexpected_error',
    surface,
    error_type: diagnosticErrorType(error),
  });
}

export function internalErrorResponse(): Response {
  return Response.json({ error: 'internal', message: 'Something went wrong. Please try again.' }, { status: 500 });
}
