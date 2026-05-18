import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { defineWorkersConfig, readD1Migrations } from '@cloudflare/vitest-pool-workers/config';

const here = path.dirname(fileURLToPath(import.meta.url));

export default defineWorkersConfig(async () => {
  const migrations = await readD1Migrations(path.join(here, 'migrations'));
  return {
    test: {
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
              APPLE_BUNDLE_ID: 'com.example.liftcoach',
            },
          },
        },
      },
    },
  };
});
