# App Store review package

Refreshed October 8, 2026 for owner review; not published. The current
[readiness audit](readiness-2026-10-07.md) records source/provider evidence and
remaining limitations. Live completion and gates belong to
[plan.md](plan.md). Reconcile claims/screenshots with the final candidate before
upload. No credentials or personal training records belong in this file.

## Product page

| Field | Proposed value |
|---|---|
| Name | Très Fort |
| Version | 1.0 |
| Subtitle | Strength training, your way |
| Primary category | Health & Fitness |
| Price / availability | Free / United States only (owner-approved 2026-09-10) |
| Marketing URL | https://tresfort.app/ |
| Support URL | https://tresfort.app/#contact |
| Privacy policy URL | https://tresfort.app/privacy |
| Copyright | 2026 Nicholas Marks |
| Release option | Manual release after approval |
| Keywords | workout,strength,lifting,gym,sets,reps,rest,training,fitness,log,barbell,dumbbell |

Description:

Très Fort helps you plan your strength training and follow it set by set on
iPhone and iPad. Build your own workouts, or optionally connect Claude, Codex or another
compatible AI app to review and adapt your plan after you approve access.

TRAIN WITH A PLAN
Create reusable workouts, choose exercises and targets, and organize your
training schedule. Follow working sets, warm-ups, timed holds, supersets and
circuits in the gym.

KEEP YOUR PLACE
Log repetitions, weight or duration, use rest timers, and return to an
interrupted workout. Review your history and correct supported training entries.

REFLECT ON YOUR WORKOUT
Save optional notes and fatigue ratings. Type feedback or use on-device speech
recognition where available, then review and edit the text before saving.

CONNECT YOUR TRAINING
Optionally import workouts from Apple Health or connect Intervals.icu to keep
your other activities in view. An authorized AI coaching connection can use your training history to help
adapt your plan. Separately, view your latest Apple Health weight and trends
privately on your iPhone.

TRAIN TOGETHER
Use an iPad as a shared workout display while two members log sets on their own
iPhones. Each person keeps their own account, weights and training history,
with shared exercise and rest progress.

TRAIN WITH YOUR CREW
Join a private group to share training progress with people you know. Apple
Health group sharing has a separate setting that is off by default.

YOUR ACCOUNT, YOUR CHOICE
Apple Health, Intervals.icu, AI coaching and groups are optional. Sign in with Apple
to sync training, export your account data, or delete your account in Profile.
AI coaching requires a separate account with a compatible service. Claude
uses custom connectors; Codex linking requires a connected desktop/host.
Access to third-party services is governed by their own terms.

## Screenshots

Capture actual candidate screens using synthetic training data. Do not include
personal accounts, connection codes, fixture banners, fabricated features or
overlaid claims that hide the UI. Version 1.0 includes native iPhone and iPad
(owner decision 2026-10-08). Use `project-app-store.yml` through
`APP_STORE_BUILD=1`: it targets families 1 and 2 for app/widget, includes manual
Station/partner training, and excludes the experimental movement camera, SDK
and model. The default `project.yml` remains the camera-enabled beta.

Capture both required display classes: iPhone 17 Pro at 1206 × 2622, and 13-inch
iPad Pro (M4) at 2064 × 2752 portrait or 2752 × 2064 landscape. These match
[Apple's screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/),
checked October 8. Do not use beta camera screens in the public listing.

Suggested sequence: Today with a scheduled workout; workout runner with set
targets and rest controls; reusable workouts; training history; editable private
feedback. Add group or integration screenshots only after their release review
requirements are resolved. Preserve source SHA, build, simulator/device, locale
and dimensions with the resulting image set.

Use the [screenshot capture workflow](screenshot-capture.md) to produce and
validate the five-image iPhone and six-image iPad draft sets from the selected source. The iPad set adds manual Station setup. Its fictional-data
fixture uses actual screens and preserves source and successful-test evidence.

## Reviewer instructions

The app requires Sign in with Apple to synchronize a member's training.
Manual workout creation/logging works without Claude, Apple Health,
Intervals.icu or group membership. Describe and verify an approved reviewer
access path before submitting; a fresh-account walkthrough alone does not prove
that Apple's account-access requirement is satisfied.

Manual path: sign in; continue setup while skipping optional groups and
Intervals.icu; choose **Build my first workout**; create a workout and add an
exercise; open Today and start that workout; log a set; finish; open Today → Calendar
to inspect history.
Exercise targets can be edited from Workouts. Profile → Account contains **Download account data** and **Delete account**.
Profile also contains Group safety and privacy/support links.

Native iPad: the same manual workout, history and account paths are available
in portrait and landscape. Today → iPad Station opens the shared partner
display. Movement-camera counting and test recording are absent in this public
build; ordinary workout logging does not require camera permission.

Partner training needs two iPhones with **different** member accounts and an
iPad signed in to the host's account. Use designated nonpersonal reviewer/test
accounts with no completed workout or logged sets that day, and no pending
training writes. Refresh Today on both phones while online. Initial link-key
loading, saving the partner’s workout and starting both sessions require
internet; device discovery and shared progress also require local-network access:

1. On the host iPhone, start a workout without logging a set. In the runner menu,
   enable **Use iPad for partner workout**.
2. On the iPad, open Today → iPad Station and enable its host-phone connection.
   Once connected, choose **Train together**.
3. On the second iPhone, open Today → Train together → **Scan iPad code**. This
   uses the camera only to read the pairing QR; it does not count movements.
   Confirm the joining member on the iPad, review personal weights on the
   partner's phone, and choose **Save workout and get ready**. Choose **Start together** on the iPad.
4. Log a set on each person's own iPhone. The shared display advances after
   both log, and shows shared rest. Each member’s workout history records
   their own sets; phones also retain shared progress for recovery.
   Use Undo to correct a set or **Continue alone** to leave the shared workout.

No new member can join after the paired workout starts. Ordinary manual
training needs neither another device nor a partner. These instructions are a
draft until the [physical acceptance matrix](../partner-training/validation.md)
is completed on the selected public build; simulator UI checks do not establish
QR discovery, network recovery or account separation on actual devices.

Feedback: near workout completion, choose **Talk about your workout**. Type a
note or choose the microphone option, stop recording, edit the transcript and
choose **Save feedback**. Microphone/speech permission denial permits typing or
skipping. Real transcription depends on supported on-device language/model
availability; simulator synthetic speech is not a demo of actual recognition.

AI coaching: Profile → Coach opens on a permission step that names the recipient
(for example "Claude, operated by Anthropic"), lists the data shared and what the
connection can change, and offers **Allow sharing** or **Not now**. No setup link,
connection detail or connect code is shown before that choice (Guidelines
5.1.1(i)/5.1.2(i), rejected 2026-09-22). Coach explains access through
Anthropic. A member uses their own compatible Claude account, generates a connect
code, adds the Très Fort connector and explicitly authorizes it. Profile can
revoke the connection. Never place a real connect code in public review notes.

Apple Health: Profile → Apple Health explains server upload and coach access
before the member opens Apple's permission sheet. The app reads workouts and
available summaries; it does not write to Health. Optional group sharing is
off by default. Intervals.icu requires the reviewer's own authorized account or
an explicitly approved nonpersonal review arrangement.

Account deletion: Profile → Account → Delete account, confirm, and complete fresh Apple
authentication if requested. Verify with a designated review/test account;
never delete the operator's account to demonstrate this path.

Groups: open a member's safety menu from group settings or an activity detail.
**Report** prepares an email with a category and reference IDs; review the draft
before sending. The app also shows the support address and **Copy report
reference** when Mail is unavailable. **Block member** hides the two accounts'
shared profiles and activity from one another in every common group. Profile →
Group safety allows unblocking. This does not erase past views or copies.
Reports are checked daily and actionable abuse addressed within 24 hours.

## Privacy and rating preparation

The following is a proposed answer worksheet, not an attestation or a claim
that the App Store privacy label is current. Apple’s [App Privacy guidance](https://developer.apple.com/app-store/app-privacy-details/)
distinguishes off-device collection from purely local processing; optional
integrations still need disclosure unless all optional-disclosure criteria apply.
No advertising/tracking SDK is present in the examined source. App functionality
is the proposed purpose for account and training data; verify all provider log
and diagnostic practices before finalizing the declaration.

| Data | Observed source/use | Proposed classification to verify |
|---|---|---|
| Apple identity, optional name, relay/ordinary email | Sign in with Apple; account profile | User ID, name, email; linked to user; app functionality |
| Exercises, sets, durations, training load | Shared training service and history | Fitness; linked to user; app functionality |
| Imported heart-rate/health workout summaries and provider health metrics | Optional HealthKit workout uploads and full Intervals activity/event responses | Health and Fitness; linked to user; app functionality |
| Intervals device/gear metadata | Full provider responses may contain power-meter serial/device identifiers, names, gear and route references; no personal payload inspected | Device ID and Other User Content as applicable; linked to user; app functionality; verify the provider data inventory before attestation |
| Other retained Intervals metadata | Full responses also retain source/model identifiers, route references, weather summaries and processing timestamps | Other Data Types; linked to user; app functionality; no inferred location coordinates or downloaded attachment content |
| Apple Health body-weight view | Separate Read weight control; samples stay in process memory and are not backend/coach/group/export data | Not collected by this local-only path; Health is still declared for uploaded workout/provider data |
| Saved notes, fatigue, plan details, group names | Member/coach authoring, history and group feed | Other user content and relevant health/fitness data; linked to user |
| Group relationships and safety | Persisted private-group memberships, member block IDs, sharing restrictions, category-only operator audit; optional support email | Contacts for the group social graph (no phone address-book access), linked identifiers and support/user content; app functionality |
| Account action history | D1 audit records retain account-linked actor, tool/action, result and timestamps, including coach-disconnection actions | Product Interaction; linked to user; app functionality for security and reversible history, not analytics |
| Performance diagnostics | Current Worker settings return logpush false, tail consumers null and observability null; account logging inventory reads returned 403 | Independent provider analytics and historical exports remain unverified; do not attest no diagnostics collection from source config alone |
| Microphone recording | On-device transcription; discarded | Audio is not uploaded; saved transcript is user content |

Proposed purposes are **App Functionality** for the collected account/training
records, and **Product Personalization** for profile/training inputs used to
tailor starter workouts and authorized coaching. Proposed tracking answer: **No**
for the examined app. No advertising SDK or behavioral analytics was found;
confirm independent provider behavior before attesting the complete label.
Support correspondence belongs under Customer Support when collected. No raw
audio, camera video or local Health weight is uploaded by the public candidate. Pairing QR images are processed locally; the Station
link carries the explicitly shared workout, member display names and progress
between participating devices, including exercise cues, targets, weights and
reps. The partner saves a separate workout copy to their account. Closing
Station clears its display, but does not delete that saved copy or each
member’s own training history.
Intervals raw metadata is retained even though coach projections exclude it.

The required-reason manifest declares app-private UserDefaults (`CA92.1`) and
elapsed-event/timer SystemBootTime (`35F9.1`).
Following [Apple TN3184](https://developer.apple.com/documentation/technotes/tn3184-adding-data-collection-details-to-your-privacy-manifest),
it also declares the audited first-party name, email, user ID, Health, Fitness,
Device ID, Other User Content, Customer Support, Contacts (group relationships),
Other Data Types (remaining provider metadata), and Product Interaction
(persisted account-action history) categories as linked and
not used for tracking. All use App Functionality; Health, Fitness and Other User
Content also use Product Personalization. These source-backed declarations do
not substitute for the separately entered App Privacy answers or settle the
unverified provider-logging inventory. Audit the final archive for every
required-reason API and any third-party SDK manifest before upload.

Age questionnaire: the October 7 readback already marks health/wellness,
user-generated content and social features present; chat, ads, unrestricted web
access and medical/treatment information are absent. It returns FOUR_PLUS.
These match the inspected feature categories, but do not establish all content
frequency answers or an operator attestation. There is no gambling or purchase
feature in the examined source. Reconfirm the final questionnaire; do not infer
a required rating override merely from the policy saying the app is not
directed at children under 13.

## Group safety and protected storage

The owner approved the [private-group safety policy](group-safety-proposal.md)
and [aggregate-only diagnostics policy](diagnostics-policy-proposal.md) on
2026-09-10. The current implementation includes mutual blocking, email reports, conservative
shared-text filtering and reversible operator sharing restrictions. Enforcement
uses the same membership rule for rosters, REST/MCP feeds and statistics, before
pagination. It preserves private originals. Filtering is limited; human reports
handle context and evasion. Approval of this design does not establish Apple's
acceptance or production delivery.

The operator uses Profile → Group safety with the member ID from an email and a
bounded reason. Only the configured owner Apple identity has this control;
ordinary group creators do not. Restriction and audit commit together. No new
moderation service, admin website or report-content database is introduced.
Verify support-mail delivery and operator access before release. The October 7 SELECT-only ledger read confirms migrations through 0056,
including 0048; do not reapply that migration. The deployed Worker matches
build-49 source. Support-mail delivery and physical moderator access remain
unverified. Rolling back to a Worker without enforcement would undo the controls.

The implemented storage path migrates training snapshots, queued writes, runner recovery,
HealthKit anchors and Intervals metadata into app-owned files with complete
file protection and backup exclusion. Ordinary settings and account identifiers
remain in UserDefaults. Protected copies and deletion markers take precedence
over stale preference values; a failed migration preserves its source bytes.
Unreadable durable work pauses feature requests, and failed saves do not claim
a queued write. Foreground return retries storage after a normal device unlock;
unresolved failures expose Retry and support controls.
An unsuccessful navigation save asks the member to retry storage and reopen
the link or choose the destination again. Sign-out preserves the account until
saved navigation can be cleared; confirmed account deletion can explicitly
erase unreadable local data.
An explicit Apple Health disconnect can reset an unreadable sync cursor without
erasing workouts. Failed resets stop Health syncing and retain a retry control
across relaunch; a later connection rebuilds its cursor through idempotent import.

Verify protection on a physical iPhone and audit the final archive before
finalizing privacy answers. The old TestFlight build cannot read the new local
format: a rollback must retain the protected-storage reader or first reconcile
all pending work. Backup exclusion also means unsynced device-only work is not
recoverable from an iCloud device backup; server-acknowledged history can sync
again after sign-in.

Sources refreshed 2026-10-07: [Apple review guidelines](https://developer.apple.com/app-store/review/guidelines/),
[UserDefaults](https://developer.apple.com/documentation/Foundation/UserDefaults),
[backup exclusions](https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup).


## Prepared response to the privacy rejection

Use only after the compatible iPhone/iPad build and both policy URLs are live.
Replace `[BUILD]` with the verified selected candidate. This is a draft, not a
message sent to App Review or a statement that publication has occurred.

> Version 1.0 ([BUILD]) adds an explicit permission step before AI connection
> setup. Profile → Coach names the selected app and provider, explains which
> training and health information is shared and what the connection can change,
> and offers Allow sharing or Not now. The subsequent authorization also
> requires Allow or Deny. Manual workouts remain available without a coach.
>
> The updated privacy policy describes collection, uses, recipients, provider
> protections, retention and withdrawal. Profile → Disconnect all AI apps stops
> future access; the policy explains that already retrieved conversations are
> managed with the external AI service. The App Store privacy-policy URL is
> https://tresfort.app/privacy.
>
> Sign in with Apple creates a normal account without an invitation or payment.
> Reviewers can skip optional connections, create a workout, log and finish a
> session, and use Profile → Account to export or delete the account. Version
> 1.0 supports iPhone and native iPad. Manual partner training uses an iPad
> shared display and two separate iPhone accounts; each phone logs its own
> member’s sets. Movement-camera counting and experimental recordings are not
> included.

The operator must approve the existing equal-protection commitment against the
chosen providers before using this response. No consent-version enforcement or
revocation of existing grants is introduced by this preparation. The existing
policy explicitly says established connections retain access until disconnected.

## Metadata update packet

During the separately authorized App Store update:

- Replace the Claude-only description with the text above. Suggested
  promotional text: “Build workouts, track every set, and review your progress.
  Optional Apple Health, Intervals.icu and AI coach connections bring your
  training together.”
- Use the final public iPhone and native iPad captures; confirm both required
  display classes and dimensions in App Store Connect. Match the source to the
  selected candidate and exclude beta movement-camera screens.
- Replace the obsolete short reviewer notes with the tested manual/consent
  instructions above; clear the leftover retired demo username and password
  while keeping Sign in with Apple instructions. Contact fields were present
  on October 7; verify them without copying private values into this repository.
- Retain free US availability and MANUAL release after verifying live state.
  Confirm applicable agreements and the complete App Privacy questionnaire.
- Select the new compatible candidate, then send the approved rejection reply
  and resubmit only with App Review authority. Internal beta approval does not
  supply that authority.
