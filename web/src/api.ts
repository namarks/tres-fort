import type {
  EnrichedTemplateExercise,
  ExternalActivityRow,
  ExternalEventRow,
  PlanTree,
  SessionRow,
  Trip,
  WeeklySchedule,
} from '../../src/types';
import type { CatalogExercise } from './editing';
import type { ActivityRouteResponse } from './routeMap';

/** The plan tree as GET /api/state returns it, with parsed plan meta. */
export type StatePlan = PlanTree & {
  schedule: WeeklySchedule;
  trips: Trip[];
  workouts: (PlanTree['workouts'][number] & { exercises: EnrichedTemplateExercise[] })[];
};

type LoadFields = 'effective_load' | 'effective_intensity' | 'load_method';

/** A completed activity; an API Worker without migration 0060 omits the load fields. */
export type StateActivity = Omit<ExternalActivityRow, LoadFields> & Partial<Pick<ExternalActivityRow, LoadFields>>;

export interface StateResponse {
  plan: StatePlan | null;
  plan_version: number;
  sessions: SessionRow[];
  external_events: ExternalEventRow[];
  external_activities: StateActivity[];
}

export interface Me {
  id: string;
  display_name: string | null;
  email: string | null;
}

export class SignedOutError extends Error {
  constructor() {
    super('signed_out');
  }
}

/** A refused request, with the API's JSON answer. */
export class ApiError extends Error {
  constructor(readonly status: number, readonly body: unknown) {
    super(`Request failed (${status})`);
  }
}

/** The plan changed since the page loaded it (in the app, or by the coach). */
export function isVersionConflict(error: unknown): boolean {
  return error instanceof ApiError && error.status === 409
    && (error.body as { conflict?: unknown } | null)?.conflict === true;
}

/** Every API call carries this header; the gateway refuses calls without it. */
const WEB_HEADERS = { 'x-tres-fort-web': '1', accept: 'application/json' };

async function request<T>(method: string, path: string, body?: unknown): Promise<T> {
  const response = await fetch(path, {
    method,
    credentials: 'same-origin',
    headers: body === undefined ? WEB_HEADERS : { ...WEB_HEADERS, 'content-type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  if (response.status === 401) throw new SignedOutError();
  const payload: unknown = await response.json().catch(() => null);
  if (!response.ok) throw new ApiError(response.status, payload);
  return payload as T;
}

const getJson = <T>(path: string) => request<T>('GET', path);

export const fetchMe = () => getJson<Me>('/api/me');
export const fetchState = () => getJson<StateResponse>('/api/state');
export const fetchExercises = () => getJson<CatalogExercise[]>('/api/exercises');

/** A run's GPS route, or null when the activity has none. Routes are the member's own. */
export async function fetchActivityRoute(activityId: string): Promise<ActivityRouteResponse | null> {
  try {
    return await getJson<ActivityRouteResponse>(`/api/activities/${encodeURIComponent(activityId)}/route`);
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) return null;
    throw error;
  }
}

/** The MapKit JS token for this site, or null when maps aren't set up. */
export async function fetchMapToken(): Promise<string | null> {
  try {
    const { token } = await getJson<{ token?: unknown }>('/maps/token');
    return typeof token === 'string' && token.length > 0 ? token : null;
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) return null;
    throw error;
  }
}

/** The plan version a write was reviewed against. */
export interface Reviewed {
  planId: string;
  version: number;
}

const id = encodeURIComponent;

/** Every plan write names the version the member saw; a newer plan answers 409. */
export const planWrites = {
  /** A member's first plan, for a web sign-up with nothing yet. */
  startPlan: () => request<{ plan: { id: string; version: number } }>('PUT', '/api/plan/active', { name: 'My Training' }),
  addWorkout: (name: string, at: Reviewed) =>
    request<{ id: string }>('POST', '/api/workouts', {
      name, expected_plan_id: at.planId, expected_version: at.version,
    }),
  updateWorkout: (workoutId: string, fields: Record<string, unknown>, at: Reviewed) =>
    request('PATCH', `/api/workouts/${id(workoutId)}`, { ...fields, expected_version: at.version }),
  deleteWorkout: (workoutId: string, at: Reviewed) =>
    request('DELETE', `/api/workouts/${id(workoutId)}?expected_version=${at.version}`),
  addSlot: (workoutId: string, exerciseId: string, fields: Record<string, unknown>, at: Reviewed) =>
    request('POST', `/api/workouts/${id(workoutId)}/exercises`, {
      ...fields, exercise: exerciseId, expected_version: at.version,
    }),
  updateSlot: (workoutId: string, slotId: string, fields: Record<string, unknown>, at: Reviewed) =>
    request('PATCH', `/api/workouts/${id(workoutId)}/exercises/${id(slotId)}`, { ...fields, expected_version: at.version }),
  removeSlot: (workoutId: string, slotId: string, at: Reviewed) =>
    request('DELETE', `/api/workouts/${id(workoutId)}/exercises/${id(slotId)}?expected_version=${at.version}`),
  replaceSlot: (workoutId: string, slotId: string, exerciseId: string, at: Reviewed) =>
    request('POST', `/api/workouts/${id(workoutId)}/exercises/${id(slotId)}/swap`, {
      to_exercise: exerciseId, expected_version: at.version,
    }),
  /**
   * Creates or rewrites a superset or circuit: its members in order, rounds
   * and rests, and optionally where the whole block lands (the number of other
   * exercises before it). A retry keeps the same group id.
   */
  setGroup: (
    workoutId: string,
    groupId: string,
    members: string[],
    values: { target_sets: number; round_rest: number; transition_rest: number; order_index?: number },
    at: Reviewed,
  ) =>
    request('PUT', `/api/workouts/${id(workoutId)}/groups`, {
      group_id: groupId, exercises: members, ...values, expected_version: at.version,
    }),
  /** Ungroups; each exercise keeps the sets and rest it had before grouping. */
  clearGroup: (workoutId: string, groupId: string, at: Reviewed) =>
    request('PUT', `/api/workouts/${id(workoutId)}/groups`, {
      group_id: groupId, exercises: [], expected_version: at.version,
    }),
  /** The whole weekly routine; a day left out would become rest. */
  setRoutine: (week: Record<string, string | null>, at: Reviewed) =>
    request('PUT', '/api/plan/schedule', { week, expected_plan_id: at.planId, expected_version: at.version }),
  addAwayDates: (fields: Record<string, unknown>, at: Reviewed) =>
    request('POST', '/api/plan/trips', { ...fields, expected_version: at.version }),
  updateAwayDates: (tripId: string, fields: Record<string, unknown>, at: Reviewed) =>
    request('PATCH', `/api/plan/trips/${id(tripId)}`, { ...fields, expected_version: at.version }),
  removeAwayDates: (tripId: string, at: Reviewed) =>
    request('DELETE', `/api/plan/trips/${id(tripId)}?expected_version=${at.version}`),
};

/**
 * One date only, outside the versioned plan: each date's sessions row has an
 * attempt counter instead, and a write names the attempt the page saw (0 for
 * none), so two devices can't both change the same date unseen.
 */
export const dateWrites = {
  /** A workout on this date, or rest (null). */
  setDate: (date: string, workoutId: string | null, expectedAttempt: number) =>
    request('PUT', `/api/calendar/${id(date)}`, { workout_id: workoutId, expected_attempt: expectedAttempt }),
  /** Moves a date's workout to another date; the first date becomes rest. */
  moveDate: (move: {
    from: string; to: string; today: string; workoutId: string;
    fromAttempt: number; toAttempt: number;
  }, at: Reviewed) =>
    request('POST', `/api/calendar/${id(move.from)}/move`, {
      id: crypto.randomUUID(), to_date: move.to, today: move.today, workout_id: move.workoutId,
      expected_plan_id: at.planId, expected_version: at.version,
      expected_from_attempt: move.fromAttempt, expected_to_attempt: move.toAttempt,
    }),
};

export async function signOut(): Promise<void> {
  const response = await fetch('/auth/signout', { method: 'POST', headers: WEB_HEADERS, credentials: 'same-origin' });
  if (!response.ok) throw new Error('Couldn’t sign out. Please try again.');
}
