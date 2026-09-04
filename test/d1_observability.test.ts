import {
  env,
  applyD1Migrations,
  createExecutionContext,
  createScheduledController,
  SELF,
  waitOnExecutionContext,
} from 'cloudflare:test';
import { afterEach, beforeAll, describe, expect, it, vi } from 'vitest';
import worker from '../src/index';
import { createD1UsageObserver } from '../src/db';

const BASE = 'https://tres-fort.test';

interface UsageLog {
  event: 'd1_usage';
  operation: string;
  outcome: 'ok' | 'error';
  query_count: number;
  rows_read: number;
  rows_written: number;
}

const USAGE_LOG_KEYS = [
  'event',
  'operation',
  'outcome',
  'query_count',
  'rows_read',
  'rows_written',
].sort();

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

async function devJwt(): Promise<string> {
  const response = await SELF.fetch(`${BASE}/auth/dev`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ secret: 'test-dev' }),
  });
  expect(response.status).toBe(200);
  return (await response.json<{ jwt: string }>()).jwt;
}

function usageLogs(spy: ReturnType<typeof vi.spyOn>): UsageLog[] {
  const logs: UsageLog[] = [];
  for (const call of spy.mock.calls) {
    const value: unknown = call[0];
    if (value === null || typeof value !== 'object' || Array.isArray(value)) continue;
    const fields = value as Record<string, unknown>;
    if (fields.event !== 'd1_usage') continue;
    // Validate the object before projecting it into UsageLog so a newly added
    // identity, token, request URL, or argument field fails this contract.
    expect(Object.keys(fields).sort()).toEqual(USAGE_LOG_KEYS);
    if (
      typeof fields.operation !== 'string' ||
      (fields.outcome !== 'ok' && fields.outcome !== 'error') ||
      typeof fields.query_count !== 'number' ||
      typeof fields.rows_read !== 'number' ||
      typeof fields.rows_written !== 'number'
    ) {
      continue;
    }
    logs.push({
      event: fields.event,
      operation: fields.operation,
      outcome: fields.outcome,
      query_count: fields.query_count,
      rows_read: fields.rows_read,
      rows_written: fields.rows_written,
    });
  }
  return logs;
}

async function expectOneUsageLog(
  operation: string,
  task: () => Promise<void>,
  expectedOutcome: UsageLog['outcome'] = 'ok',
): Promise<UsageLog> {
  const spy = vi.spyOn(console, 'log').mockImplementation(() => undefined);
  await task();
  const logs = usageLogs(spy).filter((log) => log.operation === operation);
  expect(logs).toHaveLength(1);
  const log = logs[0]!;
  expect(log).toMatchObject({ event: 'd1_usage', operation, outcome: expectedOutcome });
  expect(log.query_count).toBeGreaterThan(0);
  expect(log.rows_read).toBeGreaterThanOrEqual(0);
  expect(log.rows_written).toBeGreaterThanOrEqual(0);
  return log;
}

function failingDbOn(fragment: string): D1Database {
  return new Proxy(env.DB, {
    get(target, property) {
      if (property === 'prepare') {
        return (query: string) => {
          if (query.includes(fragment)) throw new Error('forced D1 failure');
          return target.prepare(query);
        };
      }
      const value = Reflect.get(target, property, target);
      return typeof value === 'function' ? value.bind(target) : value;
    },
  });
}

function fakeD1Result(
  results: Record<string, unknown>[],
  rowsRead: number,
  rowsWritten: number,
): D1Result<Record<string, unknown>> {
  return {
    success: true,
    results,
    meta: {
      duration: 0,
      size_after: 0,
      rows_read: rowsRead,
      rows_written: rowsWritten,
      last_row_id: 0,
      changed_db: rowsWritten > 0,
      changes: rowsWritten,
    },
  };
}

describe('D1 usage observability', () => {
  it('sums exact first, run, and multi-statement batch metadata', async () => {
    const statementQueries = new WeakMap<D1PreparedStatement, string>();
    const statement = (query: string): D1PreparedStatement => {
      const proxy = new Proxy(env.DB.prepare('SELECT 1'), {
        get(target, property) {
          if (property === 'bind') return (..._values: unknown[]) => statement(query);
          if (property === 'all') {
            return async () => fakeD1Result([{ value: 'first' }], 2, 0);
          }
          if (property === 'run') return async () => fakeD1Result([], 3, 4);
          const value = Reflect.get(target, property, target);
          return typeof value === 'function' ? value.bind(target) : value;
        },
      });
      statementQueries.set(proxy, query);
      return proxy;
    };
    const db = new Proxy(env.DB, {
      get(target, property) {
        if (property === 'prepare') return (query: string) => statement(query);
        if (property === 'batch') {
          return async (statements: D1PreparedStatement[]) =>
            statements.map((item) => {
              const query = statementQueries.get(item);
              return query === 'batch-one'
                ? fakeD1Result([], 5, 6)
                : fakeD1Result([], 7, 8);
            });
        }
        const value = Reflect.get(target, property, target);
        return typeof value === 'function' ? value.bind(target) : value;
      },
    });
    const observer = createD1UsageObserver(db);

    expect(await observer.db.prepare('first').first('value')).toBe('first');
    await observer.db.prepare('run').run();
    await observer.db.batch([
      observer.db.prepare('batch-one'),
      observer.db.prepare('batch-two'),
    ]);

    expect(observer.usage).toEqual({
      query_count: 4,
      rows_read: 17,
      rows_written: 18,
    });
  });

  it('logs one aggregated line for GET /api/state', async () => {
    const jwt = await devJwt();
    await env.DB.prepare('UPDATE users SET timezone = NULL').run();
    const log = await expectOneUsageLog('GET /api/state', async () => {
      const response = await SELF.fetch(`${BASE}/api/state`, {
        headers: {
          Authorization: `Bearer ${jwt}`,
          'X-Device-TZ': 'America/Los_Angeles',
        },
      });
      expect(response.status).toBe(200);
    });
    expect(log.rows_read).toBeGreaterThan(0);
    // /api/state itself is read-only. This write is the auth middleware's
    // timezone refresh, proving the request total includes middleware D1.
    expect(log.rows_written).toBeGreaterThan(0);
  });

  it('logs one aggregated line for GET /api/me, including former first() reads', async () => {
    const jwt = await devJwt();
    const log = await expectOneUsageLog('GET /api/me', async () => {
      const response = await SELF.fetch(`${BASE}/api/me`, {
        headers: { Authorization: `Bearer ${jwt}` },
      });
      expect(response.status).toBe(200);
    });
    // Five profile reads plus at least the live-principal auth read.
    expect(log.query_count).toBeGreaterThanOrEqual(6);
    expect(log.rows_read).toBeGreaterThan(0);
    expect(log.rows_written).toBe(0);
  });

  it('marks a handled GET /api/me 500 as an error without changing the response', async () => {
    const jwt = await devJwt();
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => undefined);
    await expectOneUsageLog(
      'GET /api/me',
      async () => {
        const context = createExecutionContext();
        const response = await worker.fetch!(
          new Request(`${BASE}/api/me`, {
            headers: { Authorization: `Bearer ${jwt}` },
          }),
          { ...env, DB: failingDbOn('SELECT display_name, email') },
          context,
        );
        expect(response.status).toBe(500);
        expect(await response.json()).toEqual({
          error: 'internal',
          message: 'forced D1 failure',
        });
        expect(errorSpy).toHaveBeenCalledOnce();
      },
      'error',
    );
  });

  it('logs one aggregated line for the MCP get_history tool', async () => {
    await devJwt();
    const log = await expectOneUsageLog('MCP get_history', async () => {
      const response = await SELF.fetch(`${BASE}/mcp`, {
        method: 'POST',
        headers: {
          Authorization: 'Bearer test-mcp-token',
          'content-type': 'application/json',
        },
        body: JSON.stringify({
          jsonrpc: '2.0',
          id: 1,
          method: 'tools/call',
          params: { name: 'get_history', arguments: { exercise: 'bench' } },
        }),
      });
      expect(response.status).toBe(200);
    });
    // Includes static-bearer owner/deletion checks plus resolution/history.
    expect(log.query_count).toBeGreaterThanOrEqual(6);
    expect(log.rows_read).toBeGreaterThan(0);
    expect(log.rows_written).toBe(0);
  });

  it('marks an MCP get_history tool isError result as an error without changing it', async () => {
    await devJwt();
    await expectOneUsageLog(
      'MCP get_history',
      async () => {
        const context = createExecutionContext();
        const response = await worker.fetch!(
          new Request(`${BASE}/mcp`, {
            method: 'POST',
            headers: {
              Authorization: 'Bearer test-mcp-token',
              'content-type': 'application/json',
            },
            body: JSON.stringify({
              jsonrpc: '2.0',
              id: 2,
              method: 'tools/call',
              params: { name: 'get_history', arguments: { exercise: 'bench' } },
            }),
          }),
          { ...env, DB: failingDbOn('SELECT * FROM exercises') },
          context,
        );
        const body = await response.json<{
          result: { content: Array<{ text: string }>; isError: boolean };
        }>();
        expect(response.status).toBe(200);
        expect(body.result.isError).toBe(true);
        expect(body.result.content[0]?.text).toContain('forced D1 failure');
      },
      'error',
    );
  });

  it('logs one aggregated line for each cron tick', async () => {
    await devJwt();
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => new Response(JSON.stringify([]), { status: 200 })),
    );
    const log = await expectOneUsageLog('cron tick', async () => {
      const context = createExecutionContext();
      await worker.scheduled!(
        createScheduledController({ scheduledTime: new Date(), cron: '0 */6 * * *' }),
        env,
        context,
      );
      await waitOnExecutionContext(context);
    });
    expect(log.rows_read).toBeGreaterThan(0);
  });

  it('marks a partial cron sync failure as an error while completing the tick', async () => {
    await devJwt();
    const fetchSpy = vi.fn(async (input: unknown) => {
      const url = String(input);
      return url.includes('/events?')
        ? new Response('boom', { status: 500 })
        : new Response(JSON.stringify([]), { status: 200 });
    });
    vi.stubGlobal('fetch', fetchSpy);

    await expectOneUsageLog(
      'cron tick',
      async () => {
        const context = createExecutionContext();
        await worker.scheduled!(
          createScheduledController({ scheduledTime: new Date(), cron: '0 */6 * * *' }),
          env,
          context,
        );
        await expect(waitOnExecutionContext(context)).resolves.toBeUndefined();
      },
      'error',
    );
    expect(fetchSpy).toHaveBeenCalledTimes(2);
  });
});
