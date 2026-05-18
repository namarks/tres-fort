declare module 'cloudflare:test' {
  interface ProvidedEnv {
    DB: D1Database;
    TEST_MIGRATIONS: D1Migration[];
    APP_JWT_SECRET: string;
    MCP_STATIC_TOKEN: string;
    DEV_AUTH_SECRET: string;
    APPLE_BUNDLE_ID: string;
    OWNER_APPLE_SUB?: string;
  }
}
