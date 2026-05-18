export interface Env {
  DB: D1Database;
  APPLE_BUNDLE_ID: string;
  APP_JWT_SECRET: string;
  MCP_STATIC_TOKEN?: string;
  /** Allowlisted Apple `sub`. If set, only this user may sign in. */
  OWNER_APPLE_SUB?: string;
  /** If set, enables POST /auth/dev for local + integration tests. */
  DEV_AUTH_SECRET?: string;
  /** Consent gate for the OAuth /authorize step (claude.ai/desktop). */
  OWNER_AUTH_PASSPHRASE?: string;
}

export type HonoEnv = {
  Bindings: Env;
  Variables: { userId: string };
};

export interface User {
  id: string;
  apple_sub: string;
  email: string | null;
  display_name: string | null;
  created_at: number;
}

export interface PlanRow {
  id: string;
  user_id: string;
  name: string;
  status: string;
  version: number;
  meta: string | null;
  created_at: number;
  updated_at: number;
}

export interface DayTemplateRow {
  id: string;
  plan_id: string;
  name: string;
  day_label: string | null;
  order_index: number;
  notes: string | null;
  created_at: number;
  updated_at: number;
}

export interface TemplateExerciseRow {
  id: string;
  day_template_id: string;
  exercise_id: string;
  order_index: number;
  target_sets: number;
  target_reps: number;
  target_reps_max: number | null;
  target_rpe: number | null;
  rest_seconds: number;
  target_weight: number | null;
  progression: string | null;
  cues: string | null;
  created_at: number;
  updated_at: number;
}

export interface SessionRow {
  id: string;
  user_id: string;
  plan_id: string;
  day_template_id: string | null;
  date: string;
  status: string;
  started_at: number | null;
  completed_at: number | null;
  perceived_fatigue: number | null;
  notes: string | null;
  created_at: number;
  updated_at: number;
}

export interface SetLogRow {
  id: string;
  session_id: string;
  exercise_id: string;
  template_exercise_id: string | null;
  set_index: number;
  weight: number;
  reps: number;
  rpe: number | null;
  is_warmup: number;
  notes: string | null;
  logged_at: number;
  source: string;
  deleted_at: number | null;
}

export interface PlanTree extends PlanRow {
  days: (DayTemplateRow & { exercises: TemplateExerciseRow[] })[];
}
