import { Hono } from 'hono';
import type { Context } from 'hono';
import type { HonoEnv } from '../types';
import { requireAppJwt } from '../auth';
import {
  addDayTemplate,
  addTemplateExercise,
  createGroup,
  createInvite,
  createPlan,
  deleteTemplateExercise,
  discardSession,
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
  getPlanTree,
  getState,
  getVolume,
  isGroupMember,
  leaveGroup,
  listGroupsForUser,
  logActivity,
  logSet,
  nextExerciseOrderIndex,
  patchDayTemplate,
  patchSession,
  patchSet,
  redeemInvite,
  resolveExercise,
  setGroupDisplayName,
  setUserIntervalsCreds,
  setUserMcpPassphrase,
  softDeleteActivity,
  updateExercise,
  writeAudit,
} from '../db';

export const apiRoutes = new Hono<HonoEnv>();
apiRoutes.use('*', requireAppJwt);

const todayLocal = () => new Date().toISOString().slice(0, 10);

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

apiRoutes.post('/plan', async (c) => {
  const b = await c.req.json<{ name: string; meta?: unknown }>();
  if (!b.name) return c.json({ error: 'missing_name' }, 400);
  return c.json(await createPlan(c.env.DB, c.get('userId'), b.name, b.meta ?? null), 201);
});

apiRoutes.post('/days', async (c) => {
  const plan = await getActivePlan(c.env.DB, c.get('userId'));
  if (!plan) return c.json({ error: 'no_active_plan' }, 400);
  const b = await c.req.json<{ name: string; day_label?: string; order_index?: number }>();
  if (!b.name) return c.json({ error: 'missing_name' }, 400);
  return c.json(
    await addDayTemplate(c.env.DB, plan.id, b.name, b.day_label ?? null, b.order_index ?? 0),
    201,
  );
});

apiRoutes.patch('/days/:id', async (c) => {
  const plan = await getActivePlan(c.env.DB, c.get('userId'));
  if (!plan) return c.json({ error: 'no_active_plan' }, 400);
  const b = await c.req.json<{
    name?: string;
    day_label?: string | null;
    order_index?: number;
    notes?: string | null;
  }>();
  const row = await patchDayTemplate(c.env.DB, plan.id, c.req.param('id'), b);
  if (!row) return c.json({ error: 'not_found' }, 404);
  if ('error' in row) return c.json(row, 400);
  return c.json(row);
});

apiRoutes.post('/days/:id/exercises', async (c) => {
  const userId = c.get('userId');
  const plan = await getActivePlan(c.env.DB, userId);
  if (!plan) return c.json({ error: 'no_active_plan' }, 400);
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
  const dayId = c.req.param('id');
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
  const session = await getOrCreateSession(c.env.DB, userId, plan.id, todayLocal(), null);
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
  const b = await c.req.json<{ date?: string; day_template_id?: string | null }>();
  const s = await getOrCreateSession(
    c.env.DB,
    userId,
    plan.id,
    b.date ?? todayLocal(),
    b.day_template_id ?? null,
  );
  return c.json(s, 201);
});

apiRoutes.patch('/sessions/:id', async (c) => {
  const b = await c.req.json<{ status?: string; perceived_fatigue?: number; notes?: string }>();
  const s = await patchSession(c.env.DB, c.get('userId'), c.req.param('id'), b);
  if (!s) return c.json({ error: 'not_found' }, 404);
  if ('error' in s) {
    // Exhaustive: invalid_status → 400 (bad request, nothing persisted);
    // session_already_started → 409 (history-integrity burial guard).
    if (s.error === 'invalid_status') return c.json(s, 400);
    return c.json(s, 409);
  }
  return c.json(s);
});

// Discard a session — "I didn't really do this." Soft-deletes its sets
// and marks it 'discarded' (vanishes from the projection; excluded from
// history/volume/conflicts). Idempotent. Restarting the same date via
// GET /today or POST /sessions resurrects a fresh planned session.
apiRoutes.post('/sessions/:id/discard', async (c) => {
  const s = await discardSession(c.env.DB, c.get('userId'), c.req.param('id'));
  if (!s) return c.json({ error: 'not_found' }, 404);
  return c.json(s);
});

apiRoutes.post('/sessions/:id/sets', async (c) => {
  const b = await c.req.json<{
    id: string;
    exercise_id: string;
    set_index: number;
    weight: number;
    reps: number;
    rpe?: number | null;
    is_warmup?: boolean;
    template_exercise_id?: string | null;
    notes?: string | null;
    logged_at?: number;
    duration_s?: number | null;
    is_timed?: boolean;
  }>();
  if (!b.id) return c.json({ error: 'missing_set_id' }, 400);
  try {
    const result = await logSet(c.env.DB, c.get('userId'), {
      ...b,
      session_id: c.req.param('id'),
      source: 'ios',
    });
    return c.json(result, result.deduped ? 200 : 201);
  } catch (e) {
    return c.json({ error: (e as Error).message }, 404);
  }
});

apiRoutes.patch('/sets/:id', async (c) => {
  const b = await c.req.json<{
    weight?: number;
    reps?: number;
    rpe?: number | null;
    notes?: string | null;
    deleted?: boolean;
  }>();
  const row = await patchSet(c.env.DB, c.get('userId'), c.req.param('id'), b);
  return row ? c.json(row) : c.json({ error: 'not_found' }, 404);
});

// ---- read models ---------------------------------------------------------
apiRoutes.get('/exercises', async (c) => {
  // Funnel through getExercises so the wire shape matches MCP's
  // list_exercises — in particular, `laterality` rides along, which iOS
  // needs to compute per-side rollups (Bulgarian split squat 45×8 →
  // 16 reps / 720 lb instead of 8 / 360).
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
  return c.json(await getVolume(c.env.DB, c.get('userId'), muscle, from, to));
});

// ---- generic activities (M3 — pilates / cardio / yoga / walks / …) -------
//
// Append-only log, client-UUID idempotent (same model as POST /sessions/:id/
// sets). The iOS outbox can retry safely; the second POST with the same `id`
// returns the existing row instead of duplicating.

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ISO_DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

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

// GET /api/me — account/setup snapshot for the iOS Profile tab. Read-only;
// derives intervals + Claude-connector status from the server so the app
// reflects env/MCP-seeded creds and the claude.ai connector (which the
// client otherwise has no way to see). Never returns the intervals api_key.
apiRoutes.get('/me', async (c) => {
  const userId = c.get('userId');
  return c.json(await getMeProfile(c.env.DB, userId, c.env.OWNER_APPLE_SUB));
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
