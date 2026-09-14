import { ATTRIBUTION_INSTRUCTIONS } from '../dataAttribution';
import { coachingSession, coachingPlanMeta } from '../coachingContext';
import { TRAINING_PROFILE_COACH_GUIDANCE } from '../trainingProfile';
import { workoutInput, workoutWire } from '../workoutWire';
import { workoutDB } from '../workoutSchema';
// Minimal, spec-correct MCP server over Streamable HTTP (JSON-RPC 2.0,
// single application/json responses — no server-initiated streams needed
// for read tools). Stateless: no Mcp-Session-Id required. All data access
// goes through src/db.ts, identical to REST.
import type { Env } from '../types';
import { coachGroupSlots, coachGroupSummary } from '../exerciseGroupViews';
import { resolvedScheduleNames } from '../planViews';
import {
  hasField,
  invalidFields,
  isNonEmptyString,
  isNonNegativeInteger,
  isPositiveInteger,
} from '../validation';
import { isGroupId } from '../exerciseGroups';
import {
  getTrainingProfile,
  addWorkoutAtVersion,
  addTemplateExercise,
  addTrip,
  setGroup,
  clearGroup,
  adjustToday,
  deleteTemplateExercise,
  deleteWorkout,
  discardSession,
  findRecentMatchingSet,
  findMcpExerciseGroupAcknowledgement,
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
  getRideConflicts,
  getSessionByDate,
  getSetsForSession,
  getSetsForSessions,
  getUpcomingRides,
  getUserTimezone,
  getVolume,
  getWorkoutSummary,
  ensureActivePlan,
  isGroupMember,
  listPlanHistory,
  listGroupsForUser,
  logActivity,
  logSet,
  logWorkoutComplete,
  nextWorkoutOrderIndex,
  nextExerciseOrderIndex,
  patchWorkoutAtVersion,
  patchSet,
  resolveExercise,
  restorePlanSnapshot,
  comparePlanVersions,
  removeTrip,
  setPeriodization,
  setPlanSchedule,
  setPlannedSession,
  setRace,
  setStressModel,
  SessionWriteConflictError,
  skipPlannedSession,
  todayInTz,
  swapExercise,
  syncExternalActivities,
  syncExternalEvents,
  updateExercise,
  updatePlanTree,
  updateTrip,
  writeAudit,
  writeNote,
} from '../db';
import { parsePlanMeta } from '../types';
import { logUnexpectedError, publicToolErrorCode } from '../errors';
import type {
  PeriodizationPhase,
  RaceGoal,
  StressModel,
  Trip,
  TripType,
  Weekday,
} from '../types';

const SERVER_INFO = { name: 'tres-fort', version: '0.1.0' };
// Host-injected system instructions (MCP `initialize.instructions`). Shapes
// how the model uses these tools — specifically the no-auto-log policy that
// stops phantom/duplicate set_logs when the user is just narrating a workout
// they are already logging in the iOS app.
const SERVER_INSTRUCTIONS =
  "You are the user's strength coach. Start by calling get_coach_brief. " +
  "The iOS app is the primary set " +
  'logger: the user records their own reps and weights in the gym. Your ' +
  'job in chat is to coach (review history, adapt the plan, motivate, ' +
  'answer questions) — NOT to mirror what they are logging. Do NOT call ' +
  'log_set unless the user explicitly asks you to log/record/add a set ' +
  '("log this", "add 225x5", "I forgot to log my warmup"). Narration like ' +
  '"set 2 down", "5x135", "just hit a PR", or "that felt easy" is a ' +
  'status update — acknowledge it, do not log. Sets with source="ios" in ' +
  'get_current_session / get_today_workout are evidence the user is ' +
  'logging in-app right now; assume any set they mention is already ' +
  'recorded. When in doubt, ask before logging. Use correct_set for value ' +
  'mistakes and delete_set only to remove a phantom or duplicate set. ' + TRAINING_PROFILE_COACH_GUIDANCE;
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

interface ToolBase {
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
  /** Appends records without replacing or deleting existing user data. */
  appendOnly?: boolean;
  /** The service writes its own audit trail; do not duplicate it in dispatch. */
  handlerAudited?: boolean;
}

/**
 * `atomicWrite` and `note` are mutually exclusive: the dispatcher consults
 * `note` only on the non-atomic, non-handler-audited path, so a plan writer
 * that commits its audit/note inside the same D1 transaction can never have
 * a dispatcher note run. The type keeps a dead hook from being re-added.
 */
type Tool =
  | (ToolBase & {
      /** Plan writer persisted its audit/note in the same D1 transaction. */
      atomicWrite: true;
      note?: never;
    })
  | (ToolBase & {
      atomicWrite?: false;
      note?: (args: Json, result: any) => string | null;
    });

const obj = (props: Json, required: string[] = []): Json => ({
  type: 'object',
  properties: props,
  required,
  additionalProperties: false,
});

function addWorkoutTool(operation: 'add_day' | 'add_workout'): Tool {
  const tool: Tool = {
    description: 'Create a reusable workout in the active plan. Scheduling is optional; the workout can stay on demand. Creates a plan if none exists.',
    inputSchema: obj(
      {
        name: { type: 'string' },
        day_label: { type: 'string' },
        order_index: { type: 'integer' },
      },
      ['name'],
    ),
    write: true,
    // Inserting at an occupied index rewrites existing workout order values.
    atomicWrite: true,
    handler: async (a, env, userId) => {
      let plan = await getActivePlan(env.DB, userId);
      if (!plan) {
        plan = (await ensureActivePlan(env.DB, userId, 'My Plan', {
          actor: 'mcp', operation: 'ensure_active_plan', args: { name: 'My Plan' },
        })).plan;
      }
      // Append densely (max+1) rather than the old 99 sentinel — same
      // fix the add_exercise path got. Honors an explicit order_index.
      const orderIndex =
        typeof a.order_index === 'number'
          ? a.order_index
          : await nextWorkoutOrderIndex(env.DB, plan.id);
      return addWorkoutAtVersion(
        env.DB,
        userId,
        plan,
        String(a.name),
        typeof a.day_label === 'string' ? a.day_label : null,
        orderIndex,
        { actor: 'mcp', operation, args: a, note: `Added workout "${a.name}".` },
      );
    },
  };
  if (operation === 'add_day') tool.description += ' Deprecated name: use add_workout. Supported for one TestFlight compatibility cycle.';
  return tool;
}

function updateWorkoutTool(operation: 'update_day' | 'update_workout'): Tool {
  const tool: Tool = {
    description:
      "Patch a reusable workout's metadata in the active plan: `name`, `day_label`, `order_index`, `notes`. Identify the workout by `workout_id` OR by `day` (label/name). Bumps the plan version. Unknown patch keys → `{error:'unknown_fields', fields}`. To change exercises within a workout, use add_exercise / update_exercise / delete_exercise / swap_exercise.",
    inputSchema: obj(
      {
        workout_id: { type: 'string' },
        day_template_id: { type: 'string', description: 'Deprecated alias for workout_id.' },
        day: { type: 'string', description: 'day label or name (used when workout_id is omitted)' },
        patch: { type: 'object' },
      },
      ['patch'],
    ),
    write: true,
    atomicWrite: true,
    handler: async (a, env, userId) => {
      const plan = await getActivePlan(env.DB, userId);
      if (!plan) return { error: 'no_active_plan' };
      let dayId: string | null = null;
      if (typeof a.workout_id === 'string') {
        dayId = a.workout_id;
      } else if (typeof a.day === 'string') {
        const row = await workoutDB(env.DB)
          .prepare(
            "SELECT id FROM workouts WHERE plan_id = ?1 AND (day_label = ?2 OR name = ?2) LIMIT 1",
          )
          .bind(plan.id, a.day)
          .first<{ id: string }>();
        dayId = row?.id ?? null;
      }
      if (!dayId) return { error: 'day_not_found' };
      const r = await patchWorkoutAtVersion(
        env.DB,
        userId,
        plan,
        dayId,
        (a.patch as Json) ?? {},
        { actor: 'mcp', operation, args: a, note: 'Updated workout.' },
      );
      return r ?? { error: 'day_not_found' };
    },
  };
  if (operation === 'update_day') tool.description += ' Deprecated name: use update_workout. Supported for one TestFlight compatibility cycle.';
  return tool;
}

const TOOLS: Record<string, Tool> = {
  get_coach_brief: {
    description: 'Start a coaching conversation here. Read the current training plan, recent sessions, feedback, activity context and coaching rules. Available to clients that do not load MCP resources or prompts.',
    inputSchema: obj({}),
    handler: async (_args, env, userId) => ({
      instructions: SERVER_INSTRUCTIONS,
      brief: await buildStateBrief(env, userId),
    }),
  },
  get_current_plan: {
    description:
      'Get the active training plan: reusable workouts with optional recurring scheduling, exercises, target sets/reps/RPE, rest, progression rules, and form cues.',
    inputSchema: obj({}),
    handler: async (_a, env, userId) => {
      const tree = await getPlanTree(env.DB, userId);
      const training_profile = await getTrainingProfile(env.DB, userId);
      if (!tree) return { plan: null, training_profile, note: 'No active plan yet.' };
      // Fold in the resolved recurring weekly schedule (weekday → day name),
      // projected from the tree already in hand.
      const schedule = resolvedScheduleNames(tree);
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
      // Authored multisport intent rides along so the coach can reason over
      // the goal/phases/trips/stress model in one read (docs/MULTISPORT.md §9).
      const meta = parsePlanMeta(tree.meta);
      return {
        ...tree,
        training_profile,
        workouts: tree.workouts.map((day) => ({ ...day, exercises: coachGroupSlots(day.exercises) })),
        schedule,
        ride_conflicts,
        race: meta.race ?? null,
        periodization: meta.periodization ?? [],
        trips: meta.trips ?? [],
        stress_model: meta.stress_model ?? null,
      };
    },
  },
  get_plan_history: {
    description:
      'List recent immutable versions of the active plan, including who changed it, why, and a compact summary. Use this before offering a restore.',
    inputSchema: obj({
      limit: { type: 'integer', minimum: 1, maximum: 100 },
      before_version: { type: 'integer', minimum: 1 },
    }),
    handler: async (a, env, userId) => {
      const fields = invalidFields(a, {}, {
        limit: (value) => isPositiveInteger(value) && (value as number) <= 100,
        before_version: isPositiveInteger,
      });
      if (fields.length > 0) return { error: 'invalid_fields', fields };
      return listPlanHistory(
        env.DB, userId,
        typeof a.limit === 'number' ? a.limit : 30,
        typeof a.before_version === 'number' ? a.before_version : undefined,
      );
    },
  },
  compare_plan_versions: {
    description:
      'Compare an older selected plan version with the current plan (default) or another captured version. Results are labeled from_version → to_version.',
    inputSchema: obj({
      from_version: { type: 'integer', minimum: 1 },
      to_version: { type: 'integer', minimum: 1 },
    }, ['from_version']),
    handler: async (a, env, userId) => {
      const fields = invalidFields(a, { from_version: isPositiveInteger }, {
        to_version: isPositiveInteger,
      });
      if (fields.length > 0) return { error: 'invalid_fields', fields };
      return comparePlanVersions(
        env.DB, userId, a.from_version as number,
        typeof a.to_version === 'number' ? a.to_version : undefined,
      );
    },
  },
  restore_plan: {
    description:
      'Restore a captured version of the active plan as a NEW version. First compare the selected version with current. Requires the current plan id and expected version; rejects stale, foreign-plan, and active-workout attempts.',
    inputSchema: obj({
      snapshot_version: { type: 'integer', minimum: 1 },
      plan_id: { type: 'string' },
      expected_version: { type: 'integer', minimum: 1 },
      reason: { type: 'string' },
    }, ['snapshot_version', 'plan_id', 'expected_version']),
    handler: async (a, env, userId) => {
      const fields = invalidFields(a, {
        snapshot_version: isPositiveInteger,
        plan_id: isNonEmptyString,
        expected_version: isPositiveInteger,
      }, { reason: (value) => typeof value === 'string' });
      if (fields.length > 0) return { error: 'invalid_fields', fields };
      return restorePlanSnapshot(env.DB, userId, {
        snapshot_version: a.snapshot_version as number,
        plan_id: (a.plan_id as string).trim(),
        expected_version: a.expected_version as number,
        actor: 'mcp', reason: typeof a.reason === 'string' ? a.reason : null,
      });
    },
    write: true,
    atomicWrite: true,
    // restorePlanSnapshot persists its audit, note, and resulting snapshot in
    // the same D1 transaction as the restore; dispatcher-level writes would
    // duplicate the trail and could fail after acknowledgement.
  },
  get_today_workout: {
    description:
      "Get today's workout: the date, any existing session for today, the reusable workout library, the recurring weekly schedule (so you can answer 'what should I do today?' from one call), and prior-session context. `last_session` is the most recent non-discarded session of ANY status (could be a skip/planned row); `last_completed_session` is the most recent COMPLETED session — use that for real training context, since a skipped day in between obscures `last_session`.",
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
      const schedule = tree ? resolvedScheduleNames(tree) : null;
      return {
        date,
        session,
        sets: session ? await getSetsForSession(env.DB, session.id) : [],
        plan_workouts: tree?.workouts.map((day) => ({ ...day, exercises: coachGroupSlots(day.exercises) })) ?? [],
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
    description: 'Get logged sessions and their persisted completion summary: work, same-load rep/hold records, and differences from targets captured when logging began. Missing historical targets are unavailable. Pass a date (YYYY-MM-DD) or recent_n for the last N.',
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
        return s ? [{ session: s, sets: await getSetsForSession(env.DB, s.id), summary: await getWorkoutSummary(env.DB, userId, s.id) }] : [];
      }
      const n = typeof a.recent_n === 'number' ? a.recent_n : 5;
      const sessions = await getRecentSessions(env.DB, userId, n);
      return Promise.all(
        sessions.map(async (s) => ({ session: s, sets: await getSetsForSession(env.DB, s.id), summary: await getWorkoutSummary(env.DB, userId, s.id) })),
      );
    },
  },
  get_history: {
    description:
      'Get set history for one exercise (by name or id, e.g. "bench"). Compare reps and holds only within the returned cohorts (same exercise/variation, execution mode and exact external load). Mixed bodyweight/hold conditions have no overall top set. Bodyweight est_1rm is always null, including positive added load; Epley is only for conventional loaded rep work. Pooled total reps describe work, not strength progress. Nullable tonnage measures positive external-load volume only, never bodyweight system load.',
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
      'Get weekly logged working-set counts (legacy hard_sets), primary-muscle attribution and recorded-effort coverage, plus positive external-load volume (tonnage_basis=external_load) for a muscle group (e.g. "chest","quads","back") over a range. Tonnage is null for unsupported work or mixed units. external_load_volume keeps each unit separate; negative assistance never subtracts. Counts are logged rows, not measured stimulus or complete muscle volume.',
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
      'List the exercise catalog so you can discover what is resolvable BEFORE calling add_exercise / update_plan (those reject unknown names with `unknown_exercise`). Optional filters: `query` (case-insensitive substring on name), `muscle` (primary_muscle exact, e.g. "quads"), `modality` (e.g. "barbell","dumbbell","bw","machine","timed"). Each row includes `laterality` ("bilateral" | "unilateral"); unilateral exercises log reps per-side, and the system doubles for total reps / tonnage (see log_set). Each row also includes `load_mode` ("total" | "per_hand"); for "per_hand" two-dumbbell lifts the weight is ONE dumbbell — set target_weight and phrase guidance per hand ("25 lb each hand"), never the doubled total. Tonnage independently counts both implements, so a per_hand + unilateral lift gets both multipliers. Returns up to a few hundred rows in the seeded catalog; combine filters to narrow.',
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
      "Get cached intervals.icu planned endurance events and a scheduling heuristic against projected lift dates. Range is days from today (default 30, max 90). Legacy clash/heavy-next-day mean training_load >=150 or planned_duration_sec >=9000 on the same/next civil day. Brick means both measures are known below thresholds; unknown means inputs are incomplete without threshold evidence. These labels do not prove easy work, intended pairing, individualized safety or interference; strength load/muscle data is not an input.",
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
        conflict_basis: 'scheduling_heuristic',
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
      'server also rejects an ambiguous same exercise/weight/reps set ' +
      'logged by iOS within the last 120 seconds (error: ' +
      '"recent_duplicate"); that signal almost always means iOS already ' +
      'logged it — do NOT retry or tweak the numbers. A distinct explicit ' +
      'set_index or duration_s is treated as a separate intended set, and ' +
      'same-weight MCP straight sets are preserved. If the user confirms ' +
      'the rejected set is separate, retry it unchanged with ' +
      'confirm_duplicate=true. The dedupe gate is ' +
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
      'word it correctly; effective.implements is 2 and tonnage counts both ' +
      'implements independently from any unilateral-side multiplier. ' +
      'BODYWEIGHT / TIMED LOAD: for a bodyweight or timed hold, weight is ' +
      'external load relative to bodyweight: positive for a belt/vest, zero ' +
      'for strict bodyweight, and negative for band or machine assistance. ' +
      'Do not substitute the athlete\'s body mass. Zero, assisted, and timed ' +
      'sets have undefined tonnage. Positive tonnage is external-load volume only. ' +
      'Compare best reps or holds only at the same exercise, mode and exact load; ' +
      'pooled rep totals describe work, not strength progress. Bodyweight e1RM is unsupported.',
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
        is_timed: {
          type: 'boolean',
          description:
            'true if this set is a timed hold (renders as "Ns"). Defaults to the exercise modality; pass true when logging a duration-pinned hold on a non-timed exercise.',
        },
        confirm_duplicate: {
          type: 'boolean',
          description:
            'true only after the user explicitly confirms a recent_duplicate is a separate intended set',
        },
        notes: { type: 'string' },
      },
      ['exercise', 'weight', 'reps'],
    ),
    write: true,
    // Reviving a discarded legacy session can clear its old feedback and
    // assignment, so the tool must retain the destructive-action hint.
    handler: async (a, env, userId) => {
      const plan = await getActivePlan(env.DB, userId);
      if (!plan) return { error: 'no_active_plan' };
      const today = await ownerToday(env, userId);
      const date = typeof a.session_date === 'string' ? a.session_date : today;
      const ex = await resolveExercise(env.DB, String(a.exercise));
      if (!ex) return { error: 'unknown_exercise', query: a.exercise };
      const exId = (ex as { id: string }).id;
      const isWarmup = a.is_warmup === true;
      const requestedSetIndex = typeof a.set_index === 'number' ? a.set_index : null;
      const requestedDuration = a.duration_s == null ? null : Number(a.duration_s);
      // Phantom-dupe guard: refuse only an ambiguous cross-channel replay.
      // Repeated MCP calls are legitimate straight/timed sets, and explicit
      // set indices or durations distinguish separate work from the recent
      // iOS set. An unchanged retry is allowed only after user confirmation.
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
            set_index: requestedSetIndex,
            duration_s: requestedDuration,
          });
      if (recent && a.confirm_duplicate !== true) {
        const ageS = Math.max(0, Math.round((Date.now() - recent.logged_at) / 1000));
        return {
          error: 'recent_duplicate',
          message:
            `A ${a.weight}x${a.reps}${isWarmup ? ' warmup' : ''} set for ` +
            `${(ex as { name: string }).name} was already logged ${ageS}s ` +
            `ago (source=${recent.source}). This is almost certainly a ` +
            `duplicate from the user logging in iOS — do NOT retry or ` +
            `tweak the numbers. If the user confirms this is a separate ` +
            `intended set, retry unchanged with confirm_duplicate=true. ` +
            `Use correct_set if the existing values are wrong; use ` +
            `delete_set only if the whole set should be removed.`,
          existing_set: recent,
        };
      }
      // All rejection-only validation must finish before touching the date
      // row. In particular, a recent cross-channel duplicate must not revive
      // a discarded target session when no set will be written.
      const session = await getOrCreateSession(env.DB, userId, plan.id, date, null);
      const existing = await getSetsForSession(env.DB, session.id);
      const setIndex =
        requestedSetIndex != null
          ? requestedSetIndex
          : existing.filter((s) => s.exercise_id === exId && !s.is_warmup).length + 1;
      let writeResult: Awaited<ReturnType<typeof logSet>>;
      try {
        writeResult = await logSet(env.DB, userId, {
          id: crypto.randomUUID(),
          session_id: session.id,
          exercise_id: exId,
          set_index: setIndex,
          weight: Number(a.weight),
          reps: Number(a.reps),
          rpe: a.rpe == null ? null : Number(a.rpe),
          is_warmup: a.is_warmup === true,
          notes: typeof a.notes === 'string' ? a.notes : null,
          duration_s: requestedDuration,
          is_timed: typeof a.is_timed === 'boolean' ? a.is_timed : undefined,
          expected_attempt: session.attempt,
          source: 'mcp',
        });
      } catch (error) {
        if (error instanceof SessionWriteConflictError) return error.response();
        throw error;
      }
      const { set, deduped } = writeResult;
      // Surface the resolved exercise + per-side/per-hand accounting so the
      // agent can confirm "two 45 lb DBs x8 each leg → 16 total reps,
      // 1,440 lb tonnage" to the user without a second lookup.
      const exLat = (ex as { laterality?: string }).laterality ?? 'bilateral';
      const exLoad = (ex as { load_mode?: string }).load_mode ?? 'total';
      const sides = exLat === 'unilateral' ? 2 : 1;
      const perHand = exLoad === 'per_hand';
      const implementsUsed = perHand ? 2 : 1;
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
          implements: implementsUsed,
          total_reps: set.is_timed === 1 ? null : set.reps * sides,
          tonnage_basis: 'external_load',
          tonnage:
            set.is_timed === 0 && set.weight > 0
              ? set.weight * set.reps * sides * implementsUsed
              : null,
          // For two-dumbbell lifts, the weight is one dumbbell — surface a
          // ready-to-say phrasing so guidance never reads as the vague total.
          weight_display: perHand
            ? `${set.weight} lb in each hand`
            : `${set.weight} lb`,
        },
      };
    },
  },
  correct_set: {
    description:
      'Correct the values on an existing logged set while preserving its identity and history. ' +
      'Pass the set_id plus at least one corrected value: weight, reps, rpe, notes, or duration_s. ' +
      'Use null to clear rpe, notes, or duration_s. Find the id with get_current_session or ' +
      'get_session_log. Use delete_set instead only when the entire set is a phantom or duplicate.',
    inputSchema: obj(
      {
        set_id: { type: 'string', description: 'set_logs.id (UUID) to correct' },
        weight: { type: 'number' },
        reps: { type: 'integer', minimum: 0 },
        rpe: { type: ['number', 'null'] },
        notes: { type: ['string', 'null'] },
        duration_s: {
          type: ['integer', 'null'],
          minimum: 0,
          description: 'seconds, or null to clear the recorded duration',
        },
      },
      ['set_id'],
    ),
    write: true,
    handler: async (a, env, userId) => {
      const has = (field: string) => Object.prototype.hasOwnProperty.call(a, field);
      const allowed = new Set(['set_id', 'weight', 'reps', 'rpe', 'notes', 'duration_s']);
      const invalid: string[] = [];
      if (typeof a.set_id !== 'string' || a.set_id.length === 0) invalid.push('set_id');
      if (has('weight') && (typeof a.weight !== 'number' || !Number.isFinite(a.weight))) {
        invalid.push('weight');
      }
      if (has('reps') && (!Number.isSafeInteger(a.reps) || (a.reps as number) < 0)) {
        invalid.push('reps');
      }
      if (
        has('rpe') &&
        a.rpe !== null &&
        (typeof a.rpe !== 'number' || !Number.isFinite(a.rpe))
      ) {
        invalid.push('rpe');
      }
      if (has('notes') && a.notes !== null && typeof a.notes !== 'string') {
        invalid.push('notes');
      }
      if (
        has('duration_s') &&
        a.duration_s !== null &&
        (!Number.isSafeInteger(a.duration_s) || (a.duration_s as number) < 0)
      ) {
        invalid.push('duration_s');
      }
      invalid.push(...Object.keys(a).filter((field) => !allowed.has(field)));
      if (invalid.length > 0) return { error: 'invalid_fields', fields: invalid };

      const correctionFields = ['weight', 'reps', 'rpe', 'notes', 'duration_s'] as const;
      if (!correctionFields.some(has)) return { error: 'no_corrections' };
      const patch: {
        weight?: number;
        reps?: number;
        rpe?: number | null;
        notes?: string | null;
        duration_s?: number | null;
      } = {};
      if (has('weight')) patch.weight = a.weight as number;
      if (has('reps')) patch.reps = a.reps as number;
      if (has('rpe')) patch.rpe = a.rpe as number | null;
      if (has('notes')) patch.notes = a.notes as string | null;
      if (has('duration_s')) patch.duration_s = a.duration_s as number | null;

      const row = await patchSet(env.DB, userId, a.set_id as string, patch);
      return row ?? { error: 'not_found', set_id: a.set_id };
    },
    note: (a, r) =>
      r?.error
        ? null
        : `Corrected set ${a.set_id} to ${r.weight}x${r.reps}` +
          `${r.rpe == null ? '' : ` @ RPE ${r.rpe}`}` +
          `${r.duration_s == null ? '' : `, ${r.duration_s}s`}.`,
  },
  delete_set: {
    description:
      'Soft-delete a logged set by id — use this to undo a wrong log_set ' +
      'call (a phantom set you logged in error, or a true duplicate). The ' +
      'row is marked deleted (deleted_at set); history is preserved but ' +
      'it stops counting toward volume/sync. To find the set_id, call ' +
      'get_current_session or get_session_log first. Use correct_set instead ' +
      'for value corrections such as wrong weight, reps, RPE, notes, or duration.',
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
  discard_workout: {
    description:
      'Discard one specific existing workout session that the user confirms they did not do. ' +
      'This marks the session discarded and soft-deletes every logged set in it. It does not ' +
      'look up a session by date or create a session. Read the session id and current attempt ' +
      'first, then pass both explicitly; a stale attempt returns a conflict.',
    inputSchema: obj(
      {
        session_id: { type: 'string', description: 'Existing owned sessions.id (UUID)' },
        expected_attempt: {
          type: 'integer',
          minimum: 0,
          description: 'Current session attempt observed from a read tool',
        },
      },
      ['session_id', 'expected_attempt'],
    ),
    write: true,
    handlerAudited: true,
    handler: async (a, env, userId) => {
      const invalid = invalidFields(a, {
        session_id: isNonEmptyString,
        expected_attempt: isNonNegativeInteger,
      });
      if (invalid.length > 0) return { error: 'invalid_fields', fields: invalid };
      const session = await discardSession(
        env.DB,
        userId,
        a.session_id as string,
        a.expected_attempt as number,
      );
      if (!session) return { error: 'not_found', session_id: a.session_id };
      if ('error' in session) return session;
      return { ok: true, session };
    },
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
      'id is generated server-side. Check recent activities before retrying ' +
      'an uncertain result to avoid recording the same activity twice.',
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
    appendOnly: true,
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
    handler: async (a, env, userId) => {
      const date = typeof a.session_date === 'string' ? a.session_date : await ownerToday(env, userId);
      const s = await logWorkoutComplete(
        env.DB,
        userId,
        date,
        a.perceived_fatigue == null ? null : Number(a.perceived_fatigue),
        typeof a.notes === 'string' ? a.notes : null,
      );
      if (!s) return { error: 'no_active_plan' };
      if ('error' in s) return s;
      const summary = await getWorkoutSummary(env.DB, userId, s.id).catch(() => null);
      return { ...s, summary: summary?.attempt === s.attempt && summary.final ? summary : null };
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
    appendOnly: true,
    handler: async (a, env, userId) => {
      await writeNote(
        env.DB,
        userId,
        String(a.scope),
        typeof a.ref_id === 'string' ? a.ref_id : null,
        'coach',
        String(a.body),
      );
      return { ok: true };
    },
  },
  update_plan: {
    description:
      'Replace the plan tree (reusable workouts + exercises) transactionally. Exercise names must match the closed catalog — call list_exercises first to discover valid names (a single unknown name surfaces ALL unknowns at once in `queries: string[]`, not just the first). Pass expected_version for optimistic concurrency; it is required whenever the existing or supplied tree has group fields. A mismatch returns a conflict — refetch get_current_plan and reapply. Workouts are matched by day_label/name across the rebuild, so the weekly schedule follows surviving workouts; schedule entries for removed workouts are cleared. Workouts need not be scheduled. The legacy days input is accepted for one compatibility cycle.',
    inputSchema: obj(
      {
        name: { type: 'string' },
        meta: { type: 'object' },
        expected_version: { type: 'integer' },
        days: { type: 'array', description: 'Deprecated alias for workouts.', items: { type: 'object' } },
        workouts: {
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
      [],
    ),
    write: true,
    atomicWrite: true,
    handler: (a, env, userId) =>
      updatePlanTree(
        env.DB,
        userId,
        a as unknown as Parameters<typeof updatePlanTree>[2],
        { actor: 'mcp', operation: 'update_plan', args: a, note: 'Rebuilt training plan.' },
      ),
  },
  group_exercises: {
    description: 'Group adjacent exercise slots into a superset or circuit. Use a caller-generated group_id UUID and current expected_version. Exercises are template slot IDs (recommended, especially for repeated exercises) or unambiguous names/aliases in the selected day. Every member performs the same number of rounds. round_rest follows the last member; transition_rest defaults to zero between members. Ordinary per-slot rest is preserved. Retry the same ID, version and payload after an uncertain response; refetch on conflict.',
    inputSchema: obj({
      day: { type: 'string', description: 'Workout day ID, label or exact name' },
      group_id: { type: 'string', format: 'uuid' },
      expected_version: { type: 'integer', minimum: 1 },
      exercises: { type: 'array', minItems: 2, items: { type: 'string' } },
      round_rest: { type: 'integer', minimum: 0 },
      transition_rest: { type: 'integer', minimum: 0 },
      target_sets: { type: 'integer', minimum: 1 },
      order_index: { type: 'integer', minimum: 0, description: 'Optional destination index for moving the entire group as a block' },
    }, ['day', 'group_id', 'expected_version', 'exercises', 'round_rest']),
    write: true,
    atomicWrite: true,
    handler: async (a, env, userId) => {
      const unknown = Object.keys(a).filter((key) => !['day', 'group_id', 'expected_version', 'exercises',
        'round_rest', 'transition_rest', 'target_sets', 'order_index'].includes(key));
      if (unknown.length) return { error: 'unknown_fields', fields: unknown };
      const fields = invalidFields(a, {
        day: isNonEmptyString, group_id: isGroupId, expected_version: isPositiveInteger,
        exercises: (value) => Array.isArray(value) && value.length >= 2 && value.every(isNonEmptyString),
        round_rest: isNonNegativeInteger,
      }, { transition_rest: isNonNegativeInteger, target_sets: isPositiveInteger, order_index: isNonNegativeInteger });
      if (fields.length) return { error: 'invalid_fields', fields };
      const replay = await findMcpExerciseGroupAcknowledgement(env.DB, userId, 'group_exercises', a);
      if (replay) return replay;
      const tree = await getPlanTree(env.DB, userId);
      if (!tree) return { error: 'no_active_plan' };
      if (tree.version !== a.expected_version) {
        // A simultaneous copy may have committed after the first receipt read.
        // Changed stale payloads conflict before stale names can fail lookup.
        return await findMcpExerciseGroupAcknowledgement(env.DB, userId, 'group_exercises', a)
          ?? { conflict: true, current_version: tree.version };
      }
      const matchingDays = tree.workouts.filter((day) => day.id === a.day || day.day_label === a.day || day.name === a.day);
      if (matchingDays.length > 1) return { error: 'ambiguous_day' };
      if (!matchingDays.length && !isGroupId(a.day)) return { error: 'day_not_found' };
      const day = matchingDays[0];
      const members: string[] = [];
      for (const ref of a.exercises as string[]) {
        const exact = day?.exercises.find((slot) => slot.id === ref);
        if (exact) { members.push(exact.id); continue; }
        // Preserve caller slot IDs through a retry even if a later rebuild
        // removed them: receipt recognition belongs to the atomic service.
        if (isGroupId(ref)) {
          members.push(ref); continue;
        }
        const exercise = await resolveExercise(env.DB, ref);
        if (!exercise) return { error: 'unknown_exercise', query: ref };
        const matching = day?.exercises.filter((slot) => slot.exercise_id === exercise.id) ?? [];
        if (matching.length !== 1) return { error: matching.length ? 'ambiguous_exercise' : 'slot_not_found', query: ref };
        members.push(matching[0]!.id);
      }
      return setGroup(env.DB, userId, day?.id ?? a.day as string, a.group_id as string, members, {
        expected_version: a.expected_version as number, round_rest: a.round_rest as number,
        ...(hasField(a, 'transition_rest') ? { transition_rest: a.transition_rest as number } : {}),
        ...(hasField(a, 'target_sets') ? { target_sets: a.target_sets as number } : {}),
        ...(hasField(a, 'order_index') ? { order_index: a.order_index as number } : {}),
      }, { actor: 'mcp', operation: 'group_exercises', args: a, note: 'Grouped exercise slots.' });
    },
  },
  ungroup_exercises: {
    description: 'Clear a superset or circuit by group_id and the current expected_version. All members regain their unchanged ordinary per-slot rests. An exact acknowledged retry creates no extra version or history.',
    inputSchema: obj({ group_id: { type: 'string', format: 'uuid' },
      expected_version: { type: 'integer', minimum: 1 } }, ['group_id', 'expected_version']),
    write: true,
    atomicWrite: true,
    handler: async (a, env, userId) => {
      const unknown = Object.keys(a).filter((key) => !['group_id', 'expected_version'].includes(key));
      if (unknown.length) return { error: 'unknown_fields', fields: unknown };
      const fields = invalidFields(a, { group_id: isGroupId, expected_version: isPositiveInteger });
      if (fields.length) return { error: 'invalid_fields', fields };
      const replay = await findMcpExerciseGroupAcknowledgement(env.DB, userId, 'ungroup_exercises', a);
      if (replay) return replay;
      return clearGroup(env.DB, userId, a.group_id as string, a.expected_version as number,
        { actor: 'mcp', operation: 'ungroup_exercises', args: a, note: 'Ungrouped exercise slots.' });
    },
  },
  update_exercise: {
    description:
      'Patch one plan slot. Identify it by template_exercise_id, or by day (label/name) + exercise. Patchable keys: target_sets, target_reps, target_reps_max, target_rpe, rest_seconds, target_weight, target_duration_s, cues, progression, order_index, is_warmup. Group columns are changed only through group_exercises/ungroup_exercises; grouped order and target_sets are group-owned. Unknown keys are rejected with {error:"unknown_fields", fields:[...]} — no silent drop.',
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
    atomicWrite: true,
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
        { actor: 'mcp', operation: 'update_exercise', args: a, note: 'Updated exercise slot.' },
      );
      return r ?? { error: 'slot_not_found' };
    },
  },
  swap_exercise: {
    description: 'Replace an exercise in a day with another (e.g. RDL → good mornings on Wednesday), preserving its targets, order, warm-up flag, and slot identity. Carried targets must be valid for the destination modality. Historical sets keep their original exercise. Both names must match the closed catalog — use list_exercises to discover valid names.',
    inputSchema: obj(
      {
        day: { type: 'string', description: 'day label or name' },
        from_exercise: { type: 'string' },
        to_exercise: { type: 'string' },
      },
      ['day', 'from_exercise', 'to_exercise'],
    ),
    write: true,
    atomicWrite: true,
    handler: async (a, env, userId) => {
      const r = await swapExercise(env.DB, userId, {
        day: String(a.day),
        from_exercise: String(a.from_exercise),
        to_exercise: String(a.to_exercise),
      }, {
        actor: 'mcp', operation: 'swap_exercise', args: a,
        note: `Swapped ${a.from_exercise} → ${a.to_exercise} on ${a.day}.`,
      });
      return r ?? { error: 'slot_not_found' };
    },
  },
  add_exercise: {
    description: 'Add an exercise to a day in the active plan. `exercise` must match the closed catalog — use list_exercises to discover valid names. order_index defaults to max(existing)+1 (append dense), not the old 99 sentinel. Set is_warmup:true for a prescribed warm-up (erg, mobility) — its logged sets stay out of working-set rollups / session RPE. For a duration-based warm-up (e.g. 5-min row), use a cardio exercise and set target_duration_s. For bodyweight or timed work, target_weight is external load relative to bodyweight: positive for added load, zero for strict bodyweight, and negative for assistance; never store body mass. For AMRAP, use target_reps as the minimum, leave target_reps_max unset, and put "AMRAP" in cues.',
    inputSchema: obj(
      {
        day: { type: 'string', description: 'day label or name' },
        exercise: { type: 'string' },
        target_sets: { type: 'integer' },
        target_reps: { type: 'integer' },
        target_reps_max: { type: 'integer' },
        target_rpe: { type: 'number' },
        rest_seconds: { type: 'integer' },
        target_weight: {
          type: 'number',
          description:
            'Planned external load. On bodyweight/timed work: positive = added load, 0 = strict bodyweight, negative = assistance.',
        },
        target_duration_s: { type: 'integer', description: 'Planned hold/effort seconds for timed or cardio slots (planks, erg warm-ups); leave unset for conventional reps slots.' },
        progression: { type: 'object' },
        order_index: { type: 'integer' },
        is_warmup: { type: 'boolean', description: 'Mark this slot a prescribed warm-up (excluded from working-set rollups / session RPE).' },
      },
      ['day', 'exercise', 'target_sets', 'target_reps'],
    ),
    write: true,
    // Inserting at an occupied index rewrites existing exercise order values.
    atomicWrite: true,
    handler: async (a, env, userId) => {
      const groupFields = Object.keys(a).filter((key) => ['group_id', 'group_rest_seconds', 'group_transition_seconds'].includes(key));
      if (groupFields.length) return { error: 'unknown_fields', fields: groupFields };
      const plan = await getActivePlan(env.DB, userId);
      if (!plan) return { error: 'no_active_plan' };
      const day = await workoutDB(env.DB).prepare(
        "SELECT d.id FROM workouts d JOIN plans p ON p.id=d.plan_id WHERE p.user_id=?1 AND p.status='active' AND (d.day_label=?2 OR d.name=?2) LIMIT 1",
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
        a.order_index !== undefined
          ? a.order_index as number
          : await nextExerciseOrderIndex(env.DB, day.id);
      return addTemplateExercise(env.DB, plan.id, {
        workout_id: day.id,
        exercise_id: (ex as { id: string }).id,
        order_index: orderIndex,
        target_sets: a.target_sets as number,
        target_reps: a.target_reps as number,
        target_reps_max: a.target_reps_max == null ? null : a.target_reps_max as number,
        target_rpe: a.target_rpe == null ? null : a.target_rpe as number,
        rest_seconds: a.rest_seconds === undefined ? 120 : a.rest_seconds as number,
        target_weight: a.target_weight == null ? null : a.target_weight as number,
        target_duration_s:
          a.target_duration_s == null ? null : a.target_duration_s as number,
        progression: a.progression == null ? null : JSON.stringify(a.progression),
        cues: null,
        is_warmup: a.is_warmup === undefined ? 0 : a.is_warmup as boolean,
      }, {
        actor: 'mcp', operation: 'add_exercise', args: a,
        note: `Added ${a.exercise} to ${a.day}.`,
      });
    },
  },
  add_workout: addWorkoutTool('add_workout'),
  add_day: addWorkoutTool('add_day'),
  update_workout: updateWorkoutTool('update_workout'),
  update_day: updateWorkoutTool('update_day'),
  delete_workout: {
    description: 'Delete a reusable workout from the active plan, clearing its recurring schedule entries and preserving completed workout history. Requires the workout ID and current plan version. Rejected while the workout is in progress. To keep the workout but remove its weekdays, use set_schedule instead.',
    inputSchema: obj({ workout_id: { type: 'string' }, expected_version: { type: 'integer', minimum: 1 } }, ['workout_id', 'expected_version']),
    write: true,
    atomicWrite: true,
    handler: async (a, env, userId) => {
      const invalid = invalidFields(a, { workout_id: isNonEmptyString, expected_version: isPositiveInteger });
      if (invalid.length) return { error: 'invalid_fields', fields: invalid };
      return deleteWorkout(env.DB, userId, String(a.workout_id), Number(a.expected_version), {
        actor: 'mcp', operation: 'delete_workout', args: a, note: 'Deleted workout.',
      });
    },
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
    atomicWrite: true,
    handler: async (a, env, userId) => {
      const r = await deleteTemplateExercise(env.DB, userId, {
        template_exercise_id:
          typeof a.template_exercise_id === 'string' ? a.template_exercise_id : undefined,
        day: typeof a.day === 'string' ? a.day : undefined,
        exercise: typeof a.exercise === 'string' ? a.exercise : undefined,
      }, {
        actor: 'mcp', operation: 'delete_exercise', args: a,
        note: 'Deleted exercise slot.',
      });
      return r ?? { error: 'slot_not_found' };
    },
  },
  adjust_today: {
    description:
      'Persistently changes recurring workout-template targets. With day_label it changes every future use of that named workout; when omitted it changes every workout in the plan. This is not a one-date override. Reduces sets (reduce_volume/deload) or load/assistance (reduce_intensity), reports before/after changes, and may be a no-op when no supported reduction exists.',
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
    atomicWrite: true,
    handler: (a, env, userId) =>
      adjustToday(
        env.DB,
        userId,
        a.intent as 'deload' | 'reduce_volume' | 'reduce_intensity',
        (a.magnitude as 'light' | 'moderate' | 'heavy') ?? 'moderate',
        typeof a.day_label === 'string' ? a.day_label : undefined,
        {
          actor: 'mcp', operation: 'adjust_today', args: a,
          reason: typeof a.reason === 'string' ? a.reason : null,
          note: `${a.intent}(${a.magnitude ?? 'moderate'})${a.day_label ? ` ${a.day_label}` : ''}.` +
            (typeof a.reason === 'string' ? ` Reason: ${a.reason}` : ''),
        },
      ),
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
        expected_plan_id: { type: 'string' },
        expected_version: { type: 'integer' },
      },
      ['week'],
    ),
    write: true,
    atomicWrite: true,
    handler: async (a, env, userId) => {
      const week = (a.week as Record<string, string | null>) ?? {};
      const r = await setPlanSchedule(
        env.DB,
        userId,
        week as Partial<Record<Weekday, string | null>>,
        typeof a.expected_version === 'number' ? a.expected_version : null,
        typeof a.expected_plan_id === 'string' ? a.expected_plan_id : null,
        { actor: 'mcp', operation: 'set_schedule', args: a, note: 'Set recurring weekly schedule.' },
      );
      return r;
    },
  },
  set_planned_session: {
    description:
      'Pin ONE specific calendar date to a training day (a single-date override, NOT a recurring change). Use this for "next Saturday do legs" — it does not alter the standing weekly pattern and does not bump the plan version. `day` accepts a day template id, day_label, or name. Pass expected_attempt from the current session, or 0 when no session exists; a mismatch returns a conflict so this calendar edit cannot rewrite a newer workout attempt. For the permanent weekly routine use set_schedule.',
    inputSchema: obj(
      {
        date: { type: 'string', description: 'YYYY-MM-DD (device-local)' },
        day: { type: 'string', description: 'day template id, label, or name' },
        expected_attempt: { type: 'integer', minimum: 0 },
      },
      ['date', 'day'],
    ),
    write: true,
    handler: async (a, env, userId) =>
      setPlannedSession(
        env.DB,
        userId,
        String(a.date),
        String(a.day),
        typeof a.expected_attempt === 'number' ? a.expected_attempt : 0,
      ),
    note: (a, r) =>
      r?.ok ? `Planned ${a.date} → day "${a.day}" (one-off, no plan change).` : null,
  },
  skip_planned_session: {
    description:
      'Mark ONE specific calendar date as a rest/skip day (single-date override, NOT recurring). Use for "skip this Friday". Pass expected_attempt from the current session, or 0 when no session exists; a mismatch returns a conflict so this calendar edit cannot hide a newer workout attempt. Does not change the standing weekly pattern and does not bump the plan version.',
    inputSchema: obj(
      {
        date: { type: 'string', description: 'YYYY-MM-DD (device-local)' },
        expected_attempt: { type: 'integer', minimum: 0 },
      },
      ['date'],
    ),
    write: true,
    handler: async (a, env, userId) =>
      skipPlannedSession(
        env.DB,
        userId,
        String(a.date),
        typeof a.expected_attempt === 'number' ? a.expected_attempt : 0,
      ),
    note: (a, r) => (r?.ok ? `Skipped ${a.date} (one-off rest, no plan change).` : null),
  },
  set_race: {
    description:
      'Set the goal A-race the whole plan builds toward — the anchor for periodization, taper, and race-week logic. Pass name, date (YYYY-MM-DD), and discipline (e.g. triathlon, running, cycling); optionally distance (e.g. "70.3"), priority (A|B|C), and location. Replaces any existing race. Versioned: optionally pass expected_version for optimistic concurrency (mismatch → conflict, refetch get_current_plan and reapply). Bumps the plan version.',
    inputSchema: obj(
      {
        name: { type: 'string' },
        date: { type: 'string', description: 'YYYY-MM-DD civil date' },
        discipline: { type: 'string', description: 'triathlon | running | cycling | ...' },
        distance: { type: 'string', description: 'e.g. "70.3", "marathon"' },
        priority: { type: 'string', enum: ['A', 'B', 'C'] },
        location: { type: 'string' },
        expected_version: { type: 'integer' },
      },
      ['name', 'date', 'discipline'],
    ),
    write: true,
    atomicWrite: true,
    handler: async (a, env, userId) => {
      const race: RaceGoal = {
        name: String(a.name),
        date: String(a.date),
        discipline: String(a.discipline),
      };
      if (typeof a.distance === 'string') race.distance = a.distance;
      if (a.priority === 'A' || a.priority === 'B' || a.priority === 'C') race.priority = a.priority;
      if (typeof a.location === 'string') race.location = a.location;
      return setRace(
        env.DB,
        userId,
        race,
        typeof a.expected_version === 'number' ? a.expected_version : null,
        {
          actor: 'mcp', operation: 'set_race', args: a,
          note: `Set A-race: ${a.name} — ${a.discipline} on ${a.date}.`,
        },
      );
    },
  },
  set_periodization: {
    description:
      'Set the periodization plan — the ordered training phases (base|build|peak|taper|race|recovery) with date ranges and intent. This is the macrocycle STRUCTURE the coach reasons over, not a per-day calendar. Pass `phases` as a full ordered array; it REPLACES any existing periodization. Each phase: phase, start (YYYY-MM-DD), end (YYYY-MM-DD); optional focus, weekly_load_target, strength_emphasis. Versioned (expected_version optional). Bumps the plan version.',
    inputSchema: obj(
      {
        phases: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              phase: {
                type: 'string',
                enum: ['base', 'build', 'peak', 'taper', 'race', 'recovery'],
              },
              start: { type: 'string', description: 'YYYY-MM-DD' },
              end: { type: 'string', description: 'YYYY-MM-DD' },
              focus: { type: 'string' },
              weekly_load_target: { type: 'number' },
              strength_emphasis: { type: 'string' },
            },
            required: ['phase', 'start', 'end'],
            additionalProperties: false,
          },
        },
        expected_version: { type: 'integer' },
      },
      ['phases'],
    ),
    write: true,
    atomicWrite: true,
    handler: async (a, env, userId) =>
      setPeriodization(
        env.DB,
        userId,
        (a.phases as PeriodizationPhase[]) ?? [],
        typeof a.expected_version === 'number' ? a.expected_version : null,
        { actor: 'mcp', operation: 'set_periodization', args: a, note: 'Set periodization.' },
      ),
  },
  add_trip: {
    description:
      'Add a trip / availability blackout range (travel, planned rest, injury) so the plan knows when training is limited or off. Pass start + end (YYYY-MM-DD) and type (travel|rest|injury|other); optionally can_train_light (pool/run access while away?) and a note. Returns the new trip id. This stores the AVAILABILITY fact only — it does NOT itself blank the calendar; re-plan affected days with set_planned_session / skip_planned_session. Versioned (expected_version optional); bumps the plan version.',
    inputSchema: obj(
      {
        start: { type: 'string', description: 'YYYY-MM-DD' },
        end: { type: 'string', description: 'YYYY-MM-DD' },
        type: { type: 'string', enum: ['travel', 'rest', 'injury', 'other'] },
        can_train_light: { type: 'boolean' },
        note: { type: 'string' },
        expected_version: { type: 'integer' },
      },
      ['start', 'end'],
    ),
    write: true,
    atomicWrite: true,
    handler: async (a, env, userId) => {
      const trip: Omit<Trip, 'id'> = {
        start: String(a.start),
        end: String(a.end),
        type: (['travel', 'rest', 'injury', 'other'].includes(a.type as string)
          ? a.type
          : 'travel') as TripType,
      };
      if (typeof a.can_train_light === 'boolean') trip.can_train_light = a.can_train_light;
      if (typeof a.note === 'string') trip.note = a.note;
      return addTrip(
        env.DB,
        userId,
        trip,
        typeof a.expected_version === 'number' ? a.expected_version : null,
        {
          actor: 'mcp', operation: 'add_trip', args: a,
          note: `Added ${a.type ?? 'travel'} trip ${a.start}→${a.end}.`,
        },
      );
    },
  },
  update_trip: {
    description:
      'Edit an existing trip by id (dates, type, can_train_light, note). Pass the trip id (from add_trip or get_current_plan) plus the fields to change; omitted fields are left unchanged. Versioned (expected_version optional); bumps the plan version.',
    inputSchema: obj(
      {
        id: { type: 'string' },
        start: { type: 'string', description: 'YYYY-MM-DD' },
        end: { type: 'string', description: 'YYYY-MM-DD' },
        type: { type: 'string', enum: ['travel', 'rest', 'injury', 'other'] },
        can_train_light: { type: 'boolean' },
        note: { type: 'string' },
        expected_version: { type: 'integer' },
      },
      ['id'],
    ),
    write: true,
    atomicWrite: true,
    handler: async (a, env, userId) => {
      const patch: Partial<Omit<Trip, 'id'>> = {};
      if (typeof a.start === 'string') patch.start = a.start;
      if (typeof a.end === 'string') patch.end = a.end;
      if (['travel', 'rest', 'injury', 'other'].includes(a.type as string)) patch.type = a.type as TripType;
      if (typeof a.can_train_light === 'boolean') patch.can_train_light = a.can_train_light;
      if (typeof a.note === 'string') patch.note = a.note;
      return updateTrip(
        env.DB,
        userId,
        String(a.id),
        patch,
        typeof a.expected_version === 'number' ? a.expected_version : null,
        { actor: 'mcp', operation: 'update_trip', args: a, note: `Updated trip ${a.id}.` },
      );
    },
  },
  remove_trip: {
    description:
      'Remove a trip by id. Versioned (expected_version optional); bumps the plan version.',
    inputSchema: obj(
      { id: { type: 'string' }, expected_version: { type: 'integer' } },
      ['id'],
    ),
    write: true,
    atomicWrite: true,
    handler: async (a, env, userId) =>
      removeTrip(
        env.DB,
        userId,
        String(a.id),
        typeof a.expected_version === 'number' ? a.expected_version : null,
        { actor: 'mcp', operation: 'remove_trip', args: a, note: `Removed trip ${a.id}.` },
      ),
  },
  set_stress_model: {
    description:
      'Set the planning stress model — the multi-dimensional load/recovery rules the coach reasons over so training stress is NEVER reduced to one number (docs/MULTISPORT.md §7). Pass discipline_weights (per-discipline system loads, e.g. {run:{aerobic:1,impact:1}}), interference_rules (prose constraints like "heavy_lower 48h from key_run"), and age_modifiers (e.g. {athlete_age:75, recovery_multiplier:1.4}). Replaces the existing model. Versioned (expected_version optional); bumps the plan version.',
    inputSchema: obj(
      {
        discipline_weights: { type: 'object', additionalProperties: true },
        interference_rules: { type: 'array', items: { type: 'string' } },
        age_modifiers: { type: 'object', additionalProperties: true },
        expected_version: { type: 'integer' },
      },
      [],
    ),
    write: true,
    atomicWrite: true,
    handler: async (a, env, userId) => {
      const model: StressModel = {};
      if (a.discipline_weights && typeof a.discipline_weights === 'object') {
        model.discipline_weights = a.discipline_weights as StressModel['discipline_weights'];
      }
      if (Array.isArray(a.interference_rules)) {
        model.interference_rules = a.interference_rules as string[];
      }
      if (a.age_modifiers && typeof a.age_modifiers === 'object') {
        model.age_modifiers = a.age_modifiers as StressModel['age_modifiers'];
      }
      return setStressModel(
        env.DB,
        userId,
        model,
        typeof a.expected_version === 'number' ? a.expected_version : null,
        { actor: 'mcp', operation: 'set_stress_model', args: a, note: 'Updated planning stress model.' },
      );
    },
  },
  refresh_rides: {
    description:
      'Force an immediate refresh from intervals.icu (the hourly backstop cron also does this): both the PLANNED cycling/endurance calendar (upcoming rides) AND the COMPLETED activity feed (rides/runs you finished, with their actual duration/power/HR). Returns how many of each are cached and the sync status. Does NOT change the training plan or its version. No-op if the intervals.icu integration is not configured.',
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
        attribution_instructions: ATTRIBUTION_INSTRUCTIONS,
        activities: acts.map((x) => ({
          source_attribution: x.source_attribution,
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
      const items = await getGroupFeed(env.DB, groupId, null, null, limit, userId);
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
  const today = await ownerToday(env, userId);
  const recent = await getRecentSessions(env.DB, userId, 7, today);
  const catalog = await getExercises(env.DB);
  const last = recent[0] ?? null;
  // Resolve metadata and names from this exact plan tree, not a later read.
  const authoredContext = tree ? coachingPlanMeta(tree.meta) : null;
  const hasSchedule = authoredContext?.schedule != null;
  const schedule = tree && hasSchedule ? resolvedScheduleNames(tree) : null;
  const lastCompleted = await getLastCompletedSession(env.DB, userId, undefined, today);
  const summaryRows = [...recent];
  if (lastCompleted && !summaryRows.some(s => s.id === lastCompleted.id)) summaryRows.push(lastCompleted);
  // One batched read for every session in the brief, grouped here — the
  // per-session read was an N+1 over up to eight rows.
  const briefSets = await getSetsForSessions(env.DB, userId, summaryRows.map(session => session.id));
  const setsBySession = new Map<string, typeof briefSets>();
  for (const set of briefSets) {
    const rows = setsBySession.get(set.session_id);
    if (rows) rows.push(set); else setsBySession.set(set.session_id, [set]);
  }
  const summaries = new Map(summaryRows.map(session =>
    [session.id, coachingSession(session, setsBySession.get(session.id) ?? [], catalog)] as const));
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
    training_profile: await getTrainingProfile(env.DB, userId),
    active_plan: tree
      ? {
          id: tree.id,
          name: tree.name,
          version: tree.version,
          authored_context: authoredContext,
          weekly_schedule: schedule,
          workouts: tree.workouts.map((d) => ({
            label: d.day_label,
            name: d.name,
            exercises: d.exercises.length,
            groups: coachGroupSummary(d.exercises),
          })),
        }
      : null,
    last_session: last ? summaries.get(last.id) : null,
    last_completed_session: lastCompleted ? summaries.get(lastCompleted.id) : null,
    recent_sessions: recent.map(session => summaries.get(session.id)),
    measures: {
      source: 'Persisted session/set logs and exercise catalog; feedback is member-authored.',
      logged_working_sets: 'Non-warm-up logged sets, counted once; primary muscle only, not measured stimulus or complete muscle volume.',
      effort_coverage: 'sets_with_effort counts recorded per-set RPE; missing effort is unknown.',
      external_load_volume: 'Positive external load times reps, with implement/side multipliers, grouped by unit; excludes timed, assisted and zero-load work. No system load or body mass.',
      key_sets: 'Best observed rep/hold set per exact comparable condition; not a PR. Counts and effort coverage include all logged working sets.',
      comparisons: 'Same exercise, execution mode, external load, units and side/implement convention only; no automatic readiness or strength conversion.',
    },
    scheduling_context: {
      basis: 'scheduling_heuristic',
      sources: ['projected strength dates', 'cached intervals.icu planned events'],
      thresholds: { training_load: 150, planned_duration_sec: 9000 },
      limitation: 'No strength-day load or muscle inputs. Unknown load/duration is incomplete context; thresholds do not establish easy work, individualized safety or interference.',
    },
    // Upcoming endurance load + lift/ride conflicts (next 28 days). Empty
    // arrays when the intervals.icu integration is dormant or clear.
    upcoming_rides: rides.map((r) => ({
      id: r.id,
      source: r.source,
      date: r.date,
      kind: r.kind,
      title: r.title,
      training_load: r.training_load,
      planned_duration_sec: r.planned_duration_sec,
    })),
    ride_conflicts: conflicts,
    // Recently COMPLETED endurance work (actuals from intervals.icu).
    attribution_instructions: ATTRIBUTION_INSTRUCTIONS,
    recent_activities: recentActivities.map((a) => ({
      source_attribution: a.source_attribution,
      id: a.id,
      source: a.source,
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
    '# tres-fort — current state',
    'Current training context. Use the tools for anything deeper.',
    '```json',
    JSON.stringify(workoutWire(brief), null, 2),
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
        instructions: SERVER_INSTRUCTIONS + "\n" + ATTRIBUTION_INSTRUCTIONS,
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
          // All tools operate on the authenticated account and its bounded
          // catalog/groups/linked Intervals account. None publish publicly or
          // accept arbitrary external destinations. Writes default to a
          // destructive hint unless explicitly verified append-only below.
          annotations: {
            readOnlyHint: !t.write,
            destructiveHint: !!t.write && !t.appendOnly,
            openWorldHint: false,
          },
        })),
      });
    case 'tools/call': {
      const name = req.params?.name as string;
      const tool = TOOLS[name];
      if (!tool) return err(req.id, -32602, `unknown tool: ${name}`);
      try {
        const args = workoutInput((req.params?.arguments as Json) ?? {}) as Json;
        const result = await tool.handler(args, env, userId, bg);
        if (tool.write && !tool.atomicWrite && !tool.handlerAudited) {
          await writeAudit(env.DB, userId, name, args, JSON.stringify(result));
          const noteBody = tool.note?.(args, result);
          if (noteBody) await writeNote(env.DB, userId, 'plan', null, 'coach', noteBody);
        }
        return ok(req.id, {
          content: [{ type: 'text', text: JSON.stringify(workoutWire(result), null, 2) }],
        });
      } catch (e) {
        const code = publicToolErrorCode(e);
        if (code === null) logUnexpectedError('mcp_tool', e);
        return ok(req.id, {
          content: [{ type: 'text', text: code === null
            ? 'error: internal. Check current state before retrying a write.'
            : `error: ${code}` }],
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
                '\n\nUse the tres-fort tools to read history and adapt the plan as we talk.',
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
  userId: string,
  bg?: BgScheduler,
): Promise<{ status: number; json?: unknown }> {
  const req = body as RpcRequest;
  if (!req || req.jsonrpc !== '2.0' || typeof req.method !== 'string') {
    return { status: 400, json: err(null, -32600, 'invalid request') };
  }
  // `userId` is resolved by the /mcp route from the bearer (static token →
  // owner; OAuth → the token's bound user). Multi-tenant: every tool scopes
  // to it. Notifications (no id) get a bare 202 with no body, per spec.
  if (req.id === undefined || req.id === null) {
    if (req.method.startsWith('notifications/')) return { status: 202 };
  }
  return { status: 200, json: await dispatch(req, env, userId, bg) };
}
