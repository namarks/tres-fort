# MediaPipe pose replay dependency

## Shipping variants

The default `project.yml` is the iPhone + iPad TestFlight variant, including
experimental Station inference. The public iPhone + iPad 1.0 candidate uses
`xcodegen generate --spec project-app-store.yml`. That spec replaces the app's
dependency/resource arrays, disables the MediaPipe setup step, removes the
forced graph linker flags, and sets device families 1,2 for the app and widget.
It includes no MediaPipe frameworks, graph archives, model or bundled notices.
The inference adapter fails explicitly if called. Manual Station and partner
training remain available; experimental camera controls and counting do not.

`APP_STORE_BUILD=1 scripts/upload-testflight.sh` selects that spec and
checks the generated project before archiving; it also checks the archive's
app and widget device families and rejects leftover SDK assets before exporting.
The verifier selects it with the same flag and checks the generated project
before building. Any presence of the obsolete `APP_STORE_IPHONE_ONLY`
environment variable is rejected, including `0` or an empty value. Remove it
from old commands. A Swift compile guard rejects setting only the public
condition while retaining an importable MediaPipe SDK.
Ordinary TestFlight generation remains unchanged. The variant and guard live
under `ios/`, so disposable verification and screenshot source manifests include
their exact bytes. Run `python3 test/app-store-packaging.test.py` to generate
and inspect both projects using offline test placeholders (XcodeGen required).

The pinned 0.10.21 archives do not supply a privacy manifest or SDK signature,
and include Abseil/Protobuf components. Their existing network audit does not
establish App Store SDK-manifest compliance. The SDK is excluded from the public
candidate; an eventual public camera release needs its own SDK compliance review.

Public CI has separate native iPhone and iPad shards, including camera-unavailable
checks and manual Station/partner journeys. The ordinary beta Station shard and
full-suite schedule remain intact. Capture draft assets with
`scripts/capture-app-store-screenshots.sh NEW_OUTPUT iphone` or `... NEW_OUTPUT ipad`.
iPhone captures contain five portrait 1206×2622 PNGs; iPad captures contain six
portrait 2064×2752 PNGs, including manual Station. The
manifest records each image's dimensions, hash, and the exact source snapshot.

## Beta setup

`xcodegen generate` runs `setup_mediapipe.py` before generating the project.
The script downloads the official **MediaPipeTasksVision/Common 0.10.21** archives
and **Pose Landmarker Full float16 revision 1** into ignored `.dependencies/`.
Every download is checked against `mediapipe.lock.json`; existing extracted
files are checked against their recorded hashes. No runtime download occurs.
The Full model is 9,398,198 bytes; the Common archive is about 96 MB.

The direct XcodeGen integration reproduces the official CocoaPods specifications
linked in the lockfile: both static XCFrameworks, the platform-specific
force-loaded graph library, libc++, and the listed Apple system frameworks.
Both arm64 device and arm64/x86_64 simulator slices are supplied. This retains
the `.xcodeproj` path used by local, CI and TestFlight builds.
`TRESFORT_MEDIAPIPE_CACHE` may point to a shared archive cache; the verification
harness uses ignored `.artifacts/mediapipe-downloads`. A warm cache works offline.
Do not bypass checksum errors or use XcodeGen's generation cache after removing
dependencies; rerun normal `xcodegen generate`.

## Version and network behavior

Google's current [Tasks privacy notice](https://developers.google.com/edge/mediapipe/solutions/tasks#mediapipe-tasks-privacy-notice)
says input images stay on device but API usage/performance metrics are sent to
Google. The official 1.0.0 iOS binaries were inspected and contain a Clearcut
uploader and Google-internal stats logger, despite the public source factory
returning a dummy logger. **That package is not used.** No supported disable
option was found in its public iOS API.

The selected 0.10.21 package was inspected together with its matching tagged
source, not chosen solely because it predates that notice. Its
[Objective-C runner](https://github.com/google-ai-edge/mediapipe/blob/v0.10.21/mediapipe/tasks/ios/core/sources/MPPTaskRunner.mm)
passes requests to the C++ `TaskRunner` Create/Process/Close path. That
[tagged implementation](https://github.com/google-ai-edge/mediapipe/blob/v0.10.21/mediapipe/tasks/cc/core/task_runner.cc)
initializes, runs and closes a CalculatorGraph without a Tasks logging interface.
`mediapipe-audit.json` retains the reviewed source URLs/hashes and all six
framework/graph binary hashes. `audit_mediapipe.py` checks those exact binaries,
expected runner symbols, and rejects known metrics uploader/network imports on
every project generation. This guards this audited package; symbol absence alone
is not a universal proof that an arbitrary SDK cannot communicate externally.
An SDK update requires a fresh source and binary review, not just new checksums.

## License and detector contract

The SDK is Apache 2.0 with additional component notices inside the official
LICENSE. Both archives contain identical license bytes, bundled in `Notices/`.
Google's linked [BlazePose GHUM model card](https://storage.googleapis.com/mediapipe-assets/Model%20Card%20BlazePose%20GHUM%203D.pdf)
also specifies Apache 2.0. The model is published on the official
[Pose Landmarker page](https://developers.google.com/edge/mediapipe/solutions/vision/pose_landmarker).
Its inferred depth is not metric-accurate depth sensing.

The adapter uses CPU inference in synchronous video mode, one instance per
replay, on a caller-owned background serial context. It accepts BGRA frames and
strictly increasing timestamps. It physically orients each non-upright input
before inference so returned coordinates are normalized against the upright
image, with a top-left origin. This avoids mixing MediaPipe's input image
projection with Vision's upright coordinate convention. Per-frame timing includes
that orientation preparation and inference, but excludes model initialization.

When updating dependencies, verify official podspecs, architecture slices,
network behavior, model hash and adapter metadata, then run dependency tests and
real simulator + device builds. Never use a moving `latest` model URL.
