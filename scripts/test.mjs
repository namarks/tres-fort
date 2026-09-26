#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const vitest = path.join(root, 'node_modules/vitest/vitest.mjs');

export function backendRuns(args) {
  const shards = args.filter(arg => arg === '--shard' || arg.startsWith('--shard='));
  if (shards.length > 1) throw new Error('Specify --shard only once.');
  if (shards.length) {
    const flag = shards[0];
    const value = flag === '--shard' ? args[args.indexOf(flag) + 1] : flag.slice(8);
    const match = /^(\d+)\/(\d+)$/.exec(value ?? '');
    if (!match || Number(match[1]) < 1 || Number(match[1]) > Number(match[2])) {
      throw new Error('Use --shard=N/M with 1 <= N <= M.');
    }
    return [args];
  }
  if (args.some(arg => /\.test\.ts$/.test(arg) || arg === '-t' || arg.startsWith('--testNamePattern'))) {
    return [args];
  }
  return [1, 2, 3].map(shard => [...args, `--shard=${shard}/3`]);
}

export function runTests(args, { run = spawnSync, exists = existsSync } = {}) {
  const runs = backendRuns(args);
  if (!exists(vitest)) throw new Error('Project dependencies are missing. Run npm ci first.');
  // Fail before website/shell suites if the query-plan prerequisite is absent.
  for (const [binary, command] of [['sqlite3', ['--version']], ['bash', ['--version']]]) {
    const result = run(binary, command, { cwd: root, encoding: 'utf8', stdio: 'pipe' });
    if (result.error || result.status !== 0) {
      throw new Error(`${binary} is required by npm test. Install it and make it available on PATH.`);
    }
  }
  const commands = [
    [process.execPath, ['--test', 'test/test-command.test.mjs']],
    ['npm', ['run', 'test:website']],
    ['npm', ['run', 'test:upload-testflight']],
    ['npm', ['run', 'test:query-plans']],
    ...runs.map(args => [process.execPath, [vitest, 'run', ...args]]),
  ];
  for (const [binary, args] of commands) {
    const result = run(binary, args, { cwd: root, stdio: 'inherit' });
    if (result.error) throw result.error;
    if (result.status !== 0) {
      return result.status ?? 1; // A signal is a failure, never a green suite.
    }
  }
  return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { process.exitCode = runTests(process.argv.slice(2)); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
