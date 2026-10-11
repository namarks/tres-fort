# Privacy policy publication (2026-10-11)

## Authority and source

On October 11 the owner asked to publish the policy, then explicitly approved
the production Worker deploy. That covered publishing the current
`website/privacy.mjs` (dated October 8, 2026) to both hosts. No migration,
secret, configuration or App Store Connect change was part of it.

The source is main `e49cd62d55250f31215e1829d3b7130d71895b8c`, tree
`b32b168f966eb9a373f926c484c8d8a7d933f854`. Among the app Worker's inputs, only
`website/privacy.mjs` differs from the previously serving source `cd3cf40`. There
were no `src/`, `migrations/`, `wrangler.jsonc` or dependency changes. The
checkout was clean.

## Pre-flight

- Website tests passed, and the build's `/privacy` carried the October 8 date.
  The pinned wrangler 4.130.0 dry run succeeded.
- `wrangler d1 migrations list DB --remote` reported no migrations to apply;
  0056 is the newest.
- The app Worker dry run kept the same bindings (D1 `tres-fort-db`, R2
  `tres-fort-demos`, `APPLE_BUNDLE_ID`, `INTERVALS_OAUTH_CLIENT_ID`). The
  bundle contained the October 8 policy and not the October 5 one.
- Baseline before the Worker deploy: `/health`, `/privacy` and OAuth discovery
  returned 200; `/api/state` and unauthenticated `POST /mcp` returned 401.

Before publication, `tresfort.app/privacy` served the September 12 policy and
the Worker's `/privacy` served the October 5 policy.

## Website (`tresfort.app`)

`npm run deploy:website` uploaded only `/privacy/index.html`. Version
`843f44c8-b97c-4dc3-ab8c-59b0ed8bf090` of `tres-fort-website`.

Afterwards the homepage, `/privacy` and a font asset returned 200, and missing
pages and assets returned 404. `/privacy` shows "Très Fort for iPhone, iPad and
its website · Last updated October 8, 2026" and the "Third-party AI services (AI
coaching connections)" section. The iCloud MX, SPF, Apple verification and DKIM
records matched the pre-deploy snapshot. The app's privacy link
(`AppInformation.privacyURL`) and the App Store privacy-policy URL both point here.

## App Worker (`tres-fort`)

`node_modules/.bin/wrangler deploy --message "source e49cd62… tree b32b168…
owner-approved privacy policy publication (Oct 8 policy)" --tag main-e49cd62d`,
following the [release procedure](../completed/coach-access-integrity/release.md).
Version `32d3243c-9ee3-47a6-acda-f18bf1d0c0b4`, created
`2026-10-11T20:52:01.526Z`, serves 100% of traffic. Its deployment message and
tag carry the source and tree above, and the hourly cron is retained.

At `2026-10-11T20:52:09Z`, `/health` returned 200 with the expected service
identity, `/privacy` and OAuth discovery returned 200, and `/api/state` and
unauthenticated `POST /mcp` returned 401, matching the baseline. `/privacy`
shows the October 8 policy. Its main content is identical to the website's,
apart from a bot-challenge script that Cloudflare injects on the `tresfort.app`
zone.

Rollback target, if ever needed: previous version
`5306d0d6-a4bf-4092-890b-55c4d6089000` (source `cd3cf40`). Its API is
identical; only the policy page would revert.

## Boundary

Publication does not answer App Privacy, confirm provider protections or
agreements, reply to App Review or resubmit. Those remain owner actions in
**Next step**. No authenticated API request or workout mutation was made.
