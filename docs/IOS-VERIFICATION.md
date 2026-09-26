# iOS verification

Run from the repository root with Xcode 26.3, XcodeGen 2.45.3, Python 3,
and the iOS 26.2 simulator runtime installed:

```bash
npm run ios:verify -- --runtime com.apple.CoreSimulator.SimRuntime.iOS-26-2 --device com.apple.CoreSimulator.SimDeviceType.iPhone-17
```

The command copies iOS sources to a disposable directory, generates the project
there, creates a new simulator, and runs unsigned `xcodebuild build-for-testing`
followed by `xcodebuild test-without-building` using the
**TresFort** scheme. It includes the widget build, existing unit tests, shared
numerical/calendar contracts, and all UI journeys. Simulator boot overlaps the
build; boot readiness is required before tests start. Both actions use the same
copied sources, project, destination, and disposable DerivedData. It neither
needs nor uses signing credentials. It does not migrate D1, deploy a Worker, or upload an
app. Existing simulator data, generated projects, and build directories are not
reused. Parallel test cloning is disabled so the command owns every simulator
it creates. Its exit status fails if building/testing or simulator deletion fails.

Select an installed runtime/device explicitly; list choices with
`xcrun simctl list runtimes` and `xcrun simctl list devicetypes`. Missing choices
fail before creating a device. Runtime installation and upgrading Xcode are
separate machine setup actions. On macOS, the simulator service must be accessible;
a sandbox that denies CoreSimulator or its caches cannot run this command.

For a focused check, append `--only-testing TresFortTests/CalendarProjectionTests`
or `--only-testing TresFortUITests/TrainingJourneyTests`. A focused result does
not substitute for the required CI unit and smoke coverage before merging an
iOS change.

CI uses `--ui-suite smoke` for ordinary iOS changes on pull requests and pushes to main.
Changes to the workflow, verifier, scope selector, or their contract tests select
`full` on the PR and push, so changes to nightly coverage prove the full job budget
before merging.
The smoke suite includes every `TresFortTests` unit test and twelve UI journeys:
sign-in through starter setup and first workout, provider setup, mobile AI
approval/disconnect access, Today navigation, manual workout creation,
logging/finishing, exact keyboard load entry, exercise swap, plan history/restore,
saved feedback, Intervals connection, and group report/block controls.
Each selector names one method. Keep this a small representative gate: new
regressions normally join the full suite, with focused verification on the PR
that changes their behavior. Replacing a smoke journey is an explicit coverage
decision. Script checks enforce twelve valid, unique methods and all unit tests.

Full UI runs are periodic, rather than required on every merge. The nightly
GitHub Actions schedule runs at 11:17 UTC on main (early morning Pacific time).
Use the CI workflow's **Run workflow** action for an additional full run. Both
select `--ui-suite full`, including history measurements, accessibility audits,
and the broader UI journeys. Schedules run only after the workflow lands on
main and may be delayed by GitHub; inspect the Actions result for actual evidence.

Smoke uses two standard runners with six UI journeys each; shard 1 also runs
all unit tests. Full runs use six standard runners, partitioned using the hosted
runner timings (including cold build time):

| Shard | Coverage |
| --- | --- |
| 1 | All unit tests and remaining UI classes |
| 2 | Training and workout feedback |
| 3 | Today navigation, Intervals connection and exercise discovery |
| 4 | Member activation and freestyle workouts |
| 5 | UI actions, history, exercise groups and exercise information |
| 6 | Workout library, weekly schedule and runner controls |

The partitions are disjoint and cover every suite; newly added classes remain
in shard 1 automatically. The partition contract rejects missing or overlapping
selectors. Monitor full-run duration as journeys grow and rebalance before a
shard approaches the 30-minute limit. The September 24 baseline had 124 UI
methods: two of the previous three partitions still had unrun tests at timeout.
Both modes retain the 30-minute job limit and existing assertions/element waits.
Sharding or smoke mode cannot be combined with `--only-testing`. Without these
arguments the command still runs the full suite locally.

CI prioritizes the current iPhone 17 layout and normal text sizes. The optional
`--content-size` argument can set a simulator system preference for a focused
investigation; it is not a required older-device or extreme-text matrix.
It applies only to the newly created simulator and records `ui-settings.log`.
A rejected setting fails the command and still cleans up.

## Evidence and cleanup

Build copies, DerivedData, and the created simulator are deleted on success,
failure, and interrupt. Failure retains `build.log`, `boot.log`, `xcodebuild.log`,
environment/toolchain identity, copied-source SHA-256 manifest, runtime inventories, cleanup diagnostics,
and any available `Build.xcresult` / `Tests.xcresult` under
`.artifacts/ios/<unique-run>/`. Set `IOS_KEEP_RESULTS=1` to retain successful results
and their synthetic screenshot attachments too. With that setting, logs and
results are written directly into the evidence directory while the run is active,
so a forced cancellation need not finish the cleanup trap to retain diagnostics.
An uncatchable process kill cannot guarantee local simulator/scratch cleanup;
CI's disposable runner owns that final cleanup. `IOS_EVIDENCE_DIR` may select a
different durable output directory. On a test failure, assertion lines are also
printed before the log tail, so an accessibility hierarchy dump cannot hide the
error in Actions. These artifacts are ignored by Git. The log records the Git
revision and local overlay; tests run on the copied working
files, including any uncommitted changes.

Open a result bundle in Xcode or export its UI attachments:

```bash
xcrun xcresulttool export attachments --path .artifacts/ios/<run>/Tests.xcresult --test-id TrainingJourneyTests --output-path .artifacts/ios/<run>/screenshots
```

Delete retained local evidence when it is no longer needed. An uncatchable kill
or host crash can leave the named `TresFort verification` simulator and
`tres-fort-ios.*` scratch directory; remove only those belonging to that run.

## Synthetic UI fixtures

The Debug simulator build accepts `TRESFORT_UI_FIXTURE` through its launch
environment. Available cases are `sign-in`, `empty`, `load-failure`, `ordinary`,
`bodyweight`, `timed`, `pending`, `correction-failure`, `ready-to-finish`, and
`onboarding`. Add `TRESFORT_UI_LARGE_TEXT=1` for the largest accessibility text
size; otherwise fixture launches inherit the simulator system setting (normally
`.large`). The synthetic banner stays at its
ordinary size so it does not take space from the product under test. This
root-view override alone does not prove presented-sheet scaling; use the
optional system setting for a specific investigation when needed.
An unknown value aborts before real authentication is constructed. Fixture code
is excluded from Release builds and physical-device builds.

Each launch uses a reset synthetic defaults namespace and a token store that
never reads or writes Keychain. Training dates are fixed at September 8, 2026.
The fixture mounts the real Today, routine editor, runner, correction, and
completion views over the real SyncModel. It avoids MainTabView's HealthKit,
group, credential-renewal, and connectivity lifecycle. APIClient switches to
`ui-fixture.invalid` and an ephemeral URLSession whose protocol answers only
bounded in-memory routes. Unknown routes fail; nothing forwards to the network.
No real user's health data is loaded or persisted. Use a disposable simulator
for walkthroughs too; the verification command already provides this isolation.

The sign-in fixture substitutes only the provider button to record a synthetic
intent; even a manual tap cannot launch AuthenticationServices. The behavioral
smoke exercises that intent, creates a
routine and first workout, logs a set and acknowledges completion, retains an
offline write, and checks that a rejected correction preserves its original
values. It also distinguishes verified empty state from initial-load failure.
Representative screenshots are XCTest attachments, not fragile pixel baselines.
The fixture server is a transport stub, not proof of backend validation or an
Apple authorization exchange. Unit/integration tests verify those separate
contracts. Native Apple authorization and its provider UI remain a separate walkthrough.

The onboarding fixture exercises all optional steps and the safe non-owner
fallback when `/api/me` is unavailable. Open-URL actions are discarded in every
fixture; provider connection routes fail closed. UI tests additionally cover
onboarding, exact decimal entry with the keyboard, rest completion,
correction recovery, and reachability of the remaining fixtures. XCTest audits
check hit regions and descriptions in the visible
entry/runner viewports. Resolved palette colors have deterministic AA contrast
checks. The native iOS 26.2 contrast heuristic produced false positives over the
dark gradient; [measured evidence](plans/completed/app-quality-and-maintainability/evidence/p1/README.md#contrast-verification)
records its limits and why it is not a CI assertion. These audits do not exercise VoiceOver focus or speech.

`ios/TresFortTests/Fixtures/CalendarProjection.json` supplies the same civil-date,
DST, leap-day, real-session, dangling schedule, and blackout expectations to
Swift and TypeScript. `BodyweightProgress.json` continues sharing numerical
expectations for reps, timed holds, assistance, unilateral, and loaded metrics.

## CI and merge evidence

CI retains the `plan graph`, `iOS build + tests`, and `typecheck + tests` check
names. The latter two aggregate every required shard and fail for failed,
cancelled, or unexpectedly skipped jobs. Both matrices use `fail-fast: false` so a
failure in one shard does not cancel coverage in another. The iOS jobs
use the public repository's standard `macos-15` runner, Xcode 26.3, iOS 26.2,
and checksum-pinned XcodeGen 2.45.3. They do not use paid large runners. The jobs
are disabled for a private repository; enabling private capacity requires an
explicit capacity decision. Toolchain changes should update this document and
the workflow together. A missing pinned toolchain must fail, not silently select
another runtime. The source image can evolve, so the environment log records
what actually ran.

Changes confined to backend source, migrations, backend TypeScript tests, or
documentation skip iOS jobs. Shared fixtures under `ios/`, verification scripts,
workflow files, package configuration, and unknown paths trigger smoke coverage.
`scripts/ci-ios-scope.py` compares the tested PR merge with its base or the entire
push range, including deletions and both sides of renames. A missing Git base or
failed scope job fails the aggregate; only an explicit `skip` decision permits
skipped iOS jobs. Nightly and manual runs always request full coverage regardless
of changed paths. Full runs have separate concurrency groups from push/PR runs.

CI uploads `ios-smoke-1` / `ios-smoke-2` or `ios-full-1` through `ios-full-3` results with a
seven-day artifact retention. No production credentials or account data are
supplied to these jobs. Dependency installation
and GitHub action permissions follow the existing repository workflow.

Backend CI runs three Vitest file shards with `npm test -- --shard=N/3`.
Every shard also runs typechecking, verification-command regressions, upload
script checks, and query-plan checks. `singleWorker: true` and
`isolatedStorage: true` remain in force within each shard: suite seeds and
per-test rollback retain the same semantics. Plain `npm test` still runs all
backend tests locally. CI sharding increases concurrent standard runner use
and duplicates iOS compilation; it reduces elapsed wait rather than total
build work. Existing test assertions, timeouts, and production behavior are
unchanged; broader UI regression detection moves to the periodic full runs.

As verified September 8, 2026, GitHub branch protection requires only
`typecheck + tests`. This change does not modify branch protection. For work
changing iOS, the smoke shards, aggregate checks, plan graph, and current-head
independent review must pass before merge; backend green alone is insufficient.
Full UI coverage is a periodic check under the September 9 owner decision.
Making the additional check
names enforced repository settings requires separate repository authority.

A compile, screenshot, or automated smoke test does not establish VoiceOver
usability, physical-device keyboard reachability, audio/lock-screen cues, or
interruption behavior. P1 records simulator evidence separately from the
optional physical-device observations. Per the September 8 owner steering,
those observations are not a delivery gate.

## History measurements

`HistoryPerformanceTests` records five raw samples per component for 12-session
and five-year synthetic histories; `HistoryJourneyTests` exercises two cached
process launches per dataset, calendar scrolling and exercise detail. Both use
the current iPhone at normal text sizes. `history-small` and `history-large` are
simulator-only fixtures; their transport rejects every request. A seed launch
resets the synthetic namespace; `TRESFORT_UI_REUSE_HISTORY=1` retains that seed
for measured cached launches only. Tests explicitly select the seeding mode
for each dataset and assert the row count before and after relaunch.

The [measurement record](plans/completed/app-quality-and-maintainability/evidence/p2/README.md)
separates main-actor component costs from XCTest/animation wall times, and records
first reads, cache reuse, snapshot size, investigation budgets and limitations.
Performance times are reported rather than asserted on shared CI hardware;
behavioral correctness remains required.
