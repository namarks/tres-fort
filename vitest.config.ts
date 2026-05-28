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
            },
          },
        },
      },
    },
  };
});
