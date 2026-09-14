import { env, applyD1Migrations, createExecutionContext, createScheduledController, SELF, waitOnExecutionContext } from 'cloudflare:test';
import { afterEach, beforeAll, describe, expect, it, vi } from 'vitest';
import worker from '../src/index';
import { diagnosticErrorType, publicToolErrorCode } from '../src/errors';

const BASE = 'https://tres-fort.test';
const PRIVATE = 'synthetic-private-training-and-credential-marker';

beforeAll(async () => { await applyD1Migrations(env.DB, env.TEST_MIGRATIONS); });
afterEach(() => { vi.restoreAllMocks(); });

function privateError(): Error {
  const error = new Error(PRIVATE, { cause: new Error(PRIVATE) });
  error.name = PRIVATE;
  error.stack = PRIVATE;
  return error;
}

function failingDb(fragment: string, failure: unknown): D1Database {
  return new Proxy(env.DB, {
    get(target, property) {
      if (property === 'prepare') {
        return (query: string) => {
          if (query.includes(fragment)) throw failure;
          return target.prepare(query);
        };
      }
      const value = Reflect.get(target, property, target);
      return typeof value === 'function' ? value.bind(target) : value;
    },
  });
}

async function devJwt(): Promise<string> {
  const response = await SELF.fetch(`${BASE}/auth/dev`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ secret: 'test-dev' }),
  });
  expect(response.status).toBe(200);
  return (await response.json<{ jwt: string }>()).jwt;
}

function logs() {
  const error = vi.spyOn(console, 'error').mockImplementation(() => undefined);
  const warn = vi.spyOn(console, 'warn').mockImplementation(() => undefined);
  const log = vi.spyOn(console, 'log').mockImplementation(() => undefined);
  return { error, assertPrivate() {
    expect(JSON.stringify([error.mock.calls, warn.mock.calls, log.mock.calls])).not.toContain(PRIVATE);
  } };
}

describe('unexpected error privacy', () => {
  it.each([false, true])('keeps HTTP error text, cause, names, headers and query values out of responses/logs (non-Error: %s)', async (nonError) => {
    const jwt = await devJwt(), captured = logs();
    const failure = nonError ? { message: PRIVATE, token: PRIVATE } : privateError();
    const context = createExecutionContext();
    const response = await worker.fetch(new Request(`${BASE}/api/me?private=${PRIVATE}`, {
      headers: { Authorization: `Bearer ${jwt}`, 'X-Private-Test': PRIVATE },
    }), { ...env, DB: failingDb('SELECT display_name, email', failure) }, context);
    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({ error: 'internal', message: 'Something went wrong. Please try again.' });
    expect(captured.error).toHaveBeenCalledOnce();
    expect(captured.error).toHaveBeenCalledWith({
      event: 'unexpected_error', surface: 'http', error_type: nonError ? 'unknown' : 'Error',
    });
    captured.assertPrivate();
    await waitOnExecutionContext(context);
  });

  it('keeps unexpected MCP failures private while preserving the tool-error transport', async () => {
    await devJwt();
    const captured = logs(), context = createExecutionContext();
    const response = await worker.fetch(new Request(`${BASE}/mcp`, {
      method: 'POST', headers: { Authorization: 'Bearer test-mcp-token', 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call',
        params: { name: 'get_history', arguments: { exercise: 'bench' } } }),
    }), { ...env, DB: failingDb('SELECT * FROM exercises', privateError()) }, context);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ jsonrpc: '2.0', id: 1, result: {
      content: [{ type: 'text', text: 'error: internal. Check current state before retrying a write.' }], isError: true,
    } });
    expect(captured.error).toHaveBeenCalledOnce();
    expect(captured.error).toHaveBeenCalledWith({ event: 'unexpected_error', surface: 'mcp_tool', error_type: 'Error' });
    captured.assertPrivate();
    await waitOnExecutionContext(context);
  });

  it('rejects retired workout fields without logging member input or recording a mutation', async () => {
    await devJwt();
    const before = await env.DB.prepare('SELECT (SELECT COUNT(*) FROM plans) AS plans, (SELECT COUNT(*) FROM audit_log) AS audits, (SELECT COUNT(*) FROM notes) AS notes').first();
    const captured = logs(), context = createExecutionContext();
    const response = await worker.fetch(new Request(`${BASE}/mcp`, {
      method: 'POST', headers: { Authorization: 'Bearer test-mcp-token', 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: {
        name: 'update_plan', arguments: { name: PRIVATE, workouts: [{ name: PRIVATE, exercises: [] }], days: [] },
      } }),
    }), env, context);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ jsonrpc: '2.0', id: 2, result: {
      content: [{ type: 'text', text: JSON.stringify({ error: 'unsupported_workout_fields' }) }], isError: true,
    } });
    expect(captured.error).not.toHaveBeenCalled();
    captured.assertPrivate();
    await waitOnExecutionContext(context);
    expect(await env.DB.prepare('SELECT (SELECT COUNT(*) FROM plans) AS plans, (SELECT COUNT(*) FROM audit_log) AS audits, (SELECT COUNT(*) FROM notes) AS notes').first()).toEqual(before);
  });

  it('keeps a failed cron marked failed without exposing the original platform exception', async () => {
    const captured = logs();
    const pending: Promise<unknown>[] = [];
    // Capture the real scheduled handler's rejected work directly. The test
    // pool registers createExecutionContext promises a second time globally,
    // making an intentionally asserted rejection fail suite teardown too.
    const context: ExecutionContext = {
      waitUntil(promise) { pending.push(promise); },
      passThroughOnException() {},
      props: {},
    };
    await worker.scheduled(createScheduledController({ scheduledTime: new Date(), cron: '0 * * * *' }),
      { ...env, DB: failingDb('', privateError()) }, context);
    expect(pending).toHaveLength(1);
    await expect(pending[0]).rejects.toThrow('Scheduled task failed');
    expect(captured.error).toHaveBeenCalledOnce();
    expect(captured.error).toHaveBeenCalledWith({ event: 'unexpected_error', surface: 'scheduled', error_type: 'Error' });
    captured.assertPrivate();
  });

  it('returns only fixed diagnostic categories and allowlisted public condition codes', () => {
    expect(diagnosticErrorType(privateError())).toBe('Error');
    const renamed = new TypeError(PRIVATE);
    renamed.name = PRIVATE;
    expect(diagnosticErrorType(renamed)).toBe('TypeError');
    expect(diagnosticErrorType({ name: PRIVATE })).toBe('unknown');
    expect(publicToolErrorCode(privateError())).toBeNull();
    expect(publicToolErrorCode({ message: 'no_active_plan' })).toBeNull();
    expect(publicToolErrorCode(new Error('no_active_plan'))).toBe('no_active_plan');
    expect(publicToolErrorCode(new Error('unknown_exercise:' + PRIVATE))).toBe('unknown_exercise');
  });
});
