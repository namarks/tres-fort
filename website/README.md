# Très Fort public website

Small, dependency-free static site for `tresfort.app` with an app landing page
and `/privacy`. The iOS API, database, and authentication stay in the existing
Worker. The website does not receive app credentials or training data.

Run `npm ci` in this directory to install the website's pinned Wrangler CLI.
Run `npm run dev`, `npm run build`, or `npm test` here as well.
The build produces only public files in `dist/`. Static builds and tests support
Node 20 or later; the pinned Cloudflare deployment CLI requires Node 22 or later.

## Cloudflare hosting

`wrangler.jsonc` configures the standalone `tres-fort-website` Worker in the
operator's Cloudflare account. It serves static files at `tresfort.app`, with
no Worker script, database, credentials, cron, or application bindings.

From this directory:

```sh
npm run build
npx wrangler deploy --config wrangler.jsonc --dry-run
npm run deploy
```

The repository-root `deploy:website` command also builds and deploys only this
website, after installing this directory's dependencies. Do not use the root
`deploy` or `release` command to publish website changes; those target the app
backend. The custom-domain route lets Cloudflare provision the website DNS
and HTTPS certificate. Preserve the existing iCloud MX, SPF, DKIM, and Apple
verification records. Check the homepage, `/privacy`, an asset, and a missing
URL after deployment; compare the email DNS records before and after.

## App download availability

On 2026-09-10, App Store Connect reported version 1.0 as
`PREPARE_FOR_SUBMISSION`. The existing Alpha Testers public link was enabled,
but its public page said it was not accepting new testers. The hero therefore
shows “Coming soon on iPhone” without linking to email or an unavailable
download. Replace that status with a working App Store link after publication,
or with an available public TestFlight link labelled as a beta. Recheck Apple's
live status before changing it; an enabled invitation URL alone is insufficient.

## Policy source

`privacy.mjs` owns the policy. `src/routes/privacy.ts` imports that same content,
preserving the policy URL already used by the app. Editing this file changes
both builds; deployment of the website does not deploy the app Worker.

Disclosures were checked against source at `69729d6`:

- `ios/TresFort/OnDeviceFeedbackTranscriber.swift`, `WorkoutFeedback.swift`,
  and `WorkoutFeedbackView.swift`: optional on-device speech recognition,
  discarded audio, and only explicitly saved text entering training records.
- `ios/TresFort/Health/HealthKitSyncModel.swift`: permissions, on-device
  heart-rate summary, uploaded workout fields, disconnect preserving imports.
- `ios/TresFort/Health/AppleHealthSettingsView.swift` and `src/db.ts` group
  projections: Apple Health group sharing is separate and off by default.
- `src/intervals.ts`, `src/routes/intervalsAuth.ts`, and `src/db.ts`: optional
  credentials, activity/event records and raw responses, strength-load export.
- `src/mcp/server.ts`, `src/oauth.ts`, and Profile: authorized coach reads and
  writes, group access, and revocation; no claim of deleting provider copies.
- `src/db.ts` `deleteUserAccount` and Profile: account export and active-record
  deletion, retained deletion receipts, and group transfer. No invented backup
  deletion deadline or automatic history purge on disconnect.

Repository behavior is not proof that the newest app Worker or iPhone build
has been released. No new consent or retention policy is activated by this
website change. Direct Garmin integration is not advertised.

## Colors

The palette lives in the `:root` tokens at the top of `styles.mjs` (and the
matching tokens in `privacy.mjs`, which the app Worker also serves at
`/privacy`). Change colors there, not in individual rules. The site uses the Ink palette:
one hue (OKLCH 255) as a tonal scale, neutrals tinted toward it, and a single
dusty-navy accent (ink 700, 7:1 on the page). Text and controls meet WCAG AA.
The app uses the same values (`ios/Shared/BrandPalette.swift`), and
`assets/app-icon.png` is the app's icon. The two app screenshots still show the
old dark and amber app until they are recaptured from a build with the new
palette.

## Assets

Fonts and icon come from the iPhone app. Both font licenses are retained in
`public/assets/`. Screenshots are unedited captures of the real app with
synthetic data, taken from source `69729d6` on an iPhone 17 Pro simulator,
iOS 26.2, on 2026-09-10. No member data was used.

The captures came from these existing passing journeys:

- `TrainingJourneyTests/testOrdinarySetLogsAndCompletesThroughAcknowledgement`
  (`ordinary-workout` attachment → `workout.png`).
- `WorkoutLibraryJourneyTests/testLibraryBadgesUnscheduleAndDateAssignment`
  (`workout-library` attachment → `library.png`).

Run those selections with `scripts/verify-ios.sh` and `IOS_KEEP_RESULTS=1` to
capture again; export the attachments with `xcrun xcresulttool export attachments`.
The simulator is disposable and the verification script removes it afterward.

## Publication boundary

The operator authorized moving this website to Cloudflare at `tresfort.app`
on 2026-09-10. Deployment of the existing app Worker, database migrations,
TestFlight distribution changes, and App Store publication remain separate
release actions. The earlier owner-private ChatGPT Sites preview is not the
website's hosting configuration or deployment target.
