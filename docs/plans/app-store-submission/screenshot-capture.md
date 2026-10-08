# App Store screenshot capture

This workflow prepares draft assets through the real app screens with fictional
training data. It does not publish images or use an App Store account. Submission
readiness and publication authority remain in [plan.md](plan.md).

From the checkout whose UI should be captured, with the supported Xcode, XcodeGen and the
iOS 26.2 simulator runtime installed:

```sh
bash scripts/capture-app-store-screenshots.sh .artifacts/app-store-iphone iphone
bash scripts/capture-app-store-screenshots.sh .artifacts/app-store-ipad ipad
```

Choose new output directories; the command refuses to overwrite an existing
set. It selects `project-app-store.yml` (`APP_STORE_BUILD=1`), creates its own
iPhone 17 Pro or 13-inch iPad Pro (M4) simulator and unsigned build, and runs the
real-screen asset journeys plus saved-partner-setup recovery. The iPad run also
opens manual Station in landscape. The workflow exports the named screenshots
and removes its temporary build and simulator. It retains failed-test evidence
if verification fails.

Both sets contain Today, the workout runner, reusable workouts, History and
editable feedback. The iPad set adds manual Station setup. All images must be
opaque RGB PNGs: iPhone portraits are 1206 × 2622; iPad portraits are
2064 × 2752 and the Station landscape is 2752 × 2064. These are native accepted
resolutions, not resized screenshots. The default device selector is `iphone`.

The manifest records public project selection, device family, per-image
dimensions and hashes, source commit/tree, checkout changes, locale,
device/runtime and capture time. `sources.json` hashes every tested iOS input,
and `capture-tests.log` retains successful UI-test evidence. Build and capture
share the same source selection. Added, removed or modified iOS inputs, or a
changed checkout identity, fail capture. Source symbolic links are rejected.
PNG validation checks the required header/end structure, chunk checksums,
compressed pixel stream, row filters and absence of transparency; these checks
remain active under optimized Python.

The `app-store` launch fixture is compiled only for Debug simulator builds.
Its ephemeral URL session intercepts requests, its token store does not read
Keychain, and its defaults use a dedicated synthetic namespace. The sample
workouts and history represent no person. This asset fixture omits the QA banner;
the other test fixtures retain their labels. No production account, integration,
invite code or personal training record is required.

Before publication, capture from the selected final candidate source and inspect
every image for system alerts, clipped controls, accidental personal data and
claims inconsistent with the release. Simulator capture demonstrates the visible
UI; it does not establish physical-device behavior, actual speech recognition or
App Review approval. Keep the images as drafts until that candidate comparison
and the separately authorized metadata publication are complete.

Specification checked 2026-10-08:
[Apple screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/).
