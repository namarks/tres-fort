import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { defineWorkersConfig, readD1Migrations } from '@cloudflare/vitest-pool-workers/config';

const here = path.dirname(fileURLToPath(import.meta.url));

export default defineWorkersConfig(async () => {
  const migrations = await readD1Migrations(path.join(here, 'migrations'));
  return {
    test: {
      // Only run this repo's own tests. Without an explicit include, vitest's
      // default glob descends into agent worktrees under .claude/worktrees/
      // and runs their stale snapshots.
      include: ['test/**/*.test.ts'],
      poolOptions: {
        workers: {
          singleWorker: true,
          // Already the default; pinned because the suites rely on it: a
          // describe-level beforeAll seed stays visible to every `it` in the
          // block while each `it`'s own writes are rolled back, which is what
          // makes the exact per-case audit/note counts hold.
          isolatedStorage: true,
          wrangler: { configPath: './wrangler.jsonc' },
          miniflare: {
            bindings: {
              TEST_MIGRATIONS: migrations,
              APP_JWT_SECRET: 'test-secret',
              MCP_STATIC_TOKEN: 'test-mcp-token',
              DEV_AUTH_SECRET: 'test-dev',
              OWNER_AUTH_PASSPHRASE: 'test-pass',
              APPLE_BUNDLE_ID: 'com.example.tresfort',
              // intervals.icu cycling-awareness: test values so the feature
              // is "enabled" in tests, but the fetcher is always injected/
              // stubbed — the suite makes ZERO real network calls.
              INTERVALS_ICU_API_KEY: 'test-intervals-key',
              INTERVALS_ICU_ATHLETE_ID: 'i12345',
              // intervals.icu OAuth: test values so the /auth/intervals/start
              // route is "configured" in tests. The /callback token exchange
              // hits the network, so callback tests assert only the offline
              // paths (bad/missing state, error param) — never the live POST.
              INTERVALS_OAUTH_CLIENT_ID: '431',
              INTERVALS_OAUTH_CLIENT_SECRET: 'test-oauth-secret',
              // intervals.icu push webhook (POST /webhooks/intervals): a test
              // value so the receiver is "configured" and secret-matching can
              // be exercised. The triggered syncs no-op gracefully in tests
              // (the reconciled-cache fetch is the injected/dormant path).
              INTERVALS_WEBHOOK_SECRET: 'test-webhook-secret',
            },
          },
        },
      },
    },
  };
});
