/**
 * One field-validation vocabulary for both write surfaces.
 *
 * `/api` bodies and MCP tool arguments are both untrusted JSON objects that
 * answer a bad value with the same `{ error: 'invalid_fields', fields }`
 * contract, so the rules and the required/optional sweep live here instead of
 * being re-derived per surface — the same reason data logic lives in `db.ts`.
 */
export type FieldRule = (value: unknown) => boolean;

/** Own-property test, so a parsed-JSON prototype key never counts as supplied. */
export const hasField = (body: Record<string, unknown>, field: string) =>
  Object.prototype.hasOwnProperty.call(body, field);

export const isNonEmptyString: FieldRule = (value) =>
  typeof value === 'string' && value.trim().length > 0;
export const isNonNegativeInteger: FieldRule = (value) =>
  Number.isSafeInteger(value) && (value as number) >= 0;
export const isPositiveInteger: FieldRule = (value) =>
  Number.isSafeInteger(value) && (value as number) > 0;

/** Return required or present optional fields whose runtime value is invalid. */
export function invalidFields(
  body: Record<string, unknown>,
  required: Record<string, FieldRule>,
  optional: Record<string, FieldRule> = {},
): string[] {
  const invalid: string[] = [];
  for (const [field, rule] of Object.entries(required)) {
    if (!hasField(body, field) || !rule(body[field])) invalid.push(field);
  }
  for (const [field, rule] of Object.entries(optional)) {
    if (hasField(body, field) && !rule(body[field])) invalid.push(field);
  }
  return invalid;
}
