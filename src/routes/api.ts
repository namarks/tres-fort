import { Hono } from 'hono';
import type { Context } from 'hono';
import type { HonoEnv } from '../types';
import { requireAppJwt } from '../auth';
import { appleProviderConfig } from '../apple';
import {
  accountDeletionContinuationMatches,
  addDayTemplateAtVersion,
  addTemplateExercise,
  createGroup,
  createInvite,
  createPlan,
  deleteDayTemplate,
  deleteUserAccount,
  deleteTemplateExercise,
  discardSession,
  exportUserData,
  getActivePlan,
  getExercises,
  getGroupActivitySeries,
  getGroupFeed,
  getGroupStats,
  getInvitePreview,
  getMeProfile,
  getGroupWithMembers,
  getHistory,
  getOrCreateSession,
  getOwnedSessionByDate,
  getDayTemplateInPlan,
  getPlanTree,
  getState,
  getUserTimezone,
  getVolume,
  isGroupMember,
  isAccountDeletionKey,
  leaveGroup,
  listGroupsForUser,
  logActivity,
  logSet,
  nextDayOrderIndex,
  nextExerciseOrderIndex,
  patchDayTemplateAtVersion,
  patchSession,
  patchSet,
  redeemInvite,
  resolveExercise,
  setPlanSchedule,
  setPlannedSession,
  skipPlannedSession,
  setGroupDisplayName,
  setUserDisplayName,
  setUserIntervalsCreds,
  setUserMcpPassphrase,
  setHealthActivitySharing,
  softDeleteActivity,
  reviveDiscardedSession,
  SessionWriteConflictError,
  todayInTz,
  updateExercise,
  upsertHealthKitActivity,
  writeAudit,
  ensureActivePlan,
} from '../db';
import { isWorkoutWriteFenceEnabled } from '../workout-write-fence';
import type { Weekday } from '../types';

export const apiRoutes = new Hono<HonoEnv>();
apiRoutes.use('*', requireAppJwt);

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ISO_DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
// Initial account deletion is too destructive to authorize with a bearer that
// may have been rolling for months. A matching durable intent or receipt is
// exempt so provider interruption cannot strand an already-authorized delete.
const ACCOUNT_DELETION_RECENT_AUTH_SECONDS = 5 * 60;

type JsonObject = Record<string, unknown>;
type FieldRule = (value: unknown) => boolean;

const hasOwn = (body: JsonObject, field: string) =>
  Object.prototype.hasOwnProperty.call(body, field);
const isNonEmptyString: FieldRule = (value) =>
  typeof value === 'string' && value.trim().length > 0;
const isFiniteNumber: FieldRule = (value) =>
  typeof value === 'number' && Number.isFinite(value);
const isNonNegativeInteger: FieldRule = (value) =>
  Number.isSafeInteger(value) && (value as number) >= 0;
const isPositiveInteger: FieldRule = (value) =>
  Number.isSafeInteger(value) && (value as number) > 0;
const isNullableString: FieldRule = (value) =>
  value === null || typeof value === 'string';
const isNullableFiniteNumber: FieldRule = (value) =>
  value === null || isFiniteNumber(value);
const isNullableNonNegativeInteger: FieldRule = (value) =>
  value === null || isNonNegativeInteger(value);

/**
 * JSON generics only describe a body to TypeScript; they do not validate the
 * bytes a client actually sent. Keep the four session/set mutation routes on
 * one stable error contract before any value reaches D1.
 */
async function readMutationBody(
  c: Context<HonoEnv>,
): Promise<
  | { ok: true; body: JsonObject }
  | { ok: false; error: 'invalid_json' | 'invalid_body' }
> {
  let value: unknown;
  try {
    value = await c.req.json<unknown>();
  } catch {
    return { ok: false, error: 'invalid_json' };
  }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    return { ok: false, error: 'invalid_body' };
  }
  return { ok: true, body: value as JsonObject };
}

/** Return required or present optional fields whose runtime value is invalid. */
function invalidMutationFields(
  body: JsonObject,
  required: Record<string, FieldRule>,
  optional: Record<string, FieldRule> = {},
): string[] {
  const invalid: string[] = [];
  for (const [field, rule] of Object.entries(required)) {
    if (!hasOwn(body, field) || !rule(body[field])) invalid.push(field);
  }
  for (const [field, rule] of Object.entries(optional)) {
    if (hasOwn(body, field) && !rule(body[field])) invalid.push(field);
  }
  return invalid;
}

function readExpectedAttemptQuery(
  c: Context<HonoEnv>,
): { ok: true; value?: number } | { ok: false } {
  const raw = c.req.query('expected_attempt');
  if (raw === undefined) return { ok: true };
  if (raw.trim() === '') return { ok: false };
  const value = Number(raw);
  return isNonNegativeInteger(value)
    ? { ok: true, value }
    : { ok: false };
}

function readAttemptProtocolHeader(
  c: Context<HonoEnv>,
): { ok: true; declared: boolean } | { ok: false } {
  const raw = c.req.header('X-TresFort-Write-Protocol');
  if (raw === undefined) return { ok: true, declared: false };
  return raw.trim().toLowerCase() === 'attempt-v1'
    ? { ok: true, declared: true }
    : { ok: false };
}

const protocolConflictBody = <T extends { status: string; attempt: number }>(
  session: T,
) => ({
  error: 'session_attempt_required' as const,
  status: session.status,
  current_attempt: session.attempt,
  current_session: session,
});

async function inactiveAttemptProtocolResponse(
  c: Context<HonoEnv>,
  declared: boolean,
): Promise<Response | null> {
  if (!declared || (await isWorkoutWriteFenceEnabled(c.env.DB))) return null;
  // The compatibility Worker is live but the irreversible database cutover
  // has not been activated yet. New-app intents are durable/retryable; make
  // the temporary admission boundary explicit instead of surfacing a D1 500.
  c.header('Retry-After', '5');
  return c.json(
    {
      error: 'write_protocol_not_active',
      protocol: 'attempt-v1',
      retryable: true,
    },
    503,
  );
}

// ---- sync pull -----------------------------------------------------------
// Device timezone (X-Device-TZ) is captured for EVERY authenticated request
// in the requireAppJwt middleware, so it stays fresh even on non-/state
// actions after the user travels — not handled here anymore.
apiRoutes.get('/state', async (c) => {
  const userId = c.get('userId');
  const since = Number(c.req.query('since') ?? 0);
  const setsSince = Number(c.req.query('sets_since') ?? 0);
  const eventsSince = Number(c.req.query('events_since') ?? 0);
  const activitiesSince = Number(c.req.query('activities_since') ?? 0);
  // log_since gates the M3 generic activity log delta (separate cursor —
  // `activities_since` is already taken by the intervals.icu external
  // actuals cache, see migration 0015 / getState).
  const logSince = Number(c.req.query('log_since') ?? 0);
  return c.json(
    await getState(c.env.DB, userId, since, setsSince, eventsSince, activitiesSince, logSince),
  );
});

// ---- plan tree -----------------------------------------------------------
apiRoutes.get('/plan/active', async (c) => {
  const tree = await getPlanTree(c.env.DB, c.get('userId'));
  return tree ? c.json(tree) : c.json({ error: 'no_active_plan' }, 404);
});

// Idempotent manual-authoring bootstrap. This route deliberately does not use
// createPlan: a retry or concurrent coach write must return the active winner,
// never archive it.
apiRoutes.put('/plan/active', async (c) => {
  const parsed = await readMutationBody(c);
  if (!parsed.ok) return c.json({ error: parsed.error }, 400);
  const invalid = invalidMutationFields(parsed.body, { name: isNonEmptyString });
  if (invalid.length > 0) return c.json({ error: 'invalid_fields', fields: invalid }, 400);
  const userId = c.get('userId');
  const result = await ensureActivePlan(c.env.DB, userId, String(parsed.body.name).trim());
  await writeAudit(
    c.env.DB,
    userId,
    'ensure_active_plan',
    { name: parsed.body.name },
    JSON.stringify({ id: result.plan.id, created: result.created }),
    'ios',
  );
  return c.json(result, result.created ? 201 : 200);
});

apiRoutes.post('/plan', async (c) => {
  const b = await c.req.json<{ name: string; meta?: unknown }>();
  if (!b.name) return c.json({ error: 'missing_name' }, 400);
  return c.json(await createPlan(c.env.DB, c.get('userId'), b.name, b.meta ?? null), 201);
});

apiRoutes.post('/days', async (c) => {
  const userId = c.get('userId');
  const plan = await getActivePlan(c.env.DB, userId);
  if (!plan) return c.json({ error: 'no_active_plan' }, 400);
  const parsed = await readMutationBody(c);
  if (!parsed.ok) return c.json({ error: parsed.error }, 400);
  const b = parsed.body;
  const invalid = invalidMutationFields(
    b,
    { name: isNonEmptyString },
    {
      day_label: isNullableString,
      order_index: isNonNegativeInteger,
      expected_plan_id: isNonEmptyString,
      expected_version: isPositiveInteger,
    },
  );
  if (invalid.length > 0) return c.json({ error: 'invalid_fields', fields: invalid }, 400);
  if (hasOwn(b, 'expected_plan_id') && b.expected_plan_id !== plan.id) {
    return c.json({ conflict: true, current_plan_id: plan.id, current_version: plan.version }, 409);
  }
  if (hasOwn(b, 'expected_version') && b.expected_version !== plan.version) {
    return c.json({ conflict: true, current_version: plan.version }, 409);
  }
  const orderIndex = hasOwn(b, 'order_index')
    ? Number(b.order_index)
    : await nextDayOrderIndex(c.env.DB, plan.id);
  const row = await addDayTemplateAtVersion(
    c.env.DB,
    userId,
    plan,
    String(b.name).trim(),
    typeof b.day_label === 'string' ? b.day_label : null,
    orderIndex,
  );
  if ('conflict' in row) return c.json(row, 409);
  await writeAudit(
    c.env.DB,
    userId,
    'add_day',
    {
      name: b.name,
      day_label: b.day_label ?? null,
      order_index: orderIndex,
      expected_plan_id: b.expected_plan_id ?? null,
    },
    row.id,
    'ios',
  );
  return c.json(row, 201);
});

apiRoutes.patch('/days/:id', async (c) => {
  const userId = c.get('userId');
  const plan = await getActivePlan(c.env.DB, userId);
  if (!plan) return c.json({ error: 'no_active_plan' }, 400);
  const parsed = await readMutationBody(c);
  if (!parsed.ok) return c.json({ error: parsed.error }, 400);
  const b = parsed.body;
  const invalid = invalidMutationFields(
    b,
    {},
    {
      name: isNonEmptyString,
      day_label: isNullableString,
      order_index: isNonNegativeInteger,
      notes: isNullableString,
      expected_version: isPositiveInteger,
    },
  );
  if (invalid.length > 0) return c.json({ error: 'invalid_fields', fields: invalid }, 400);
  if (hasOwn(b, 'expected_version') && b.expected_version !== plan.version) {
    return c.json({ conflict: true, current_version: plan.version }, 409);
  }
  const { expected_version: _expectedVersion, ...patch } = b;
  const row = await patchDayTemplateAtVersion(
    c.env.DB, userId, plan, c.req.param('id'), patch,
  );
  if (!row) return c.json({ error: 'not_found' }, 404);
  if ('conflict' in row) return c.json(row, 409);
  if ('error' in row) return c.json(row, 400);
  await writeAudit(
    c.env.DB,
    userId,
    'update_day',
    { day_template_id: c.req.param('id'), patch },
    row.id,
    'ios',
  );
  return c.json(row);
});

apiRoutes.delete('/days/:id', async (c) => {
  const userId = c.get('userId');
  const plan = await getActivePlan(c.env.DB, userId);
  if (!plan) return c.json({ error: 'no_active_plan' }, 400);
  const rawExpected = c.req.query('expected_version');
  if (rawExpected !== undefined) {
    const expected = Number(rawExpected);
    if (!isPositiveInteger(expected)) {
      return c.json({ error: 'invalid_fields', fields: ['expected_version'] }, 400);
    }
    if (expected !== plan.version) {
      return c.json({ conflict: true, current_version: plan.version }, 409);
    }
  }
  const dayId = c.req.param('id');
  const result = await deleteDayTemplate(c.env.DB, userId, dayId, plan.version);
  if ('conflict' in result) return c.json(result, 409);
  if ('error' in result && result.error === 'day_in_progress') {
    return c.json(result, 409);
  }
  if ('error' in result) return c.json({ error: 'not_found' }, 404);
  await writeAudit(
    c.env.DB,
    userId,
    'delete_day',
    { day_template_id: dayId },
    JSON.stringify(result),
    'ios',
  );
  return c.json(result);
});

apiRoutes.put('/plan/schedule', async (c) => {
  const parsed = await readMutationBody(c);
  if (!parsed.ok) return c.json({ error: parsed.error }, 400);
  const b = parsed.body;
  const invalid = invalidMutationFields(
    b,
    { week: (value) => value !== null && typeof value === 'object' && !Array.isArray(value) },
    {
      expected_plan_id: isNonEmptyString,
      expected_version: isPositiveInteger,
    },
  );
  if (invalid.length > 0) return c.json({ error: 'invalid_fields', fields: invalid }, 400);
  const week = b.week as Record<string, unknown>;
  const badKeys = Object.keys(week).filter(
    (key) => !['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'].includes(key),
  );
  const badValues = Object.entries(week)
    .filter(([, value]) => value !== null && typeof value !== 'string')
    .map(([key]) => key);
  if (badKeys.length > 0 || badValues.length > 0) {
    return c.json({ error: 'invalid_fields', fields: [...new Set([...badKeys, ...badValues])] }, 400);
  }
  const userId = c.get('userId');
  const result = await setPlanSchedule(
    c.env.DB,
    userId,
    week as Partial<Record<Weekday, string | null>>,
    typeof b.expected_version === 'number' ? b.expected_version : null,
    typeof b.expected_plan_id === 'string' ? b.expected_plan_id : null,
  );
  if ('conflict' in result) return c.json(result, 409);
  if ('error' in result) return c.json(result, 400);
  await writeAudit(c.env.DB, userId, 'set_schedule', { week }, JSON.stringify(result), 'ios');
  return c.json(result);
});

// One concrete date only. `day_template_id: null` means rest; either branch
// mutates sessions and deliberately leaves the recurring schedule/version
// untouched.
apiRoutes.put('/calendar/:date', async (c) => {
  const date = c.req.param('date');
  if (!ISO_DATE_RE.test(date)) return c.json({ error: 'invalid_date' }, 400);
  const parsed = await readMutationBody(c);
  if (!parsed.ok) return c.json({ error: parsed.error }, 400);
  const b = parsed.body;
  const invalid = invalidMutationFields(
    b,
    { day_template_id: (value) => value === null || isNonEmptyString(value) },
    { expected_attempt: isNonNegativeInteger },
  );
  if (invalid.length > 0) return c.json({ error: 'invalid_fields', fields: invalid }, 400);
  const userId = c.get('userId');
  // Attempt zero is the explicit absence token for released clients that did
  // not yet send the field. The first assignment persists as attempt one.
  const expectedAttempt = typeof b.expected_attempt === 'number' ? b.expected_attempt : 0;
  const isRest = b.day_template_id === null;
  const result = isRest
    ? await skipPlannedSession(c.env.DB, userId, date, expectedAttempt)
    : await setPlannedSession(c.env.DB, userId, date, String(b.day_template_id), expectedAttempt);
  if ('conflict' in result) return c.json(result, 409);
  if ('error' in result) {
    const conflict = result.error === 'session_attempt_conflict'
      || result.error === 'session_attempt_missing'
      || result.error === 'session_state_conflict'
      || result.error === 'session_already_started';
    return c.json(result, conflict ? 409 : 400);
  }
  await writeAudit(
    c.env.DB,
    userId,
    isRest ? 'skip_planned_session' : 'set_planned_session',
    { date, day_template_id: b.day_template_id },
    result.session.id,
    'ios',
  );
  return c.json(result);
});

apiRoutes.post('/days/:id/exercises', async (c) => {
  const userId = c.get('userId');
  const plan = await getActivePlan(c.env.DB, userId);
  if (!plan) return c.json({ error: 'no_active_plan' }, 400);
  const dayId = c.req.param('id');
  // Resolve the nested day through THIS user's active plan before resolving
  // the exercise or computing order. A globally-valid day from another user
  // or one of this user's archived plans is intentionally indistinguishable
  // from a missing day and can never receive a slot or bump the active plan.
  const day = await getDayTemplateInPlan(c.env.DB, plan.id, dayId);
  if (!day) return c.json({ error: 'not_found' }, 404);
  const b = await c.req.json<{
    exercise: string;
    order_index?: number;
    target_sets: number;
    target_reps: number;
    target_reps_max?: number | null;
    target_rpe?: number | null;
    rest_seconds?: number;
    target_weight?: number | null;
    target_duration_s?: number | null;
    progression?: unknown;
    cues?: string | null;
    is_warmup?: boolean;
  }>();
  const ex = await resolveExercise(c.env.DB, b.exercise);
  if (!ex) return c.json({ error: 'unknown_exercise', query: b.exercise }, 400);
  const orderIndex =
    typeof b.order_index === 'number'
      ? b.order_index
      : await nextExerciseOrderIndex(c.env.DB, dayId);
  const row = await addTemplateExercise(c.env.DB, plan.id, {
    day_template_id: dayId,
    exercise_id: (ex as { id: string }).id,
    order_index: orderIndex,
    target_sets: b.target_sets,
    target_reps: b.target_reps,
    target_reps_max: b.target_reps_max ?? null,
    target_rpe: b.target_rpe ?? null,
    rest_seconds: b.rest_seconds ?? 120,
    target_weight: b.target_weight ?? null,
    target_duration_s: b.target_duration_s ?? null,
    progression: b.progression == null ? null : JSON.stringify(b.progression),
    cues: b.cues ?? null,
    is_warmup: b.is_warmup ? 1 : 0,
  });
  // Audit the in-app plan edit (actor='ios') so the trust/undo trail covers
  // app-side mutations the same as MCP ones (DESIGN §5).
  await writeAudit(
    c.env.DB,
    userId,
    'add_exercise',
    { day_template_id: dayId, exercise: b.exercise, is_warmup: !!b.is_warmup },
    row.id,
    'ios',
  );
  return c.json(row, 201);
});

// Edit one exercise slot in place (targets / rest / warm-up flag / order).
// Thin wrapper over the same updateExercise the MCP `update_exercise` tool
// uses, scoped to this user. Version-bumped + audited (actor='ios'). The slot
// is scoped to the URL :id day: a stale/mismatched client patching
// /days/<dayA>/exercises/<slot-from-dayB> resolves to null → 404 instead of
// mutating the wrong day's workout.
apiRoutes.patch('/days/:id/exercises/:teId', async (c) => {
  const userId = c.get('userId');
  const dayId = c.req.param('id');
  const teId = c.req.param('teId');
  const b = await c.req.json<{
    target_sets?: number;
    target_reps?: number;
    target_reps_max?: number | null;
    target_rpe?: number | null;
    rest_seconds?: number;
    target_weight?: number | null;
    target_duration_s?: number | null;
    cues?: string | null;
    progression?: unknown;
    order_index?: number;
    is_warmup?: boolean;
  }>();
  const patch: Record<string, unknown> = { ...b };
  if (typeof b.is_warmup === 'boolean') patch.is_warmup = b.is_warmup ? 1 : 0;
  const row = await updateExercise(c.env.DB, userId, { template_exercise_id: teId, day_template_id: dayId }, patch);
  if (!row) return c.json({ error: 'not_found' }, 404);
  if ('error' in row) return c.json(row, 400);
  await writeAudit(c.env.DB, userId, 'update_exercise', { template_exercise_id: teId, patch: b }, row.id, 'ios');
  return c.json(row);
});

// Remove one exercise slot from a day. Detaches (NULLs) any historical
// set_logs.template_exercise_id rather than deleting logged work. Version-
// bumped + audited. Scoped to the URL :id day (see the PATCH above): a slot
// from another day resolves to null → 404, never deleting the wrong exercise.
apiRoutes.delete('/days/:id/exercises/:teId', async (c) => {
  const userId = c.get('userId');
  const dayId = c.req.param('id');
  const teId = c.req.param('teId');
  const row = await deleteTemplateExercise(c.env.DB, userId, { template_exercise_id: teId, day_template_id: dayId });
  if (!row) return c.json({ error: 'not_found' }, 404);
  await writeAudit(c.env.DB, userId, 'delete_exercise', { template_exercise_id: teId }, row.id, 'ios');
  return c.json(row);
});

// ---- sessions + sets -----------------------------------------------------
apiRoutes.get('/today', async (c) => {
  const userId = c.get('userId');
  const plan = await getActivePlan(c.env.DB, userId);
  if (!plan) return c.json({ error: 'no_active_plan' }, 400);
  const date = todayInTz(await getUserTimezone(c.env.DB, userId));
  const session = await getOrCreateSession(
    c.env.DB,
    userId,
    plan.id,
    date,
    null,
    // Compatibility read/start: the released app's date resolver had implicit
    // restart semantics. It may revive only a legacy generation; the DB helper
    // leaves an attempt-v1 tombstone untouched.
    { reviveDiscarded: true },
  );
  const sets = await c.env.DB
    .prepare('SELECT * FROM set_logs WHERE session_id = ?1 AND deleted_at IS NULL ORDER BY logged_at')
    .bind(session.id)
    .all();
  return c.json({ session, sets: sets.results });
});

apiRoutes.post('/sessions', async (c) => {
  const userId = c.get('userId');
  const plan = await getActivePlan(c.env.DB, userId);
  if (!plan) return c.json({ error: 'no_active_plan' }, 400);
  const parsed = await readMutationBody(c);
  if (!parsed.ok) return c.json({ error: parsed.error }, 400);
  const b = parsed.body;
  const protocolHeader = readAttemptProtocolHeader(c);
  if (!protocolHeader.ok) return c.json({ error: 'invalid_write_protocol' }, 400);
  const invalid = invalidMutationFields(b, {}, {
    date: (value) => typeof value === 'string' && ISO_DATE_RE.test(value),
    day_template_id: (value) => value === null || isNonEmptyString(value),
    restart_discarded: (value) => typeof value === 'boolean',
    expected_attempt: isNonNegativeInteger,
  });
  if (invalid.length > 0) return c.json({ error: 'invalid_fields', fields: invalid }, 400);
  const carriesAttemptProtocol =
    protocolHeader.declared ||
    hasOwn(b, 'expected_attempt') ||
    hasOwn(b, 'restart_discarded');
  if (carriesAttemptProtocol && !hasOwn(b, 'expected_attempt')) {
    return c.json({ error: 'invalid_fields', fields: ['expected_attempt'] }, 400);
  }
  const restartDiscarded = b.restart_discarded === true;
  if (restartDiscarded && !hasOwn(b, 'expected_attempt')) {
    return c.json(
      {
        error: 'invalid_fields',
        fields: ['expected_attempt'],
      },
      400,
    );
  }
  const inactiveProtocol = await inactiveAttemptProtocolResponse(
    c,
    protocolHeader.declared,
  );
  if (inactiveProtocol) return inactiveProtocol;
  const date =
    typeof b.date === 'string'
      ? b.date
      : todayInTz(await getUserTimezone(c.env.DB, userId));
  const dayTemplateId =
    (b.day_template_id as string | null | undefined) ?? null;
  // An offline intent may retain a day UUID that update_plan has since
  // rebuilt away. Resolve the optional pin through this user's active plan
  // before it reaches the sessions FK, both to keep tenant/plan boundaries
  // closed and to give iOS a stable permanent-client-error fallback.
  if (
    dayTemplateId !== null &&
    !(await getDayTemplateInPlan(c.env.DB, plan.id, dayTemplateId))
  ) {
    return c.json({ error: 'unknown_day' }, 422);
  }
  let s;
  if (restartDiscarded) {
    const expectedAttempt = b.expected_attempt as number;
    const existing = await getOwnedSessionByDate(c.env.DB, userId, date);
    if (!existing) {
      return c.json(
        { error: 'restart_target_missing', expected_attempt: expectedAttempt },
        409,
      );
    }
    // The helper also handles a commit-then-timeout retry whose next
    // generation is already live. That matters during migration-first
    // rollout: the old Worker may have performed the restart and migration
    // 0032's trigger advanced the attempt while leaving the row `legacy`.
    // The first attempt-aware retry must claim that winner atomically before
    // returning it, so later tokenless writes are fenced out.
    const revived = await reviveDiscardedSession(
      c.env.DB,
      userId,
      existing.id,
      expectedAttempt,
      dayTemplateId,
      protocolHeader.declared,
    );
    if (!revived) return c.json({ error: 'not_found' }, 404);
    if ('error' in revived) return c.json(revived, 409);
    s = revived;
  } else {
    const expectedAttempt = carriesAttemptProtocol
      ? (b.expected_attempt as number)
      : undefined;
    if (expectedAttempt !== undefined && expectedAttempt > 0) {
      const existing = await getOwnedSessionByDate(c.env.DB, userId, date);
      if (!existing) {
        return c.json(
          {
            error: 'session_attempt_missing',
            expected_attempt: expectedAttempt,
          },
          409,
        );
      }
    }
    try {
      s = await getOrCreateSession(
        c.env.DB,
        userId,
        plan.id,
        date,
        dayTemplateId,
        {
          reviveDiscarded: !carriesAttemptProtocol,
          expectedAttempt,
          claimAttemptProtocol: protocolHeader.declared,
        },
      );
    } catch (error) {
      if ((error as Error).message === 'session_expected_attempt_missing') {
        return c.json(
          {
            error: 'session_attempt_missing',
            expected_attempt: expectedAttempt,
          },
          409,
        );
      }
      throw error;
    }
  }
  if (!carriesAttemptProtocol && s.write_protocol !== 'legacy') {
    return c.json(protocolConflictBody(s), 409);
  }
  if (!restartDiscarded && s.status === 'discarded') {
    return c.json(
      { error: 'session_discarded', status: 'discarded', current_session: s },
      409,
    );
  } else if (
    !restartDiscarded &&
    carriesAttemptProtocol &&
    s.attempt !== (b.expected_attempt as number)
  ) {
    const expectedAttempt = b.expected_attempt as number;
    return c.json(
      {
        error: 'session_attempt_conflict',
        status: s.status,
        expected_attempt: expectedAttempt,
        current_attempt: s.attempt,
        current_session: s,
      },
      409,
    );
  }
  return c.json(s, 201);
});

apiRoutes.patch('/sessions/:id', async (c) => {
  const protocolHeader = readAttemptProtocolHeader(c);
  if (!protocolHeader.ok) return c.json({ error: 'invalid_write_protocol' }, 400);
  const expected = readExpectedAttemptQuery(c);
  if (!expected.ok) {
    return c.json({ error: 'invalid_fields', fields: ['expected_attempt'] }, 400);
  }
  if (protocolHeader.declared && expected.value === undefined) {
    return c.json({ error: 'invalid_fields', fields: ['expected_attempt'] }, 400);
  }
  const parsed = await readMutationBody(c);
  if (!parsed.ok) return c.json({ error: parsed.error }, 400);
  const b = parsed.body;
  const invalid = invalidMutationFields(b, {}, {
    // status remains deliberately `unknown`: patchSession owns its closed
    // status allowlist and stable invalid_status response.
    perceived_fatigue: isNonNegativeInteger,
    notes: (value) => typeof value === 'string',
    day_template_id: (value) => value === null || isNonEmptyString(value),
  });
  if (
    hasOwn(b, 'day_template_id') &&
    !(typeof b.status === 'string' && b.status.trim().toLowerCase() === 'planned')
  ) {
    invalid.push('day_template_id');
  }
  if (invalid.length > 0) return c.json({ error: 'invalid_fields', fields: invalid }, 400);
  const inactiveProtocol = await inactiveAttemptProtocolResponse(
    c,
    protocolHeader.declared,
  );
  if (inactiveProtocol) return inactiveProtocol;
  if (typeof b.day_template_id === 'string') {
    const plan = await getActivePlan(c.env.DB, c.get('userId'));
    if (!plan || !(await getDayTemplateInPlan(c.env.DB, plan.id, b.day_template_id))) {
      return c.json({ error: 'unknown_day' }, 422);
    }
  }
  const s = await patchSession(
    c.env.DB,
    c.get('userId'),
    c.req.param('id'),
    b,
    expected.value,
    protocolHeader.declared,
  );
  if (!s) return c.json({ error: 'not_found' }, 404);
  if ('error' in s) {
    // Exhaustive: invalid_status → 400 (bad request, nothing persisted);
    // the history-integrity and discarded-terminal guards → 409.
    if (s.error === 'invalid_status') return c.json(s, 400);
    return c.json(s, 409);
  }
  return c.json(s);
});

// Discard a session — "I didn't really do this." Soft-deletes its sets
// and marks it 'discarded' (vanishes from the projection; excluded from
// history/volume/conflicts). Idempotent. Restarting the same date requires
// the explicit attempt-scoped POST /sessions restart protocol.
apiRoutes.post('/sessions/:id/discard', async (c) => {
  const protocolHeader = readAttemptProtocolHeader(c);
  if (!protocolHeader.ok) return c.json({ error: 'invalid_write_protocol' }, 400);
  const expected = readExpectedAttemptQuery(c);
  if (!expected.ok) {
    return c.json({ error: 'invalid_fields', fields: ['expected_attempt'] }, 400);
  }
  if (protocolHeader.declared && expected.value === undefined) {
    return c.json({ error: 'invalid_fields', fields: ['expected_attempt'] }, 400);
  }
  const inactiveProtocol = await inactiveAttemptProtocolResponse(
    c,
    protocolHeader.declared,
  );
  if (inactiveProtocol) return inactiveProtocol;
  const s = await discardSession(
    c.env.DB,
    c.get('userId'),
    c.req.param('id'),
    expected.value,
    protocolHeader.declared,
  );
  if (!s) return c.json({ error: 'not_found' }, 404);
  if ('error' in s) return c.json(s, 409);
  return c.json(s);
});

apiRoutes.post('/sessions/:id/sets', async (c) => {
  const protocolHeader = readAttemptProtocolHeader(c);
  if (!protocolHeader.ok) return c.json({ error: 'invalid_write_protocol' }, 400);
  const parsed = await readMutationBody(c);
  if (!parsed.ok) return c.json({ error: parsed.error }, 400);
  const b = parsed.body;
  // Preserve the established missing-id response while using invalid_fields
  // for a present id (or any other field) with the wrong runtime shape.
  if (!hasOwn(b, 'id')) return c.json({ error: 'missing_set_id' }, 400);
  const invalid = invalidMutationFields(
    b,
    {
      id: (value) => typeof value === 'string' && UUID_RE.test(value),
      exercise_id: isNonEmptyString,
      set_index: isPositiveInteger,
      weight: isFiniteNumber,
      reps: isNonNegativeInteger,
    },
    {
      rpe: isNullableFiniteNumber,
      is_warmup: (value) => typeof value === 'boolean',
      template_exercise_id: (value) => value === null || isNonEmptyString(value),
      notes: isNullableString,
      logged_at: isNonNegativeInteger,
      duration_s: isNullableNonNegativeInteger,
      is_timed: (value) => typeof value === 'boolean',
      expected_attempt: isNonNegativeInteger,
    },
  );
  if (invalid.length > 0) return c.json({ error: 'invalid_fields', fields: invalid }, 400);
  if (protocolHeader.declared && !hasOwn(b, 'expected_attempt')) {
    return c.json({ error: 'invalid_fields', fields: ['expected_attempt'] }, 400);
  }
  const inactiveProtocol = await inactiveAttemptProtocolResponse(
    c,
    protocolHeader.declared,
  );
  if (inactiveProtocol) return inactiveProtocol;
  try {
    const result = await logSet(c.env.DB, c.get('userId'), {
      id: b.id as string,
      session_id: c.req.param('id'),
      exercise_id: b.exercise_id as string,
      template_exercise_id: b.template_exercise_id as string | null | undefined,
      set_index: b.set_index as number,
      weight: b.weight as number,
      reps: b.reps as number,
      rpe: b.rpe as number | null | undefined,
      is_warmup: b.is_warmup as boolean | undefined,
      notes: b.notes as string | null | undefined,
      logged_at: b.logged_at as number | undefined,
      duration_s: b.duration_s as number | null | undefined,
      is_timed: b.is_timed as boolean | undefined,
      expected_attempt: b.expected_attempt as number | undefined,
      claim_attempt_protocol: protocolHeader.declared,
      source: 'ios',
    });
    return c.json(result, result.deduped ? 200 : 201);
  } catch (e) {
    if (e instanceof SessionWriteConflictError) {
      return c.json(e.response(), 409);
    }
    const error = (e as Error).message;
    return c.json(
      { error },
      error === 'session_discarded' || error === 'session_attempt_conflict'
        ? 409
        : 404,
    );
  }
});

apiRoutes.patch('/sets/:id', async (c) => {
  const parsed = await readMutationBody(c);
  if (!parsed.ok) return c.json({ error: parsed.error }, 400);
  const b = parsed.body;
  const allowed = new Set(['weight', 'reps', 'rpe', 'notes', 'duration_s', 'deleted']);
  const invalid = invalidMutationFields(b, {}, {
    weight: isFiniteNumber,
    reps: isNonNegativeInteger,
    rpe: isNullableFiniteNumber,
    notes: isNullableString,
    duration_s: isNullableNonNegativeInteger,
    // Tombstones are intentionally one-way. Reanimating an old row after its
    // session was discarded/restarted would attach prior-attempt work to the
    // current history without an attempt token.
    deleted: (value) => value === true,
  });
  invalid.push(...Object.keys(b).filter((field) => !allowed.has(field)));
  if (invalid.length > 0) return c.json({ error: 'invalid_fields', fields: invalid }, 400);
  if (Object.keys(b).length === 0) return c.json({ error: 'no_corrections' }, 400);
  const row = await patchSet(c.env.DB, c.get('userId'), c.req.param('id'), b);
  return row ? c.json(row) : c.json({ error: 'not_found' }, 404);
});

// ---- read models ---------------------------------------------------------
apiRoutes.get('/exercises', async (c) => {
  // Funnel through getExercises so the wire shape matches MCP's
  // list_exercises — in particular, `laterality` rides along, which iOS
  // needs to compute per-side/per-hand rollups (two-DB Bulgarian split squat
  // 45×8 → 16 reps / 1,440 lb instead of 8 / 360).
  return c.json(await getExercises(c.env.DB));
});

// Demo image proxy. iOS first checks its bundled asset catalog for the
// foundational lifts; misses fall through to here, which pulls the frame
// from the R2 bucket and returns it with a long-immutable Cache-Control
// (slug + frame are content-addressed: when an upstream image changes
// it ships under a new slug). Stays inside /api/* so the existing JWT
// gate covers it — these are public-domain assets, but routing them
// through the same auth surface keeps the worker config simple. The
// route 404s gracefully when the catalog row has no demo_slug, when
// the frame is anything other than 0/1, or when R2 has no object.
apiRoutes.get('/exercises/:id/demo/:frame', async (c) => {
  const id = c.req.param('id');
  const frame = c.req.param('frame');
  if (frame !== '0' && frame !== '1') {
    return c.json({ error: 'invalid_frame' }, 400);
  }
  const row = await c.env.DB.prepare(
    'SELECT demo_slug FROM exercises WHERE id = ?1',
  )
    .bind(id)
    .first<{ demo_slug: string | null }>();
  if (!row) return c.json({ error: 'unknown_exercise' }, 404);
  if (!row.demo_slug) return c.json({ error: 'no_demo' }, 404);
  if (!c.env.DEMOS) return c.json({ error: 'demos_unconfigured' }, 503);
  const key = `demos/${row.demo_slug}/${frame}.webp`;
  const obj = await c.env.DEMOS.get(key);
  if (!obj) return c.json({ error: 'demo_missing' }, 404);
  return new Response(obj.body, {
    headers: {
      'Content-Type': 'image/webp',
      // 1 year, immutable: slug+frame is the only address; we'd ship a new
      // slug to invalidate.
      'Cache-Control': 'public, max-age=31536000, immutable',
      // httpEtag, not etag: R2's `etag` is the raw hex digest; `httpEtag`
      // is the same value quoted per RFC 7232 (e.g. "\"abc123\""), which is
      // what a conditional-request validator expects. Sending the raw form
      // makes caches/intermediaries ignore the header on revalidation,
      // undercutting the immutable caching this route is built for.
      'ETag': obj.httpEtag,
    },
  });
});

apiRoutes.get('/history', async (c) => {
  const exerciseId = c.req.query('exercise_id');
  if (!exerciseId) return c.json({ error: 'missing_exercise_id' }, 400);
  const from = Number(c.req.query('from') ?? 0);
  const to = Number(c.req.query('to') ?? Date.now());
  return c.json(await getHistory(c.env.DB, c.get('userId'), exerciseId, from, to));
});

apiRoutes.get('/volume', async (c) => {
  const muscle = c.req.query('muscle');
  if (!muscle) return c.json({ error: 'missing_muscle' }, 400);
  const from = Number(c.req.query('from') ?? 0);
  const to = Number(c.req.query('to') ?? Date.now());
  const result = await getVolume(c.env.DB, c.get('userId'), muscle, from, to);
  if ('error' in result) return c.json(result, 400);
  return c.json(result);
});

// ---- generic activities (M3 — pilates / cardio / yoga / walks / …) -------
//
// Append-only log, client-UUID idempotent (same model as POST /sessions/:id/
// sets). The iOS outbox can retry safely; the second POST with the same `id`
// returns the existing row instead of duplicating.

apiRoutes.post('/activities', async (c) => {
  const b = await c.req.json<{
    id?: string;
    date?: string;
    type?: string;
    title?: string | null;
    duration_minutes?: number | null;
    notes?: string | null;
    logged_at?: number;
  }>();
  if (!b.id || typeof b.id !== 'string' || !UUID_RE.test(b.id)) {
    return c.json({ error: 'invalid_id' }, 400);
  }
  if (typeof b.date !== 'string' || !ISO_DATE_RE.test(b.date)) {
    return c.json({ error: 'invalid_date' }, 400);
  }
  if (typeof b.type !== 'string' || b.type.length === 0 || b.type !== b.type.toLowerCase()) {
    return c.json({ error: 'invalid_type' }, 400);
  }
  if (typeof b.logged_at !== 'number' || !Number.isFinite(b.logged_at)) {
    return c.json({ error: 'invalid_logged_at' }, 400);
  }
  const row = await logActivity(
    c.env.DB,
    c.get('userId'),
    {
      id: b.id,
      date: b.date,
      type: b.type,
      title: b.title ?? null,
      duration_minutes:
        typeof b.duration_minutes === 'number' ? b.duration_minutes : null,
      notes: b.notes ?? null,
      logged_at: b.logged_at,
    },
    'ios',
  );
  return c.json(row, 201);
});

apiRoutes.delete('/activities/:id', async (c) => {
  const ok = await softDeleteActivity(c.env.DB, c.get('userId'), c.req.param('id'));
  if (!ok) return c.json({ error: 'not_found' }, 404);
  return c.json({ ok: true });
});

// ---- Apple Health (HealthKit) workout push — iOS on-device → backend ------
//
// HealthKit lives ONLY on the phone; the Worker can never read it. The iOS app
// reads HKWorkout and PUSHes each workout here, landing in the SAME
// external_activities cache the intervals pull writes (source='healthkit').
// Client-UUID idempotent (the HKWorkout uuid) — the iOS outbox / a re-anchored
// sync re-POSTing the same workout lands on ON CONFLICT and updates in place.
// The intervals reconcile is source-scoped (migration 0027), so it never
// tombstones these pushed rows.
apiRoutes.post('/activities/healthkit', async (c) => {
  const b = await c.req.json<{
    id?: string;
    date?: string;
    start_date_local_ms?: number | null;
    kind?: string;
    name?: string | null;
    moving_time_sec?: number | null;
    elapsed_time_sec?: number | null;
    distance_m?: number | null;
    average_watts?: number | null;
    average_hr?: number | null;
    max_hr?: number | null;
    calories?: number | null;
    elevation_gain_m?: number | null;
    raw?: string | null;
  }>();
  if (!b.id || typeof b.id !== 'string' || !UUID_RE.test(b.id)) {
    return c.json({ error: 'invalid_id' }, 400);
  }
  if (typeof b.date !== 'string' || !ISO_DATE_RE.test(b.date)) {
    return c.json({ error: 'invalid_date' }, 400);
  }
  if (typeof b.kind !== 'string' || b.kind.length === 0 || b.kind !== b.kind.toLowerCase()) {
    return c.json({ error: 'invalid_kind' }, 400);
  }
  // REAL (floating) columns: keep any finite value.
  const numOrNull = (v: unknown): number | null =>
    typeof v === 'number' && Number.isFinite(v) ? v : null;
  // INTEGER columns. Codex P2: HealthKit yields Double (TimeInterval / HKQuantity),
  // so e.g. moving_time_sec=1800.5 would persist as a SQLite decimal and break
  // iOS's Int? decode of external_activities (dropping the whole feed). Round to
  // an int before persisting. Applies to the columns iOS decodes as Int:
  // start_date_local_ms, moving_time_sec, elapsed_time_sec, max_hr, calories.
  const intOrNull = (v: unknown): number | null =>
    typeof v === 'number' && Number.isFinite(v) ? Math.round(v) : null;
  const row = await upsertHealthKitActivity(c.env.DB, c.get('userId'), {
    id: b.id,
    date: b.date,
    start_date_local_ms: intOrNull(b.start_date_local_ms),
    kind: b.kind,
    name: typeof b.name === 'string' && b.name.length > 0 ? b.name : null,
    moving_time_sec: intOrNull(b.moving_time_sec),
    elapsed_time_sec: intOrNull(b.elapsed_time_sec),
    distance_m: numOrNull(b.distance_m),
    average_watts: numOrNull(b.average_watts),
    average_hr: numOrNull(b.average_hr),
    max_hr: intOrNull(b.max_hr),
    calories: intOrNull(b.calories),
    elevation_gain_m: numOrNull(b.elevation_gain_m),
    raw: typeof b.raw === 'string' ? b.raw : null,
  });
  return c.json(row, 201);
});

// PATCH /api/me/health-sharing — flip the Apple Health group-feed opt-in
// (migration 0028). Off by default; the iOS Apple Health detail toggle calls
// this. When off, the group feed/stats/series exclude this user's HealthKit rows.
apiRoutes.patch('/me/health-sharing', async (c) => {
  const b = await c.req.json<{ enabled?: unknown }>();
  if (typeof b.enabled !== 'boolean') return c.json({ error: 'invalid_enabled' }, 400);
  return c.json(await setHealthActivitySharing(c.env.DB, c.get('userId'), b.enabled));
});

// GET /api/me — account/setup snapshot for the iOS Profile tab. Read-only;
// derives intervals + Claude-connector status from the server so the app
// reflects env/MCP-seeded creds and the claude.ai connector (which the
// client otherwise has no way to see). Never returns the intervals api_key.
apiRoutes.get('/me', async (c) => {
  const userId = c.get('userId');
  return c.json(await getMeProfile(c.env.DB, userId, c.env.OWNER_APPLE_SUB));
});

// GET /api/me/export — download the authenticated caller's portable account
// and training-data snapshot. There is deliberately no user id in either the
// path or query contract: requireAppJwt supplies the sole export principal.
// The attachment is never cacheable and the service projection excludes
// credentials, tokens, invite capabilities, and other members' private data.
apiRoutes.get('/me/export', async (c) => {
  const exported = await exportUserData(c.env.DB, c.get('userId'));
  if (!exported) return c.json({ error: 'not_found' }, 404);
  const exportedAt = exported.exported_at;
  const date =
    typeof exportedAt === 'number' && Number.isFinite(exportedAt)
      ? new Date(exportedAt).toISOString().slice(0, 10)
      : 'data';
  return new Response(JSON.stringify(exported, null, 2), {
    status: 200,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Content-Disposition':
        `attachment; filename="tres-fort-account-export-${date}.json"`,
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
    },
  });
});

// PATCH /api/me/profile — repair the display name Apple provides only on the
// first authorization. Only the caller's user row changes; group-specific
// nickname overrides remain independent.
apiRoutes.patch('/me/profile', async (c) => {
  let body: { display_name?: unknown };
  try {
    body = await c.req.json<{ display_name?: unknown }>();
  } catch {
    return c.json({ error: 'invalid_json' }, 400);
  }
  if (body === null || typeof body !== 'object' || typeof body.display_name !== 'string') {
    return c.json({ error: 'invalid_display_name' }, 400);
  }
  const displayName = body.display_name.trim();
  if (displayName.length < 1 || displayName.length > 80) {
    return c.json({ error: 'invalid_display_name' }, 400);
  }
  const userId = c.get('userId');
  if (!(await setUserDisplayName(c.env.DB, userId, displayName))) {
    return c.json({ error: 'not_found' }, 404);
  }
  await writeAudit(
    c.env.DB,
    userId,
    'update_profile',
    { field: 'display_name' },
    'ok',
    'ios',
  );
  return c.json(await getMeProfile(c.env.DB, userId, c.env.OWNER_APPLE_SUB));
});

// DELETE /api/me — permanently delete the authenticated account.
//
// There is deliberately no soft-delete or recovery token: the iOS client puts
// a plainly worded destructive confirmation in front of this request, and the
// service transaction removes all caller-owned rows and credentials. Shared
// groups survive under their longest-tenured remaining member; an owner
// deletion additionally leaves the non-personal bootstrap-suppression
// tombstone. Tests exercise seeded users only.
apiRoutes.delete('/me', async (c) => {
  const idempotencyKey = c.req.header('X-Account-Deletion-Key') ?? '';
  if (!isAccountDeletionKey(idempotencyKey)) {
    return c.json({ error: 'invalid_account_deletion_key' }, 400);
  }
  const userId = c.get('userId');
  const livePrincipal = await c.env.DB
    .prepare('SELECT 1 AS x FROM users WHERE id = ?1')
    .bind(userId)
    .first<{ x: number }>();
  const continuingDeletion = await accountDeletionContinuationMatches(
    c.env.DB,
    userId,
    idempotencyKey,
  );
  const authAgeSeconds = Math.max(
    0,
    Math.floor(Date.now() / 1000) - c.get('appAuthTime'),
  );
  if (
    livePrincipal &&
    !continuingDeletion &&
    authAgeSeconds > ACCOUNT_DELETION_RECENT_AUTH_SECONDS
  ) {
    return c.json({ error: 'reauthentication_required' }, 401);
  }
  const result = await deleteUserAccount(
    c.env.DB,
    userId,
    c.env.OWNER_APPLE_SUB,
    idempotencyKey,
    { appleConfig: appleProviderConfig(c.env) },
  );
  if ('error' in result) {
    return c.json(
      {
        error:
          result.error === 'not_found' ? 'account_not_found' : result.error,
      },
      result.error === 'conflict' ? 409 : 404,
    );
  }
  return c.json(result);
});

// ---- integrations: intervals.icu credentials (M1 multi-user) ------------
// Connect / disconnect THIS user's intervals.icu account. Each Apple sign-in
// owns its own credentials so multiple users can each connect a separate
// athlete without overwriting one another (the env-secret model could not).
// Disconnect = pass null on either field; both columns clear together.
apiRoutes.patch('/me/integrations/intervals', async (c) => {
  const userId = c.get('userId');
  let b: { api_key?: unknown; athlete_id?: unknown };
  try {
    b = await c.req.json<{ api_key?: unknown; athlete_id?: unknown }>();
  } catch {
    return c.json({ error: 'invalid_json' }, 400);
  }
  // Required keys (either value may be null = disconnect). Reject silently-
  // missing keys so a typo doesn't accidentally clear a working connection.
  if (!('api_key' in b) || !('athlete_id' in b)) {
    return c.json({ error: 'missing_fields' }, 400);
  }
  const rawKey = b.api_key;
  const rawId = b.athlete_id;
  const okKey = rawKey === null || typeof rawKey === 'string';
  const okId = rawId === null || typeof rawId === 'string';
  if (!okKey || !okId) return c.json({ error: 'invalid_field_type' }, 400);
  // Empty strings are treated as null (disconnect) — defensive against
  // iOS form posting "" instead of null on the clear path.
  const apiKey = typeof rawKey === 'string' && rawKey.length > 0 ? rawKey : null;
  const athleteId = typeof rawId === 'string' && rawId.length > 0 ? rawId : null;
  const result = await setUserIntervalsCreds(c.env.DB, userId, apiKey, athleteId);
  // Audit the change without recording the API key itself (only the
  // outcome). actor='ios' distinguishes this REST mutation from MCP audits.
  await writeAudit(
    c.env.DB,
    userId,
    'set_intervals_creds',
    { connected: result.connected },
    result.connected ? 'connected' : 'disconnected',
    'ios',
  );
  return c.json(result);
});

// ---- MCP passphrase (M3 multi-tenant) -----------------------------------
// Set THIS user's personal passphrase used to connect a Claude MCP session
// via OAuth (/oauth/authorize). Self-service: a signed-in user provisions
// their own passphrase; it is PBKDF2-hashed and never returned. The owner can
// also use the OWNER_AUTH_PASSPHRASE env path and does not need this.
apiRoutes.post('/me/mcp-passphrase', async (c) => {
  let b: { passphrase?: unknown };
  try {
    b = await c.req.json<{ passphrase?: unknown }>();
  } catch {
    return c.json({ error: 'invalid_json' }, 400);
  }
  const passphrase = typeof b.passphrase === 'string' ? b.passphrase : '';
  if (passphrase.length < 8) return c.json({ error: 'passphrase_too_short' }, 400);
  const res = await setUserMcpPassphrase(c.env.DB, c.get('userId'), passphrase, c.env.OWNER_AUTH_PASSPHRASE);
  if ('error' in res) {
    // Already in use by another user — accepting it would bind their MCP
    // session to that account (cross-user access). 409, no audit-as-ok.
    await writeAudit(c.env.DB, c.get('userId'), 'set_mcp_passphrase', {}, res.error, 'ios');
    return c.json({ error: res.error }, 409);
  }
  await writeAudit(c.env.DB, c.get('userId'), 'set_mcp_passphrase', {}, 'ok', 'ios');
  return c.json({ ok: true });
});

// ---- groups (M2 — friends/family invite-gated containers) ----------------
//
// All routes require requireAppJwt (mounted at the top). Membership is the
// authorization unit: non-members see 403 on group-scoped GET/PATCH/POST,
// 200-or-404 on leave (idempotent), 404 on unknown group id. Mutations
// audit via writeAudit inside the db.ts helpers (actor='ios').

apiRoutes.post('/groups', async (c) => {
  const userId = c.get('userId');
  let b: { name?: unknown };
  try {
    b = await c.req.json<{ name?: unknown }>();
  } catch {
    return c.json({ error: 'invalid_json' }, 400);
  }
  if (typeof b.name !== 'string' || b.name.trim().length === 0) {
    return c.json({ error: 'invalid_name' }, 400);
  }
  const group = await createGroup(c.env.DB, userId, b.name.trim());
  // Hydrate so the iOS client gets the full shape (creator listed as the
  // sole member) without a second roundtrip.
  const full = await getGroupWithMembers(c.env.DB, group.id);
  return c.json(full, 201);
});

apiRoutes.get('/groups', async (c) => {
  const userId = c.get('userId');
  return c.json({ groups: await listGroupsForUser(c.env.DB, userId) });
});

// Preview an invite by code (group name + state) so the in-app join-confirm
// sheet can show "Join <name>?" BEFORE redeeming. Any signed-in user may
// call it — the code is the join capability, so this exposes nothing they
// couldn't get by redeeming. Read-only: does NOT consume the code. Registered
// before `/groups/:id` so the literal "invite" segment can never be read as a
// group id (group ids are UUIDs, so they never collide, but order makes it
// unambiguous). `code` is normalized inside getInvitePreview's lookup.
apiRoutes.get('/groups/invite/:code', async (c) => {
  const code = c.req.param('code').trim();
  return c.json(await getInvitePreview(c.env.DB, code));
});

apiRoutes.get('/groups/:id', async (c) => {
  const userId = c.get('userId');
  const groupId = c.req.param('id');
  // Non-member -> 403 (do not 404, which would silently leak nothing-vs-
  // not-mine — but also do not list members of arbitrary groups). The
  // 404 case is the truly-unknown group id below.
  const exists = await c.env.DB
    .prepare('SELECT 1 AS x FROM groups WHERE id = ?1')
    .bind(groupId)
    .first<{ x: number }>();
  if (!exists) return c.json({ error: 'not_found' }, 404);
  if (!(await isGroupMember(c.env.DB, userId, groupId))) {
    return c.json({ error: 'forbidden' }, 403);
  }
  const full = await getGroupWithMembers(c.env.DB, groupId);
  return c.json(full);
});

apiRoutes.post('/groups/:id/invites', async (c) => {
  const userId = c.get('userId');
  const groupId = c.req.param('id');
  if (!(await isGroupMember(c.env.DB, userId, groupId))) {
    // 403 (rather than 404) when the group exists but caller isn't in it;
    // 404 when the group truly doesn't exist (we treat the missing FK as
    // the latter from a UX point of view — the iOS client can't tell the
    // difference and shouldn't, since the only way to know a group id is
    // membership).
    const exists = await c.env.DB
      .prepare('SELECT 1 AS x FROM groups WHERE id = ?1')
      .bind(groupId)
      .first<{ x: number }>();
    if (!exists) return c.json({ error: 'not_found' }, 404);
    return c.json({ error: 'forbidden' }, 403);
  }
  let b: { expires_at?: unknown };
  try {
    b = await c.req.json<{ expires_at?: unknown }>().catch(() => ({}));
  } catch {
    b = {};
  }
  // expires_at semantics: undefined -> default +30d (db.ts), null ->
  // never expires, number -> exact epoch ms. Anything else is rejected
  // so a typo doesn't accidentally mint a never-expiring code.
  let expiresAt: number | null | undefined = undefined;
  if ('expires_at' in b) {
    const v = b.expires_at;
    if (v === null) expiresAt = null;
    else if (typeof v === 'number' && Number.isFinite(v)) expiresAt = v;
    else return c.json({ error: 'invalid_expires_at' }, 400);
  }
  const invite = await createInvite(c.env.DB, userId, groupId, expiresAt);
  return c.json(
    { code: invite.code, group_id: invite.group_id, expires_at: invite.expires_at },
    201,
  );
});

apiRoutes.post('/groups/join', async (c) => {
  const userId = c.get('userId');
  let b: { code?: unknown };
  try {
    b = await c.req.json<{ code?: unknown }>();
  } catch {
    return c.json({ error: 'invalid_json' }, 400);
  }
  if (typeof b.code !== 'string' || b.code.length === 0) {
    return c.json({ error: 'invalid_code' }, 400);
  }
  const result = await redeemInvite(c.env.DB, b.code.trim(), userId);
  if ('error' in result) {
    // Map db.ts error tags to HTTP status per spec:
    //   unknown  -> 404 (no such code)
    //   used     -> 410 (code was consumed)
    //   expired  -> 410 (code timed out)
    //   already_member -> 409 (you're already in this group; code NOT consumed)
    if (result.error === 'unknown') return c.json(result, 404);
    if (result.error === 'already_member') return c.json(result, 409);
    return c.json(result, 410);
  }
  // On success, hand back the freshly-joined group with members hydrated
  // so the iOS client can render the group page without a follow-up GET.
  const group = await getGroupWithMembers(c.env.DB, result.group_id);
  return c.json({ ok: true, group });
});

apiRoutes.delete('/groups/:id/members/me', async (c) => {
  const userId = c.get('userId');
  const groupId = c.req.param('id');
  // Idempotent: 200 whether or not the caller was a member. leaveGroup
  // returns false when no rows changed (already gone / never joined),
  // but per spec we still return 200 — the postcondition holds either way.
  const removed = await leaveGroup(c.env.DB, userId, groupId);
  return c.json({ ok: true, removed });
});

apiRoutes.patch('/groups/:id/members/me', async (c) => {
  const userId = c.get('userId');
  const groupId = c.req.param('id');
  let b: { display_name?: unknown };
  try {
    b = await c.req.json<{ display_name?: unknown }>();
  } catch {
    return c.json({ error: 'invalid_json' }, 400);
  }
  if (!('display_name' in b)) {
    return c.json({ error: 'missing_display_name' }, 400);
  }
  const raw = b.display_name;
  if (raw !== null && typeof raw !== 'string') {
    return c.json({ error: 'invalid_display_name' }, 400);
  }
  // Empty string is treated as null (clear). Mirrors the intervals creds
  // route's empty-string-as-null convention so an iOS form posting "" on
  // clear doesn't end up with an empty nickname.
  const displayName = typeof raw === 'string' && raw.length > 0 ? raw : null;
  const ok = await setGroupDisplayName(c.env.DB, userId, groupId, displayName);
  if (!ok) return c.json({ error: 'forbidden' }, 403);
  // Return the hydrated group so the iOS client can update its model.
  const full = await getGroupWithMembers(c.env.DB, groupId);
  return c.json(full);
});

// ---- M4: group feed + stats ---------------------------------------------
//
// Two read endpoints on top of the existing group-membership authz:
// `/feed` (interleaved session/ride/activity stream) and `/stats` (per-
// member workout_count + streak). Both 403 non-members, 404 unknown ids,
// and stamp `is_me` so the iOS client doesn't compare user ids manually.
//
// Privacy contract enforced INSIDE the db.ts helpers (notes / RPE / set
// notes / perceived_fatigue are never selected). See the long comment at
// the top of the M4 section in db.ts for the full rules.

/**
 * Shared guard for /groups/:id/feed and /groups/:id/stats: 404 if the
 * group doesn't exist, 403 if the caller isn't a member. Returns null on
 * pass-through (call site continues), or a Response on reject (call site
 * `return`s it). Mirrors the same 404-before-403 ordering POST
 * /:id/invites uses.
 */
async function requireGroupMembership(
  c: Context<HonoEnv>,
  userId: string,
  groupId: string,
): Promise<Response | null> {
  const exists = await c.env.DB
    .prepare('SELECT 1 AS x FROM groups WHERE id = ?1')
    .bind(groupId)
    .first<{ x: number }>();
  if (!exists) return c.json({ error: 'not_found' }, 404);
  if (!(await isGroupMember(c.env.DB, userId, groupId))) {
    return c.json({ error: 'forbidden' }, 403);
  }
  return null;
}

apiRoutes.get('/groups/:id/feed', async (c) => {
  const userId = c.get('userId');
  const groupId = c.req.param('id');
  const guard = await requireGroupMembership(c, userId, groupId);
  if (guard) return guard;

  // Composite pagination cursor on (occurred_at, id): when N rows share
  // an occurred_at at the page boundary, a plain timestamp cursor would
  // drop the rest of the tied rows on the next page. iOS passes BOTH
  // `since` (epoch-ms upper bound) and `since_id` (the tail item's id);
  // server filters strictly older on the composite. Both null → no upper
  // bound (most-recent N).
  const sinceRaw = c.req.query('since');
  let sinceMs: number | null = null;
  if (sinceRaw != null) {
    const n = Number(sinceRaw);
    if (!Number.isFinite(n)) return c.json({ error: 'invalid_since' }, 400);
    sinceMs = n;
  }
  const sinceIdRaw = c.req.query('since_id');
  const sinceId =
    sinceIdRaw != null && sinceIdRaw.length > 0 ? sinceIdRaw : null;
  // `limit`: default 30, capped at 100 (FEED_LIMIT_MAX in db.ts). Out-of-
  // range values clamp rather than 400 — the iOS client's safer to keep
  // moving on a typo than to surface a "what did you do wrong" error.
  let limit = 30;
  const limitRaw = c.req.query('limit');
  if (limitRaw != null) {
    const n = Number(limitRaw);
    if (Number.isFinite(n) && n > 0) limit = Math.min(100, Math.floor(n));
  }

  const items = await getGroupFeed(c.env.DB, groupId, sinceMs, sinceId, limit, userId);
  // Composite next cursor = the LAST returned item (smallest by
  // (occurred_at, id) DESC). iOS passes both fields back as ?since= and
  // ?since_id= to load the next page. null both when empty → end of stream.
  const tail = items.length === 0 ? null : items[items.length - 1]!;
  return c.json({
    group_id: groupId,
    items,
    next_since: tail?.occurred_at ?? null,
    next_since_id: tail?.id ?? null,
    server_time: Date.now(),
  });
});

apiRoutes.get('/groups/:id/stats', async (c) => {
  const userId = c.get('userId');
  const groupId = c.req.param('id');
  const guard = await requireGroupMembership(c, userId, groupId);
  if (guard) return guard;

  // `range`: "7d" | "14d" | "30d" (default 7d). Other suffixes (weeks,
  // months) are rejected so the iOS surface is honest about what it
  // accepts — 5d would silently round, etc.
  const rangeRaw = c.req.query('range') ?? '7d';
  const m = /^(\d+)d$/.exec(rangeRaw);
  if (!m) return c.json({ error: 'invalid_range' }, 400);
  const days = Number(m[1]);
  if (!Number.isFinite(days) || days < 1 || days > 365) {
    return c.json({ error: 'invalid_range' }, 400);
  }
  const members = await getGroupStats(c.env.DB, groupId, days, userId);
  return c.json({ group_id: groupId, range: rangeRaw, members });
});

// GET /groups/:id/activity?days=N — per-member DAILY activity series for
// the week/month/year zoom. One generous pull (default 371d ≈ 53 weeks)
// powers all three client zooms with no refetch on toggle. Same
// 404-before-403 membership guard as /feed and /stats.
apiRoutes.get('/groups/:id/activity', async (c) => {
  const userId = c.get('userId');
  const groupId = c.req.param('id');
  const guard = await requireGroupMembership(c, userId, groupId);
  if (guard) return guard;

  // `days`: trailing civil-day window. Default 371 (covers the year
  // view's 53 week-buckets); clamped 1..372 in db.ts. Out-of-range
  // clamps rather than 400 — same forgiving stance as /feed's limit.
  let days = 371;
  const daysRaw = c.req.query('days');
  if (daysRaw != null) {
    const n = Number(daysRaw);
    if (Number.isFinite(n) && n > 0) days = Math.floor(n);
  }
  const members = await getGroupActivitySeries(c.env.DB, groupId, days, userId);
  return c.json({ group_id: groupId, days, server_time: Date.now(), members });
});
