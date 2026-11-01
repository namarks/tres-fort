import type {
  EnrichedTemplateExercise,
  ExternalActivityRow,
  ExternalEventRow,
  PlanTree,
  SessionRow,
  Trip,
  WeeklySchedule,
} from '../../src/types';

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

/** Every API call carries this header; the gateway refuses calls without it. */
const WEB_HEADERS = { 'x-tres-fort-web': '1', accept: 'application/json' };

async function getJson<T>(path: string): Promise<T> {
  const response = await fetch(path, { headers: WEB_HEADERS, credentials: 'same-origin' });
  if (response.status === 401) throw new SignedOutError();
  if (!response.ok) throw new Error(`Request failed (${response.status})`);
  return (await response.json()) as T;
}

export const fetchMe = () => getJson<Me>('/api/me');
export const fetchState = () => getJson<StateResponse>('/api/state');

export async function signOut(): Promise<void> {
  await fetch('/auth/signout', { method: 'POST', headers: WEB_HEADERS, credentials: 'same-origin' });
}
