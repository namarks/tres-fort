// intervals.icu I/O — the ONLY place this backend talks to intervals.icu.
//
// Behind an injectable `fetcher` so tests never hit the network
// (vitest-pool-workers is offline). The cycling-awareness feature is
// DORMANT when INTERVALS_ICU_API_KEY is unset: fetchPlannedEvents returns
// a clean {ok:false, reason:'disabled'} with no network call and no throw.
import type { Env, PlannedEvent } from './types';

/** Minimal fetch signature we depend on (URL or string + RequestInit). */
export type Fetcher = (
  input: string,
  init?: {
    method?: string;
    headers?: Record<string, string>;
    body?: string;
    signal?: AbortSignal;
  },
) => Promise<{ ok: boolean; status: number; json: () => Promise<unknown> }>;

export interface FetchDeps {
  /** Defaults to global fetch. Stubbed in tests so the suite is offline. */
  fetcher?: Fetcher;
  /** Device-local "today" YYYY-MM-DD. Defaults to the worker clock. */
  today?: string;
  /** Window width in days (inclusive of today). Defaults to 90. */
  windowDays?: number;
  /** Per-request timeout in ms (default 10s). */
  timeoutMs?: number;
}

export type FetchResult =
  | { ok: true; events: PlannedEvent[] }
  | { ok: false; reason: 'disabled' | 'http' | 'timeout' | 'parse'; status?: number };

const DAY_MS = 86_400_000;

function todayLocal(): string {
  return new Date().toISOString().slice(0, 10);
}

/** Add n days to a YYYY-MM-DD via UTC math on the civil date (no DST risk:
 *  we only ever shift whole days and slice the date part back out). */
function addDays(ymd: string, n: number): string {
  const t = Date.parse(`${ymd}T00:00:00Z`);
  return new Date(t + n * DAY_MS).toISOString().slice(0, 10);
}

/**
 * Map an intervals.icu `type` to our coarse kind. intervals uses values
 * like "Ride","VirtualRide","Run","Swim","Workout","Weight Training", ...
 */
function kindOf(type: unknown): string {
  const t = String(type ?? '').toLowerCase();
  if (t.includes('ride') || t.includes('bike') || t.includes('cycl')) return 'ride';
  if (t.includes('run')) return 'run';
  if (t.includes('swim')) return 'swim';
  return 'other';
}

function num(v: unknown): number | null {
  return typeof v === 'number' && Number.isFinite(v) ? v : null;
}

function str(v: unknown): string | null {
  return typeof v === 'string' && v.length > 0 ? v : null;
}

/**
 * GET intervals.icu planned events in [today, today+windowDays]. Returns a
 * discriminated result:
 *   - {ok:true, events}     on 2xx + parseable body
 *   - {ok:false, reason}    on disabled / non-2xx / timeout / parse-error
 *
 * Only `category == "WORKOUT"` rows are kept. `date` is the intervals
 * `start_date_local` date part VERBATIM — no timezone math (the contract).
 */
export async function fetchPlannedEvents(
  env: Env,
  deps: FetchDeps = {},
): Promise<FetchResult> {
  const apiKey = env.INTERVALS_ICU_API_KEY;
  const athleteId = env.INTERVALS_ICU_ATHLETE_ID;
  // Dormant when unconfigured: a clean no-op, never an error/throw.
  if (!apiKey || !athleteId) return { ok: false, reason: 'disabled' };

  const fetcher = deps.fetcher ?? (globalThis.fetch as unknown as Fetcher);
  const today = deps.today ?? todayLocal();
  const windowDays = deps.windowDays ?? 90;
  const newest = addDays(today, windowDays);
  const url =
    `https://intervals.icu/api/v1/athlete/${encodeURIComponent(athleteId)}` +
    `/events?oldest=${today}&newest=${newest}`;
  // intervals.icu uses HTTP Basic with username "API_KEY" and the key as
  // the password: base64("API_KEY:" + key).
  const authToken = btoa(`API_KEY:${apiKey}`);

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), deps.timeoutMs ?? 10_000);
  let res: { ok: boolean; status: number; json: () => Promise<unknown> };
  try {
    res = await fetcher(url, {
      method: 'GET',
      headers: { Authorization: `Basic ${authToken}`, Accept: 'application/json' },
      signal: controller.signal,
    });
  } catch {
    // AbortError (timeout) or any network error — leave caller to NOT touch
    // the cache. Indistinguishable cases all collapse to a no-op signal.
    return { ok: false, reason: 'timeout' };
  } finally {
    clearTimeout(timer);
  }

  if (!res.ok) return { ok: false, reason: 'http', status: res.status };

  let body: unknown;
  try {
    body = await res.json();
  } catch {
    return { ok: false, reason: 'parse' };
  }
  if (!Array.isArray(body)) return { ok: false, reason: 'parse' };

  const events: PlannedEvent[] = [];
  for (const raw of body as Record<string, unknown>[]) {
    if (!raw || typeof raw !== 'object') continue;
    if (String(raw.category ?? '') !== 'WORKOUT') continue;
    const externalId = raw.id != null ? String(raw.id) : null;
    const startLocal = str(raw.start_date_local);
    if (!externalId || !startLocal) continue;
    events.push({
      external_id: externalId,
      date: startLocal.slice(0, 10), // verbatim civil date, no tz math
      kind: kindOf(raw.type),
      title: str(raw.name),
      description: str(raw.description),
      // intervals planned duration is `moving_time` (seconds).
      planned_duration_sec: num(raw.moving_time),
      // planned TSS is `icu_training_load`.
      training_load: num(raw.icu_training_load),
      intensity: num(raw.icu_intensity),
      raw: JSON.stringify(raw),
    });
  }
  return { ok: true, events };
}

// ---- WRITE path: one-way lifting-load export ---------------------------
//
// The ONLY place this backend WRITES to intervals.icu. Mirrors the read
// path: injectable fetcher (tests never hit the network), dormant no-op
// when unconfigured, and a discriminated result — any non-2xx / throw /
// parse error collapses to a typed {ok:false} that the caller treats as
// "leave it pending, retry later" (it must never throw into the caller).

export interface StrengthActivity {
  /** Device-local civil date YYYY-MM-DD — used VERBATIM, no tz math. */
  date: string;
  /** e.g. "Lift: Push A". */
  name: string;
  /** Computed sRPE load → intervals `icu_training_load`. */
  loadTss: number;
  /** Clamped session duration in seconds → intervals `moving_time`. */
  durationSec: number;
  /**
   * Existing intervals.icu event id to UPDATE (idempotent re-export of the
   * same session). When absent a new event is created.
   */
  ref?: string | null;
}

export type PushResult =
  | { ok: true; ref: string }
  | { ok: false; reason: 'disabled' | 'http' | 'timeout' | 'parse'; status?: number };

/**
 * Create-or-update a COMPLETED strength entry in intervals.icu carrying the
 * computed training load.
 *
 * VERIFIED endpoint (against the intervals-icu MCP server's working client
 * — ~/repos/mcp-servers/intervals-icu/.../client.py + event_management.py):
 *   - create: POST  https://intervals.icu/api/v1/athlete/{id}/events
 *   - update: PUT   https://intervals.icu/api/v1/athlete/{id}/events/{ref}
 *   body: {
 *     start_date_local: "YYYY-MM-DDT00:00:00",   // T00:00:00 suffix required
 *     name, category: "WORKOUT", type: "WeightTraining",
 *     moving_time: <sec>, icu_training_load: <load>
 *   }
 *   auth: HTTP Basic, username "API_KEY", password = the API key.
 * The read path consumes exactly this shape (category=="WORKOUT" +
 * icu_training_load), so create→read round-trips.
 *
 * NOTE / uncertainty (flagged, not silently guessed): the intervals-icu
 * MCP only ever creates calendar EVENTS, never uploads a recorded activity
 * file. There is no code-verified "manual completed activity" write API.
 * A WORKOUT event with icu_training_load is the verified, round-trippable
 * mechanism for injecting strength load into the intervals.icu calendar;
 * it is isolated behind THIS one function so the artifact can be swapped
 * without touching db.ts if a manual-activity endpoint is later confirmed.
 */
export async function pushStrengthActivity(
  env: Env,
  activity: StrengthActivity,
  deps: Pick<FetchDeps, 'fetcher' | 'timeoutMs'> = {},
): Promise<PushResult> {
  const apiKey = env.INTERVALS_ICU_API_KEY;
  const athleteId = env.INTERVALS_ICU_ATHLETE_ID;
  // Dormant when unconfigured: clean no-op, never an error/throw.
  if (!apiKey || !athleteId) return { ok: false, reason: 'disabled' };

  const fetcher = deps.fetcher ?? (globalThis.fetch as unknown as Fetcher);
  const base =
    `https://intervals.icu/api/v1/athlete/${encodeURIComponent(athleteId)}/events`;
  const isUpdate = activity.ref != null && activity.ref.length > 0;
  const url = isUpdate ? `${base}/${encodeURIComponent(activity.ref!)}` : base;
  const method = isUpdate ? 'PUT' : 'POST';
  const authToken = btoa(`API_KEY:${apiKey}`);

  const body = JSON.stringify({
    // T00:00:00 suffix is required by the intervals.icu API; the date part
    // is the device-local civil date VERBATIM (no timezone math).
    start_date_local: `${activity.date}T00:00:00`,
    name: activity.name,
    category: 'WORKOUT',
    type: 'WeightTraining',
    moving_time: activity.durationSec,
    icu_training_load: activity.loadTss,
  });

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), deps.timeoutMs ?? 10_000);
  let res: { ok: boolean; status: number; json: () => Promise<unknown> };
  try {
    res = await fetcher(url, {
      method,
      headers: {
        Authorization: `Basic ${authToken}`,
        Accept: 'application/json',
        'Content-Type': 'application/json',
      },
      body,
      signal: controller.signal,
    });
  } catch {
    // AbortError (timeout) or any network error — caller leaves the export
    // row 'pending' for the cron to retry. NEVER throws to the caller.
    return { ok: false, reason: 'timeout' };
  } finally {
    clearTimeout(timer);
  }

  if (!res.ok) return { ok: false, reason: 'http', status: res.status };

  let parsed: unknown;
  try {
    parsed = await res.json();
  } catch {
    return { ok: false, reason: 'parse' };
  }
  // On update we already know the ref; the id echo is best-effort.
  const echoed =
    parsed && typeof parsed === 'object' && (parsed as { id?: unknown }).id != null
      ? String((parsed as { id: unknown }).id)
      : null;
  const ref = echoed ?? (isUpdate ? activity.ref! : null);
  if (!ref) return { ok: false, reason: 'parse' };
  return { ok: true, ref };
}
