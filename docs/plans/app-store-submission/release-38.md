# UI fixes — 1.0 (38)

Dated release evidence for September 11, 2026 (Pacific). The owner requested
deployment after the UI fixes merged in PR #183. The scope is internal
TestFlight distribution.

## Source and verification

- Release source: `0ac5d46b5a245c674fbc10727117b264a38db580`.
- [PR #183](https://github.com/namarks/tres-fort/pull/183) passed independent
  review at `7a376a243423fa39c810f9ad4f1eccb3d246a657`, with no unresolved
  findings and all eight CI checks green in
  [run 34611333343](https://github.com/namarks/tres-fort/actions/runs/34611333343).
  Its merged tree exactly matches the reviewed head. CI passed 512 model tests
  and 46 UI journeys; one physical-protection model test remained skipped.
- The candidate includes full-row workout browsing and swipe deletion from
  PR #182, compact Profile account controls, a pinned set action, separate
  workout editing modes, named deletion confirmations, and explicit completion
  choices. Deleting a required set returns review to unresolved exercises;
  completed exercises show completion instead of an ineffective Log action.
- All 579 tracked source hashes remained unchanged through packaging. The
  archive and exported app passed signature verification. App and widget are
  version 1.0, build 38, iPhone-only; the export disallows debugging and includes
  the required-reason privacy manifest without synthetic fixture markers.
- IPA SHA-256:
  `c14a5cd52efe98893e7d07aaa8fa0f14d127154b46d0bbcd2eb61fe7ebb758d0`.

## Upload and delivery

Build 38 was unused in the 18:50:22 UTC preflight read. The upload returned
`UPLOAD SUCCEEDED with no errors` at 18:52:23 UTC, delivery ID
`df66fbcc-61bc-4514-a5e6-1d0882ede365`. The 18:56:48 UTC App Store Connect
read confirmed version 1.0, build 38, VALID processing, IN_BETA_TESTING,
notifications enabled, and membership in the internal Testers group. External
Alpha Testers does not include this build.

Signed package and sanitized provider receipts are retained on the release host
under `~/.codex/visualizations/2026/09/11/01a08ee9-d0bb-7783-ae12-b462bc279faa/testflight-release/`.

## Scope and remaining evidence

Backend, migration, and runtime configuration source match the preceding
[1.0 (37) release](release-37.md); this workflow performed no backend deployment,
migration, website publication, or production training mutation. The owner's
existing live-workout-canary deferral remains explicit. Other physical-device
coverage is unverified. No App Review submission, selected review-build change,
external beta submission, or public App Store release is included.
