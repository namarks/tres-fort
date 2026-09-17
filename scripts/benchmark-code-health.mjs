// Synthetic CPU/serialization evidence. No D1, network, credentials or user data.
// Baseline must precede the canonical cutover and contain workoutWire.ts.
// Usage: node scripts/benchmark-code-health.mjs <baseline-git-ref>
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { performance } from 'node:perf_hooks';
import { fileURLToPath } from 'node:url';
import ts from 'typescript';

const baselineRef = process.argv[2];
if (!baselineRef || process.argv.length !== 3) {
  console.error('Usage: node scripts/benchmark-code-health.mjs <baseline-git-ref>');
  process.exit(1);
}
const root = fileURLToPath(new URL('../', import.meta.url));
const source = (path, ref) => ref
  ? execFileSync('git', ['show', `${ref}:${path}`], { cwd: root, encoding: 'utf8' })
  : readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
function moduleURL(text) {
  const code = ts.transpileModule(text, { compilerOptions: {
    target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext,
  } }).outputText;
  return 'data:text/javascript;base64,' + Buffer.from(code).toString('base64');
}
async function load(ref) {
  const metrics = moduleURL(source('src/metrics.ts', ref));
  const context = source('src/coachingContext.ts', ref).replace("'./metrics'", JSON.stringify(metrics));
  return {
    context: await import(moduleURL(context)),
    wire: ref ? await import(moduleURL(source('src/workoutWire.ts', ref))) : null,
  };
}
const baseline = await load(baselineRef);
const candidate = await load();

const session = { id: 'synthetic-session', date: '2026-09-14', status: 'completed',
  notes: 'Member words: "keep this"\n  indented line — très fort', perceived_fatigue: 4 };
const catalog = Array.from({ length: 300 }, (_, i) => ({
  id: `exercise-${i}`, name: `Exercise ${i}`, primary_muscle: ['chest', 'back', 'quads'][i % 3],
  modality: ['barbell', 'dumbbell', 'bw', 'timed', 'cardio'][i % 5],
  unit: ['lb', 'kg', 'sec'][i % 3], laterality: i % 2 ? 'unilateral' : 'bilateral',
  load_mode: i % 2 ? 'per_hand' : 'total',
}));
const sets = Array.from({ length: 120 }, (_, i) => ({
  id: `set-${String(i).padStart(3, '0')}`, session_id: i % 19 ? session.id : 'another-session',
  exercise_id: i % 29 ? `exercise-${i % 12}` : 'unknown-exercise',
  logged_at: Math.floor(i / 2), weight: i % 7 ? 100 : -20, reps: 5 + i % 8,
  duration_s: i % 3 ? 30 : null, is_timed: i % 5 ? 0 : 1,
  is_warmup: i % 17 ? 0 : 1, deleted_at: i % 23 ? null : 1, rpe: i % 3 ? 7 : null,
}));
// Whole-object comparison includes cohort/key-set order, unknown exercises,
// ties, timed/assisted work, warm-ups, tombstones, other sessions and free text.
for (const rows of [[], sets.slice(0, 1), sets]) {
  assert.deepEqual(candidate.context.coachingSession(session, rows, catalog),
    baseline.context.coachingSession(session, rows, catalog));
}
const payload = { workouts: [{ id: 'workout', notes: session.notes }],
  session: candidate.context.coachingSession(session, sets, catalog) };
const legacyWire = baseline.wire.workoutWire(payload);
assert.deepEqual(legacyWire.workouts, payload.workouts);
assert.deepEqual(legacyWire.session, payload.session);
const legacyCompact = JSON.stringify(legacyWire);
const canonicalCompact = JSON.stringify(payload);
assert.deepEqual(JSON.parse(canonicalCompact), payload);

function median(values) { return [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)]; }
function measure(before, after, iterations) {
  for (let i = 0; i < 20; i++) { before(); after(); }
  const samples = { baseline: [], candidate: [] };
  for (let sample = 0; sample < 7; sample++) {
    const order = sample % 2 ? [['candidate', after], ['baseline', before]]
      : [['baseline', before], ['candidate', after]];
    for (const [label, task] of order) {
      const start = performance.now();
      for (let i = 0; i < iterations; i++) task();
      samples[label].push(performance.now() - start);
    }
  }
  return { iterations, samples: 7, baseline_median_ms: median(samples.baseline),
    candidate_median_ms: median(samples.candidate) };
}
console.log(JSON.stringify({
  baseline: baselineRef, candidate: 'working tree', node: process.version,
  scope: 'Synthetic warm CPU workloads; not end-to-end Worker latency or model token counts.',
  coaching: { catalog_entries: catalog.length, input_sets: sets.length, ...measure(
    () => baseline.context.coachingSession(session, sets, catalog),
    () => candidate.context.coachingSession(session, sets, catalog), 1000) },
  serialization: { legacy_bytes: Buffer.byteLength(legacyCompact), canonical_bytes: Buffer.byteLength(canonicalCompact),
    ...measure(() => JSON.stringify(baseline.wire.workoutWire(payload)), () => JSON.stringify(payload), 1000) },
  compatibility: 'Canonical values deeply equal; deprecated output aliases intentionally removed.',
}, null, 2));
