# Release 1.0 (48)

## Source and authority

On October 5 the owner requested the latest iPhone and iPad apps in TestFlight.
This is an internal beta only. No Worker deployment, migration, external beta,
App Review change or public release was requested or performed.

The source is main `7d2714c2823fec50314cdb05ed5095c914e260e7`, merged in
[PR #237](https://github.com/namarks/tres-fort/pull/237). Its
[CI run](https://github.com/namarks/tres-fort/actions/runs/37261841748) passed
plan graph, typecheck + tests and iOS build + tests. That merge changed only
plan documents, so the iOS shards were skipped by scope selection; the iOS
source is identical to `3ba231d` from
[PR #235](https://github.com/namarks/tres-fort/pull/235). Since build 47 the
client adds the Station camera comparison and corrections (#228, #234), the
calendar move (#233), the iPhone/iPad auto-logging link (#232), the
experimental generic rep counter (#236) and catalog camera profiles with hold
timers (#235).

## Backend compatibility

The serving Worker is still source `e3251de9bf8ff6f2e447068b69fe4154c0b468a8`
from [release 47](release-47.md). The only backend change on main since then is
the station link-key route (`GET /api/me/station-link-key`) from #232; there are
no new migrations. Every other client path matches the serving Worker. The
iPhone/iPad link needs that route, so it cannot work until a separately
authorized Worker deployment; the
[Station plan](../ipad-workout-station/plan.md) owns that trial gate.

## iOS package and Apple availability

A fresh App Store Connect build list showed 47 as the highest build, so this
upload used 48 through `BUILD_NUMBER=48 ./scripts/upload-testflight.sh` from a
clean worktree; `ios/project.yml` was not modified. Build 48 was previously
used only for the local development installation of `e15d53b` recorded in the
Station plan; that build never reached App Store Connect.

Xcode 27.0 (27A266a) with the iPhoneOS 27.0 SDK archived and exported the source
as **1.0 (48)**, device family iPhone and iPad, minimum iOS 17.0. Signing used
the existing Xcode account and App Manager key `VP9G3R7Q85`; no credential or
provisioning change was made. The 26,096,022-byte IPA has SHA-256
`86923b80716fdefa8a774a527dcfb9332952bdffb8e6b6fa0d618047be02263d`.

Upload reported **UPLOAD SUCCEEDED with no errors**, delivery UUID and App
Store Connect build ID `670f268c-00dc-4e78-ad8c-72125eff5620`, uploaded
`2026-10-05T04:16:54Z`. At `2026-10-05T04:18:06Z` Apple reported the build
**VALID** and **IN_BETA_TESTING**. The internal **Testers** group
(`5df996bf-8c8b-471e-b79e-f626a4f98211`) has access to all builds and lists
build 48; no group mutation was needed. The key cannot read a build's group
relationship (HTTP 403), so membership was read from the group's build list.
External state is Apple's default READY_FOR_BETA_SUBMISSION; nothing was
submitted. Version 1.0 still selects rejected build 40 with MANUAL release.

## Verification boundary

Authenticated live workout checks, physical-device acceptance and the paired
iPhone/iPad trial remain unperformed. This upload does not replace the App
Review candidate, authorize public release or waive any open requirement. The
temporary worktree and build outputs were removed after verification; Apple
retains the distributed build.
