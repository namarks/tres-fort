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

const BASE = 'https://tres-fort.test';

interface UsageLog {
  event: 'd1_usage';
  operation: string;
  outcome: 'ok' | 'error';
  query_count: number;
  rows_read: number;
  rows_written: number;
}

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
    if (
      fields.event !== 'd1_usage' ||
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
): Promise<UsageLog> {
  const spy = vi.spyOn(console, 'log').mockImplementation(() => undefined);
  await task();
  const logs = usageLogs(spy).filter((log) => log.operation === operation);
  expect(logs).toHaveLength(1);
  const log = logs[0]!;
  expect(log).toMatchObject({ event: 'd1_usage', operation, outcome: 'ok' });
  expect(log.query_count).toBeGreaterThan(0);
  expect(log.rows_read).toBeGreaterThanOrEqual(0);
  expect(log.rows_written).toBeGreaterThanOrEqual(0);
  return log;
}

describe('D1 usage observability', () => {
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
});
