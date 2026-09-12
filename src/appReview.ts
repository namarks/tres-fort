import type { Env } from './types';

// Reserved server identity: never an Apple subject or the MCP owner sentinel.
export const APP_REVIEW_SUB = 'tres-fort:app-review';
export const APP_REVIEW_USERNAME = 'app-review';

export function appReviewEnabled(env: Env): boolean {
  return !!env.OWNER_APPLE_SUB && env.OWNER_APPLE_SUB !== APP_REVIEW_SUB
    && /^[a-f0-9]{64}$/.test(env.APP_REVIEW_PASSWORD_SHA256 ?? '');
}

export async function validAppReviewCredentials(env: Env, body: unknown): Promise<boolean> {
  if (!appReviewEnabled(env) || !body || typeof body !== 'object') return false;
  if (!('username' in body) || !('password' in body)
      || body.username !== APP_REVIEW_USERNAME || typeof body.password !== 'string'
      || body.password.length < 32 || body.password.length > 256) return false;
  // The credential must be randomly generated, not a human password. Store
  // only its SHA-256 digest as a Worker secret; never ship it in the app.
  const actual = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(body.password));
  const expected = Uint8Array.from(env.APP_REVIEW_PASSWORD_SHA256!.match(/../g)!, pair => parseInt(pair, 16));
  return crypto.subtle.timingSafeEqual(actual, expected);
}

/** Shared sample access cannot connect personal sources, a coach, or groups.
 * New endpoint families require an explicit decision to expose to review. */
export function appReviewAllows(method: string, path: string): boolean {
  if (method === 'POST' && path === '/auth/renew') return true;
  if (path === '/api/me') return method === 'GET' || method === 'DELETE';
  if (path === '/api/me/export' || path === '/api/groups') return method === 'GET';
  if (path === '/api/me/profile') return method === 'PATCH';
  if (path === '/api/activities/healthkit') return false;
  return /^\/api\/(state|plan|calendar|today|workouts|days|sessions|sets|exercises|history|volume|activities)(\/|$)/.test(path);
}
