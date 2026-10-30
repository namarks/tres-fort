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
  uploadActivityFile,
  type Fetcher,
  type IntervalsActivityRef,
  type IntervalsWriteResult,
} from '../intervals';
import type { Env } from '../types';
import type { ActivitySyncDeps, SyncResult } from './intervalsSync';

/** Prefix that marks a provider activity as created by Tres Fort. Only an
 *  external_id carrying it is ever deleted, so a watch import whose own
 *  external_id happens to be passed to delete_activity is never touched. */
export const TRES_FORT_ACTIVITY_PREFIX = 'tresfort:activity:';

/** Provider external_id for a Tres Fort activity UUID (idempotent). */
export function tresFortExternalId(id: string): string {
  return id.startsWith(TRES_FORT_ACTIVITY_PREFIX) ? id : `${TRES_FORT_ACTIVITY_PREFIX}${id}`;
}

function isTresFortCreated(externalId: string | null): externalId is string {
  return externalId !== null && externalId.startsWith(TRES_FORT_ACTIVITY_PREFIX);
}

/** Prefix that marks a run recorded in the Tres Fort app and uploaded as a
 *  file (docs/plans/run-recorder). */
export const TRES_FORT_RECORDING_PREFIX = 'tresfort:recording:';

/** Largest recorded-run file accepted. A two-hour GPX at one point per
 *  second is a few megabytes; FIT is far smaller. */
export const MAX_RECORDING_BYTES = 10 * 1024 * 1024;

export type RecordingFormat = 'fit' | 'gpx' | 'tcx';

/**
 * The file's format, from its extension, when its first bytes agree: a FIT
 * header carries ".FIT" at offset 8, and GPX/TCX are XML with their root
 * element near the start. Null for anything else.
 */
export function recordingFormat(filename: string, head: Uint8Array): RecordingFormat | null {
  const ext = /\.([a-z]+)$/i.exec(filename)?.[1]?.toLowerCase();
  if (ext === 'fit') {
    return String.fromCharCode(...head.subarray(8, 12)) === '.FIT' ? 'fit' : null;
  }
  if (ext !== 'gpx' && ext !== 'tcx') return null;
  const text = new TextDecoder().decode(head.subarray(0, 1024));
  if (ext === 'gpx') return text.includes('<gpx') ? 'gpx' : null;
  return text.includes('<TrainingCenterDatabase') ? 'tcx' : null;
}

export interface RecordedRunInput {
  /** Client UUID of the recording; sent prefixed as the provider external_id. */
  recording_id: string;
  /** Civil start date, for the earlier-upload lookup and the refresh window. */
  date: string;
  file: Blob;
  format: RecordingFormat;
  name: string | null;
}

export type RecordedRunUploadResult =
  | {
      ok: true;
      destination: 'intervals.icu';
      deduplicated: boolean;
      recording_id: string;
      /** Null only when intervals.icu reported a duplicate file without its id. */
      intervals_activity_id: string | null;
      refresh: RefreshSummary;
    }
  | EnduranceWriteError;

export interface EnduranceActivityInput {
  /** Tres Fort activity UUID; sent prefixed as the provider external_id. */
  activity_id: string;
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
      /** The Tres Fort id delete_activity accepts; null when the matching
       *  activity was not created by Tres Fort (a watch import, say). */
      activity_id: string | null;
      intervals_activity: IntervalsActivityRef;
      refresh: RefreshSummary;
    }
  | EnduranceWriteError;

export type IntervalsDeleteResult =
  | {
      ok: true;
      destination: 'intervals.icu';
      activity_id: string;
      intervals_activity_id: string;
      already_deleted?: true;
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
  const externalId = tresFortExternalId(input.activity_id);
  const byId = refs.find((r) => r.external_id === externalId);
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
  /**
   * Best-effort cache refresh so the change shows up immediately. The window
   * always contains `date`, so a backfilled or deleted activity older than
   * the default 90 days still reaches (or leaves) the cache.
   */
  async function refresh(
    db: D1Database,
    env: Env,
    userId: string,
    date: string,
    deps: WriteServiceDeps,
  ): Promise<RefreshSummary> {
    const utcToday = new Date().toISOString().slice(0, 10);
    const today = date > utcToday ? date : utcToday;
    const span = Math.ceil((Date.parse(`${today}T00:00:00Z`) - Date.parse(`${date}T00:00:00Z`)) / 86_400_000);
    try {
      const r = await syncExternalActivities(db, env, {
        userId,
        today,
        pastDays: Math.max(90, Number.isFinite(span) ? span : 0),
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
        activity_id: isTresFortCreated(duplicate.external_id)
          ? duplicate.external_id.slice(TRES_FORT_ACTIVITY_PREFIX.length)
          : null,
        intervals_activity: duplicate,
        // A retry after a create whose refresh failed must still reach the
        // cache, and the default sync window may not cover an old date.
        refresh: await refresh(db, env, userId, duplicate.start_date_local?.slice(0, 10) ?? input.date, deps),
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
        external_id: tresFortExternalId(input.activity_id),
      },
      request,
    );
    if (!created.ok) return providerError(created, 'create the activity');
    return {
      ok: true,
      destination: 'intervals.icu',
      deduplicated: false,
      activity_id: input.activity_id,
      intervals_activity: created.value,
      refresh: await refresh(db, env, userId, input.date, deps),
    };
  }

  /**
   * Delete the intervals.icu activity Tres Fort created for this activity id
   * (the bare UUID or its prefixed external_id). Only an activity whose
   * external_id carries the Tres Fort prefix is eligible, so watch-synced or
   * hand-entered provider activities can never be deleted here. Looks in the
   * synced cache first, then asks the provider (on `date`, or the last 90
   * days). The refresh window then contains the deleted activity's date.
   */
  async function deleteIntervalsActivityByExternalId(
    db: D1Database,
    env: Env,
    userId: string,
    activityId: string,
    window: { today: string; date?: string },
    deps: WriteServiceDeps = {},
  ): Promise<IntervalsDeleteResult> {
    const cred = await resolveIntervalsCredential(db, env, userId);
    if (!cred) return NOT_CONNECTED;
    const request = { fetcher: deps.fetcher, accessToken: cred.accessToken };
    const externalId = tresFortExternalId(activityId);

    let target: { id: string; date: string } | null = await db
      .prepare(
        `SELECT external_id AS id, date FROM external_activities
          WHERE user_id = ?1 AND source = 'intervals' AND deleted_at IS NULL
            AND json_extract(raw, '$.external_id') = ?2
          LIMIT 1`,
      )
      .bind(userId, externalId)
      .first<{ id: string; date: string }>();
    if (target === null) {
      const from = window.date ?? addDays(window.today, -90);
      const to = window.date ?? addDays(window.today, 1);
      const listed = await listActivityRefs(cred.apiKey, cred.athleteId, from, to, request);
      if (!listed.ok) return providerError(listed, 'look up the activity');
      const ref = listed.value.find((r) => r.external_id === externalId);
      if (ref) target = { id: ref.id, date: ref.start_date_local?.slice(0, 10) ?? window.date ?? window.today };
    }
    if (target === null) {
      return {
        error: 'not_found',
        message:
          `No local activity or Tres Fort-created intervals.icu activity has id ${activityId}. ` +
          'Activities synced from a watch or entered in intervals.icu cannot be deleted here.',
      };
    }
    const deleted = await deleteIntervalsActivity(cred.apiKey, target.id, request);
    // A 404 means an earlier delete already removed it (say its refresh
    // failed): still reconcile, or an old cached row would stay live.
    const alreadyGone = !deleted.ok && deleted.reason === 'http' && deleted.status === 404;
    if (!deleted.ok && !alreadyGone) return providerError(deleted, 'delete the activity');
    return {
      ok: true,
      destination: 'intervals.icu',
      activity_id: externalId.slice(TRES_FORT_ACTIVITY_PREFIX.length),
      intervals_activity_id: target.id,
      ...(alreadyGone ? { already_deleted: true } : {}),
      refresh: await refresh(db, env, userId, target.date, deps),
    };
  }

  /**
   * Upload a run recorded in the app to intervals.icu as an activity file,
   * unless an earlier attempt already did. The GPS stream passes through and
   * is never stored here; the activity returns through the normal sync.
   * Provider failure is an error, never a local fallback.
   */
  async function uploadRecordedRun(
    db: D1Database,
    env: Env,
    userId: string,
    input: RecordedRunInput,
    deps: WriteServiceDeps = {},
  ): Promise<RecordedRunUploadResult> {
    const cred = await resolveIntervalsCredential(db, env, userId);
    if (!cred) return NOT_CONNECTED;
    const request = { fetcher: deps.fetcher, accessToken: cred.accessToken };
    const externalId = `${TRES_FORT_RECORDING_PREFIX}${input.recording_id}`;

    // A day either side: the device's civil date and intervals.icu's local
    // date can differ for a run that crosses midnight or a timezone.
    const existing = await listActivityRefs(
      cred.apiKey, cred.athleteId, addDays(input.date, -1), addDays(input.date, 1), request,
    );
    if (!existing.ok) return providerError(existing, 'check for an earlier upload');
    const earlier = existing.value.find((r) => r.external_id === externalId);
    if (earlier) {
      return {
        ok: true,
        destination: 'intervals.icu',
        deduplicated: true,
        recording_id: input.recording_id,
        intervals_activity_id: earlier.id,
        refresh: await refresh(db, env, userId, earlier.start_date_local?.slice(0, 10) ?? input.date, deps),
      };
    }

    const uploaded = await uploadActivityFile(
      cred.apiKey,
      cred.athleteId,
      {
        file: input.file,
        filename: `${input.recording_id}.${input.format}`,
        ...(input.name ? { name: input.name } : {}),
        external_id: externalId,
      },
      request,
    );
    if (!uploaded.ok) return providerError(uploaded, 'upload the run');
    return {
      ok: true,
      destination: 'intervals.icu',
      deduplicated: !uploaded.value.created,
      recording_id: input.recording_id,
      intervals_activity_id: uploaded.value.ids[0] ?? null,
      refresh: await refresh(db, env, userId, input.date, deps),
    };
  }

  return { logEnduranceActivity, deleteIntervalsActivityByExternalId, uploadRecordedRun };
}
