// Minimal, spec-correct MCP server over Streamable HTTP (JSON-RPC 2.0,
// single application/json responses — no server-initiated streams needed
// for read tools). Stateless: no Mcp-Session-Id required. All data access
// goes through src/db.ts, identical to REST.
import type { Env } from '../types';
import {
  addDayTemplate,
  addTemplateExercise,
  adjustToday,
  ensureOwnerUser,
  getActivePlan,
  getHistory,
  getInProgressSession,
  getOrCreateSession,
  getPlanTree,
  getRecentSessions,
  getSessionByDate,
  getSetsForSession,
  getVolume,
  logSet,
  logWorkoutComplete,
  resolveExercise,
  swapExercise,
  updateExercise,
  updatePlanTree,
  writeAudit,
  writeNote,
} from '../db';

const SERVER_INFO = { name: 'lift-coach', version: '0.1.0' };
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

const todayLocal = () => new Date().toISOString().slice(0, 10);

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

interface Tool {
  description: string;
  inputSchema: Json;
  handler: (args: Json, env: Env, userId: string) => Promise<unknown>;
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
      return tree ?? { plan: null, note: 'No active plan yet.' };
    },
  },
  get_today_workout: {
    description:
      "Get today's workout: the date, any existing session for today, the plan's day templates, and the most recent prior session for context.",
    inputSchema: obj({}),
    handler: async (_a, env, userId) => {
      const date = todayLocal();
      const tree = await getPlanTree(env.DB, userId);
      const session = await getSessionByDate(env.DB, userId, date);
      const recent = await getRecentSessions(env.DB, userId, 2);
      const last = recent.find((s) => s.date !== date) ?? null;
      return {
        date,
        session,
        sets: session ? await getSetsForSession(env.DB, session.id) : [],
        plan_days: tree?.days ?? [],
        last_session: last,
        last_session_sets: last ? await getSetsForSession(env.DB, last.id) : [],
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

  // ---- write tools -------------------------------------------------------

  log_set: {
    description:
      'Log one working/warmup set. Auto-creates the day\'s session and infers set_index. Logs to today unless session_date is given.',
    inputSchema: obj(
      {
        exercise: { type: 'string', description: 'name, alias, or id' },
        weight: { type: 'number' },
        reps: { type: 'integer' },
        rpe: { type: 'number' },
        is_warmup: { type: 'boolean' },
        set_index: { type: 'integer' },
        session_date: { type: 'string', description: 'YYYY-MM-DD (default today)' },
        notes: { type: 'string' },
      },
      ['exercise', 'weight', 'reps'],
    ),
    write: true,
    handler: async (a, env, userId) => {
      const plan = await getActivePlan(env.DB, userId);
      if (!plan) return { error: 'no_active_plan' };
      const date = typeof a.session_date === 'string' ? a.session_date : todayLocal();
      const session = await getOrCreateSession(env.DB, userId, plan.id, date, null);
      const ex = await resolveExercise(env.DB, String(a.exercise));
      if (!ex) return { error: 'unknown_exercise', query: a.exercise };
      const exId = (ex as { id: string }).id;
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
        source: 'mcp',
      });
      return { set, deduped, session_id: session.id };
    },
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
      const date = typeof a.session_date === 'string' ? a.session_date : todayLocal();
      const s = await logWorkoutComplete(
        env.DB,
        userId,
        date,
        a.perceived_fatigue == null ? null : Number(a.perceived_fatigue),
        typeof a.notes === 'string' ? a.notes : null,
      );
      return s ?? { error: 'no_active_plan' };
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
      'Replace the plan tree (days + exercises) transactionally. Pass expected_version for optimistic concurrency; a mismatch returns a conflict — refetch get_current_plan and reapply.',
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
      r?.conflict
        ? null
        : `Rebuilt plan: ${r.plan.days.length} day(s), v${r.plan.version}.`,
  },
  update_exercise: {
    description:
      'Patch one plan slot. Identify it by template_exercise_id, or by day (label/name) + exercise.',
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
    description: 'Replace an exercise in a day with another (e.g. RDL → good mornings on Wednesday).',
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
    description: 'Add an exercise to a day in the active plan.',
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
      return addTemplateExercise(env.DB, plan.id, {
        day_template_id: day.id,
        exercise_id: (ex as { id: string }).id,
        order_index: typeof a.order_index === 'number' ? a.order_index : 99,
        target_sets: Number(a.target_sets),
        target_reps: Number(a.target_reps),
        target_reps_max: a.target_reps_max == null ? null : Number(a.target_reps_max),
        target_rpe: a.target_rpe == null ? null : Number(a.target_rpe),
        rest_seconds: typeof a.rest_seconds === 'number' ? a.rest_seconds : 120,
        target_weight: a.target_weight == null ? null : Number(a.target_weight),
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
      return addDayTemplate(
        env.DB,
        plan.id,
        String(a.name),
        typeof a.day_label === 'string' ? a.day_label : null,
        typeof a.order_index === 'number' ? a.order_index : 99,
      );
    },
    note: (a) => `Added day "${a.name}".`,
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
};

// ---- resource + prompt ---------------------------------------------------

const STATE_URI = 'coach://state/current';

async function buildStateBrief(env: Env, userId: string): Promise<string> {
  const tree = await getPlanTree(env.DB, userId);
  const recent = await getRecentSessions(env.DB, userId, 1);
  const last = recent[0] ?? null;
  const lastSets = last ? await getSetsForSession(env.DB, last.id) : [];
  const brief = {
    today: todayLocal(),
    active_plan: tree
      ? {
          name: tree.name,
          version: tree.version,
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

async function dispatch(req: RpcRequest, env: Env, userId: string) {
  switch (req.method) {
    case 'initialize': {
      const requested = (req.params?.protocolVersion as string) ?? DEFAULT_PROTOCOL;
      return ok(req.id, {
        protocolVersion: SUPPORTED_PROTOCOLS.has(requested) ? requested : DEFAULT_PROTOCOL,
        capabilities: { tools: {}, resources: {}, prompts: {} },
        serverInfo: SERVER_INFO,
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
        const result = await tool.handler(args, env, userId);
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
  return { status: 200, json: await dispatch(req, env, userId) };
}
