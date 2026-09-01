declare module 'cloudflare:test' {
  interface ProvidedEnv {
    DB: D1Database;
    TEST_MIGRATIONS: D1Migration[];
    APP_JWT_SECRET: string;
    MCP_STATIC_TOKEN: string;
    DEV_AUTH_SECRET: string;
    OWNER_AUTH_PASSPHRASE: string;
    APPLE_BUNDLE_ID: string;
    APPLE_TEAM_ID?: string;
    APPLE_KEY_ID?: string;
    APPLE_PRIVATE_KEY?: string;
    OWNER_APPLE_SUB?: string;
    /** intervals.icu key — wired in vitest.config.ts so tests are not dormant. */
    INTERVALS_ICU_API_KEY?: string;
    /** intervals.icu athlete id — paired with INTERVALS_ICU_API_KEY in tests. */
    INTERVALS_ICU_ATHLETE_ID?: string;
  }
}
