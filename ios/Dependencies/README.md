# MediaPipe pose replay dependency

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
