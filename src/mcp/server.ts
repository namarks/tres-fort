// Minimal, spec-correct MCP server over Streamable HTTP (JSON-RPC 2.0,
// single application/json responses — no server-initiated streams needed
// for read tools). Stateless: no Mcp-Session-Id required. All data access
// goes through src/db.ts, identical to REST.
import type { Env } from '../types';
import {
  addDayTemplate,
  addTemplateExercise,
  adjustToday,
  deleteTemplateExercise,
  ensureOwnerUser,
  findRecentMatchingSet,
  getActivePlan,
  getExercises,
  getGroupFeed,
  getGroupStats,
  getHistory,
  getInProgressSession,
  getLastCompletedSession,
  getOrCreateSession,
  getPlanTree,
  getRecentActivities,
  getRecentSessions,
  getResolvedScheduleNames,
  getRideConflicts,
  getSessionByDate,
  getSetsForSession,
  getUpcomingRides,
  getUserTimezone,
  getVolume,
  isGroupMember,
  listGroupsForUser,
  logActivity,
  logSet,
  logWorkoutComplete,
  nextDayOrderIndex,
  nextExerciseOrderIndex,
  patchDayTemplate,
  patchSet,
  tryExportSessionLoad,
  resolveExercise,
  setPlanSchedule,
  setPlannedSession,
  skipPlannedSession,
  todayInTz,
  swapExercise,
  syncExternalActivities,
  syncExternalEvents,
  updateExercise,
  updatePlanTree,
  writeAudit,
  writeNote,
} from '../db';
import type { Weekday } from '../types';

const SERVER_INFO = { name: 'lift-coach', version: '0.1.0' };
// Host-injected system instructions (MCP `initialize.instructions`). Shapes
// how the model uses these tools — specifically the no-auto-log policy that
// stops phantom/duplicate set_logs when the user is just narrating a workout
// they are already logging in the iOS app.
const SERVER_INSTRUCTIONS =
  "You are the user's strength coach. The iOS app is the primary set " +
  'logger: the user records their own reps and weights in the gym. Your ' +
  'job in chat is to coach (review history, adapt the plan, motivate, ' +
  'answer questions) — NOT to mirror what they are logging. Do NOT call ' +
  'log_set unless the user explicitly asks you to log/record/add a set ' +
  '("log this", "add 225x5", "I forgot to log my warmup"). Narration like ' +
  '"set 2 down", "5x135", "just hit a PR", or "that felt easy" is a ' +
  'status update — acknowledge it, do not log. Sets with source="ios" in ' +
  'get_current_session / get_today_workout are evidence the user is ' +
  'logging in-app right now; assume any set they mention is already ' +
  'recorded. When in doubt, ask before logging. Use delete_set to undo a ' +
  'wrongly-logged set; the user fixes weight/reps mistakes in iOS.';
const DEFAULT_PROTOCOL = '2025-06-18';
const SUPPORTED_PROTOCOLS = new Set(['2025-06-18', '2025-03-26', '2024-11-05']);

type Json = Record<string, unknown>;

interface RpcRequest {
  jsonrpc: '2.0';
  id?: string | number | null;
  method: string;
  params?: Json;
}

const ok = (id: RpcRequest['id'], result: unknown) => ({ jsonrpc: '2.0', id, result });
const err = (id: RpcRequest['id'], code: number, message: string) => ({
  jsonrpc: '2.0',
  id: id ?? null,
  error: { code, message },
});

/**
 * The owner's civil "today" (YYYY-MM-DD) in their device-reported timezone.
 * MCP calls come from Claude, not the device, so we resolve "today" from the
 * tz the iOS app last synced (falls back to UTC when none recorded). This is
 * what stops get_today_workout returning tomorrow's date after ~17:00 PT.
 */
const ownerToday = async (env: Env, userId: string): Promise<string> =>
  todayInTz(await getUserTimezone(env.DB, userId));

/** Add n whole days to a YYYY-MM-DD (UTC math, date part only — no DST). */
const addDaysIso = (ymd: string, n: number) =>
  new Date(Date.parse(`${ymd}T00:00:00Z`) + n * 86_400_000).toISOString().slice(0, 10);

/** "30d" | "8w" | "6mo" | "all" -> epoch-ms lower bound. */
function rangeToFrom(range: string | undefined): number {
  if (!range || range === 'all') return 0;
  const m = /^(\d+)(d|w|mo)$/.exec(range.trim());
  if (!m) return 0;
  const n = Number(m[1]);
  const dayMs = 86_400_000;
  const mult = m[2] === 'd' ? dayMs : m[2] === 'w' ? 7 * dayMs : 30 * dayMs;
  return Date.now() - n * mult;
}

// ---- tool registry -------------------------------------------------------

/**
 * Cloudflare execution context surface we depend on. `waitUntil` keeps a
 * promise alive AFTER the response is returned without blocking it — used
 * so the best-effort intervals.icu export never delays log_workout_complete
 * (BLOCKER-2 fix). Optional everywhere: when absent (e.g. a direct unit
 * call) the export still runs, just inline.
 */
export interface BgScheduler {
  waitUntil(p: Promise<unknown>): void;
}

interface Tool {
  description: string;
  inputSchema: Json;
  handler: (
    args: Json,
    env: Env,
    userId: string,
    bg?: BgScheduler,
  ) => Promise<unknown>;
  /** Write tools are audited; `note` (if it returns text) is persisted. */
  write?: boolean;
  note?: (args: Json, result: any) => string | null;
}

const obj = (props: Json, required: string[] = []): Json => ({
  type: 'object',
  properties: props,
  required,
  additionalProperties: false,
});

const TOOLS: Record<string, Tool> = {
  get_current_plan: {
    description:
      'Get the active training plan: day templates with exercises, target sets/reps/RPE, rest, progression rules, and form cues.',
    inputSchema: obj({}),
    handler: async (_a, env, userId) => {
      const tree = await getPlanTree(env.DB, userId);
      if (!tree) return { plan: null, note: 'No active plan yet.' };
      // Fold in the resolved recurring weekly schedule (weekday → day name).
      const schedule = await getResolvedScheduleNames(env.DB, userId);
      // Conflict-aware with zero extra calls: a compact 28-day lift/ride
      // conflict list rides along with the plan context.
      const today = await ownerToday(env, userId);
      const ride_conflicts = await getRideConflicts(
        env.DB,
        userId,
        today,
        addDaysIso(today, 28),
        today,
      );
      return { ...tree, schedule, ride_conflicts };
    },
  },
  get_today_workout: {
    description:
      "Get today's workout: the date, any existing session for today, the plan's day templates, the recurring weekly schedule (so you can answer 'what should I do today?' from one call), and prior-session context. `last_session` is the most recent non-discarded session of ANY status (could be a skip/planned row); `last_completed_session` is the most recent COMPLETED session — use that for real training context, since a skipped day in between obscures `last_session`.",
    inputSchema: obj({}),
    handler: async (_a, env, userId) => {
      const date = await ownerToday(env, userId);
      const tree = await getPlanTree(env.DB, userId);
      const session = await getSessionByDate(env.DB, userId, date);
      const recent = await getRecentSessions(env.DB, userId, 2);
      const last = recent.find((s) => s.date !== date) ?? null;
      // The most recent COMPLETED session — the real "last training" for
      // coaching, unobscured by an intervening skip/planned row.
      const lastCompleted = await getLastCompletedSession(env.DB, userId, date);
      // `schedule` lets an agent answer "what should I do today?" without
      // a second call to get_current_plan — the natural one-shot answer.
      const schedule = tree ? await getResolvedScheduleNames(env.DB, userId) : null;
      return {
        date,
        session,
        sets: session ? await getSetsForSession(env.DB, session.id) : [],
        plan_days: tree?.days ?? [],
        schedule,
        last_session: last,
        last_session_sets: last ? await getSetsForSession(env.DB, last.id) : [],
        last_completed_session: lastCompleted,
        last_completed_session_sets: lastCompleted
          ? await getSetsForSession(env.DB, lastCompleted.id)
          : [],
      };
    },
  },
  get_current_session: {
    description: 'Get the in-progress workout session, if any, with sets logged so far.',
    inputSchema: obj({}),
    handler: async (_a, env, userId) => {
      const s = await getInProgressSession(env.DB, userId);
      if (!s) return { session: null };
      return { session: s, sets: await getSetsForSession(env.DB, s.id) };
    },
  },
  get_session_log: {
    description: 'Get logged sessions. Pass a specific date (YYYY-MM-DD) or recent_n for the last N.',
    inputSchema: obj(
      {
        date: { type: 'string', description: 'YYYY-MM-DD' },
        recent_n: { type: 'integer', minimum: 1, maximum: 50 },
      },
      [],
    ),
    handler: async (a, env, userId) => {
      if (typeof a.date === 'string') {
        const s = await getSessionByDate(env.DB, userId, a.date);
        return s ? [{ session: s, sets: await getSetsForSession(env.DB, s.id) }] : [];
      }
      const n = typeof a.recent_n === 'number' ? a.recent_n : 5;
      const sessions = await getRecentSessions(env.DB, userId, n);
      return Promise.all(
        sessions.map(async (s) => ({ session: s, sets: await getSetsForSession(env.DB, s.id) })),
      );
    },
  },
  get_history: {
    description:
      'Get set history for one exercise (by name or id, e.g. "bench"), with Epley est-1RM and the top working set per session.',
    inputSchema: obj(
      {
        exercise: { type: 'string', description: 'Exercise name, alias, or id' },
        range: { type: 'string', description: '30d | 90d | 6mo | all (default 90d)' },
      },
      ['exercise'],
    ),
    handler: async (a, env, userId) => {
      const ex = await resolveExercise(env.DB, String(a.exercise));
      if (!ex) return { error: 'unknown_exercise', query: a.exercise };
      const id = (ex as { id: string }).id;
      const from = rangeToFrom(typeof a.range === 'string' ? a.range : '90d');
      return { exercise: ex, ...(await getHistory(env.DB, userId, id, from, Date.now())) };
    },
  },
  get_volume_trend: {
    description:
      'Get weekly hard-set count and tonnage for a muscle group (e.g. "chest","quads","back") over a range.',
    inputSchema: obj(
      {
        muscle_group: { type: 'string' },
        range: { type: 'string', description: '8w | 12w | 6mo | all (default 12w)' },
      },
      ['muscle_group'],
    ),
    handler: async (a, env, userId) => {
      const from = rangeToFrom(typeof a.range === 'string' ? a.range : '12w');
      return getVolume(env.DB, userId, String(a.muscle_group), from, Date.now());
    },
  },

  list_exercises: {
    description:
      'List the exercise catalog so you can discover what is resolvable BEFORE calling add_exercise / update_plan (those reject unknown names with `unknown_exercise`). Optional filters: `query` (case-insensitive substring on name), `muscle` (primary_muscle exact, e.g. "quads"), `modality` (e.g. "barbell","dumbbell","bw","machine","timed"). Each row includes `laterality` ("bilateral" | "unilateral"); unilateral exercises log reps per-side, and the system doubles for total reps / tonnage (see log_set). Each row also includes `load_mode` ("total" | "per_hand"); for "per_hand" two-dumbbell lifts the weight is ONE dumbbell — set target_weight and phrase guidance per hand ("25 lb each hand"), never the doubled total. Returns up to a few hundred rows in the seeded catalog; combine filters to narrow.',
    inputSchema: obj(
      {
        query: { type: 'string' },
        muscle: { type: 'string' },
        modality: { type: 'string' },
      },
      [],
    ),
    handler: (a, env, _userId) =>
      getExercises(env.DB, {
        query: typeof a.query === 'string' ? a.query : undefined,
        muscle: typeof a.muscle === 'string' ? a.muscle : undefined,
        modality: typeof a.modality === 'string' ? a.modality : undefined,
      }),
  },

  get_upcoming_rides: {
    description:
      "Get planned cycling/endurance events (from intervals.icu) and where they conflict with the lift calendar. `range` is a day count from today (default 30, max 90). Conflicts: severity 'clash' = a lift and a ride on the SAME day; 'heavy-next-day' = a lift the calendar day BEFORE a hard ride (training_load >= 150 or planned_duration_sec >= 9000). Use this to coordinate lifting around riding.",
    inputSchema: obj(
      { range: { type: 'integer', minimum: 1, maximum: 90, description: 'days ahead (default 30)' } },
      [],
    ),
    handler: async (a, env, userId) => {
      const range = typeof a.range === 'number' ? Math.min(90, Math.max(1, a.range)) : 30;
      const today = await ownerToday(env, userId);
      const to = addDaysIso(today, range);
      const rides = await getUpcomingRides(env.DB, userId, { from: today, range });
      const conflicts = await getRideConflicts(env.DB, userId, today, to, today);
      return {
        from: today,
        to,
        rides: rides.map((r) => ({
          id: r.id,
          date: r.date,
          kind: r.kind,
          title: r.title,
          planned_duration_sec: r.planned_duration_sec,
          training_load: r.training_load,
        })),
        conflicts,
      };
    },
  },

  // ---- write tools -------------------------------------------------------

  log_set: {
    description:
      "Log one working/warmup set into the workout database. Auto-creates " +
      "the day's session and infers set_index. Logs to today unless " +
      'session_date is given. ' +
      'STRICT USAGE: do NOT call this tool while the user is narrating a ' +
      'workout in progress. Assume the iOS app is the primary logger — ' +
      'sets with source="ios" in get_current_session / get_today_workout ' +
      'mean the user is actively logging in-app, so any set they mention ' +
      'in chat is almost certainly ALREADY recorded. Only call log_set ' +
      'when the user explicitly asks you to ("log this", "record this ' +
      'set", "add 225x5 for me", "I forgot to log my warmup"). Phrases ' +
      'like "set 2 down", "5x135", "just did bench", "that felt heavy" ' +
      'are status reports, not logging requests — acknowledge them, do ' +
      'not call this tool. When unsure, ask the user before logging. The ' +
      'server also rejects sets that duplicate a same exercise/weight/' +
      'reps logged within the last 120 seconds (error: "recent_duplicate"' +
      '); that signal almost always means iOS already logged it — do NOT ' +
      'retry, and do NOT re-call with tweaked numbers. The dedupe gate is ' +
      'skipped for explicit backfill (session_date set to a past day, e.g. ' +
      '"log yesterday\'s 185x5") — those are explicit logging intents. ' +
      'CONVENTION: weight is per implement and reps is per side. For a ' +
      'unilateral exercise (Bulgarian split squat, lunge, one-arm row — ' +
      'list_exercises returns laterality), log ONE set with the per-side ' +
      'numbers; the system doubles for total reps and tonnage. Example: ' +
      'DB Bulgarian split squat with 45lb DBs, 8 reps each leg → ' +
      '`weight=45, reps=8` (NOT 90, NOT 16). The response echoes ' +
      'exercise.laterality + effective.{sides,total_reps,tonnage} so you ' +
      'can confirm to the user. ' +
      'TWO-DUMBBELL LIFTS: when list_exercises reports load_mode="per_hand" ' +
      '(DB bench, DB shoulder press, DB curl, lateral raise, DB lunge…), ' +
      'weight is the weight of ONE dumbbell. Set target_weight and phrase ' +
      'all guidance per hand — say "25 lb in each hand", never a vague ' +
      'doubled "50 lb". The response echoes exercise.load_mode so you can ' +
      'word it correctly.',
    inputSchema: obj(
      {
        exercise: { type: 'string', description: 'name, alias, or id' },
        weight: { type: 'number' },
        reps: { type: 'integer' },
        rpe: { type: 'number' },
        is_warmup: { type: 'boolean' },
        set_index: { type: 'integer' },
        session_date: { type: 'string', description: 'YYYY-MM-DD (default today)' },
        duration_s: { type: 'integer', description: 'seconds the set took / was held' },
        notes: { type: 'string' },
      },
      ['exercise', 'weight', 'reps'],
    ),
    write: true,
    handler: async (a, env, userId) => {
      const plan = await getActivePlan(env.DB, userId);
      if (!plan) return { error: 'no_active_plan' };
      const today = await ownerToday(env, userId);
      const date = typeof a.session_date === 'string' ? a.session_date : today;
      const session = await getOrCreateSession(env.DB, userId, plan.id, date, null);
      const ex = await resolveExercise(env.DB, String(a.exercise));
      if (!ex) return { error: 'unknown_exercise', query: a.exercise };
      const exId = (ex as { id: string }).id;
      const isWarmup = a.is_warmup === true;
      // Phantom-dupe guard: if the same exercise/weight/reps was logged by
      // ANY source in the last 120s, refuse. The narration-while-logging-
      // in-iOS case (the bug this fixes) hits exactly this window.
      // BUT: skip the gate for explicit backfill ("log yesterday's 185x5")
      // — when session_date is supplied and isn't today, the user is making
      // an explicit historical log, not narrating; rejecting it on a same-
      // day same-triple iOS write would block a legitimate workflow.
      const isBackfill = typeof a.session_date === 'string' && a.session_date !== today;
      const recent = isBackfill
        ? null
        : await findRecentMatchingSet(env.DB, userId, {
            exercise_id: exId,
            weight: Number(a.weight),
            reps: Number(a.reps),
            is_warmup: isWarmup,
          });
      if (recent) {
        const ageS = Math.max(0, Math.round((Date.now() - recent.logged_at) / 1000));
        return {
          error: 'recent_duplicate',
          message:
            `A ${a.weight}x${a.reps}${isWarmup ? ' warmup' : ''} set for ` +
            `${(ex as { name: string }).name} was already logged ${ageS}s ` +
            `ago (source=${recent.source}). This is almost certainly a ` +
            `duplicate from the user logging in iOS — do NOT retry, and ` +
            `do NOT tweak the numbers to bypass this. Use delete_set if ` +
            `the existing set is wrong.`,
          existing_set: recent,
        };
      }
      const existing = await getSetsForSession(env.DB, session.id);
      const setIndex =
        typeof a.set_index === 'number'
          ? a.set_index
          : existing.filter((s) => s.exercise_id === exId && !s.is_warmup).length + 1;
      const { set, deduped } = await logSet(env.DB, userId, {
        id: crypto.randomUUID(),
        session_id: session.id,
        exercise_id: exId,
        set_index: setIndex,
        weight: Number(a.weight),
        reps: Number(a.reps),
        rpe: a.rpe == null ? null : Number(a.rpe),
        is_warmup: a.is_warmup === true,
        notes: typeof a.notes === 'string' ? a.notes : null,
        duration_s: a.duration_s == null ? null : Number(a.duration_s),
        source: 'mcp',
      });
      // Surface the resolved exercise + per-side accounting so the agent
      // can confirm "45x8 each leg → 16 total reps, 720 lb tonnage" to the
      // user without a second lookup.
      const exLat = (ex as { laterality?: string }).laterality ?? 'bilateral';
      const exLoad = (ex as { load_mode?: string }).load_mode ?? 'total';
      const sides = exLat === 'unilateral' ? 2 : 1;
      const perHand = exLoad === 'per_hand';
      return {
        set,
        deduped,
        session_id: session.id,
        exercise: {
          id: exId,
          name: (ex as { name: string }).name,
          laterality: exLat,
          load_mode: exLoad,
        },
        effective: {
          sides,
          total_reps: set.reps * sides,
          tonnage: set.weight * set.reps * sides,
          // For two-dumbbell lifts, the weight is one dumbbell — surface a
          // ready-to-say phrasing so guidance never reads as the vague total.
          weight_display: perHand
            ? `${set.weight} lb in each hand`
            : `${set.weight} lb`,
        },
      };
    },
  },
  delete_set: {
    description:
      'Soft-delete a logged set by id — use this to undo a wrong log_set ' +
      'call (a phantom set you logged in error, or a true duplicate). The ' +
      'row is marked deleted (deleted_at set); history is preserved but ' +
      'it stops counting toward volume/sync. To find the set_id, call ' +
      'get_current_session or get_session_log first. For value ' +
      'corrections (wrong weight/reps), ask the user to fix it in iOS — ' +
      'there is no patch tool here.',
    inputSchema: obj(
      {
        set_id: { type: 'string', description: 'set_logs.id (UUID) to soft-delete' },
      },
      ['set_id'],
    ),
    write: true,
    handler: async (a, env, userId) => {
      const row = await patchSet(env.DB, userId, String(a.set_id), { deleted: true });
      return row ?? { error: 'not_found', set_id: a.set_id };
    },
    note: (a, r) =>
      r?.error
        ? null
        : `Deleted set ${a.set_id} (${r.weight}x${r.reps}${r.is_warmup ? ' warmup' : ''}).`,
  },
  log_activity: {
    description:
      'Log a non-strength activity — pilates, yoga, jump rope, walks, ' +
      'cardio, "anything else" — to the generic activities log. This is ' +
      'the bucket for movement OUTSIDE strength sessions (use log_set for ' +
      'lifts) and OUTSIDE intervals.icu cycling/running (which syncs ' +
      'automatically). `type` is free-form lower-case (e.g. "pilates", ' +
      '"yoga", "walk", "cardio", "other"). `date` defaults to the user\'s ' +
      'civil "today" in their device timezone if omitted. The activity ' +
      "id is generated server-side; Claude isn't an outbox retrying like " +
      'iOS, so client-side idempotency keys are unnecessary.',
    inputSchema: obj(
      {
        type: { type: 'string', description: 'lower-case freeform: pilates|cardio|yoga|walk|other|...' },
        title: { type: 'string', description: 'e.g. "Reformer class at Studio MDR"' },
        duration_minutes: { type: 'integer', minimum: 0 },
        date: { type: 'string', description: 'YYYY-MM-DD (default today in user tz)' },
        notes: { type: 'string' },
      },
      ['type'],
    ),
    write: true,
    handler: async (a, env, userId) => {
      const today = await ownerToday(env, userId);
      const date = typeof a.date === 'string' && a.date.length > 0 ? a.date : today;
      const type = String(a.type).toLowerCase().trim();
      if (!type) return { error: 'invalid_type' };
      const row = await logActivity(
        env.DB,
        userId,
        {
          id: crypto.randomUUID(),
          date,
          type,
          title: typeof a.title === 'string' ? a.title : null,
          duration_minutes:
            typeof a.duration_minutes === 'number' ? a.duration_minutes : null,
          notes: typeof a.notes === 'string' ? a.notes : null,
          logged_at: Date.now(),
        },
        'mcp',
      );
      const dur = row.duration_minutes != null ? `${row.duration_minutes}min ` : '';
      const msg = `Logged ${dur}${row.type} on ${row.date}${row.title ? ` — ${row.title}` : ''}`;
      return { ok: true, message: msg, activity: row };
    },
    // Audited like every write tool (dispatch loop calls writeAudit). The
    // `note` hook persists a Claude-authored note row, matching the pattern
    // used by delete_set / adjust_today so the activity has a visible
    // coaching trail.
    note: (_a, r) =>
      r?.error || !r?.activity
        ? null
        : `Logged activity: ${r.message}.`,
  },
  log_workout_complete: {
    description: 'Mark a session complete, optionally with perceived fatigue (1-10) and notes.',
    inputSchema: obj(
      {
        session_date: { type: 'string', description: 'YYYY-MM-DD (default today)' },
        perceived_fatigue: { type: 'integer', minimum: 1, maximum: 10 },
        notes: { type: 'string' },
      },
      [],
    ),
    write: true,
    handler: async (a, env, userId, bg) => {
      const date = typeof a.session_date === 'string' ? a.session_date : await ownerToday(env, userId);
      const s = await logWorkoutComplete(
        env.DB,
        userId,
        date,
        a.perceived_fatigue == null ? null : Number(a.perceived_fatigue),
        typeof a.notes === 'string' ? a.notes : null,
      );
      if (!s) return { error: 'no_active_plan' };
      // BEST-EFFORT one-way load export to intervals.icu. tryExport* is
      // fully self-guarded (never throws). BLOCKER-2 fix: when an execution
      // context is available, run it via waitUntil so the response returns
      // IMMEDIATELY and the (up to ~10s) intervals round-trip finishes
      // afterwards without being killed. Only if no ctx is plumbed (e.g. a
      // direct test/unit call) do we fall back to inline — still safe, just
      // not deferred. Either way the sacred path cannot throw or be blocked
      // by intervals.icu when a ctx is present.
      const exportP = tryExportSessionLoad(env.DB, env, userId, s.id);
      if (bg) bg.waitUntil(exportP);
      else await exportP;
      return s;
    },
  },
  add_note: {
    description:
      'Record a coaching note (your reasoning). scope: plan|session|exercise|general; ref_id optional.',
    inputSchema: obj(
      {
        scope: { type: 'string', enum: ['plan', 'session', 'exercise', 'general'] },
        ref_id: { type: 'string' },
        body: { type: 'string' },
      },
      ['scope', 'body'],
    ),
    write: true,
    handler: async (a, env, userId) => {
      await writeNote(
        env.DB,
        userId,
        String(a.scope),
        typeof a.ref_id === 'string' ? a.ref_id : null,
        'claude',
        String(a.body),
      );
      return { ok: true };
    },
  },
  update_plan: {
    description:
      'Replace the plan tree (days + exercises) transactionally. Exercise names must match the closed catalog — call list_exercises first to discover valid names (a single unknown name surfaces ALL unknowns at once in `queries: string[]`, not just the first). Pass expected_version for optimistic concurrency; a mismatch returns a conflict — refetch get_current_plan and reapply. Days are matched by day_label/name across the rebuild, so the weekly schedule follows surviving days; schedule entries for removed days are cleared.',
    inputSchema: obj(
      {
        name: { type: 'string' },
        meta: { type: 'object' },
        expected_version: { type: 'integer' },
        days: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              day_label: { type: 'string' },
              name: { type: 'string' },
              order_index: { type: 'integer' },
              notes: { type: 'string' },
              exercises: { type: 'array', items: { type: 'object' } },
            },
            required: ['name'],
          },
        },
      },
      ['days'],
    ),
    write: true,
    handler: (a, env, userId) =>
      updatePlanTree(env.DB, userId, a as unknown as Parameters<typeof updatePlanTree>[2]),
    note: (_a, r) =>
      r?.conflict || r?.error
        ? null
        : `Rebuilt plan: ${r.plan.days.length} day(s), v${r.plan.version}.`,
  },
  update_exercise: {
    description:
      'Patch one plan slot. Identify it by template_exercise_id, or by day (label/name) + exercise. Patchable keys: target_sets, target_reps, target_reps_max, target_rpe, rest_seconds, target_weight, cues, progression, order_index. Unknown keys are rejected with {error:"unknown_fields", fields:[...]} — no silent drop.',
    inputSchema: obj(
      {
        template_exercise_id: { type: 'string' },
        day: { type: 'string' },
        exercise: { type: 'string' },
        patch: { type: 'object' },
      },
      ['patch'],
    ),
    write: true,
    handler: async (a, env, userId) => {
      const r = await updateExercise(
        env.DB,
        userId,
        {
          template_exercise_id:
            typeof a.template_exercise_id === 'string' ? a.template_exercise_id : undefined,
          day: typeof a.day === 'string' ? a.day : undefined,
          exercise: typeof a.exercise === 'string' ? a.exercise : undefined,
        },
        (a.patch as Json) ?? {},
      );
      return r ?? { error: 'slot_not_found' };
    },
    note: (_a, r) => (r?.error ? null : `Updated slot ${r.id}.`),
  },
  swap_exercise: {
    description: 'Replace an exercise in a day with another (e.g. RDL → good mornings on Wednesday). Both names must match the closed catalog — use list_exercises to discover valid names.',
    inputSchema: obj(
      {
        day: { type: 'string', description: 'day label or name' },
        from_exercise: { type: 'string' },
        to_exercise: { type: 'string' },
        carry_targets: { type: 'boolean' },
      },
      ['day', 'from_exercise', 'to_exercise'],
    ),
    write: true,
    handler: async (a, env, userId) => {
      const r = await swapExercise(env.DB, userId, {
        day: String(a.day),
        from_exercise: String(a.from_exercise),
        to_exercise: String(a.to_exercise),
        carry_targets: a.carry_targets === true,
      });
      return r ?? { error: 'slot_not_found' };
    },
    note: (a, r) =>
      r?.error ? null : `Swapped ${a.from_exercise} → ${a.to_exercise} on ${a.day}.`,
  },
  add_exercise: {
    description: 'Add an exercise to a day in the active plan. `exercise` must match the closed catalog — use list_exercises to discover valid names. order_index defaults to max(existing)+1 (append dense), not the old 99 sentinel.',
    inputSchema: obj(
      {
        day: { type: 'string', description: 'day label or name' },
        exercise: { type: 'string' },
        target_sets: { type: 'integer' },
        target_reps: { type: 'integer' },
        target_reps_max: { type: 'integer' },
        target_rpe: { type: 'number' },
        rest_seconds: { type: 'integer' },
        target_weight: { type: 'number' },
        target_duration_s: { type: 'integer', description: 'Planned hold seconds for timed exercises (planks, holds); leave unset for conventional reps slots.' },
        progression: { type: 'object' },
        order_index: { type: 'integer' },
      },
      ['day', 'exercise', 'target_sets', 'target_reps'],
    ),
    write: true,
    handler: async (a, env, userId) => {
      const plan = await getActivePlan(env.DB, userId);
      if (!plan) return { error: 'no_active_plan' };
      const day = await env.DB.prepare(
        "SELECT d.id FROM day_templates d JOIN plans p ON p.id=d.plan_id WHERE p.user_id=?1 AND p.status='active' AND (d.day_label=?2 OR d.name=?2) LIMIT 1",
      )
        .bind(userId, String(a.day))
        .first<{ id: string }>();
      if (!day) return { error: 'day_not_found', day: a.day };
      const ex = await resolveExercise(env.DB, String(a.exercise));
      if (!ex) return { error: 'unknown_exercise', query: a.exercise };
      // Honor an explicit order_index; otherwise append densely (max+1)
      // instead of the old 99 sentinel, which stranded everything at the
      // bottom (P0 in the bug report).
      const orderIndex =
        typeof a.order_index === 'number'
          ? a.order_index
          : await nextExerciseOrderIndex(env.DB, day.id);
      return addTemplateExercise(env.DB, plan.id, {
        day_template_id: day.id,
        exercise_id: (ex as { id: string }).id,
        order_index: orderIndex,
        target_sets: Number(a.target_sets),
        target_reps: Number(a.target_reps),
        target_reps_max: a.target_reps_max == null ? null : Number(a.target_reps_max),
        target_rpe: a.target_rpe == null ? null : Number(a.target_rpe),
        rest_seconds: typeof a.rest_seconds === 'number' ? a.rest_seconds : 120,
        target_weight: a.target_weight == null ? null : Number(a.target_weight),
        target_duration_s:
          a.target_duration_s == null ? null : Number(a.target_duration_s),
        progression: a.progression == null ? null : JSON.stringify(a.progression),
        cues: null,
      });
    },
    note: (a, r) => (r?.error ? null : `Added ${a.exercise} to ${a.day}.`),
  },
  add_day: {
    description: 'Add a training day to the active plan (e.g. a deadlift day). Creates a plan if none exists.',
    inputSchema: obj(
      {
        name: { type: 'string' },
        day_label: { type: 'string' },
        order_index: { type: 'integer' },
      },
      ['name'],
    ),
    write: true,
    handler: async (a, env, userId) => {
      let plan = await getActivePlan(env.DB, userId);
      if (!plan) {
        const r = await updatePlanTree(env.DB, userId, { name: 'My Plan', days: [] });
        plan = (await getActivePlan(env.DB, userId))!;
        void r;
      }
      // Append densely (max+1) rather than the old 99 sentinel — same
      // fix the add_exercise path got. Honors an explicit order_index.
      const orderIndex =
        typeof a.order_index === 'number'
          ? a.order_index
          : await nextDayOrderIndex(env.DB, plan.id);
      return addDayTemplate(
        env.DB,
        plan.id,
        String(a.name),
        typeof a.day_label === 'string' ? a.day_label : null,
        orderIndex,
      );
    },
    note: (a) => `Added day "${a.name}".`,
  },
  update_day: {
    description:
      "Patch a day template's metadata in the active plan: `name`, `day_label`, `order_index`, `notes`. Identify the day by `day_template_id` OR by `day` (label/name). Bumps the plan version. Unknown patch keys → `{error:'unknown_fields', fields}`. To change exercises within a day, use add_exercise / update_exercise / delete_exercise / swap_exercise.",
    inputSchema: obj(
      {
        day_template_id: { type: 'string' },
        day: { type: 'string', description: 'day label or name (used when day_template_id is omitted)' },
        patch: { type: 'object' },
      },
      ['patch'],
    ),
    write: true,
    handler: async (a, env, userId) => {
      const plan = await getActivePlan(env.DB, userId);
      if (!plan) return { error: 'no_active_plan' };
      let dayId: string | null = null;
      if (typeof a.day_template_id === 'string') {
        dayId = a.day_template_id;
      } else if (typeof a.day === 'string') {
        const row = await env.DB
          .prepare(
            "SELECT id FROM day_templates WHERE plan_id = ?1 AND (day_label = ?2 OR name = ?2) LIMIT 1",
          )
          .bind(plan.id, a.day)
          .first<{ id: string }>();
        dayId = row?.id ?? null;
      }
      if (!dayId) return { error: 'day_not_found' };
      const r = await patchDayTemplate(env.DB, plan.id, dayId, (a.patch as Json) ?? {});
      return r ?? { error: 'day_not_found' };
    },
    note: (_a, r) =>
      r?.error
        ? null
        : `Updated day "${(r as { name: string }).name}".`,
  },
  delete_exercise: {
    description:
      'Remove an exercise slot from a day in the active plan. Identify it by `template_exercise_id` OR by `day` (label/name) + `exercise`. NULLs any historical `set_logs.template_exercise_id` that pointed at this slot (sets are kept, queryable by exercise_id; the slot pointer is detached). Bumps the plan version. For substitution, use `swap_exercise` instead.',
    inputSchema: obj(
      {
        template_exercise_id: { type: 'string' },
        day: { type: 'string' },
        exercise: { type: 'string' },
      },
      [],
    ),
    write: true,
    handler: async (a, env, userId) => {
      const r = await deleteTemplateExercise(env.DB, userId, {
        template_exercise_id:
          typeof a.template_exercise_id === 'string' ? a.template_exercise_id : undefined,
        day: typeof a.day === 'string' ? a.day : undefined,
        exercise: typeof a.exercise === 'string' ? a.exercise : undefined,
      });
      return r ?? { error: 'slot_not_found' };
    },
    note: (_a, r) =>
      r?.error ? null : `Deleted exercise slot ${r.id}.`,
  },
  adjust_today: {
    description:
      "\"I'm beat — adjust.\" Scales target sets (reduce_volume/deload) or weight (reduce_intensity) for a day (day_label) or the whole plan, and records why.",
    inputSchema: obj(
      {
        intent: { type: 'string', enum: ['deload', 'reduce_volume', 'reduce_intensity'] },
        magnitude: { type: 'string', enum: ['light', 'moderate', 'heavy'] },
        day_label: { type: 'string' },
        reason: { type: 'string', description: 'why — stored as a coaching note' },
      },
      ['intent'],
    ),
    write: true,
    handler: (a, env, userId) =>
      adjustToday(
        env.DB,
        userId,
        a.intent as 'deload' | 'reduce_volume' | 'reduce_intensity',
        (a.magnitude as 'light' | 'moderate' | 'heavy') ?? 'moderate',
        typeof a.day_label === 'string' ? a.day_label : undefined,
      ),
    note: (a, r) =>
      `${a.intent}(${a.magnitude ?? 'moderate'})${a.day_label ? ` ${a.day_label}` : ''}: ` +
      `${r?.changes?.length ?? 0} change(s).` +
      (typeof a.reason === 'string' ? ` Reason: ${a.reason}` : ''),
  },
  set_schedule: {
    description:
      'Set the PERMANENT recurring weekly training pattern (which day template runs each weekday — Mon..Sun). This is the standing routine, not a one-off: it repeats every week and drives the future calendar. Pass `week` as a full map keyed mon/tue/wed/thu/fri/sat/sun; each value is a day template id, day_label, or day name, or null for a rest day. Omitted weekdays become rest. Optionally pass expected_version for optimistic concurrency (mismatch → conflict, refetch get_current_plan and reapply). Bumps the plan version. For a single specific date use set_planned_session / skip_planned_session instead.',
    inputSchema: obj(
      {
        week: {
          type: 'object',
          description: 'Keys mon..sun → day id/label/name or null (rest).',
          properties: {
            mon: { type: ['string', 'null'] },
            tue: { type: ['string', 'null'] },
            wed: { type: ['string', 'null'] },
            thu: { type: ['string', 'null'] },
            fri: { type: ['string', 'null'] },
            sat: { type: ['string', 'null'] },
            sun: { type: ['string', 'null'] },
          },
          additionalProperties: false,
        },
        expected_version: { type: 'integer' },
      },
      ['week'],
    ),
    write: true,
    handler: async (a, env, userId) => {
      const week = (a.week as Record<string, string | null>) ?? {};
      const r = await setPlanSchedule(
        env.DB,
        userId,
        week as Partial<Record<Weekday, string | null>>,
        typeof a.expected_version === 'number' ? a.expected_version : null,
      );
      return r;
    },
    note: (_a, r) =>
      r?.ok
        ? `Set recurring weekly schedule (v${r.version}): ` +
          (['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'] as const)
            .map((d) => `${d}:${r.schedule.week[d] ?? 'rest'}`)
            .join(' ')
        : null,
  },
  set_planned_session: {
    description:
      'Pin ONE specific calendar date to a training day (a single-date override, NOT a recurring change). Use this for "next Saturday do legs" — it does not alter the standing weekly pattern and does not bump the plan version. `day` accepts a day template id, day_label, or name. For the permanent weekly routine use set_schedule.',
    inputSchema: obj(
      {
        date: { type: 'string', description: 'YYYY-MM-DD (device-local)' },
        day: { type: 'string', description: 'day template id, label, or name' },
      },
      ['date', 'day'],
    ),
    write: true,
    handler: async (a, env, userId) =>
      setPlannedSession(env.DB, userId, String(a.date), String(a.day)),
    note: (a, r) =>
      r?.ok ? `Planned ${a.date} → day "${a.day}" (one-off, no plan change).` : null,
  },
  skip_planned_session: {
    description:
      'Mark ONE specific calendar date as a rest/skip day (single-date override, NOT recurring). Use for "skip this Friday". Does not change the standing weekly pattern and does not bump the plan version.',
    inputSchema: obj(
      { date: { type: 'string', description: 'YYYY-MM-DD (device-local)' } },
      ['date'],
    ),
    write: true,
    handler: async (a, env, userId) => skipPlannedSession(env.DB, userId, String(a.date)),
    note: (a, r) => (r?.ok ? `Skipped ${a.date} (one-off rest, no plan change).` : null),
  },
  refresh_rides: {
    description:
      'Force an immediate refresh from intervals.icu (the cron also does this every 6h): both the PLANNED cycling/endurance calendar (upcoming rides) AND the COMPLETED activity feed (rides/runs you finished, with their actual duration/power/HR). Returns how many of each are cached and the sync status. Does NOT change the training plan or its version. No-op if the intervals.icu integration is not configured.',
    inputSchema: obj({}),
    // An action → audited. Reconciled caches only: NO plans.version bump and
    // (no `note`) NO notes row.
    write: true,
    handler: async (_a, env, userId) => {
      const r = await syncExternalEvents(env.DB, env, { userId });
      const a = await syncExternalActivities(env.DB, env, { userId });
      return {
        rides: { synced: r.synced, status: r.status, ...(r.detail ? { detail: r.detail } : {}) },
        activities: {
          synced: a.synced,
          status: a.status,
          ...(a.detail ? { detail: a.detail } : {}),
        },
      };
    },
  },
  get_recent_activities: {
    description:
      'Get COMPLETED endurance activities recorded in intervals.icu (rides, runs, swims) with their actuals: duration, average/normalized power, average/max heart rate, distance, elevation, TSS. `range` is a day count back from today (default 30, max 365); `limit` caps the count (default 20). Use this to see what endurance work has actually been done when coaching around lifting.',
    inputSchema: obj(
      {
        range: { type: 'integer', minimum: 1, maximum: 365, description: 'days back (default 30)' },
        limit: { type: 'integer', minimum: 1, maximum: 200, description: 'max results (default 20)' },
      },
      [],
    ),
    handler: async (a, env, userId) => {
      const range = typeof a.range === 'number' ? Math.min(365, Math.max(1, a.range)) : 30;
      const limit = typeof a.limit === 'number' ? Math.min(200, Math.max(1, a.limit)) : 20;
      const today = await ownerToday(env, userId);
      const acts = await getRecentActivities(env.DB, userId, { to: today, range, limit });
      return {
        to: today,
        range,
        activities: acts.map((x) => ({
          id: x.id,
          date: x.date,
          kind: x.kind,
          name: x.name,
          moving_time_sec: x.moving_time_sec,
          distance_m: x.distance_m,
          average_watts: x.average_watts,
          weighted_avg_watts: x.weighted_avg_watts,
          average_hr: x.average_hr,
          max_hr: x.max_hr,
          training_load: x.training_load,
          intensity: x.intensity,
          calories: x.calories,
          elevation_gain_m: x.elevation_gain_m,
        })),
      };
    },
  },
  get_group_feed: {
    description:
      'See the recent training activity of the people in a group — strength sessions (with top sets), intervals.icu rides, and free-form activities (pilates, yoga, walks) from every member, interleaved by recency. Pass `group_id` for a specific group or omit to default to the first group the user is in. `range` is "7d" | "14d" | "30d" (default 7d) and ALSO returns per-member workout_count + streak_days so you can compare. Use this to answer questions like "how is the group doing this week?" or "did Sarah lift yesterday?". Read-only; does not log anything. Privacy contract: a strength session here exposes the day name + top set per exercise but NEVER the session notes, perceived fatigue, set notes, or set-level RPE — those stay private to the lifter.',
    inputSchema: obj(
      {
        group_id: { type: 'string', description: 'Group id (UUID). Omit to default to the first group the user belongs to.' },
        range: { type: 'string', description: '7d | 14d | 30d (default 7d)' },
        limit: { type: 'integer', minimum: 1, maximum: 100, description: 'Max feed items (default 30)' },
      },
      [],
    ),
    handler: async (a, env, userId) => {
      // Resolve target group: explicit `group_id` (and verify caller is in
      // it — same 403/404 collapse the REST surface uses since MCP can't
      // distinguish a stranger vs a stale id any better) OR the caller's
      // first group via listGroupsForUser. The "no groups yet" empty-state
      // is a normal return value, not an error.
      const groups = await listGroupsForUser(env.DB, userId);
      let groupId: string | undefined;
      if (typeof a.group_id === 'string' && a.group_id.length > 0) {
        groupId = a.group_id;
        if (!(await isGroupMember(env.DB, userId, groupId))) {
          return { error: 'forbidden_or_not_found', group_id: groupId };
        }
      } else if (groups.length > 0) {
        groupId = groups[0]!.id;
      } else {
        return { groups: [], items: [], stats: [], note: 'You are not in any groups yet.' };
      }
      // range: same accepted set as the REST endpoint.
      const rangeStr = typeof a.range === 'string' ? a.range : '7d';
      const m = /^(\d+)d$/.exec(rangeStr);
      const days = m ? Math.max(1, Math.min(365, Number(m[1]))) : 7;
      const limit =
        typeof a.limit === 'number' ? Math.max(1, Math.min(100, Math.floor(a.limit))) : 30;
      const items = await getGroupFeed(env.DB, groupId, null, limit, userId);
      const stats = await getGroupStats(env.DB, groupId, days, userId);
      const groupName = groups.find((g) => g.id === groupId)?.name ?? null;
      return {
        group_id: groupId,
        group_name: groupName,
        range: `${days}d`,
        items,
        stats,
      };
    },
  },
};

// ---- resource + prompt ---------------------------------------------------

const STATE_URI = 'coach://state/current';

async function buildStateBrief(env: Env, userId: string): Promise<string> {
  const tree = await getPlanTree(env.DB, userId);
  const recent = await getRecentSessions(env.DB, userId, 1);
  const last = recent[0] ?? null;
  const lastSets = last ? await getSetsForSession(env.DB, last.id) : [];
  const schedule = tree ? await getResolvedScheduleNames(env.DB, userId) : null;
  const today = await ownerToday(env, userId);
  // Most recent COMPLETED session — the real training context, unobscured
  // by an intervening skip/planned row that getRecentSessions surfaces.
  const lastCompleted = await getLastCompletedSession(env.DB, userId);
  const lastCompletedSets = lastCompleted
    ? await getSetsForSession(env.DB, lastCompleted.id)
    : [];
  // Cycling awareness, zero extra Claude calls: a compact 28-day ride
  // window + conflicts folded straight into the auto-loaded brief.
  const horizon = addDaysIso(today, 28);
  const rides = await getUpcomingRides(env.DB, userId, { from: today, range: 28 });
  const conflicts = await getRideConflicts(env.DB, userId, today, horizon, today);
  // Completed endurance actuals (last 14d) so the coach sees real ride/run
  // load without an extra call. Empty when the integration is dormant.
  const recentActivities = await getRecentActivities(env.DB, userId, {
    to: today,
    range: 14,
    limit: 10,
  });
  const brief = {
    today,
    active_plan: tree
      ? {
          name: tree.name,
          version: tree.version,
          weekly_schedule: schedule,
          days: tree.days.map((d) => ({
            label: d.day_label,
            name: d.name,
            exercises: d.exercises.length,
          })),
        }
      : null,
    last_session: last
      ? {
          date: last.date,
          status: last.status,
          perceived_fatigue: last.perceived_fatigue,
          key_sets: lastSets
            .filter((s) => !s.is_warmup)
            .map((s) => `ex:${s.exercise_id} ${s.weight}x${s.reps}${s.rpe ? `@${s.rpe}` : ''}`),
        }
      : null,
    last_completed_session:
      lastCompleted && lastCompleted.id !== last?.id
        ? {
            date: lastCompleted.date,
            status: lastCompleted.status,
            perceived_fatigue: lastCompleted.perceived_fatigue,
            key_sets: lastCompletedSets
              .filter((s) => !s.is_warmup)
              .map((s) => `ex:${s.exercise_id} ${s.weight}x${s.reps}${s.rpe ? `@${s.rpe}` : ''}`),
          }
        : null,
    // Upcoming endurance load + lift/ride conflicts (next 28 days). Empty
    // arrays when the intervals.icu integration is dormant or clear.
    upcoming_rides: rides.map((r) => ({
      date: r.date,
      kind: r.kind,
      title: r.title,
      training_load: r.training_load,
      planned_duration_sec: r.planned_duration_sec,
    })),
    ride_conflicts: conflicts,
    // Recently COMPLETED endurance work (actuals from intervals.icu).
    recent_activities: recentActivities.map((a) => ({
      date: a.date,
      kind: a.kind,
      name: a.name,
      moving_time_sec: a.moving_time_sec,
      distance_m: a.distance_m,
      average_watts: a.average_watts,
      average_hr: a.average_hr,
      training_load: a.training_load,
    })),
  };
  return [
    '# lift-coach — current state',
    'Auto-loaded context. Use the tools for anything deeper.',
    '```json',
    JSON.stringify(brief, null, 2),
    '```',
  ].join('\n');
}

// ---- JSON-RPC dispatch ---------------------------------------------------

async function dispatch(
  req: RpcRequest,
  env: Env,
  userId: string,
  bg?: BgScheduler,
) {
  switch (req.method) {
    case 'initialize': {
      const requested = (req.params?.protocolVersion as string) ?? DEFAULT_PROTOCOL;
      return ok(req.id, {
        protocolVersion: SUPPORTED_PROTOCOLS.has(requested) ? requested : DEFAULT_PROTOCOL,
        capabilities: { tools: {}, resources: {}, prompts: {} },
        serverInfo: SERVER_INFO,
        instructions: SERVER_INSTRUCTIONS,
      });
    }
    case 'ping':
      return ok(req.id, {});
    case 'tools/list':
      return ok(req.id, {
        tools: Object.entries(TOOLS).map(([name, t]) => ({
          name,
          description: t.description,
          inputSchema: t.inputSchema,
        })),
      });
    case 'tools/call': {
      const name = req.params?.name as string;
      const tool = TOOLS[name];
      if (!tool) return err(req.id, -32602, `unknown tool: ${name}`);
      try {
        const args = (req.params?.arguments as Json) ?? {};
        const result = await tool.handler(args, env, userId, bg);
        if (tool.write) {
          await writeAudit(env.DB, userId, name, args, JSON.stringify(result));
          const noteBody = tool.note?.(args, result);
          if (noteBody) await writeNote(env.DB, userId, 'plan', null, 'claude', noteBody);
        }
        return ok(req.id, {
          content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
        });
      } catch (e) {
        return ok(req.id, {
          content: [{ type: 'text', text: `error: ${(e as Error).message}` }],
          isError: true,
        });
      }
    }
    case 'resources/list':
      return ok(req.id, {
        resources: [
          {
            uri: STATE_URI,
            name: 'Current coaching state',
            description: 'Active plan summary + last session. Read this at chat start.',
            mimeType: 'text/markdown',
          },
        ],
      });
    case 'resources/templates/list':
      return ok(req.id, { resourceTemplates: [] });
    case 'resources/read': {
      const uri = req.params?.uri as string;
      if (uri !== STATE_URI) return err(req.id, -32602, `unknown resource: ${uri}`);
      return ok(req.id, {
        contents: [
          { uri: STATE_URI, mimeType: 'text/markdown', text: await buildStateBrief(env, userId) },
        ],
      });
    }
    case 'prompts/list':
      return ok(req.id, {
        prompts: [
          { name: 'coach_brief', description: 'Load current training state and act as the coach.' },
        ],
      });
    case 'prompts/get': {
      if ((req.params?.name as string) !== 'coach_brief') {
        return err(req.id, -32602, 'unknown prompt');
      }
      return ok(req.id, {
        description: 'Coach brief',
        messages: [
          {
            role: 'user',
            content: {
              type: 'text',
              text:
                'You are my strength coach. Here is my current state:\n\n' +
                (await buildStateBrief(env, userId)) +
                '\n\nUse the lift-coach tools to read history and adapt the plan as we talk.',
            },
          },
        ],
      });
    }
    default:
      return err(req.id, -32601, `method not found: ${req.method}`);
  }
}

/** Handle one POST body (single request only; batching removed in spec). */
export async function handleMcp(
  body: unknown,
  env: Env,
  bg?: BgScheduler,
): Promise<{ status: number; json?: unknown }> {
  const req = body as RpcRequest;
  if (!req || req.jsonrpc !== '2.0' || typeof req.method !== 'string') {
    return { status: 400, json: err(null, -32600, 'invalid request') };
  }
  const userId = (await ensureOwnerUser(env.DB, env.OWNER_APPLE_SUB)).id;
  // Notifications (no id) get a bare 202 with no body, per spec.
  if (req.id === undefined || req.id === null) {
    if (req.method.startsWith('notifications/')) return { status: 202 };
  }
  return { status: 200, json: await dispatch(req, env, userId, bg) };
}
