// Idempotency marker for TestFlight feedback mirrored into GitHub issues.
// Shared by scripts/beta-feedback-to-issues.mjs and its unit test; kept free
// of node: imports so the test can load it under the Workers vitest pool.

/**
 * Matches the marker a mirrored feedback issue carries in its body. Two
 * syntaxes exist in the wild: this script's `<!-- asc-feedback:<id> -->` and
 * `<!-- ASC-ID: <id> -->` from an earlier mirror (filed under a different
 * label). Case-insensitive and whitespace-tolerant; capture group 1 is the
 * App Store Connect submission id.
 */
export const FEEDBACK_MARKER_RE = /<!--\s*(?:asc-feedback|asc-id)\s*:\s*([^\s>]+)\s*-->/i;

/** The ASC submission id an issue body carries, or null when unmarked. */
export function feedbackIdFromBody(body) {
  const m = FEEDBACK_MARKER_RE.exec(body || "");
  return m ? m[1] : null;
}
