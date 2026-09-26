# Release 1.0 (44)

## Source and authority

The owner requested TestFlight distribution on September 19 Pacific and then
explicitly approved production migrations 0053/0054 and the matching Worker.
The owner then explicitly approved deferring authenticated live workout checks
to device testing for this internal beta and changing the App Store release
mode to MANUAL. These are build-44 approvals, separate from the historical
build-35 exception.
The pinned source is `d801e9dbfdb402531ddae6266b9b16e3da46dece`, merged in
[PR #218](https://github.com/namarks/tres-fort/pull/218), with tree
`f6064efeb3c2cc83080597fb7db25742daf7a224`. It includes workout tags/archiving,
freestyle sessions and reviewed save, and the canonical workout contract.

The merged tree equals independently reviewed head
`27edcfd31d8336bb44eb5854fbdd3b9acf895e77`; all eight checks in
[the final source CI run](https://github.com/namarks/tres-fort/actions/runs/35479454392)
passed. Fresh release verification passed all **1,161 backend tests** across
the configured three CI shards, TypeScript, website/upload/query-plan checks,
and the Worker deploy dry-run. An initial unsharded run exhausted the test
pool's accumulating proxy chain late in its single process; all three complete
CI-shaped shards subsequently passed without source or assertion changes.

## Production release

Migrations `0053_workout_metadata.sql` and `0054_freestyle_sessions.sql` applied
in order. Readback confirmed the metadata/session defaults, empty receipt table,
all eight added guard triggers, unchanged workout/slot/session/set counts,
unchanged aggregate plan versions/session attempts, and zero foreign-key
violations. The workout write fence remains enabled with zero permits.
There are no pending migrations at this source. No authenticated training
mutation or disposable workout canary was performed.

Deployment `e22ed5d9-994a-4349-b005-a5f3f6a02004`, created at
`2026-09-20T02:52:14.429471Z`, serves Worker
`dcbcc2ba-09dd-4dfb-9d50-c860cc1553d3` at **100% traffic**. Cloudflare deployment
metadata records the exact source and tree above. Public health returns the
expected service identity; unauthenticated state and MCP POST return 401.
Health itself carries no source SHA, so the provider receipt supplies source
attribution. These checks do not prove authenticated workout behavior.
The five-minute public observation from `2026-09-20T02:53:08.867Z` through
`02:58:09.279Z` passed all 33 health and unauthenticated boundary checks. It
does not replace the unperformed authenticated workout canary.

## iOS package and upload

The exact source archived and exported as **1.0 (44)**. The app and widget both
carry build 44; distribution signatures verify. Apple validation returned
**VERIFY SUCCEEDED with no errors**. The retained IPA's SHA-256 is
`7b3fd63ecab310988d8d03a0cb87d398c75026890d9184255db948ef3d8d8f63`.

Upload at `2026-09-20T03:32:07.564Z` reported **UPLOAD SUCCEEDED with no errors**,
delivery UUID `f78c1016-a8f9-4f7b-be0a-9efd021ea5c2`. The retained package hash
was rechecked immediately before upload. At `2026-09-20T03:35:57.022Z`, Apple
reported build `f78c1016-a8f9-4f7b-be0a-9efd021ea5c2` **VALID** and
**IN_BETA_TESTING**. A complete paginated read confirmed assignment to internal
**Testers** (`5df996bf-8c8b-471e-b79e-f626a4f98211`). External Alpha Testers do
not have this build; its external state is READY_FOR_BETA_SUBMISSION.

A read at `2026-09-20T03:09:03.096Z` reported build 40 IN_REVIEW /
AFTER_APPROVAL. Its pinned client source `9373d6f` defaults to the retired
`/api/days` and `day_template_id` contract, which the canonical Worker rejects.
Build 40 is therefore known to be incompatible with the serving backend.
After explicit owner approval, the release-mode PATCH returned HTTP 200 and
readback at `2026-09-20T03:31:39.517Z` confirmed **MANUAL**, with build 40 still
selected and IN_REVIEW. Automatic publication is prevented. No candidate
replacement, review resubmission, listing or external-beta change was made.
A compatible App Review candidate and public-release authority remain separate
from this internal TestFlight release.

## Verification boundary

The owner explicitly approved finishing this internal beta using the passed
automated and production schema/public checks, deferring the runbooks'
authenticated live workout checks to device testing. Those checks remain
unperformed and are not claimed as passed. Do not reinstate them as a build-44
upload gate. Physical-device and VoiceOver acceptance remain unverified;
the internal-release exception does not close App Review/public-readiness gates.

Value-free release, migration, test, package and Apple receipts, the signed
archive and the validated IPA are retained in the task's local `release-44`
artifact directory. Canonical next actions remain in the linked plans.
