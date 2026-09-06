#!/usr/bin/env node

import { mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const migrationsDir = path.join(repoRoot, 'migrations');
const sqliteBinary = 'sqlite3';

function fail(message) {
  throw new Error(message);
}

function runSqlite(args, input, label) {
  const result = spawnSync(sqliteBinary, args, {
    cwd: repoRoot,
    encoding: 'utf8',
    input,
    maxBuffer: 20 * 1024 * 1024,
  });
  if (result.error?.code === 'ENOENT') {
    fail(
      'sqlite3 is required for data-storage query-plan validation but was not found on PATH',
    );
  }
  if (result.error) {
    fail(`${label} could not start sqlite3: ${result.error.message}`);
  }
  if (result.status !== 0) {
    const detail = (result.stderr || result.stdout || 'no sqlite3 output').trim();
    fail(`${label} failed (sqlite3 exit ${result.status}): ${detail}`);
  }
  return result.stdout.trim();
}

function assertUsesIndex(databasePath, name, sql, expectedIndex) {
  const plan = runSqlite(
    ['-batch', '-noheader', databasePath],
    `.bail on\nEXPLAIN QUERY PLAN ${sql};\n`,
    `query plan ${name}`,
  );
  if (!plan.includes(expectedIndex)) {
    fail(
      `${name} did not use ${expectedIndex}. Query plan:\n${plan || '(empty)'}`,
    );
  }
  console.log(`${name}: ${expectedIndex}`);
}

function main() {
  runSqlite(['--version'], undefined, 'sqlite3 prerequisite check');

  const migrationNames = readdirSync(migrationsDir)
    .filter((name) => /^\d+.*\.sql$/.test(name))
    .sort();
  if (migrationNames.length === 0) {
    fail(`no SQL migrations found in ${migrationsDir}`);
  }
  if (!migrationNames.some((name) => name.startsWith('0036_'))) {
    fail('0036 member-first hot-path migration is missing');
  }

  const scratchDir = mkdtempSync(path.join(tmpdir(), 'tres-fort-query-plans-'));
  const databasePath = path.join(scratchDir, 'query-plans.sqlite');
  try {
    for (const migrationName of migrationNames) {
      const migration = readFileSync(path.join(migrationsDir, migrationName), 'utf8');
      runSqlite(
        ['-batch', databasePath],
        `.bail on\n${migration}\n`,
        `migration ${migrationName}`,
      );
    }

    const expectedIndexes = [
      'ix_sets_user_ex_time',
      'ix_audit_user_actor_created',
      'ix_oauth_tokens_user',
    ];
    const installedIndexes = runSqlite(
      ['-batch', '-noheader', databasePath],
      `SELECT name FROM sqlite_master
        WHERE type = 'index'
          AND name IN (${expectedIndexes.map((name) => `'${name}'`).join(',')})
        ORDER BY name;\n`,
      'installed-index check',
    ).split(/\r?\n/).filter(Boolean);
    if (installedIndexes.length !== expectedIndexes.length) {
      fail(
        `expected indexes are missing: installed ${installedIndexes.join(', ') || '(none)'}`,
      );
    }

    const removedIndex = runSqlite(
      ['-batch', '-noheader', databasePath],
      "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'ix_sets_ex_time';\n",
      'replaced-index check',
    );
    if (removedIndex) {
      fail('replaced index ix_sets_ex_time is still installed');
    }

    const queryPlans = [
      {
        name: 'profile OAuth grant',
        expectedIndex: 'ix_oauth_tokens_user',
        sql: `SELECT 1 AS x FROM oauth_tokens
              WHERE refresh_token IS NOT NULL AND user_id = 'member-a'
              LIMIT 1`,
      },
      {
        name: 'owner profile OAuth grant with legacy fallback',
        expectedIndex: 'ix_oauth_tokens_user',
        sql: `SELECT 1 AS x FROM oauth_tokens
              WHERE refresh_token IS NOT NULL
                AND (user_id = 'member-a' OR user_id IS NULL)
              LIMIT 1`,
      },
      {
        name: 'profile latest MCP action',
        expectedIndex: 'ix_audit_user_actor_created',
        sql: `SELECT MAX(created_at) AS t FROM audit_log
              WHERE user_id = 'member-a' AND actor = 'mcp'`,
      },
      {
        name: 'exercise history',
        expectedIndex: 'ix_sets_user_ex_time',
        sql: `SELECT sl.*, s.date AS session_date FROM set_logs sl
              JOIN sessions s ON s.id = sl.session_id
              WHERE sl.user_id = 'member-a'
                AND s.user_id = 'member-a'
                AND sl.exercise_id = 'ex_bench'
                AND sl.deleted_at IS NULL
                AND sl.is_warmup = 0
                AND sl.logged_at BETWEEN 0 AND 9999999999999
              ORDER BY sl.logged_at`,
      },
      {
        name: 'recent matching set',
        expectedIndex: 'ix_sets_user_ex_time',
        sql: `SELECT sl.* FROM set_logs sl
              JOIN sessions s ON s.id = sl.session_id
              WHERE sl.user_id = 'member-a'
                AND s.user_id = 'member-a'
                AND sl.exercise_id = 'ex_bench'
                AND sl.weight = 135
                AND sl.reps = 5
                AND sl.is_warmup = 0
                AND sl.source <> 'mcp'
                AND sl.deleted_at IS NULL
                AND sl.logged_at >= 0
                AND (NULL IS NULL OR sl.set_index = NULL)
                AND (NULL IS NULL OR sl.duration_s = NULL)
              ORDER BY sl.logged_at DESC LIMIT 1`,
      },
    ];
    for (const query of queryPlans) {
      assertUsesIndex(databasePath, query.name, query.sql, query.expectedIndex);
    }
  } finally {
    rmSync(scratchDir, { recursive: true, force: true });
  }
}

try {
  main();
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  console.error(`data-storage query-plan validation failed: ${message}`);
  process.exitCode = 1;
}
