# Direct iPad iteration

Use a development build on the owner's connected iPad to inspect tracking while
the owner moves. This is an observation-only trial. Camera images are neither
recorded nor uploaded, and Station Mode cannot log or advance workout sets.

## Setup and installation

After an Xcode update, check for any license/first-launch gate. If Apple tooling
requires a new agreement, the owner must review and accept it in Xcode or via
`sudo xcodebuild -license` on the Mac running this workspace. Do not accept legal
terms or handle the owner's password on their behalf.

1. Finish any iPadOS update, unlock the iPad, trust the Mac and enable Developer
   Mode (including the required restart and confirmation). Select the iPad from
   `xcrun devicectl list devices` and keep its identifier in `station_device`.
   Read fresh details with
   `xcrun devicectl device info details --device "$station_device"` before
   continuing; obtain `station_udid` from its hardware properties locally.
2. Verify the existing development identity and local profile metadata. Both
   the app and embedded widget need valid development profiles containing the
   iPad. Reuse the existing team and signing identity. Existing App Store Connect
   authentication can support profile refresh even without a signed-in Xcode
   account; do not create or copy credentials. If no existing authorized method
   works, leave account sign-in or new signing credentials to the owner.
3. Generate the project and build incrementally. `station_udid` is the locally
   verified hardware UDID used by Xcode; `station_dev_sha1` identifies the
   existing Apple Development certificate. Do not put device identifiers or
   credentials in this document or the repository.

```bash
xcodegen generate --spec ios/project.yml
xcodebuild -project ios/TresFort.xcodeproj -scheme TresFort \
  -configuration Debug -destination "platform=iOS,id=$station_udid" \
  -derivedDataPath "$PWD/.artifacts/station-device/DerivedData" \
  DEVELOPMENT_TEAM=8BA2RY6RCA CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY='Apple Development' CURRENT_PROJECT_VERSION=46 build
```

If device registration/profile refresh is needed, the one-time build can add
`-allowProvisioningUpdates -allowProvisioningDeviceRegistration`. With an existing
authorized App Store Connect key, also pass `-authenticationKeyPath`,
`-authenticationKeyID` and `-authenticationKeyIssuerID` using the established
local release configuration. Pass the existing key file directly to Xcode;
never print, copy or commit its contents. This path successfully registered the
iPad and refreshed both development profiles with the existing release key.

Automatic signing rejects a literal certificate hash as `CODE_SIGN_IDENTITY`.
Use the supported `Apple Development` selector, then verify that **both** bundles'
actual signing-leaf fingerprints match the pre-existing `station_dev_sha1`
before installation. These provisioning flags permit wider portal changes;
stop if new certificates, credentials or owner interaction are requested. Keep
the DerivedData path for subsequent iterations.

4. Verify the resulting app and widget signatures, bundle IDs, team,
   `get-task-allow`, required capabilities, development profile expiry and iPad
   inclusion. Install in place with the same bundle/team. Never uninstall or
   clear app data as a debugging shortcut. Confirm the existing account and
   training are still present after installation.

```bash
station_app="$PWD/.artifacts/station-device/DerivedData/Build/Products/Debug-iphoneos/TresFort.app"
xcrun devicectl device install app --device "$station_udid" "$station_app"
xcrun devicectl device process launch --device "$station_udid" \
  --terminate-existing --console com.nmarkspdx.tresfort
```

Use the **TresFort** scheme. This process installs locally; it does not upload a
TestFlight build or change the backend. A connected TestFlight build does not
provide this Debug-only instrumentation.

## Inspect a trial

The owner opens Station Mode, enables the camera, expands **Developer
diagnostics**, and enables **Stream tracking measurements**. Camera access and
measurement output both require explicit action. Diagnostics are off by default
and turn off on leaving Station Mode. The on-device numerical history lasts at
most 60 seconds and is bounded by sample count; there is no file/network sink.

Filter the attached console for `STATION_DIAGNOSTIC ` followed by JSON. Output
is limited to two summaries per second; transitions and angle extrema between
summaries are coalesced. Preserve every emitted sample on the host: further
decimation loses hip-height and confidence changes. Even 2 Hz summaries are not
a full frame-rate movement trace; use actual counter results plus manual ground
truth to assess accuracy. Inspect only these diagnostic lines when sharing
evidence, rather than unrelated application logs. Capture source timestamps,
joint confidence/missing joints, admission reasons, counter phases, segment
resets and Apple warm-up/coverage/queue state. Missing values remain missing.
When no candidate limb qualifies, selected/input joint lists can be empty;
inspect the raw confidence and missing/unclear fields instead. For squats,
either complete hip/knee/ankle trio can qualify; both sides are not required.
Once a comparison becomes terminal, its admission field is the last decision,
while camera measurements continue updating. Label that decision as historical
and start a new comparison before assessing counting or rejection rates.
Keep the iPad unlocked during preparation and installation. An active Station
camera keeps the screen awake for the trial.

The verified live console path uses the connected iPad and `devicectl --console`.
Keep that connection during the trial; ordinary app operation does not require
it. A restricted shell may fail to initialize CoreDevice even while the device
is connected, so use the runtime's authorized device-service access. Xcode 27's
LLDB crashed during a separate attach attempt in this setup; stdout diagnostics
work without LLDB. A debugger-induced pause must not be attributed to camera
performance. Camera inference latency alone does not measure console delay.

Start with manually counted side-view and front-facing squats, including slow
reps, bottom pauses, partial dips and a brief occlusion. Also check standing
still, bending forward, stepping sideways and walking closer to the camera.
The existing custom counter still uses side-view 2D knee angles. Front-facing
hip/shoulder heights and torso scale are diagnostic candidates only; no frontal
counter has been validated. Compare a fixed standing-scale hip displacement
signal before considering a new counter, and test false counts and tracking
recovery before changing the supported movement guidance.

For a numerical change, run focused Station tests and rebuild/install/relaunch
with the same DerivedData path. Simulator tests establish logic and layout;
manual ground truth on the actual iPad establishes movement quality.
