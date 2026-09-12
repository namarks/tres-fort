# Reviewer access

App Store Connect rejected the Sign in with Apple-only review instructions with
required username/password errors. The owner approved a dedicated sample login
and preparation of a replacement build on 2026-09-11.

## App behavior

The signed-out screen has a visible **Reviewer sign-in** disclosure. Its username
is `app-review`; its password is entered only by the reviewer. The server checks
a random password against the `APP_REVIEW_PASSWORD_SHA256` Worker secret. Missing
or invalid configuration disables this path. The owner Apple subject must remain
configured and must not equal the reserved reviewer subject.

A successful login atomically creates a separate sample account and a strength
workout with three catalog exercises, a recurring schedule, and an ordinary plan
snapshot/audit record. Existing sample edits survive repeat and concurrent
sign-ins. Workouts, logging, feedback, history, export, and account deletion use
the normal account-scoped services. Deletion followed by login creates a new
account UUID; old bearers remain revoked. This is a shared review account: use
sample data only.

The account cannot become the MCP owner, join/read real groups, import Apple
Health, connect Intervals.icu, or establish Claude credentials. The server enforces
these limits, including after renewal; the app explains the personal sign-in
requirement. Personal deep links cannot bypass it. Legacy unscoped local training
and HealthKit values are never migrated into this account. It has no Apple grant,
so deletion does not display Apple revocation instructions. A reviewer can use
Sign in with Apple separately to inspect personal onboarding and optional features.

## Activation and review fields

No production activation follows automatically from repository merge. Deploy the
reviewed compatible Worker before distributing this client. No database migration
or new hosted resource is required. Use an owner-managed, cryptographically random
password with at least 32 characters; store only its lowercase SHA-256 digest as
`APP_REVIEW_PASSWORD_SHA256` through Wrangler's secret input. Do not place either
value in source, arguments, logs, repository notes, or build settings. Removing
that secret disables new reviewer logins and live sample-account requests. Existing
sample data remains until deletion; rotation does not reset workouts.

Put the username and actual password in the private App Review Information fields,
leave **Sign-in required** checked, and replace the earlier notes with:

> On the sign-in screen, expand Reviewer sign-in and enter the credentials above.
> This opens a shared sample account with a strength workout. From Today, choose
> the sample workout and start it; create/edit workouts, log sets, complete a
> workout, and inspect Calendar/history. Profile > Account provides export,
> sign-out, and deletion. Deleting this sample account is supported; signing in
> again creates fresh sample data. Use sample data only. To inspect personal
> onboarding, private groups, Apple Health, Intervals.icu, or Claude, sign out and
> use Sign in with Apple. Those connections are optional; Claude requires a
> separate account supporting custom connectors. No invitation or subscription
> is required to create and log workouts.

Keep the credential active throughout review. Verify actual login, a sample
workout write, and account isolation against the deployed Worker before selecting
the replacement build. App Review submission and public release remain distinct;
keep the owner's manual-release selection.
