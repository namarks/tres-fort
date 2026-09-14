import { describe, expect, it } from 'vitest';
import { FEEDBACK_MARKER_RE, feedbackIdFromBody } from '../scripts/beta-feedback-marker.mjs';

// The dedup scan in scripts/beta-feedback-to-issues.mjs must recognise the
// marker this mirror writes AND the one an earlier mirror wrote, or a re-run
// files duplicate issues for already-mirrored feedback.
describe('beta feedback issue marker', () => {
  it("matches this mirror's asc-feedback marker at the end of a body", () => {
    const body = '> comment\n\n---\n_Filed automatically._\n<!-- asc-feedback:1a2b-3c4d -->';
    expect(feedbackIdFromBody(body)).toBe('1a2b-3c4d');
  });

  it("matches the earlier mirror's ASC-ID marker, case-insensitively and with spaces", () => {
    expect(feedbackIdFromBody('<!-- ASC-ID: 0F1E2D -->')).toBe('0F1E2D');
    expect(feedbackIdFromBody('<!--asc-id:xyz-->')).toBe('xyz');
    expect(feedbackIdFromBody('<!-- Asc-Feedback : id9 -->')).toBe('id9');
  });

  it('returns null for bodies without a usable marker', () => {
    expect(feedbackIdFromBody(null)).toBeNull();
    expect(feedbackIdFromBody(undefined)).toBeNull();
    expect(feedbackIdFromBody('')).toBeNull();
    expect(feedbackIdFromBody('<!-- something-else: 1 -->')).toBeNull();
    expect(feedbackIdFromBody('<!-- asc-feedback: -->')).toBeNull();
  });

  it('is a non-global regex so repeated exec calls never skip a match', () => {
    expect(FEEDBACK_MARKER_RE.global).toBe(false);
    expect(FEEDBACK_MARKER_RE.exec('<!-- asc-feedback:a -->')?.[1]).toBe('a');
    expect(FEEDBACK_MARKER_RE.exec('<!-- asc-feedback:a -->')?.[1]).toBe('a');
  });
});
