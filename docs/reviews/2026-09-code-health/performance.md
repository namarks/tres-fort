# Code health: performance and compatibility evidence

Compared on 2026-09-14: original main `3f4c927`, reviewed PR head `0bede39`,
and the follow-up working tree. All fixtures are synthetic; no production
database, provider account or deployment was used.

## Database work

The same `test/code_health.test.ts` fixture was run against all three versions.
The original-main measurement used a detached worktree with the fixture added
and query-budget limits relaxed for measurement; application code was unchanged.
Schema metadata was primed before counting request work. The fixture includes
seven recent sessions, a distinct older completed session, deleted sets,
member-authored multiline text, a recurring lift and a hard planned ride.

| Operation | Original main | Reviewed PR | Follow-up |
|---|---:|---:|---:|
| Ride conflict queries | 11 | 6 | 4 |
| Ride conflict rows read | 11 | 6 | 4 |
| Eight-session coaching brief queries | 29 | 17 | 15 |
| Eight-session coaching brief rows read | 626 | 614 | 612 |
| Rows written by either read | 0 | 0 | 0 |

The final tests cap conflict reads at four queries and the brief at fifteen,
alongside assertions on real results, older completion context, tombstones,
legacy aliases and preserved member text. They run in normal CI. Row counts
depend on fixture size; query counts are not an end-to-end latency claim.

## CPU and serialization

Reproduce from the repository root after `npm ci`:

```sh
node scripts/benchmark-code-health.mjs 3f4c9274b894b5113ee05cdef3ec34407f45b37e
```

This compares original-main implementations with the working tree. It
transpiles the actual source with the existing TypeScript dependency, warms
both implementations and alternates measurement order over seven samples.
Outputs are deeply compared before timing, including unknown exercises,
equal-time sets, timed/assisted work, warm-ups, tombstones and multiline text.
Timing is manual evidence, not a flaky CI threshold.

Observed on Node 24.19.0 in Linux:

| Synthetic CPU workload | Original median | Follow-up median |
|---|---:|---:|
| 311 distinct original SQL strings, repeated 100 times | 209.1 ms | 22.4 ms |
| 1,000 session summaries; 300 catalog entries and 120 input sets each | 337.4 ms | 170.0 ms |

The SQL result supports retaining the bounded rewrite cache. The summary
improvement comes from indexing per invocation instead of repeatedly scanning
the catalog and all sets. Neither benchmark measures production Worker latency,
cold-cache behavior, or iOS frame time.

The synthetic result used for serialization is 30,981 UTF-8 bytes when pretty
printed and 20,402 bytes when compact. Parsed values are identical. Byte savings
are not model-token savings; the embedded Markdown coaching brief remains
pretty printed. Raw-text snapshots and whitespace-sensitive external consumers
need to accept the new formatting.

## Code boundaries and preserved contracts

- `calendarProjection.ts` owns civil-date math, calendar projection and conflict
  rules. It has no database or network imports. `db.ts` owns selection and
  re-exports existing names for compatibility. The shared Swift/TypeScript
  calendar fixtures now import the pure module directly.
- Conflict detection uses the same calendar algorithm with empty endurance
  display feeds. Endurance-only cells never create a strength conflict. Real
  sessions, first-match trips, hard blackouts, skipped/discarded rows and the
  extra next-day boundary retain the existing rules and ordering.
- The full calendar still loads both endurance feeds. Only the conflict reader
  omits those unnecessary reads. There is no cross-request training-data cache.
- `getState` collection reads remain independent. Its interleaved-write
  watermark test and all atomic plan-write paths remain intact.
- Deprecated wire keys, MCP tool names and the schema-rollout adapter remain.
  The exception/error branch is unchanged; compact serialization applies only
  to normal tool results and preserves whitespace inside strings.
- The hourly cron skips caches successfully synced within two hours. The tool
  description and remaining cron comments describe that policy; no cron or
  provider-refresh behavior is changed.

The in-repository synthetic client tests cover protocol compatibility. Live
Codex/Claude rendering and model behavior require a release smoke check. Further
splits of plan writers or iOS recovery are independent work; this change does
not claim to remove all complexity from either large module.

## Validation

The follow-up passed `npm run typecheck`, `npm run test:query-plans`,
`npm run plans:check` and all three backend Vitest shards: 80 files and 1,108
tests (323 / 419 / 366). Existing calendar parity, blackout/boundary,
coaching-client, schema compatibility, atomic-write and interleaved-write
watermark regressions are included. The benchmark above passed its output
comparisons. Website and TestFlight-upload script tests also passed.

The local all-in-one test wrapper initially stopped because the SQLite CLI was
absent. The query-plan check then passed with a user-local SQLite 3.46.1 build;
no harness checks were disabled. Backend shards were run separately to avoid
the existing Workers-pool teardown issue documented in the handoff. iOS build
and smoke tests require macOS and must pass on the final PR commit in CI.
