// Endurance activity writes to intervals.icu. Public callers use the db.ts
// facade. log_activity routes run/ride/swim/walk sessions here so they carry
// distance, pace, HR and calories and count toward intervals.icu training
// load. Nothing is written to the local activities table: the created
// activity returns through the normal completed-activity sync, which this
// service triggers right after a create or delete.
import { addDays } from '../calendarProjection';
import { familyOfIntervalsType, type IntervalsTypeMapping } from '../enduranceActivity';
import {
  createManualActivity,
  deleteIntervalsActivity,
  listActivityRefs,
  type Fetcher,
  type IntervalsActivityRef,
  type IntervalsWriteResult,
} from '../intervals';
import type { Env } from '../types';
import type { ActivitySyncDeps, SyncResult } from './intervalsSync';

export interface EnduranceActivityInput {
  /** Tres Fort UUID sent as the provider external_id (dedupe key). */
  external_id: string;
  date: string;
  /** "HH:MM" in the member's timezone. */
  start_time: string;
  mapping: IntervalsTypeMapping;
  name: string;
  duration_s: number;
  distance_m: number | null;
  avg_hr: number | null;
  calories: number | null;
  notes: string | null;
}

export type EnduranceWriteError = {
  error:
    | 'intervals_not_connected'
    | 'intervals_write_forbidden'
    | 'intervals_unavailable'
    | 'intervals_rejected'
    | 'not_found';
  message: string;
  status?: number;
};

export interface RefreshSummary {
  status: SyncResult['status'] | 'error';
  synced: number;
}

export type EnduranceLogResult =
  | {
      ok: true;
      destination: 'intervals.icu';
      deduplicated: boolean;
      external_id: string;
      intervals_activity: IntervalsActivityRef;
      refresh: RefreshSummary | null;
    }
  | EnduranceWriteError;

export type IntervalsDeleteResult =
  | {
      ok: true;
      destination: 'intervals.icu';
      external_id: string;
      intervals_activity_id: string;
      refresh: RefreshSummary;
    }
  | EnduranceWriteError;

interface IntervalsActivityWriteDependencies {
  resolveIntervalsCredential(db: D1Database, env: Env, userId: string): Promise<
    { apiKey: string | null; accessToken: string | null; athleteId: string } | null
  >;
  syncExternalActivities(db: D1Database, env: Env, deps?: ActivitySyncDeps): Promise<SyncResult>;
}

export interface WriteServiceDeps {
  /** Stubbed in tests; defaults to global fetch. */
  fetcher?: Fetcher;
}

/** Duration slack for treating a provider activity as the same session. */
const DUPLICATE_SLACK_S = 60;

const NOT_CONNECTED: EnduranceWriteError = {
  error: 'intervals_not_connected',
  message:
    'Endurance activities are logged to intervals.icu, but this account has no intervals.icu ' +
    'connection. Connect intervals.icu in the Tres Fort app, then log it again. Nothing was saved.',
};

/** Translate a failed provider call into the caller-visible error. */
function providerError(r: Extract<IntervalsWriteResult<unknown>, { ok: false }>, action: string): EnduranceWriteError {
  if (r.reason === 'disabled') return NOT_CONNECTED;
  if (r.reason === 'http' && (r.status === 401 || r.status === 403)) {
    return {
      error: 'intervals_write_forbidden',
      status: r.status,
      message:
        `intervals.icu refused to ${action} (HTTP ${r.status}). The stored connection may be read-only ` +
        '(connections made before activity write access was requested) or revoked. Reconnect ' +
        'intervals.icu in the Tres Fort app, then try again. Nothing was changed.',
    };
  }
  if (r.reason === 'http' && r.status !== undefined && r.status < 500 && r.status !== 429) {
    return {
      error: 'intervals_rejected',
      status: r.status,
      message: `intervals.icu rejected the request to ${action} (HTTP ${r.status})` +
        `${r.message ? `: ${r.message}` : ''}. Nothing was changed.`,
    };
  }
  return {
    error: 'intervals_unavailable',
    ...(r.status !== undefined ? { status: r.status } : {}),
    message:
      `intervals.icu could not ${action} right now (${r.reason}${r.status !== undefined ? ` ${r.status}` : ''}). ` +
      'Nothing was saved locally; try again shortly.',
  };
}

/** Same session already on intervals.icu: our external id, or the same civil
 *  date, endurance family and duration within a minute. */
function findDuplicate(
  refs: IntervalsActivityRef[],
  input: EnduranceActivityInput,
): IntervalsActivityRef | null {
  const byId = refs.find((r) => r.external_id === input.external_id);
  if (byId) return byId;
  return (
    refs.find((r) => {
      if (r.start_date_local?.slice(0, 10) !== input.date) return false;
      if (familyOfIntervalsType(r.type) !== input.mapping.family) return false;
      return [r.moving_time, r.elapsed_time].some(
        (t) => t !== null && Math.abs(t - input.duration_s) <= DUPLICATE_SLACK_S,
      );
    }) ?? null
  );
}

export function createIntervalsActivityWriteService({
  resolveIntervalsCredential,
  syncExternalActivities,
}: IntervalsActivityWriteDependencies) {
  /** Best-effort cache refresh so the change shows up immediately. */
  async function refresh(
    db: D1Database,
    env: Env,
    userId: string,
    deps: WriteServiceDeps,
  ): Promise<RefreshSummary> {
    try {
      const r = await syncExternalActivities(db, env, {
        userId,
        ...(deps.fetcher ? { fetcher: deps.fetcher } : {}),
      });
      return { status: r.status, synced: r.synced };
    } catch {
      return { status: 'error', synced: 0 };
    }
  }

  /**
   * Create one completed endurance activity on intervals.icu, unless the
   * same session is already there. Any provider failure is returned as an
   * error; there is never a local fallback.
   */
  async function logEnduranceActivity(
    db: D1Database,
    env: Env,
    userId: string,
    input: EnduranceActivityInput,
    deps: WriteServiceDeps = {},
  ): Promise<EnduranceLogResult> {
    const cred = await resolveIntervalsCredential(db, env, userId);
    if (!cred) return NOT_CONNECTED;
    const request = { fetcher: deps.fetcher, accessToken: cred.accessToken };

    const existing = await listActivityRefs(
      cred.apiKey, cred.athleteId, input.date, input.date, request,
    );
    if (!existing.ok) return providerError(existing, 'check for an existing activity');
    const duplicate = findDuplicate(existing.value, input);
    if (duplicate) {
      return {
        ok: true,
        destination: 'intervals.icu',
        deduplicated: true,
        external_id: duplicate.external_id ?? input.external_id,
        intervals_activity: duplicate,
        refresh: null,
      };
    }

    const created = await createManualActivity(
      cred.apiKey,
      cred.athleteId,
      {
        name: input.name,
        type: input.mapping.type,
        start_date_local: `${input.date}T${input.start_time}:00`,
        moving_time: input.duration_s,
        elapsed_time: input.duration_s,
        ...(input.distance_m !== null ? { distance: input.distance_m } : {}),
        ...(input.avg_hr !== null ? { average_heartrate: input.avg_hr } : {}),
        ...(input.calories !== null ? { calories: input.calories } : {}),
        trainer: input.mapping.trainer,
        ...(input.notes ? { description: input.notes } : {}),
        external_id: input.external_id,
      },
      request,
    );
    if (!created.ok) return providerError(created, 'create the activity');
    return {
      ok: true,
      destination: 'intervals.icu',
      deduplicated: false,
      external_id: input.external_id,
      intervals_activity: created.value,
      refresh: await refresh(db, env, userId, deps),
    };
  }

  /**
   * Delete the intervals.icu activity Tres Fort created with this external
   * id. Only an exact external_id match is eligible, so watch-synced or
   * hand-entered provider activities can never be deleted here. Looks in the
   * synced cache first, then asks the provider over `searchFrom..searchTo`.
   */
  async function deleteIntervalsActivityByExternalId(
    db: D1Database,
    env: Env,
    userId: string,
    externalId: string,
    window: { today: string; date?: string },
    deps: WriteServiceDeps = {},
  ): Promise<IntervalsDeleteResult> {
    const cred = await resolveIntervalsCredential(db, env, userId);
    if (!cred) return NOT_CONNECTED;
    const request = { fetcher: deps.fetcher, accessToken: cred.accessToken };

    const cached = await db
      .prepare(
        `SELECT external_id FROM external_activities
          WHERE user_id = ?1 AND source = 'intervals' AND deleted_at IS NULL
            AND json_extract(raw, '$.external_id') = ?2
          LIMIT 1`,
      )
      .bind(userId, externalId)
      .first<{ external_id: string }>();
    let providerId = cached?.external_id ?? null;
    if (providerId === null) {
      const from = window.date ?? addDays(window.today, -90);
      const to = window.date ?? addDays(window.today, 1);
      const listed = await listActivityRefs(cred.apiKey, cred.athleteId, from, to, request);
      if (!listed.ok) return providerError(listed, 'look up the activity');
      providerId = listed.value.find((r) => r.external_id === externalId)?.id ?? null;
    }
    if (providerId === null) {
      return {
        error: 'not_found',
        message:
          `No local activity or Tres Fort-created intervals.icu activity has id ${externalId}. ` +
          'Check get_recent_activities or the activity log for the right id.',
      };
    }
    const deleted = await deleteIntervalsActivity(cred.apiKey, providerId, request);
    if (!deleted.ok) return providerError(deleted, 'delete the activity');
    return {
      ok: true,
      destination: 'intervals.icu',
      external_id: externalId,
      intervals_activity_id: providerId,
      refresh: await refresh(db, env, userId, deps),
    };
  }

  return { logEnduranceActivity, deleteIntervalsActivityByExternalId };
}
