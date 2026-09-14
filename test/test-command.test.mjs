import assert from 'node:assert/strict';
import { test } from 'node:test';
import { runTests } from '../scripts/test.mjs';

function invoke(args = [], failure = () => false) {
  const calls = [];
  const status = runTests(args, { exists: () => true, run(binary, args) {
    const call = [binary, args];
    calls.push(call);
    return failure(call) ? { status: 7 } : { status: 0 };
  } });
  return { calls, status };
}

test('the default command runs prerequisites once and all supported shards', () => {
  const { calls, status } = invoke();
  assert.equal(status, 0);
  assert.equal(calls.filter(([, args]) => args.includes('test:query-plans')).length, 1);
  assert.deepEqual(calls.filter(([, args]) => args[0].endsWith('vitest.mjs'))
    .map(([, args]) => args.at(-1)), ['--shard=1/3', '--shard=2/3', '--shard=3/3']);
});

test('CI shard selection and focused test arguments are preserved', () => {
  for (const args of [['--shard=2/3'], ['--shard', '3/3'], ['test/calendar.test.ts', '-t', 'blackout']]) {
    const { calls } = invoke(args);
    const runs = calls.filter(([, args]) => args[0].endsWith('vitest.mjs'));
    assert.equal(runs.length, 1);
    assert.deepEqual(runs[0][1].slice(2), args);
  }
});

test('failure in a shard propagates and stops later work', () => {
  const { calls, status } = invoke([], ([, args]) => args.includes('--shard=2/3'));
  assert.equal(status, 7);
  assert.ok(!calls.some(([, args]) => args.includes('--shard=3/3')));
});

test('missing prerequisites and invalid selectors fail before suites run', () => {
  let calls = 0;
  assert.throws(() => runTests([], { exists: () => true, run() {
    calls++; return { error: new Error('ENOENT') };
  } }), /sqlite3 is required/);
  assert.equal(calls, 1);
  for (const args of [['--shard=0/3'], ['--shard=4/3'], ['--shard'], ['--shard=1/3', '--shard=2/3']]) {
    assert.throws(() => invoke(args), /shard/);
  }
});

test('termination by signal cannot report success', () => {
  let calls = 0;
  assert.equal(runTests([], { exists: () => true, run() {
    return ++calls < 3 ? { status: 0 } : { status: null, signal: 'SIGTERM' };
  } }), 1);
});
