// intervals.icu I/O — the ONLY place this backend talks to intervals.icu.
//
// Behind an injectable `fetcher` so tests never hit the network
// (vitest-pool-workers is offline). The cycling-awareness feature is
// DORMANT when no API key/athlete id is supplied: each function returns a
// clean {ok:false, reason:'disabled'} with no network call and no throw.
//
// CREDENTIALS — M1 change. Per-user creds (multi-user backend foundation).
// These functions used to read INTERVALS_ICU_API_KEY/ATHLETE_ID off `env`
// directly; they now take the pair explicitly so callers in db.ts can
// loop per-user (each user owns their own intervals.icu credentials in
// the `users` row — see migrations/0016_user_intervals_creds.sql). Env
// lookup is intentionally OUT of this module — pure I/O on injected creds.
import type { CompletedActivity, PlannedEvent } from './types';

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
  /**
   * OAuth bearer access token. When present it takes precedence over the
   * `apiKey` (Basic) argument — the request uses `Authorization: Bearer`.
   * Lets the same fetchers serve both the legacy per-user API-key path and
   * the OAuth path without changing their call signatures.
   */
  accessToken?: string | null;
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
 * like "Ride","VirtualRide","Run","TrailRun","Swim","OpenWaterSwim",
 * "Walk","Hike","Rowing","Elliptical","AlpineSki","Yoga","Workout",
 * "WeightTraining", ... We match on substrings so the many intervals
 * spelling variants collapse to a handful of kinds the clients have
 * glyphs for; anything we don't recognise still falls through to 'other'.
 * NOTE: "WeightTraining" never reaches here — isTresFortExport() filters
 * it upstream — but "Strength"/"WeightLifting" do, hence the 'strength'
 * branch. Keep the kinds emitted here in sync with the glyph maps in
 * ios FeedItemRow.rideGlyph and Models.ExternalActivity.glyph.
 */
function kindOf(type: unknown): string {
  const t = String(type ?? '').toLowerCase();
  if (t.includes('ride') || t.includes('bike') || t.includes('cycl')) return 'ride';
  if (t.includes('run')) return 'run';
  if (t.includes('swim')) return 'swim';
  if (t.includes('walk')) return 'walk';
  if (t.includes('hike')) return 'hike';
  if (t.includes('row')) return 'row';
  if (t.includes('ski')) return 'ski';
  if (t.includes('yoga')) return 'yoga';
  if (t.includes('elliptical')) return 'elliptical';
  if (t.includes('weight') || t.includes('strength')) return 'strength';
  return 'other';
}

function num(v: unknown): number | null {
  return typeof v === 'number' && Number.isFinite(v) ? v : null;
}

/**
 * Parse an intervals.icu `start_date_local` ("YYYY-MM-DDTHH:MM:SS") to
 * epoch-ms by treating it as UTC. Used ONLY as an ordering key for the
 * group feed — comparing the same civil-time strings across users in
 * different timezones gives a stable, reproducible numeric order without
 * needing a per-user timezone lookup. Returns null on any parse failure.
 */
function parseCivilToMs(startLocal: string): number | null {
  const ms = Date.parse(startLocal + 'Z');
  return Number.isFinite(ms) ? ms : null;
}

function str(v: unknown): string | null {
  return typeof v === 'string' && v.length > 0 ? v : null;
}

/**
 * Resolve the `Authorization` header value for an intervals.icu request.
 * Prefers OAuth (`Bearer <token>`) when an access token is supplied; falls
 * back to the legacy HTTP Basic scheme (username "API_KEY", password = the
 * key → base64("API_KEY:" + key)). Returns null when neither credential is
 * present — callers treat that as the dormant "disabled" no-op (no fetch).
 */
function intervalsAuthHeader(
  apiKey: string | null | undefined,
  accessToken: string | null | undefined,
): string | null {
  if (accessToken) return `Bearer ${accessToken}`;
  if (apiKey) return `Basic ${btoa(`API_KEY:${apiKey}`)}`;
  return null;
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
  apiKey: string | null | undefined,
  athleteId: string | null | undefined,
  deps: FetchDeps = {},
): Promise<FetchResult> {
  // Dormant when unconfigured: a clean no-op, never an error/throw. Auth is
  // OAuth Bearer when a token is supplied, else HTTP Basic with the API key.
  const authHeader = intervalsAuthHeader(apiKey, deps.accessToken);
  if (!authHeader || !athleteId) return { ok: false, reason: 'disabled' };

  const fetcher = deps.fetcher ?? (globalThis.fetch as unknown as Fetcher);
  const today = deps.today ?? todayLocal();
  const windowDays = deps.windowDays ?? 90;
  const newest = addDays(today, windowDays);
  const url =
    `https://intervals.icu/api/v1/athlete/${encodeURIComponent(athleteId)}` +
    `/events?oldest=${today}&newest=${newest}`;

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), deps.timeoutMs ?? 10_000);
  let res: { ok: boolean; status: number; json: () => Promise<unknown> };
  try {
    res = await fetcher(url, {
      method: 'GET',
      headers: { Authorization: authHeader, Accept: 'application/json' },
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
    // BLOCKER-3 fix: never ingest OUR OWN exported lift events back into
    // the endurance cache. Without this, exportSessionLoad's WeightTraining
    // event lands in `external_events` and detectConflicts flags every lift
    // day as clashing with its own exported load (a self-conflict loop).
    // `external_events` stays endurance-commitments-only.
    if (isTresFortExport(raw)) continue;
    const externalId = raw.id != null ? String(raw.id) : null;
    const startLocal = str(raw.start_date_local);
    if (!externalId || !startLocal) continue;
    events.push({
      external_id: externalId,
      date: startLocal.slice(0, 10), // verbatim civil date, no tz math
      // start_date_local is "YYYY-MM-DDTHH:MM:SS" (civil time, no zone).
      // Parse as UTC for an order-stable numeric — across users in different
      // tzs, two events at the same civil time get the same numeric key,
      // which is the correct ordering for a "what happened on each day"
      // feed. Returns null on parse failure rather than NaN.
      start_date_local_ms: parseCivilToMs(startLocal),
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

// ---- READ path: completed activities (the intervals.icu actuals) -------
//
// Mirror of fetchPlannedEvents but against the /activities feed — the
// RECORDED, COMPLETED activities (rides/runs) the intervals.icu app shows,
// carrying actual duration/power/HR/distance/TSS. Same discipline:
// injectable fetcher (offline in tests), dormant no-op when unconfigured,
// discriminated result. Window looks BACKWARD: [today-pastDays, today].

export interface ActivityFetchDeps {
  /** Defaults to global fetch. Stubbed in tests so the suite is offline. */
  fetcher?: Fetcher;
  /** Device-local "today" YYYY-MM-DD. Defaults to the worker clock. */
  today?: string;
  /** How many days back from today to pull (inclusive). Defaults to 90. */
  pastDays?: number;
  /** Per-request timeout in ms (default 10s). */
  timeoutMs?: number;
  /** OAuth bearer access token — see FetchDeps.accessToken. */
  accessToken?: string | null;
}

export type ActivityFetchResult =
  | { ok: true; activities: CompletedActivity[] }
  | { ok: false; reason: 'disabled' | 'http' | 'timeout' | 'parse'; status?: number };

/**
 * GET intervals.icu completed activities in [today-pastDays, today]. Returns
 * the same discriminated result shape as fetchPlannedEvents. Our own
 * exported strength rows are skipped (isTresFortExport) so the completed
 * cache stays endurance-actuals-only. `date` is the `start_date_local` date
 * part VERBATIM — no timezone math (the contract).
 */
export async function fetchCompletedActivities(
  apiKey: string | null | undefined,
  athleteId: string | null | undefined,
  deps: ActivityFetchDeps = {},
): Promise<ActivityFetchResult> {
  // Dormant when unconfigured: a clean no-op, never an error/throw. Auth is
  // OAuth Bearer when a token is supplied, else HTTP Basic with the API key.
  const authHeader = intervalsAuthHeader(apiKey, deps.accessToken);
  if (!authHeader || !athleteId) return { ok: false, reason: 'disabled' };

  const fetcher = deps.fetcher ?? (globalThis.fetch as unknown as Fetcher);
  const today = deps.today ?? todayLocal();
  const pastDays = deps.pastDays ?? 90;
  const oldest = addDays(today, -pastDays);
  const url =
    `https://intervals.icu/api/v1/athlete/${encodeURIComponent(athleteId)}` +
    `/activities?oldest=${oldest}&newest=${today}`;

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), deps.timeoutMs ?? 10_000);
  let res: { ok: boolean; status: number; json: () => Promise<unknown> };
  try {
    res = await fetcher(url, {
      method: 'GET',
      headers: { Authorization: authHeader, Accept: 'application/json' },
      signal: controller.signal,
    });
  } catch {
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

  const activities: CompletedActivity[] = [];
  for (const raw of body as Record<string, unknown>[]) {
    if (!raw || typeof raw !== 'object') continue;
    // Never ingest our OWN exported lift activities back in (symmetry with
    // the planned-event read path) — keeps this cache endurance-only.
    if (isTresFortExport(raw)) continue;
    const externalId = raw.id != null ? String(raw.id) : null;
    const startLocal = str(raw.start_date_local);
    if (!externalId || !startLocal) continue;
    activities.push({
      external_id: externalId,
      date: startLocal.slice(0, 10), // verbatim civil date, no tz math
      // See note on PlannedEvent.start_date_local_ms — same ordering proxy.
      start_date_local_ms: parseCivilToMs(startLocal),
      kind: kindOf(raw.type),
      name: str(raw.name),
      moving_time_sec: num(raw.moving_time),
      elapsed_time_sec: num(raw.elapsed_time),
      distance_m: num(raw.distance),
      // intervals computes icu_average_watts; fall back to the Strava-style
      // average_watts when only that is present.
      average_watts: num(raw.icu_average_watts) ?? num(raw.average_watts),
      weighted_avg_watts: num(raw.icu_weighted_avg_watts),
      average_hr: num(raw.average_heartrate),
      max_hr: num(raw.max_heartrate),
      training_load: num(raw.icu_training_load),
      intensity: num(raw.icu_intensity),
      calories: num(raw.calories),
      elevation_gain_m: num(raw.total_elevation_gain),
      raw: JSON.stringify(raw),
    });
  }
  return { ok: true, activities };
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
   * tres-fort session id. Drives the DETERMINISTIC `external_id` marker
   * (`liftcoach:session:<id>`) stamped on the remote event so a re-export
   * — even with a lost D1 ref — finds and UPDATEs its own prior event
   * instead of creating a duplicate.
   */
  sessionId: string;
  /**
   * Known intervals.icu event id to UPDATE directly (fast path; from our
   * D1 ledger). When absent we fall back to a marker lookup before any
   * create, so a blind retry never duplicates.
   */
  ref?: string | null;
}

export type PushResult =
  | { ok: true; ref: string }
  | { ok: false; reason: 'disabled' | 'http' | 'timeout' | 'parse'; status?: number };

/** Deterministic, session-stable marker stamped as the event `external_id`.
 *  This is THE idempotency key for the remote artifact (see EXPORT MARKER
 *  note on pushStrengthActivity).
 *
 *  The `liftcoach:` prefix is a FROZEN wire format — it is intentionally NOT
 *  renamed to `tresfort:` in the rebrand. It is already persisted on every
 *  exported intervals.icu event; changing it would orphan those events and
 *  duplicate them on the next sync. Leave it. */
export function exportMarker(sessionId: string): string {
  return `liftcoach:session:${sessionId}`;
}

/** Recognises our own exported lift events (used to keep them OUT of the
 *  endurance `external_events` cache — no self-conflict). Matches either
 *  the deterministic external_id marker or the strength `type`. */
export function isTresFortExport(raw: {
  external_id?: unknown;
  type?: unknown;
}): boolean {
  const ext = typeof raw.external_id === 'string' ? raw.external_id : '';
  if (ext.startsWith('liftcoach:session:')) return true;
  const t = String(raw.type ?? '').toLowerCase();
  return t === 'weighttraining';
}

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
 *
 * EXPORT MARKER / remote idempotency (BLOCKER-1 fix). The intervals.icu
 * event API does NOT expose a verified server-side dedupe on create:
 * `models.py` shows the Event model HAS an `external_id` field and
 * `client.create_event` POSTs an arbitrary body (so we can set it), but
 * `client.get_events` only filters by date window and NO code path relies
 * on the server rejecting/upserting a duplicate `external_id`. So a blind
 * re-POST after a lost D1 ref WOULD create a duplicate. Per the verified
 * API we therefore use the **pre-POST lookup**: stamp a deterministic
 * `external_id = liftcoach:session:<id>` AND, whenever we don't already
 * hold a ref, GET that date's events and PUT-update our own prior event
 * if the marker is present — we never POST without first checking for our
 * own export. Evidence: ~/repos/mcp-servers/intervals-icu/src/
 * intervals_icu_mcp/{models.py:191 external_id field, client.py
 * create_event/get_events/update_event}.
 */
export async function pushStrengthActivity(
  apiKey: string | null | undefined,
  athleteId: string | null | undefined,
  activity: StrengthActivity,
  deps: Pick<FetchDeps, 'fetcher' | 'timeoutMs' | 'accessToken'> = {},
): Promise<PushResult> {
  // Dormant when unconfigured: clean no-op, never an error/throw. Auth is
  // OAuth Bearer when a token is supplied, else HTTP Basic with the API key.
  const authHeader = intervalsAuthHeader(apiKey, deps.accessToken);
  if (!authHeader || !athleteId) return { ok: false, reason: 'disabled' };
  // Capture the narrowed (non-null) header into a string-typed const so the
  // nested `call` closure sees `string`, not `string | null` (TS doesn't
  // propagate the guard's narrowing into nested function bodies).
  const authValue: string = authHeader;

  const fetcher = deps.fetcher ?? (globalThis.fetch as unknown as Fetcher);
  const base =
    `https://intervals.icu/api/v1/athlete/${encodeURIComponent(athleteId)}/events`;
  const marker = exportMarker(activity.sessionId);
  const timeoutMs = deps.timeoutMs ?? 10_000;

  // One AbortController per HTTP call; total wall-time is bounded by each
  // call's own timeout (the export runs off the response path via
  // waitUntil — see db.ts/mcp.ts).
  async function call(
    url: string,
    method: string,
    jsonBody?: string,
  ): Promise<
    | { ok: true; status: number; json: unknown }
    | { ok: false; reason: 'http' | 'timeout' | 'parse'; status?: number }
  > {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    let res: { ok: boolean; status: number; json: () => Promise<unknown> };
    try {
      res = await fetcher(url, {
        method,
        headers: {
          Authorization: authValue,
          Accept: 'application/json',
          ...(jsonBody ? { 'Content-Type': 'application/json' } : {}),
        },
        body: jsonBody,
        signal: controller.signal,
      });
    } catch {
      return { ok: false, reason: 'timeout' };
    } finally {
      clearTimeout(timer);
    }
    if (!res.ok) return { ok: false, reason: 'http', status: res.status };
    try {
      return { ok: true, status: res.status, json: await res.json() };
    } catch {
      return { ok: false, reason: 'parse' };
    }
  }

  const body = JSON.stringify({
    // T00:00:00 suffix is required by the intervals.icu API; the date part
    // is the device-local civil date VERBATIM (no timezone math).
    start_date_local: `${activity.date}T00:00:00`,
    name: activity.name,
    category: 'WORKOUT',
    type: 'WeightTraining',
    moving_time: activity.durationSec,
    icu_training_load: activity.loadTss,
    // Deterministic remote idempotency key (see EXPORT MARKER note).
    external_id: marker,
  });

  // Resolve the target event id. Fast path: a known ref from our ledger.
  let ref: string | null =
    activity.ref != null && activity.ref.length > 0 ? activity.ref : null;

  // Slow path / SAFETY NET: no known ref → look up our own prior export
  // for this date by the deterministic marker BEFORE any create, so a
  // blind retry (D1 ref lost after a successful POST) updates instead of
  // duplicating on intervals.icu.
  if (ref == null) {
    const day = activity.date;
    const lookup = await call(
      `${base}?oldest=${day}&newest=${day}`,
      'GET',
    );
    if (!lookup.ok) {
      return lookup.reason === 'parse'
        ? { ok: false, reason: 'parse' }
        : lookup.reason === 'http'
          ? { ok: false, reason: 'http', status: lookup.status }
          : { ok: false, reason: 'timeout' };
    }
    if (Array.isArray(lookup.json)) {
      for (const e of lookup.json as Record<string, unknown>[]) {
        if (e && typeof e === 'object' && e.external_id === marker && e.id != null) {
          ref = String(e.id);
          break;
        }
      }
    }
  }

  const isUpdate = ref != null;
  const url = isUpdate ? `${base}/${encodeURIComponent(ref!)}` : base;
  const out = await call(url, isUpdate ? 'PUT' : 'POST', body);
  if (!out.ok) {
    return out.reason === 'parse'
      ? { ok: false, reason: 'parse' }
      : out.reason === 'http'
        ? { ok: false, reason: 'http', status: out.status }
        : { ok: false, reason: 'timeout' };
  }

  const parsed = out.json;
  const echoed =
    parsed && typeof parsed === 'object' && (parsed as { id?: unknown }).id != null
      ? String((parsed as { id: unknown }).id)
      : null;
  const finalRef = echoed ?? ref;
  if (!finalRef) return { ok: false, reason: 'parse' };
  return { ok: true, ref: finalRef };
}
