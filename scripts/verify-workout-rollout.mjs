import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readdir, copyFile, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:net';

// Entirely local: no production config, bindings, credentials, or network I/O
// beyond the loopback smoke requests. Never print the synthetic JWT.
const root = resolve(import.meta.dirname, '..');
const scratch = await mkdtemp(join(tmpdir(), 'tres-fort-workout-rollout-'));
const config = join(scratch, 'wrangler.json');
const state = join(scratch, 'state');
const migrations = join(scratch, 'migrations');
const wrangler = join(root, 'node_modules/wrangler/bin/wrangler.js');
const env = { ...process.env, WRANGLER_SEND_METRICS: 'false', CI: 'true' };
for (const key of Object.keys(env)) if (/^(CLOUDFLARE_|CF_)/.test(key)) delete env[key];
let worker;
let workerOutput = '';
function cli(args) {
  const result = spawnSync(process.execPath, [wrangler, ...args, '--config', config],
    { cwd: scratch, env, encoding: 'utf8' });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, `${args[0]} failed:\n${result.stdout}\n${result.stderr}`);
  return result.stdout;
}
try {
  await mkdir(migrations);
  for (const name of await readdir(join(root, 'migrations'))) {
    if (name === '0053_workout_metadata.sql') {
      // Synthetic pre-rename fixture; production applies this only after 0045.
      const sql = await readFile(join(root, 'migrations', name), 'utf8');
      await writeFile(join(migrations, name), sql.replace(/\bworkouts\b/g, 'day_templates').replace(/\bworkout_id\b/g, 'day_template_id'));
    } else if (name.endsWith('.sql') && name !== '0045_workouts.sql') await copyFile(join(root, 'migrations', name), join(migrations, name));
  }
  await writeFile(config, JSON.stringify({ name: 'workout-rollout-local',
    main: join(root, 'src/index.ts'), compatibility_date: '2024-12-30', compatibility_flags: ['nodejs_compat'],
    d1_databases: [{ binding: 'DB', database_name: 'rollout-local', database_id: '00000000-0000-0000-0000-000000000045', migrations_dir: migrations }],
    r2_buckets: [{ binding: 'DEMOS', bucket_name: 'rollout-local' }],
    vars: { DEV_AUTH_SECRET: 'synthetic-local-only', APP_JWT_SECRET: 'synthetic-local-only', MCP_STATIC_TOKEN: 'synthetic-local-only' } }));
  cli(['d1', 'migrations', 'apply', 'rollout-local', '--local', '--persist-to', state]);
  const server = createServer();
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const port = server.address().port;
  await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
  const base = `http://127.0.0.1:${port}`;
  worker = spawn(process.execPath, [wrangler, 'dev', '--local', '--ip', '127.0.0.1', '--port', String(port),
    '--persist-to', state, '--config', config], { cwd: scratch, env, stdio: ['ignore', 'pipe', 'pipe'] });
  worker.stdout.on('data', b => { workerOutput += b; });
  worker.stderr.on('data', b => { workerOutput += b; });
  let ready = false;
  for (let i = 0; i < 120; i++) {
    if (worker.exitCode !== null) throw new Error(`Local Worker exited: ${workerOutput}`);
    try { await fetch(`${base}/privacy`); ready = true; break; } catch { await new Promise(r => setTimeout(r, 250)); }
  }
  assert(ready, `Local Worker did not start: ${workerOutput}`);
  const auth = await fetch(`${base}/auth/dev`, { method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ secret: 'synthetic-local-only' }) });
  assert.equal(auth.status, 200);
  const { jwt } = await auth.json();
  const headers = { Authorization: `Bearer ${jwt}`, 'content-type': 'application/json' };
  async function api(path, method = 'GET', body) {
    const response = await fetch(`${base}/api/${path}`, { method, headers,
      ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
    assert(response.ok, `${path}: ${response.status}`);
    return response.json();
  }
  await api('plan/active', 'PUT', { name: 'Synthetic rollout' });
  const workout = await api('days', 'POST', { name: 'Before rename' });
  const initial = await api('plan/active');
  assert.equal(initial.workouts[0].id, workout.id); assert.deepEqual(initial.workouts, initial.days);
  await copyFile(join(root, 'migrations/0045_workouts.sql'), join(migrations, '0045_workouts.sql'));
  cli(['d1', 'migrations', 'apply', 'rollout-local', '--local', '--persist-to', state]);
  // The same Worker has a cached old schema. Its next write must recover once.
  await api(`workouts/${workout.id}`, 'PATCH', { name: 'After rename', expected_version: initial.version });
  const renamed = await api('plan/active');
  assert.equal(renamed.version, initial.version + 1); assert.equal(renamed.workouts[0].name, 'After rename');
  cli(['d1', 'execute', 'rollout-local', '--local', '--persist-to', state,
    '--file', join(root, 'docs/plans/workouts-and-multi-session/rollback/0045_workouts.sql')]);
  await api(`days/${workout.id}`, 'PATCH', { name: 'After rollback', expected_version: renamed.version });
  const reverted = await api('plan/active');
  assert.equal(reverted.version, renamed.version + 1); assert.equal(reverted.workouts[0].id, workout.id);
  console.log('PASS: local migration → live Worker → rename → same-isolate write → rollback → old-client write');
} finally {
  if (worker && worker.exitCode === null) {
    const stopped = once(worker, 'exit'); worker.kill('SIGTERM');
    const timeout = setTimeout(() => worker.kill('SIGKILL'), 5000);
    await stopped; clearTimeout(timeout);
  }
  await rm(scratch, { recursive: true, force: true });
}
