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
 * NOTE: on the EVENTS path "WeightTraining" never reaches here —
 * isTresFortExport() filters it upstream — but on the ACTIVITIES path only
 * our marker-stamped exports are filtered (isOwnExportMarker), so a
 * member's genuine "WeightTraining"/"Strength"/"WeightLifting" lands on the
 * 'strength' branch. Keep the kinds emitted here in sync with the glyph maps
 * in ios FeedItemRow.rideGlyph and Models.ExternalActivity.glyph.
 */
function kindOf(type: unknown): string {
  const t = String(type ?? '').toLowerCase();
  if (t.includes('ride') || t.includes('bike') || t.includes('cycl')) return 'ride';
  if (t.includes('run')) return 'run';
  if (t.includes('swim')) return 'swim';
  if (t.includes('walk')) return 'walk';
  if (t.includes('hik')) return 'hike'; // matches "Hike" and the alias "Hiking"
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
    // Never ingest a (now-legacy) Tres Fort lift export back into the
    // endurance cache. The one-way load export was removed, but WeightTraining
    // events it wrote previously may still exist in a user's intervals.icu
    // account; keeping them out of `external_events` keeps it endurance-only
    // and avoids detectConflicts flagging a lift day against its own old event.
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
 * the same discriminated result shape as fetchPlannedEvents. Only our own
 * marker-stamped exports are skipped (isOwnExportMarker) — a member's
 * genuine recorded strength (`WeightTraining`) is KEPT and classified, since
 * this cache feeds display only. `date` is the `start_date_local` date part
 * VERBATIM — no timezone math (the contract).
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
    // Skip ONLY our own marker-stamped exports — NOT every WeightTraining
    // row. Unlike the planned-event path, dropping all weight-training here
    // would hide a member's genuine watch-recorded strength activity from
    // the feed/calendar (this cache feeds display only, never the conflict/
    // load math). Marker-only detection keeps real strength, drops exports.
    if (isOwnExportMarker(raw)) continue;
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

// ---- read-path filter: legacy exported lift events -------------------
//
// Tres Fort once exported lifting load to intervals.icu as WeightTraining
// WORKOUT events; that export was removed. Those events may still exist in
// a user's intervals.icu account, so the inbound sync paths screen them out
// via the two helpers below, keeping the endurance caches free of our own
// (now-historical) strength exports.

/** Recognises our own exported lift events (used to keep them OUT of the
 *  endurance `external_events` cache — no self-conflict). Matches either
 *  the deterministic external_id marker or the strength `type`.
 *
 *  USE ON THE EVENTS PATH ONLY. The `type === 'weighttraining'` clause is
 *  belt-and-suspenders for the planned-events read-back, where ingesting
 *  our own export would make detectConflicts flag a self-conflict
 *  (BLOCKER-3). The completed-activities path must NOT use this — a
 *  member's genuine watch-recorded `WeightTraining` would be dropped
 *  entirely — so it uses isOwnExportMarker (marker-only) instead. */
export function isTresFortExport(raw: {
  external_id?: unknown;
  type?: unknown;
}): boolean {
  if (isOwnExportMarker(raw)) return true;
  const t = String(raw.type ?? '').toLowerCase();
  return t === 'weighttraining';
}

/** Marker-only variant of isTresFortExport. Matches ONLY our deterministic
 *  `liftcoach:session:` external_id, never the generic `WeightTraining`
 *  type. Used on the completed-activities read path: our exports are
 *  planned EVENTS that don't surface in the /activities feed, and
 *  `external_activities` feeds only the display feed/calendar (never the
 *  conflict/load math, which reads `external_events`), so a member's real
 *  strength activity is safe to keep and classify. */
export function isOwnExportMarker(raw: { external_id?: unknown }): boolean {
  const ext = typeof raw.external_id === 'string' ? raw.external_id : '';
  return ext.startsWith('liftcoach:session:');
}
