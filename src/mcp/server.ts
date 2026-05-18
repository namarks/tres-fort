// Minimal, spec-correct MCP server over Streamable HTTP (JSON-RPC 2.0,
// single application/json responses — no server-initiated streams needed
// for read tools). Stateless: no Mcp-Session-Id required. All data access
// goes through src/db.ts, identical to REST.
import type { Env } from '../types';
import {
  ensureOwnerUser,
  getHistory,
  getInProgressSession,
  getPlanTree,
  getRecentSessions,
  getSessionByDate,
  getSetsForSession,
  getVolume,
  resolveExercise,
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
        const result = await tool.handler((req.params?.arguments as Json) ?? {}, env, userId);
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
